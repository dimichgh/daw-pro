#!/usr/bin/env python
"""Re-make the brand outro with the corrected (non-narration) card and re-ship.

WHY THIS EXISTS AS A SEPARATE SCRIPT: the outro card shipped by all six films
read "Narration is a synthetic voice. No music-generation model was used." on a
film that has NO narration. No gate can see words on a card; I found it by
opening a frame of the finished canon. Re-running tunesmith.py end-to-end would
rebuild the project, the render and 1500 frames of picture to change 12 words,
so this reuses each film's `body.mp4` -- which already carries the CONVERGED
true-peak trim from the original build -- re-concats, re-applies the corner
meter, and RE-RUNS BOTH GATES so nothing ships unjudged.
"""
import json, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "/Users/dsemenov/Views/daw-pro"
PLUGIN = f"{REPO}/plugins/narrated-film"
VENV = f"{PLUGIN}/.venv/bin/python"
W, H = 1080, 1920

def run(c, **k):
    p = subprocess.run(c, capture_output=True, text=True, **k)
    if p.returncode: sys.exit(f"FAILED {c[:3]}\n{p.stdout}\n{p.stderr}")
    return p.stdout

def ff(p, *a): return run(["ffprobe", "-v", "error", *a, "-of", "csv=p=0", p]).strip()
def dur(p): return float(ff(p, "-show_entries", "format=duration"))
def tp(p):
    o = subprocess.run(["ffmpeg","-hide_banner","-i",p,"-af","ebur128=peak=true","-f","null","-"],
                       capture_output=True, text=True).stderr
    v=[l for l in o.splitlines() if "Peak:" in l]
    return float(v[-1].split()[-2]) if v else None
def lufs(p):
    o = subprocess.run(["ffmpeg","-hide_banner","-i",p,"-af","ebur128=framelog=verbose","-f","null","-"],
                       capture_output=True, text=True).stderr
    for i,l in enumerate(o.splitlines()):
        if l.strip().startswith("I:") and "LUFS" in l: last=l
    return float(last.split()[-2])

d = os.path.abspath(sys.argv[1])   # ⚠ concat list paths resolve against the LIST FILE dir
OUT = os.path.join(d, "out")
song = json.load(open(os.path.join(d, "song.json")))
sid = song["id"]
body = os.path.join(OUT, "body.mp4")
outro = os.path.join(OUT, "outro.mp4")
film = os.path.join(OUT, f"{sid}.mp4")
assert os.path.exists(body), body

run([VENV, f"{PLUGIN}/scripts/brand.py", "outro", "--brand", f"{HERE}/brand.tunes.json",
     "--theme", "tunes", "--size", f"{W}x{H}", "--seconds", "2.4", "--out", outro])
V = ("-show_entries", "stream=width,height,r_frame_rate,pix_fmt,sample_aspect_ratio",
     "-select_streams", "v:0")
A = ("-show_entries", "stream=codec_name,sample_rate,channels", "-select_streams", "a:0")
for tag, sel in (("v", V), ("a", A)):
    if ff(outro, *sel) != ff(body, *sel):
        sys.exit(f"{d}: outro stream mismatch ({tag}): {ff(outro,*sel)} vs {ff(body,*sel)}")
lst = os.path.join(OUT, "_concat.txt")
open(lst, "w").write(f"file '{body}'\nfile '{outro}'\n")
nometer = os.path.join(OUT, f"{sid}-nometer.mp4")
run(["ffmpeg","-hide_banner","-loglevel","error","-y","-f","concat","-safe","0","-i",lst,
     "-c","copy",nometer])
if os.path.exists(film): os.remove(film)
run([VENV, f"{REPO}/scripts/video/meter.py", nometer, film, "--work", os.path.join(OUT,"seg"),
     "--corner","br","--start","0","--short"])

D, L, P = dur(film), lufs(film), tp(film)
print(f"{sid}: {D:.3f}s  {L} LUFS  {P} dBTP  {os.path.getsize(film)} bytes")
if P > -1.0: sys.exit(f"{sid}: true peak {P} over -1.0 dBTP after re-outro")

man = {"video": {"width": W, "height": H, "fps": 30},
       "stages": [{"id": sid, "narration": "", "shots": []}]}
manp = os.path.join(OUT, "manifest.json"); json.dump(man, open(manp,"w"), indent=1)
v = subprocess.run([VENV, f"{PLUGIN}/scripts/verify.py","--film",film,"--manifest",manp,
                    "--joins", f"{dur(body):.3f}"], capture_output=True, text=True)
fails=[l.strip() for l in v.stdout.splitlines() if l.lstrip().startswith("[ FAIL ]")]
broken=[b.strip() for b in v.stdout.splitlines() if b.lstrip().startswith("[BROKEN]")]
broken=[b for b in broken if "narrated stages" not in b]
s = subprocess.run([VENV, f"{HERE}/sync.py", film, os.path.join(d,"song.json")],
                   capture_output=True, text=True)
print("  " + "\n  ".join(s.stdout.strip().splitlines()[-3:]))
if s.returncode: fails.append(s.stdout.strip().splitlines()[-1])
print(f"  verify: {len([l for l in v.stdout.splitlines() if '[  ok  ]' in l])} ok, "
      f"{len(fails)} fail, {len(broken)} broken(unallowed)")
if fails or broken: sys.exit("GATES FAILED:\n" + "\n".join(fails+broken))
r = os.path.join(OUT, "build-report.json")
rep = json.load(open(r)); rep.update({"duration": round(D,3), "integratedLufs": L,
    "truePeakDbtp": P, "bytes": os.path.getsize(film), "outroRebuilt": "brand.tunes.json"})
json.dump(rep, open(r,"w"), indent=1)
