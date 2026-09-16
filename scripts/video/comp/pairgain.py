#!/usr/bin/env python3
"""Apply ONE static gain, shared across an A/B pair, so the level DIFFERENCE
that IS the measurement survives to the viewer.

⚠ The assembler's loudnorm is single-pass and dynamic; on the makeup A/B it did
not flatten a 2.1 LU difference, it INVERTED it. A stage whose subject is level
sets `normalize: false` and comes through here instead. The gain is chosen from
the LOUDER file's peak so nothing clips, and the true peak of every output is
printed and checked.

    pairgain.py OUTDIR CEILING_DBFS in1.wav in2.wav ...
"""
import math, os, re, subprocess, sys
import numpy as np, soundfile as sf

out_dir, ceiling = sys.argv[1], float(sys.argv[2])
files = sys.argv[3:]
peaks = []
for f in files:
    x, sr = sf.read(f, always_2d=True)
    peaks.append(20 * math.log10(float(np.max(np.abs(x)))))
gain = ceiling - max(peaks)
print(f"peaks {[round(p,3) for p in peaks]}  shared gain {gain:+.3f} dB")
for f in files:
    o = os.path.join(out_dir, "g-" + os.path.basename(f))
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", f,
                    "-af", f"volume={gain:.4f}dB", "-c:a", "pcm_s16le", o], check=True)
    p = subprocess.run(["ffmpeg", "-hide_banner", "-i", o, "-af", "ebur128=peak=true",
                        "-f", "null", "-"], capture_output=True, text=True)
    tp = re.findall(r"Peak:\s*(-?\d+\.?\d*)", p.stderr)
    x, sr = sf.read(o, always_2d=True)
    print(f"  {os.path.basename(o)}  peak {20*math.log10(float(np.max(np.abs(x)))):.3f} dBFS"
          f"  true peak {tp[-1] if tp else '?'} dBTP")
