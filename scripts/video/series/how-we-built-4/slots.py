#!/usr/bin/env python3
"""What is on screen, and when, for every talk segment — computed with
assemble.py's OWN formula rather than by intuition:

    n = max(1, round(total / cut));  holdLast -> seq[i] = shots[min(i, len-1)]
    each = total / n
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAN = json.load(open(f"{HERE}/out/manifest.json"))


def dur(p):
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                                 "format=duration", "-of", "default=nw=1:nk=1", p],
                                capture_output=True, text=True).stdout.strip())


want = sys.argv[1] if len(sys.argv) > 1 else None
for st in MAN["stages"]:
    if want and st["id"] != want:
        continue
    p = f"{HERE}/out/segments/{st['id']}-talk-mux.mp4"
    if not os.path.exists(p):
        continue
    total = dur(p)
    cut = st.get("cut", MAN["video"]["cut"])
    shots = st["shots"]
    n = max(1, round(total / cut))
    seq = [shots[min(i, len(shots) - 1)] for i in range(n)] if st.get("holdLast") \
        else [shots[i % len(shots)] for i in range(n)]
    each = total / n
    print(f"\n{st['id']}  {total:.2f}s  cut {cut}  n={n}  each={each:.2f}s  "
          f"{len(shots)} shots")
    for i, s in enumerate(seq):
        print(f"   {i*each:6.2f}-{(i+1)*each:6.2f}  {s}")
