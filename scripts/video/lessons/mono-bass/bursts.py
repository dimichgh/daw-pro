#!/usr/bin/env python3
"""L8 rebuild — PASS 3b: turn the animations and the screen recordings into the
frame BURSTS the assembler plays, and build the audio that goes under them.

assemble.py's play beat takes either stills or a `burst` — a directory of
f0001.png… plus meta.json {frames, seconds, fps}. Everything with motion in this
film arrives here:

  * the two manim scenes, rendered at 1920x1080/30 and exploded into frames;
  * the two ScreenCaptureKit recordings of the mixer, CROPPED to the master
    strip so the correlation meter is legible after the film scales it down.

⭐ THE AUDIO IS BUILT FROM THE SCENE'S OWN PRINTED OFFSETS, never from a number
typed twice. Each anim_*.py prints where its sweeps start; this pads silence and
drops the wavs in at exactly those instants, so `run_time` and the audio under
it cannot drift apart.

⚠ Run with the plugin venv (manim, numpy, scipy).
"""
import json, os, shutil, subprocess, sys
import numpy as np
from scipy.io import wavfile

HERE = os.path.dirname(os.path.abspath(__file__))
AUD, BUR = os.path.join(HERE, "audio"), os.path.join(HERE, "bursts")
PY = sys.executable
SR = 48000
FPS = 30


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        sys.exit(f"FAILED: {' '.join(cmd[:8])}\n{p.stdout[-1500:]}\n{p.stderr[-2500:]}")
    return p.stdout


def explode(mp4, name, vf=None):
    """One mp4 -> bursts/<name>/f%04d.png + meta.json.

    ⚠ CLEAR THE DIRECTORY FIRST. assemble.py globs it, so a shorter re-render
    silently ends on frames left over from the previous take."""
    d = os.path.join(BUR, name)
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d)
    args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", mp4]
    if vf:
        args += ["-vf", vf]
    run(args + ["-r", str(FPS), os.path.join(d, "f%04d.png")])
    frames = len([f for f in os.listdir(d) if f.startswith("f")])
    if frames < 2:
        sys.exit(f"{name}: {frames} frames — a burst that is one picture is a still")
    secs = frames / FPS
    json.dump({"fps": FPS, "frames": frames, "seconds": round(secs, 3)},
              open(os.path.join(d, "meta.json"), "w"), indent=1)
    print(f"  burst {name:14s} {frames:4d} frames  {secs:6.2f}s")
    return secs


def scene(pyfile, cls):
    """Render one manim scene at 1920x1080/30 and return (mp4, printed spec)."""
    spec = json.loads(run([PY, os.path.join(HERE, pyfile)]))
    run([PY, "-m", "manim", "render", "-qh", "--fps", str(FPS), "--format=mp4",
         "--media_dir", os.path.join(HERE, "manim"),
         os.path.join(HERE, pyfile), cls], cwd=HERE)
    stem = os.path.splitext(pyfile)[0]
    mp4 = os.path.join(HERE, "manim", "videos", stem, f"1080p{FPS}", f"{cls}.mp4")
    if not os.path.exists(mp4):
        sys.exit(f"manim wrote no {mp4}")
    return mp4, spec


def lay(spec, out):
    """Silence of the scene's length with each wav dropped in at its offset."""
    n = int(round(spec["total"] * SR))
    buf = np.zeros((n, 2), dtype=np.float32)
    for a in spec["audio"]:
        sr, x = wavfile.read(os.path.join(AUD, a["wav"]))
        assert sr == SR
        x = x.astype(np.float32)
        if x.ndim == 1:
            x = np.column_stack([x, x])
        i = int(round(a["atSec"] * SR))
        j = min(i + len(x), n)
        buf[i:j] += x[:j - i]
    wavfile.write(os.path.join(AUD, out), SR, buf)
    print(f"  audio {out:14s} {n / SR:6.2f}s  "
          + ", ".join(f'{a["wav"]}@{a["atSec"]}s' for a in spec["audio"]))
    return n / SR


if __name__ == "__main__":
    os.makedirs(BUR, exist_ok=True)
    # `--meters` re-crops the screen recordings without re-rendering manim,
    # which is the only slow step here (~40 s a scene).
    only_meters = "--meters" in sys.argv

    for pyf, cls, aout, bname in (("anim_phase.py", "PhaseSlide", "mech.wav", "mechanism"),
                                  ("anim_time.py", "FoldOverTime", "chartaudio.wav", "foldchart")):
        if only_meters:
            break
        mp4, spec = scene(pyf, cls)
        vs = explode(mp4, bname)
        as_ = lay(spec, aout)
        if bname == "foldchart":
            # ⚠ 08-chart TALKS over a still of this chart before it plays. Copy
            # the burst's LAST frame into shots/ so the still can never point at
            # a different picture than the words describe — and so nothing
            # references the burst dir, which explode() wipes.
            d = os.path.join(BUR, bname)
            last = sorted(f for f in os.listdir(d) if f.startswith("f"))[-1]
            dst = os.path.join(HERE, "shots", "foldchart-final.png")
            shutil.copyfile(os.path.join(d, last), dst)
            print(f"  still shots/foldchart-final.png  <- {bname}/{last}")
        # ⚠ The scene's PRINTED total and the rendered video's real length must
        # agree, or the playhead points at the wrong instant. Say so loudly.
        if abs(vs - spec["total"]) > 0.25:
            print(f"  ⚠ {bname}: scene printed {spec['total']:.2f}s but the render is "
                  f"{vs:.2f}s — the audio offsets are built from the printed value")

    # ── the mixer recordings, cropped to the master strip. The meter is ~440 px
    #    wide in a 3000 px frame; without the crop the film scales it to about a
    #    fifth of its captured size and the correlation number is unreadable.
    for ms in (0, 6):
        src = os.path.join(HERE, "media", f"mixer{ms}.mp4")
        if not os.path.exists(src):
            print(f"  ⚠ no media/mixer{ms}.mp4 — run record.mjs")
            continue
        explode(src, f"meter{ms}", vf="crop=480:664:2560:1176")
