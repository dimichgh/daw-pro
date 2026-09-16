#!/usr/bin/env python3
"""Pull the FINISHED FILM's frame at the instant each figure is spoken.

Stage starts are computed from the actual mux segment durations (out/timeline.json
went stale across rebuilds on Part 2 and is not trusted here); the within-stage
instants come from locate.py, which transcribed the stage's own wav.
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAN = json.load(open(f"{HERE}/out/manifest.json"))
S = f"{HERE}/out/segments"


def dur(p):
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                                 "format=duration", "-of", "default=nw=1:nk=1", p],
                                capture_output=True, text=True).stdout.strip())


start, t = {}, dur(f"{HERE}/out/intro.mp4")
for st in MAN["stages"]:
    for kind in ("talk", "play"):
        p = f"{S}/{st['id']}-{kind}-mux.mp4"
        if os.path.exists(p):
            start[f"{st['id']}-{kind}"] = t
            t += dur(p)
json.dump({"stageStarts": {k: round(v, 3) for k, v in start.items()},
           "totalFromSegments": round(t + dur(f"{HERE}/out/outro.mp4"), 3)},
          open(f"{HERE}/chapters.json", "w"), indent=1)

# (stage, within-stage seconds, what should be on screen)
CHECKS = [
    ("00-open", 22.0, "card01 WHO — written by an AI agent"),
    ("02-invisible", 45.0, "card03 GREP — exit 127"),
    ("04-quiet", 29.0, "comp-release-30"),
    ("04-quiet", 32.5, "comp-release-800"),
    ("05-listen", 20.0, "chart-pair"),
    ("07-meter", 46.0, "card06 BARS — the five frequencies"),
    ("08-before", 12.0, "card07 COUNT — 11 vs 5"),
    ("10-reveal", 16.0, "card08 AB — plus zero point zero zero"),
    ("10-reveal", 41.0, "card14 FROZEN — the still-image check"),
    ("12-pump", 20.0, "card10 PUMP — 6.45 three times"),
    ("13-close", 35.0, "card11 CLOSING — part four"),
]
os.makedirs(f"{HERE}/frames", exist_ok=True)
rows = []
for sid, off, want in CHECKS:
    at = start[f"{sid}-talk"] + off
    out = f"{HERE}/frames/{sid}_{off:.0f}.png"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-ss", f"{at:.3f}", "-i", f"{HERE}/out/HWB4.mp4",
                    "-frames:v", "1", "-vf", "scale=960:-1", out], check=True)
    rows.append((sid, off, round(at, 2), want, out))
    print(f"  {sid:14s} +{off:5.1f} -> film {at:7.2f}s  expect {want}")
# one contact sheet, so eleven frames can be looked at in one go
lst = f"{HERE}/frames/list.txt"
open(lst, "w").write("".join(f"file '{r[4]}'\n" for r in rows))
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat",
                "-safe", "0", "-i", lst, "-vf",
                "tile=3x4:padding=6:color=0x202632", "-frames:v", "1",
                f"{HERE}/frames/sheet.png"], check=True)
print(f"  contact sheet: {HERE}/frames/sheet.png")
