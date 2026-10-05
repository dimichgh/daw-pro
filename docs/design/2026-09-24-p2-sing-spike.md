# p2-sing: the hands-on spike plan for "sing typed lyrics on a melody"

Status: PLAN ONLY (written 2026-09-24/25 by daw-architect). Nothing in this document has been downloaded, installed or run.
Research input: `docs/research/2026-09-24-lyrics-sung-on-a-melody.md`.

## 0. Decision and scope

**Evidence tags used throughout.** VERIFIED = I read the primary source myself on 2026-09-24 or 2026-09-25 and the quote
below comes from that read (the URL or `file:line` is given). VERIFIED-2ND = verified by the research doc
(`docs/research/2026-09-24-lyrics-sung-on-a-melody.md`), which I did not re-fetch myself. UNVERIFIED = nobody has checked it.
The spike's job is to turn UNVERIFIED rows into measurements. DECISION = a call this plan makes, with the reason given.

### 0.1 The decision

DECISION: the hands-on spike runs **Route A: upstream SoulX-Singer** (`github.com/Soul-AILab/SoulX-Singer`,
Apache-2.0 code and weights) on this Mac. It uses the repo's own one-shot CLI (`python -m cli.inference`) plus a thin
in-process timing harness. It does **not** use the Gradio WebUI and does **not** build a sidecar: the FastAPI
sidecar belongs to the epic (§5), which is sized only after this spike reports. In the same run the spike does three more things:

- It runs **Route B** (ACE-Step Cover with the typed lyrics over a guide-tone bounce of the same melody) as the
  comparison baseline. ACE is started **only** through the staging app (port 17695), **never** on the user's
  app at 17600. It kills the ACE sidecar pidfile-exact straight afterwards (it holds ~75 GB when loaded; a standing user rule).
- It runs the community MLX conversion (`ailuntx/SoulX-Singer-MLX`) as an **optional leg (S-MLX)**, and only after
  the upstream leg has produced reference audio. §1.2 explains why this leg is not the primary path.
- It does **not** spike **Route C** (Synthesizer V Studio 2 Pro). Route C stays a named, priced alternative in §6.

### 0.2 The two strongest alternatives, and why they lose

1. **Skip the spike and build the sidecar epic directly** (an install script, a FastAPI facade and a Swift client,
   following the RVC shape). *Loses:* every load-bearing fact is unmeasured: whether it runs on MPS at all, the
   score schema, peak memory, and whether the output sounds usable. A facade built over an unread schema bakes
   guesses into the wire, and this project's wire is additive-only and never renamed, so a wrong guess is permanent.
   The RVC epic ran the same gate as its `(vi-a)` item (`docs/research/2026-07-11-vocals-voice-conversion.md:159`, VERIFIED).
2. **Spike the community MLX conversion first**, because it is labelled "Apple Silicon". *Loses:* it is third-party,
   and its own card says full audio generation "currently uses the official PyTorch model structure"
   (VERIFIED first-hand, §1.2). Testing it first stacks two unknowns: does upstream work, and did the conversion
   preserve it. A failure would not say which layer broke. Upstream first gives a **reference render**. The MLX leg
   is then judged against that render (§1.2), which is a comparison a first-leg MLX run cannot make.

(A third loser is recorded only so nobody re-litigates it. DiffSinger through OpenUtau has voicebank licences
that are fragmented per voicebank. Its only headless engine, `DiffSingerMiniEngine`, is AGPL-3.0 and archived.
VERIFIED-2ND, research doc §2.1.)

### 0.3 The failure modes this plan is built around

Each of these would produce a result that **looks valid and is wrong**, which is this tree's characteristic failure:

| # | Failure mode | Where it bites | Caught by |
|---|---|---|---|
| F1 | The stock script hardcodes `--device cuda` and `--fp16` (VERIFIED, `example/infer.sh`, quoted in §1.1) | It crashes, or someone "fixes" it by falling back to CPU without saying so | §1.1, §1.2 |
| F2 | MPS numerics yield NaN or all-zero audio, and the CLI still exits 0 and writes a `.wav`. (`--fp16` cannot cause this: it is honoured only on CUDA, VERIFIED `cli/inference.py`) | A silent file reads as "it ran" | §1.1's audibility and NaN check; §3's gates |
| F3 | `control=score` is set in `infer.sh` but not passed, and `--control` **defaults to `"melody"`** (VERIFIED, both fetches, §1.3 D) | The stock example silently runs the **melody (F0)** mode, not the score mode | Always pass `--control score`; §1.3's mode tell |
| F4 | `--auto_shift` (in the stock script) plausibly transposes the score toward the prompt singer's range (semantics UNVERIFIED) | Note accuracy is destroyed while the output still sounds fine | §1.7: auto_shift OFF for accuracy, ON only for the cloning listen |
| F5 | The voice reference needs a **metadata JSON as well as the wav** (`--prompt_metadata_path`, VERIFIED `infer.sh`). The README says the metadata comes from a preprocessing stack (separation, RMVPE, ROSVOT, Paraformer/Parakeet) | Parakeet is an NVIDIA NeMo model. That stack may be the real Mac blocker, not the synthesiser | §1.6's two-route prompt plan |
| F6 | Hidden first-use downloads into shared default caches (`~/.cache/huggingface`, ModelScope, torch hub) | The disk figure is wrong, and teardown leaves gigabytes behind | §2.3's pinned cache roots and before/after `du` of every default cache |
| F7 | Memory read on the wrong process, or with a metric blind to GPU memory. The ACE lesson as corrected on 2026-08-05: ~1 GB RSS on the `uv` wrapper's pid while its Python child held ~75 GB | Someone quotes a "2 GB model" that actually holds 20 GB | §1.5: direct-child launch, process-tree sum, footprint-class instruments, positive control |
| F8 | The Route-B leg or an import touches the **user's live app** (17600) | Their session gets mutated | The standing constraints in §0.5 |
| F9 | A `PYTORCH_ENABLE_MPS_FALLBACK=1` copied from a Mac install guide | Unsupported ops silently run on the CPU, with only a warning | §1.2: first run without it, fallback warnings counted |

### 0.4 Run order (the spike agent executes in this order and stops at the first KILL)

S0 preflight (§2.1) → S1 install (§2.2) → S2 device and compute-path tells (§1.1, §1.2) → S3 schema capture
(§1.3) → S4 speed and memory (§1.4, §1.5) → S5 note accuracy (§1.7) → S6 voice reference and cloning (§1.6)
→ S7 the Route-B baseline (§3) → S8 listening set gated and published (§3) → S-MLX (optional, §1.2) → S9
teardown and disk re-measure (§2.4). **Teardown (§2.4) also runs after every leg that loaded a model**, not only at the end.

### 0.5 Standing constraints the spike agent must be briefed on (non-negotiable)

- **Port 17600 is the user's live app.** Never connect to it, and never call any `mcp__daw-pro__*` or
  `mcp__plugin_daw-pro-music-team_daw-pro__*` tool. Any DAW-side step (a guide-tone bounce, pitch analysis,
  an import test) runs on a **staging** app at port 17695, launched and killed by the spike itself,
  pidfile-exact. Identify a process **by port** (`lsof -nP -p <pid> | grep -i listen`), never by path.
- **Name the test project** the spike creates (user rule 2026-08-23), for example `p2-sing-spike-2026-MM-DD`.
- **Pidfile-exact kill after every test** of every model process it starts: SoulX, and ACE for Route B. Never
  `pkill`/`pgrep`. Never kill a process whose pidfile the spike did not write.
- **Never touch** `scripts/ace-step/`, `scripts/rvc/` or their venvs, `.env`, or the user's audio devices
  (ZoomAudioDevice, ParrotAudioPlugin). Never list or grep `scripts/ace-step/`, `scripts/rvc/` or `scripts/video/` recursively.
