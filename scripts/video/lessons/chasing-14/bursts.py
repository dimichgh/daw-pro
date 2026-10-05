#!/usr/bin/env python3
"""L6 rebuild — PASS 3b: turn the manim scenes (and any screen recording) into
the frame BURSTS the assembler plays, and build the audio that goes under them.

assemble.py's play beat takes either stills or a `burst` — a directory of
f0001.png… plus meta.json {frames, seconds, fps}. Everything with motion in this
film arrives here.

⭐ THE AUDIO IS BUILT FROM EACH SCENE'S OWN PRINTED OFFSETS, never from a number
typed twice. Each anim_*.py prints where its sweeps start; this pads silence and
drops the wavs in at exactly those instants, so `run_time` and the audio under
it cannot drift apart.

⚠ Run with the plugin venv (manim, numpy, soundfile).
"""
import json, os, shutil, subprocess, sys
import numpy as np
import soundfile as sf

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
        x, sr = sf.read(os.path.join(AUD, a["wav"]), dtype="float32", always_2d=True)
        assert sr == SR, f'{a["wav"]}: {sr} Hz'
        if x.shape[1] == 1:
            x = np.column_stack([x[:, 0], x[:, 0]])
        i = int(round(a["atSec"] * SR))
        j = min(i + len(x), n)
        buf[i:j] += x[:j - i]
    sf.write(os.path.join(AUD, out), buf, SR, subtype="FLOAT")
    print(f"  audio {out:16s} {n / SR:6.2f}s  "
          + ", ".join(f'{a["wav"]}@{a["atSec"]}s' for a in spec["audio"]))
    return n / SR


SCENES = (("anim_clip.py", "ClipCeiling", "mech.wav", "mechanism"),
          ("anim_time.py", "ClipOverTime", "chartaudio.wav", "clipchart"))

if __name__ == "__main__":
    os.makedirs(BUR, exist_ok=True)
    only = sys.argv[1] if len(sys.argv) > 1 else None
    for pyf, cls, aout, bname in SCENES:
        if only and only != bname:
            continue
        mp4, spec = scene(pyf, cls)
        vs = explode(mp4, bname)
        lay(spec, aout)
        # ⚠ A stage that TALKS over a chart before playing it must show THAT
        # chart. Copy the burst's last frame into shots/ so a still can never
        # point at a different picture than the words describe — and so nothing
        # references the burst dir, which explode() wipes on every render.
        d = os.path.join(BUR, bname)
        last = sorted(f for f in os.listdir(d) if f.startswith("f"))[-1]
        dst = os.path.join(HERE, "shots", f"{bname}-final.png")
        shutil.copyfile(os.path.join(d, last), dst)
        print(f"  still shots/{bname}-final.png  <- {bname}/{last}")
        # ⚠ The scene's PRINTED total and the rendered video's real length must
        # agree, or the playhead points at the wrong instant. Say so loudly.
        if abs(vs - spec["total"]) > 0.25:
            print(f"  ⚠ {bname}: scene printed {spec['total']:.2f}s but the render is "
                  f"{vs:.2f}s — the audio offsets are built from the printed value")

    # ── the ONE screen recording: the transport crossing the arrangement at
    #    30 fps, which `debug.captureUI` cannot do (it managed 3.30 fps on the
    #    same shot). ⚠ CROPPED to 16:9 starting below the macOS title bar, so it
    #    matches the framing of every captureUI still in the film; the recorder
    #    includes the window chrome and the stills do not. ⚠ CROP THEN PAD, do
    #    not crop to 16:9 directly — a 3086x1736 centre crop cut the DAW PRO
    #    wordmark off the left and the PRO toggle off the right. Found by
    #    looking at a frame.
    src = os.path.join(HERE, "media", "arrange.mp4")
    if os.path.exists(src):
        explode(src, "arrangeplay", vf="crop=3200:1736:0:64,pad=3200:1800:0:0:black")
    else:
        print("  (no media/arrange.mp4 — run record.mjs for the moving playhead)")
