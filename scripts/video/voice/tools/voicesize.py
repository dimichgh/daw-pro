#!/usr/bin/env python3
"""voicesize.py — an INDEPENDENT reading of "voice size" off rendered stems.

    voicesize.py <wav>...        (first wav = the reference, usually as-sung)

Long-term average spectrum of the vowel frames (4096-pt Hann, hop 1024,
frames within 30 dB of the loudest), 80 Hz - 8 kHz. Reports:
  * centroid   - the spectrum's centre of mass (Hz), and its ratio to the first wav
  * bright     - energy 1-4 kHz relative to 80 Hz-1 kHz, in dB

Why this and not LPC formants: an LPC-12 formant reader was tried first and
FAILED ITS CONTROL (a half-speed copy of the take, whose resonances are
exactly halved, read F1 532 Hz vs 552 Hz — the reader tracked harmonics, not
resonances). This reader passes the same control: the half-speed copy reads
~0.54x the centroid and ~6 dB less brightness, so `--control` is built in.

    voicesize.py --control <reference.wav> <wav>...
        also writes and reads a half-speed copy of the reference (pitch AND
        voice size an octave down, the "slowed tape" giant), and fails loudly
        if its centroid ratio is not below 0.7.
"""
import sys
import numpy as np
import soundfile as sf


def ltas(path):
    x, sr = sf.read(path, always_2d=True)
    x = x.mean(axis=1)
    n, hop = 4096, 1024
    w = np.hanning(n)
    fr = [x[i:i + n] for i in range(0, len(x) - n, hop)]
    rms = np.array([np.sqrt(np.mean(f ** 2)) + 1e-12 for f in fr])
    gate = rms.max() * 10 ** (-30 / 20)
    S = np.mean([np.abs(np.fft.rfft(f * w)) ** 2 for f, r in zip(fr, rms) if r >= gate], axis=0)
    f = np.fft.rfftfreq(n, 1 / sr)
    m = (f >= 80) & (f <= 8000)
    P, F = S[m], f[m]
    cen = float((F * P).sum() / P.sum())
    hi = P[(F >= 1000) & (F <= 4000)].sum()
    lo = P[(F >= 80) & (F < 1000)].sum()
    return cen, float(10 * np.log10(hi / lo))


def main(argv):
    control = argv and argv[0] == "--control"
    paths = argv[1:] if control else argv
    if control:
        x, sr = sf.read(paths[0], always_2d=True)
        idx = np.arange(0, len(x) - 1, 0.5)
        y = np.stack([np.interp(idx, np.arange(len(x)), x[:, c]) for c in range(x.shape[1])], axis=1)
        cpath = paths[0].replace(".wav", ".halfspeed-control.wav")
        sf.write(cpath, y, sr)
        paths = paths + [cpath]
    ref = None
    for p in paths:
        cen, br = ltas(p)
        ref = ref or cen
        print(f"{p.split('/')[-1]:<40} centroid {cen:6.0f} Hz  x{cen / ref:4.2f}   bright {br:+5.1f} dB")
        if control and p == paths[-1] and cen / ref > 0.7:
            print("⛔ CONTROL FAILED: the half-speed copy did not read smaller — this reader is blind")
            sys.exit(3)


if __name__ == "__main__":
    main(sys.argv[1:])
