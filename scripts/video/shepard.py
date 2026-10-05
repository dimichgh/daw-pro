#!/usr/bin/env python3
"""Generate a Shepard tone — a pitch that appears to rise forever.

Construction (per Shepard 1964): a bank of sine partials spaced exactly one
octave apart, all gliding upward together. Their loudness follows a fixed bell
over LOG frequency, so a partial fades in at the bottom and out at the top
while the ear tracks the middle. After exactly one octave of movement the set
maps onto itself, which is what makes the loop seamless.

⚠ The frequency of each partial CHANGES over time, so the phase has to be
integrated (cumulative sum), not computed as 2*pi*f*t. Using the latter gives
a tone that sounds right for a moment and then develops audible artefacts as
the phase error grows — it measures fine and sounds broken.
"""
import argparse
import math

import numpy as np
import soundfile as sf

SR = 48000


def shepard(seconds=12.0, cycle=4.0, base_hz=32.703, octaves=8, sr=SR):
    """`cycle` seconds per octave of apparent rise."""
    n = int(seconds * sr)
    t = np.arange(n) / sr
    p = t / cycle                      # octaves travelled so far
    centre = (octaves - 1) / 2.0
    out = np.zeros(n)
    for i in range(octaves):
        # This partial's position in octaves above base, moving with p.
        pos = i + p
        f = base_hz * np.power(2.0, pos)
        # Bell over log frequency. Partials outside the span are silent, so
        # the one that wraps past the top is already inaudible when it does.
        x = (pos - centre) / (octaves / 2.6)
        amp = np.exp(-0.5 * x * x)
        amp[f > sr / 2.2] = 0.0        # never let a partial approach Nyquist
        phase = 2 * math.pi * np.cumsum(f) / sr
        out += amp * np.sin(phase)
    out /= np.max(np.abs(out)) or 1.0
    # gentle fades so the file itself does not click at its ends
    k = int(0.03 * sr)
    out[:k] *= np.linspace(0, 1, k)
    out[-k:] *= np.linspace(1, 0, k)
    return (out * 0.89).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=12.0)
    ap.add_argument("--cycle", type=float, default=4.0)
    a = ap.parse_args()
    y = shepard(a.seconds, a.cycle)
    sf.write(a.out, np.stack([y, y], axis=1), SR)
    print(f"wrote {a.out}  {len(y)/SR:.1f}s  peak {np.max(np.abs(y)):.3f}")

    # --- verification, because "it sounds like it rises" is not a measurement
    seg = y[int(0.5 * SR):int(1.5 * SR)]
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
    freqs = np.fft.rfftfreq(len(seg), 1 / SR)
    peaks = []
    for i in range(2, len(spec) - 2):
        if spec[i] > spec[i - 1] and spec[i] > spec[i + 1] and spec[i] > spec.max() * 0.02:
            peaks.append(freqs[i])
    ratios = [round(peaks[i + 1] / peaks[i], 2) for i in range(len(peaks) - 1)]
    print(f"  partials found: {len(peaks)}")
    print(f"  ratios between neighbours: {ratios[:8]}  (octave spacing = 2.0)")
    near2 = sum(1 for r in ratios if 1.9 <= r <= 2.1)
    print(f"  ratios within 5% of an octave: {near2}/{len(ratios)}")
    # the loop claim: one cycle apart should look near-identical
    a0 = y[int(0.5 * SR):int(0.5 * SR) + 2048]
    a1 = y[int((0.5 + a.cycle) * SR):int((0.5 + a.cycle) * SR) + 2048]
    if len(a1) == len(a0):
        s0 = np.abs(np.fft.rfft(a0))
        s1 = np.abs(np.fft.rfft(a1))
        cos = float(np.dot(s0, s1) / (np.linalg.norm(s0) * np.linalg.norm(s1)))
        rnd = np.abs(np.fft.rfft(np.random.default_rng(0).normal(size=2048)))
        ctrl = float(np.dot(s0, rnd) / (np.linalg.norm(s0) * np.linalg.norm(rnd)))
        print(f"  spectrum one cycle later: cosine {cos:.4f} (1.0 = identical)")
        print(f"  CONTROL vs noise:         cosine {ctrl:.4f} (must be much lower)")


if __name__ == "__main__":
    main()
