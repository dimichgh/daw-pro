#!/usr/bin/env python3
"""Checks I run on the DELIVERABLE, after verify.py is already green.

Every one of these exists because a previous lesson shipped a defect through a
fully green build. They are listed separately from verify.py's own eight so that
the eight are never inflated.

  1. PER-SEGMENT LOUDNESS. A film-level LUFS number cannot see one bad segment;
     this sweep is what caught two manim beds shipping at +3.6 LUFS on the
     previous rebuild while every gate said ok.
  2. A/B AND PLAY CUT QUALITY. The tail of each demo segment, in dB below its
     own peak. A cut through a hit reads near 0; a clean one reads far down.
     Positive control: a deliberately mid-hit cut is measured alongside.
  4. MAX MOMENTARY LOUDNESS of every demo against the voice. Integrated LUFS
     and peak BOTH mis-rank sparse percussive material; momentary is what
     matches a laptop speaker, and it is what caught the clicks sitting 12 LU
     under the narration while peak said they were LOUDER.
  3. WHERE EACH PHRASE ACTUALLY RUNS, from silencedetect, so the frame carrying
     a number can be pulled at the moment the number is SPOKEN. No gate sees a
     card that is on screen at the wrong time.

Usage:  python3 filmcheck.py out/L7v2.mp4
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FILM = sys.argv[1] if len(sys.argv) > 1 else f"{HERE}/out/L7v2.mp4"
SEG = f"{HERE}/out/segments"


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stderr + \
           subprocess.run(cmd, capture_output=True, text=True).stdout


def lufs(path):
    # ⚠ -hide_banner, NOT -v error: ebur128's summary logs at INFO and -v error
    #   suppresses it entirely, turning a loud failure into a clean empty answer.
    p = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path,
                        "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    m = re.findall(r"I:\s+(-?[\d.]+) LUFS", p.stderr)
    t = re.findall(r"Peak:\s+(-?[\d.]+) dBFS", p.stderr)
    return (float(m[-1]) if m else None), (float(t[-1]) if t else None)


def tail_db(path, window=0.06):
    """Level of the last `window` seconds, in dB below the file's own peak."""
    p = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                        "-of", "csv=p=0", path], capture_output=True, text=True)
    try:
        dur = float(p.stdout.strip())
    except ValueError:
        return None, None
    def peak(extra):
        q = subprocess.run(["ffmpeg", "-hide_banner", "-nostats"] + extra +
                           ["-i", path, "-af", "astats=metadata=1", "-f", "null", "-"],
                           capture_output=True, text=True)
        v = re.findall(r"Peak level dB:\s+(-?[\d.inf]+)", q.stderr)
        try:
            return float(v[0])
        except (ValueError, IndexError):
            return -240.0
    full = peak([])
    last = peak(["-ss", f"{max(0, dur - window):.4f}"])
    return round(last - full, 2), round(dur, 3)


def phrases(path, noise="-38dB", d=0.28):
    p = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path,
                        "-af", f"silencedetect=noise={noise}:d={d}", "-f", "null", "-"],
                       capture_output=True, text=True)
    starts = [float(x) for x in re.findall(r"silence_end: ([\d.]+)", p.stderr)]
    ends = [float(x) for x in re.findall(r"silence_start: ([\d.]+)", p.stderr)]
    return sorted(starts), sorted(ends)


out = {}
print("── 1. per-segment loudness ──────────────────────────────────────────")
segs = sorted(f for f in os.listdir(SEG) if f.endswith("-mux.mp4")) if os.path.isdir(SEG) else []
rows = []
for f in segs:
    i, t = lufs(f"{SEG}/{f}")
    rows.append((f, i, t))
    flag = ""
    if i is not None and (i > -12.0 or i < -24.0):
        flag = "   ⚠ OUTLIER"
    print(f"  {f:34s} {str(i):>8} LUFS  peak {str(t):>7} dBFS{flag}")
out["segments"] = [{"file": f, "lufs": i, "peakDbfs": t} for f, i, t in rows]
vals = [i for _, i, _ in rows if i is not None]
if vals:
    print(f"  range: {min(vals):.1f} .. {max(vals):.1f} LUFS over {len(vals)} segments")
    out["segmentLufsRange"] = [min(vals), max(vals)]

