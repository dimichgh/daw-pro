#!/usr/bin/env python3
"""What did each take say AFTER the last word of its script?

⚠ THE PIPELINE STILL HAS NO SUCH CHECK. Part 3 found two takes that said every
word correctly and then babbled for 119 and 115 more words, passing level,
pace, brand, factCheck and a 0.83/0.87 similarity — because a tail of junk on a
1,100-character script cannot move an aggregate below the floor.

⚠⚠ AND THE FIRST VERSION OF THIS SCRIPT COULD NOT SEE A TAIL AT ALL. Part 3's
helper walks BACKWARD from the end looking for the last window containing the
script's final words; with a real tail present that window straddles the script
end, so it returns only the few words after the window rather than the whole
tail. Planted an 11-word tail: it reported 3. Every "clean, 1-word overhang"
reading it produced — including Part 3's sweep of all fourteen stages — is that
artefact, not a measurement.

This version anchors on the LAST OCCURRENCE of the script's final content word
and is POSITIVE-CONTROLLED on every run: it plants a tail of known length and
refuses to report anything if it cannot find it.
"""
import json, re, sys

W = json.load(open("wordcheck.json"))
MAN = json.load(open("out/manifest.json"))
SCRIPT = {s["id"]: s["narration"] for s in MAN["stages"]}


def words(t):
    return re.findall(r"[a-z']+", t.lower())


def tail_after(script, got):
    sw = [x for x in words(script) if len(x) > 2]
    gw = words(got)
    last = sw[-1]
    idx = max((i for i, w in enumerate(gw) if w == last), default=None)
    if idx is None:
        return None            # final word never spoken — cannot judge
    return gw[idx + 1:]


# ── POSITIVE CONTROL FIRST. A detector not shown to find a tail is a printer. ─
PLANT = ("and then the wheel of pandemics is the signature between thirty three "
         "degrees and forty five")
n_plant = len(words(PLANT))
for sid in SCRIPT:
    got = tail_after(SCRIPT[sid], SCRIPT[sid] + " " + PLANT)
    if got is None or len(got) != n_plant:
        sys.exit(f"TAILCHECK REFUSES — the detector found "
                 f"{len(got) if got is not None else 'nothing'} of a planted "
                 f"{n_plant}-word tail on {sid}. It cannot see a real one either.")
print(f"positive control: a planted {n_plant}-word tail is detected as "
      f"{n_plant} words on all {len(SCRIPT)} stages\n")

bad = []
for sid in SCRIPT:
    t = tail_after(SCRIPT[sid], W[sid]["transcript"])
    if t is None:
        print(f"  {sid:12s} ⚠ final word never spoken — cannot judge")
        bad.append(sid)
    elif len(t) > 2:
        print(f"  {sid:12s} ✘ TAIL {len(t)} words: {' '.join(t[:16])}")
        bad.append(sid)
    else:
        print(f"  {sid:12s} clean ({len(t)} words after the script's last word)")
print(f"\nstages with a tail: {len(bad)} of {len(SCRIPT)}  {bad}")
