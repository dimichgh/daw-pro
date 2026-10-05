#!/usr/bin/env python3
"""Bring a loop up to platform loudness — by GAIN ALONE wherever possible.

    python3 master-loop.py out/cosmic-ascent-5m/cosmic-ascent-5m-loop.wav

⭐ WHY THE FULL PIECES MEASURE QUIET, AND WHY IT IS NOT A MASTERING FAULT.
The five-minute pieces sit at -18.0 to -19.5 LUFS integrated. That is 4-5 LU
below where YouTube normalises (about -14), and YouTube only ever turns things
DOWN, never up — so they play quieter than everything around them. The cause is
NOT timid mastering and NOT peak limiting: it is LOUDNESS RANGE. These pieces
measure LRA 13-17 LU because they are built to start near silence and arrive,
and the integrated figure averages the whole arc. Squashing that to hit -14
would flatten the very development the arrival gate exists to prove. The full
pieces keep their dynamics.

⭐⭐ A LOOP IS A DIFFERENT OBJECT AND GETS A DIFFERENT ANSWER. It is cut from the
climax, so its own LRA is 2-4 LU — there is no quiet opening dragging the
average down. That means plain gain, with no compression and no limiting, gets
it to platform loudness. Nothing is squashed and nothing is lost.

⛔ AND LOUDNESS DOES NOT COST TREBLE. Turning a signal up raises every frequency
by the same number of dB; the spectrum is unchanged. What can dull a master is
LIMITING — shaving peaks flattens transients, and heavy limiting is what people
hear as "lifeless". The ceiling here is true peak (inter-sample peaks can exceed
the sample peak, and lossy encoders overshoot further), which is why this targets
-1.0 dBTP and not 0.0. This script REFUSES to limit: if gain alone cannot reach
the target it stops short and says by how much, so the trade is a decision
somebody makes rather than something that quietly happened.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

import numpy as np
import soundfile as sf

TARGET = -14.0     # YouTube/Spotify normalisation target
CEILING = -1.0     # true-peak ceiling, leaves room for lossy encoding


def measure(path):
    out = subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", "-i", str(path),
         "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"],
        capture_output=True, text=True).stderr
    def grab(label, key):
        m = re.search(label + r".*?" + key + r":\s*(-?\d+\.?\d*)", out, re.S)
        return float(m.group(1)) if m else None
    return grab(r"Integrated loudness", "I"), grab(r"True peak", "Peak"), \
           grab(r"Loudness range", "LRA")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--target", type=float, default=TARGET)
    ap.add_argument("--ceiling", type=float, default=CEILING)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    src = pathlib.Path(args.path)
    lufs, tp, lra = measure(src)
    if lufs is None or tp is None:
        sys.exit("⛔ could not measure — ebur128 printed nothing (use -hide_banner, not -v error)")

    want = args.target - lufs           # gain needed to hit the target
    allow = args.ceiling - tp           # gain available before the ceiling
    gain = min(want, allow)
    achieved = lufs + gain
    peak_limited = want > allow + 0.05

    x, sr = sf.read(str(src), dtype="float64", always_2d=True)
    y = x * (10 ** (gain / 20))
    op = pathlib.Path(args.out) if args.out else src.with_name(src.stem + "-master.wav")
    sf.write(str(op), y, sr, subtype="FLOAT")

    got_l, got_tp, got_lra = measure(op)
    print(f"{src.name}")
    print(f"  before : {lufs:6.1f} LUFS   {tp:5.1f} dBTP   LRA {lra:4.1f}")
    print(f"  gain   : {gain:+6.2f} dB  ({'PEAK-LIMITED — ' if peak_limited else ''}"
          f"wanted {want:+.2f}, headroom {allow:+.2f})")
    print(f"  after  : {got_l:6.1f} LUFS   {got_tp:5.1f} dBTP   LRA {got_lra:4.1f}   -> {op.name}")
    # ⭐ VERIFY THE CEILING HELD rather than trusting the arithmetic — an
    # inter-sample peak is not a sample peak, and this is the check that a
    # loudness meter cannot make for you.
    if got_tp > args.ceiling + 0.05:
        sys.exit(f"⛔ true peak {got_tp:.1f} dBTP is over the {args.ceiling} ceiling")
    if peak_limited:
        print(f"  ⚠ {args.target - achieved:.1f} LU short of {args.target}. Closing that would "
              f"need a limiter, which is a tone decision, not a level one — not taken here.")
    else:
        print(f"  ✅ at platform loudness by gain alone — no compression, no limiting, "
              f"spectrum unchanged")


if __name__ == "__main__":
    main()
