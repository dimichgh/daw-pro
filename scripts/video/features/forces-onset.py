#!/usr/bin/env python3
"""Measure when each energy is FIRST AUDIBLE, from its own bounced stem.

⛔ WHY THIS EXISTS. The review page printed "Stardust first heard 0:00 /
Knowledge first heard 1:39 / Consciousness first heard 3:18" under a note saying
the figures are "drawn from the audio, not from the plan". They were not.
`forces-gate.py` writes:

    bars = {f: forces[f]["emergeBar"] for f in names}   # straight from build.json
    "emergeSeconds": {f: round(bars[f] * spb, 1) ...}

— a DESIGN CONSTANT multiplied by a tempo, wearing a measurement's name. An
independent observer pass on 2026-09-22 measured `apart`'s Knowledge stem as
inaudible until 106.4 s while the page, citing that field, said 99.0 s. The gate
that "checks" emergence compares those three declared numbers to EACH OTHER and
never opens the audio, so it cannot fail for this reason.

⭐ A FIELD NAMED FOR A MEASUREMENT IS NOT A MEASUREMENT. Check what wrote it.

This opens the stems. Usage:  forces-onset.py [--write] [--floor -50]
"""
import argparse
import json
import pathlib
import sys

import numpy as np
import soundfile as sf

HOP = 0.010          # 10 ms envelope hop — finer than the 0.1 s we report
WIN = 0.100          # 100 ms RMS window
HOLD = 0.150         # must STAY above the floor this long, so one stray sample
                     # of dither or a click cannot declare an entrance


def envelope_db(path):
    """Full-scale dB envelope of a stem, mono-summed."""
    x, sr = sf.read(str(path), dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    hop, win = int(sr * HOP), int(sr * WIN)
    n = 1 + max(0, (len(x) - win) // hop)
    # cumulative-sum RMS: exact, and fast enough on a 5-minute stem
    p = np.concatenate([[0.0], np.cumsum(x.astype(np.float64) ** 2)])
    idx = np.arange(n) * hop
    rms = np.sqrt(np.maximum(p[idx + win] - p[idx], 0.0) / win)
    return 20 * np.log10(np.maximum(rms, 1e-12)), sr, hop


def first_above(db, hop, floor):
    """First time the envelope rises above `floor` and STAYS there for HOLD."""
    need = max(1, int(HOLD / HOP))
    ok = db > floor
    if not ok.any():
        return None
    # a run of `need` consecutive True values
    run = np.convolve(ok.astype(int), np.ones(need, int), mode="valid")
    hit = np.flatnonzero(run == need)
    return None if len(hit) == 0 else float(hit[0] * HOP)


def control():
    """⭐ POSITIVE CONTROL, every run. Plant a known onset; the detector must
    find it, and must NOT find one in silence. Without this a broken probe
    returns 0.0 for everything and 0.0 looks like 'starts at the beginning'."""
    sr = 48000
    sec = 6.0
    x = np.zeros(int(sr * sec), dtype=np.float32)
    at = 2.5
    t = np.arange(int(sr * (sec - at))) / sr
    x[int(sr * at):] = (0.02 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)  # ~-37 dBFS
    p = pathlib.Path("/tmp/_onset_control.wav")
    sf.write(str(p), x, sr)
    db, _, hop = envelope_db(p)
    got = first_above(db, hop, -50.0)
    sil = first_above(np.full(500, -90.0), hop, -50.0)
    p.unlink(missing_ok=True)
    if got is None or abs(got - at) > 0.15:
        sys.exit(f"⛔ CONTROL FAILED: planted onset at {at}s, detector said {got}")
    if sil is not None:
        sys.exit(f"⛔ CONTROL FAILED: detector found an onset in pure silence ({sil})")
    print(f"control: planted onset {at:.2f}s -> detected {got:.2f}s; "
          f"silence -> none. Detector works.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--floor", type=float, default=-50.0,
                    help="dBFS below which a stem counts as not yet sounding")
    ap.add_argument("--write", action="store_true",
                    help="write firstAudibleSeconds into each gate.json")
    a = ap.parse_args()

    control()
    print()

    for d in sorted(pathlib.Path("out").glob("cosmic-forces*")):
        gp = d / "gate.json"
        sd = d / "stems"
        if not gp.exists() or not sd.is_dir():
            continue
        g = json.loads(gp.read_text())
        measured, declared = {}, g.get("emergeSeconds", {})
        print(f"{d.name}")
        for stem in sorted(sd.glob("*.wav")):
            force = stem.stem.split(" ", 1)[1].lower()
            db, sr, hop = envelope_db(stem)
            t50 = first_above(db, hop, a.floor)
            t40 = first_above(db, hop, a.floor + 10)
            measured[force] = None if t50 is None else round(t50, 1)
            dec = declared.get(force)
            drift = "" if dec is None or t50 is None else f"   drift {t50 - dec:+.1f}s"
            print(f"   {force:14} first audible {t50:7.1f}s "
                  f"(at {a.floor + 10:.0f} dB: {t40:7.1f}s)   "
                  f"build.json says {dec}{drift}")
        if a.write:
            g["firstAudibleSeconds"] = measured
            g["firstAudibleFloorDb"] = a.floor
            gp.write_text(json.dumps(g, indent=2, ensure_ascii=False))
            back = json.loads(gp.read_text())["firstAudibleSeconds"]
            assert back == measured, "write did not take"
            print("   -> written to gate.json and read back")
        print()


if __name__ == "__main__":
    main()
