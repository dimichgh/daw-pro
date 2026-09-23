#!/usr/bin/env python3
"""Measure a rendered arrangement and ASSERT ITS PHYSICS.

WHY THIS ASSERTS STRUCTURE AND NOT JUST LOUDNESS:
the first render of `machine-room` measured -13.9 LUFS integrated -- a number
that reads as a healthy mix -- while true peak sat at +1.6 dBFS. The headline
metric was fine and the render was clipping. So this checks:

  1. TRUE PEAK, because a loudness meter does not look up.
  2. PER-SECTION level, because "it made sound" is not "it made the arrangement".
     A breakdown that is not quieter than the drop is not a breakdown, and a
     file of uniform noise would pass every loudness check ever written.

EXITS: 0 all assertions hold - 1 an assertion failed - 3 refused to score.
"""
import json
import os
import re
import subprocess
import sys

EXIT_OK, EXIT_FAIL, EXIT_CONTROL = 0, 1, 3


def die_control(msg):
    print(f"measure: CONTROL FAILED -- {msg}", file=sys.stderr)
    sys.exit(EXIT_CONTROL)


def run(args):
    # NOT `-v error`: that suppresses ebur128/astats, which log at INFO.
    # NOT paired with 2>/dev/null: an empty result must stay distinguishable
    # from a failed invocation.
    p = subprocess.run(args, capture_output=True, text=True)
    return p.stdout + p.stderr


def ebur128(path):
    out = run(["ffmpeg", "-hide_banner", "-nostats", "-i", path,
               "-af", "ebur128=peak=true", "-f", "null", "-"])
    # ⚠⚠ ANCHOR ON THE SUMMARY BLOCK, NEVER A BARE `I:`.
    # ebur128 also logs a PER-FRAME line every 100 ms ("t: 0.1 M: -70 S: -70
    # I: -70 LUFS LRA: 0 LU"). A bare re.search for `I:` therefore returns the
    # FIRST FRAME -- silence at t=0 -- which reads as a real measurement of
    # -70.0 LUFS. That is exactly what happened here: -70.0 LUFS and LRA 0.0 LU
    # were reported next to per-section RMS of -14 dB, and the assertions below
    # still said OK because nothing cross-checked the two instruments.
    m_i = re.search(r"Integrated loudness:\s*\n\s*I:\s*(-?[\d.]+)\s*LUFS", out)
    m_tp = re.search(r"True peak:\s*\n\s*Peak:\s*(-?[\d.]+)\s*dBFS", out)
    m_lra = re.search(r"Loudness range:\s*\n\s*LRA:\s*(-?[\d.]+)\s*LU", out)
    if not (m_i and m_tp and m_lra):
        die_control("could not parse the ebur128 SUMMARY block -- the parser is "
                    "broken or ffmpeg printed nothing (did someone add -v error, "
                    "which suppresses it?). Raw tail:\n" + out[-600:])
    return float(m_i.group(1)), float(m_tp.group(1)), float(m_lra.group(1))


def rms_db(path, start, dur):
    out = run(["ffmpeg", "-hide_banner", "-nostats", "-ss", str(start), "-t", str(dur),
               "-i", path, "-af", "astats=measure_perchannel=none", "-f", "null", "-"])
    m = re.search(r"RMS level dB:\s*(-?[\d.]+|-inf)", out)
    if not m:
        die_control(f"astats gave no RMS for {start}..{start+dur}s. Raw tail:\n" + out[-600:])
    v = m.group(1)
    return float("-inf") if v == "-inf" else float(v)


def bright_db(path, start, dur):
    """RMS of everything above 4 kHz -- a proxy for 'how open does this sound'.
    A filter sweep is a BRIGHTNESS gesture: it barely moves broadband RMS but
    moves this a lot. Checking only RMS would score a closed filter as a pass."""
    out = run(["ffmpeg", "-hide_banner", "-nostats", "-ss", str(start), "-t", str(dur),
               "-i", path, "-af", "highpass=f=4000,astats=measure_perchannel=none",
               "-f", "null", "-"])
    m = re.search(r"RMS level dB:\s*(-?[\d.]+|-inf)", out)
    if not m:
        die_control(f"astats gave no high-band RMS for {start}..{start+dur}s")
    v = m.group(1)
    return float("-inf") if v == "-inf" else float(v)


