#!/usr/bin/env python3
"""Does this render actually contain three forces that take turns?

    python3 forces-gate.py out/cosmic-forces/build.json

⭐ WHY THIS EXISTS AND WHY `section-arc.py` COULD NOT DO IT.
That gate's ④ ARRIVAL test assumes a piece has ONE climax and asks whether it
lands in the final third. This piece has THREE, deliberately, at 18%, 40% and
70% of the way through — so `section-arc.py` would either report N/A or pick one
of them and judge the piece on it. A gate that says N/A on the exact property
the piece was built for is the incapable-of-failing pattern this pipeline has
produced three times already, so it gets a gate of its own instead.

⛔⛔⛔ THIS GATE MEASURES STEMS, NOT FREQUENCY BANDS, AND THAT COST TWO RENDERS.
The first two versions split the spectrum into a high, a mid and a low band and
called them stardust, knowledge and consciousness. It does not work. Not because
the boundaries were badly chosen — because KNOWLEDGE'S OWN INSTRUMENTS ARE
BRIGHT. A resonant square and a saw put strong harmonics above 800 Hz; they have
to, or the layer stops sounding like a voice. So in the Knowledge section the
"stardust band" read 35.0 dB while stardust's one surviving layer there was
filtered down to -0.88. The band was measuring BRIGHTNESS. Register and attack
are what separate these three; treble is not, and no boundary fixes that.

⭐ THE FIX IS TO STOP INFERRING. Each force owns a bus, each bus renders its own
stem, and "how much stardust is in this section" becomes a direct measurement of
stardust with nothing else in the file. A band is a proxy for a force; a stem IS
the force. ⚠ If the stems are missing this script REFUSES rather than falling
back to bands — a weaker measurement that reports the same ✔ is how a blind gate
gets shipped.

⭐⭐ THE CLAIMS, TAKEN STRAIGHT OUT OF THE USER'S SENTENCE.
  "3 main powerful, different tones"   → ① the three stems' own centroids are
                                           ordered bright → dark, by a margin
  "emerge at different point of time"  → ② three distinct first bars
  "go full force"                      → ③a it is the force you are HEARING
                                           there (largest share of the three),
                                           and ③b it is at its own LOUDEST there
  "one subsides and another emerges"   → ④ across each handover the two shares
                                           cross

⛔ ③ IS TWO CLAIMS AND SPLITTING THEM IS NOT PEDANTRY — IT IS A BUG THIS GATE
ALREADY HAD. An earlier version asked only whether a force's SHARE peaked in its
own section, and crowned "First Light" — six bars of ONE quiet layer — as
Knowledge's full-force moment at 96.6%, because when a single layer plays it
owns the mix by definition. Share alone cannot tell "this force has taken over"
from "nothing else is on". ③a uses share; ③b uses absolute energy; a section
passes only if both hold, and neither can be satisfied by the piece being empty.

⛔ LOUDNESS IS NOT COMPARED ACROSS FORCES, ONLY BOUNDED, AND IT IS READ OFF THE
MIX. K-weighting boosts above 2 kHz and cuts below 100, so CONSCIOUSNESS — the
biggest-sounding of the three — measures quietest in LUFS. The trap is "fixing"
that with gain until true peak blows. ⑤ only asks that no peak sits more than
`--lufs-spread` below the loudest. And it reads the MIXDOWN, never a stem:
stems are rendered pre-master, so they are the wrong file to judge delivery by.

⭐ EVERY RUN CARRIES TWO CONTROLS AND REFUSES TO SCORE IF EITHER MISBEHAVES.
  A · ROTATED LABELS — the same measurements, each force credited to the NEXT
      force's peak section. ③ must FAIL, or ③ is not reading the labels.
  B · IDENTICAL STEMS — all three forces replaced by the same noise. ③ must
      FAIL, or ③ would pass anything.
Both exist because `verify-loop.py` printed ✅ twice while blind, and the only
thing that ever caught it was a planted control that ran every single time.
"""
import argparse
import datetime as _dt
import json
import math
import os
import subprocess
import sys

