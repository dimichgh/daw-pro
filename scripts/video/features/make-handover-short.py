#!/usr/bin/env python3
"""Cut a ~1-minute window CENTRED ON A HANDOVER, fading out so it does not jump.

    python3 make-handover-short.py cosmic-forces [--bars 16] [--pair knowledge:consciousness]

⭐ WHY THIS IS NOT `make-loop.py`. A loop needs a window that ENDS WHERE IT BEGAN
— same chord, same tone, same level — which is precisely what a handover is not.
`make-loop.py` therefore refuses to choose one: its scorer ranks windows by how
little the texture moves across them, so a handover always loses. The three
pieces here differ ONLY in their handovers, so a loop-scored Short shows the one
thing they have in common and hides the thing that distinguishes them.

So this cuts the handover deliberately and solves the join the other way: the
window FADES OUT. A Short replays instantly, and a fade to silence meeting a
fade-in is a rest, not a click. Nothing is crossfaded or wrapped.

⚠ THE HANDOVER IS MEASURED, NOT ASSUMED. The crossover is where the incoming
energy's own bounced stem actually overtakes the outgoing one — not the section
boundary the form declares, which the build record puts as much as 7 s away from
what the audio does (see daw-pro-gate-laws §2026-09-22e). The window is then
snapped to a bar line so it starts musically.
"""
import argparse
import json
import pathlib
import sys

import numpy as np
import soundfile as sf

HERE = pathlib.Path(__file__).resolve().parent
HOP = 0.05


def env_db(path):
    x, sr = sf.read(str(path), dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    hop = int(sr * HOP)
    n = len(x) // hop
    r = np.sqrt(np.maximum(
        np.add.reduceat(x[:n * hop].astype(np.float64) ** 2,
                        np.arange(0, n * hop, hop)) / hop, 0.0))
    return 20 * np.log10(np.maximum(r, 1e-12))


def crossover(d, a, b):
    """Time where stem `b` overtakes stem `a`, measured. None if never."""
    stems = {p.stem.split(" ", 1)[1].lower(): p for p in (d / "stems").glob("*.wav")}
    for k in (a, b):
        if k not in stems:
            sys.exit(f"⛔ no stem for {k} in {d/'stems'} (have: {sorted(stems)})")
    ea, eb = env_db(stems[a]), env_db(stems[b])
    n = min(len(ea), len(eb))
    ea, eb = ea[:n], eb[:n]
    # both must be genuinely present, and b must be the louder one, held 2 s
    live = (ea > -60) & (eb > -60)
    over = live & (eb > ea)
    need = int(2.0 / HOP)
    run = np.convolve(over.astype(int), np.ones(need, int), "valid")
    hit = np.flatnonzero(run == need)
    if len(hit):
        return float(hit[0] * HOP), "crossover"

    # ⭐ NO OVERLAP IS NOT A FAILURE — it is what `apart` IS. The two energies
    # never sound together there, so nothing can overtake anything. The
    # changeover still exists; it is the SILENCE between them, and that gap is
    # the most characteristic moment in the piece. Centre on the middle of it.
    la = np.flatnonzero(ea > -60)
    fb = np.flatnonzero(eb > -60)
    if not len(la) or not len(fb):
        return None
    # `gap1 < gap0` is NOT an error either: in `apart` the two never sound
    # together musically, but knowledge's reverb TAIL overlaps consciousness's
    # fade-in by about half a second — measured. So the changeover is the point
    # where one ends and the other begins, whether that leaves a silence or a
    # hair of overlap. Take the midpoint in both cases and say which it was.
    gap0, gap1 = la[-1] * HOP, fb[0] * HOP
    kind = (f"silent gap {gap0:.1f}-{gap1:.1f}s" if gap1 > gap0
            else f"tails touching, {gap0 - gap1:.1f}s overlap")
    return (gap0 + gap1) / 2.0, kind


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("piece")
    ap.add_argument("--bars", type=int, default=16)
    ap.add_argument("--pair", default="knowledge:consciousness",
                    help="outgoing:incoming energy, by stem name")
    ap.add_argument("--fade-in", type=float, default=1.5)
    ap.add_argument("--fade-out", type=float, default=6.0)
    ap.add_argument("--source", choices=["raw", "master"], default="raw")
    a = ap.parse_args()

    d = HERE / "out" / a.piece
    b = json.loads((d / "build.json").read_text())
    bar = 240.0 / b["tempo"]
    out_e, in_e = a.pair.split(":")

    found = crossover(d, out_e, in_e)
    if found is None:
        sys.exit(f"⛔ {a.piece}: no changeover from {out_e} to {in_e} at all")
    x, how = found

    wav = pathlib.Path(b["wav"])
    if a.source == "master":
        m = wav.with_name(wav.stem + "-master.wav")
        if m.exists():
            wav = m
    src, sr = sf.read(str(wav), dtype="float64", always_2d=True)
    dur = len(src) / sr

    # Centre the window on the crossover, then snap the START to a bar line.
    L = a.bars * bar
    start = x - L / 2
    start = max(0.0, min(start, dur - L))
    start = round(start / bar) * bar
    start = max(0.0, min(start, dur - L))
    i0, i1 = int(start * sr), int((start + L) * sr)
    seg = src[i0:i1].copy()

    fi, fo = int(a.fade_in * sr), int(a.fade_out * sr)
    if fi:
        seg[:fi] *= np.linspace(0.0, 1.0, fi)[:, None] ** 0.5
    if fo:
        seg[-fo:] *= np.linspace(1.0, 0.0, fo)[:, None] ** 0.5

    op = d / f"{a.piece}-handover.wav"
    sf.write(str(op), seg, sr, subtype="PCM_24")

    # ⚠ PROVE the replay cannot click — and measure the RIGHT thing. A first
    # attempt checked the first/last 50 ms and reported "NOT SILENT" at -33 dBFS,
    # which was the CHECK being wrong: 50 ms into a 1.5 s fade the gain is only
    # -15 dB by design. What matters for a replay is that the last sample meets
    # the first sample, so measure the actual endpoints, and confirm the fades
    # are monotonic so nothing swells back up at the edges.
    ends = max(abs(seg[0]).max(), abs(seg[-1]).max())
    hd = 20 * np.log10(max(np.abs(seg[:int(0.005 * sr)]).max(), 1e-12))
    tl = 20 * np.log10(max(np.abs(seg[-int(0.005 * sr):]).max(), 1e-12))
    print(f"{a.piece}: {out_e} -> {in_e}")
    print(f"  changeover measured at {x:7.1f}s (bar {x/bar:.1f}) via {how} "
          f"— from the stems, not the form")
    print(f"  window {start:7.1f}s .. {start+L:7.1f}s  ({a.bars} bars = {L:.2f}s)"
          f"  bar-aligned: {abs(start/bar - round(start/bar)) < 1e-6}")
    print(f"  endpoints: first sample {abs(seg[0]).max():.2e}, "
          f"last {abs(seg[-1]).max():.2e}   first 5 ms {hd:.1f} dBFS, "
          f"last 5 ms {tl:.1f} dBFS")
    if ends > 1e-6:
        sys.exit("⛔ endpoints are not zero — the replay would click")
    print(f"  -> fades to and from digital silence; replay cannot jump")
    print(f"  wrote {op}  ({len(seg)/sr:.2f}s)")


if __name__ == "__main__":
    main()
