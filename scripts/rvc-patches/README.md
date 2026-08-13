# rvc-patches — our fixes to the vendored MLX RVC fork

Two independent defects make the MLX voice-conversion path produce wrong audio. Both are
corrected here, **outside** `scripts/rvc/`, which is a read-only fence (user ruling: work
on copies, never write inside it). Nothing in this directory modifies the vendored tree.

## Why this directory exists at all

The vendored fork lives at `scripts/rvc/runtime/src/` and is not ours to edit. The fixes
are two whole modules copied from it and corrected; `shadow.py` binds them into
`sys.modules` under their real dotted names before the fork imports them.

`generators.patch` and `synthesizers.patch` hold the exact diff against the vendored
originals, so drift is detectable — see *Checking for drift* below.

## Bug 1 — `conv_transpose1d` is broken in MLX itself (not the fork)

`mlx 0.30.1`'s Metal `conv_transpose1d` **silently leaves a large fraction of its output
at the layer bias when the output is long.** Measured on the `dec.ups` geometry
(64→32, K=4, S=2, P=1):

| `L_out` | result |
|---|---|
| 32 768 | exact, corr 1.000000 |
| 32 770 | **wrong**, max diff 1.64 |
| 400 000 | exact again |
| 1 844 000 | **49.8 % of samples wrong**, corr 0.708560 |

The boundary is 2^15 output samples and **it is not monotone** — very large outputs are
correct again, so MLX evidently selects a different kernel there. A "chunk only above N"
guard would therefore be unsafe. Plain `Conv1d` is unaffected at identical sizes; the CPU
stream is exact but 100–500× slower.

**Fix:** `conv_transpose1d_chunked()` splits each dispatch so no single call emits more
than 16 384 output samples. Exact (corr 1.000000, max diff ≤ 2.3e-3 = fp32 rounding),
costs 36–94 ms.

This is an upstream MLX bug and it endangers **any** MLX audio model using
`conv_transpose1d` on long signals, not just RVC.

