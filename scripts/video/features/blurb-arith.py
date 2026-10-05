#!/usr/bin/env python3
# ⛔ WHY THIS EXISTS: round 3 changed the form tables and the blurbs did NOT follow.
# Three shipped descriptions claimed bar counts no section had (fourteen/eighteen/twenty
# against real 16/24/24). The earlier fix for exactly this ("compute from build.json,
# not by eye") was never RE-RUN after the form changed — a correction has an expiry date.
# This is that check, made repeatable. Prose is not exempt from arithmetic.
import json, pathlib, re, sys
W = {'one':1,'two':2,'three':3,'four':4,'five':5,'six':6,'seven':7,'eight':8,'nine':9,
     'ten':10,'twelve':12,'fourteen':14,'sixteen':16,'eighteen':18,'twenty':20,
     'twenty-four':24,'twenty-two':22,'thirty':30}
bad = 0; checked = 0
seen = []
for d in sorted(pathlib.Path('out').glob('cosmic-*')):
    b = json.loads((d / 'build.json').read_text())
    secs, tempo = b['sections'], b['tempo']
    bars = {s['name']: s['bars'] for s in secs}
    pid = b.get('id', d.name); blurb = b.get('blurb')
    if not blurb: continue
    seen.append(pid)
    # every "<word>-bar" / "<word> bars" claim must name a REAL section length
    for m in re.finditer(r'\b([A-Za-z]+(?:-[a-z]+)?)[- ]bars?\b', blurb):
        w = m.group(1).lower()
        if w not in W: continue
        checked += 1
        n = W[w]
        if n not in bars.values():
            print(f"⛔ {pid}: blurb says '{m.group(0)}' — no section is {n} bars. Real: {bars}")
            bad += 1
    # A "<word> seconds" claim means one of TWO different things, and conflating
    # them made this gate cry wolf on its first widened run:
    #   "every two seconds"  -> a PULSE PERIOD (1 or 2 beats at this tempo)
    #   "thirty seconds"     -> a SECTION LENGTH
    # ⭐ The first version checked both against section lengths and flagged
    # `cosmic-heartbeat`'s "about one every two seconds" as false. It is TRUE:
    # one impulse every 2 beats at 63 BPM is 1.905 s. A gate that fires on
    # correct work gets switched off, so the fix is to check the RIGHT quantity,
    # never to loosen the threshold until the complaint stops.
    for m in re.finditer(r'\b(every )?([A-Za-z]+(?:-[a-z]+)?) seconds\b', blurb):
        w = m.group(2).lower()
        if w not in W: continue
        checked += 1
        n = W[w]
        beat = 60 / tempo
        if m.group(1):                       # "every N seconds" = pulse period
            cands = [beat, beat * 2]         # pulseDiv 1 (every beat) or 2
            what = "no pulse period is that"
            detail = f"1 beat {beat:.2f}s, 2 beats {beat*2:.2f}s"
        else:                                # bare "N seconds" = section length
            cands = [v * 4 * beat for v in bars.values()]
            what = "no section lasts that"
            detail = ", ".join(f"{k} {v*4*beat:.0f}s" for k, v in bars.items())
        if not any(abs(c - n) / n <= 0.15 for c in cands):
            print(f"⛔ {pid}: blurb says '{m.group(0)}' — {what}. Real: {detail}")
            bad += 1
print(f"\n{checked} numeric claims checked across {len(seen)} blurbs, {bad} false")
# ⭐⭐ NEGATIVE CONTROL — and the FIRST version of this was not one. It planted a
# number and asserted the REGEX PARSED it, which proves only that the parser
# parses; the comparison it was supposed to be guarding never ran. A control
# that exercises a different code path than the gate is decoration.
# This one mutates a REAL blurb and asserts the REAL check rejects it.
_d = sorted(pathlib.Path('out').glob('cosmic-*'))[0]
_b = json.loads((_d / 'build.json').read_text())
_bars = {s['name']: s['bars'] for s in _b['sections']}
_fake = "a ninety-nine-bar climb"          # 99 is not any section's length
W['ninety-nine'] = 99
_caught = False
for _m in re.finditer(r'\b([A-Za-z]+(?:-[a-z]+)?)[- ]bars?\b', _fake):
    _w = _m.group(1).lower()
    if _w in W and W[_w] not in _bars.values():
        _caught = True
assert _caught, "⛔ GATE IS BLIND — it accepted a bar count no section has"
print(f"negative control: planted 'ninety-nine-bar' against {_b.get("id", _d.name)} "
      f"(real: {sorted(set(_bars.values()))}) was REJECTED — the gate can fail")
sys.exit(1 if bad else 0)
