#!/usr/bin/env python3
r"""⭐ THE BACH GROUND TRUTH, RUN ON THE BUILD PATH.

Moonlight's `ground_truth()` is a MOONLIGHT ground truth (bar 1 = G#3 C#4 E4,
the bass 37/49, `bars <= 59`) and asserts nothing about any other piece — that
is round 29's finding and the whole reason round 30 happened. This is BWV 846's
equivalent, and it is stronger than a hand-written expectation because the
comparison target is `source/wtk1-prelude1.mid`, which LILYPOND produced from the
same `.ly`. 549 notes, matched on pitch AND onset AND duration.

⛔ IT MUST RUN BEFORE THE TENOR HOLD. The hold rewrites 66 durations on purpose;
scoring after it would fail on the edit rather than on a transcription error.
"""
import os, sys, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location("v", os.path.join(HERE, "source", "validate.py"))
_v = importlib.util.module_from_spec(_s); _s.loader.exec_module(_v)


def check(figure, tenor, bass, bpm, bars=35):
    """`figure`/`tenor`/`bass` are take() output: [startBeat, midi, lenBeats, ...].
    Returns a one-line report; raises AssertionError on any disagreement.

    ⭐ ROUND 32: `bars` WINDOWS THE REFERENCE THE SAME WAY take() WINDOWS OURS.
    07's Short is bars 1-11, so scoring it against all 549 MIDI notes reported
    283 "unmatched" figure notes — a correct parse failing a gate whose premise
    had moved. ⚠ THE CLAMP MATTERS AS MUCH AS THE CUT: take() does
    `min(dur, end - pos)`, so a note straddling the last bar line is SHORTENED,
    and a reference that only drops notes would then mismatch it on DURATION.
    Both sides window and both sides clamp."""
    div, trk = _v.midi_notes(os.path.join(HERE, "source", "wtk1-prelude1.mid"))
    BAR = 4 * div
    END = bars * BAR
    L, U = trk[1], trk[2]          # already paired into (onTick, pitch, offTick)
    win = lambda ns: [(a, p, min(b, END)) for (a, p, b) in ns if a < END - 1e-9]
    L, U = win(L), win(U)
    ten_ref, bas_ref = [], []
    for b in sorted({t // BAR for t, _, _ in L}):
        inb = [n for n in L if n[0] // BAR == b]
        lo = min(p for _, p, _ in inb)
        for n in inb:
            (bas_ref if n[1] == lo else ten_ref).append(n)
    tot_h = tot_n = 0
    lines = []
    for nm, ours, ref in (("figure", figure, U), ("tenor", tenor, sorted(ten_ref)),
                          ("bass", bass, sorted(bas_ref))):
        mine = sorted((round(n[0] / 4.0, 9), n[1], round(n[2] / 4.0, 9)) for n in ours)
        h, n, miss, extra = _v.score(nm, mine, ref, div)
        assert not miss and not extra, (
            f"{nm}: {len(miss)} disagreements and {len(extra)} unmatched MIDI notes "
            f"against LilyPond's own render — first: {(miss or extra)[:2]}")
        tot_h += h; tot_n += n
        lines.append(f"{nm} {h}/{n}")
    want = len(U) + len(ten_ref) + len(bas_ref)
    assert tot_h == tot_n == want, f"{tot_h}/{tot_n}, expected {want}/{want}"
    # ⛔ THE WHOLE-PIECE FIGURE STAYS PINNED. A derived `want` alone would follow
    # a windowing bug wherever it went; 549 is the number the round-30 oracle
    # actually measured on the full score and it must not move.
    if bars == 35:
        assert tot_h == 549, f"the full score scored {tot_h}, not 549"
    return (f"MIDI oracle {tot_h}/{tot_n} exact over bars 1-{bars} ("
            + ", ".join(lines) + ")")
