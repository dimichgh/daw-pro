#!/usr/bin/env python3
"""clock-montage.py — the transport TIME readout from each take, at 0 s, 4 s and
8 s into the recording, in one labelled image for a person to READ.

    clock-montage.py <out.png> <burst>...

Why a person reads it: this machine has no OCR, and the clock in the frame is
the ground truth for "which song second is this frame" — the number every
take is trimmed by (sync-takes.py). Three readings per take, so a misread
digit shows up as a reading that disagrees with the other two (each later
reading must equal the first + its offset, within a frame).
"""
import os, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOX = (1000, 1672, 1235, 1752)          # TIME digits in a 2880x1800 take
TS = [0.0, 4.0, 8.0]
# CLOCK_FILE=clip.mp4 reads the TRIMMED takes (the sync proof); default raw.mp4.
SRC = os.environ.get("CLOCK_FILE", "raw.mp4")
out, bursts = sys.argv[1], sys.argv[2:]
w, h = BOX[2] - BOX[0], BOX[3] - BOX[1]
img = Image.new("RGB", (220 + w * len(TS), 30 + h * len(bursts)), (10, 14, 20))
d = ImageDraw.Draw(img)
font = ImageFont.load_default(size=22)
for j, t in enumerate(TS):
    d.text((220 + j * w + 10, 4), f"t = {t:g} s", fill=(200, 200, 200), font=font)
for i, b in enumerate(bursts):
    d.text((8, 30 + i * h + 25), b, fill=(255, 255, 255), font=font)
    for j, t in enumerate(TS):
        png = f"{HOME}/logs/_clk.png"
        r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{t}",
                            "-i", f"{HOME}/bursts/{b}/{SRC}", "-frames:v", "1", png],
                           capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"⛔ {b} @ {t}s: {r.stderr[-300:]}")
        img.paste(Image.open(png).crop(BOX), (220 + j * w, 30 + i * h))
img.save(out)
print(out)
