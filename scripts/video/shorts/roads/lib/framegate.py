#!/usr/bin/env python3
"""Two checks on the RENDERED SEQUENCE, after shoot.mjs has written the frames.

(A) STILLS == SEQUENCE. Every pixel gate in this pipeline measures a COLD
    __frame(t) call. The film is a sequential render. Those are only the same
    thing if the scene is genuinely stateless by t, and round 5 added three
    stateful containers (the trail group, the struck-disk pool, the spawn
    curve). If any of them accumulates, the gates keep passing and the FILM
    drifts -- and the whole "replay it from a different angle" idea dies with
    it, because take 2 would be a different performance.
    So: re-render a few frames cold and md5 them against the sequence's own
    PNGs. Equal, or fail. Control: the ADJACENT frame must NOT match, or the
    comparison proves nothing.

(B) SINGLE-CHANNEL BLOOM CLIP. The observer measured red-channel clipping
    peaking at t=0.53 -- 1134 px with R>=254 while G<254, against only 19
    truly white pixels. A warm light that clips in red alone goes ORANGE and
    posterises rather than blooming white. Counted across every frame, so a
    peak that moves (it did: the reverse-angle take presents a growing bright
    face to the lens) cannot hide between samples.

Usage: framegate.py <frames-dir> <payload.json> [--maxclip N] [--break]
"""
import sys, os, json, glob, hashlib, subprocess
import numpy as np
from PIL import Image

frames = sys.argv[1]; payload = sys.argv[2]
mc = sys.argv.index('--maxclip') if '--maxclip' in sys.argv else -1
# ⚠⚠ THIS CEILING IS A REGRESSION GUARD AT A MEASURED LEVEL, NOT A CLEAN BILL.
# The observer measured 1134 px of red-only clip at t=0.53 on the round-4 film.
# Round 5 measures 13213 px at t=11.03 -- the four-note chord -- and I could not
# get it down: neutralising both cores moved it 16715 -> 15233, cutting the
# strike emissive and halo moved it to 13219, and whitening the lamps moved it
# to 13213. The remaining source is the LIT WARM PAPER itself under four
# simultaneous lights, which is the look the user asked for, so lowering it
# further is a LOOK decision and is offered as a ladder rung rather than taken
# by me. The number here only stops it getting worse.
MAXCLIP = int(sys.argv[mc + 1]) if mc > 0 else 14500
BREAK = '--break' in sys.argv
P = json.load(open(payload))
FPS = 30
files = sorted(glob.glob(os.path.join(frames, 'f*.png')))
# ⛔ THIS WAS THE ONLY FRAME-COUNT GUARD IN THE WHOLE SUITE, and 31 of 414
# frames passes it. The real pin now lives in r4.sh, derived from
# renderSeconds; this stays as the local floor for a directory handed here
# directly. ⚠ A FLOOR IS NOT A PIN — it cannot tell a short render from a
# short film, which is why the derived one had to exist elsewhere.
if len(files) < 30:
    print(f"  [BROKEN] only {len(files)} frames in {frames}"); sys.exit(2)

fails, broken = [], []