print("\n── 2. demo-segment cut quality (tail, dB below own peak) ────────────")
demo = [f for f in segs if "-ab" in f or "-play" in f]
out["cuts"] = []
for f in demo:
    t, dur = tail_db(f"{SEG}/{f}")
    print(f"  {f:34s} {str(t):>9} dB   ({dur} s)")
    out["cuts"].append({"file": f, "tailDbOfPeak": t, "seconds": dur})
# positive control: the SAME probe on a cut deliberately made mid-hit
ctl = f"{HERE}/audio/motif-mark-216.wav"
if os.path.exists(ctl):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", ctl,
                    "-t", "0.63", "/tmp/_midhit.wav"], capture_output=True)
    t, _ = tail_db("/tmp/_midhit.wav")
    print(f"  CONTROL: a cut 0.63 s in, mid-note        {t:>9} dB  "
          f"(so the probe can separate a chopped cut from a clean one)")
    out["cutControlDb"] = t

print("\n── 4. MAX MOMENTARY: can the demos be heard next to the voice? ─────")
# ⚠⚠ INTEGRATED LUFS AND PEAK BOTH GIVE THE WRONG ANSWER ON A METRONOME.
#   A 20 ms woodblock at -3 dBFS peak measured LOUDER than the speech by peak
#   and TWELVE LU QUIETER by max momentary (400 ms) -- and momentary is the one
#   that matches what a laptop speaker does. The two instruments disagreeing was
#   the whole signal. Talk sits near -11..-12; a demo more than ~8 LU under that
#   is not audible next to it, which is what forced the soft-clip lift.
def momentary(path):
    p = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path,
                        "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    # ⚠ parse ebur128's per-frame "M:" readings with a regex. An awk field-split
    #   version of this returned a UNIFORM 0.0 for all six files -- a tidy result
    #   across many units is the signature of a broken probe, not a clean system.
    ms = [float(x) for x in re.findall(r"M:\s*(-?[\d.]+)", p.stderr) if float(x) > -70]
    return max(ms) if ms else None

talk = [f for f in segs if f.endswith("-talk-mux.mp4")]
demo = [f for f in segs if "-ab" in f or "-play" in f]
tvals = [v for v in (momentary(f"{SEG}/{f}") for f in talk[:4]) if v is not None]
ref = max(tvals) if tvals else None
print(f"  voice reference (max over {len(tvals)} talk segments): {ref} LUFS momentary")
out["talkMaxMomentary"] = ref
out["demoMomentary"] = []
worst = None
for f in demo:
    v = momentary(f"{SEG}/{f}")
    gap = None if (v is None or ref is None) else round(ref - v, 1)
    flag = "   ⚠ MORE THAN 8 LU UNDER THE VOICE" if (gap or 0) > 8.0 else ""
    if gap is not None and (worst is None or gap > worst):
        worst = gap
    print(f"  {f:34s} {str(v):>7} LUFS momentary   {str(gap):>5} LU under voice{flag}")
    out["demoMomentary"].append({"file": f, "maxMomentaryLufs": v, "luUnderVoice": gap})
out["worstDemoGapLu"] = worst
# the probe's own control: it must NOT return one uniform value for everything.
vals = {d["maxMomentaryLufs"] for d in out["demoMomentary"]} | {ref}
print(f"  CONTROL: {len(vals)} distinct momentary values across "
      f"{len(out['demoMomentary'])+1} files -- a single value would mean the "
      f"probe is broken, not that the mix is uniform")
out["distinctMomentaryValues"] = len(vals)

print("\n── 3. where phrases run (for pulling frames at spoken numbers) ──────")
st, en = phrases(FILM)
out["speechStarts"] = st[:80]
print(f"  {len(st)} phrase starts detected; first 12: "
      + ", ".join(f"{x:.1f}" for x in st[:12]))

json.dump(out, open(f"{HERE}/FILMCHECK.json", "w"), indent=1)
print(f"\nwrote {HERE}/FILMCHECK.json")
