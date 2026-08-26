#!/usr/bin/env python3
"""m23-fn: level / clipping measurement on a REAL conversion, before vs after.

**Code we own.** Never writes under `scripts/rvc/`; run with
`PYTHONDONTWRITEBYTECODE=1` and cwd = the vendored src root.

Why this exists: the corrected flow mapping changes the decoder's input
distribution, and the spike measured the output moving by LSD 1.06 at roughly
4x the level. **A "correct" model that clips is worse for the user than a
wrong one that doesn't**, so the level has to be measured, not assumed.

What is measured, per conversion:

* sample peak and RMS;
* **true peak** by 8x polyphase oversampling (ITU-R BS.1770-4 asks for >=4x at
  these rates), which is what an inter-sample-peak meter or a downstream
  true-peak limiter actually sees;
* clipped sample count (|x| >= 1.0);
* whether the vendored pipeline's own max-normaliser fired.  That normaliser
  (`rvc_mlx/infer/pipeline_mlx.py:369-372`) is `audio_max = |out|.max()/0.99;
  if audio_max > 1: out /= audio_max` — it only engages ABOVE 0.99, so a
  reported peak of exactly 0.99 means the output ran into the ceiling and was
  scaled back, and any peak below that means it did not.

⚠️ `mx.clear_cache()` is called before every inference by default. That is the
mitigation the m23-fd spike proved necessary and sufficient for the SEPARATE
defect m23-fo (repeated conversion in one process degrades to saturation by
about the 5th call, peak pinned at 0.99). Without it, a before/after level
comparison measures the allocator bug rather than the weights. `--no-clear-cache`
reproduces the degraded regime deliberately, so the scope of any "does not
clip" claim can be stated honestly.

    PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=1 <venv>/bin/python \
        measure_conversion.py --model M.npz --input in.wav --outdir DIR \
        [--reps 3] [--pitch 0] [--no-clear-cache] [--json report.json]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys


def _db(x: float) -> float:
    return 20.0 * math.log10(x) if x > 0 else float("-inf")


def analyse(path: str) -> dict:
    import numpy as np
    import soundfile as sf
    from scipy import signal as sps

    audio, sr = sf.read(path)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    audio = np.asarray(audio, dtype=np.float64)
    peak = float(np.abs(audio).max()) if audio.size else 0.0
    rms = float(np.sqrt((audio**2).mean())) if audio.size else 0.0
    up = sps.resample_poly(audio, 8, 1)
    true_peak = float(np.abs(up).max()) if up.size else 0.0
    return {
        "file": os.path.basename(path),
        "sampleRate": int(sr),
        "samples": int(audio.size),
        "rms": round(rms, 6),
        "peak": round(peak, 6),
        "peakDbfs": round(_db(peak), 3),
        "truePeak": round(true_peak, 6),
        "truePeakDbfs": round(_db(true_peak), 3),
        "clippedSamples": int(np.count_nonzero(np.abs(audio) >= 1.0)),
        "clippedFraction": round(
            float(np.count_nonzero(np.abs(audio) >= 1.0)) / max(audio.size, 1), 6
        ),
        "truePeakOverFullScale": bool(true_peak > 1.0),
        "normaliserFired": bool(abs(peak - 0.99) < 1e-4),
        "nonFinite": int(np.count_nonzero(~np.isfinite(audio))),
    }


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument(
        "--input",
        required=True,
        action="append",
        help="stimulus wav; repeat to sweep several input levels in ONE process",
    )
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--tag", default="run")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--pitch", type=int, default=0)
    ap.add_argument("--no-clear-cache", action="store_true")
    ap.add_argument("--json")
    args = ap.parse_args(argv)

    import mlx.core as mx
    from rvc_mlx.infer.infer_mlx import RVC_MLX

    os.makedirs(args.outdir, exist_ok=True)
    engine = RVC_MLX(os.path.abspath(args.model))

    reps = []
    call = 0
    for src in args.input:
        stem = os.path.splitext(os.path.basename(src))[0]
        for i in range(args.reps):
            if not args.no_clear_cache:
                mx.clear_cache()
            out = os.path.join(args.outdir, f"{args.tag}-{stem}-rep{i}.wav")
            # Exactly the call `scripts/rvc/server.py:334` makes for voiceId
            # "base": rmvpe pitch, no retrieval index, index_rate 0.
            engine.infer(
                os.path.abspath(src),
                out,
                pitch=args.pitch,
                f0_method="rmvpe",
                index_path=None,
                index_rate=0.0,
            )
            rep = analyse(out)
            rep["rep"] = i
            rep["callIndexInProcess"] = call
            rep["inputFile"] = os.path.basename(src)
            rep["inputMetrics"] = analyse(os.path.abspath(src))
            reps.append(rep)
            call += 1

    report = {
        "model": os.path.abspath(args.model),
        "input": analyse(os.path.abspath(args.input[0])),
        "clearCache": not args.no_clear_cache,
        "pitchSemitones": args.pitch,
        "reps": reps,
    }
    print(json.dumps(report, indent=2))
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