- **No commits** (commits happen only on the user's word). No `git checkout/stash/restore/clean`.
- Evidence hygiene: there is **no `timeout(1)`** on this macOS. Never pair `2>/dev/null` with an emptiness you intend to read.
  Every negative result gets a positive control. Use `ffmpeg -hide_banner` (and `-loglevel verbose` for per-frame
  `ebur128`) when the loudness numbers are the point.
- **Nothing in §6 may start before the user answers §6.**

## 1. The questions the spike must answer

Every question has a **measurement**, a **positive control** (proof the instrument can return a non-empty,
non-zero answer on this machine), and a **PASS / KILL** line. The thresholds are DECISIONS made here so the spike
agent does not re-decide them. The rationale sits next to each one.

**Machine facts the thresholds rest on** (VERIFIED by read-only probes on 2026-09-24): Apple M5 Max,
128 GiB (`sysctl hw.memsize` = 137438953472), macOS 26.4 (25E246), 662 GiB free on the home volume (`df -h`).
`uv` is at `~/.local/bin/uv` and the `hf` CLI at `~/.local/bin/hf`. **No conda and no `python3.10`** are on
the PATH (only `/opt/homebrew/bin/python3.12`). `ffmpeg`/`ffprobe` are at `/opt/homebrew/bin`.

### 1.0 The named test fixtures (authored by the spike, in the spike's own named staging project)

T1 is a traditional nursery rhyme; its public-domain status is common knowledge, UNVERIFIED by a fetch here. T2 is a three-word
line written for this plan, borrowing no melody or text. T3 repeats T1. The fixtures are 4/4 at **100 BPM**, so a quarter note lasts 0.6 s. MIDI 60 = C4.

**T1 "twinkle", one syllable per note, 14 notes, 16 beats = 9.6 s** (the speed, memory and accuracy phrase):

| # | Syllable | MIDI | Start beat | Length (beats) |
|---|---|---|---|---|
| 1 | Twin | 60 | 0 | 1 |
| 2 | kle | 60 | 1 | 1 |
| 3 | twin | 67 | 2 | 1 |
| 4 | kle | 67 | 3 | 1 |
| 5 | lit | 69 | 4 | 1 |
| 6 | tle | 69 | 5 | 1 |
| 7 | star | 67 | 6 | 2 |
| 8 | how | 65 | 8 | 1 |
| 9 | I | 65 | 9 | 1 |
| 10 | won | 64 | 10 | 1 |
| 11 | der | 64 | 11 | 1 |
| 12 | what | 62 | 12 | 1 |
| 13 | you | 62 | 13 | 1 |
| 14 | are | 60 | 14 | 2 |

**T2 "hold me now", a melisma and a rest, 5 notes, 6 beats = 3.6 s.** "me" is **one syllable held across three notes**:

| # | Syllable | MIDI | Start beat | Length (beats) | Note |
|---|---|---|---|---|---|
| 1 | hold | 64 | 0 | 1 | |
| 2 | me | 65 | 1 | 0.5 | melisma starts |
| 3 | (me, continued) | 67 | 1.5 | 0.5 | slur / tie |
| 4 | (me, continued) | 69 | 2 | 1 | slur / tie |
| (rest) | | | 3 | 1 | one beat of silence |
| 5 | now | 67 | 4 | 2 | |

**T3 "long": T1 repeated with a one-beat rest between repeats.** It is made at two lengths: **T3-30 = 3 repeats (3×16 + 2 = 50 beats = 30.0 s)**
and **T3-60 = 6 repeats (6×16 + 5 = 101 beats = 60.6 s)**. It exists only to measure how speed and memory **grow with phrase length**.
An attention-based model can grow faster than linearly, and the product needs to know the longest phrase it can render in one call.

The fixtures are authored as DAW Pro MIDI clips (`MIDINote`, §4) and exported to the score format captured in §1.3.
**Syllable splitting ("twinkle" into "twin" + "kle") is given by the fixture.** Automatic syllabification of typed words is an epic item (§5), not a spike question.

### 1.1 Does it run on this Mac (Apple Silicon)?

**Why it is open.** The upstream example script targets CUDA. VERIFIED, verbatim from
`https://raw.githubusercontent.com/Soul-AILab/SoulX-Singer/main/example/infer.sh`:

```bash
model_path=pretrained_models/SoulX-Singer/model.pt
config=soulxsinger/config/soulxsinger.yaml
prompt_wav_path=example/audio/zh_prompt.mp3
prompt_metadata_path=example/audio/zh_prompt.json
target_metadata_path=example/audio/music.json
phoneset_path=soulxsinger/utils/phoneme/phone_set.json
save_dir=example/generated/music
control=score  # melody or score

python -m cli.inference \
    --device cuda \
    --model_path $model_path \
    --config $config \
    --prompt_wav_path $prompt_wav_path \
    --prompt_metadata_path $prompt_metadata_path \
    --target_metadata_path $target_metadata_path \
    --phoneset_path $phoneset_path \
    --save_dir $save_dir \
    --auto_shift \
    --pitch_shift 0 \
    --fp16
```

The README names no device at all: no CUDA, MPS, CPU or VRAM requirement (VERIFIED absence, README fetch of
`https://github.com/Soul-AILab/SoulX-Singer`). It pins **`python=3.10`** through conda (VERIFIED, README), and this Mac has neither.

**Measurement (S2).** Every step logs its full stdout and stderr to `$SPIKE_ROOT/logs/`. There is no stderr suppression anywhere.

**The harness contract (DECISION).** `harness.py` **imports upstream's `cli.inference` module** and calls its own model-construction and
inference functions with an argparse namespace built from the same flags. Around those calls it adds only four things: seeding (`torch.manual_seed`,
`torch.mps.manual_seed`), timing, the NaN check, and memory sampling. The seed is **20260924** for every run unless a test names another.
**It never re-implements inference.** If `cli/inference.py` has no importable entry point (its logic sits in a `__main__` body), the harness copies
that body **verbatim** with only the seeding and instrumentation added, and logs `diff cli/inference.py harness.py` so the copy stays checkable. So a CLI run and a harness run differ only in
what is measured, and "the code that ran is the code that was read" (§1.3 D) stays checkable.

1. **Interpreter and wheel check.** Run `$SPIKE_ROOT/venv/bin/python -c "import torch, platform; print(torch.__version__, platform.machine(), torch.backends.mps.is_built(), torch.backends.mps.is_available())"`.
   It must print `arm64 True True`. Run the venv python **directly**, never through `uv run`. §1.5 explains why: a `uv` wrapper puts the model in a child process.
2. **The CLI surface.** Run `python -m cli.inference --help`, save the help text verbatim to `logs/cli-help.txt`, and record the accepted `--device` values. This file is also the primary source for §1.3's flags.
3. **Positive control: the repo's own fixture.** Run the command above with four changes: `--device mps`, **no `--fp16`**,
   `PYTORCH_ENABLE_MPS_FALLBACK` **unset** (F9), and **`--control score` added explicitly** (F3; the stock line omits it and the default is melody).
   Pass every path explicitly. The argparse defaults point at `example/metadata/…` and `zh_prompt.wav`, and the git-tree listing
   shows only `example/audio/…` with `.mp3` prompts. This uses upstream's own `zh_prompt` and `music.json`, so it separates
   "the engine cannot sing on this Mac" from "our English score is malformed". Then repeat with upstream's **English** pair
   (`en_prompt.mp3`/`.json` as the prompt and `en_target.json` as the target) as the English positive control.
4. **Variants on the same fixture.** Run (a) `--device mps --fp16` through the seeded harness. It must be **bit-identical** to the fp32 MPS run, because the flag is CUDA-only (§1.3 D). A difference means the code that runs is not the code that was read. Run (b) `--device cpu`. The CPU run is the control and the slow floor.
5. **The audibility and NaN gate** (F2) on every output. Inside the harness, before the file is written, run `torch.isnan(wav).any()` and
   `torch.isinf(wav).any()`, and write **float32** WAV. After it is written, run
   `ffmpeg -hide_banner -i out.wav -af ebur128=peak=true,astats -f null -`. That call reads integrated LUFS, true peak, RMS and astats' `Number of NaNs`.
   **The gate is itself positive-controlled.** It must PASS upstream's own `example/audio/zh_prompt.mp3` and must FAIL a
   silence file (`ffmpeg -f lavfi -i anullsrc=r=44100:cl=mono -t 10 -c:a pcm_f32le silence.wav`). If it cannot fail the silence file, it measures nothing.
6. **Duration check.** Output duration (`ffprobe`) must be within ±5% of the score's total duration read from the metadata.
   A wrong-length file that still sounds like singing is F3's signature: the melody mode was used, or the score was ignored.

**Patching rule.** The spike **may** make three kinds of patch:

1. Change device strings: `cuda` → `mps`/`cpu` in the CLI, in `DataProcessor(device='cuda')`'s default, and in any hard `.cuda()` / `torch.cuda.*` call.
2. Guard the import of a CUDA-oriented kernel package with a fallback to `torch.nn.functional.scaled_dot_product_attention`, if upstream has no fallback already.
   `sageattention==1.0.6` is pinned (VERIFIED, `requirements.txt`). Whether it installs or imports on macOS arm64 is UNVERIFIED.
3. Drop pins that SVS inference never imports (§2.2).

Every patch is kept as a `git diff` of the upstream clone in `logs/upstream-patch.diff` with a line count. Anything deeper is **not** done in the spike, for example re-implementing an op. It is recorded as an epic cost.

**PASS:** step 3 produces a NaN-free, audible (integrated loudness above -40 LUFS, RMS above -50 dBFS), correct-length wav on
`--device mps` in fp32, with the fallback env unset and only the patching rule's allowed patches.
**PASS-degraded:** MPS fails but CPU passes, with CPU RTF ≤ 4 (see §1.4). Record the MPS failure verbatim (op name, PyTorch version).
**KILL:** neither MPS nor CPU produces an audible, correct-length file. Also KILL if the install needs a CUDA-only package with no CPU/MPS path
(for example an unconditional `flash_attn`, `triton` or `sageattention` dependency inside the model math) that the three allowed patches cannot remove.
**Precision.** All MPS measurements are fp32, because `--fp16` does nothing on MPS. An fp16/bf16 MPS path is an S-MLX or epic question, not a PASS criterion.


### 1.2 Which compute path ran: MLX, PyTorch/MPS, or CPU?

**The honest reframe (VERIFIED first-hand).** No pure-MLX inference path exists to test. The Hugging Face card
(`https://huggingface.co/mlx-community/SoulX-Singer`) says: *"This is not a pure end-to-end MLX audio runtime yet. The
weights are converted to an MLX-friendly safetensors layout, while full audio generation currently uses the official
PyTorch model structure through `ailuntx/SoulX-Singer-MLX`."* The community repo
(`https://github.com/ailuntx/SoulX-Singer-MLX`) repeats it: *"Full audio generation still uses the official PyTorch model
structure as a bridge. This is not yet a pure end-to-end MLX runtime."* So the "MLX path" is a **weight format and a
loader**, and the compute is PyTorch. The measurable questions become two:

- **(a)** On which device does the PyTorch compute actually land: MPS, CPU, or a silent mix?
- **(b)** Does the MLX conversion buy anything: a smaller download, lower runtime memory, or speed? And does it preserve the weights?

**A warning sign, noted rather than concluded.** The community repo's own documented SVS command is
`PYTORCH_ENABLE_MPS_FALLBACK=1 python scripts/inference_mlx_bridge.py --model ./models/SoulX-Singer-bf16 --component svs --device mps --prompt_wav_path example/audio/zh_prompt.mp3 --n_steps 1 --cfg 1`
(VERIFIED, same fetch). Setting the fallback variable **suggests** at least one op in the model is not implemented on
MPS. That is my inference (UNVERIFIED), and it is exactly failure mode F9. The same command shows the sampler has
`--n_steps` and `--cfg` knobs. The **upstream** CLI does not expose them (VERIFIED absent from its argparse, §1.3 D). The YAML supplies them
(32 and 3), and the harness can override them.

**Measurement (S2, continued). Five tells, all logged per run into `logs/compute-path-<run>.json`:**

1. **Which torch device holds the model.** After the model loads, record `str(next(model.parameters()).device)`; it is expected to be `mps:0`.
   After synthesis, record `torch.mps.current_allocated_memory()` and `torch.mps.driver_allocated_memory()`. Zero MPS bytes after a
   "successful" MPS run means MPS never did the work.
2. **Hidden CPU fallback (F9).** The first run always has `PYTORCH_ENABLE_MPS_FALLBACK` **unset**, so an unsupported op raises
   `NotImplementedError` with the op name, loudly. Only if that happens is a second run made with it set to `1`, under `python -W always`.
   The default warning filter shows a warning only once per location, which would under-count. That run
   counts every fallback `UserWarning` and lists the distinct `aten::` op names.
3. **Where the time goes.** Wrap only the synthesis call (not model load) in `torch.profiler.profile(activities=[ProfilerActivity.CPU])`
   and `cProfile`, and save the top-30 `aten::` ops by self CPU time.
   - **The CPU-fallback share is an estimate:** the self CPU time of the ops that tell 2's warnings flagged, divided by the total. The 2.2 profiler does not
     capture asynchronous MPS kernel time, so the report must say "estimated".
   - **The MLX share** is the fraction of time in `mlx.*` versus `torch.*` Python frames (cProfile). A synthesis call with 0% `mlx.*` time means MLX did
     no compute, however the weights were loaded.
4. **Whether MLX was even imported.** Record `'mlx.core' in sys.modules` after synthesis. It must be **False** on the
   upstream leg; this is the negative control that proves the tell can read False. On the S-MLX leg it will be True (the loader), which on its own proves only an import.
5. **The external GPU-activity tell** (independent of anything the process says about itself). Sample
   `ioreg -r -c IOAccelerator -d 1 -w 0` every 0.5 s and parse `"Device Utilization %"` and `"In use system memory"`.
   VERIFIED on this Mac 2026-09-24: both keys exist on `AGXAcceleratorG17X` and are readable **without sudo**. They are
   system-wide, so the spike takes a 30 s idle baseline first, with the user away and no other CPU/GPU work running.
   - **Positive control:** a 10 s loop of 4096×4096 fp32 `torch.mm` on `mps` must lift Device Utilization well above
     baseline (DECISION: at least +40 points) and lift "In use system memory".
   - **Negative control:** the same loop on `cpu` must leave both within noise of baseline. If the positive control does not move
     the counter, this tell is blind and the report says so. It is not treated as "no GPU used".

**Verdict rule for (a).** "Ran on MPS" is claimed only if tells 1, 3 and 5 all agree: MPS bytes above 0, an **estimated** CPU-fallback share (tell 3)
below 20% of synthesis self-time, and GPU utilization above baseline for the length of the synthesis. **If two tells disagree, that disagreement is
the finding** and gets reported, not averaged away.

**S-MLX leg (optional; runs only after the upstream leg PASSES §1.1) answers (b):**

- **Weight fidelity, deterministic, no listening.** Cast the upstream `model.pt` state dict to bf16 in torch, and compare it tensor by tensor
  with the bridge's **bf16** conversion (2.6 GB). A faithful conversion gives max |Δ| = 0, because both sides round the same fp32 values to bf16.
  The 4-bit variant (774 MB) is compared after the bridge's own dequantization, as per-tensor relative error. **The fp32 conversion (5.6 GB) is not
  downloaded.** It is almost exactly `model.pt` + `model-svc.pt` together (2.82 + 2.79 GB, VERIFIED sizes in §2.2), so the MLX
  card's sizes very likely cover SVS **and** SVC. That is an inference, UNVERIFIED. The spike downloads only the SVS files if the repo layout allows.
- **Output fidelity.** No null test is possible across precisions, so compare the bridge renders against upstream's fp32 render at the same seed on two measures: §1.7's
  note-accuracy score, and a log-mel distance (the mean absolute difference over the model's own 128 mel bands).
  **Calibrate the distance first:** the distance between two upstream fp32 renders at *different* seeds (20260924 and 20260925) is the natural-variation baseline. A quantized variant at or under that
  baseline is "within natural variation". **No agent can listen**, so if a subjective check of the quantized variants is wanted, it goes to the user as a
  separate optional page. These variants are **not** part of §3's set.
- **What it saves.** Download size (VERIFIED card sizes: 4-bit 774 MB, 8-bit 1.4 GB, bf16 2.6 GB, fp32 5.6 GB). Runtime peak memory
  and RTF go through §1.4 and §1.5's instruments. The paraphrased card summary says the bridge **dequantizes** quantized weights at run time. That is
  UNVERIFIED, and if true, 4-bit saves download bytes but not runtime memory. Measure it; do not assume it.

**PASS (a):** the verdict rule holds on MPS (fp32 is acceptable). **PASS-degraded (a):** CPU fallback ops take 20–50% of synthesis
self-time. That is recorded as an epic item: pin a newer PyTorch, or patch the op. **KILL (a) on MPS:** more than 50% of synthesis self-time is CPU
fallback **and** CPU-only RTF fails §1.4. The route then depends on a PyTorch MPS fix, which the user must know about.
**S-MLX verdict:** "adopt the quantized weights in the epic" only if the bf16 weight comparison is exact (max |Δ| = 0) **and** a quantized variant
cuts runtime peak memory or RTF by at least 25% with a §1.7 score within 5 points of upstream. Otherwise the recorded finding is "MLX conversion =
smaller download only" or "no value". **An S-MLX KILL never kills Route A**, because upstream is the primary path.

### 1.3 The exact score-input schema

**Source-read status.** Everything in this subsection was fetched from the upstream repo on 2026-09-24
(`main` branch; the commits API read the same day shows HEAD at `81aeb3a…`, pinned in §2.2). It was returned through a summarising fetch tool, which **miscounted tokens twice**
(it reported 11 and 24 tokens where the lists hold 14; see below). So **S3 step 1 re-reads every raw file named here and diffs it
against these quotes** before anything is built on them. The files and their sizes come from the git-tree API
(`https://api.github.com/repos/Soul-AILab/SoulX-Singer/git/trees/main?recursive=1`, VERIFIED): `example/audio/en_prompt.json`
(1958 B), `example/audio/en_target.json` (2729 B), `example/audio/music.json` (15927 B), `example/audio/zh_prompt.json` (3613 B),
`cli/inference.py` (6335 B), `soulxsinger/utils/data_processor.py` (6679 B), `soulxsinger/config/soulxsinger.yaml` (579 B),
`preprocess/tools/g2p.py` (1808 B), `preprocess/tools/midi_parser.py` (20282 B).

**A. File shape.** A metadata file is a JSON **array** of segment objects. Each object has these keys (VERIFIED in `zh_prompt.json`,
`music.json` and `en_prompt.json`): `index` (string), `language` (string; `"English"` and `"Mandarin"` are seen), `time` (`[start_ms, end_ms]`),
`duration`, `text`, `phoneme`, `note_pitch`, `note_type` (each a **space-separated string with one entry per note-token**), and `f0` (a
space-separated string at frame rate). Units, VERIFIED by arithmetic on the fetched values:

- `duration` is in **seconds**. `en_prompt.json`'s 14 durations sum to **5.06 s** against `time` `[5220, 10280]` (5060 ms).
- `zh_prompt.json`'s 23 durations sum to **10.36 s** against `[320, 10687]` (10.367 s).
- `note_pitch` holds **MIDI note numbers**, with **0 for a rest**. In `music.json`, notes marked 64 sit on f0 ≈ 330 Hz, and E4 = 329.6 Hz.

**B. The English token grammar** (VERIFIED, `https://raw.githubusercontent.com/Soul-AILab/SoulX-Singer/main/example/audio/en_prompt.json`).
One token per **note**. An English token is **a whole word**: `en_` followed by that word's ARPAbet phones joined with `-`, with stress digits on the vowels.
Upstream examples include `en_UW1`, `en_W-IH1-SH` and `en_N-AH1-TH-IH0-NG`. A word held across N notes **repeats the same text and
phoneme token N times**. Rests are `<SP>`. The file's per-note lists, with the lyric words deliberately **not reproduced** here
(`en_target.json` carries commercial-song lyrics, which the fetch tool declined to reproduce; this plan does not need it):

```text
duration   : 0.24 0.36 0.30 0.78 0.24 0.56 0.19 0.53 0.36 0.20 0.32 0.57 0.19 0.22      (14 entries)
note_pitch : 0 63 65 0 65 67 68 62 62 64 67 67 65 0                                      (14 entries)
note_type  : 1 2 3 1 2 2 2 3 2 3 2 2 3 1                                                 (14 entries)
phoneme    : <SP> en_UW1 en_UW1 <SP> ... en_N-AH1-TH-IH0-NG en_N-AH1-TH-IH0-NG ... <SP>  (14 tokens; "..." elided here)
```

**`note_type` semantics: an INFERENCE from the three fetched files, UNVERIFIED in code.** In all three files, every `<SP>` token has type **1**
(and pitch 0). A token that **repeats the previous word** (the melisma or held-syllable continuation) has type **3**. Every other note, where
a new word starts, has type **2**. The one exception seen: a `zh_prompt.json` row where the fetch output shows a `<SP>` with pitch 67.
It is either a fetch-tool transcription error or an auto-transcription wart. S3 confirms the meaning by reading
`DataProcessor.preprocess` / `merge_phoneme` in full.

**C. How the metadata becomes model input** (VERIFIED, `soulxsinger/utils/data_processor.py`, as returned by the fetch tool).
The signatures are `__init__(self, hop_size: int, sample_rate: int, phoneset_path: str = 'soulxsinger/utils/phoneme/phone_set.json', device: str = 'cuda', prompt_append_duration: float = 0.5)`,
`merge_phoneme(self, meta)`, `preprocess(self, note_duration, phonemes, note_pitch, note_type)` and `process(self, meta, wav_path=None)`. English is detected by
`if phonemes[ph_idx][:3] == "en_"` and expanded by `phonemes[ph_idx][3:].split('-')`. The special tokens `<BOW>`, `<EOW>`, `<SEP>` and `<PAD>` are used in the expansion.
`process` in full:

```python
def process(self, meta: dict, wav_path: str = None):
    meta = self.merge_phoneme(meta)
    item = self.preprocess(meta["duration"], meta["phoneme"],
                          meta["note_pitch"], meta["note_type"])
    f0 = [float(x) for x in meta.get("f0", "").split()]
    min_frame = min(item["mel2note"].shape[1], len(f0)) if len(f0) > 0 else item["mel2note"].shape[1]
    item['f0'] = torch.tensor(f0)[:min_frame].unsqueeze(0).float().to(self.device) if len(f0) > 0 else None
    item["mel2note"] = item["mel2note"][:, :min_frame]
    if wav_path is not None:
        waveform = load_wav(wav_path, self.sample_rate)
        item["waveform"] = waveform.to(self.device)[:, :min_frame * self.hop_size]
    return item
```

Consequences (VERIFIED as code reading, not yet as behaviour). **`f0` is optional:** an absent key gives `item['f0'] = None`. The note timeline
(`mel2note`) is built from `duration`. `f0` is read at the **mel frame rate** and truncated to it. So a DAW-generated target can omit `f0`, and
whether score mode then runs is S3's test. The **prompt** is processed with `wav_path`, so the prompt's metadata must align with its audio.

**D. The CLI surface** (VERIFIED, `cli/inference.py` argparse, as returned by the fetch tool):

```python
parser.add_argument("--device", type=str, default="cuda")
parser.add_argument("--model_path", type=str, default='pretrained_models/soulx-singer/model.pt')
parser.add_argument("--config", type=str, default='soulxsinger/config/soulxsinger.yaml')
parser.add_argument("--prompt_wav_path", type=str, default='example/audio/zh_prompt.wav')
parser.add_argument("--prompt_metadata_path", type=str, default='example/metadata/zh_prompt.json')
parser.add_argument("--target_metadata_path", type=str, default='example/metadata/zh_target.json')
parser.add_argument("--phoneset_path", type=str, default='soulxsinger/utils/phoneme/phone_set.json')
parser.add_argument("--save_dir", type=str, default='outputs')
parser.add_argument("--auto_shift", action="store_true")
parser.add_argument("--pitch_shift", type=int, default=0)
parser.add_argument("--control", type=str, default="melody", choices=["melody", "score"], help="Control mode: melody or score only")
parser.add_argument("--fp16", action="store_true", default=False, help="Use FP16 inference (faster on GPU)")
```

The fp16 path runs only on CUDA:
`if use_fp16 and ((isinstance(device, str) and device.startswith("cuda")) or (hasattr(device, "type") and getattr(device, "type", None) == "cuda"))`.
The output is `generated.wav` at **24000 Hz**. The config (VERIFIED, `soulxsinger.yaml`) is `infer: n_steps: 32, cfg: 3` and
`audio: hop_size: 480, sample_rate: 24000, max_length: 36000, n_fft: 1920, num_mels: 128, fmin: 0, fmax: 12000`. The model is a flow-matching
transformer: `hidden_size: 1024, num_layers: 22, num_heads: 16`.

Three findings follow from that source, each a trap for a spike that runs the stock script:

1. **F3 is real (VERIFIED from two fetches).** `--control` **defaults to `"melody"`**, and the fetched `example/infer.sh` sets
   `control=score` but its `python -m cli.inference` line has no `--control`. **The stock example runs in melody mode.** It still
   "works" because `music.json` carries `f0`. The spike always passes `--control score` explicitly. On the day it re-checks the script with
   `grep -n -- '--control' example/infer.sh`, positive-controlled by `grep -n -- '--device' example/infer.sh`.
2. **`--fp16` is a no-op on MPS** (VERIFIED as code reading). §1.1 step 4a therefore becomes a check that the flag does nothing, not a precision test.
3. **There is no `--seed`, `--n_steps` or `--cfg` flag** (VERIFIED absent from the argparse list). The values come from the YAML
   (32 steps, cfg 3). All determinism and null tests go through the spike's **harness**, which seeds `torch.manual_seed` and
   `torch.mps.manual_seed` itself. Two CLI runs are not expected to match.

`--auto_shift` and `--pitch_shift` are passed to `model.infer`. What they do is **UNVERIFIED** (see F4). S3 reads `model.infer` and S5 measures it.

**E. The converter the spike writes: DAW notes to SoulX target metadata** (`$SPIKE_CODE/score_from_notes.py`). This is DECISION-level
design; the epic reuses it.

1. Input: `(pitch, startBeat, lengthBeats)` triples in `MIDINote.canonicallyOrdered` order, a tempo (fixed 100 BPM for the spike),
   and the words **already assigned to notes** (the fixture gives the assignment).
2. Convert beats to seconds. Emit a leading `<SP>` of 0.24 s. Upstream's examples open with a 0.21–0.24 s `<SP>` (`music.json` 0.21,
   `zh_prompt.json` 0.23, `en_prompt.json` 0.24; VERIFIED fetched values). Emit an `<SP>` for every gap between notes and a
   trailing `<SP>`. **Round the cumulative onset times to 10 ms and then take differences.** Never round each duration on its own,
   or the rounding error accumulates along the phrase (14 notes × ±5 ms = up to ±70 ms of drift).
3. Per note: `text` = the word; `phoneme` = `en_` + `-`.join(g2p_en(word)); `note_pitch` = MIDI; `note_type` = 2 on a word's first
   note and 3 on its continuation notes. Rests: `<SP>` / `<SP>` / 0 / 1.
4. `language: "English"`, `time: [0, total_ms]`, `index: "vocal_0_<total_ms>"`, and **no `f0` key**.
5. Assert that all five per-note lists have equal length, that the durations sum to `time[1] - time[0]` within 10 ms, and that every phone is in `phone_set.json`
   (VERIFIED to contain `en_`-prefixed ARPAbet with stress digits, for example `en_AA0`, `en_IH1`, `en_NG`, plus `<SP>`, `<AP>`, `<BOW>` and `<EOW>`).
   **The spike does not quote the phone set's per-prefix counts.** The fetch returned counts that do not add up to its own total.

Expected `g2p_en` tokens for the fixtures (standard CMUdict pronunciations, UNVERIFIED until `g2p_en==2.1.0` runs; the spike logs
the actual output): twinkle `en_T-W-IH1-NG-K-AH0-L`, little `en_L-IH1-T-AH0-L`, star `en_S-T-AA1-R`, how `en_HH-AW1`,
I `en_AY1`, wonder `en_W-AH1-N-D-ER0`, what `en_W-AH1-T`, you `en_Y-UW1`, are `en_AA1-R`, hold `en_HH-OW1-L-D`, me
`en_M-IY1`, now `en_N-AW1`.

**Fixture encoding.** §1.0's syllable columns map to SoulX's word tokens like this:

- **T1:** Twinkle(2) Twinkle(3) twinkle(2) twinkle(3) little(2) little(3) star(2) how(2) I(2) wonder(2) wonder(3) what(2) you(2) are(2).
- **T2:** hold(2) me(2) me(3) me(3) `<SP>`(1) now(2).

**Measurement (S3).**

1. Diff the raw files against every quote above. Any mismatch is reported, and the plan is re-read before building on it.
2. **The mode tell** (F3, a deterministic null test through the seeded harness). Render T1 as follows:
   - **(i)** `--control score`, no `f0`. It must render.
   - **(ii)** `--control melody`, no `f0`. It is **expected to fail loudly** or to differ grossly from (i). This is the positive control that the flag is actually consumed.
   - **(iii)** `--control score` with a deliberately wrong constant `f0` (110 Hz on every frame). At the same seed it must be **identical to (i)** (max |Δ| sample = 0).
     If not, score mode reads `f0`, and that is recorded.
   - **(iv)** `--control score` with every `note_pitch` +2. The output's median F0 must move **+200 ± 25 cents** (§1.7's instrument).