def main():
    if len(sys.argv) < 2:
        die_control("usage: measure.py <build.json>")
    bj = sys.argv[1]
    if not os.path.exists(bj):
        die_control(f"no build.json at {bj}")
    b = json.load(open(bj))
    wav = b["wav"]
    if not os.path.exists(wav) or os.path.getsize(wav) < 100_000:
        die_control(f"render missing or implausibly small: {wav}")

    spb = 60.0 / b["tempo"] * 4          # seconds per bar
    print(f"=== {b['title']} ===")
    print(f"{wav}  ({os.path.getsize(wav)/1e6:.1f} MB)")

    I, tp, lra = ebur128(wav)
    print(f"\nintegrated : {I:7.1f} LUFS")
    print(f"true peak  : {tp:7.1f} dBTP")
    print(f"LRA        : {lra:7.1f} LU")

    print("\nper-section (the arrangement, not the loudness):")
    print(f"  {'section':<11} {'window':>14}   {'RMS':>8} {'>4kHz':>8}")
    levels, bright = {}, {}
    for s in b["sections"]:
        start, dur = s["bar"] * spb, s["bars"] * spb
        levels[s["name"]] = rms_db(wav, start, dur)
        bright[s["name"]] = bright_db(wav, start, dur)
        print(f"  {s['name']:<11} {start:6.1f}s +{dur:5.1f}s   "
              f"{levels[s['name']]:7.1f} {bright[s['name']]:8.1f}")

    fails = []

    # 0. THE TWO INSTRUMENTS MUST AGREE. Integrated loudness and the per-section
    #    RMS measure the same file; if they disagree wildly, one of the two
    #    PARSERS is broken and neither number may be quoted. This check exists
    #    because a mis-anchored regex reported -70.0 LUFS beside -14 dB RMS and
    #    every other assertion below still passed.
    loud_sections = [v for v in levels.values() if v != float("-inf")]
    if loud_sections:
        coarse = max(loud_sections)
        if abs(I - coarse) > 20:
            die_control(
                f"integrated {I:.1f} LUFS vs loudest-section RMS {coarse:.1f} dB -- "
                f"these cannot both be right, so one parser is broken. REFUSING TO SCORE.")

    # 1. TRUE PEAK. The one that caught a clipping render behind a healthy LUFS.
    if tp > -0.5:
        fails.append(f"TRUE PEAK {tp:+.1f} dBTP exceeds -0.5 -- this will crunch when encoded")

    # 2. Nothing silent. A silent section is a build bug that every loudness
    #    check in the world would score as 'fine'.
    for name, v in levels.items():
        if v == float("-inf") or v < -50:
            fails.append(f"section '{name}' is effectively SILENT ({v:.1f} dB)")

    # 3. THE BREAKDOWN MUST BREAK DOWN. This is the invariance control: uniform
    #    noise passes every loudness metric and fails this one.
    if "Breakdown" in levels and "Drop" in levels:
        gap = levels["Drop"] - levels["Breakdown"]
        print(f"\nbreakdown is {gap:.1f} dB below the drop")
        if gap < 3.0:
            fails.append(f"breakdown only {gap:.1f} dB below the drop -- "
                         f"a listener will not hear it as a breakdown")

    # 3b. THE TRACK MUST BUILD. Added after a mix measured intro -14.3 dB against
    #     drop -14.2 dB: every loudness check passed and the arrangement was flat.
    #     Brightness is checked too, because a filter sweep is a BRIGHTNESS
    #     gesture and barely shows up in broadband RMS.
    if "Intro" in levels and "Drop" in levels:
        lift = levels["Drop"] - levels["Intro"]
        open_up = bright["Drop"] - bright["Intro"]
        print(f"drop is {lift:+.1f} dB louder and {open_up:+.1f} dB brighter than the intro")
        if lift < 1.5:
            fails.append(f"drop is only {lift:+.1f} dB above the intro -- the track does not build")
        if open_up < 6.0:
            fails.append(f"drop is only {open_up:+.1f} dB brighter than the intro -- "
                         f"the filter sweep is not doing its job")

    # 4. The second drop must not be a damp squib.
    if "Drop 2" in levels and "Drop" in levels:
        d = levels["Drop 2"] - levels["Drop"]
        print(f"drop 2 is {d:+.1f} dB vs drop 1")
        if d < -1.5:
            fails.append(f"Drop 2 is {d:.1f} dB BELOW Drop 1 -- the payoff goes backwards")

    if fails:
        print("\nFAIL:")
        for f in fails:
            print(f"  x {f}")
        sys.exit(EXIT_FAIL)
    print("\nOK -- true peak safe, no silent section, structure is audible.")
    sys.exit(EXIT_OK)


if __name__ == "__main__":
    main()
