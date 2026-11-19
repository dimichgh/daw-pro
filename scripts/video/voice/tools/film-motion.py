#!/usr/bin/env python3
"""film-motion.py — does every PLAY beat in the FINISHED film move, and does a
single-still TALK beat read static? (The bursts were checked before assembly;
this checks what the viewer gets, after trimming, scaling and concatenation.)

Changed-pixel count between a frame 1 s into a segment and a frame 1 s
before its end (ffmpeg blend=difference + signalstats YMAX), per segment of
work/segments-map.json. A burst-backed play beat must change >= 300 pixels by more than
40 luma. CONTROLS: a talk beat built from ONE still must change <= 20 (the probe can return a static
answer), and the same frame against itself must read 0.
"""
import json, os, re, subprocess, sys
import numpy as np
from PIL import Image
HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILM = f"{HOME}/out/voice-film.mp4"
man = {s["id"]: s for s in json.load(open(f"{HOME}/manifest.json"))["stages"]}
parts = json.load(open(f"{HOME}/work/segments-map.json"))["parts"]

def frame(t, path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{t:.2f}", "-i", FILM,
                        "-frames:v", "1", path], capture_output=True, text=True)
    if r.returncode or not os.path.exists(path):
        sys.exit(f"⛔ no frame at {t}: {r.stderr[-300:]}")
    return np.asarray(Image.open(path).convert("L"), float)


def ymax(t1, t2):
    """Pixels whose luma changed by more than 40 between frame t1 and frame t2.

    ⛔ NOT ffmpeg `-ss t1 -i F -ss t2 -i F ... blend=difference`. That was the
    first version (copied from record-all.sh) and it is BROKEN on this film:
    blend pairs its inputs BY TIMESTAMP, so the frame it compared was pts 5.52 s
    against pts 5.52 s, not t1 against t2 — MEASURED, it read 0 on the drums
    beat whose clock visibly runs 0:05.834 -> 0:08.618, and 255 on a talk beat
    that is one still. Each frame is extracted alone and compared in numpy."""
    a, b = frame(t1, f"{HOME}/logs/_fm-a.png"), frame(t2, f"{HOME}/logs/_fm-b.png")
    return int((np.abs(a - b) > 40).sum())


MOVE, STATIC = 300, 20     # changed pixels (>40 luma); a 2 px playhead over a lane is ~1000
rows, bad = [], 0
for start, dur, name in parts:
    sid = name.split("-talk")[0].split("-play")[0].split("-ab0")[0].replace(".mp4", "")
    if "-play" in name or "-ab0-" in name:
        burst = (man.get(sid, {}).get("burst") if "-play" in name else None)
        kind = "play"
        if "-ab0-before" in name: burst = man[sid]["ab"].get("beforeBurst")
        if "-ab0-after" in name: burst = man[sid].get("burst")
        if not burst:
            kind = "play-still"
    elif "-talk" in name and len(man.get(sid, {}).get("shots", [])) == 1:
        kind = "talk-1still"
    else:
        continue
    if dur < 2.5:
        continue
    y = ymax(start + 1.0, start + dur - 1.0)
    ok = (y >= MOVE) if kind == "play" else (y <= STATIC) if kind == "talk-1still" else True
    bad += not ok
    rows.append({"segment": name, "kind": kind, "start": start, "ymax": y, "ok": ok})
    print(f"{name:32s} {kind:12s} @{start:7.2f}s  changed px {y:7d}  {'ok' if ok else '⛔'}")
self_ = ymax(parts[5][0] + 1.0, parts[5][0] + 1.0)
print(f"CONTROL same frame vs itself: {self_:.0f} (must be 0)")
moved = sum(1 for r in rows if r["kind"] == "play" and r["ok"])
static = sum(1 for r in rows if r["kind"] == "talk-1still" and r["ok"])
json.dump({"rows": rows, "selfControl": self_}, open(f"{HOME}/work/film-motion.json", "w"), indent=1)
print(f"\n{moved}/{sum(1 for r in rows if r['kind']=='play')} play beats move; "
      f"{static}/{sum(1 for r in rows if r['kind']=='talk-1still')} single-still talk beats read static")
sys.exit(1 if bad or self_ != 0 else 0)
