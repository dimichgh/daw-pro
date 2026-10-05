#!/usr/bin/env python3
"""PASS 4: turn the two manim scenes into the frame BURSTS the assembler plays,
and build the audio bed that goes under them.

⭐ THE AUDIO IS BUILT FROM THE SCENE'S OWN PRINTED OFFSETS, never from a number
typed twice, so run_time and the audio cannot drift apart.
⚠ Run with the plugin venv (manim, numpy, scipy).
"""
import json, os, shutil, subprocess, sys
import numpy as np
from scipy.io import wavfile

HERE = os.path.dirname(os.path.abspath(__file__))
AUD, BUR = os.path.join(HERE, "audio"), os.path.join(HERE, "bursts")
PY, SR, FPS = sys.executable, 48000, 30


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        sys.exit(f"FAILED: {' '.join(cmd[:8])}\n{p.stdout[-1500:]}\n{p.stderr[-2500:]}")
    return p.stdout


def explode(mp4, name):
    d = os.path.join(BUR, name)
    if os.path.exists(d):
        shutil.rmtree(d)            # ⚠ a shorter re-render otherwise ends on the
    os.makedirs(d)                  #   PREVIOUS take's leftover frames
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", mp4,
         "-r", str(FPS), os.path.join(d, "f%04d.png")])
    frames = len([f for f in os.listdir(d) if f.startswith("f")])
    if frames < 2:
        sys.exit(f"{name}: {frames} frames — a burst that is one picture is a still")
    json.dump({"fps": FPS, "frames": frames, "seconds": round(frames / FPS, 3)},
              open(os.path.join(d, "meta.json"), "w"), indent=1)
    print(f"  burst {name:12s} {frames:4d} frames  {frames / FPS:6.2f}s")
    return frames / FPS


def scene(pyfile, cls):
    spec = json.loads(run([PY, os.path.join(HERE, pyfile)]))
    run([PY, "-m", "manim", "render", "-qh", "--fps", str(FPS), "--format=mp4",
         "--media_dir", os.path.join(HERE, "manim"), os.path.join(HERE, pyfile), cls], cwd=HERE)
    stem = os.path.splitext(pyfile)[0]
    mp4 = os.path.join(HERE, "manim", "videos", stem, f"1080p{FPS}", f"{cls}.mp4")
    if not os.path.exists(mp4):
        sys.exit(f"manim wrote no {mp4}")
    return mp4, spec


def lay(spec, out):
    n = int(round(spec["total"] * SR))
    buf = np.zeros((n, 2), dtype=np.float32)
    for a in spec["audio"]:
        sr, x = wavfile.read(os.path.join(AUD, a["wav"]))
        assert sr == SR, f"{a['wav']} is {sr} Hz"
        # ⚠ scipy returns the file's OWN dtype: int16 for a PCM_16 wav, float
        # for a float one. Casting without scaling is what put a bed on screen
        # at +89 dB; normalise by dtype and then REFUSE anything over full
        # scale, so this can never again be something only a listener notices.
        if np.issubdtype(x.dtype, np.integer):
            x = x.astype(np.float32) / float(np.iinfo(x.dtype).max)
        else:
            x = x.astype(np.float32)
        if np.abs(x).max() > 1.001:
            sys.exit(f"REFUSING: {a['wav']} peaks at {np.abs(x).max():.3f} — over full scale")
        if x.ndim == 1:
            x = np.column_stack([x, x])
        if a.get("trim"):
            x = x[:int(round(a["trim"] * SR))]
        i = int(round(a["atSec"] * SR))
        j = min(i + len(x), n)
        buf[i:j] += x[:j - i]
    wavfile.write(os.path.join(AUD, out), SR, buf)
    print(f"  audio {out:16s} {n / SR:6.2f}s  "
          + ", ".join(f'{a["wav"]}@{a["atSec"]}s' for a in spec["audio"]))


if __name__ == "__main__":
    os.makedirs(BUR, exist_ok=True)
    audio_only = "--audio-only" in sys.argv
    for pyf, cls, aout, bname, still in (
            ("anim_drift.py", "DriftOverTime", "bed-drift.wav", "driftchart", True),
            ("anim_unit.py", "SameMetronome", "bed-unit.wav", "unitchart", True)):
        if audio_only:
            # re-lay the bed from the scene's own printed offsets without paying
            # for a manim re-render; the frames on disk are unchanged.
            spec = json.loads(run([PY, os.path.join(HERE, pyf)]))
            lay(spec, aout)
            continue
        mp4, spec = scene(pyf, cls)
        vs = explode(mp4, bname)
        lay(spec, aout)
        if still:
            # ⚠ The TALK beat before each of these describes the picture. Copy a
            # frame from the burst into shots/ so the words cannot end up over a
            # different image -- and never reference bursts/*/f####.png from the
            # spec, because explode() wipes that directory on every re-render.
            d = os.path.join(BUR, bname)
            fs = sorted(f for f in os.listdir(d) if f.startswith("f"))
            for tag, f in (("final", fs[-1]), ("mid", fs[len(fs) * 2 // 3])):
                shutil.copyfile(os.path.join(d, f),
                                os.path.join(HERE, "shots", f"{bname}-{tag}.png"))
            print(f"  still shots/{bname}-final.png, {bname}-mid.png")
        if abs(vs - spec["total"]) > 0.25:
            print(f"  ⚠ {bname}: scene printed {spec['total']:.2f}s but the render is "
                  f"{vs:.2f}s — the audio offsets come from the PRINTED value")
