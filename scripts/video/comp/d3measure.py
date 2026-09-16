#!/usr/bin/env python3
"""Measure the compressor's RELEASE against the prediction t = releaseMs * ln(G).

⭐ PER-SAMPLE, NOT PER-ENVELOPE. With mix 1 and makeup 0 the compressor is a
per-sample scalar: comp[i] = dry[i] * gain[i]. So the gain curve is a division,
not an envelope estimate -- no window, no RMS ripple on a 220 Hz tone, and no
ambiguity about where t = 0 is. The FIRST cut of this demo measured the output
envelope and reported a rate that read identically in the bypassed control,
because that rate was the drum pattern.

The figure is a TWO-CROSSING time: from the gain crossing -12 dB to the gain
crossing -1 dB. Anchoring on the crossings rather than on the burst's end
removes the detector's own fall time from the answer... almost. What it cannot
remove is the 5 ms peak decay INSIDE the crossing window (the target is still
descending while the release has started) and the `env > -1e-10 -> env = 0`
snap at the bottom, so the measurement is expected to run slightly LONG.
"""
import json, math, sys
import numpy as np
import soundfile as sf

# ⚠⚠ THIS FLOOR WAS -60 AND IT PUT A FALSE FINDING ON SCREEN. The dry tail peaks
# at -39.67 dBFS, so a -60 floor discards every sample within |sin| < 0.096 of a
# zero crossing — about 0.15 ms of gap per half cycle. A crossing that falls in a
# gap is then detected EARLY at -12 and LATE at -1, and both biases point the same
# way: LONG. That is the whole of the "0.2 ms" the first re-cut attributed to the
# detector's 5 ms decay. Moving the floor to -80 changes 74.688 to 74.583, which
# is the test that a real property of the compressor would have failed.
# ⭐ CONTROL YOUR METRIC BEFORE YOU EXPLAIN A NUMBER IT PRODUCED.
FLOOR_DB = -80.0      # below this the dry carrier is too small to divide by


def gain_curve(dry_path, comp_path):
    d, sr = sf.read(dry_path, always_2d=True)
    c, sr2 = sf.read(comp_path, always_2d=True)
    assert sr == sr2, (sr, sr2)
    nd = min(len(d), len(c))
    d, c = d[:nd, 0], c[:nd, 0]
    floor = 10 ** (FLOOR_DB / 20.0)
    ok = np.abs(d) > floor
    g = np.full(nd, np.nan)
    g[ok] = 20.0 * np.log10(np.abs(c[ok]) / np.abs(d[ok]))
    return g, sr, ok


def recovery_ms(dry, comp, sr_hint=None):
    """Time from -12 dB of reduction to -1 dB, in ms. None if never at -12.

    Both crossings are LINEARLY INTERPOLATED between the samples that bracket
    them. Sample-quantised crossings cost up to a sample each and the two errors
    do not cancel; at a 30 ms release the whole answer is 74.5 ms, so a tenth of
    a millisecond of quantisation is a tenth of a millisecond of made-up physics.
    """
    g, sr, ok = gain_curve(dry, comp)
    idx = np.where(ok)[0]
    gv = g[idx]
    below = np.where(gv <= -12.0)[0]
    if len(below) == 0:
        return None, sr, float(np.nanmin(gv))
    last12 = below[-1]
    after = np.where(gv[last12:] >= -1.0)[0]
    if len(after) == 0 or last12 + 1 >= len(gv):
        return None, sr, float(np.nanmin(gv))
    i1 = last12 + after[0]

    def cross(i, target):
        """Sub-sample position where the gain curve passes `target`, between
        sample i-1 (below it) and sample i (at or above it)."""
        a, b = idx[i - 1], idx[i]
        ga, gb = gv[i - 1], gv[i]
        return b if gb == ga else a + (target - ga) / (gb - ga) * (b - a)

    return (cross(i1, -1.0) - cross(last12 + 1, -12.0)) / sr * 1000.0, sr, float(np.nanmin(gv))


def peak_db(path, t0, t1):
    x, sr = sf.read(path, always_2d=True)
    seg = x[int(t0 * sr):int(t1 * sr)]
    p = float(np.max(np.abs(seg)))
    return 20 * math.log10(p) if p > 0 else float("-inf")


if __name__ == "__main__":
    aud = sys.argv[1]
    if sys.argv[2] == "peaks":
        print(json.dumps({
            "burst_peak_dbfs": round(peak_db(f"{aud}/d3b-dry.wav", 0.1, 1.1), 6),
            "tail_peak_dbfs":  round(peak_db(f"{aud}/d3b-dry.wav", 2.0, 4.5), 6),
        }, indent=1))
    else:
        out = {}
        for rel in (30, 100, 800):
            ms, sr, gmin = recovery_ms(f"{aud}/d3b-dry.wav", f"{aud}/d3b-rel{rel}.wav")
            out[f"rel{rel}"] = {
                "predicted_ms": round(rel * math.log(12.0), 1),
                "measured_ms": None if ms is None else round(ms, 2),
                "deepest_reduction_db": round(gmin, 4),
            }
        ms, sr, gmin = recovery_ms(f"{aud}/d3b-dry.wav",
                                   f"{aud}/d3b-rel100-ratio1-CONTROL.wav")
        out["control_ratio1"] = {"measured_ms": ms, "deepest_reduction_db": round(gmin, 4)}
        print(json.dumps(out, indent=1))
