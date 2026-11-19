#!/usr/bin/env python3
"""content-gate.py — transcribe every KEPT narration take and compare it to the
script, word list against word list (difflib, autojunk=False), and write the
table to work/content-gate.json. A re-check of the takes narrate.py kept, with
the transcript itself saved, so a reader can see WHAT was heard, not only a
score.

    OMLX_BASE=... content-gate.py

Uses narrate.py's own transcribe() and similarity() — the same whisper model
and the same scoring — imported from the demo-film skill, not re-implemented.
"""
import json, os, sys
sys.path.insert(0, "/Users/dsemenov/Views/daw-pro/claude-plugin/skills/demo-film/scripts")
import narrate  # noqa: E402

HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
man = json.load(open(f"{HOME}/manifest.json"))
rows, worst = [], 1.0
for st in man["stages"]:
    if not st.get("narration"):
        continue
    wav = f"{HOME}/vo/{st['id']}.wav"
    heard = narrate.transcribe(wav)
    sim = narrate.similarity(st["narration"], heard)
    d, rms = narrate.measure(wav)
    rows.append({"id": st["id"], "similarity": round(sim, 3), "seconds": round(d, 2), "rmsDb": round(rms, 1),
                 "script": st["narration"], "heard": heard})
    worst = min(worst, sim)
    print(f"{st['id']:8s} sim {sim:.2f}  {d:5.1f}s  heard: {heard[:110]}")
json.dump(rows, open(f"{HOME}/work/content-gate.json", "w"), indent=1)
print(f"\nworst similarity {worst:.2f} (gate {narrate.SIM_MIN})")
sys.exit(0 if worst >= narrate.SIM_MIN else 1)
