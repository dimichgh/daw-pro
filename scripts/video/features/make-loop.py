#!/usr/bin/env python3
"""Cut a SEAMLESSLY LOOPING window out of a finished piece.

    python3 make-loop.py cosmic-ascent-5m [--bars 8] [--xfade 2.0]

⭐ WHY A LOOP IS NOT JUST A SHORTER CUT. A Short replays the instant it ends, so
the join is heard on every repeat — it is the single most-listened moment in the
video. Three separate things have to be true, and the shipped Shorts got none of
them:

  1. THE HARMONY MUST CLOSE. `cosmic-material.mjs` cycles i-VI-III-VII-iv over
     EIGHT bars, indexed by ABSOLUTE bar (`chords[(bar0 + b) % 8]`), so a window
     that is an exact multiple of 8 bars ends on the chord it began on — for any
     start bar. A 36-second window is 9.45 bars at 63 BPM and lands on a
     different chord, which is why the shipped ones lurch.
  2. THE TONE MUST MATCH. Harmony closing is necessary, not sufficient: these
     sections sweep a filter and add layers as they go, so the same chord eight
     bars later can be several dB louder and much brighter. MEASURED, not
     assumed: at Summit's start the piece is 3.0 dB quieter than eight bars in.
     So this script SEARCHES the candidate windows and scores them, rather than
     trusting the first bar-aligned one.
  3. THE REVERB TAIL MUST CARRY OVER. Even a perfect musical match clicks,
     because at the loop's end a reverb tail is ringing that does not exist at
     its start. Fixed by a crossfade WRAP: the head of the loop is summed with
     the material that would have followed its end, equal-power. The tail then
     decays across the join exactly as it would have in the full piece.

⛔ AND THE SHIPPED SHORTS ALSO END IN 2.4 SECONDS OF DIGITAL SILENCE — the outro
card. Measured at -inf dBFS. No amount of musical care survives that, so a
looping Short does not get a tail card; the brand goes in-frame instead.
"""
import argparse
import json
import pathlib
import sys

import numpy as np
import soundfile as sf

HERE = pathlib.Path(__file__).resolve().parent


def probe_spectrum(x, sr, bands=28):
    """Log-spaced band energies in dB — a coarse timbre fingerprint."""
    mono = x.mean(axis=1) if x.ndim > 1 else x
    if len(mono) < 1024:
        return None
    win = np.hanning(len(mono))
    mag = np.abs(np.fft.rfft(mono * win))
    freqs = np.fft.rfftfreq(len(mono), 1 / sr)
    edges = np.geomspace(40, min(16000, sr / 2 - 1), bands + 1)
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        sel = (freqs >= lo) & (freqs < hi)
        out.append(np.sqrt((mag[sel] ** 2).mean()) if sel.any() else 1e-12)
    return 20 * np.log10(np.maximum(np.array(out), 1e-12))


def rms_db(x):
    return 20 * np.log10(max(float(np.sqrt((x ** 2).mean())), 1e-12))


def score(src, sr, t0, L, probe=2.0):
    """How well does the material at t0 match the material at t0+L?

    Lower is better. Returns (total, rms_delta_dB, spectral_mean_abs_dB).
    """
    n = int(probe * sr)
    a = src[int(t0 * sr): int(t0 * sr) + n]
    b = src[int((t0 + L) * sr): int((t0 + L) * sr) + n]
    if len(a) < n or len(b) < n:
        return None
    dr = abs(rms_db(a) - rms_db(b))
    sa, sb = probe_spectrum(a, sr), probe_spectrum(b, sr)
    ds = float(np.abs(sa - sb).mean())
    # ⭐ BOTH AXES, WEIGHTED TO WHAT IS AUDIBLE. A 1 dB level step at the loop is
    # about as noticeable as ~2 dB of average spectral drift, so level counts
    # double. Weighting is a judgement, so it is written down rather than buried.
    return (dr * 2.0 + ds, dr, ds)


