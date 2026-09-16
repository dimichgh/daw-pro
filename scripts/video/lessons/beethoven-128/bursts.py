#!/usr/bin/env python3
"""L11 rebuild — turn the manim scenes (and the screen recording) into the frame
BURSTS the assembler plays, and build the audio that goes under them.

⭐ THE AUDIO IS BUILT FROM EACH SCENE'S OWN PRINTED OFFSETS, never from a number
typed twice. Each anim_*.py prints where its beds start; this pads silence and
drops the wavs in at exactly those instants, so `run_time` and the audio under
it cannot drift apart.

⚠ `lay()` IS ADDITIVE. Two excerpts whose windows overlap play SIMULTANEOUSLY
and nothing errors — a previous film in this series shipped a draft doing
exactly that. `lay()` now measures the gap between consecutive excerpts and
refuses a build where they collide.

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
    """Silence of the scene's length with each wav dropped in at its offset.

    ⚠ ADDITIVE, so overlapping excerpts SUM. Checked, with a positive control:
    the gap between consecutive excerpts must be digital silence while both of
    its neighbours are not."""
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
            sys.exit(f"OVERLAP: {n1} runs to {e1 / SR:.3f}s but {n2} starts at "
                     f"{s2 / SR:.3f}s — lay() is ADDITIVE, they would play together")
        gap = float(np.abs(buf[e1:s2]).max()) if s2 > e1 else 1.0
        pre = float(np.abs(buf[max(0, e1 - SR // 4):e1]).max())
        post = float(np.abs(buf[s2:s2 + SR // 4]).max())
        print(f"  gap {n1} -> {n2}: {gap:.6f}  (control: before {pre:.4f}, "
              f"after {post:.4f})")
        if gap != 0.0 or pre == 0.0 or post == 0.0:
            sys.exit("the silence check or its own control failed")
    sf.write(os.path.join(AUD, out), buf, SR, subtype="FLOAT")
    print(f"  audio {out:16s} {n / SR:6.2f}s  "
          + ", ".join(f'{a["wav"]}@{a["atSec"]}s' for a in spec["audio"]))
    return n / SR


SCENES = (("anim_cell.py", "CellScene", "cellbed.wav", "cellanim"),
          ("anim_time.py", "SubOverTime", "markerbed.wav", "submarker"))

if __name__ == "__main__":
    os.makedirs(BUR, exist_ok=True)
    only = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else None
    if "--only-media" not in sys.argv:
        for pyf, cls, aout, bname in SCENES:
            if only and only != bname:
                continue
            mp4, spec = scene(pyf, cls)
            vs = explode(mp4, bname)
            lay(spec, aout)
            # ⚠ A stage that TALKS over a chart before playing it must show THAT
            # chart. Copy the burst's last frame into shots/ so a still can never
            # point at a different picture than the words describe — and so
            # nothing references the burst dir, which explode() wipes.
            d = os.path.join(BUR, bname)
            last = sorted(f for f in os.listdir(d) if f.startswith("f"))[-1]
            shutil.copyfile(os.path.join(d, last),
                            os.path.join(HERE, "shots", f"{bname}-final.png"))
            print(f"  still shots/{bname}-final.png  <- {bname}/{last}")
            if abs(vs - spec["total"]) > 0.25:
                print(f"  ⚠ {bname}: scene printed {spec['total']:.2f}s but the render "
                      f"is {vs:.2f}s — the audio offsets use the PRINTED value")

    # ── the screen recording: the transport crossing the arrangement at 30 fps,
    #    which `debug.captureUI` cannot do (it managed 2.59 fps on this project).
    #    ⚠ CROPPED to match the framing of every captureUI still in the film —
    #    the recorder includes the window chrome and the stills do not. Crop
    #    THEN pad; a straight centre crop to 16:9 cuts the wordmark off.
    src = os.path.join(HERE, "media", "build.mp4")
    if os.path.exists(src):
        secs = explode(src, "buildrec", vf="crop=3200:1736:0:64,pad=3200:1800:0:0:black")
        # ⭐ THE AUDIO UNDER THIS FOOTAGE IS CUT TO MATCH THE FOOTAGE, not the
        # other way round. MEASURED off media/_first.png and media/_last.png,
        # which were both extracted and LOOKED AT: the first frame's transport
        # readout is TIME 0:00.366 and the last is 0:13.070, so the recorder's
        # first frame is 366 ms into the music and the sweep runs at real time
        # (12.70 s of transport across 12.65 s of video). An excerpt starting at
        # 0.0 would put every layer arrival ~0.37 s late in the ear relative to
        # the eye — small, but it is the same class of defect as playing bars
        # 10–13 over footage of bars 1–4.
        REC_LEAD = 0.366
        x, sr = sf.read(os.path.join(AUD, "techno.wav"), dtype="float32",
                        always_2d=True)
        y = x[int(REC_LEAD * sr):int((REC_LEAD + secs) * sr)]
        y = y * (10 ** (-1.0 / 20) / max(float(np.abs(y).max()), 1e-9))
        sf.write(os.path.join(AUD, "play-buildrec.wav"), y, sr, subtype="FLOAT")
        print(f"  audio play-buildrec.wav  {len(y) / sr:6.2f}s  "
              f"techno.wav from {REC_LEAD:.3f}s (the recording's own start)")
    else:
        print(f"  (no {src} — run record.mjs for the moving playhead)")
