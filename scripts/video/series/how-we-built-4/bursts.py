#!/usr/bin/env python3
"""Every MOVING shot as a burst directory (numbered frames + meta.json).
sweep.py writes flam-together/flam-apart; this handles the rest.

⚠⚠ `play-arrange` IS NOT FILMED IN THIS BUILD, AND THAT IS DECLARED EVERYWHERE.
The user's screen was LOCKED for the whole of this build ("Display 1 Shield" in
the capturable-window list), and a locked screen delivers no changed frames to
ScreenCaptureKit — screenrec honestly reported "ZERO frames captured" three
times rather than writing a valid-looking empty file. I will not unlock someone
else's screen. So the 30 fps footage is Part 3's recording OF THIS SAME PROJECT
ON THIS SAME STAGING APP, made earlier the same day; NOTES.md and the
description both say so.

⭐ What IS filmed in this build is `slowcap`: debug.captureUI in a loop while
the transport rolled, at its real measured rate. That is not a fallback dressed
as footage — it is the §5 limitation itself, and the film says the number.
"""
import json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUR, MAN = f"{HERE}/bursts", f"{HERE}/manim/videos/anim/1080p60"
P3 = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-3"
FPS = 30
TRIM = 1.535   # MEASURED by Part 3 on this same file; see its NOTES.md

SRC = [("play-arrange", f"{P3}/media/play-arrange.mp4", TRIM, 12.0),
       ("vacuous",      f"{MAN}/Vacuous.mp4",           0.0,  None),
       ("falsify",      f"{MAN}/Falsify.mp4",           0.0,  None)]


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"FAILED: {' '.join(cmd[:9])}\n{p.stderr[-1500:]}")


out = json.load(open(f"{HERE}/bursts.json")) if os.path.exists(f"{HERE}/bursts.json") else {}
for name, src, ss, dur in SRC:
    if not os.path.exists(src):
        sys.exit(f"missing source for burst {name}: {src}")
    d = f"{BUR}/{name}"
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    if ss:
        cmd += ["-ss", str(ss)]
    cmd += ["-i", src]
    if dur:
        cmd += ["-t", str(dur)]
    cmd += ["-vf", f"fps={FPS},scale=1920:1080:flags=lanczos", f"{d}/f%04d.png"]
    run(cmd)
    n = len([f for f in os.listdir(d) if f.startswith("f") and f.endswith(".png")])
    if n < 30:
        sys.exit(f"burst {name}: only {n} frames")
    json.dump({"fps": FPS, "frames": n, "seconds": round(n / FPS, 3)},
              open(f"{d}/meta.json", "w"), indent=1)
    out[name] = round(n / FPS, 3)
    print(f"  {name:16s} {n:4d} frames  {n/FPS:6.2f}s")

# ── slowcap: what 3 frames a second actually looks like ──────────────────────
SC = json.load(open(f"{HERE}/slowcap.json"))
d = f"{BUR}/slowcap"
shutil.rmtree(d, ignore_errors=True)
os.makedirs(d)
stamps = SC["stamps"]
secs = SC["spanSeconds"]
frames = int(round(secs * FPS))
src_dir = f"{HERE}/media/slowcap"
# Each captured still is HELD until the next one's timestamp — which is exactly
# what the viewer would have seen. Nothing is interpolated; the stutter is real.
k = 0
for f in range(frames):
    t = f / FPS
    while k + 1 < len(stamps) and stamps[k + 1]["t"] <= t:
        k += 1
    srcp = f"{src_dir}/c{stamps[k]['i']:04d}.png"
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", srcp,
         "-vf", "scale=1920:1080:flags=lanczos", f"{d}/f{f:04d}.png"])
json.dump({"fps": FPS, "frames": frames, "seconds": round(frames / FPS, 3)},
          open(f"{d}/meta.json", "w"), indent=1)
out["slowcap"] = round(frames / FPS, 3)
print(f"  {'slowcap':16s} {frames:4d} frames  {frames/FPS:6.2f}s "
      f"from {len(stamps)} real captures at {SC['fps']} fps")
json.dump(out, open(f"{HERE}/bursts.json", "w"), indent=1)