import numpy as np
import soundfile as sf

WIN = 4096             # ~85 ms at 48 kHz — long enough to resolve 25 Hz
FULL = (25.0, 9000.0)  # DC and ultrasonic carry no musical claim


# ----------------------------------------------------------------- measuring
def profile(x, sr):
    """Mean in-band power and spectral centroid over `x`.

    Averaged across the whole slice — a Welch estimate of the section's mean
    spectrum, not a snapshot, which for a piece whose three filters are always
    moving would be a different number every time you asked.
    """
    n = len(x) // WIN * WIN
    if n < WIN:
        return None
    frames = x[:n].reshape(-1, WIN) * np.hanning(WIN)
    power = (np.abs(np.fft.rfft(frames, axis=1)) ** 2).mean(axis=0)
    freq = np.fft.rfftfreq(WIN, 1.0 / sr)
    m = (freq >= FULL[0]) & (freq <= FULL[1])
    total = power[m].sum()
    if total <= 0:
        return dict(energy=0.0, centroid=float("nan"))
    return dict(energy=float(total),
                centroid=float((freq[m] * power[m]).sum() / total))


def lufs(path, start, dur):
    """Integrated loudness of one slice, via the real meter.

    ⚠ `-hide_banner`, NOT `-v error`: ebur128 logs its summary at INFO and
    `-v error` deletes it, which is how this pipeline once read an empty result
    as a measurement. ⚠ `-nostdin` because ffmpeg reads stdin and this is called
    from inside a loop.
    """
    r = subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", "-ss", f"{start:.3f}",
         "-t", f"{dur:.3f}", "-i", path, "-af", "ebur128=peak=true",
         "-f", "null", "-"],
        capture_output=True, text=True)
    val = None
    for line in r.stderr.splitlines():
        s = line.strip()
        if s.startswith("I:") and "LUFS" in s:
            val = float(s.split()[1])
    return val


def measure(signals, sr, sections, names):
    """Per-section energy, share and centroid for each force's own stem."""
    energy = {f: {} for f in names}
    centroid = {f: {} for f in names}
    for s in sections:
        a, b = int(s["t0"] * sr), int(s["t1"] * sr)
        for f in names:
            p = profile(signals[f][a:b], sr)
            if p is None:
                sys.exit(f"⛔ section {s['name']} is shorter than one analysis window")
            energy[f][s["name"]] = p["energy"]
            centroid[f][s["name"]] = p["centroid"]
    share = {f: {} for f in names}
    for s in sections:
        tot = sum(energy[f][s["name"]] for f in names)
        for f in names:
            share[f][s["name"]] = energy[f][s["name"]] / tot if tot > 0 else 0.0
    return energy, share, centroid


# -------------------------------------------------------------------- claims
def claim_dominant(share, peak_of, names):
    """③a At its own peak, a force is the largest of the three."""
    rows, ok = [], True
    for f in names:
        sec = peak_of[f]
        here = {g: share[g][sec] for g in names}
        winner = max(here, key=here.get)
        passed = winner == f
        ok &= passed
        rows.append((f, sec, here, winner, passed))
    return ok, rows


def claim_full_force(energy, peak_of, names, margin_db):
    """③b At its own peak, a force is at its own maximum absolute energy."""
    rows, ok = [], True
    for f in names:
        want = peak_of[f]
        ranked = sorted(energy[f].items(), key=lambda kv: -kv[1])
        top = ranked[0][0]
        runner = next(v for s, v in ranked if s != want)
        got = energy[f][want]
        lead = 10 * math.log10(max(got, 1e-30) / max(runner, 1e-30))
        passed = (top == want) and (lead >= margin_db)
        ok &= passed
        rows.append((f, want, top, lead, passed))
    return ok, rows


def claim_handover(share, peak_of, order):
    """④ Across each handover the two shares CROSS.

    A is bigger at its own peak than at B's, and B is bigger at its own peak
    than at A's. That is what "one subsides as another emerges" means when you
    have to write it down.
    """
    rows, ok = [], True
    for a, b in zip(order, order[1:]):
        pa, pb = peak_of[a], peak_of[b]
        a_falls = share[a][pa] > share[a][pb]
        b_rises = share[b][pb] > share[b][pa]
        ok &= a_falls and b_rises
        rows.append((a, b, share[a][pa], share[a][pb], share[b][pa], share[b][pb],
                     a_falls and b_rises))
    return ok, rows


