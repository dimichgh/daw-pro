#!/usr/bin/env python3
"""Does this audio really loop, and does it close the harmony?

    python3 verify-loop.py out/cosmic-ascent-5m/cosmic-ascent-5m-loop.wav
    python3 verify-loop.py out/cosmic-ascent-5m/video/x-short.mp4

⛔⛔ TWO EARLIER VERSIONS OF THIS FILE WERE BLIND, AND BOTH PRINTED ✅ FIRST.

  v1 measured SPECTRAL FLUX. Flux is frame-to-frame change, so it finds clicks
  and attacks — the easy failure. The failure that matters is harmonic: the loop
  restarting on the wrong chord. Under a 2-second crossfade, in music this slow,
  that produces almost no flux. The planted wrong-chord control passed on all
  five pieces.
  v2 compared BROAD BAND SPECTRA before and after the join, against the music's
  own spread. Too blunt: adjacent windows inside the piece straddle chord
  changes anyway, so the "normal" bar sat at 8-9 dB and a genuinely wrong chord
  (7 dB) hid underneath it. The control passed on four of five.

⭐⭐⭐ AND THE THIRD FRAMING WAS WRONG TOO, IN THE MOST INSTRUCTIVE WAY. I set out
to check that the loop "starts and ends on the same chord". It does not, and it
must not: an 8-bar window over an 8-bar cycle starts on chord N and ends on
chord N-1. What has to be true is that THE CHORD FOLLOWING THE END IS THE CHORD
AT THE START — which is the same statement as "the window is a whole number of
cycles", and is what actually makes the wrap inaudible. Measuring the thing I
first named would have rejected every correct loop I had just built.

WHAT IT MEASURES NOW:
  1. SILENCE — the shipped Shorts end in 2.4 s of digital zero (the outro card).
     Nothing else matters if that is true.
  2. HARMONIC CLOSURE — chroma (12 pitch classes, octaves folded) at the window
     start vs one loop-length later in the SOURCE. Controls: the same comparison
     at 7 and 4 bars, which are NOT whole cycles and must score far worse.
     Measured separation is 5-10x, so this one discriminates.
  3. CLICK — a sample step at the join larger than the music's own largest.
"""
import argparse
import json
import pathlib
import subprocess
import sys
import tempfile

import numpy as np
import soundfile as sf

NOTE = "C C# D D# E F F# G G# A A# B".split()


def load(path):
    p = pathlib.Path(path)
    if p.suffix.lower() in (".mp4", ".mov", ".m4a"):
        tmp = pathlib.Path(tempfile.mkdtemp()) / "a.wav"
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(p),
                        "-vn", "-c:a", "pcm_f32le", "-y", str(tmp)], check=True)
        p = tmp
    x, sr = sf.read(str(p), dtype="float64", always_2d=True)
    return x, sr


def chroma(x, sr):
    """Energy per pitch class, octaves folded. Restricted to A1-C7, where these
    pieces put their chords — including the sub octave would let one bass note
    dominate the vector and hide the harmony above it."""
    m = x.mean(axis=1) if x.ndim > 1 else x
    if len(m) < 2048:
        return None
    w = np.hanning(len(m))
    mag = np.abs(np.fft.rfft(m * w))
    fr = np.fft.rfftfreq(len(m), 1 / sr)
    sel = (fr > 55) & (fr < 2200)
    pc = (np.round(69 + 12 * np.log2(np.maximum(fr[sel], 1e-9) / 440.0)).astype(int)) % 12
    c = np.zeros(12)
    np.add.at(c, pc, mag[sel] ** 2)
    return c / max(c.sum(), 1e-12)


