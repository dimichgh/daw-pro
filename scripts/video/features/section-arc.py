#!/usr/bin/env python3
"""Measure a Starlight piece SECTION BY SECTION and gate the claim that it develops.

    python3 section-arc.py cosmic-ascent [cosmic-heartbeat ...]

⛔⛔ WHY THIS EXISTS. "It develops from simple to complex" is a CLAIM, and the
film pass that preceded this work found nine defects that every gate written for
it passed clean — three of those gates were structurally INCAPABLE of failing.
A form table saying `layers: [pad]` then `layers: [pad, halo, voice, shimmer,
low, deep]` proves only what was ASKED FOR. This measures what came out.

It gates three things, and each one is written to be able to fail:

  ① THE LAYER GATE ACTUALLY DID SOMETHING. The section with the most layers must
     be at least 4 LU louder than the section with the fewest. If the two land
     within a couple of LU, the clips did not go where the table said and the
     piece is a wash with a filter moving over it — which is exactly what the
     earlier 40-bar versions were, and what this work exists to replace.

  ② THE DESIGNED DIP IS A DIP, NOT NOISE. Where the form table closes the filter
     (`to` < `filt`), measured brightness must actually fall. This is the one the
     brief calls "cosmic energies fluctuating", and it is the one most likely to
     be silently absent, because the same section ADDS low layers — energy rises
     while brightness falls, and only a two-axis measurement can see that.

  ③ NOTHING FELL BELOW AUDIBILITY. USER RULE: never ship a sound demo without
     checking it can BE heard. `collapse` deliberately ends dark; a piece whose
     last section measures −40 LUFS is not "atmospheric", it is broken.

⚠ BRIGHTNESS IS A RATIO, NOT A LEVEL — energy above 2 kHz RELATIVE to full band.
An absolute high-band figure would rise whenever the music merely got louder,
which would hide the very thing ② is looking for.

⚠ -hide_banner, NOT -v error: ebur128 and astats log their summaries at INFO, so
`-v error` prints nothing at all and every cell would read as a measurement that
came back empty. That mistake has already cost this repo 45 blank cells that
read as a real finding.
"""
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "out"


def ff(path, start, dur, pre_filters=""):
    """Return (integrated LUFS, RMS dB) for one slice."""
    chain = (pre_filters + "," if pre_filters else "") + "ebur128=peak=true,astats=metadata=0"
    p = subprocess.run(
        ["ffmpeg", "-hide_banner", "-ss", f"{start:.3f}", "-t", f"{dur:.3f}",
         "-i", str(path), "-af", chain, "-f", "null", "-"],
        capture_output=True, text=True)
    txt = p.stderr
    lufs = rms = None
    for m in re.finditer(r"^\s+I:\s+(-?[\d.]+) LUFS", txt, re.M):
        lufs = float(m.group(1))
    # ⚠ NO `^` ANCHOR. astats prefixes every line with "[Parsed_astats_1 @ 0x…] "
    # while ebur128's summary does not — an anchored pattern matched the LUFS
    # and silently returned None for every RMS, which surfaced as a formatting
    # crash rather than as a wrong number. It would have been far worse if the
    # column had simply printed 0.0.
    # The LAST match is astats' "Overall" block; the per-channel blocks precede it.
    for m in re.finditer(r"RMS level dB:\s+(-?[\d.]+|-?inf|nan)", txt):
        try:
            rms = float(m.group(1))
        except ValueError:
            rms = None
    return lufs, rms