def build_loop(src, sr, t0, L, xf, curve="eqpower"):
    """The loop body, with its head crossfaded against the material that would
    have followed its end. Equal power (sin/cos), because a reverb tail and a
    fresh attack are uncorrelated — linear would dip ~3 dB in the middle."""
    n_l, n_x = int(round(L * sr)), int(round(xf * sr))
    s0 = int(round(t0 * sr))
    out = np.array(src[s0: s0 + n_l], dtype=np.float64)
    tail = src[s0 + n_l: s0 + n_l + n_x]
    if len(tail) < n_x:
        sys.exit(f"⛔ not enough material after the window for a {xf}s crossfade")
    # ⛔ EQUAL POWER IS WRONG WHEN THE TWO SIDES ARE CORRELATED. sin+cos keeps
    # POWER constant, which is right for a reverb tail against a fresh attack
    # (uncorrelated — linear would dip ~3 dB mid-fade). But `heartbeat` has a
    # pulse on the beat, and the loop is a whole number of bars, so the pulse in
    # the tail lands on the SAME instant as the pulse in the head. Identical
    # events sum in AMPLITUDE, not power, so equal-power made the pulse at the
    # join ~3 dB louder than any other — measured as a flux spike above the 99th
    # percentile of the piece's own frames. Linear sums to exactly 1 and is the
    # correct choice wherever the two sides carry the same rhythmic event.
    w = np.linspace(0, np.pi / 2, n_x)
    if curve == "linear":
        fi = np.linspace(0, 1, n_x); fo = 1 - fi
    else:
        fi, fo = np.sin(w), np.cos(w)
    if out.ndim > 1:
        fi, fo = fi[:, None], fo[:, None]
    out[:n_x] = out[:n_x] * fi + tail * fo
    return out


