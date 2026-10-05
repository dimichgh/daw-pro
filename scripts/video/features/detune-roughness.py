#!/usr/bin/env python3
"""Does a unison detune SHIMMER, or does it BUZZ?

⭐ WHY THIS EXISTS. Raising `veil` an octave (+12 → +24) to separate stardust
from knowledge in register fixed the thing it was meant to fix — and silently
broke something no gate was looking at. Detune is specified in CENTS, which is a
constant RATIO, so the BEAT RATE it produces scales with pitch:

    beat_hz ≈ f * (2**(cents/1200) - 1)

At 22 cents that is 0.0128 * f. On the approved Starlight strings at D4 (294 Hz)
it is ~3.8 Hz — a slow, lush swell. On veil at D6 (1175 Hz) it is ~15 Hz, which
is not a swell at all: 15–35 Hz amplitude modulation is the classic ROUGHNESS
band, heard as a buzz or a metallic rattle rather than as richness. The patch
number never changed, so nothing flagged it; the register did.

⛔ I CANNOT HEAR THIS FILE, SO THE MEASUREMENT HAS TO EARN ITS ANSWER. Every
number below is meaningless unless the POSITIVE CONTROL passes first: synthetic
unisons whose roughness is known BY CONSTRUCTION must come out ordered the way
the physics says they must. If the control does not separate them, this script
reports that it is blind and refuses to score the real audio — a metric that
cannot detect a defect it was handed is not evidence of that defect's absence.

⭐⭐ MEASURED 2026-09-22, AND THE ANSWER WAS "LEAVE IT ALONE". The control
ranked the four synthetic unisons exactly as the physics forces (0.01 → 0.06 →
0.18, and halving the detune dropped 0.18 → 0.11), so the metric can see
roughness when handed it. The real veil then measured a 5.6 Hz peak and a
rough/shimmer ratio of 0.03 — LESS rough than the synthetic prediction for an
octave LOWER, and nowhere near the 0.18 its bare 22 cents at D6 predicts.

The gap is the patch, and it is worth knowing which parts did the work:
`drift 0.45` and `voiceJitter 0.3` keep the seven voices from settling into one
steady 15 Hz beat, the 5200 Hz cutoff removes the upper harmonics (harmonic h
beats at h × 15 Hz, so the fast beating lives up there), and a 4.5 s hall smears
what is left. A bare unison calculator would have condemned this patch; the
rendered sound is what gets measured, reverb included, because that is what
gets heard. ⛔ SO DO NOT "FIX" VEIL'S DETUNE ON THE ARITHMETIC ALONE — the
prediction is a reason to MEASURE, never a finding on its own.

Usage:  detune-roughness.py <wav> [--from SEC] [--to SEC] [--control-only]
"""

import argparse
import sys

import numpy as np
import soundfile as sf

# Modulation bands, in Hz of ENVELOPE rate (not carrier frequency).
SHIMMER = (0.5, 8.0)    # slow beating: reads as lush, alive, "wide"
ROUGH = (12.0, 40.0)    # fast beating: reads as buzz, rattle, "cheap"


