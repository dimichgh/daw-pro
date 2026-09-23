#!/usr/bin/env python3
"""Prove a pulsed piece's pulse is ACTUALLY THERE — with a control that can fail.

    python3 pulse-check.py cosmic-heartbeat cosmic-ascent 150
    python3 pulse-check.py cosmic-signal    cosmic-aurora 300
        (piece, control-without-the-pulse, low-band cutoff in Hz)

⛔⛔ WHY A SEPARATE GATE. `section-arc.py` reports cosmic-heartbeat and
cosmic-ascent as measuring within 0.2 LU of each other in EVERY section — which
is correct, and completely uninformative about the one thing that distinguishes
them. A loudness meter cannot see a pulse. If the pulse layer had silently
failed to render, every gate would still have passed and two "drastically
different" versions would have shipped as the same piece.

⭐ THE TEST: pull the low band as raw PCM, build a 50 ms RMS envelope, pick peaks,
and check the gaps cluster at the DESIGNED period — 2 beats at the piece's own
tempo. A real pulse gives tight, repeated gaps; a wash gives scattered ones.

⭐⭐ AND IT RUNS AGAINST A CONTROL. The control is the unpulsed sibling: same
form, same harmony, same instruments, minus the pulse track. If the same test
"finds" a pulse there too, the test is measuring the music rather than the pulse
and its positive result means nothing. MEASURED 2026-09-21:
    cosmic-heartbeat  16 peaks, median gap 1.90 s   (designed 1.905)
    cosmic-ascent      5 peaks, median gap 4.35 s   — scattered: 4.35 1.45 1.8 14.9

⚠ THE BAND IS AN ARGUMENT, NOT A CONSTANT, AND THAT IS DELIBERATE. heartbeat's
pulse sits on the bare root (MIDI 31-38 = 49-73 Hz); signal's is an octave up
(MIDI 43-50 = 98-147 Hz). A 150 Hz lowpass that isolates one would clip the
other's fundamental, and a gate that quietly measured the wrong band would report
a clean failure for a pulse that is plainly audible.
"""
import array
import json
import math
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
SR = 4000
WIN = 0.05


def envelope(wav, t0, dur, cutoff):
    raw = subprocess.run(
        ["ffmpeg", "-v", "quiet", "-ss", f"{t0}", "-t", f"{dur}", "-i", str(wav),
         "-af", f"lowpass=f={cutoff}", "-ac", "1", "-ar", str(SR), "-f", "s16le", "-"],
        capture_output=True).stdout
    a = array.array("h")
    a.frombytes(raw[:len(raw) // 2 * 2])
    n = int(SR * WIN)
    return [math.sqrt(sum(float(x) * x for x in a[i:i + n]) / n) + 1e-9
            for i in range(0, len(a) - n, n)]


def analyse(piece, t0, dur, cutoff):
    env = envelope(HERE / "out" / piece / f"{piece}.wav", t0, dur, cutoff)
    mean = sum(env) / len(env)
    depth = 20 * math.log10(max(env) / min(env))
    peaks = []
    for i in range(1, len(env) - 1):
        if env[i] > env[i - 1] and env[i] >= env[i + 1] and env[i] > 1.6 * mean:
            t = i * WIN
            if not peaks or t - peaks[-1] > 1.0:     # one impulse per cycle, not per ripple
                peaks.append(t)
    gaps = [round(peaks[i + 1] - peaks[i], 2) for i in range(len(peaks) - 1)]
    med = sorted(gaps)[len(gaps) // 2] if gaps else None
    return depth, peaks, gaps, med


def window(piece):
    """First section that carries the pulse, in seconds."""
    b = json.loads((HERE / "out" / piece / "build.json").read_text())
    spb = 60.0 / b["tempo"]
    for s in b["sections"]:
        if "pulse" in s["layers"]:
            return s["bar"] * 4 * spb, s["bars"] * 4 * spb, b["tempo"], s["name"]
    sys.exit(f"⛔ {piece}: no section carries a pulse layer")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    piece, control, cutoff = sys.argv[1], sys.argv[2], float(sys.argv[3])
    t0, dur, tempo, secname = window(piece)
    expect = 60.0 / tempo * 2        # div=2 beats

    print(f"{piece} — section '{secname}', {t0:.1f}s +{dur:.1f}s, "
          f"low band < {cutoff:.0f} Hz, designed period {expect:.3f} s")
    dp, pk, gp, md = analyse(piece, t0, dur, cutoff)
    print(f"  piece    depth {dp:5.1f} dB  peaks {len(pk):>3}  median gap "
          f"{md if md else '—'} s   gaps {gp[:10]}")
    cdp, cpk, cgp, cmd = analyse(control, t0, dur, cutoff)
    print(f"  control  depth {cdp:5.1f} dB  peaks {len(cpk):>3}  median gap "
          f"{cmd if cmd else '—'} s   gaps {cgp[:10]}   [{control}]")

    ok_period = md is not None and abs(md - expect) / expect < 0.10
    ok_count = len(pk) >= 0.6 * (dur / expect)
    # The control must NOT look like a pulse — otherwise the test proves nothing.
    ok_control = cmd is None or abs(cmd - expect) / expect > 0.15 or len(cpk) < 0.5 * len(pk)
    for label, ok in (("period matches design", ok_period),
                      ("enough impulses", ok_count),
                      ("control shows NO pulse", ok_control)):
        print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    print("\n" + ("✅ the pulse is present and audible" if all((ok_period, ok_count, ok_control))
                  else "⛔ THE PULSE DID NOT VERIFY"))
    sys.exit(0 if all((ok_period, ok_count, ok_control)) else 1)
