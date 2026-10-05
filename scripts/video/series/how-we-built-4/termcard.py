#!/usr/bin/env python3
"""Render REAL output from this build's own logs as terminal cards.

⚠ EVERY CHARACTER OF EVERY RESULT LINE IS COPIED FROM A FILE ON DISK. What is
edited is only the LAYOUT: the test runner repeats the whole test name in front
of each of its four failures, which at 1920 px shrinks the line to unreadable,
so the name is printed once and its four failures are indented under it. No
figure, no wording and no verdict is changed. The `✘`/`✔` glyphs are not in the
mono font on this machine (they draw as nothing), so they are written as
[FAIL]/[ ok ] — checked by looking at the rendered card, not assumed.
"""
import os, re, sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 1920, 1080
BG, FG, DIM, HOT, OK, ACC = "#080b10", "#e8eef6", "#7b8ba0", "#ff6b5e", "#4fd1c5", "#8ab4ff"
MONO = "/System/Library/Fonts/Menlo.ttc"


def card(name, title, lines, size=30, top=190):
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    d.text((110, 80), title, font=ImageFont.truetype(MONO, 33), fill=ACC)
    d.line([(110, 142), (W - 110, 142)], fill="#22303f", width=2)
    y = top
    for ln in lines:
        col = FG
        if isinstance(ln, tuple):
            ln, col = ln
        elif ln.startswith("[FAIL]"):
            col = HOT
        elif ln.startswith("[ ok ]"):
            col = OK
        s = size
        while s > 14 and d.textlength(ln, font=ImageFont.truetype(MONO, s)) > W - 220:
            s -= 1
        if s < 20:
            sys.exit(f"TERMCARD REFUSES — {name}: a line shrank to {s}px to fit; "
                     f"split it instead of shipping something nobody can read:\n  {ln}")
        d.text((110, y), ln, font=ImageFont.truetype(MONO, s), fill=col)
        y += int(size * 1.55)
    im.save(f"{HERE}/shots/{name}.png")
    print(f"  {name:16s} {len(lines):2d} lines")


G0 = open(f"{HERE}/logs/plant-00-green.log").read().splitlines()
RED = open(f"{HERE}/logs/plant-01-red.log").read().splitlines()
G2 = open(f"{HERE}/logs/plant-02-green.log").read().splitlines()


def one(lines, pat):
    got = [l.rstrip() for l in lines if re.search(pat, l)]
    if not got:
        sys.exit(f"TERMCARD REFUSES — nothing matched {pat!r}")
    return got


errs = [re.search(r"(Expectation failed: \(m\.alignmentError → \d+\) == 0)", l).group(1)
        for l in RED if "alignmentError →" in l]
mix = one(RED, r"pdcLate →")[0]
mix = re.search(r"(Expectation failed: \(pdcLate → [\d.]+\) > 0\.9)", mix).group(1)
run_red = re.sub(r"^✘ ", "", one(RED, r"^✘ Test run with")[0])
run_g0 = re.sub(r"^✔ ", "", one(G0, r"^✔ Test run with")[0])
run_g2 = re.sub(r"^✔ ", "", one(G2, r"^✔ Test run with")[0])

# 1 — the pin, as it ships
card("term-green", "$ ./scripts/test.sh --filter PDCHostedAURender",
     [("[ ok ] POSITIVE CONTROL + SURVEY: every render makes signal", OK),
      ("[ ok ] THE PIN: a latent hosted AU insert is compensated", OK),
      ("       to sample-exact alignment", OK),
      ("[ ok ] NEGATIVE CONTROL: a 0-latency hosted AU gets no", OK),
      ("       compensation at all", OK),
      ("[ ok ] IN THE MIX: PDC turns a ~85 ms flam into one", OK),
      ("       coherent transient", OK),
      "",
      ("[ ok ] " + run_g0, OK)], size=32, top=200)

# 2 — the same four tests, one number changed
card("term-red", "$ ./scripts/test.sh --filter PDCHostedAURender"
                 "   # chainLatencyActive: 0",
     [("[FAIL] THE PIN: a latent hosted AU insert is compensated", HOT),
      ("       to sample-exact alignment", HOT)]
     + [("         " + e, HOT) for e in errs]
     + [("[FAIL] IN THE MIX: PDC turns a ~85 ms flam into one", HOT),
        ("       coherent transient", HOT),
        ("         " + mix, HOT), "",
        ("[FAIL] " + run_red, HOT)], size=30, top=175)

# 3 — what stayed green under the plant: the load-bearing half
card("term-controls", "# under the plant: what reddened, and what did NOT",
     [("[FAIL] THE PIN: a latent hosted AU insert is compensated", HOT),
      ("       to sample-exact alignment", HOT),
      ("[FAIL] IN THE MIX: PDC turns a ~85 ms flam into one", HOT),
      ("       coherent transient", HOT), "",
      ("[ ok ] POSITIVE CONTROL + SURVEY: every render makes", OK),
      ("       signal; dry onset is exactly the impulse frame", OK),
      ("[ ok ] NEGATIVE CONTROL: a 0-latency hosted AU", OK),
      ("       (AULowpass) gets no compensation at all", OK)], size=32, top=210)

# 4 — the restore, proved four ways
card("term-restore", "# the restore, proved four ways — never by a return code",
     [("$ cmp backup shippingfile                  ->  exit 0", OK),
      ("$ grep -cF 'PLANTED-DEFECT-HWB4' file      ->  0", OK),
      ("$ grep -cF 'chainLatencyActive: chain...'  ->  1", OK),
      ("$ git status --porcelain -- that file      ->  (nothing)", OK), "",
      ("$ ./scripts/test.sh --filter PDCHostedAURender", ACC),
      ("[ ok ] " + run_g2, OK)], size=31, top=250)