def claim_three(energy, share, peak_of, names, margin_db):
    o1, _ = claim_dominant(share, peak_of, names)
    o2, _ = claim_full_force(energy, peak_of, names, margin_db)
    return o1 and o2


# ------------------------------------------------------------------ controls
def control_rotated(energy, share, peak_of, names, margin_db):
    """A · credit each force with the NEXT one's peak section. ③ must FAIL."""
    rot = {f: peak_of[names[(i + 1) % len(names)]] for i, f in enumerate(names)}
    return not claim_three(energy, share, rot, names, margin_db)


def control_identical(sr, seconds, sections, names, peak_of, margin_db,
                      seed=20260922):
    """B · all three forces replaced by the SAME noise. ③ must FAIL."""
    rng = np.random.default_rng(seed)
    n = rng.standard_normal(int(sr * seconds)).astype(np.float32) * 0.1
    flat = {f: n for f in names}
    e, sh, _ = measure(flat, sr, sections, names)
    return not claim_three(e, sh, peak_of, names, margin_db)


# ---------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("build")
    ap.add_argument("--margin-db", type=float, default=1.5,
                    help="③b: a force's own peak must beat its next-best section "
                         "by this many dB (default 1.5)")
    ap.add_argument("--centroid-ratio", type=float, default=1.25,
                    help="①: each stem's centroid must exceed the next darker "
                         "force's by this factor (default 1.25)")
    ap.add_argument("--lufs-spread", type=float, default=4.0)
    ap.add_argument("--json", metavar="PATH",
                    help="write the measured figures here so a review page can "
                         "be generated from them instead of transcribing them")
    args = ap.parse_args()

    b = json.loads(open(args.build).read())
    wav = b["wav"]
    if not os.path.exists(wav):
        sys.exit(f"⛔ mixdown missing: {wav}")

    forces = b["forces"]
    names = sorted(forces, key=lambda f: forces[f]["emergeBar"])
    peak_of = {f: forces[f]["peakSection"] for f in names}

    # ⛔ NO STEMS, NO SCORE. Falling back to band analysis here would report the
    # same ✔ from a measurement already proven blind.
    stems = b.get("stems")
    if not stems:
        sys.exit("⛔ this build has no stems — re-render with forces.mjs so each "
                 "force bounces its own bus. This gate does not fall back to "
                 "frequency bands; that measurement was proven blind.")
    missing = [f for f in names if not os.path.exists(stems.get(f, ""))]
    if missing:
        sys.exit(f"⛔ stem files missing for: {missing}")

    spb = 4 * 60.0 / b["tempo"]
    sections = [dict(name=s["name"], t0=s["bar"] * spb, t1=(s["bar"] + s["bars"]) * spb)
                for s in b["sections"]]

    sig, sr = {}, None
    for f in names:
        y, r = sf.read(stems[f], dtype="float32", always_2d=True)
        sig[f] = y.mean(axis=1)
        sr = r if sr is None else sr
        if r != sr:
            sys.exit(f"⛔ stem {f} is {r} Hz, others are {sr} Hz")
    dur = min(len(sig[f]) for f in names) / sr
    print(f"{b['variant']}  ({b.get('coexist','?')})  mix {os.path.getsize(wav)/1e6:.0f} MB  "
          f"stems {dur:.1f}s @ {sr} Hz  {len(sections)} sections")
    print(f"measuring per-force STEMS (not bands): " + ", ".join(names))

    energy, share, centroid = measure(sig, sr, sections, names)

    hdr = ("section".ljust(15) + "".join(f"{f[:9]:>9}" for f in names)
           + "  │" + "".join(f"{f[:4]+' dB':>9}" for f in names) + "   mix cent")
    print("\n" + hdr)
    print("-" * len(hdr))
    for s in sections:
        n = s["name"]
        mark = " ".join(f[0].upper() for f in names if peak_of[f] == n)
        tot = sum(energy[f][n] for f in names)
        cen = (sum(centroid[f][n] * energy[f][n] for f in names) / tot) if tot > 0 else 0
        print(f"{n:<15}" + "".join(f"{share[f][n]*100:8.1f}%" for f in names)
              + "  │" + "".join(f"{10*math.log10(energy[f][n]+1e-30):9.1f}" for f in names)
              + f"{cen:11.0f}  {mark}")

    # ---- CONTROLS FIRST. A gate that scores before proving it can fail is a
    # gate whose ✅ means nothing, and this pipeline has shipped two of those.
    print("\ncontrols")
    ctl_a = control_rotated(energy, share, peak_of, names, args.margin_db)
    ctl_b = control_identical(sr, dur, sections, names, peak_of, args.margin_db)
    print(f"  A rotated labels   → claim ③ {'rejects (good)' if ctl_a else 'ACCEPTS — BLIND'}")
    print(f"  B identical stems  → claim ③ {'rejects (good)' if ctl_b else 'ACCEPTS — BLIND'}")
    if not (ctl_a and ctl_b):
        sys.exit("\n⛔ REFUSING TO SCORE — a control passed, so this gate is not "
                 "measuring what it claims to measure. Fix the gate, not the piece.")

    fails = []

    # ---- ① different tones, measured on each force ALONE
    print("\n① THREE DIFFERENT TONES — each stem's own centroid, bright → dark")
    prev = None
    for f in names:
        c = centroid[f][peak_of[f]]
        note = ""
        if prev is not None:
            ratio = prev / c
            note = f"  {ratio:.2f}× darker than the one before"
            if ratio < args.centroid_ratio:
                fails.append(f"① {f}: only {ratio:.2f}× darker than the force before it "
                             f"(need {args.centroid_ratio}×) — not distinct tones")
                note += "  ✘"
        print(f"  {f:<15} at '{peak_of[f]}'  centroid {c:7.0f} Hz{note}")
        prev = c

    # ---- ② distinct emergence
    print("\n② EMERGE AT DIFFERENT TIMES")
    bars = {f: forces[f]["emergeBar"] for f in names}
    for f in names:
        print(f"  {f:<15} first bar {bars[f]:3d}   ({bars[f]*spb:6.1f} s)")
    if len(set(bars.values())) != len(names):
        fails.append(f"② forces do not emerge at distinct bars: {bars}")

    # ---- ③a dominance
    _, rows = claim_dominant(share, peak_of, names)
    print("\n③a IT IS THE FORCE YOU HEAR THERE — largest of the three")
    for f, sec, here, winner, passed in rows:
        others = "  ".join(f"{g[:4]} {here[g]*100:.0f}%" for g in names if g != f)
        print(f"  {f:<15} '{sec}' {here[f]*100:5.1f}%   vs {others}   {'✔' if passed else '✘'}")
        if not passed:
            fails.append(f"③a {f}: in its own section '{sec}' the ear is on {winner}, not {f}")

    # ---- ③b full force
    _, rows = claim_full_force(energy, peak_of, names, args.margin_db)
    print("\n③b AND IT IS AT ITS OWN LOUDEST THERE")
    for f, want, top, lead, passed in rows:
        print(f"  {f:<15} '{want}' leads its next-best section by {lead:+5.1f} dB   "
              f"(max is '{top}')   {'✔' if passed else '✘'}")
        if not passed:
            # ⚠ TWO DISTINCT FAILURES LIVE HERE AND ONE MESSAGE CANNOT SAY BOTH.
            # The first draft always printed "biggest in X, not its named Y",
            # which reads as gibberish — "biggest in 'Stardust', not its named
            # 'Stardust'" — in the case that actually fires most often: the
            # force IS biggest where it should be, but not by enough to call it
            # a peak rather than a plateau. Naming the wrong cause sends the
            # next fix at the wrong thing.
            if top != want:
                fails.append(f"③b {f}: biggest in '{top}', not in its named "
                             f"peak '{want}' — the form puts its full force "
                             f"somewhere else")
            else:
                fails.append(f"③b {f}: peaks in the right section '{want}' but "
                             f"only leads the next-best by {lead:+.1f} dB "
                             f"(needs {args.margin_db}) — it plateaus rather "
                             f"than peaking")

    # ---- ④ handover
    _, hrows = claim_handover(share, peak_of, names)
    print("\n④ ONE SUBSIDES AS ANOTHER EMERGES — the shares cross")
    for a, bb, a_at_a, a_at_b, b_at_a, b_at_b, passed in hrows:
        print(f"  {a} → {bb}")
        print(f"      {a:<14} {a_at_a*100:5.1f}% → {a_at_b*100:5.1f}%   "
              f"{'falls ✔' if a_at_a > a_at_b else 'DOES NOT FALL ✘'}")
        print(f"      {bb:<14} {b_at_a*100:5.1f}% → {b_at_b*100:5.1f}%   "
              f"{'rises ✔' if b_at_b > b_at_a else 'DOES NOT RISE ✘'}")
        if not passed:
            fails.append(f"④ handover {a}→{bb} does not cross")

    # ---- ⑤ no peak left behind — READ OFF THE MIX, never a pre-master stem
    print("\n⑤ ALL THREE ARE POWERFUL — no peak far below the others (mixdown)")
    peaks = {}
    for f in names:
        s = next(s for s in sections if s["name"] == peak_of[f])
        peaks[f] = lufs(wav, s["t0"], s["t1"] - s["t0"])
    if any(v is None for v in peaks.values()):
        fails.append("⑤ ebur128 returned no summary — measurement failed, not the music")
    else:
        loudest = max(peaks.values())
        for f in names:
            d = peaks[f] - loudest
            print(f"  {f:<15} {peaks[f]:6.1f} LUFS   {d:+5.1f} LU vs loudest  "
                  f"{'✔' if d >= -args.lufs_spread else '✘'}")
            if d < -args.lufs_spread:
                fails.append(f"⑤ {f} peaks {abs(d):.1f} LU below the loudest force "
                             f"(limit {args.lufs_spread}) — it does not arrive")

    # ---- the sidecar: what the REVIEW PAGE is allowed to claim
    # ⭐ THE PAGE MUST NOT HAND-COPY A SINGLE NUMBER FROM THIS OUTPUT. Every
    # figure a reader sees has to come from the run that measured it, or it
    # rots the next time a form changes and nobody notices the page is now
    # describing a piece that no longer exists. `build.json` already carries
    # the form; this carries the measurement, so the page can be generated
    # from the two and never from memory.
    if args.json:
        _, b3 = claim_full_force(energy, peak_of, names, args.margin_db)
        json.dump({
            "variant": b["variant"],
            "passed": not fails,
            "fails": fails,
            "marginDb": args.margin_db,
            "peakOf": peak_of,
            "emergeBar": bars,
            "emergeSeconds": {f: round(bars[f] * spb, 1) for f in names},
            "centroidHz": {f: round(centroid[f][peak_of[f]], 1) for f in names},
            "shareAtOwnPeak": {f: round(share[f][peak_of[f]], 4) for f in names},
            "fullForceLeadDb": {r[0]: round(r[3], 2) for r in b3},
            "peakLufs": {f: round(peaks[f], 2) for f in names
                         if peaks.get(f) is not None},
            "sectionShare": {s["name"]: {f: round(share[f][s["name"]], 4)
                                         for f in names} for s in sections},
            "at": _dt.datetime.now().isoformat(timespec="seconds"),
        }, open(args.json, "w"), indent=2)
        print(f"\nwrote measurement sidecar → {args.json}")

    print("\n" + "=" * 66)
    if fails:
        print(f"✘ {b['variant']} FAILS {len(fails)} check(s):")
        for f in fails:
            print(f"   • {f}")
        sys.exit(1)
    print(f"✔ {b['variant']} — three forces, three tones, three arrivals, two handovers.")


if __name__ == "__main__":
    main()