def cdist(a, b):
    return float(np.abs(a - b).sum())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--probe", type=float, default=1.5)
    args = ap.parse_args()

    path = pathlib.Path(args.path)
    x, sr = load(path)
    n = int(args.probe * sr)
    print(f"{path.name}   {len(x)/sr:.2f}s")

    fails = []

    # ---- 1. silence
    tail_db = 20 * np.log10(max(float(np.sqrt((x[-int(0.5 * sr):] ** 2).mean())), 1e-12))
    print(f"  last 0.5 s level        : {tail_db:.1f} dBFS")
    if tail_db <= -60:
        print("  ⛔ ENDS IN SILENCE — it cannot loop, whatever the music does")
        fails.append("silence")

    # ---- 3. click (cheap, do it before the expensive one)
    mono = np.concatenate([x, x], axis=0).mean(axis=1)
    d = np.abs(np.diff(mono))
    seam = abs(float(mono[len(x)]) - float(mono[len(x) - 1]))
    print(f"  sample step at the join : {seam:.6f}  (largest inside: {float(d.max()):.6f})")
    if seam > float(d.max()):
        print("  ⛔ CLICK at the join")
        fails.append("click")

    # ---- 2. harmonic closure, against the source
    meta_p = path.with_name(path.stem.replace("-short", "") + ".json")
    if not meta_p.exists():
        meta_p = path.with_suffix(".json")
    if meta_p.exists():
        meta = json.loads(meta_p.read_text())
        b = json.loads((path.parent / "build.json").read_text()) if (path.parent / "build.json").exists() \
            else json.loads((pathlib.Path(__file__).parent / "out" / meta["piece"] / "build.json").read_text())
        w = pathlib.Path(b["wav"])
        m = w.with_name(w.stem + "-master.wav")
        src, ssr = sf.read(str(m if m.exists() else w), dtype="float64", always_2d=True)
        bar = 4 * 60 / b["tempo"]
        t0 = meta["start_s"]
        nb = meta["bars"]

        def at(off_bars):
            s = int((t0 + off_bars * bar) * ssr)
            return chroma(src[s:s + int(args.probe * ssr)], ssr)

        a = at(0)
        good = cdist(a, at(nb))
        # ⛔ THE NEGATIVE CONTROL MUST NOT BE A WHOLE CHORD CYCLE. The cycle is
        # 8 bars (`cosmic-material.mjs`, indexed by ABSOLUTE bar), so ANY offset
        # that is a multiple of 8 closes the harmony correctly and is a POSITIVE
        # case, not a control. The old choice was `(nb-1, nb//2)`: fine at the
        # 8-bar default (7 and 4), but at 16 bars `nb//2` is 8 — a perfectly good
        # wrap being scored as a wrong offset. It made two genuinely-closing
        # 16-bar loops report "NO SEPARATION ... the harmony does not close".
        # ⭐ A CONTROL THAT IS SECRETLY A POSITIVE CASE TURNS A GATE INTO A LIAR.
        CYCLE = 8
        cand = [nb - 1, nb - 3, nb // 2 + 1, nb // 2 - 1, nb + 1, nb - 5]
        offs = [o for o in dict.fromkeys(cand) if o > 0 and o % CYCLE != 0][:2]
        if len(offs) < 2:
            sys.exit(f"⛔ cannot form two non-cycle controls for a {nb}-bar loop")
        ctrl = {o: cdist(a, at(o)) for o in offs}
        start_pc = NOTE[int(np.argmax(a))]
        end_pc = NOTE[int(np.argmax(at(nb - 1)))]
        print(f"  chord at start / last bar : {start_pc} / {end_pc}  "
              f"(different, and that is correct — see the header)")
        print(f"  chroma distance {nb} bars on : {good:.3f}   ← the wrap")
        for o, v in ctrl.items():
            print(f"                  {o:>2} bars on : {v:.3f}   (control, not a whole cycle)")
        worst_ctrl = min(ctrl.values())
        if good < worst_ctrl * 0.6:
            print(f"  ✅ the chord that follows the end IS the chord at the start — "
                  f"{worst_ctrl/max(good,1e-9):.1f}x closer than a wrong offset")
        else:
            print(f"  ⛔ NO SEPARATION from a wrong offset — the harmony does not close")
            fails.append("harmony")
    else:
        print("  (no -loop.json beside it — harmonic closure not checked)")

    print("  " + ("✅ LOOPS" if not fails else "⛔ FAILS: " + ", ".join(fails)))
    sys.exit(0 if not fails else 1)


if __name__ == "__main__":
    main()
