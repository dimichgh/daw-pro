#!/usr/bin/env python3
"""Extract the REAL per-sample gain curve of a compressed render, for animation.

⚠️ THE POINT IS THAT THIS IS MEASURED. A hand-drawn exponential would look
identical to a viewer and would be a lie in a film whose entire premise is
prediction-then-measurement. Every point here comes out of the rendered audio:
`gain[i] = compressed[i] / dry[i]`, which is exact because mix = 1 and
makeup = 0, so the compressor's only contribution IS the gain.
"""
import json, subprocess, sys
import numpy as np

SR = 48000


def read(path):
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path,
                          "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def curve(dry_path, comp_path, hop_ms=4.0, floor_db=-80.0):
    """Gain in dB, sampled every `hop_ms`, with the sample floor stated.

    ⚠️ THE FLOOR IS LOAD-BEARING AND IT ONCE PRODUCED A WRONG ON-SCREEN CLAIM.
    Near a zero crossing both signals approach 0 and the ratio is noise, so
    quiet samples must be excluded -- but a floor set too HIGH (-60 dB against a
    -39.7 dBFS tail) blanks ~0.15 ms either side of every crossing, which moved
    a measured recovery time by 0.1 ms and got blamed on the detector on screen.
    """
    dry, comp = read(dry_path), read(comp_path)
    n = min(len(dry), len(comp))
    dry, comp = dry[:n], comp[:n]
    ok = np.abs(dry) > 10 ** (floor_db / 20.0)
    hop = int(SR * hop_ms / 1000.0)
    out = []
    for i in range(0, n - hop, hop):
        sl = slice(i, i + hop)
        m = ok[sl]
        if m.sum() < 4:
            continue
        g = np.abs(comp[sl][m] / dry[sl][m])
        out.append([round(i / SR, 5), round(float(20 * np.log10(np.median(g) + 1e-12)), 4)])
    return out


if __name__ == "__main__":
    dry = sys.argv[1]
    series = {}
    for label, path in (a.split("=", 1) for a in sys.argv[2:]):
        series[label] = curve(dry, path)
        lo = min(p[1] for p in series[label])
        print(f"  {label:<10} {len(series[label])} points, deepest {lo:.2f} dB")
    json.dump(series, open("gaincurve.json", "w"))
    print("  -> gaincurve.json")
