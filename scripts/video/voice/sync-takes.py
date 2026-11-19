#!/usr/bin/env python3
"""Trim each screen take so its FIRST FRAME is the excerpt's FIRST SAMPLE.

    plugins/narrated-film/.venv/bin/python sync-takes.py   -> bursts/<b>/clip.mp4 + bursts/sync.json

T0 (the song second at the raw take's first frame) comes from the transport
clock READ in the frame (work/take-clock.json, three readings per take). The
excerpt starts at songStart = srcSong + start (takes.json, the same row
cut-loops.py cut the audio from). trim = songStart - T0, and must be positive:
a take that began AFTER its excerpt cannot be fixed by trimming and is refused.

⭐ The proof is not the arithmetic: tools/clock-montage.py is run again on the
TRIMMED clips (work/clocks-synced-*.png), and the clock at clip t must read
songStart + t. That check is read the same way the inputs were.
"""
import json, os, statistics, subprocess, sys

HOME = os.path.dirname(os.path.abspath(__file__))
takes = {t["burst"]: t for t in json.load(open(f"{HOME}/takes.json"))["takes"]}
clock = json.load(open(f"{HOME}/work/take-clock.json"))
res = {}
for b, rd in clock.items():
    if b.startswith("_"):
        continue
    t = takes[b]
    t0 = statistics.median(r - s for r, s in zip(rd, (0.0, 4.0, 8.0)))
    spread = max(r - s for r, s in zip(rd, (0, 4, 8))) - min(r - s for r, s in zip(rd, (0, 4, 8)))
    song = t["srcSong"] + t["start"]
    trim = song - t0
    if trim <= 0:
        sys.exit(f"⛔ {b}: the take starts at {t0:.3f}s, AFTER its excerpt ({song:.3f}s) — re-record it")
    raw, clip = f"{HOME}/bursts/{b}/raw.mp4", f"{HOME}/bursts/{b}/clip.mp4"
    need = t["len"] + 0.6
    p = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{trim:.3f}", "-i", raw,
                        "-t", f"{need:.3f}", "-an", "-vf", "fps=30", "-c:v", "libx264", "-preset", "medium",
                        "-crf", "18", "-pix_fmt", "yuv420p", clip], capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"⛔ {b}: {p.stderr[-400:]}")
    got = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                clip], capture_output=True, text=True).stdout)
    if got < t["len"]:
        sys.exit(f"⛔ {b}: trimmed clip is {got:.2f}s, shorter than its {t['len']}s excerpt — the burst would loop")
    res[b] = {"T0": round(t0, 3), "readingSpread": round(spread, 3), "songStart": song, "trim": round(trim, 3),
              "clipSeconds": round(got, 3), "excerptSeconds": t["len"]}
    print(f"{b:14s} T0 {t0:7.3f}  excerpt @ {song:6.2f}  trim {trim:5.3f}s  clip {got:5.2f}s (needs {t['len']})")
json.dump(res, open(f"{HOME}/bursts/sync.json", "w"), indent=1)
