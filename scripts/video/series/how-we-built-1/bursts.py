#!/usr/bin/env python3
"""Turn the screen recording + the driver's log into BURSTS with the wire
messages composited back on, and render the manim scenes into bursts too.

⭐ THE OVERLAY IS THE FILM'S PROOF. `drive.mjs` recorded the exact text of every
message it sent and the instant it sent it; screenrec recorded the app. This
puts them in the same frame, so the viewer sees the message and the reaction
together instead of being asked to believe they are related.

⚠ THE OFFSET IS MEASURED, NOT ASSUMED. The recorder and the driver started
independently. `calibrate()` finds the frames where the track headers change,
matches them to the driver's own `track.add` timestamps, and refuses to build
if the five offsets disagree by more than 60 ms — which is the only thing that
stops a message being drawn over the wrong reaction.
"""
import json, os, shutil, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = f"{HERE}/bursts/drive-raw"
BUR = f"{HERE}/bursts"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
SF = "/System/Library/Fonts/SFNS.ttf"
A = (130, 205, 255)          # the "theory" accent, matching the cards
DIM = (150, 158, 175)
PY = sys.executable
FPS_OUT = 30


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        sys.exit(f"FAILED: {' '.join(cmd[:8])}\n{p.stdout[-1200:]}\n{p.stderr[-2000:]}")
    return p.stdout


def frames_and_pts():
    fs = sorted(f for f in os.listdir(RAW) if f.startswith("f") and f.endswith(".png"))
    pts = [float(l.split(",")[0]) for l in open(f"{HERE}/media/drive-pts.csv") if l.strip()]
    if len(fs) != len(pts):
        sys.exit(f"{len(fs)} frames but {len(pts)} timestamps")
    return fs, pts


def calibrate(fs, pts, log):
    """recording_time = driver_time + offset, measured five independent ways."""
    prev, events = None, []
    for i, f in enumerate(fs):
        a = np.asarray(Image.open(f"{RAW}/{f}").convert("L").crop((0, 220, 600, 900)),
                       dtype=np.float32)
        if prev is not None and float(np.abs(a - prev).mean()) > 0.75:
            events.append(pts[i])
        prev = a
    adds = [e["at"] for e in log if e["text"].startswith("track.add")]
    # the track.add events are the FIRST of each 2.2 s pair; take one per pair
    picked, last = [], -9
    for t in events:
        # ⚠ `last` ADVANCES ONLY ON A PICK. Advancing it on every event made the
        # 0.9 s clip.addMIDI flash push the window past the next track.add, and
        # five events collapsed to three — a calibration that fails LOUDLY only
        # because the count is asserted against the driver's own log.
        if t - last > 1.5:
            picked.append(t)
            last = t
    picked = [t for t in picked if t > 4.0][:len(adds)]
    if len(picked) != len(adds):
        sys.exit(f"calibration: {len(picked)} header events for {len(adds)} track.add")
    offs = [p - a for p, a in zip(picked, adds)]
    spread = max(offs) - min(offs)
    print("  calibration offsets: " + ", ".join(f"{o:.3f}" for o in offs)
          + f"   spread {spread*1000:.0f} ms")
    if spread > 0.060:
        sys.exit("REFUSING: the recorder and the driver do not agree to 60 ms — "
                 "the overlay would be drawn over the wrong reaction")
    return sum(offs) / len(offs)


def draw_msg(im, text, age):
    """The wire message, bottom-left, where the corner meter is not."""
    d = ImageDraw.Draw(im, "RGBA")
    fh = ImageFont.truetype(MONO, 21)
    fm = ImageFont.truetype(MONO, 27)
    w = max(d.textlength(text, font=fm), 430) + 56
    x0, y0, h = 44, im.height - 214, 104
    fade = 1.0 if age < 1.3 else max(0.0, 1.0 - (age - 1.3) / 0.6)
    al = int(235 * fade)
    d.rounded_rectangle([x0, y0, x0 + w, y0 + h], 12, fill=(9, 13, 20, int(232 * fade)),
                        outline=A + (int(150 * fade),), width=2)
    d.text((x0 + 26, y0 + 16), "SENT OVER THE CONTROL SOCKET", font=fh,
           fill=DIM + (al,))
    d.text((x0 + 26, y0 + 52), text, font=fm, fill=A + (al,))


def make_burst(name, t_from, t_to, fs, pts, log, offset, overlay=True):
    d = f"{BUR}/{name}"
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d)
    idx = [i for i, t in enumerate(pts) if t_from <= t <= t_to]
    n = 0
    for i in idx:
        im = Image.open(f"{RAW}/{fs[i]}").convert("RGB")
        if overlay:
            t = pts[i] - offset                      # back into DRIVER time
            cur = [e for e in log if e["at"] <= t and t - e["at"] < 1.9]
            if cur:
                e = cur[-1]
                draw_msg(im, e["text"], t - e["at"])
        n += 1
        im.save(f"{d}/f{n:04d}.png")
    secs = pts[idx[-1]] - pts[idx[0]]
    fps = n / secs
    json.dump({"fps": round(fps, 4), "frames": n, "seconds": round(secs, 3)},
              open(f"{d}/meta.json", "w"), indent=1)
    shutil.copyfile(f"{d}/f{n:04d}.png", f"{HERE}/shots/{name}-final.png")
    shutil.copyfile(f"{d}/f{max(1, n//2):04d}.png", f"{HERE}/shots/{name}-mid.png")
    print(f"  burst {name:14s} {n:4d} frames  {secs:6.2f}s  {fps:.2f} fps")
    return secs