def envelope_spectrum(x, sr, env_sr=400.0):
    """Amplitude-envelope modulation spectrum of a mono signal.

    Rectify, decimate to `env_sr`, remove the DC term (the steady level is not
    modulation), and take the magnitude spectrum of what is left. Everything
    that survives is how hard the loudness is wobbling, and how fast.
    """
    env = np.abs(x)
    # Box-average down to env_sr. Cheap, and its lowpass is exactly what we want
    # before decimating — no aliasing of the carrier into the modulation band.
    step = max(1, int(round(sr / env_sr)))
    n = (len(env) // step) * step
    if n < step * 8:
        return None, None
    env = env[:n].reshape(-1, step).mean(axis=1)
    fs = sr / step
    env = env - env.mean()
    if not np.any(env):
        return None, None
    win = np.hanning(len(env))
    mag = np.abs(np.fft.rfft(env * win))
    freqs = np.fft.rfftfreq(len(env), 1.0 / fs)
    return freqs, mag


def roughness_ratio(x, sr):
    """Energy in the ROUGH modulation band over energy in the SHIMMER band.

    >1 means the wobble is mostly fast enough to read as buzz. Returns
    (ratio, peak_rate_hz) or (None, None) when there is nothing to measure.
    """
    freqs, mag = envelope_spectrum(x, sr)
    if freqs is None:
        return None, None
    p = mag ** 2

    def band(lo, hi):
        return p[(freqs >= lo) & (freqs < hi)].sum()

    sh, ro = band(*SHIMMER), band(*ROUGH)
    if sh + ro <= 0:
        return None, None
    sel = (freqs >= SHIMMER[0]) & (freqs < ROUGH[1])
    peak = freqs[sel][np.argmax(p[sel])] if sel.any() else None
    return ro / max(sh, 1e-20), peak


def unison(f0, cents, voices, sr, secs=6.0):
    """A synthetic unison: `voices` saws spread across ±`cents`."""
    t = np.arange(int(sr * secs)) / sr
    out = np.zeros_like(t)
    spread = np.linspace(-1.0, 1.0, voices) if voices > 1 else np.array([0.0])
    for s in spread:
        f = f0 * (2.0 ** (s * cents / 1200.0))
        # Band-limited enough for this purpose: a few harmonics of a saw.
        for h in range(1, 7):
            if f * h < sr / 2:
                out += np.sin(2 * np.pi * f * h * t) / h
    return out / voices


def control(sr=48000):
    """Prove the metric can SEE roughness before trusting it on real audio.

    Three synthetic unisons whose ordering is fixed by physics, not by taste:
    the same 22-cent detune beats twice as fast an octave up, and halving the
    cents halves the rate again. If the metric does not order these correctly it
    cannot be used to judge the veil.
    """
    cases = [
        ("D4 294 Hz, 22 cents (the approved Starlight register)", 293.66, 22),
        ("D5 587 Hz, 22 cents (veil BEFORE the octave lift)", 587.33, 22),
        ("D6 1175 Hz, 22 cents (veil AS BUILT)", 1174.66, 22),
        ("D6 1175 Hz, 11 cents (veil, detune halved)", 1174.66, 11),
    ]
    print("── POSITIVE CONTROL: synthetic unisons, 7 voices ──")
    print(f"{'case':<48} {'predicted':>10} {'peak':>8} {'rough/shimmer':>14}")
    rows = []
    for label, f0, cents in cases:
        x = unison(f0, cents, 7, sr)
        ratio, peak = roughness_ratio(x, sr)
        pred = f0 * (2.0 ** (cents / 1200.0) - 1.0)
        rows.append((label, pred, peak, ratio))
        pk = f"{peak:.1f}" if peak is not None else "—"
        rt = f"{ratio:.2f}" if ratio is not None else "—"
        print(f"{label:<48} {pred:>9.1f}H {pk:>7}H {rt:>14}")

    # The control passes only if the metric RANKS these the way the physics
    # does: the as-built veil must measure rougher than the same patch an octave
    # down, AND rougher than itself with the detune halved. Two independent
    # orderings, both forced by f * (2^(c/1200) - 1).
    by = {r[0]: r[3] for r in rows}
    as_built = by["D6 1175 Hz, 22 cents (veil AS BUILT)"]
    octave_dn = by["D5 587 Hz, 22 cents (veil BEFORE the octave lift)"]
    halved = by["D6 1175 Hz, 11 cents (veil, detune halved)"]
    if None in (as_built, octave_dn, halved):
        print("\n⛔ CONTROL FAILED — the metric returned nothing on synthetic "
              "audio it was handed. It is blind; no score follows.")
        return False
    ok = as_built > octave_dn and as_built > halved
    if ok:
        print(f"\n✅ control passes — as-built ({as_built:.2f}) measures rougher "
              f"than an octave down ({octave_dn:.2f}) and than half the detune "
              f"({halved:.2f}), which is the order the physics forces.")
    else:
        print(f"\n⛔ CONTROL FAILED — as-built {as_built:.2f} vs octave-down "
              f"{octave_dn:.2f} vs halved {halved:.2f} is NOT the order "
              f"f*(2^(c/1200)-1) requires. The metric cannot see this defect, "
              f"so it cannot be used to rule it out either.")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav", nargs="?")
    ap.add_argument("--from", dest="t0", type=float, default=0.0)
    ap.add_argument("--to", dest="t1", type=float, default=None)
    ap.add_argument("--control-only", action="store_true")
    a = ap.parse_args()

    if not control():
        sys.exit(3)
    if a.control_only or not a.wav:
        return

    x, sr = sf.read(a.wav, always_2d=True)
    x = x.mean(axis=1)
    i0 = int(a.t0 * sr)
    i1 = int(a.t1 * sr) if a.t1 else len(x)
    seg = x[i0:i1]
    print(f"\n── MEASURED: {a.wav}  [{a.t0:.1f}s … "
          f"{(a.t1 if a.t1 else len(x)/sr):.1f}s] ──")
    ratio, peak = roughness_ratio(seg, sr)
    if ratio is None:
        print("nothing to measure in that window (silent?)")
        sys.exit(2)
    print(f"peak modulation rate : {peak:.1f} Hz")
    print(f"rough/shimmer ratio  : {ratio:.2f}")
    verdict = ("BUZZ — the wobble is mostly in the roughness band"
               if ratio > 1.0 else
               "shimmer — the wobble is mostly slow and lush")
    print(f"verdict              : {verdict}")


if __name__ == "__main__":
    main()