3. Word-level melisma: render T2. Check with §1.7's per-note F0 that the three "me" notes land on their pitches. Then check that "me" is
   **held**, not re-articulated three times. A re-articulated "me" closes on the nasal M, which shows as an RMS dip. The criterion is no RMS dip deeper
   than 6 dB within ±40 ms of the 2→3 and 3→4 note boundaries (20 ms frames). The dip test is a DECISION and UNVERIFIED as a discriminator.
   **Positive control:** render a T2 variant where "me" is three separate words (`note_type` 2, 2, 2), which should show the dips.
   If the metric cannot tell the two renders apart, it is reported as **undecidable**. The question then moves to the user's listening page as a labelled
   extra. It is never passed silently. **No agent can listen**, so an agent's impression is never evidence here.

**PASS:** a DAW-generated target with no `f0` renders in score mode, and (iii) is identical to (i) while (iv) moves +200 cents.
**KILL:** score mode needs a frame-level `f0` that only an audio analysis can supply, so a MIDI-only target cannot be sung.
That kills the "type lyrics on a melody" shape of Route A even if everything else passes. It would be reported as the headline.

### 1.4 Inference speed (real-time factor)

**Definition.** RTF = wall-clock synthesis time ÷ duration of the audio produced. RTF 0.5 means a 10 s phrase takes 5 s. Two numbers are
reported, and they answer different product questions:

- **Warm RTF.** The synthesis call only, with the model already loaded. Measured in the harness as the median of 5 runs after 1 discarded
  warm-up. This sets how long a user waits per phrase.
- **Cold start.** Process launch to the first wav written, which covers Python imports, model load and one synthesis. Measured externally by
  `/usr/bin/time -l` (`real`). This decides the epic's process shape. If cold start is at least 30 s, the epic needs a resident sidecar with
  idle teardown (the ACE/RVC shape). If it is at most 5 s, a one-shot process per job is enough. **Between 5 and 30 s, the resident-sidecar shape wins**, because it is already built for ACE and RVC.

**Named phrases.** T1 (9.6 s) is primary. T3-30 and T3-60 show how RTF **scales with phrase length**. Every run uses the config's
own sampler settings: `n_steps: 32` and `cfg: 3` (VERIFIED, `soulxsinger.yaml`). They are recorded per run, because they are the quality settings and
the listening set uses them. **S4b (optional)** re-measures warm RTF on T1 at `n_steps` ∈ {8, 16}, a speed-versus-quality curve for the
epic. Those renders are **not** shown to the user.

**The trap: MPS is asynchronous.** A clock stopped when the Python call returns measures kernel **enqueue**, not the work. Two things guard against it:

- **Stopping the clock.** The harness stops the clock only after `torch.mps.synchronize()` **and** after `wav.cpu()` has been
  materialised.
