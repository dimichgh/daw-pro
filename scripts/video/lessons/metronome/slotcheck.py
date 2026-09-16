#!/usr/bin/env python3
"""Which still is on screen when each number is SPOKEN.

⚠⚠ NO GATE IN THIS KIT SEES THIS, and it has shipped twice: a card carrying a
value that had already cut away 18 seconds before the value was read, and a
chart on screen while the words describing a different picture were spoken.

The still timer in assemble.py is NOT "evenly spread across the stage":

    n = max(1, round(total / cut));  each = total / n
    holdLast:  seq = [shots[min(i, len(shots)-1)] for i in range(n)]
    otherwise: seq = [shots[i % len(shots)] for i in range(n)]

So a three-shot holdLast stage of 33 s at cut 5.4 gives SIX slots of 5.49 s, and
the third shot owns slots 3-6 — the first two shots get 5.49 s each and the
rest of the stage belongs to the last one. Guessing at this is what produced
both shipped defects.

This estimates the spoken time of each factCheck phrase from its WORD POSITION
in the narration (speech is close enough to uniform in words per second for
this purpose) and prints which slot it lands in. It is a POINTER, not a proof —
the proof is pulling the frame at the printed film time and looking at it, and
the script prints the exact ffmpeg command for that.
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = json.load(open(f"{HERE}/L7v2.json"))
SEG = f"{HERE}/out/segments"
DEFAULT_CUT = SPEC.get("cut", 4.2)
EXTRA = [a.lower() for a in sys.argv[1:]]   # extra phrases to locate, beyond factCheck


def label(s):
    """⚠ TWO CROPS OF ONE PNG PRINT THE SAME NAME unless the rect is shown --
    that is how a zoom-order defect hides in this very audit."""
    if isinstance(s, dict):
        return os.path.basename(s.get("path", "?")) + " zoom=" + str(s.get("zoom"))
    if isinstance(s, int):
        return f"card {s}"
    return os.path.basename(str(s))


def dur(p):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                        "-of", "csv=p=0", p], capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return None


# film-time offset of every segment, from the concat list the film was built from
order, t = [], 0.0
for line in open(f"{SEG}/_all.txt"):
    if not line.startswith("file"):
        continue
    f = line.split("'")[1]
    p = f if os.path.isabs(f) else os.path.join(SEG, f)
    d = dur(p)
    order.append((os.path.basename(p), t, d))
    t += d
offset = {n: (a, d) for n, a, d in order}

bad = 0
for st in SPEC["stages"]:
    seg = f"{st['id']}-talk-mux.mp4"
    if seg not in offset:
        continue
    at, total = offset[seg]
    cut = st.get("cut", DEFAULT_CUT)
    shots = st["shots"]
    n = max(1, round(total / cut))
    each = total / n
    if st.get("holdLast", True):
        seq = [shots[min(i, len(shots) - 1)] for i in range(n)]
    else:
        seq = [shots[i % len(shots)] for i in range(n)]
    words = st["narration"].split()
    wps = len(words) / total
    print(f"\n{st['id']}  talk {total:.2f}s at {at:.1f}s, cut {cut}, {n} slots of {each:.2f}s")
    for i, s in enumerate(seq):
        nm = label(s)
        print(f"    slot {i}  {i*each:6.2f}-{(i+1)*each:6.2f}s   {os.path.basename(str(nm))}")
    low = st["narration"].lower()
    for f in list(st.get("factCheck", [])) + [e for e in EXTRA if e in low]:
        alts = f if isinstance(f, (list, tuple)) else [f]
        phrase = next((a for a in alts if str(a).lower() in low), None)
        if phrase is None:
            continue
        # word index of the phrase's first word
        wi = len(st["narration"][:low.index(str(phrase).lower())].split())
        ts = wi / wps
        slot = min(int(ts / each), n - 1)
        nm = seq[slot]
        nm = label(nm)
        print(f'    "{phrase}"  ~{ts:5.1f}s into the stage  -> slot {slot} '
              f'({os.path.basename(str(nm))})   FILM t={at+ts:.1f}s')
        print(f"       ffmpeg -hide_banner -loglevel error -y -ss {at+ts:.1f} "
              f"-i out/L7v2.mp4 -frames:v 1 /tmp/f_{st['id']}_{wi}.png")
print("\n⚠ this is an ESTIMATE from word position. Pull the frames and LOOK.")
