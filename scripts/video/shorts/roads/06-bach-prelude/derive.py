#!/usr/bin/env python3
r"""⭐ EVERY TIMESTAMP IN DESCRIPTION.md, DERIVED FROM song.json AND THE PAYLOAD.

⛔ THE MOONLIGHT FILE RECORDS THREE FALSE CLAIMS AND ALL THREE CAME FROM THE SAME
MISTAKE: counting note ONSETS in a bar and concluding an instrument was absent.
AN ONSET COUNT IS NOT A SOUNDING COUNT. So every "is X playing here" question
below is answered from `start <= t < start + length`, never from onsets.
"""
# ⭐ ROUND 32: ONE DERIVER, POINTED AT A DIRECTORY — 07 and 08 do not get copies.
# The bar-33 error of round 31 was a typed number in exactly this file, and a
# second and third copy of it is three places for the same mistake to live.
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else HERE
S = json.load(open(os.path.join(DIR, "song.json")))
P = json.load(open(os.path.join(DIR, "out", "payload.json")))
BPM = S["tempoSegments"][0]["bpm"]; LAG = S["vizLagMs"] / 1000.0
T = lambda beat: beat * 60.0 / BPM + LAG
MS = lambda s: f"{int(s)//60}:{int(s)%60:02d}"
TR = {t["name"]: t["notes"] for t in S["tracks"]}
bar = lambda n: T((n - 1) * 4)

print(f"[{os.path.basename(DIR)}] id {S['id']}")
print(f"tempo {BPM} BPM, lag {LAG*1000:.1f} ms, {S['lengthBeats']} beats, "
      f"music {S['renderSeconds']}s, picture {S['pictureSeconds']}s")
# ⚠ THE CROSS-CHECK IS INDEXED FROM THE END, not from a typed bar number: at
# BACH_BARS=11 there is no bar 24 and `P['bars'][23]` was an IndexError.
_nb = len(P["bars"])
print(f"payload bar lines: {_nb}; bar {_nb} payload {P['bars'][-1]['t']:.4f} "
      f"vs derived {bar(_nb):.4f}")

rows = []
rows.append(("the piece begins", "bar 1 line; BOTH left-hand voices sound at beat 0 "
             "and the figure at beat 0.5", bar(1)))
# the pedal: the bass pitch that does not change
bassn = sorted(TR["Bass"])
run, best = [], None
for i, n in enumerate(bassn):
    if run and n[1] == bassn[run[-1]][1]:
        run.append(i)
    else:
        run = [i]
    if best is None or len(run) > len(best):
        best = list(run)
p0, p1 = bassn[best[0]], bassn[best[-1]]
pedal_end = p1[0] + p1[2]
# ⚠ ONLY REPORTED WHEN THERE IS ONE. The 11-bar Short's longest single-pitch
# bass run is 2 onsets — one ordinary bar — and calling that "the pedal" would be
# the same class of mistake as typing bar 32: a row that reads like a measurement
# and is an artefact of the window.
PEDAL = len(best) >= 8
if PEDAL:
    rows.append(("the G2 pedal begins", f"longest run of ONE bass pitch: MIDI {p0[1]}, "
                 f"{len(best)} onsets from beat {p0[0]:g}", T(p0[0])))
    rows.append(("the G2 pedal ends", f"that run's LAST note SOUNDS to beat {pedal_end:g} "
                 "(a sounding end, not an onset)", T(pedal_end)))
else:
    print(f"  (no pedal in this span: the longest single-pitch bass run is "
          f"{len(best)} onsets on MIDI {p0[1]} — not reported as one)")
# ⚠ THE PATTERN BREAK IS COMPUTED, NOT TYPED. Round 31's first draft typed
# bar 32 (where the BASS lands on C) and called it the figure's break; the
# half-bar test says the figure's halves are identical through bar 32.
def halves_differ(n):
    b0 = (n - 1) * 4
    h1 = sorted(x[1] for x in TR["Figure"] if b0 <= x[0] < b0 + 2)
    h2 = sorted(x[1] for x in TR["Figure"] if b0 + 2 <= x[0] < b0 + 4)
    return h1 != h2