def measure(piece):
    d = OUT / piece
    bj = d / "build.json"
    if not bj.exists():
        print(f"⛔ {piece}: no build.json"), sys.exit(1)
    b = json.loads(bj.read_text())
    # ⭐⭐ MEASURE WHAT SHIPS. `master-cosmic.sh` lifts every piece by 6-9 dB, and
    # the mastered file is what goes into the visualiser and onto the page — so
    # measuring the raw render was measuring an intermediate nobody hears.
    #
    # ⛔ THIS WAS NOT A THRESHOLD THAT NEEDED RELAXING, IT WAS THE WRONG FILE.
    # Proof, and it is the only reason this changed: `cosmic-b` — the version the
    # user listened to and approved — has a RAW opening of −41.5 LUFS, which is
    # exactly what the audibility gate was failing `cosmic-aurora` for. Mastered,
    # the same 27 seconds measure −34.0. A gate that fails the piece the user
    # already picked is not detecting a defect.
    #
    # `make-viz.sh` already had this rule ("PREFER THE MASTERED FILE") for the
    # same reason; the measurement side simply had not been given it.
    wav = d / f"{piece}-master.wav"
    src = "master"
    if not wav.exists():
        wav = d / f"{piece}.wav"
        src = "RAW — run master-cosmic.sh; levels below are ~7 dB under what ships"
    if not wav.exists():
        print(f"⛔ {piece}: no {piece}.wav and no {piece}-master.wav"), sys.exit(1)

    tempo = b["tempo"]
    spb = 60.0 / tempo                       # seconds per beat
    rows = []
    print(f"\n{'═' * 96}\n{b['title']}   {piece}   {b['bars']} bars @ {tempo} BPM"
          f"\nmeasuring: {wav.name}  [{src}]")
    print(f"{'section':<11}{'bars':>5}{'layers':>7}{'LUFS':>9}{'bright':>9}   arc")
    for s in b["sections"]:
        t0 = s["bar"] * 4 * spb
        dur = s["bars"] * 4 * spb
        lufs, full_rms = ff(wav, t0, dur)
        _, hi_rms = ff(wav, t0, dur, "highpass=f=2000")
        bright = (hi_rms - full_rms) if (hi_rms is not None and full_rms is not None) else None
        rows.append(dict(name=s["name"], bars=s["bars"], layers=len(s["layers"]),
                         lufs=lufs, bright=bright, hi=hi_rms,
                         filt=s["filt"], to=s["to"]))
    lo = min(r["lufs"] for r in rows)
    hi = max(r["lufs"] for r in rows)
    for r in rows:
        # a 40-column bar, scaled across this piece's own measured range
        n = int(round((r["lufs"] - lo) / max(hi - lo, 0.001) * 40))
        print(f"{r['name']:<11}{r['bars']:>5}{r['layers']:>7}{r['lufs']:>9.1f}"
              f"{r['bright']:>9.1f}   {'█' * n}")

    # ---------------------------------------------------------------- gates
    fails = []
    most = max(rows, key=lambda r: r["layers"])
    fewest = min(rows, key=lambda r: r["layers"])
    spread = most["lufs"] - fewest["lufs"]
    ok1 = spread >= 4.0
    print(f"\n① layer gate      {most['name']} ({most['layers']} layers) vs "
          f"{fewest['name']} ({fewest['layers']}) = {spread:+.1f} LU   "
          f"{'PASS' if ok1 else 'FAIL — the staging did not land'}")
    if not ok1:
        fails.append("layer gate")

    # ② every section whose filter CLOSES must get measurably darker than the
    #    section before it. Only sections with a predecessor can be judged.
    # ⛔⛔ THIS GATE JUDGES ON *ABSOLUTE* HIGH-BAND ENERGY, NOT ON THE RATIO, AND
    # THAT CHANGED 2026-09-21 BECAUSE THE RATIO RETURNED A CONFIDENT WRONG ANSWER.
    #
    # The ratio (high band RELATIVE to full band) is confounded by layer count.
    # `ascent-5m`'s `Drift` drops from seven layers to two — the sub and the low
    # octave both leave — so the full band falls FASTER than the treble and the
    # ratio RISES even as the music empties out. Measured, Ascent -> Drift:
    #     full band   -16.8 -> -27.5 dB   (10.7 dB quieter)
    #     high band   -30.5 -> -38.2 dB   ( 7.7 dB darker)   <- the truth
    #     ratio       -13.7 -> -10.8 dB   ( 2.9 dB BRIGHTER) <- the artifact
    # The gate failed a dip that is one of the largest gestures in the piece.
    #
    # ⚠ THE ORIGINAL RATIONALE FOR THE RATIO IS STILL ON THE RECORD ABOVE — "an
    # absolute high-band figure would rise whenever the music merely got louder"
    # — and it is a real risk, so this does not discard it: the ratio is still
    # measured and still PRINTED beside the verdict. It simply no longer decides.
    # Checked against the case that motivated it, `Depths`, absolute high band
    # falls -31.1 -> -36.1 dB while the section gets 7 LU LOUDER, so the absolute
    # figure catches the "thicker and darker at once" gesture correctly too.
    dips = [(i, r) for i, r in enumerate(rows) if i > 0 and r["to"] < r["filt"] - 0.15]
    if dips:
        ok2 = True
        for i, r in dips:
            prev = rows[i - 1]
            if r["hi"] is None or prev["hi"] is None:
                print(f"② dip             {r['name']}: high band unavailable — not judged")
                continue
            delta = r["hi"] - prev["hi"]
            ratio = (r["bright"] - prev["bright"]) if None not in (r["bright"], prev["bright"]) else float("nan")
            good = delta < -1.0
            ok2 &= good
            print(f"② dip             {r['name']} vs {prev['name']} = {delta:+.1f} dB high band "
                  f"(ratio {ratio:+.1f})   "
                  f"{'PASS' if good else 'FAIL — the dip is not audible'}")
        if not ok2:
            fails.append("brightness dip")
    else:
        print("② brightness dip  (no closing section in this form — not applicable)")

    ok3 = lo > -40.0
    print(f"③ audibility      quietest section {lo:.1f} LUFS   "
          f"{'PASS' if ok3 else 'FAIL — inaudible on a phone'}")
    if not ok3:
        fails.append("audibility")

    # ④ THE ARRIVAL MUST ARRIVE SOMEWHERE NEW.
    #
    # ⛔⛔ WHY THIS EXISTS, AND IT IS THE SAME LESSON AS THE NINE FILM DEFECTS:
    # gates ①②③ ALL PASS on a five-minute piece whose second climax is no
    # brighter than its first. ① measures layer spread (both climaxes are
    # `L.full`, so it is happy), ② only checks that DIPS darken, and ③ only
    # checks nothing is inaudible. A piece can therefore build to a peak at 2:45,
    # fall away, and build to an identical peak at 4:42 — which does not develop,
    # it REPEATS — and every gate reports success.
    #
    # MEASURED 2026-09-21: the first cut of `ascent-5m` had `Ascent` ending at
    # −0.06 and `Summit` at 0.00 on a −0.72…0.00 sweep. That is 92% versus 100%
    # open: the two climaxes were within a decibel of each other and the second
    # half of the piece was the first half again, longer.
    #
    # ⚠ IT ONLY APPLIES TO A RISING FORM. `collapse` peaks in its FIRST section
    # by design; demanding a bright arrival at the end would be demanding that it
    # stop being the inverted one. So the gate asks where the form's highest `to`
    # falls, and steps aside — saying so out loud — when it is not in the last
    # third.
    peak_i = max(range(len(rows)), key=lambda i: rows[i]["to"])
    if peak_i < len(rows) * 2 / 3:
        print(f"④ arrival         (peak section '{rows[peak_i]['name']}' is not in the "
              f"final third — inverted form, not applicable)")
    else:
        # ⛔⛔ TWO AXES, AND EITHER ONE SATISFIES IT — BECAUSE THE FAMILIES ARRIVE
        # DIFFERENTLY, AND A ONE-AXIS VERSION OF THIS GATE WAS WRONG.
        #
        # This gate first shipped judging LOUDNESS alone. Run against the five
        # already-approved 3½-minute pieces it failed `aurora` (-0.4 LU) and
        # `signal` (+0.1 LU) — both B-family, both fine. The reason is written
        # into develop.mjs above them: B-family has no low octave and no sub, so
        # there is no weight left to add, and its climax arrives by OPENING (the
        # filter) rather than by THICKENING. Aurora brightens 23 dB across its
        # arc while barely changing level. Demanding loudness of it is demanding
        # that it become a D-family piece.
        #
        # ⭐ That is the SAME mistake as the one ② had just been fixed for — one
        # metric, confounded for a whole family — and it was caught only by
        # running the new gate against work that was ALREADY APPROVED. A gate
        # validated solely on the thing it was written for proves nothing.
        #
        # ⚠ THRESHOLDS ARE PERCEPTUAL, NOT TUNED TO MAKE THIS BATCH PASS: ~1 LU
        # is about the smallest loudness step a listener reliably notices, and
        # ~2 dB of high band about the smallest colour change. An arrival that
        # clears neither is not an arrival, whatever the form table intended.
        peak = rows[peak_i]
        prev = rows[:peak_i]
        loud = [r for r in prev if r["lufs"] is not None]
        brite = [r for r in prev if r["hi"] is not None]
        if not loud or peak["lufs"] is None:
            print("④ arrival         (measurements unavailable — not judged)")
        else:
            lr = max(loud, key=lambda r: r["lufs"])
            lm = peak["lufs"] - lr["lufs"]
            hm, hr = None, None
            if brite and peak["hi"] is not None:
                hr = max(brite, key=lambda r: r["hi"])
                hm = peak["hi"] - hr["hi"]
            ok4 = (lm >= 1.0) or (hm is not None and hm >= 2.0)
            how = "louder" if lm >= 1.0 else ("brighter" if ok4 else "neither")
            hs = f", {hm:+.1f} dB vs {hr['name']}" if hm is not None else ""
            print(f"④ arrival         {peak['name']}: {lm:+.1f} LU vs {lr['name']}{hs}   "
                  f"{'PASS (' + how + ')' if ok4 else 'FAIL — the last climax is no bigger than an earlier one, on either axis'}")
            if not ok4:
                fails.append("arrival")

    print(f"\n{'✅ ' + piece + ' develops, measured' if not fails else '⛔ ' + piece + ' FAILED: ' + ', '.join(fails)}")
    return (not fails), rows, b


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    emit = "--json" in sys.argv

    # ⚠ THE DEFAULT GLOB ONLY PICKS UP THE DEVELOPED FORM, AND NOT BY NAME.
    # `cosmic-a/b/c/d` and the two long forms are built by cosmic.mjs, whose
    # sections carry `filt` but no `to` — running them here would KeyError.
    # ⛔ The tempting fix, `s.get("to", s["filt"])`, is the wrong one: it would
    # silently run the older pieces through a gate designed for a different
    # form and report a brightness-dip result that means nothing. Presence of
    # `to` IS the test for "this piece has a travelling sweep", so it is what
    # selects. Naming a piece explicitly still measures it, whatever its shape.
    def developed(p):
        bj = p / "build.json"
        if not bj.exists():
            return False
        try:
            return all("to" in s for s in json.loads(bj.read_text())["sections"])
        except Exception:
            return False

    pieces = args or sorted(p.name for p in OUT.glob("cosmic-*") if developed(p))
    if not pieces:
        sys.exit("no developed pieces found — name one explicitly to measure it anyway")
    results = {}
    payload = {}
    for p in pieces:
        ok, rows, b = measure(p)
        results[p] = ok
        # ⭐ THE REVIEW PAGE IS DRAWN FROM THIS, NOT FROM PROSE. Every number the
        # page shows is one this script measured off the shipped wav — so the
        # page cannot claim an arc the audio does not have, which is exactly the
        # mistake that put "all four are level-matched to −18 LUFS" in front of
        # the user over files measuring −19.5 / −19.6 / −18.9 / −18.0.
        payload[p] = dict(
            title=b["title"], subtitle=b["subtitle"], blurb=b["blurb"],
            family=b.get("family"), pulsed=b.get("pulsed"), power=b.get("power"),
            tempo=b["tempo"], bars=b["bars"], seconds=b.get("seconds"),
            notes=b.get("noteCounts", {}), passed=ok,
            sections=[dict(name=r["name"], bars=r["bars"], layers=r["layers"],
                           lufs=r["lufs"], bright=r["bright"],
                           filt=r["filt"], to=r["to"]) for r in rows],
            sweep=b["sweep"],
        )
    print(f"\n{'═' * 96}")
    for p, ok in results.items():
        print(f"  {'PASS' if ok else 'FAIL'}  {p}")
    if emit:
        dest = OUT / "page-data.json"
        dest.write_text(json.dumps(payload, indent=1))
        print(f"\nwrote {dest}  ({dest.stat().st_size} bytes, {len(payload)} pieces)")
    sys.exit(0 if all(results.values()) else 1)