def seam_report(loop, sr):
    """⭐ THE ONLY TEST THAT MATTERS: play the loop twice and look at the join.

    A click is a sample-to-sample jump far larger than the material's own. So
    compare the delta ACROSS the seam against the distribution of deltas inside
    the loop — a POSITIVE CONTROL built from the same audio, not a fixed
    threshold that would pass anything quiet."""
    mono = loop.mean(axis=1) if loop.ndim > 1 else loop
    d = np.abs(np.diff(mono))
    seam = abs(float(mono[0]) - float(mono[-1]))
    p999 = float(np.percentile(d, 99.9))
    mx = float(d.max())
    # level continuity across the join, 0.25 s either side
    n = int(0.25 * sr)
    before, after = rms_db(mono[-n:]), rms_db(mono[:n])
    return {
        "seam_jump": seam,
        "p99.9_internal": p999,
        "max_internal": mx,
        "click": seam > mx,
        "rms_before_dB": before,
        "rms_after_dB": after,
        "rms_step_dB": abs(before - after),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("piece")
    ap.add_argument("--bars", type=int, default=8,
                    help="loop length in bars — MUST be a multiple of 8 or the "
                         "harmony does not close (the script refuses otherwise)")
    ap.add_argument("--xfade", type=float, default=2.0)
    ap.add_argument("--curve", choices=["eqpower", "linear"], default="eqpower",
                    help="eqpower for uncorrelated tails; linear when both sides "
                         "carry the same on-beat event (pulsed pieces)")
    ap.add_argument("--probe", type=float, default=2.0)
    ap.add_argument("--loud-tol", type=float, default=3.0,
                    help="how many dB below the loudest candidate window a "
                         "window may be and still be considered (default 3)")
    ap.add_argument("--from", dest="t_from", type=float, default=None)
    ap.add_argument("--to", dest="t_to", type=float, default=None)
    ap.add_argument("--source", choices=["master", "raw"], default="master",
                    help="cut from the mastered piece (default, what the shipped "
                         "loopshorts used) or from the raw render, which avoids "
                         "mastering twice and leaves the loop its own headroom")
    ap.add_argument("--out", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if args.bars % 8:
        sys.exit(f"⛔ --bars {args.bars} is not a multiple of 8. The chord cycle "
                 "is 8 bars; any other length ends on a different chord. If you "
                 "genuinely want that, change the cycle, not this check.")

    d = HERE / "out" / args.piece
    b = json.loads((d / "build.json").read_text())
    tempo = b["tempo"]
    wav = pathlib.Path(b["wav"])
    master = wav.with_name(wav.stem + "-master.wav")
    # ⚠ DEFAULT IS THE MASTER, and the shipped -5m loopshorts were cut that way —
    # do not change it. But it means DOUBLE MASTERING: the piece is normalised to
    # -18 LUFS with its true peak pushed near the ceiling, the loop is cut out of
    # that, and `master-loop.py` then tries for -14. Measured 2026-09-22: a piece
    # whose master sat at -1.0 dBTP left the loop ZERO headroom, so its Short came
    # out 3.6 LU quieter than its siblings — and three Shorts meant to be compared
    # arrived at -14.0 / -15.8 / -17.6. `--source raw` cuts from the unmastered
    # render instead, so the loop gets the whole headroom budget once.
    if args.source == "master" and master.exists():
        wav = master
    if args.source == "raw" and not wav.exists():
        sys.exit(f"⛔ raw render missing: {wav}")
    print(f"  source: {wav.name}")
    src, sr = sf.read(str(wav), dtype="float64", always_2d=True)
    bar = 4 * 60 / tempo
    L = args.bars * bar
    dur = len(src) / sr

    # candidate starts: every bar boundary in the search region
    lo = args.t_from if args.t_from is not None else 0.0
    hi = args.t_to if args.t_to is not None else dur
    cands = []
    k = 0
    while True:
        t0 = k * bar
        k += 1
        if t0 > hi:
            break
        if t0 < lo:
            continue
        if t0 + L + args.xfade > dur:
            break
        s = score(src, sr, t0, L, args.probe)
        if s:
            body = src[int(t0 * sr): int((t0 + L) * sr)]
            cands.append((s[0], s[1], s[2], t0, k - 1, rms_db(body)))
    if not cands:
        sys.exit("⛔ no candidate window fits — check --from/--to and the tempo")
    # ⛔⛔ MATCH ALONE PICKS THE DULLEST PASSAGE IN THE PIECE. A quiet, static
    # window matches itself beautifully — the first run of this search chose a
    # -29.7 dB stretch of Aurora over its climax, because nothing happening is
    # the easiest thing to loop. A Short has about one second to hook, so a
    # window that loops perfectly and says nothing is a worse answer than a
    # slightly harder join. Candidates must first be within LOUD_TOL dB of the
    # loudest window in the search region; the match score only ranks survivors.
    loudest = max(c[5] for c in cands)
    keep = [c for c in cands if c[5] >= loudest - args.loud_tol]
    dropped = len(cands) - len(keep)
    cands, all_cands = keep, cands
    cands.sort()

    print(f"{args.piece}: {tempo} BPM, bar {bar:.3f}s, loop {args.bars} bars = {L:.2f}s")
    print(f"  searched {len(cands)} bar-aligned windows in {lo:.0f}-{min(hi,dur):.0f}s")
    print(f"  loudest window {loudest:.2f} dB; {dropped} of {len(all_cands)} dropped "
          f"as >{args.loud_tol:.0f} dB quieter (a dull window loops easily and hooks nobody)")
    print(f"  {'bar':>5} {'start':>8} {'ΔRMS dB':>9} {'Δspec dB':>9} {'loud dB':>8} {'score':>7}")
    for sc, dr, ds, t0, kb, ld in cands[:5]:
        print(f"  {kb:>5} {t0:>8.2f} {dr:>9.2f} {ds:>9.2f} {ld:>8.2f} {sc:>7.2f}")
    worst = max(all_cands)
    print(f"  (worst of all {len(all_cands)}: bar {worst[4]} ΔRMS {worst[1]:.2f} dB — "
          f"proof the search discriminates, not that every window is fine)")

    sc, dr, ds, t0, kb, ld = cands[0]
    loop = build_loop(src, sr, t0, L, args.xfade, args.curve)
    rep = seam_report(loop, sr)
    print(f"\n  chosen: bar {kb}, {t0:.2f}s → {t0 + L:.2f}s")
    print(f"  seam jump {rep['seam_jump']:.6f} vs largest internal step "
          f"{rep['max_internal']:.6f} → {'⛔ CLICK' if rep['click'] else 'no click'}")
    print(f"  level across the join: {rep['rms_before_dB']:.2f} → "
          f"{rep['rms_after_dB']:.2f} dB (step {rep['rms_step_dB']:.2f} dB)")

    if args.dry_run:
        return
    op = pathlib.Path(args.out) if args.out else d / f"{args.piece}-loop.wav"
    sf.write(str(op), loop, sr, subtype="FLOAT")
    print(f"  wrote {op}  ({L:.2f}s)")
    meta = {"piece": args.piece, "tempo": tempo, "bars": args.bars,
            "start_bar": kb, "start_s": round(t0, 4), "length_s": round(L, 4),
            "xfade_s": args.xfade, "curve": args.curve, "seam": {k: float(v) for k, v in rep.items()}}
    (d / f"{args.piece}-loop.json").write_text(json.dumps(meta, indent=2) + "\n")


if __name__ == "__main__":
    main()