NB = len(P["bars"]) - 1   # bar LINES; the last line is the end, not a bar
_same = [n for n in range(1, NB + 1) if not halves_differ(n)]
_diff = [n for n in range(1, NB + 1) if halves_differ(n)]
BREAK = _diff[0] if _diff else None
if BREAK is None:
    print(f"  (the figure's half-bars are IDENTICAL in all {NB} bars of this span "
          f"— there is no pattern break here to report)")
if BREAK is not None:
  rows.append(("the pattern breaks", f"first bar whose figure half-bars DIFFER, computed: "
               f"bar {BREAK} of {NB}; halves IDENTICAL in {len(_same)} bars "
               f"({_same[0]}–{_same[-1]}), DIFFERING only in "
               + ", ".join(str(n) for n in _diff), bar(BREAK)))
fin = max(TR["Figure"], key=lambda n: n[0])
rows.append(("the final chord" if len(P["bars"]) - 1 == 35 else "the figure's last note",
             f"last figure onset, beat {fin[0]:g}, "
             f"{len([n for n in TR['Figure'] if n[0] == fin[0]])} notes, "
             f"{fin[2]:g} beats long", T(fin[0])))
last = max(n[0] + n[2] for ns in TR.values() for n in ns)
rows.append(("the last sound ends", f"max(start+length) over all three roads, "
             f"beat {last:g}", T(last)))

# ⚠ ON AN EXCERPT, THE ARRIVAL BAR LINE IS A TABLE ROW TOO. It was in 07's
# DESCRIPTION and NOT in this output — correct in value, typed in provenance,
# which is the whole failure mode this deriver exists to prevent.
if NB < 35:
    rows.append((f"bar {NB} — the arrival lands",
                 f"bar line, ({NB}-1)*4 beats at the session tempo + the lag",
                 T((NB - 1) * 4)))

# ⭐ THE END CARD AND THE FILM'S OWN END ARE PART OF THE TABLE, so that "every
# timestamp is derived" is true of EVERY row and not just the musical ones. Read
# from song.json and from the rendered frames on disk — never typed.
_ec = (S.get("look") or {}).get("endCard") or {}
if "at" in _ec:
    rows.append(("the end card begins", 'song.json look.endCard.at', float(_ec["at"])))
_fr = os.path.join(DIR, "out", "frames")
if os.path.isdir(_fr):
    _n = len([f for f in os.listdir(_fr) if f.endswith(".png")])
    rows.append(("the film ends", f"last of {_n} rendered frames: ({_n}-1)/30",
                 (_n - 1) / 30.0))

rows.sort(key=lambda r: r[2])   # chronological; the rows are appended by topic
print("\n| moment | derived from | seconds | m:ss |")
print("|---|---|---|---|")
for nm, how, s in rows:
    print(f"| {nm} | {how} | {s:.3f} | {MS(s)} |")

# ⚠ A 44-SECOND VERTICAL SHORT HAS NO CHAPTERS — the surface does not show them,
# and three chapter marks inside forty seconds would be noise even where it did.
# Printed anyway so the numbers exist; the Short's DESCRIPTION.md does not use it.
print("\nCHAPTERS (paste block)"
      + ("" if len(P["bars"]) - 1 == 35 else
         "  — ⚠ NOT FOR THE SHORT: a 44 s vertical cut has no chapter surface"))
_chapters = [("Bars 1–10 — the figure, and the two voices under it", bar(1))]
if NB >= 11: _chapters.append(("Bar 11 — the harmony moves off the opening", bar(11)))
if NB >= 19: _chapters.append(("Bar 19 — the approach", bar(19)))
if PEDAL:    _chapters.append(("Bars 24–31 — the pedal: the bass stops moving", T(p0[0])))
if NB >= 32: _chapters.append(("Bar 32 — the bass lands on C", bar(32)))
if BREAK is not None:
    _chapters.append((f"Bar {BREAK} — the figure breaks its own pattern", bar(BREAK)))
_chapters.append((f"Bar {NB} — " + ("the final chord" if NB == 35 else "the arrival the excerpt ends on"),
                  T(fin[0])))
for nm, s in _chapters:
    print(f"{MS(s)} {nm}")

