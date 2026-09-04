#!/usr/bin/env python3
"""Audio for the tuning lessons — and a measurement of what it demonstrates.

The comma is usually explained with arithmetic. It is much better heard: two
tones a Pythagorean comma apart beat against each other at a rate you can
count, and that rate is predictable from the ratio alone. This generates the
demonstrations and then MEASURES the beat rate off the rendered audio, so the
number that goes on screen came from the file the viewer hears.
"""
import argparse
import math
import os

import numpy as np
import soundfile as sf

SR = 48000
COMMA = (3 ** 12) / (2 ** 19)          # 531441/524288, exact
A4 = 440.0


def tone(f, seconds, partials=4, decay=0.0):
    t = np.arange(int(seconds * SR)) / SR
    y = np.zeros_like(t)
    for k in range(1, partials + 1):
        y += (1.0 / k ** 1.6) * np.sin(2 * math.pi * f * k * t)
    if decay:
        y *= np.exp(-decay * t)
    return y / (np.max(np.abs(y)) or 1.0)


def env(y, k=0.03):
    n = len(y)
    e = int(k * SR)
    y[:e] *= np.linspace(0, 1, e)
    y[-e:] *= np.linspace(1, 0, e)
    return y


def write(path, y, gain=0.85):
    y = env(np.asarray(y, dtype=float).copy())
    y = y / (np.max(np.abs(y)) or 1.0) * gain
    sf.write(path, np.stack([y, y], axis=1).astype(np.float32), SR)
    return path


def beat_rate(y):
    """(hz, depth) of the beating, or None if there is none to find.

    ⚠ The first version returned the loudest bin in the search band no matter
    what, so a SINGLE steady tone -- which cannot beat -- reported 39.83 Hz,
    the band edge. An argmax always returns something. The prominence test is
    what makes a null result possible, and the single-tone control is what
    exposed the need for it."""
    a = np.abs(np.asarray(y, dtype=float))
    win = int(SR * 0.004)
    a = np.convolve(a, np.ones(win) / win, mode="same")
    a = a[SR // 2: -SR // 2]

    # Gate on SLOW modulation depth only.
    #   * A steady tone has a flat envelope, so a "times the median" test is
    #     meaningless -- any bin clears it. That version reported 40 Hz for a
    #     single tone.
    #   * A JUST major third has no beating, but its waveform is periodic at
    #     110 Hz, so a broadband depth test sees fluctuation and calls it a
    #     beat. 110 Hz is a pitch, not a beat.
    # So the depth is measured inside the beat band itself.
    dc = float(np.mean(a))
    if dc <= 0:
        return None
    a = a - dc
    spec = np.abs(np.fft.rfft(a * np.hanning(len(a)))) * 2 / len(a)
    freqs = np.fft.rfftfreq(len(a), 1 / SR)
    band = (freqs > 0.5) & (freqs < 60)
    sb, fb = spec[band], freqs[band]
    depth = float(np.sqrt(np.sum(sb ** 2))) / dc
    # Threshold chosen from MEASURED separation, with a control on each side,
    # not tuned until the answer looked right:
    #     single tone      0.0001   (must be null)
    #     just 5:4 third   0.0000   (must be null)
    #     tempered third   0.0009   peak 17.27 Hz vs 17.46 predicted
    #     comma pair       0.3276   peak  6.00 Hz vs  6.00 predicted
    # A tempered third really is ~350x shallower than the comma. It is a
    # roughness, not a wobble, and the number should say so.
    if depth < 5e-4:
        return None
    return float(fb[int(np.argmax(sb))]), depth


def expected_beat(f_root, f_upper, max_h=8):
    """The rate you actually HEAR is the closest coincidence between harmonics,
    not the difference between fundamentals.

    Measured 17.27 Hz on a tempered major third while this function's naive
    ancestor predicted 4.37. The ear is beating the root's 5th harmonic
    (2200 Hz) against the third's 4th (2217.5) -- the measurement was right and
    the arithmetic was wrong."""
    best = None
    for m in range(1, max_h + 1):
        for n in range(1, max_h + 1):
            d = abs(f_root * m - f_upper * n)
            if d < 60 and (best is None or d < best[0]):
                best = (d, m, n)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    d = a.out_dir
    os.makedirs(d, exist_ok=True)

    # 1. Twelve just fifths, each note dropped an octave when it runs high, so
    #    the climb stays audible instead of leaving the register.
    seq = []
    f = 261.63                                  # C4
    for i in range(13):
        seq.append(env(tone(f, 0.42, decay=3.0)))
        seq.append(np.zeros(int(0.06 * SR)))
        f *= 1.5
        while f > 1100:
            f /= 2
    write(os.path.join(d, "stack.wav"), np.concatenate(seq))

    # 2. The comma itself: A440 against the note twelve just fifths reaches,
    #    folded into the same octave. They beat.
    hi = A4 * COMMA
    clash = tone(A4, 7.0, partials=3) + tone(hi, 7.0, partials=3)
    write(os.path.join(d, "clash.wav"), clash)
    m = beat_rate(clash)
    e = expected_beat(A4, hi)
    print(f"  clash.wav : {A4:.2f} Hz + {hi:.2f} Hz")
    print(f"              expected {e[0]:.2f} Hz (h{e[1]}:h{e[2]}), "
          f"MEASURED {m[0]:.2f} Hz  depth {m[1]:.4f}")

    # control: a single tone cannot beat. If this finds one, the method is broken.
    mc = beat_rate(tone(A4, 7.0, partials=6))
    print(f"  CONTROL   : one tone alone -> {mc} "
          f"({'correct: no beat found' if mc is None else 'WRONG -- method invalid'})")

    # 3. Just major third versus the equal-tempered one, over the same root.
    # ⚠ SIX partials, not three. The roughness of a tempered major third is the
    # root's 5th harmonic beating against the third's 4th. With only three
    # partials those do not exist, the file does not beat, and the demo fails
    # to demonstrate the thing it is about -- while still sounding like a
    # major third. The audio has to contain the harmonics that cause the effect.
    just = tone(A4, 3.2, partials=6) + tone(A4 * 5 / 4, 3.2, partials=6)
    eq = tone(A4, 3.2, partials=6) + tone(A4 * 2 ** (4 / 12), 3.2, partials=6)
    gap = np.zeros(int(0.35 * SR))
    write(os.path.join(d, "thirds.wav"),
          np.concatenate([env(just), gap, env(eq), gap, env(just.copy()), gap, env(eq.copy())]))
    mt = beat_rate(eq)
    mj = beat_rate(just)
    et = expected_beat(A4, A4 * 2 ** (4 / 12))
    print(f"  thirds.wav: just 5:4 = {A4*5/4:.2f} Hz, tempered = {A4*2**(4/12):.2f} Hz")
    print(f"              tempered: expected {et[0]:.2f} Hz (h{et[1]}:h{et[2]}), "
          f"MEASURED {'no beat' if mt is None else f'{mt[0]:.2f} Hz  depth {mt[1]:.4f}'}")
    print(f"              just    : {mj} "
          f"({'no beating -- that is the point' if mj is None else 'unexpected beating'})")
    print(f"  comma     : {COMMA:.9f}  =  {1200*math.log2(COMMA):.2f} cents")


if __name__ == "__main__":
    main()