- **Positive control for the timer.** Time a 10 s `torch.mm` loop on `mps` twice, once with the synchronize and once without. The unsynchronized
  number must come out **much** smaller. That proves the sync is doing its job and the harness is not reporting enqueue time.

**Conditions.**

- The machine is otherwise idle, and the user is away. This is the tree's own law: never run CPU work while measuring.
- Record `sysctl -n vm.loadavg` before each run, and **re-run any measurement taken at a 1-minute load above 2.0**.
- Record whether port 8001 or 8002 is listening. §1.5 explains why a loaded ACE must not share the run.
- Device: MPS fp32 is primary. CPU fp32 is the control and the PASS-degraded floor.

**PASS:**

- Warm RTF ≤ **1.0** on MPS for T1, so a 10 s phrase renders in at most 10 s.
- T3-60's warm RTF is at most 1.5× T1's, so growth is roughly linear.

**PASS-degraded:**

- Warm RTF 1.0–4.0. It ships as a background job with progress, and a 3-minute vocal takes 3–12 minutes.
- Or T3-60 fails (out of memory or a length error) while T3-30 passes. The epic then renders **per phrase**, splitting at rests, with a
  recorded maximum phrase length.
- `max_length: 36000` in the config is a candidate cap. It would be 720 s if it counts 20 ms frames, but its unit is UNVERIFIED. S4 records the length at which rendering actually errors.

**KILL:**

- Warm RTF above 4.0 on **both** MPS and CPU.
- Or T1 itself cannot render.

The thresholds are DECISIONS. A non-musician waiting more than 12 minutes for a 3-minute vocal abandons the feature, and ACE's
own song generation is the comparison they will make.

### 1.5 Peak memory, measured so unified/GPU memory is visible

**First, the lesson stated precisely.** The brief says "the ACE sidecar holds ~75 GB while RSS reports ~1 GB". This machine's own record
**corrected that reading on 2026-08-05** (VERIFIED-2ND, the project memory note `daw-pro-ace-memory-hygiene`). `ps -axo rss` showed 1.1 GB
at teardown while the kill returned ~75 GB (`vm_stat` free pages 1,166,504 → 5,744,768 at 16384 B/page). But *"RSS was not lying — we
were reading the WRONG PROCESS"*: `scripts/ace-step/run.sh` ends in `exec uv run --no-sync acestep-api`, so the pidfile pid is the `uv`
supervisor, and **its Python child holds the memory**. The recorded fix is to **sum `proc_pid_rusage` over the whole process tree**.
The same note records that Activity Monitor's Memory column is `phys_footprint`. It showed the ACE Python process at 75–80 GB.

So this plan fixes **both** failure modes, the wrong pid and the wrong metric, rather than just one.

**Why `phys_footprint` rather than RSS.** RSS counts pages resident in the process's own VM map. `phys_footprint` is the kernel ledger that also charges
the process for compressed and swapped anonymous memory and for **IOKit/Metal allocations made on its behalf**. Those include
GPU-private buffers, which are not mapped as ordinary resident pages. It **excludes** clean file-backed mappings. So a model that memory-maps its
weights can show a small footprint while filling the page cache, which is why instrument 4 below is system-wide. Whether `phys_footprint` sees **MPS-private**
buffers on macOS 26.4 is **UNVERIFIED**, and the positive control below decides it before any model number is quoted.

**Launch shape (the wrong-pid fix).** The model runs in **one** Python process that is the **direct child** of the measuring
tool: `/usr/bin/time -l $SPIKE_ROOT/venv/bin/python harness.py …`. No `uv run`, no `conda run`, and no shell `exec` chain. The harness logs
its own pid. After every run, `ps -axo pid,ppid,rss,command` filtered on the ppid (never `pgrep`) confirms it had **no children**. If it had
children, instrument 2's tree sum is the one that counts.

**Instruments.** All five are sampled for every S4 run, on T1, T3-30 and T3-60:

1. **The kernel's lifetime peak for the model process.** Read the `peak memory footprint` line of `/usr/bin/time -l`. VERIFIED present on this
   Mac 2026-09-24 (`/usr/bin/time -l /usr/bin/true` printed both `maximum resident set size` and `peak memory footprint`). It has no sampling gap,
   and it is primary when the process has no children.
2. **A tree-sum sampler.** A ~40-line stdlib `ctypes` script calls libproc's `proc_pid_rusage(pid, RUSAGE_INFO_V4)` every 0.25 s for the root
   pid **and every descendant** (from `ps -axo pid,ppid`). It sums `ri_phys_footprint` and keeps the maximum, and at exit it reads
   `ri_lifetime_max_phys_footprint`. This implements the recorded fix exactly, and is primary when there are children.
3. **The category breakdown.** One `footprint -p <pid> -j snap.json` snapshot at steady state after load. VERIFIED on this Mac: `footprint`
   supports `-p`, `-j`, `--sample <interval>` and `--wired`. It shows **what kind** of memory it is: malloc, IOKit/IOAccelerator, or mapped files.
4. **System-wide deltas.** These see anything outside the tree.
   - `vm_stat` free pages at 16384 B/page, VERIFIED page size.
   - `ioreg -r -c IOAccelerator` `"In use system memory"`, VERIFIED readable without sudo (§1.2).
   - `memory_pressure`'s level at peak: Normal, Warn or Critical.
   - All three are taken before, at peak and 30 s after exit.
5. **The MPS allocator's own view.** `torch.mps.driver_allocated_memory()` is sampled from a harness thread every 0.25 s during synthesis.
   I know of no MPS peak-allocation counter in torch 2.2 (UNVERIFIED), so it is sampled; if one exists, use it as well.

**Positive control (S4-pc), run before any model number is quoted:**

- **(a)** A harness process allocates and fills an **8 GiB MPS tensor**, synchronizes, and holds it for 15 s. Instruments 1 and 2 must rise by ≥ 7.5
  GiB, instrument 4's `ioreg` value by ≈ 8 GiB, and instrument 5 must read ≥ 8 GiB. RSS is recorded alongside. If RSS stays low while footprint rises, the
  "what RSS misses" claim becomes **measured on this Mac**, not lore. **If `phys_footprint` does not rise, it is blind to MPS memory here.** Instruments
  4 and 5 then become primary, and the report says so.
- **(b) Negative control.** The same 8 GiB as a **CPU** tensor. The footprint rises, `ioreg` stays flat, and instrument 5 reads 0.
- **(c) The wrong-pid demonstration.** Run (a) under `uv run` instead. The `uv` pid's footprint stays small while its child holds 8 GiB. This
  re-proves the ACE lesson cheaply and shows the tree sum catches it.

**Release check (after every run).** Within 30 s of the process exiting, `vm_stat` free memory and `ioreg`'s value must return to within **2 GiB** of their
pre-run baselines. Memory that does not come back was held outside the process: an orphaned child, or a leaked GPU surface. That is escalated.

**Concurrency rule.** S4 runs only when port **8001 is not listening** (`lsof -nP -iTCP:8001 -sTCP:LISTEN`, positive-controlled
by the same command against a port the spike itself holds open). If the user's own app has ACE loaded, the spike **waits or skips** and reports.
It never stops the user's instance.

**PASS / KILL (DECISIONS).** The machine has 128 GiB. ACE alone holds 75–80 GB, and leaving it up has driven macOS to its force-quit dialog
(VERIFIED-2ND, the same note). The thresholds follow from that:

- **PASS:** peak tree-sum `phys_footprint` is at most **16 GiB** on T1 and at most **24 GiB** on T3-60, and the release check passes. At that size it can
  share the machine with ACE (80 + 24 = 104 GiB, leaving room for macOS and the DAW).
- **PASS-degraded:** 16–40 GiB. It can run, but **never alongside ACE**, so the epic registers it with the model-admission layer as mutually
  exclusive with ACE (§5).
- **KILL:** above 40 GiB on T1, `memory_pressure` reaching **Critical** during T1, or a failed release check that repeats on a second run.
- **Always reported:** peak memory against phrase length across T1, T3-30 and T3-60, as GiB per minute of audio, plus whether the growth is super-linear.
  Together with §1.4, that sets the longest phrase per call.

### 1.6 Zero-shot voice-cloning quality with the user's own voice

