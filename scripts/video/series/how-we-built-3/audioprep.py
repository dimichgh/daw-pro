#!/usr/bin/env python3
"""Every wav the film plays, built here so the record describes the file the
viewer actually hears.

⚠ THE DEMONSTRATION PAIR IS NOT TOUCHED on its first pass. d3-release-fast.wav
and d3-release-slow.wav are the ACTUAL FILES that shipped inside the compressor
lesson's cut 1 — the demonstration the user could not hear. Playing a rebuilt
imitation of them would be exactly the kind of claim this film is about.

⚠ THE SECOND PASS APPLIES ONE SHARED STATIC GAIN to BOTH halves. Not loudnorm,
not per-file: `g` is the same number for both, so the relationship between the
two settings — which IS the demonstration — cannot move. Both play stages carry
`normalize: false`.
"""
import json, os, subprocess, sys
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
CA = "/Users/dsemenov/Views/daw-pro/scripts/video/comp/audio"
A = f"{HERE}/audio"
SR = 48000
LIFT_DB = None        # read from MEASUREMENTS.json below — ONE home for the number
MIX_TRIM_DB = 0.0     # ⚠ WAS -4.0 "for headroom". MEASURED 2026-09-05: the demo
                      # mix is 18 dB crest, so at -4 it played at -25.9 LUFS under a
                      # -16.4 LUFS film — 9.5 LU down, the quietest thing in the cut,
                      # and it was the FIRST "here it is working" moment. Setting
                      # normalize=True instead was tried and REJECTED: loudnorm got
                      # the segment to -16.0 but its peaks tripped assemble.py's
                      # true-peak backstop, which turned THE WHOLE FILM down 0.81 dB
                      # (measured window-by-window against the untrimmed build) to fix
                      # 30 seconds of it: -16.4/-1.5 became -17.1/-1.0. A static 0 dB
                      # here lands the play at -21.9 LUFS, peak -3.38 dBFS, no trim.
EXCERPT = 12.0        # the same twelve seconds the app footage shows

M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
LIFT_DB = float(M["pairLiftDb"])
out = {}


def rd(p):
    x, sr = sf.read(p, dtype="float64", always_2d=True)
    if sr != SR:
        sys.exit(f"{p} is {sr} Hz, expected {SR}")
    return x


def wr(name, x):
    sf.write(f"{A}/{name}", x.astype("float32"), SR, subtype="FLOAT")
    pk = 20 * np.log10(np.max(np.abs(x)) + 1e-12)
    rms = 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12)
    out[name] = {"seconds": round(len(x) / SR, 3), "peakDb": round(float(pk), 2),
                 "rmsDb": round(float(rms), 2)}
    print(f"  {name:24s} {len(x)/SR:6.2f}s  peak {pk:7.2f} dBFS  rms {rms:7.2f}")
    return x


# ── the project's own twelve seconds ──────────────────────────────────────────
mix = rd(f"{A}/mix-full.wav")[:int(EXCERPT * SR)]
g = 10 ** (MIX_TRIM_DB / 20)
wr("mix-clean.wav", mix * g)

# ── the demonstration that was correct and inaudible ──────────────────────────
f0, s0 = rd(f"{CA}/d3-release-fast.wav"), rd(f"{CA}/d3-release-slow.wav")
n = min(len(f0), len(s0))
f0, s0 = f0[:n], s0[:n]
wr("pair-fast.wav", f0)          # verbatim: what actually shipped
wr("pair-slow.wav", s0)
lift = 10 ** (LIFT_DB / 20)
wr("pair-fast-lift.wav", f0 * lift)
wr("pair-slow-lift.wav", s0 * lift)

# ⚠ PROVE THE SHARED GAIN DID NOT MOVE THE DEMONSTRATION. The whole point of one
# static gain is that the RELATIONSHIP survives; assert it rather than trusting it.
def env(x, ms=20.0):
    m = x.mean(axis=1)
    w = int(SR * ms / 1000)
    k = len(m) // w
    return 20 * np.log10(np.sqrt((m[:k * w].reshape(k, w) ** 2).mean(axis=1)) + 1e-12)


d_before = env(f0) - env(s0)
d_after = env(f0 * lift) - env(s0 * lift)
drift = float(np.max(np.abs(d_before - d_after)))
if drift > 1e-5:   # float64 log round-off, not a real move (measured 2.5e-7 dB)
    sys.exit(f"REFUSING — the shared gain moved the A/B by {drift} dB")
print(f"  shared gain {LIFT_DB:+.1f} dB moved the difference by {drift:.2e} dB "
      f"(round-off only)")

# ── the A/B whose two halves are ONE FILE ─────────────────────────────────────
# ⚠⚠ THIS IS THE DEFECT, ON PURPOSE, AND IT IS THE POINT OF ITS CHAPTER.
# verify.py now FAILS an `ab` block whose halves are the same audio, so this is
# built as two ordinary play stages sharing one `loop` path instead. It is
# deliberate; the narration reveals it inside the same chapter. Do NOT "fix" it.
same = rd(f"{A}/mix-clean.wav")[:int(6.0 * SR)]
wr("same-before.wav", same)
wr("same-after.wav", same)                  # byte-for-byte the same samples
a = sf.read(f"{A}/same-before.wav", dtype="float32")[0]
b = sf.read(f"{A}/same-after.wav", dtype="float32")[0]
if not np.array_equal(a, b):
    sys.exit("REFUSING — the two halves are supposed to be identical and are not")
print(f"  same-before vs same-after: identical samples "
      f"({np.abs(a - b).max():.1f} max difference) — deliberately")

json.dump(out, open(f"{HERE}/audio.json", "w"), indent=1)