> ### ⭐ FIXED UPSTREAM IN MLX 0.31.2 — measured 2026-08-13, do not report it
>
> Re-ran the exact matrix above against three MLX versions (GPU vs MLX's own CPU
> stream as ground truth, with a positive control proving the probe could see a
> difference, and the version printed per run after an earlier attempt silently
> fell through to the venv's copy and "tested" 0.30.1 three times):
>
> | MLX | `L_out` 32 770 | `L_out` 1 844 000 |
> |---|---|---|
> | 0.30.1 | max diff **3.46** | max diff **7.08** |
> | 0.31.2 | 0.0049 | 0.0053 |
> | 0.32.0 | 0.0049 | 0.0053 |
>
> 0.0049–0.0053 is the same magnitude as the sizes that were always exact — i.e.
> ordinary fp32 GPU/CPU drift. **The defect is gone from 0.31.2 onward.**
>
> **So `conv_transpose1d_chunked` is a workaround for a pinned-version problem, not a
> permanent one.** It stays necessary only while `scripts/rvc/install.sh` produces an
> environment on MLX 0.30.1. Bumping MLX would let us delete it and recover the
> 36–94 ms — but `install.sh` is inside the read-only fence, so that is the user's
> call, and the fork's own version pin would need testing first.
>
> ⚠️ Bug 2 below (the zeroed flow-sampling noise) is the FORK's own defect and is
> **not** affected by any MLX version. It still needs our patch.

> The fork's README advertises "0.986 spectrogram correlation — perceptually identical to
> PyTorch". That claim is **length-dependent, not false**: they measured on 13.5 s of
> audio, below the failure boundary. Our 46 s clip pushes `L_out` to 1.84 M.

## Bug 2 — the fork zeroes the flow sampling noise

| | |
|---|---|
| PyTorch reference `rvc/lib/algorithm/synthesizers.py:228` | `z_p = (m_p + exp(logs_p)·randn · **0.66666**) · x_mask` |
| MLX fork `rvc_mlx/lib/mlx/synthesizers.py:206` | `z_p = (m_p + exp(logs_p)·randn · **0.0**) · x_mask` |

The comment directly above the line reads *"Expanding m_p with noise"* — the intent was
noise; the multiplier was zeroed (almost certainly to get determinism during parity work)
and never restored. With it at zero the model emits the conditional **mean** rather than a
sample, which strips the aperiodic/breath component and reads as a metallic, ringing tail.

Fingerprint: `z_p` min/max print byte-identical to `m_p`.

**Fix:** honour `RVC_MLX_NOISE_SCALE`, **defaulting to 0.66666** so forgetting to set it
fails toward the reference value.

Measured phase-invariantly (log-spectral 2048/512) against the PyTorch reference. Both
frameworks draw unseeded noise, so two runs of the *same* pipeline already diverge — the
absolute LSD is meaningless without that floor:

| model | floor (two MLX runs) | noise=0 | noise=0.66666 |
|---|---|---|---|
| Kermit | 8.10 dB | 9.90 dB (+1.80) | **8.42 dB (+0.32)** |
| Minami | 7.68 dB | 10.41 dB (+2.73) | **8.77 dB (+1.0)** |

HF bias flips from −1.4 dB (audibly dark vs PyTorch) to +0.4 dB.

## Not a bug — checked and at parity

- **`SineGenerator` random phase.** The fork's `Demos/iOS/AUDIO_QUALITY_FIX.md` documents a
  missing random phase offset causing "continuous robotic NOISE", fixed only in its Swift
  demo. The **Python** path already has it, including zeroing the fundamental — a faithful
  port of `rvc/lib/algorithm/generators/hifigan.py:171-194`. Do not re-investigate.
- **NSF source noise term.** `noise_amp = uv·0.003 + (1−uv)·(sine_amp/3)` matches PyTorch.
- **Chunk seams.** Ruled out by control, not inspection: two runs at chunk=16384 differ by
  rms 1.55e-3; chunk 4096 vs 16384 differ by 1.54e-3 — indistinguishable, so chunk size
  contributes nothing beyond the RNG floor.

## Usage

```bash
python3 scripts/rvc-patches/infer.py <model.npz> <input.wav> <output.wav> [index.index]
```

or from Python:

```python
from shadow import install
install()                       # raises if either patch fails to bind
from rvc_mlx.infer.infer_mlx import RVC_MLX
```

`install()` **must** run before anything imports `rvc_mlx`; it raises if the fenced module
got there first, because silently running unpatched code while believing the fix applied is
the worst failure this can have.

Env: `RVC_MLX_NOISE_SCALE` (default `0.66666`).

## Checking for drift

These are whole-file copies, so a vendored-tree update can silently desync them:

```bash
for f in generators synthesizers; do
  diff -u --label "vendored/$f.py" --label "patched/$f.py" \
       "scripts/rvc/runtime/src/rvc_mlx/lib/mlx/$f.py" "scripts/rvc-patches/$f.py" \
    | diff - "scripts/rvc-patches/$f.patch" \
    && echo "$f: in sync"
done
```

Empty diff output means the vendored file has not changed since the patch was taken.

The `--label` flags are load-bearing: without them the diff header carries file **mtimes**,
so a mere `cp` makes the check report drift that does not exist. Verified in both
directions — it catches a planted one-line change, and it stays quiet after a touch-only
restore.

## Determinism

`0.66666` makes output non-deterministic run to run — the NSF source module also draws
unseeded noise, so **nothing** in this pipeline is reproducible at any setting. Any gate
asserting on audio must seed (`mx.random.seed(...)`) or assert on profile statistics rather
than a hash. That determinism need is the most likely reason the fork's author zeroed the
noise in the first place.

## Upstream

Neither defect has been reported upstream yet.

- **MLX** (`ml-explore/mlx`) — bug 1. High value: affects any MLX audio model.
- **The fork** (`Acelogic/Retrieval-based-Voice-Conversion-MLX`) — bug 2.

⚠️ The fork ships **no LICENSE file** (its `pyproject` claims MIT; GitHub reports
`licenseInfo: null`). That is unresolved and bears on vendoring it long-term.