**Policy.** The user's own recorded voice is the **default** reference, **not a restriction**. The own-voice-only policy was withdrawn on
2026-07-27 (the research doc's §4b correction), and the provenance of any voice the user supplies is theirs. The upstream stock prompts
(`example/audio/en_prompt.mp3` and `zh_prompt.mp3`) are used only as the **stock-voice comparison**: a timbre reference whose audio is never played to the user.

**What a reference is, mechanically** (VERIFIED, §1.1 and §1.3). A reference is a **wav plus a metadata JSON** in the §1.3 schema, and the metadata must align with
the audio (`process(meta, wav_path)` truncates the waveform to the metadata's frames). Upstream's examples are **5.06 s** (`en_prompt.json`) and
**10.37 s** (`zh_prompt.json`) long (VERIFIED by arithmetic, §1.3 A). Upstream builds that metadata with a preprocessing pipeline: lead-vocal
separation, dereverberation, RMVPE, ROSVOT note transcription, and Paraformer/Parakeet-tdt-0.6b-v2 lyric transcription (VERIFIED, README
and `preprocess/README.md`). It needs a **second weights repo**, `Soul-AILab/SoulX-Singer-Preprocess`. `nemo_toolkit==2.6.1` and
`funasr==1.3.0` are in the main `requirements.txt` (VERIFIED). **Whether that stack installs and runs on macOS arm64 is UNVERIFIED, and it is the
likeliest Mac blocker in the whole route (F5).**

**The recording the spike asks the user for.** This is a §6 item, and the spike never goes looking through the user's files.

- **Content.** One sung line, about 5 s, dry (no music behind it), in a quiet room, singing along with a guide the spike provides.
- **Fixture P1 "row your boat"** (traditional, public domain; UNVERIFIED by a fetch). At 100 BPM the notes and beat lengths are: Row C4 1, row C4 1, row C4 0.75, your D4 0.25, boat E4 1,
  gent- E4 0.75, -ly D4 0.25, down E4 0.75, the F4 0.25, stream G4 2. That is 8 beats, or 4.8 s.
- **Why a different line from T1.** A prompt that sings the same words and tune as the target could let the model copy the prompt's delivery, which would
  flatter the cloning score.
- **The clip check before use.**
  - Duration 3–12 s.
  - True peak ≤ -1 dBTP, which rules out clipping.
  - A noise floor, measured in the gaps, at least 30 dB below the vocal RMS.
  - A failed clip gets a re-record request **through the handoff page**; it never interrupts the user.

**Two routes to the reference metadata. H runs first. P is optional and runs only if its install fits §6's approval.**

- **Route H (in-tree plus a known score; nothing new to download beyond the core install).**
  1. Text, phonemes and note types come from the known lyric through the §1.3 E converter.
  2. `note_pitch` is P1's melody, **transposed by the user's actual key**: the median cents offset between the detected f0 and the score, rounded to a
     semitone. The metadata must describe what the user sang, not the guide.
  3. Note boundaries come from the guide's timings plus the single time offset that best lines up the detected f0 contour with the score's step contour
     (cross-correlation). The spike may **hand-correct** one clip once, logging the correction. The epic then owns automating it.
  4. f0 comes from `librosa.pyin` at sr 24000 with hop 480, which matches the model's 20 ms frame (VERIFIED config; `librosa==0.11.0` is already pinned upstream).
     Unvoiced frames are written as `0.0`, the upstream convention.
  5. Cross-check the pitch with the DAW's own `clip.detectPitch` (§1.7). If the two disagree by more than 50 cents on a note, it is flagged.
- **Route P (upstream preprocessing, optional).** Run `preprocess/pipeline.py` on the same clip. Compare its `note_pitch` and note boundaries with Route H's,
  then render T1 with both references at the same seed. If P's references render measurably better (§1.7 score, and word error rate below), the epic needs the
  preprocessing stack. If not, the epic builds reference metadata **in-app** from `clip.detectPitch` and the known lyric, with no ASR and no separation.

**Measurements.** These run on the §3 renders and each one is gated.

1. **Identity: the user's ears.** The §3 page asks one extra question after the pick: *"Does option A sound like you? yes / a bit / no."*
   No agent can answer this, because an agent cannot listen.
2. **Intelligibility.** Run `clip.transcribe` (on-device WhisperKit, `language: "en"`; VERIFIED case label and params in
   `Sources/DAWControl/Commands.swift`) on each render inside the spike's named staging project. Compute word error rate against the typed lyric.
   - Budget for the first call's recorded ~90 s CoreML compile (93.7 s cold versus 1.15 s warm, per the same comment).
   - **Positive control:** transcribe the user's own reference clip, where the words are known. If WER is above 20% there, Whisper cannot read this
     person's singing, and the renders' WER is reported as **instrument-limited** rather than as a failure.
3. **Pitch accuracy under the user's reference.** §1.7's score with the user's reference must stay within 5 points of its score with the stock reference.
   This checks that the voice prompt does not pull the melody.

**PASS (zero-shot own voice is a viable default):**

- The user answers **yes** or **a bit** for A.
- A's word error rate is ≤ 20% (or instrument-limited).
- Measurement 3 holds.

**PASS-degraded:** the user answers **no** for A but picks B, the RVC re-skin. The epic's default then becomes SoulX with a stock reference, followed by RVC into
**the user's trained voice**. That makes the RVC real-model gate (`m10-p-6`, user-dependent) a prerequisite, and zero-shot own voice becomes secondary.

**KILL (Route A):**

- Word error rate above 40% on both A and C (unintelligible whatever the voice, and not instrument-limited).
- Or the user rejects every SoulX option.

### 1.7 Note accuracy: does the output hit the score's notes?

**Why this is a question of its own.** The brief's list does not name it, but it **is** the user's request ("sang/arranges to the note of the lead
melody track"). It is also the axis that separates Route A from Route B: ACE Cover is documented as contour-level, not note-exact
(VERIFIED-2ND, research doc §3). Audibility is not correctness: in this tree, five deliberately **planted** defects each passed an `audible=true`
gate (VERIFIED-2ND, the project's gate-law record).

**Instrument 1: the DAW's own pitch tracker**, `clip.detectPitch`. VERIFIED case label and params in `Sources/DAWControl/Commands.swift`: `clipId`
(required), `fromSeconds?`/`durationSeconds?`, `confidenceThreshold?` (default 0.9) and `silenceFloorDbfs?` (default -75 dBFS). The comment marks the floor
*"UNTUNED against real vocal material"*, so the spike records the values it uses. It wraps the `PitchTracker`/`SwiftF0PitchTracker` seam, which is
**independent of SoulX's own RMVPE**, so the model is not graded by the family of tools it was trained on. It runs on a staging app (port 17695) inside
the spike's named project, with each render imported as an audio clip. It is read-only, with no undo entry and nothing persisted (VERIFIED, same comment).

**Instrument 2, the cross-check: `librosa.pyin`** in the spike venv (a different algorithm). Where the two instruments disagree by more than 20 cents on a note, the
note is flagged, and the disagreement is itself reported.

**The metric (DECISION).**

1. For each scored note, take the median f0 over the **middle 50%** of its window. That skips onset scoops, consonants and the transitions.
2. Convert to cents against the score: `1200 · log2(f_med / (440 · 2^((p − 69)/12)))`.
3. Report three numbers:
   - **hit rate**: notes within ±50 cents, meaning the note reads as the right semitone;
   - **mean |error|** over the hit notes;
   - **voiced coverage**: the fraction of scored note time with a confident pitch. This catches a render that is mostly unvoiced or whispered.
4. Also check the total rendered duration against the score duration, within ±5%.

**Controls. These run first; without them a hit rate proves nothing.**

- **Positive control.** A pure-sine rendering of T1 at the exact score pitches: `render.bounce` of the T1 MIDI clip on a simple sine patch on staging, or a numpy
  synth. It must score **14/14 within ±10 cents** with voiced coverage ≥ 95%.
- **Negative control.** The same sine rendering transposed **+1 semitone** must score **0/14** within ±50 cents, with every note about +100 cents. A metric
  that passes both files cannot fail, and it is not used.

**Settings.** `--control score`, `--pitch_shift 0`, and **`--auto_shift` OFF** for the accuracy runs (F4). A separate run with it **ON** measures
what it actually does. The median offset in cents across notes is expected to be a multiple of 100 if it transposes. That answers F4's
UNVERIFIED semantics.

**Runs.**

- T1 with the stock English reference.
- T1 with the user's reference (feeds §1.6 measurement 3).
- T2, for the three "me" notes plus the rest.
- Route B's ACE Cover output on T1, graded by the **same** instrument.

**PASS:**

- ≥ **12/14** T1 notes hit (at least 85%), with mean |error| ≤ 25 cents and voiced coverage ≥ 80%.
- T2's three "me" notes hit 3/3.

**PASS-degraded:** exactly **11/14**. It is reported as borderline, and the §3 pick decides whether it is good enough.

**KILL (Route A):** at most **10/14** hit with auto-shift off. At that level the model does not follow a score closely enough to be a "sing on my melody"
feature.

**The finding that would flip the recommendation:** if Route B (ACE Cover) **also** passes this bar on T1 and T2. It is already installed and needs no new download,
so the report must lead with that result rather than bury it.

## 2. The install plan

**Full Xcode: not needed** for anything in this spike (Python, the `hf`/`uv` CLIs, and the existing staging app). The epic needs it only if the
sidecar is ever to be embedded in the signed `.app`, which is not proposed (ACE and RVC live under `scripts/`, not in the bundle).

### 2.1 Where it lives (DECISION), and the preflight (S0)

**Two roots.** The code and the heavy runtime are split on purpose:

| Root | Path | Holds | Size |
|---|---|---|---|
| `SPIKE_CODE` | `/Users/dsemenov/Views/daw-pro/scripts/sing-spike/` (**new**, in-repo, untracked until the user says otherwise) | `README.md`, `install.sh`, `harness.py`, `score_from_notes.py`, `rusage_sampler.py`, `gates.sh`, `teardown.sh`, `fixtures/*.json` | **Text only, at most 1 MB.** `install.sh` asserts this with `du -sk` and refuses to run over it |
| `SPIKE_ROOT` | `/Users/dsemenov/DAWPro-spikes/sing-soulx/` (**new**, outside the repo, no spaces in the path) | uv-managed Python, the upstream clone, venvs, weights, every cache, renders, logs, pidfiles | ≈ 6–10 GB core; ≤ 22 GB with every optional leg (§2.2) |

**Why the runtime is outside the repo.**

- `CLAUDE.md` records that `scripts/video/` grew **after** the grep-exclusion rule was written, and the documented grep then hung anyway. A new multi-GB directory under `scripts/` would
  rot that mitigation the same way, silently.
- Outside the repo, teardown is one `rm -rf` of one root, and the disk figure is one `du -sh` (plus the cache diffs in §2.3).
- Nothing lands inside `scripts/ace-step/` or `scripts/rvc/`, or near their venvs, which is the brief's hard rule.

**Preflight (S0).** `install.sh` refuses to continue on any failed item:

1. **Idle machine.** 1-minute `vm.loadavg` < 2.0, and the orchestrator confirms **no other lane is running**. It read 4.1–6.0 while this plan was written,
   because other lanes were working. Measuring under that load breaks §1.4 and §1.5.
2. **Free disk** ≥ 50 GB on the home volume. 662 GiB was free on 2026-09-24 (VERIFIED, `df -h`).
3. **Ports.** Record `lsof -nP -iTCP -sTCP:LISTEN` for 8001, 8002, 8004, 17600 and 17695. **Never connect to 17600.** 8001 must be free for S4 and S7 (§1.5).
4. **Baselines.** Record `vm_stat`, the `ioreg` GPU counters, and `du -sk` of every default cache in §2.3. Record `git -C /Users/dsemenov/Views/daw-pro status --porcelain`.
   S9 reruns this to prove no tracked file changed.
5. **Identity.** Record the tool versions: `uv --version` (0.11.19 on 2026-09-24), `hf version` (huggingface_hub 1.18.0), `ffmpeg -version`, and `sw_vers`.

### 2.2 Pinned versions and the disk budget

Pinned on 2026-09-24/25 (all VERIFIED by fetch). **The spike uses exactly these, or logs every deviation:**

| Item | Pin | Evidence |
|---|---|---|
| Upstream code | `github.com/Soul-AILab/SoulX-Singer` at commit **`81aeb3ae772c70093c3de74dc23c92d983801ae4`** (2026-05-29). The last five commits (2026-03-19 → 05-29) are all "update wechat QR code", so the code has been static since about March. | GitHub commits API |
| SVS weights | HF `Soul-AILab/SoulX-Singer` at revision **`40493ad90286056c7a9095035164434a79daa8c9`** (lastModified 2026-03-13, `apache-2.0`, not gated). **Download only `model.pt` (2,818,092,278 B) and `config.yaml` (579 B).** Skip `model-svc.pt` (2,793,965,154 B): its SVC role is covered by RVC. | HF model-info and tree APIs |
| Preprocess weights (Route P, optional) | HF `Soul-AILab/SoulX-Singer-Preprocess` at revision **`83dc50289d22a81b1e9998f5b9e111aef7c1fdcd`** (`apache-2.0` on the card; see §6 for the licence caveat). Full repo 7,619,543,322 B. **Download only `rmvpe/` (181 MB), `rosvot/` (633 MB) and, if the pipeline insists on ASR, `parakeet-tdt-0.6b-v2/` (2.47 GB), which is ≤ 3.3 GB.** Skip separation and dereverb (the clip is recorded dry) and the Mandarin Paraformer. | HF tree API |
| MLX weights (S-MLX, optional) | HF `mlx-community/SoulX-Singer`, **bf16 (2.6 GB) and 4-bit (774 MB)** only. Record the revision sha on the day; it was not fetched here (UNVERIFIED). | HF card |
| Python | CPython **3.10** (upstream: `conda create -n soulxsinger -y python=3.10`), installed by `uv python install 3.10` into `$SPIKE_ROOT/python`. There is no conda and no python3.10 on this Mac. | README; local probe |
| Python packages | Upstream `requirements.txt` as pinned: `torch==2.2.0`, `torchaudio==2.2.0`, `transformers==4.41.2`, `g2p_en==2.1.0`, `librosa==0.11.0`, `numpy<2.0.0`, `pyloudnorm==0.2.0`, `scipy==1.15.3` and the rest, **minus** `nemo_toolkit==2.6.1`, `funasr==1.3.0`, `gradio==6.3.0` and `wandb==0.24.2` (preprocessing, WebUI and training only; they go in Route P's own venv). | `requirements.txt` |

**Install risks the plan expects to meet first.** None of these are verified; each gets a verbatim log line:

- **`sageattention==1.0.6`** is an attention-kernel package that I believe targets CUDA. Whether it installs or imports on macOS arm64 is UNVERIFIED. If it fails, it is dropped and §1.1's patch 2 applies.
- **`torch==2.2.0` is pinned next to `torchcodec==0.10.0`.** From memory, torchcodec releases track much newer torch, so the pair may not co-install or co-import (UNVERIFIED). The spike first checks whether the SVS path imports `torchcodec` at all. If it does not, `torchcodec` is dropped.
- **MPS op gaps.** torch 2.2.0 is early 2024, and MPS op coverage has grown since. If S2 hits `NotImplementedError` on MPS, **S2-alt** retries with the newest torch that still loads the checkpoint, logged as a deviation.
  Watch for torch ≥ 2.6 defaulting `torch.load(weights_only=True)`, which can refuse a pickled checkpoint. That failure is loud, which is fine.
- **The dependency guard.** After S2's positive control, `sys.modules` must contain **none** of `nemo`, `funasr`, `gradio` or `wandb`. If one appears, the SVS path imports it
  at module level. It is then added back, or its import is guarded under patch rule 3, and the case is recorded.

**Install steps (S1).** Idempotent, each step logged to `$SPIKE_ROOT/logs/install-*.log`, with no stderr suppression:

1. **Environment.** Export the §2.3 environment block, then `mkdir -p $SPIKE_ROOT/{python,src,run,logs,renders,fixtures}`.
2. **Python.** `uv python install 3.10`. `UV_PYTHON_INSTALL_DIR` is set, so it lands in `$SPIKE_ROOT/python`. Record the exact patch version.
3. **Upstream clone, pinned.** In `$SPIKE_ROOT/src/SoulX-Singer`, run `git init`, add the remote,
   `git fetch --depth 1 origin 81aeb3ae772c70093c3de74dc23c92d983801ae4`, then `git checkout FETCH_HEAD`. Assert `git rev-parse HEAD` equals the pin.
4. **Venv.** `uv venv --python 3.10 $SPIKE_ROOT/venv`. First run `uv pip install --dry-run` against the reduced requirements and log the resolution. Then install, and save
   `uv pip freeze` to `logs/freeze-core.txt`. That frozen list **is** the pinned-versions record for the epic.
5. **Download check.** `hf download Soul-AILab/SoulX-Singer model.pt config.yaml --revision 40493ad90286056c7a9095035164434a79daa8c9 --local-dir $SPIKE_ROOT/src/SoulX-Singer/pretrained_models/SoulX-Singer --dry-run`.
   Confirm the byte count, then rerun without `--dry-run`.
6. **Weight check.** Assert that `stat -f %z model.pt` equals **2818092278**, and record the sha256.
7. **Optional legs, only with the user's word (§6).**
   - Route P gets its own `$SPIKE_ROOT/venv-pre` (`preprocess/requirements.txt` plus `nemo_toolkit`/`funasr`) and the `--include`-filtered Preprocess download.
   - S-MLX gets `$SPIKE_ROOT/venv-mlx` per the community README (`mlx safetensors huggingface_hub hf_transfer`).
   - Neither venv is shared with the core venv, so a NeMo install failure cannot break the core.

**Disk budget (DECISION).**

| Scope | Size | Status |
|---|---|---|
| Core (weights) | **2.82 GB** | VERIFIED |
| Core (venv, Python and clone) | about 2–4 GB | UNVERIFIED; the spike measures it |
| **Core ceiling** | **≤ 10 GB** | |
| Route P | ≤ 3.3 GB of weights plus its venv (**≤ 7 GB**) | |
| S-MLX | 3.4 GB of weights plus its venv (**≤ 5 GB**) | |
| **Everything** | **≤ 22 GB** | against 662 GiB free |

The **measured** figure is `du -sh $SPIKE_ROOT` plus the §2.3 cache deltas at S9. Only that number is reported to the user after the spike.

### 2.3 The cache-redirect block (F6: nothing may land in a shared default cache)

Every spike process runs with:

```bash
export SPIKE_ROOT=/Users/dsemenov/DAWPro-spikes/sing-soulx
export UV_PYTHON_INSTALL_DIR=$SPIKE_ROOT/python  UV_CACHE_DIR=$SPIKE_ROOT/cache/uv
export HF_HOME=$SPIKE_ROOT/cache/hf  TORCH_HOME=$SPIKE_ROOT/cache/torch  XDG_CACHE_HOME=$SPIKE_ROOT/cache/xdg
export NLTK_DATA=$SPIKE_ROOT/cache/nltk  MODELSCOPE_CACHE=$SPIKE_ROOT/cache/modelscope  MPLCONFIGDIR=$SPIKE_ROOT/cache/mpl
unset PYTORCH_ENABLE_MPS_FALLBACK   # F9: set only in the explicit second run of §1.2 tell 2
```

Setting variables is not proof that they took, so the block is verified two ways:

- **Cache diff.** S0 and S9 both record `du -sk` of `~/.cache`, `~/.cache/huggingface`, `~/.cache/torch`, `~/.cache/uv`, `~/nltk_data`, `~/.cache/modelscope`
  and `~/Library/Caches/pip`. **Any growth is a leak**, and S9 reports it by path. `g2p_en` is expected to fetch NLTK data (a CMU dictionary and a POS tagger) on first
  use (UNVERIFIED), and `NLTK_DATA` is there to catch that.
- **Positive control for the diff itself.** S0 writes and then deletes a 1 MB file under `~/.cache/`, and the diff must see it.

### 2.4 Teardown: pidfile-exact, after every leg that loaded a model (a standing user rule)

**SoulX processes.**

- `harness.py` writes its own pid to `$SPIKE_ROOT/run/soulx.pid` at start and removes it on clean exit.
- `teardown.sh` runs after **every** leg. It first checks for the pidfile:
  - **Pidfile gone.** Confirm the pid is gone (`ps -p`).
  - **Pidfile still present** (a crash or hang). Confirm three things before acting:
    - `ps -p <pid> -o command=` contains the `harness.py` path;
    - the process holds no LISTEN socket;
    - the child pids come from `ps -axo pid,ppid`.
  - Then `kill` those exact pids, wait, and confirm they are gone.
- Never `pkill`, `pgrep` or `killall`, and never kill a pid the spike did not record.
- Then run §1.5's release check: `vm_stat` and `ioreg` back to within 2 GiB of baseline within 30 s.

**ACE (Route B, S7).**

- **Start only if port 8001 is free.** If it is already listening, it is **not ours**: skip S7 and report, and never stop it.
- Start it through the staging app (port 17695, `ai.sidecarStart`). Record the whole chain that appears on 8001 (`lsof` for the pid, then `ps` for the ppid chain: the `uv run` wrapper and its Python child, per the ACE memory note).
- After the leg, run `ai.sidecarStop` on 17695, then **verify** port 8001 is free with `lsof`. A setter's return is not proof. If it is still up, `kill` the recorded chain pid-exact.
- Verify with `vm_stat` that free memory recovered by roughly the model's size.

**RVC (option B's re-skin).**

- Start it only if port **8002 is free**, and only through the staging app (`vc.sidecarStart`). If 8002 is already listening, it is not ours: build the set without B and say so.
- The memory note records that RVC `exec`s straight into Python, with no `uv` wrapper split (VERIFIED-2ND). Record the pid that holds 8002 anyway.
- After use, run `vc.sidecarStop`, then verify 8002 is free with `lsof`. If it is still up, `kill` the recorded pid exactly.

**The staging app.** Launched by the spike on **17695** with its own pidfile, and killed pidfile-exact at S9. Identify it **by port**, never by path.

**The disk (S9).** Record `du -sh $SPIKE_ROOT`. Delete it only on the user's answer to §6 item 7. Until then the weights stay, so a follow-up does not re-download 2.8 GB.

### 2.5 The epic's port (DECISION, re-checked on the day)

The spike itself needs **no port** (CLI plus harness). The epic's sidecar takes **`127.0.0.1:8004`**, loopback only. The reasons:

- **8001** is ACE and **8002** is RVC. Both are VERIFIED in code: `Sources/AIServices/SidecarManager.swift` and `ACEStepClient.swift` default to `http://127.0.0.1:8001`, and
  `VoiceConversionClient.swift` and `VoiceConversionManager.swift` default to `http://127.0.0.1:8002`.
- **8003** is claimed, tentatively, by the unshipped real-time VC streaming spike (`docs/research/2026-08-10-realtime-vc-spike.md`, the line naming
  `scripts/rvc-stream/server.py` on 127.0.0.1:8003).
- **17600** is the user's app, and **17695** is staging.

Re-check on the day in two ways:

- `grep -rn --exclude-dir=video --exclude-dir=ace-step --exclude-dir=rvc --exclude-dir=node_modules -E '127\.0\.0\.1:8004|:8004([^0-9]|$)' Sources mcp-server/src docs scripts`
  must return nothing. It is positive-controlled by the same command with `8002`, which must return hits.
  Use the portable pattern `-E '127\.0\.0\.1:8004|:8004([^0-9]|$)'`, because `\b` in macOS `grep -E` is not verified here.
  **If the grep runs longer than a minute, stop.** Run `du -sh scripts/*/ | sort -rh` before trusting the exclude list, because `CLAUDE.md` records that this exact
  mitigation has rotted before.
- `lsof -nP -iTCP:8004 -sTCP:LISTEN` must be empty.

The `docs/AI-INTEGRATIONS.md` port table lists only 8001 today (VERIFIED by grep). The epic adds rows for 8002 and 8004.

## 3. The listening set

**The user's rule:** ship 3–4 options that differ on **one axis each**, never a single result. Their pick is the feedback, and their words describe; they do not diagnose.
The set has one **base** option (A). Each other option changes exactly **one** thing from A.

### 3.1 The options (DECISION)

All four sing the **same typed words on the same melody**: T1, then 1 s of silence, then T2 (about 14.2 s), at 100 BPM. The SoulX options use
`--control score`, `--auto_shift` OFF, `--pitch_shift 0`, `n_steps` 32, `cfg` 3, and harness seed **20260924**.

| Option | What it is | The one axis changed from A | How it is made |
|---|---|---|---|
| **A (base)** | The new singing engine, imitating **your** voice | none | SoulX zero-shot, with the user's reference clip plus Route-H metadata (§1.6) |
| **B** | A, then passed through DAW Pro's existing **voice changer** | **re-skin** on | A's wav goes through `vc.convertVocals` on the staging app (RVC sidecar on 8002, started by staging and killed pidfile-exact after). The voice is **the user's own trained voice** if `vc.listVoices` shows one. Otherwise the built-in voice, **said so on the page** |
| **C** | The new singing engine, imitating a **stock singer** | **reference voice** | Same as A, but the reference is upstream's `example/audio/en_prompt.mp3` + `.json`. Only the prompt's timbre is used, and its audio is never played to the user |
| **D** | DAW Pro's **existing song engine** (ACE-Step), asked to sing the same words over the same tune | **engine** | Route B, in three steps (below) |

**How D is made.**

1. `render.bounce` of the fixture MIDI on a plain patch on staging gives the guide audio.
2. An ACE **Cover** job with the typed lyrics and a neutral "a cappella" caption. The **Cover task is not wired in DAW Pro:** `ACEStepClient` builds only `extract`, `lego` and
   `repaint` jobs (VERIFIED by grep, positive-controlled by `repaint`/`lego` matching). So the spike POSTs the job **directly** to its own ACE instance on 127.0.0.1:8001, with
   `task_type: "cover"` and `src_audio_path`. These are the body keys `ACEStepClient` uses for its other jobs; Cover's own extra parameters are UNVERIFIED, so read upstream's API docs on the day.
3. The shipped `extract` (vocals) job isolates the voice.

Then §2.4's ACE teardown runs.

**Disclosed on the page, because the axes cannot be made perfectly clean:**

- **D's voice is ACE's own.** The spike does not try to give ACE the user's voice, so the engine axis carries the voice with it.
- **A and C stop at 12 kHz.** SoulX renders at 24 kHz with `fmax: 12000` (VERIFIED config). B (RVC) and D (ACE) render full-band, so they will sound **brighter**. That is part of those axes, not a normalisation artifact.
- **The fallback set.** If the user has not yet given a reference clip (§6), A and B cannot be made. The set is then C (as the base), C + RVC, and D: three options.
  The own-voice question stays open and is reported as open.

### 3.2 Gates. Every option passes all four, on the **exact bytes that get published**

The published files are 48 kHz, 24-bit WAV (all options resampled to one format), **loudness-matched**. The target is -18 LUFS integrated.
If any option would then exceed -1.0 dBTP, **all** of them are lowered together until the worst one meets it, so they stay matched. Louder options win blind comparisons, which is why they are matched at all.

- **G1: audible.**
  - Integrated loudness within ±0.5 LU of the shared target.
  - RMS above -40 dBFS.
  - **Voiced coverage** ≥ 80% of the scored note time, from §1.7's instrument. This catches a render that is loud but is not singing.
- **G2: true peak** ≤ **-1.0 dBTP**, by **two meters that must agree**:
  - `ffmpeg -hide_banner -i f.wav -af ebur128=peak=true -f null -` (true peak and integrated loudness);
  - a scipy check in the spike venv: 4× oversampled peak via `resample_poly`, plus `pyloudnorm` integrated loudness.
  - Disagreement over 0.5 dB or 0.5 LU fails the gate. A loudness meter does not look up, and a single meter cannot detect its own miscount.
- **G3: physics.** NaN-free (the harness check), and duration within ±5% of the score. §1.7's hit rate is computed and **stored**, but not shown before the pick.
- **G4: invariance.**
  - All four durations lie within ±5% of each other.
  - `clip.transcribe` word error rate is logged for each option, confirming they all sing the same words.

**The gates' own controls** (run once, before any option is gated; a gate that cannot fail is not a gate):

- **G2 control, the "a loudness meter does not look up" case.** A 12 kHz sine at 48 kHz with π/4 phase:
  `ffmpeg -f lavfi -i "aevalsrc='1.3352*sin(2*PI*12000*t+PI/4)':s=48000:d=5" -c:a pcm_f32le tp.wav`.
  Its **samples** peak at -0.5 dBFS while its **true** peak is about **+2.5 dBTP**. G2 must **fail** it; a sample-peak meter would pass it.
- **G1 control: silence.** A 10 s `anullsrc` file must **fail** G1.
- **G1 control: loud but not singing.** Pink noise normalised to -18 LUFS must **fail** G1 on voiced coverage. Audibility is not correctness.

### 3.3 The page (handed to the orchestrator, which publishes it by rewriting the user's one listening page in place)

- **Options.** Four players, **in a randomised order** (the mapping is logged). Each has one plain-language line saying what differs, taken from §3.1's "What it is" column.
  There are no metrics above the fold.
- **Questions.**
  1. *"Which one would you want as the vocal on your song?"* The answers are the four options, or **"none of them"**.
  2. *"Does the option that imitates your voice sound like you?"* yes / a bit / no. This is §1.6's identity measure.
  3. Optional free text: *"Anything that sounds wrong? Describe it in your own words."*
- **Collapsed "details" section below the questions.** Each option's note hit rate, word error rate, loudness and true peak, and the disclosures from §3.1.
- **The recording.** The user's own reference clip is **not** published anywhere except this private page, and only if they ask to hear it back.

## 4. The pipeline sketch and the existing seams

**Citation note.** Other lanes were editing `Sources/DAWControl/Commands.swift` and `mcp-server/src/server.ts` **while this was written**. Line numbers
for the same case label moved about 120 lines, and for the same MCP tool about 70 lines, between two greps. So those two files are cited by **case label / tool name**
(re-anchor with `grep -n 'case "<verb>":'`). Every other `file:line` was read on 2026-09-24 or 2026-09-25 and is VERIFIED as of that read.

### 4.1 The stages

```text
lead MIDI clip (MIDINote[])  +  typed lyric line
   │ ① read notes, beats → seconds (TempoMap)                                  DAWCore (exists)
   │ ② words → phones (g2p_en, ARPAbet)                                        sidecar (new endpoint)
   │ ③ words → notes assignment (+ melisma continuation, warnings)             DAWCore (new, pure)
   │ ④ SoulX target metadata (§1.3 E) + voice reference                        sidecar (new)
   │ ⑤ score-conditioned synthesis → 24 kHz wav                                sidecar on 127.0.0.1:8004 (new)
   │ ⑥ optional RVC re-skin                                                    vc.convertVocals (exists)
   │ ⑦ import as an audio track/take at the lead clip's start beat             ProjectStore (exists)
```

| Stage | Existing seam (VERIFIED) | What is new |
|---|---|---|
| ① notes | `MIDINote` at `Sources/DAWCore/Model.swift:137`: `pitch` (:140), `velocity` (:142), `startBeat` (:144), `lengthBeats` (:146), and `MIDINote.canonicallyOrdered` (:173). Beats to seconds: `TempoMap.seconds(fromBeatZeroTo:)` at `Sources/DAWCore/TempoMap.swift:181` and `seconds(from:to:)` at :190 | A **monophony rule** for the lead line: overlapping notes must be resolved before scoring, the earlier note truncated. The spike's fixtures are monophonic, so the epic decides this |
| ② phones | none in Swift, and none should be: G2P is data-heavy Python (`g2p_en==2.1.0` is already a SoulX pin) | A sidecar endpoint returning per-word ARPAbet and syllable count (the vowels carrying stress digits) |
| ③ assignment | none. The only lyric field in DAWCore is `ClipFix.lyrics` (`Sources/DAWCore/ClipFix.swift:24`), which belongs to ACE repaint, not to MIDI clips | A pure **`LyricNoteAssigner`** in DAWCore, headless-testable. It takes words with syllable counts plus notes, and returns word spans over notes plus warnings. Default rule (the research doc §4a, adapted to SoulX's **word-level** tokens, §1.3 B): each word takes as many notes as it has syllables, while notes remain; spare notes become continuations (type 3) of the word they follow; **more words than notes is never guessed**, and is returned as a warning the UI or agent must resolve |
| ④ metadata | none | The sidecar builds the §1.3 E JSON. **SoulX's schema never crosses the wire**: the facade takes notes-in-seconds plus word spans. This is the RVC research's facade rule (`docs/research/2026-07-11-vocals-voice-conversion.md:147`, VERIFIED) |
| ⑤ synthesis | The async submit/poll shape of `ACEStepClient` (`Sources/AIServices/ACEStepClient.swift`, baseURL default at :730). The loopback-client pattern of `VoiceConversionClient` (`Sources/AIServices/VoiceConversionClient.swift`: protocol `VoiceConverting` :42, `health()` :103, baseURL default `http://127.0.0.1:8002` at :396) | `SingingSynthesisClient` (actor) behind a new **`SingingSynthesizing`** protocol, a sibling of `VoiceConverting`. A sidecar manager on 8004 in the `SidecarManager` pattern (`Sources/AIServices/SidecarManager.swift`, baseURL :668). Registration with the model-admission layer: `ModelRegistry` / `ModelDescriptor` / `HoldRequirement` (`Sources/AIServices/ModelRegistry.swift:223`, :105, :44), with `HoldRequirement` fed by §1.5's **measured** peak |
| ⑥ re-skin | `VoiceConverting.convert(_:)` (`VoiceConversionClient.swift:189`) with `VoiceConvertRequest(inputPath:voiceId:pitchSemitones:)` (:496/:501). Wire verb `vc.convertVocals` (case label in `Commands.swift`); MCP tool `vc_convert_vocals`; bridge tier `VOICE_CONVERT_TIMEOUT_MS = 330000` (`mcp-server/src/bridge.ts:47`) | Nothing. It is fed the ⑤ wav path. Whether RVC accepts a 24 kHz input without a resample step is UNVERIFIED, and **S8 exercises it** |
| ⑦ import | `ProjectStore.importConvertedVoice(fileURL:trackName:atBeat:)` (`Sources/DAWCore/ProjectStore+VoiceConversion.swift:43`) imports a local file as a new track and clip at a beat. `ProjectStore.importGeneration(jobID:trackName:atBeat:setProjectTempo:)` (`ProjectStore+Generation.swift:27`) is the ACE-job variant. The take verbs `take.group` / `take.setComp` / `take.select` (case labels) let several renders sit as takes the user comps | Nothing new in the model. **Alignment:** the render starts with §1.3 E's 0.24 s leading `<SP>`, which also gives the singer room for consonants that anticipate the beat. So `atBeat` must be the beat at **(the first note's start time − 0.24 s)**, computed through `TempoMap`. If that falls before beat 0, trim the leading silence from the file instead. §1.7's per-note F0 on the imported clip is the check that note 1 lands on its beat. **S8 imports a 24 kHz render into the staging project**, which tests this seam for real |

### 4.2 The command surface (one surface; the MCP server never talks to a sidecar)

- **The existing rule, VERIFIED.** The MCP `vc_*` tools are thin `bridge.send("vc.…")` passthroughs (`server.ts`, the
  `vc_sidecar_status` / `vc_sidecar_start` / `vc_sidecar_stop` / `vc_convert_vocals` registrations). The app owns the sidecar. The new verbs follow it exactly:
  - a `sing.` namespace in `Commands.swift`, **additive only**;
  - matching MCP tools in `server.ts` as `bridge.send` passthroughs;
  - a new timeout tier in `bridge.ts`, beside `LONG_RUNNING_TIMEOUT_MS` (:25), `VOICE_CONVERT_TIMEOUT_MS` (:47), `CLIP_TRANSCRIBE_TIMEOUT_MS` (:84) and `CLIP_DETECT_PITCH_TIMEOUT_MS` (:103).

  The SwiftUI panel calls the same commands, through ProjectStore.
- **`mcp-server/src/ai.ts` is not a sidecar seam** (VERIFIED: it holds only direct Anthropic, OpenAI, Suno and image clients). Its role here is upstream of
  the pipeline. `generateLyrics` (`ai.ts:206`) lets an agent write the words, then call the new `sing_*` tool. **No change to `ai.ts` is needed.**
- **The research doc's tool sketch** (`sing_lyrics_on_lead` + `get_sing_job`) is kept as the MCP shape. §5 names the wire verbs.

### 4.3 Invariants this pipeline keeps

- **The render thread is untouched.** Synthesis is offline, in a separate process. Import goes through `ProjectStore` on `@MainActor`, and the playback
  graph sees an ordinary audio clip. No new real-time code, so there is no allocation, locking or blocking risk to flag.
- **DAWCore stays headless and dependency-free.** Only the pure `LyricNoteAssigner` and model fields land there. G2P and synthesis stay in the sidecar, and
  the client lives in `AIServices`. No Python runs in-process.
- **DAWEngine is not involved** beyond normal clip playback. No CoreAudio or AVAudioEngine surface changes.

## 5. The downstream epic, outlined but not sized

**Not sized, on purpose.** The research doc says to size only after the spike reports (§6 takeaway 3 there). Every item below is **gated on the spike's
PASS**, and the spike's PASS-degraded outcomes **change the item list**. The mapping is at the end of this section. The shape mirrors the RVC epic
(`docs/research/2026-07-11-vocals-voice-conversion.md` §4c: research → install → client → wire+MCP → UI → real-model gate, VERIFIED at :155-166).
Each item ships the project's triple: a control command, an MCP tool, and a test.

| Id (proposed) | Item | Route (per `CLAUDE.md` routing) | Depends on |
|---|---|---|---|
| p2-sing-a | **This spike, executed.** The hands-on run of this plan, which ends with the §3 page and a measured report. | `audio-dsp-engineer` executes; `daw-architect` reviews | the user's word on §6 |
| p2-sing-b | **Sidecar install and run scripts.** An idempotent `install.sh`, a `run.sh`, and a FastAPI **facade** `server.py` bound to 127.0.0.1:8004 only. They mirror `scripts/rvc/`'s shape (`install.sh`, `run.sh`, `server.py`, VERIFIED by a top-level `ls`). Endpoints: `GET /health`, `POST /v1/sing/phonemize`, `POST /v1/sing/jobs`, `GET /v1/sing/jobs/{id}`, `POST /v1/sing/reference`. **Runtime location:** outside the repo (for example `~/Library/Application Support/DAWPro/sidecars/soulx-singer/`; that path contains a space, so every script quotes it), because a new multi-GB directory under `scripts/` rots `CLAUDE.md`'s grep-exclusion rule, and changing `CLAUDE.md` needs the user's word. The pins come from the spike's `freeze-core.txt` and the §1.1 patch diff | `audio-dsp-engineer` | a |
| p2-sing-c | **Swift client and lifecycle.** `SingingSynthesisClient` behind a new `SingingSynthesizing` protocol in `AIServices`, plus a sidecar manager in the `SidecarManager` / `VoiceConversionManager` pattern (health probe, lazy spawn, idle teardown, pidfile, tree-aware stop). Also a `ModelDescriptor` + `HoldRequirement` entry in `ModelRegistry`, sized from §1.5's **measured** peak, and marked exclusive with ACE if §1.5 was PASS-degraded. Wire: `sing.sidecarStatus/Start/Stop`. MCP: `sing_sidecar_status/start/stop` | `mcp-integration-engineer`; the stop/lifecycle design is reviewed by `daw-architect` (m23-bb precedent: a stop verb that "succeeded" while the process ran on) | b |
| p2-sing-d | **Domain.** A pure `LyricNoteAssigner` in DAWCore (§4.1 ③) and the lyric line plus word spans as an **optional** field on the MIDI clip. It must be additive, and it must decode from existing projects to `nil`: a render byte-gate cannot see a `Codable` decode default, so this needs its own decode test. Headless Swift Testing suites cover one syllable per note, melisma, more words than notes (a warning), rests, and a tempo change mid-phrase | `swift-app-engineer` | a (the tokens and melisma encoding come from §1.3) |
| p2-sing-e | **Wire and MCP.** Five verbs:<br>• `sing.previewAssignment` (no synthesis: returns word spans and warnings, so an agent or the UI can fix the line before spending compute);<br>• `sing.lyricsOnClip` (submit; returns a job id);<br>• `sing.status` (poll);<br>• `sing.import` (to a track or take via `importConvertedVoice`, optionally through `vc.convertVocals` first);<br>• `sing.setVoiceReference` (records or imports the user's clip and builds its metadata, Route H in-app).<br>MCP tools `sing_lyrics_on_lead` / `get_sing_job` (the research doc's sketch) and so on, as `bridge.send` passthroughs, with their own `bridge.ts` timeout tier | `mcp-integration-engineer` | c, d |
| p2-sing-f | **UI.** A "Sing lyrics…" action on the MIDI clip menu. A sheet with the line, **word chips glowing over their notes**, and melisma shown as a stretched chip, so mismatches are visible before rendering. A voice picker: *your voice* / *stock singer* / *your trained RVC voice*. Progress, then the result as a violet AI take. A one-time "record your voice" flow (sing along with P1) | `swift-app-engineer` + `ui-design-engineer` | e |
| p2-sing-g | **Real-model gate.** One real reference, one real line on a real project's lead melody, and §1.7's hit-rate bar on the **imported** clip. §3's G1–G4 run on the bounced track, then `/dogfood` looks at the UI. This follows the (v-c)/(iii-c-real) precedent: no box above the gate is trusted until it passes | `qa-test-engineer` | f |
| p2-sing-h | **Docs.** Add `docs/AI-INTEGRATIONS.md` port rows for **8002** (missing today; VERIFIED, the table lists only 8001) and **8004**. Add a `docs/ARCHITECTURE.md` section and a "Key future decisions" entry, a ROADMAP item (research takeaway 3), and a CHANGELOG entry | `docs-scribe` | g |

**How the spike's outcomes reshape the epic (decided now, so nobody re-decides later):**

| Spike outcome | Epic change |
|---|---|
| §1.1 PASS-degraded (CPU only) | p2-sing-b pins a newer torch (S2-alt) or carries the op patch; the UI must say "slow on this Mac" |
| §1.2 S-MLX adopted | p2-sing-b downloads the quantized weights instead of `model.pt`; the §6 download figure shrinks |
| §1.4 PASS-degraded | `sing.lyricsOnClip` renders **per phrase** (split at rests, capped at the measured maximum length) and reports progress per phrase |
| §1.5 PASS-degraded | `HoldRequirement` is marked exclusive with ACE; the UI explains "close the song generator first" |
| §1.6 PASS-degraded | The default voice path becomes stock reference → RVC into the user's trained voice. **`m10-p-6` (the RVC real-model gate, user-dependent) becomes a prerequisite**, and zero-shot own voice becomes secondary |
| §1.6 Route P needed | The preprocessing stack (≤ 3.3 GB of extra weights, NeMo/funasr) joins p2-sing-b, and **its licence review becomes an epic item** (§6 item 3) |
| §1.7 **Route B also passes** | Stop and re-plan. ACE Cover is already installed, so the epic may shrink to "wire Cover + extract" |
| Any KILL | The epic is not opened. Route C (§6) stays the user's paid alternative, and the finding is recorded in the research README |

## 6. What needs the user's word before the spike runs

Plain-language list, for the user's handoff page. **Nothing in §2's install step (S1) or later starts until the user has answered 1–4.** Items 5–7
are choices with safe defaults.

1. **Download size.**
   - The singing model is **2.8 GB** (measured from its download page).
   - The software it needs adds **roughly 2–4 GB** (an estimate; we'll measure it).
   - Plan on **about 6–7 GB, at most 10 GB**. Your Mac has about 660 GB free.
   - Everything goes in **one new folder outside the project**, `/Users/dsemenov/DAWPro-spikes/sing-soulx/`, so deleting it later is one step.
2. **Memory, and running while you're away.**
   - Nobody has measured how much memory this model uses on a Mac. **Measuring it is part of the test.**
   - The test **stops itself if the model goes over 40 GB**, about a third of your Mac's 128 GB.
   - It runs **while you're away**, because timing and memory readings need a quiet computer.
   - It **never** runs next to the song generator (ACE, which holds about 75 GB).
   - Every model is **shut down straight after each test**, the rule you set for ACE.
   - Your open DAW Pro session is **never touched**. The test uses its own separate copy of the app.
3. **Licence note.**
   - The singing engine's code and model are **Apache-2.0**, the same free licence as the song generator. Using the results in your songs, including commercially, is allowed.
   - Songs made with **your own voice** as the example raise no licence question. **Other voices are your call** (you lifted the own-voice-only rule on 2026-07-27).
   - **One caveat, and it only matters for an optional extra (item 6).** The "voice-reading tools" pack says Apache-2.0 on its page, but it bundles other companies' models
     (NVIDIA's speech recogniser and community vocal-separation models) whose own licences we haven't checked. That doesn't matter for a private test. We would check it before ever shipping it.
4. **The paid alternative (Route C), so you can compare.** **Synthesizer V Studio 2 Pro:**
   - **$99** one-time for the app, plus **$79 per voice**, or **$149** for the app with one voice. No subscription. (These are the vendor's own prices, checked 2026-09-25.)
   - It runs on your Mac without the internet, has strong English voices, and commercial use is included.
   - **But an AI agent can't type the lyrics in for you. You'd do that by hand.**
   - We are **not** testing it. It's listed so you know the option exists, and buying it is entirely your choice.
5. **A 5-second recording of you singing** (recommended, not required).
   - What we'd ask: sing one short line, *"Row, row, row your boat, gently down the stream"*, along with a little tune we'll send you. Somewhere quiet, with no music playing.
   - Why: this is how we find out whether the new engine can **sound like you**.
   - Without it, we test with a stock singer only, and "does it sound like you?" stays unanswered.
6. **Optional extras.** Each defaults to **no**:
   - **(a) The "voice-reading tools"** (up to 3.3 GB more). They help the engine understand your recording better, and they are only needed if the simple way (§1.6 Route H) doesn't work well.
   - **(b) A smaller, Apple-optimised copy of the model** (3.4 GB more). It tests whether a smaller download works as well.
7. **After the test: keep or delete the downloaded files?**
   - The default is **keep until you say**, so a follow-up doesn't re-download 2.8 GB.
   - You'll see the exact size on disk in the test report.

When the test is done, you'll get **one listening page with four versions of the same sung line**. Pick the one you'd want on your song, or "none". Your pick is the feedback.

## 7. Verification ledger

**The caveat on every upstream quote.** Each one passed through a summarising web-fetch tool, and that tool **miscounted tokens twice** (§1.3). S3 step 1 re-reads the raw
files and diffs them against this document before anything is built on it.

### 7.1 VERIFIED first-hand (fetched or read by daw-architect, 2026-09-24/25)

| # | Claim | Source |
|---|---|---|
| V1 | The licence is Apache-2.0 ("We use the Apache 2.0 license."). Python 3.10 through conda. `hf download` commands for `SoulX-Singer` and `SoulX-Singer-Preprocess`. The modes "score-conditioned (MIDI notes)" and "melody-conditioned (F0 contour)". SVS relies on preprocessing metadata. No device requirement is stated. The latest news item is 2026-03-16 | https://github.com/Soul-AILab/SoulX-Singer |
| V2 | `infer.sh` hardcodes `--device cuda` and `--fp16`, sets `control=score` but never passes it, and passes `--auto_shift --pitch_shift 0` | https://raw.githubusercontent.com/Soul-AILab/SoulX-Singer/main/example/infer.sh |
| V3 | The CLI argparse, all 12 arguments. `--control` defaults to `"melody"`. There is no `--seed`, `--n_steps` or `--cfg`. fp16 applies only when the device starts with `cuda`. The output is `generated.wav` at 24000 Hz | https://raw.githubusercontent.com/Soul-AILab/SoulX-Singer/main/cli/inference.py |
| V4 | The config: `n_steps: 32`, `cfg: 3`, `hop_size: 480`, `sample_rate: 24000`, `max_length: 36000`, `fmax: 12000`, `num_mels: 128`, and a flow-matching transformer (hidden 1024, 22 layers, 16 heads) | https://raw.githubusercontent.com/Soul-AILab/SoulX-Singer/main/soulxsinger/config/soulxsinger.yaml |
| V5 | `DataProcessor` signatures. English is detected with `[:3] == "en_"` and split on `-`. The `process()` body, where `f0` is optional (`meta.get("f0", "")` → `None`) | https://raw.githubusercontent.com/Soul-AILab/SoulX-Singer/main/soulxsinger/utils/data_processor.py |
| V6 | The English metadata schema. The keys are `index`, `language`, `time`, `duration`, `text`, `phoneme`, `note_pitch`, `note_type` and `f0`. The per-note lists have 14 entries each. Tokens are whole words (`en_` + ARPAbet joined with `-`). Durations sum to 5.06 s, matching `time` [5220, 10280] | https://raw.githubusercontent.com/Soul-AILab/SoulX-Singer/main/example/audio/en_prompt.json |
| V7 | The Mandarin examples. `zh_prompt.json` has 23 aligned entries whose durations sum to 10.36 s against a 10.367 s span. `music.json` shows note 64 at f0 ≈ 330 Hz | `…/example/audio/zh_prompt.json`, `…/example/audio/music.json` (same raw base URL) |
| V8 | The phone set: `en_`-prefixed ARPAbet with stress digits, plus `<PAD> <SP> <AP> <UNK> <BOW> <EOW> <BOS> <EOS> <MASK> <SEP>` | `…/soulxsinger/utils/phoneme/phone_set.json` |
| V9 | `requirements.txt` pins, including `torch==2.2.0`, `torchcodec==0.10.0`, `sageattention==1.0.6`, `nemo_toolkit==2.6.1`, `funasr==1.3.0`, `g2p_en==2.1.0`, `librosa==0.11.0`, `numpy<2.0.0`, `transformers==4.41.2` | https://raw.githubusercontent.com/Soul-AILab/SoulX-Singer/main/requirements.txt |
| V10 | The repo file list and sizes: English and Mandarin examples, `cli/inference.py`, `preprocess/tools/{g2p,midi_parser,lyric_transcription}.py`, and no `example/metadata/` directory in the listing | https://api.github.com/repos/Soul-AILab/SoulX-Singer/git/trees/main?recursive=1 |
| V11 | HEAD is `81aeb3ae772c70093c3de74dc23c92d983801ae4` (2026-05-29). The last five commits are all QR-code updates | https://api.github.com/repos/Soul-AILab/SoulX-Singer/commits?per_page=5 |
| V12 | HF weights: revision `40493ad90286056c7a9095035164434a79daa8c9`, `apache-2.0`, not gated. `model.pt` is 2,818,092,278 B and `model-svc.pt` 2,793,965,154 B; the repo totals 5.62 GB | https://huggingface.co/api/models/Soul-AILab/SoulX-Singer and `/tree/main?recursive=true` |
| V13 | Preprocess weights: revision `83dc50289d22a81b1e9998f5b9e111aef7c1fdcd`, `apache-2.0` card, 7,619,543,322 B in total. By folder: Parakeet 2.47 GB, the karaoke roformer 1.72 GB, Paraformer 1.70 GB, dereverb 0.91 GB, ROSVOT 0.63 GB, RMVPE 0.18 GB | https://huggingface.co/api/models/Soul-AILab/SoulX-Singer-Preprocess and `/tree/main?recursive=true` |
| V14 | The MLX conversion is "not a pure end-to-end MLX audio runtime yet", and generation uses the official PyTorch structure. Its variants are 774M / 1.4G / 2.6G / 5.6G, and its licence follows upstream Apache-2.0 | https://huggingface.co/mlx-community/SoulX-Singer |
| V15 | The community bridge: "not yet a pure end-to-end MLX runtime". Its documented command sets `PYTORCH_ENABLE_MPS_FALLBACK=1` with `--device mps --n_steps 1 --cfg 1`. It publishes no Apple-Silicon benchmarks | https://github.com/ailuntx/SoulX-Singer-MLX |
| V16 | Synthesizer V Studio 2 Pro: $99 one-time, $79 per voice, $149 for the app plus one voice, no subscription. It runs locally on Apple Silicon (M1+) and includes commercial use | https://dreamtonics.com/synthesizerv/ (2026-09-25) |
| V17 | This Mac: M5 Max, 128 GiB, macOS 26.4 (25E246), 662 GiB free. `uv` 0.11.19; `hf` (huggingface_hub 1.18.0). No conda and no python3.10. ffmpeg is present | local `sysctl`, `sw_vers`, `df`, `command -v` |
| V18 | The measurement tools on this Mac. `/usr/bin/time -l` prints `peak memory footprint`. `footprint` supports `-p/-j/--sample/--wired`. `ioreg` IOAccelerator (`AGXAcceleratorG17X`) exposes `Device Utilization %` and `In use system memory` without sudo. The `vm_stat` page is 16384 B, and `vm.loadavg` works | local probes |
| V19 | `hf download` supports `--revision/--include/--exclude/--local-dir/--dry-run`. `uv` honours `UV_PYTHON_INSTALL_DIR` and `UV_CACHE_DIR` | local `--help` |
| V20 | Ports in code: 8001 (`SidecarManager.swift:668`, `ACEStepClient.swift:730`) and 8002 (`VoiceConversionClient.swift:396`, `VoiceConversionManager.swift:722`). 8003 is tentatively claimed (`docs/research/2026-08-10-realtime-vc-spike.md:675`). `docs/AI-INTEGRATIONS.md` lists only 8001 | repo greps |
| V21 | The Swift seams listed in §4.1: `MIDINote` (`Model.swift:137-173`), `TempoMap.swift:181/190`, `ClipFix.swift:24` (the only lyric field), `ProjectStore+Generation.swift:27`, `ProjectStore+VoiceConversion.swift:43`, `VoiceConversionClient.swift:42/103/189/496/501`, `ModelRegistry.swift:8/44/105/182/223` | repo reads |
| V22 | `ACEStepClient` wires `extract`, `lego` and `repaint`, but **not** Cover (a grep positive-controlled by `repaint`/`lego`) | `Sources/AIServices/ACEStepClient.swift:218/227/244-266/304-321` |
| V23 | The wire verbs `vc.convertVocals`, `clip.detectPitch` (default confidence 0.9, silence floor -75 dBFS, SwiftF0 seam), `clip.transcribe` (WhisperKit, cold ≈ 93.7 s), `audio.profileFile`, `render.bounce`, `render.measureLoudness`, `take.*`, `ai.generateSong`, `ai.importGeneration` and `ai.repaintAudio`. Cited by case label, because lines move under concurrent edits | `Sources/DAWControl/Commands.swift` |
| V24 | MCP: the `vc_*` tools are `bridge.send` passthroughs, and their tool names are as listed in §4.2. The `bridge.ts` timeout tiers are at :21/:25/:47/:84/:103. `ai.ts` holds only direct provider clients, with `generateLyrics` at :206 | `mcp-server/src/{server,bridge,ai}.ts` |
| V25 | The RVC epic shape is research → install → client → wire+MCP → UI → real gate. The facade rule is at :147 and `(vi-a)` at :159 | `docs/research/2026-07-11-vocals-voice-conversion.md:155-166` |
| V26 | Research README takeaway 1 was **already applied** in commit `109b483` (lines 16-19) | `git log -- docs/research/README.md` |

### 7.2 VERIFIED-2ND (from a source I did not re-derive)

- The ACE memory lesson, from the project memory note `daw-pro-ace-memory-hygiene` (2026-08-05). RSS was read on the wrong pid: `run.sh` execs into `uv`, and the Python child holds the memory. Activity Monitor shows `phys_footprint` (75–80 GB), and the `vm_stat` free-page delta was measured. The fix is a process-tree sum.
- From the research doc: `DiffSingerMiniEngine` is AGPL-3.0 and archived; ACE Cover is contour-level, not note-exact; and the VocalNet short-reference complaint.

### 7.3 Inferences from verified data (labelled as inference wherever used)

- **`note_type` semantics.** 1 = rest, 2 = a new word starts, 3 = continuation (melisma). All three files agree, but it is not yet read in code.
- **The MLX card's sizes** most likely cover SVS and SVC together: fp32 5.6 GB ≈ 2.82 + 2.79 GB.
- **`f0` runs at the mel frame rate** of 20 ms, from `process()`'s truncation logic.
- **The MLX repo setting `PYTORCH_ENABLE_MPS_FALLBACK=1`** suggests at least one op is not implemented on MPS.

### 7.4 UNVERIFIED (the spike measures or checks each one)

- **Does it run.**
  - MPS viability and op coverage under torch 2.2.0.
  - Whether `sageattention==1.0.6` installs or imports on macOS arm64.
  - Whether `torch==2.2.0` and `torchcodec==0.10.0` co-install (my pairing concern is from memory).
  - Whether `nemo_toolkit`/`funasr` install on macOS arm64.
  - Whether the SVS path imports `nemo`, `funasr`, `gradio` or `wandb`.
- **The schema's behaviour.**
  - Whether score mode actually runs with no `f0`.
  - What `--auto_shift` and `--pitch_shift` do.
  - The unit of `max_length`.
  - `note_type` semantics in code.
  - The exact `g2p_en` tokens for the fixtures.
- **Measurement.**
  - Whether `phys_footprint` sees MPS-private buffers on macOS 26.4.
  - Warm RTF, cold start, and peak memory. **None has been measured anywhere for this model on Apple Silicon.**
- **Quality.** The zero-shot cloning quality. No independent listening test exists anywhere.
- **Size.** The venv's size (the 2–4 GB estimate).
- **The MLX leg.**
  - The MLX conversion's revision sha.
  - Whether the bridge dequantizes 4-bit weights at run time (the fetch tool's paraphrase).
- **Hidden downloads.** Whether `g2p_en` fetches NLTK data on first use.
- **Licences.** The third-party licences inside the Preprocess bundle: Parakeet, the roformers, ROSVOT and Paraformer.
- **The harness and the schema's plumbing.**
  - Whether `cli/inference.py`'s model construction and inference are importable functions. The harness contract assumes so; §1.1 gives the verbatim-copy fallback.
  - The role of the target's `time` field. The CLI reads `time[0]` and `time[1]`; the converter writes `[0, total_ms]`, which should be safe but is untested.
- **The other engines and seams.**
  - ACE Cover's exact request parameters.
  - Whether RVC and `importConvertedVoice` accept a 24 kHz file.
- **Loose ends.**
  - The public-domain status of the T1 and P1 texts (common knowledge, not fetched).
  - The one anomalous `zh_prompt.json` row (`<SP>` with pitch 67).
  - `\b` support in macOS `grep -E`. The plan avoids it.
