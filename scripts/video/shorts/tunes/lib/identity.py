#!/usr/bin/env python3
"""Prove the twelve colours really are ONE line: read the notes BACK out of the
DAW and assert the twelve phrase-carrying tracks hold byte-identical material.

    python3 identity.py DIR/out/readback.json DIR/song.json [--mutate N]

Compares the tuple list of each `identity: true` track after subtracting that
track's own first onset, so the twelve copies are compared as PHRASES rather
than as positions on the timeline.

⭐ `--mutate N` corrupts the Nth track's first note by one semitone before
comparing. It must FAIL. An assertion nobody has watched fail is decoration --
this repo has shipped two checks that were literal-against-literal and could not
fail at all, and this flag is the antidote.
"""
import argparse, hashlib, json, sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("readback")
    ap.add_argument("song")
    ap.add_argument("--mutate", type=int, default=None)
    a = ap.parse_args()
    rb = json.load(open(a.readback))
    song = json.load(open(a.song))
    names = [t["name"] for t in song["tracks"] if t.get("identity")]
    if len(names) < 2:
        print("[BROKEN] identity: fewer than two identity tracks -- nothing to compare")
        return 2
    sigs = {}
    for i, nm in enumerate(names):
        if nm not in rb:
            print(f"[BROKEN] identity: '{nm}' is not in the DAW readback")
            return 2
        ns = sorted(rb[nm], key=lambda n: (n[0], n[1]))
        if a.mutate == i:
            ns[0] = [ns[0][0], ns[0][1] + 1, ns[0][2], ns[0][3]]
        t0 = ns[0][0]
        phrase = [(round(s - t0, 6), p, round(l, 6), v) for s, p, l, v in ns]
        sigs[nm] = hashlib.sha256(repr(phrase).encode()).hexdigest()[:16]
    uniq = sorted(set(sigs.values()))
    for nm in names:
        print(f"  {sigs[nm]}  {nm}")
    if len(uniq) == 1:
        print(f"[  ok  ] identity: all {len(names)} tracks carry the SAME phrase "
              f"({uniq[0]}, {len(rb[names[0]])} notes each)")
        return 0
    print(f"[ FAIL ] identity: {len(uniq)} distinct phrases across {len(names)} tracks")
    return 1


if __name__ == "__main__":
    sys.exit(main())
