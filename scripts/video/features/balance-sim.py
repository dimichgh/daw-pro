#!/usr/bin/env python3
"""What would a level change do to ⑤, WITHOUT spending a 20-minute render?

⭐ THE WHOLE TRICK IS THAT STEMS SUM. `render.stems` bounces each force's bus
PRE-MASTER, and pre-master stems add back up to the pre-master mix exactly — the
app's own tool description says so, and it is why "mastered stems" are refused
there. So a proposed mix change can be auditioned by scaling one stem and
re-summing, instead of re-rendering the session to find out.

⛔ AND THAT IS A CLAIM, SO IT GETS CHECKED BEFORE IT GETS USED. The mixdown on
disk went through the master limiter; the stems did not. If the limiter is
working at all, the sum will NOT match the mixdown and every number this script
prints afterwards is fiction. So pass 1 always sums at unity and compares
against the real mixdown, per section, and the script REFUSES to simulate
anything if they disagree by more than --tolerance. A simulator that has not
been shown to reproduce the thing it simulates is a random number generator.

Usage:
  balance-sim.py <build.json> --force knowledge --db 0 2 3 4
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

FF = "ffmpeg"


def lufs(path, start, dur):
    """Integrated LUFS of one window, via ffmpeg's ebur128 summary.

    ⚠ `-v error` SUPPRESSES the summary this reads — it logs at INFO. This tree
    has lost measurements to that exact flag, so `-hide_banner` it is.
    """
    out = subprocess.run(
        [FF, "-nostdin", "-hide_banner", "-ss", f"{start:.3f}", "-t", f"{dur:.3f}",
         "-i", path, "-filter_complex", "ebur128=peak=true", "-f", "null", "-"],
        capture_output=True, text=True).stderr
    m = re.findall(r"I:\s*(-?\d+\.?\d*)\s*LUFS", out)
    return float(m[-1]) if m else None


def summed(stems, order, gains_db, out):
    """Sum the three stems, with `gains_db` applied per force."""
    args = [FF, "-nostdin", "-hide_banner", "-y"]
    for f in order:
        args += ["-i", stems[f]]
    parts, labels = [], []
    for i, f in enumerate(order):
        g = gains_db.get(f, 0.0)
        if g:
            parts.append(f"[{i}]volume={g}dB[g{i}]")
            labels.append(f"[g{i}]")
        else:
            labels.append(f"[{i}]")
    # normalize=0 is what makes this a SUM rather than an average — with
    # normalize=1 (the default) ffmpeg divides by the input count and every
    # level below would be wrong by the same 9.5 dB, which looks plausible.
    chain = ";".join(parts + ["".join(labels) + f"amix=inputs={len(order)}:normalize=0[m]"])
    args += ["-filter_complex", chain, "-map", "[m]", "-c:a", "pcm_s24le", out]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"⛔ ffmpeg sum failed: {r.stderr[-600:]}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("build")
    ap.add_argument("--force")
    ap.add_argument("--db", type=float, nargs="+")
    # ⚠ ONE FORCE AT A TIME WAS NOT ENOUGH, AND THE REASON IS THE POINT.
    # Sections SHARE layers, so lifting one force lifts every section that
    # borrows from it: +3 dB on knowledge fixed `apart` and broke `forces`,
    # because canonical's Consciousness section carries lattice and mind. A
    # balance question is therefore never about one number, and a tool that can
    # only move one number will keep proposing fixes that move the problem.
    ap.add_argument("--scenario", nargs="+", metavar="F=DB",
                    help="comma-separated per-force shifts, e.g. "
                         "'knowledge=+1,consciousness=-2'; repeatable")
    ap.add_argument("--tolerance", type=float, default=0.5,
                    help="LU disagreement between the stem sum and the real "
                         "mixdown above which this script refuses to simulate")
    ap.add_argument("--spread", type=float, default=4.0)
    a = ap.parse_args()

    b = json.load(open(a.build))
    stems = b.get("stems")
    if not stems:
        sys.exit("⛔ build has no stems")
    order = list(stems.keys())
    wav = b["wav"]
    spb = 4 * 60.0 / b["tempo"]

    # Each force's peak section window, straight from the build — never typed in.
    peak_of = {f: b["forces"][f]["peakSection"] for f in order}
    win = {}
    t = 0.0
    for s in b["sections"]:
        for f in order:
            if s["name"] == peak_of[f]:
                win[f] = (t, s["bars"] * spb)
        t += s["bars"] * spb

    tmp = tempfile.mkdtemp(prefix="balance-sim-")
    try:
        # ---- pass 1: does the sum reproduce the mixdown at all?
        print("── VALIDATING THE SIMULATOR (unity sum vs the real mixdown) ──")
        unity = summed(stems, order, {}, os.path.join(tmp, "unity.wav"))
        ok = True
        for f in order:
            s0, d = win[f]
            a_ = lufs(wav, s0, d)
            b_ = lufs(unity, s0, d)
            if a_ is None or b_ is None:
                sys.exit("⛔ ebur128 returned no summary — measurement failed")
            d_ = b_ - a_
            flag = "✔" if abs(d_) <= a.tolerance else "✘"
            print(f"  {f:<15} mixdown {a_:7.2f}   stem-sum {b_:7.2f}   "
                  f"{d_:+5.2f} LU  {flag}")
            ok = ok and abs(d_) <= a.tolerance
        if not ok:
            sys.exit(f"\n⛔ REFUSING TO SIMULATE — the stem sum does not "
                     f"reproduce the mixdown within {a.tolerance} LU, so the "
                     f"master chain IS changing levels here and a stem-domain "
                     f"prediction would not transfer to a real render.")
        print(f"\n✅ the sum reproduces the mixdown within {a.tolerance} LU — "
              f"the master chain is transparent at these levels, so a stem-"
              f"domain prediction will transfer.\n")

        # ---- pass 2: the actual question
        if a.scenario:
            cases = []
            for sc in a.scenario:
                d = {}
                for part in sc.split(","):
                    k, _, v = part.partition("=")
                    if k.strip() not in order:
                        sys.exit(f"⛔ unknown force '{k.strip()}' — have {order}")
                    d[k.strip()] = float(v)
                cases.append((sc, d))
        else:
            if not (a.force and a.db):
                sys.exit("⛔ pass either --force with --db, or --scenario")
            cases = [(f"{a.force}{g:+g}", {a.force: g}) for g in a.db]

        print("── SIMULATING ──")
        print(f"{'scenario':<34}  " + "  ".join(f"{f[:9]:>9}" for f in order)
              + f"   {'spread':>7}  verdict")
        for label, gains in cases:
            path = summed(stems, order, gains,
                          os.path.join(tmp, f"s{abs(hash(label))}.wav"))
            vals = {}
            for f in order:
                s0, d = win[f]
                vals[f] = lufs(path, s0, d)
            loud = max(vals.values())
            spread = loud - min(vals.values())
            verdict = "✔ within limit" if spread <= a.spread else "✘ too wide"
            print(f"{label:<34}  " + "  ".join(f"{vals[f]:>9.2f}" for f in order)
                  + f"   {spread:>7.2f}  {verdict}")
            os.remove(path)
    finally:
        for fn in os.listdir(tmp):
            try:
                os.remove(os.path.join(tmp, fn))
            except OSError:
                pass
        os.rmdir(tmp)


if __name__ == "__main__":
    main()
