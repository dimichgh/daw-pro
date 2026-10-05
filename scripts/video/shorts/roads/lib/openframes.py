#!/usr/bin/env python3
r"""⭐ OPEN FRAMES OF A FINISHED FILM, WITH THEIR TIMESTAMPS BURNED IN.

Round 31 did this by hand and the annotation carried a WRONG CAPTION into the
record ("the pattern break" on a frame that is the bass landing on C). A caption
is a claim; this file makes the mechanical part mechanical — index, time, bar —
and takes anything else as an argument you have to type deliberately.

⚠ FIRST AND LAST ARE ALWAYS INCLUDED, whatever you ask for: a film's opening
frame and its final frame are the two most likely to be wrong and the two least
likely to be sampled by a gate.

usage: openframes.py <framesdir> <payload.json> <outdir> [t|t:caption ...]
"""
import json, os, shutil, sys
from PIL import Image, ImageDraw, ImageFont

FRAMES, PAYLOAD, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
P = json.load(open(PAYLOAD))
FPS = 30
os.makedirs(OUT, exist_ok=True)
n = len([f for f in os.listdir(FRAMES) if f.startswith("f") and f.endswith(".png")])
bars = [b["t"] for b in P["bars"]]


def bar_at(t):
    k = sum(1 for b in bars if b <= t + 1e-9)
    return k if k else 0


asked = []
for a in sys.argv[4:]:
    t, _, cap = a.partition(":")
    asked.append((float(t), cap))
first, last = 0.0, (n - 1) / FPS
if not any(abs(t - first) < 1e-6 for t, _ in asked):
    asked.insert(0, (first, "the first frame"))
if not any(abs(t - last) < 1e-6 for t, _ in asked):
    asked.append((last, "the LAST frame"))

F = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 17)
print(f"{n} frames, {n/FPS:.3f}s at {FPS} fps; opening {len(asked)}")
for t, cap in sorted(asked):
    i = int(round(t * FPS))
    assert 0 <= i < n, f"t={t} -> frame {i}, outside 0..{n-1}"
    src = os.path.join(FRAMES, f"f{i:06d}.png")
    im = Image.open(src).convert("RGB")
    strip = Image.new("RGB", (im.width, 30), (0, 0, 0))
    d = ImageDraw.Draw(strip)
    line = f"t={i/FPS:8.3f}s   frame {i}/{n-1}   bar {bar_at(i/FPS)}" + (f"   {cap}" if cap else "")
    d.text((10, 6), line, font=F, fill=(255, 220, 160))
    canvas = Image.new("RGB", (im.width, im.height + 30))
    canvas.paste(strip, (0, 0)); canvas.paste(im, (0, 30))
    dst = os.path.join(OUT, f"t{i/FPS:07.3f}.png")
    canvas.save(dst)
    print(f"  {os.path.basename(dst):16s} <- {os.path.basename(src)}   {line}")
