#!/usr/bin/env python3
"""chapters.py — YouTube chapter lines for the voice film, from the MEASURED
segment start times (work/segments-map.json, written from the concat list's own
part durations), never from the manifest's estimates. Floors each start to the
second, so a chapter never begins after its picture does.

    plugins/narrated-film/.venv/bin/python tools/chapters.py   -> publish/chapters.txt
"""
import json, os, sys
HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
parts = {p[2]: p[0] for p in json.load(open(f"{HOME}/work/segments-map.json"))["parts"]}
CH = [("intro.mp4", "What we'll make"),
      ("drums-talk-mux.mp4", "Drums from DAW Pro's own drum machine"),
      ("band-talk-mux.mp4", "Bass and a pad"),
      ("lead-talk-mux.mp4", "A lead melody on its own track"),
      ("sheet-talk-mux.mp4", "Words onto the melody: the Sing sheet"),
      ("singing-talk-mux.mp4", "The built-in singer sings it"),
      ("editor-talk-mux.mp4", "The note editor: hear a note, see the cut"),
      ("sour-talk-mux.mp4", "Spoiling the take on purpose"),
      ("ttm-talk-mux.mp4", "Tune to Melody, before and after"),
      ("hard-talk-mux.mp4", "Natural vs Hard Tune"),
      ("size-talk-mux.mp4", "An octave down: Keep voice size"),
      ("voice-talk-mux.mp4", "The Voice tool"),
      ("close-talk-mux.mp4", "The finished song")]
lines, prev = [], -1
for seg, name in CH:
    if seg not in parts:
        sys.exit(f"⛔ {seg} not in segments-map.json")
    t = int(parts[seg])
    if t - prev < 10 and prev >= 0:
        sys.exit(f"⛔ chapter '{name}' is under 10 s after the previous one (YouTube drops the list)")
    lines.append(f"{t // 60}:{t % 60:02d} {name}")
    prev = t
open(f"{HOME}/publish/chapters.txt", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
