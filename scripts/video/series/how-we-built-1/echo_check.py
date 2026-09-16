#!/usr/bin/env python3
"""Measure the narration wash — the "self-feeding echo" a listener reported.

    python3 echo_check.py out/vo/*.wav

WHAT IT MEASURES. Chop the take into fifths; inside each fifth take the 10th
percentile of 20 ms RMS frames, in dBFS. That is the GAP FLOOR: how quiet the
quiet parts are. A clean take holds its floor for the whole take. An affected
one climbs, until the pauses are only ~20 dB under the voice and you can hear a
wash sitting behind it.

WHY THIS METRIC AND NOT LOUDNESS. Integrated loudness, peak and LUFS are all
essentially IDENTICAL between an affected take and a clean one -- the voice is
the voice. The difference lives entirely in the silence, which is why every
meter already in the pipeline scored the bad audio healthy.

THE CONTROLLED PAIR IT WAS BUILT ON (same 1,432 characters, one take vs two):
    1,432 ch, ONE take   58.1 s   -50.3 -42.2 -33.1 -28.8 -28.3
      715 ch, take A     31.7 s   -45.4 -50.3 -49.3 -43.2 -41.8
      716 ch, take B     31.5 s   -42.1 -68.6 -46.9 -47.1 -40.3

⚠ CONFOUNDS, because this is a proxy and not a mechanism. (1) In a dense
passage with few pauses the 10th percentile lands on speech, so one fifth can
read high innocently. (2) A quiet lead-in makes the FIRST fifth read very low
and inflates any "rise" figure -- 10-fader rose 40.8 dB and is perfectly clean.
READ THE LAST FIFTH'S ABSOLUTE VALUE, which is what the gate does; the rise is
printed for interest only. (3) Nothing here shows WHY the floor climbs.
"self-feeding echo" is the listener's name for the sound, not a mechanism.

THRESHOLD: last fifth at or below -38.0 dBFS. Known-clean takes measure -40 to
-60; known-affected ones -24 to -35.
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from shortsmith import echo_floor, ECHO_FLOOR_DB          # ONE definition, shared
import wave

paths = sys.argv[1:] or sorted(
    os.path.join("out/vo", f) for f in os.listdir("out/vo") if f.endswith(".wav"))
bad = 0
print(f"{'take':<26} {'chars':>6} {'secs':>6} {'peak':>6}  gap floor per fifth (dBFS)"
      f"        last   verdict")
for p in paths:
    w = wave.open(p); secs = w.getnframes() / w.getframerate(); w.close()
    txt = p[:-4] + ".txt"
    n = len(open(txt).read()) if os.path.exists(txt) else 0
    peak, fl = echo_floor(p)
    ok = fl[-1] <= ECHO_FLOOR_DB
    bad += 0 if ok else 1
    print(f"{os.path.basename(p):<26} {n:>6} {secs:>6.1f} {peak:>6.1f}  "
          + " ".join(f"{x:6.1f}" for x in fl)
          + f"  {fl[-1]:6.1f}   {'ok' if ok else 'WASH'}")
print(f"\n{len(paths) - bad}/{len(paths)} takes at or under {ECHO_FLOOR_DB} dBFS")
sys.exit(1 if bad else 0)
