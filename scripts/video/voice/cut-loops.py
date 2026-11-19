#!/usr/bin/env python3
"""ONE AUDIO EXCERPT PER BEAT, cut from takes.json — the same table the screen
takes are filmed from — with ONE static gain per beat (per PAIR for an A/B).

    plugins/narrated-film/.venv/bin/python cut-loops.py   -> loops/<burst>.wav + loops/cuts.json

Why static gain and not the assembler's loudnorm: loudnorm is single-pass and
DYNAMIC, applied per half, and it has inverted an A/B's level difference before
(narrated-film SKILL, "normalize: false"). Every play beat in this film sets
"normalize": false and arrives here already at about -16 LUFS; an A/B pair
shares one gain (computed on its LOUDER half), so the halves keep exactly the
level relation the app rendered. A gain is lowered if it would push a true peak
above -2.0 dBTP (see TP_CEIL).

⚠ ebur128's summary logs at INFO: -hide_banner, never -v error (an empty parse
would read as silence). A file whose summary does not parse is a hard error.
"""
import json, os, re, subprocess, sys

HOME = os.path.dirname(os.path.abspath(__file__))
REN, LOOPS = f"{HOME}/out/renders", f"{HOME}/loops"
# TP_CEIL was -1.5 until 2026-10-11: the AAC encode of the finished film adds
# overshoot on percussive material, MEASURED +0.5 dB on the drums beat (wav
# -1.5 dBTP -> -1.00 dBTP in the film, both ebur128 and loudnorm), which left
# the film exactly AT the -1.0 ceiling with zero margin. -2.0 buys that margin.
TARGET, TP_CEIL = -16.0, -2.0
os.makedirs(LOOPS, exist_ok=True)


def run(a):
    p = subprocess.run(a, capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"FAILED {' '.join(a[:6])}\n{p.stderr[-800:]}")
    return p


def loud(path):
    err = run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true",
               "-f", "null", "-"]).stderr
    i = re.findall(r"^\s+I:\s+(-?[\d.]+) LUFS", err, re.M)
    tp = re.findall(r"^\s+Peak:\s+(-?[\d.]+) dBFS", err, re.M)
    if not i or not tp:
        sys.exit(f"⛔ no ebur128 summary for {path} — the probe saw nothing")
    return float(i[-1]), float(tp[-1])


takes = json.load(open(f"{HOME}/takes.json"))["takes"]
raw = {}
for t in takes:
    src = f"{REN}/{t['src']}.wav"
    if not os.path.exists(src):
        sys.exit(f"⛔ missing render {src} — run render-all.mjs")
    out = f"{LOOPS}/{t['burst']}.raw.wav"
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{t['start']}", "-t", f"{t['len']}",
         "-i", src, "-af", f"afade=t=in:st=0:d=0.02,afade=t=out:st={t['len'] - 0.06:.3f}:d=0.06",
         "-c:a", "pcm_s24le", out])
    raw[t["burst"]] = loud(out)

groups = {}
for t in takes:
    groups.setdefault(t.get("group") or t["burst"], []).append(t["burst"])
cuts = {}
for g, members in groups.items():
    gain = TARGET - max(raw[m][0] for m in members)
    gain = min(gain, TP_CEIL - max(raw[m][1] for m in members))
    for m in members:
        t = next(x for x in takes if x["burst"] == m)
        out = f"{LOOPS}/{m}.wav"
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", f"{LOOPS}/{m}.raw.wav",
             "-af", f"volume={gain:.2f}dB", "-c:a", "pcm_s24le", out])
        os.remove(f"{LOOPS}/{m}.raw.wav")
        i, tp = loud(out)
        cuts[m] = {**t, "group": g, "gainDb": round(gain, 2), "rawLufs": raw[m][0], "rawTp": raw[m][1],
                   "lufs": i, "tp": tp, "songStart": round(t["srcSong"] + t["start"], 3)}
        print(f"{m:14s} {t['src']:18s} @{t['start']:6.2f}s +{t['len']:5.2f}s  gain {gain:+6.2f} dB"
              f"  -> {i:6.1f} LUFS  {tp:6.1f} dBTP   (group {g})")
json.dump(cuts, open(f"{LOOPS}/cuts.json", "w"), indent=1)

# every excerpt must be a different file
md5 = run(["md5", "-q"] + [f"{LOOPS}/{m}.wav" for m in cuts]).stdout.split()
dups = len(md5) - len(set(md5))
print(f"distinct excerpts: {len(set(md5))}/{len(md5)}" + ("" if not dups else "  ⛔ DUPLICATES"))
sys.exit(1 if dups else 0)
