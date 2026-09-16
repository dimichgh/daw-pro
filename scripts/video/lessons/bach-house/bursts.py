#!/usr/bin/env python3
"""Render the manim scenes, explode them into frame BURSTS, and build the audio
that goes under each one.

⭐ EVERY AUDIO OFFSET COMES FROM THE SCENE ITSELF. Each anim_*.py prints where
its beds start; lay() pads silence and drops the wavs in at exactly those
instants, so a scene's run_time and the audio under it cannot drift apart.

⚠ lay() IS ADDITIVE — two excerpts whose windows overlap play SIMULTANEOUSLY and
nothing errors. It measures the gap between consecutive excerpts and refuses a
build where they collide, with the neighbours as the positive control that the
silence check can see anything at all.

⚠ Run with the plugin venv (manim, numpy, soundfile).
"""
import json, os, shutil, subprocess, sys
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
AUD, BUR = os.path.join(HERE, "audio"), os.path.join(HERE, "bursts")
PY = sys.executable
SR, FPS = 48000, 30


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        sys.exit(f"FAILED: {' '.join(cmd[:8])}\n{p.stdout[-1500:]}\n{p.stderr[-2500:]}")
    return p.stdout


def explode(mp4, name):
    d = os.path.join(BUR, name)
    if os.path.exists(d):
        shutil.rmtree(d)                 # a shorter re-render must not inherit frames
    os.makedirs(d)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", mp4,
         "-r", str(FPS), os.path.join(d, "f%04d.png")])
    frames = len([f for f in os.listdir(d) if f.startswith("f")])
    if frames < 2:
        sys.exit(f"{name}: {frames} frames — a burst that is one picture is a still")
    secs = frames / FPS
    json.dump({"fps": FPS, "frames": frames, "seconds": round(secs, 3)},
              open(os.path.join(d, "meta.json"), "w"), indent=1)
    print(f"  burst {name:12s} {frames:4d} frames  {secs:6.2f}s")
    shutil.copyfile(os.path.join(d, sorted(f for f in os.listdir(d)
                                           if f.startswith("f"))[-1]),
                    os.path.join(HERE, "shots", f"{name}-final.png"))
    return secs


def scene(pyfile, cls):
    run([PY, "-m", "manim", "render", "-qh", "--fps", str(FPS), "--format=mp4",
         "--media_dir", os.path.join(HERE, "manim"),
         os.path.join(HERE, pyfile), cls], cwd=HERE)
    stem = os.path.splitext(pyfile)[0]
    mp4 = os.path.join(HERE, "manim", "videos", stem, f"1080p{FPS}", f"{cls}.mp4")
    if not os.path.exists(mp4):
        sys.exit(f"manim wrote no {mp4}")
    return mp4


def lay(spec, out):
    n = int(round(spec["total"] * SR))
    buf = np.zeros((n, 2), dtype=np.float32)
    spans = []
    for a in spec["audio"]:
        x, sr = sf.read(os.path.join(AUD, a["wav"]), dtype="float32", always_2d=True)
        assert sr == SR, f'{a["wav"]}: {sr} Hz'
        if x.shape[1] == 1:
            x = np.column_stack([x[:, 0], x[:, 0]])
        i = int(round(a["atSec"] * SR))
        j = min(i + len(x), n)
        buf[i:j] += x[:j - i]
        spans.append((a["wav"], i, j))
    for (n1, _, e1), (n2, s2, _) in zip(spans, spans[1:]):
        if s2 < e1:
            sys.exit(f"OVERLAP: {n1} runs to {e1/SR:.3f}s but {n2} starts at "
                     f"{s2/SR:.3f}s — lay() is ADDITIVE, they would play together")
        pre = float(np.abs(buf[max(0, e1 - SR//4):e1]).max())
        post = float(np.abs(buf[s2:s2 + SR//4]).max())
        if s2 == e1:
            # ⚠ EXACTLY ABUTTING IS LEGAL AND HAS NO GAP TO MEASURE. The
            # inherited version scored this case as gap=1.0 and killed the
            # build — a check that cannot be satisfied by a correct layout. The
            # thing that actually matters (no overlap) was already asserted
            # above; here the controls still have to fire so we know the probe
            # is looking at real audio.
            print(f"  abut {n1} -> {n2}: exact, no gap  (control: before "
                  f"{pre:.4f}, after {post:.4f})")
            if pre == 0.0 or post == 0.0:
                sys.exit("the abutment control failed — one side is silent")
            continue
        gap = float(np.abs(buf[e1:s2]).max())
        print(f"  gap {n1} -> {n2}: {gap:.6f}  (control: before {pre:.4f}, "
              f"after {post:.4f})")
        if gap != 0.0 or pre == 0.0 or post == 0.0:
            sys.exit("the silence check or its own control failed")
    sf.write(os.path.join(AUD, out), buf, SR, subtype="FLOAT")
    print(f"  audio {out:18s} {n/SR:6.2f}s  "
          + ", ".join(f'{a["wav"]}@{a["atSec"]}s' for a in spec["audio"]))
    return n / SR


if __name__ == "__main__":
    os.makedirs(BUR, exist_ok=True)
    only = sys.argv[1] if len(sys.argv) > 1 else None
    lp = json.loads(run([PY, os.path.join(HERE, "anim_loops.py")]))
    tm = json.loads(run([PY, os.path.join(HERE, "anim_time.py")]))
    JOBS = [
        ("invariant", "anim_loops.py", "FigureInvariant", lp,           "invbed.wav"),
        ("nested",    "anim_loops.py", "NestedLoops",     lp["nested"], "nestbed.wav"),
        ("buildmark", "anim_time.py",  "BuildMarker",     tm,           "markbed.wav"),
    ]
    for name, pyf, cls, spec, aout in JOBS:
        if only and only != name:
            continue
        vs = explode(scene(pyf, cls), name)
        lay(spec, aout)
        if abs(vs - spec["total"]) > 0.25:
            print(f"  \u26a0 {name}: scene printed {spec['total']:.2f}s but the render "
                  f"is {vs:.2f}s \u2014 the audio uses the PRINTED value")