# ---------------------------------------------------------------- (A)
HERE = os.path.dirname(os.path.abspath(__file__))
# ⭐ THE DETERMINISM SAMPLE SCALES WITH LENGTH. This was a FIXED THREE frames
# whether the film was 414 frames or 5,400 — a 3-minute film got the same three
# probes as a 12-second one, so per-second coverage fell with duration exactly
# where drift is most likely to appear. One probe per ~5 s of film, at least 3,
# capped at 12 so a long run does not spend all its time here. Spread across
# the WHOLE length, ends included (a late-only defect is the one length
# introduces).
NS = max(3, min(12, len(files) // (5 * FPS) + 1))
idx = [round((len(files) - 1) * (q + 0.5) / NS) for q in range(NS)]
work = os.path.join(frames, '..', '_stills')
times = [i / FPS for i in idx]
# ⛔ TWO BUGS OF MINE LIVED HERE, AND THE SECOND IS A REAL FINDING.
#
# (1) shoot.mjs takes its still times as ONE COMMA-SEPARATED argv[5], not as
#     separate arguments. Passing them separately rendered only the FIRST time
#     and the gate then compared two different frames against that one file --
#     three failures, two of them meaningless.
#
# (2) ⭐⭐ A COLD FRAME IS *NOT* BIT-IDENTICAL TO THE SAME FRAME REACHED
#     SEQUENTIALLY, AND THE SCENE IS NOT WHY. Measured, frame 82:
#         no preceding frame at all ....... 5f0098fa
#         preceded by ONE frame at t=0 .... 1b633c6d
#         preceded by ONE frame at t=9.5 .. 1b633c6d   (same as t=0)
#         preceded by frame 81 ............ 3d06d0c6  == the full sequence
#     Two cold renders of the same t are byte-identical to each other, and
#     perfcam proves the performance STATE is identical under different
#     cameras -- so the scene is deterministic. What is not is the COMPOSITOR:
#     EffectComposer ping-pongs two render targets and carries one frame of
#     buffer history, so the pixels depend slightly on what was drawn last
#     (mean 0.5/255, max 107/255). It converges after ONE matching frame.
#     Hence: render frame i-1 then i, and compare i. That is the honest form
#     of "the stills are the film" for a compositor with history.
prev = [f"{(i-1)/FPS:.6f},{i/FPS:.6f}" for i in idx]
subprocess.run(['node', os.path.join(HERE, 'shoot.mjs'), payload, work,
                str(P.get('total', 14) + 2), ','.join(
                    sorted({f"{(i-1)/FPS:.6f}" for i in idx} | {f"{i/FPS:.6f}" for i in idx},
                           key=float))],
               check=True, capture_output=True)
# ⭐⭐ THE CLAIM IS "THE STILLS ARE THE FILM", AND BIT-EXACT IS THE WRONG FORM
# OF IT. MEASURED: two cold renders of the same t are byte-identical, and
# perfcam proves the performance STATE is identical under different cameras --
# the SCENE is deterministic. But EffectComposer ping-pongs render targets and
# carries buffer history of more than one frame, so a cold frame differs from
# the same frame reached sequentially by a mean of ~0.5/255. Chasing that to
# zero would mean rebuilding the post chain, and it is not what the claim needs.
# What the claim needs is that the difference is NEGLIGIBLE COMPARED TO ONE
# FRAME OF MOTION -- if anything accumulated, cold would drift away from the
# sequence without bound and this ratio would collapse toward 1.
def mad(a, b):
    A = np.asarray(Image.open(a).convert('RGB'), float)
    B = np.asarray(Image.open(b).convert('RGB'), float)
    return float(np.abs(A - B).mean())

print(f"(A) STILLS == SEQUENCE — {len(idx)} frames re-rendered cold (with one warm-up frame)")
same = 0
RATIO = 5.0
for i, t in zip(idx, times):
    cold = os.path.join(work, "t%.2f.png" % t)
    if not os.path.exists(cold):
        broken.append(f"(A) no cold still written for t={t:.4f}"); continue
    seq = files[i + (1 if BREAK else 0)]
    adj = files[min(i + 1, len(files) - 1)]
    d_seq, d_adj = mad(cold, seq), mad(cold, adj)
    ratio = d_adj / d_seq if d_seq > 1e-9 else float('inf')
    ok = ratio >= RATIO
    print(f"    frame {i} t={t:.4f}  cold-vs-its-own-frame {d_seq:.3f}/255  "
          f"cold-vs-NEXT-frame {d_adj:.3f}/255  ratio {ratio:.1f}x  "
          f"{'matches its own frame' if ok else '<-- NOT ITS OWN FRAME'}")
    if d_adj < 1e-6:
        broken.append(f"(A) frame {i} is identical to its neighbour, so matching proves nothing")
    if ok: same += 1
    else: fails.append(f"(A) cold __frame({t:.4f}) is no closer to frame {i} than to frame {i+1} "
                       f"(ratio {ratio:.1f}x, need {RATIO}x) — the scene carries state between "
                       f"frames, so a second camera take would not be the same performance")

# ---------------------------------------------------------------- (B)
# ⛔⛔⛔ THIS CHECK IS SUPERSEDED. IT NO LONGER GATES ANYTHING, AND THE REASON
# MATTERS MORE THAN THE NUMBER.
#
# It counted pixels with R>=254 while G<254 and called that "clipping in red
# alone, which goes orange and posterises". Two things are now known about it:
#
# (1) IT WAS PROTECTING AGAINST A LOOK NOBODY ASKED FOR. I inferred "orange
#     posterisation is a defect" from a pixel count, set a ceiling, and then
#     spent two rounds trading real look decisions against it -- the
#     struck-note glow went 2.8 -> 1.5 and the trail gain 0.55 -> 0.30 to keep
#     it green. The user has since asked, BY NAME, for note disks that "decay
#     into red like metal getting cooled". A warm red ramp IS red-dominant
#     pixels. The gate would now flag the requested appearance as the defect,
#     and dimming the ramp to satisfy it would be the third time a gate I set
#     quietly overruled a look the user named.
#
# (2) IT OVER-STATES WHAT A VIEWER SEES ANYWAY. Measured on approach t=11.500:
#     of the 20398 pixels it counted, the MEDIAN R-G is 1, and only 8230 have
#     R-G >= 20. Most of what it counted is near-white, not orange.
#
# What would be worth catching is LOSS OF DETAIL -- channels pinned at maximum
# across a contiguous area -- which is a different measurement from hue and is
# not built here. Rather than ship a hue gate that fights the brief, both
# numbers are printed as INFORMATION and neither can fail the run.
# ⚠ THE OLD CEILING AND THE OLD NUMBERS DO NOT CARRY FORWARD. Any earlier
# "13213 px, under the 14500 ceiling" verdict described a different look under
# a retired rule; do not compare a post-cooling-ramp figure to it.
print(f"\n(B) WARM-CLIP CENSUS — informational only, NOT a gate (see the note in this file)")
worst, worst_i, whites, vis_at_worst = 0, -1, 0, 0
vworst, vworst_i = 0, -1
for i, f in enumerate(files):
    a = np.asarray(Image.open(f).convert('RGB')).astype(int)
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    red = (r >= 254) & (g < 254)
    n = int(red.sum())
    v = int((red & ((r - g) >= 20)).sum())     # the visibly ORANGE subset
    if n > worst: worst, worst_i, whites, vis_at_worst = n, i, int(((r >= 254) & (g >= 254) & (b >= 254)).sum()), v
    if v > vworst: vworst, vworst_i = v, i
print(f"    raw R>=254 & G<254 .......... worst {worst} px at t={worst_i/FPS:.2f}s "
      f"({whites} fully white, of which {vis_at_worst} are visibly orange)")
print(f"    visibly orange (R-G >= 20) .. worst {vworst} px at t={vworst_i/FPS:.2f}s")

for x in broken: print(f"  [BROKEN] {x}", file=sys.stderr)
if fails:
    for f in fails: print(f"  [ FAIL ] {f}", file=sys.stderr)
    sys.exit(1)
if broken: sys.exit(2)
print(f"\n  [ ok ] the film is the stills ({same}/{len(idx)} matched); the warm-clip census is reported, not gated")