def plain(mp4, name, ss, t):
    """A screen recording straight into a burst — no overlay, no manim.

    ⚠ screenrec writes ONLY frames whose content changed, so the file's frame
    rate is not its nominal one. The meta records the MEASURED rate (frames
    divided by the trimmed duration) rather than 30, or the playhead would run
    at the wrong speed against the audio under it.
    """
    d = f"{BUR}/{name}"
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{ss}",
         "-t", f"{t}", "-i", mp4, "-vsync", "0",
         "-vf", "scale=1920:1080:flags=lanczos", f"{d}/f%04d.png"])
    fr = len([f for f in os.listdir(d) if f.startswith("f")])
    if fr < 2:
        sys.exit(f"{name}: {fr} frames — a burst that is one picture is a still")
    fps = fr / t
    json.dump({"fps": round(fps, 4), "frames": fr, "seconds": round(t, 3)},
              open(f"{d}/meta.json", "w"), indent=1)
    shutil.copyfile(f"{d}/f{fr:04d}.png", f"{HERE}/shots/{name}-final.png")
    shutil.copyfile(f"{d}/f{fr//2:04d}.png", f"{HERE}/shots/{name}-mid.png")
    print(f"  burst {name:14s} {fr:4d} frames  {t:6.2f}s  {fps:.2f} fps")
    return t


# ── manim scenes ───────────────────────────────────────────────────────────
def scene(pyfile, cls):
    run([PY, "-m", "manim", "render", "-qh", "--fps", str(FPS_OUT), "--format=mp4",
         "--media_dir", f"{HERE}/manim", f"{HERE}/{pyfile}", cls], cwd=HERE)
    stem = os.path.splitext(pyfile)[0]
    mp4 = f"{HERE}/manim/videos/{stem}/1080p{FPS_OUT}/{cls}.mp4"
    if not os.path.exists(mp4):
        sys.exit(f"manim wrote no {mp4}")
    return mp4


def explode(mp4, name):
    d = f"{BUR}/{name}"
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", mp4,
         "-r", str(FPS_OUT), f"{d}/f%04d.png"])
    fr = len([f for f in os.listdir(d) if f.startswith("f")])
    if fr < 2:
        sys.exit(f"{name}: {fr} frames — a burst that is one picture is a still")
    secs = fr / FPS_OUT
    json.dump({"fps": FPS_OUT, "frames": fr, "seconds": round(secs, 3)},
              open(f"{d}/meta.json", "w"), indent=1)
    shutil.copyfile(f"{d}/f{fr:04d}.png", f"{HERE}/shots/{name}-final.png")
    shutil.copyfile(f"{d}/f{fr//2:04d}.png", f"{HERE}/shots/{name}-mid.png")
    print(f"  burst {name:14s} {fr:4d} frames  {secs:6.2f}s")
    return secs


if __name__ == "__main__":
    only = sys.argv[1] if len(sys.argv) > 1 else None
    out = {}
    if only in (None, "drive"):
        log = json.load(open(f"{HERE}/drive-log.json"))
        fs, pts = frames_and_pts()
        off = calibrate(fs, pts, log)
        print(f"  offset {off:.3f}s")
        out["drive-build"] = make_burst("drive-build", off + 1.2, off + 20.8,
                                        fs, pts, log, off)
        out["drive-mix"] = make_burst("drive-mix", off + 21.6, off + 27.6,
                                      fs, pts, log, off)
        out["_offset"] = round(off, 3)
    if only in (None, "plain"):
        out["play-arrange"] = plain(f"{HERE}/media/play-arrange.mp4",
                                    "play-arrange", 1.7, 14.1)
        out["play-roll"] = plain(f"{HERE}/media/play-roll.mp4",
                                 "play-roll", 1.7, 11.1)
    for nm, pyf, cls in [("modules", "anim_modules.py", "Modules"),
                         ("journey-a", "anim_journey.py", "JourneyA"),
                         ("journey-b", "anim_journey.py", "JourneyB")]:
        if only in (None, nm):
            out[nm] = explode(scene(pyf, cls), nm)
    prev = {}
    if os.path.exists(f"{HERE}/bursts.json"):
        prev = json.load(open(f"{HERE}/bursts.json"))
    prev.update(out)
    json.dump(prev, open(f"{HERE}/bursts.json", "w"), indent=1)
    print(json.dumps(prev, indent=1))