# ⚠ THE SOUNDING TEST, run rather than asserted in prose.
print("\nSOUNDING CHECK (start <= t < start+length, never an onset count)")
_probe = ((bar(24) + 1, bar(28), bar(31) + 3, bar(34)) if NB >= 35
          else (bar(1) + 1, bar(NB // 2), bar(NB) + 1, bar(NB) + 3))
for t in _probe:
    live = {k: sum(1 for n in v if n[0] <= (t - LAG) * BPM / 60 < n[0] + n[2]) for k, v in TR.items()}
    print(f"  t={t:7.3f}s  sounding: " + "  ".join(f"{k} {c}" for k, c in live.items()))

# ═════════════════════════════════════════════════════════════════════════════
# ⭐ THE SHORT'S SPAN, JUSTIFIED BY COMPUTATION RATHER THAN BY PROSE (round 32).
# Only printed for an excerpt. The rule: a Short must END WHERE THE MUSIC ENDS A
# THOUGHT, and this piece has NO RESTS to end on — the figure runs unbroken 16ths
# from bar 1 to bar 33 — so the phrase boundary has to come from the HARMONY.
# The test is a descending-fifths chain in the bass terminating at the last bar,
# plus a root-position triad on that bass in the final bar.
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
if NB < 35:
    def bass_of(n):
        b0 = (n - 1) * 4
        ps = [x[1] for x in TR["Bass"] if b0 <= x[0] < b0 + 4]
        return min(ps) if ps else None
    chain = [NB]
    while len(chain) < NB:
        a, b = bass_of(chain[0] - 1), bass_of(chain[0])
        # ⛔ NO `a > b`. My first cut required the bass to FALL, and it measured
        # a chain of ONE — because bars 9-11 read A3(57) -> D3(50) -> G3(55):
        # the last step RISES a fourth. A fourth up and a fifth down are the same
        # root motion, and a bass line that never changed register would be a
        # different piece. The pitch-class test is the whole test.
        if a is None or b is None or (a - b) % 12 != 7:
            break
        chain.insert(0, chain[0] - 1)
    last = bass_of(NB)
    b0 = (NB - 1) * 4
    fig = sorted({x[1] % 12 for x in TR["Figure"] if b0 <= x[0] < b0 + 4})
    ten = sorted({x[1] % 12 for x in TR["Tenor"] if b0 <= x[0] < b0 + 4})
    iv = sorted({(p - last) % 12 for p in fig + ten + [last]})
    quality = {(0, 4, 7): "major", (0, 3, 7): "minor"}.get(tuple(iv), "not a plain triad")
    print(f"\nSPAN — why bars 1-{NB}")
    print(f"  root-motion-by-fifth chain in the bass terminating at bar {NB} "
          f"(each root a fifth below the last, register free — a rising fourth "
          f"is the same motion): bars "
          f"{chain[0]}-{chain[-1]} = "
          + " -> ".join(f"{NAMES[bass_of(n) % 12]}{bass_of(n)//12-1}" for n in chain)
          + f"  ({len(chain)} bars)")
    print(f"  bar {NB} chord over its own bass: intervals {iv} = {quality} "
          f"on {NAMES[last % 12]}{last//12-1}")
    # ⚠ THE NEXT BAR IS NOT IN THIS song.json — the excerpt stops at NB. Whether
    # the chain TERMINATES at NB or merely passes through it can only be answered
    # from the FULL score, so it is read from 06's own song.json (the approved
    # 35-bar film) rather than asserted. If that file is not there, say so
    # instead of implying the check ran.
    _full = os.path.join(HERE, "song.json")
    if os.path.exists(_full):
        FB = {t["name"]: t["notes"] for t in json.load(open(_full))["tracks"]}["Bass"]
        nxt = [x[1] for x in FB if NB * 4 <= x[0] < NB * 4 + 4]
        nxt = min(nxt) if nxt else None
        print(f"  bar {NB+1} in the FULL score (06/song.json): bass "
              + (f"{NAMES[nxt % 12]}{nxt//12-1}" if nxt else "none")
              + (f" — the chain does NOT continue, bar {NB} is its terminus"
                 if nxt is not None and (last - nxt) % 12 != 7 else
                 f" — ⚠ the chain CONTINUES past bar {NB}"))
    else:
        print("  bar NB+1: NOT CHECKED — 06/song.json (the full score) is not here")
    print(f"  the arrival LANDS at bar {NB}'s line, {T((NB-1)*4):.3f}s = "
          f"{MS(T((NB-1)*4))}; the excerpt runs to the END of that bar and stops "
          f"at {T(NB*4):.3f}s = {MS(T(NB*4))}, not partway into the next move")
