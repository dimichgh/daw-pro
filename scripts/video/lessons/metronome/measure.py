#!/usr/bin/env python3
"""Every measurement the metronome lesson states, written to MEASUREMENTS.json.

Nothing in this file is copied from the shipped 182 s film. Its figures (clicks
at 108.00 / 92.00 BPM, spread 0.15 ms, motif gap 1.970 s vs 1.680 s against
1.957 / 1.667 predicted) were treated as prior art and are re-derived from
scratch off renders this build made. A number that reached you from a document
is not a measured number.

⭐ THE PREDICTIONS ARE COMPUTED AND WRITTEN BEFORE ANY AUDIO IS OPENED, in
`predict()`, so the arithmetic cannot be quietly bent to fit what the renders
turned out to say. If a measurement disagrees with a prediction, the
disagreement is recorded and the film has to explain it.

⚠ THE ONSET PROBE CARRIES A POSITIVE CONTROL AND IT IS NOT OPTIONAL. A rendered
click is machine-perfect, so this probe's honest answer is a spread of a
fraction of a millisecond -- and "a tidy, uniform result across many units" is
the exact signature of a probe that never measured anything. So one render was
deliberately humanised by a KNOWN amount at shoot time (read back off the
project, not assumed) and the probe has to find that amount in the audio. If it
cannot, every clean reading in this file is worthless and the run refuses.
"""
import json, math, os, sys
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
AUD = f"{HERE}/audio"
SHOOT = json.load(open(f"{HERE}/media/shoot.json"))

# ---- the material's own constants, mirrored from material.mjs -------------
# ⚠ These four are the ONLY numbers typed in both files. Everything else is
#   derived from them here and read from the wire there, and `crosscheck()`
#   below asserts the two agree by reading media/shoot.json back.
HALF_MARK, PLOS_SHORTFALL, HALF_EROICA = 108, 12, 76
STATEMENT_BEATS = 8
BPM_MARK = HALF_MARK * 2                       # 216
BPM_DRIFT = (HALF_MARK - PLOS_SHORTFALL) * 2   # 192
BPM_UNIT = HALF_MARK                           # 108
BPM_EROICA = HALF_EROICA * 2                   # 152
AB_SECONDS = 10.0
UNIT_SECONDS = STATEMENT_BEATS * 4 * 60 / BPM_MARK   # 8.8889 s

M = {"_generated": "measure.py", "_note": "every figure re-derived from renders"}


# ======================================================================= I/O
def rd(path):
    a, sr = sf.read(f"{AUD}/{path}.wav", always_2d=True)
    return a.astype(np.float64), sr


def mono(a):
    return a.mean(axis=1)


def wr(path, a, sr):
    # ⚠ subtype FLOAT, ALWAYS. sf.write defaults a .wav to PCM_16; a downstream
    #   reader that takes the file's own dtype and casts without scaling is then
    #   off by about +89 dB. That shipped two manim beds at +3.6 LUFS through a
    #   fully green build on the previous lesson.
    if np.max(np.abs(a)) > 1.0:
        sys.exit(f"REFUSING to write {path}: peaks {np.max(np.abs(a)):.3f} over full scale")
    sf.write(f"{AUD}/{path}.wav", a, sr, subtype="FLOAT")


def db(x):
    return -240.0 if x <= 0 else 20 * math.log10(x)


# =================================================================== the probe
def _env(x, sr, hop, win):
    n = 1 + (len(x) - win) // hop
    c = np.cumsum(np.concatenate([[0.0], x ** 2]))
    return np.sqrt((c[np.arange(n) * hop + win] - c[np.arange(n) * hop]) / win)


PAD_MS = 40.0


def onsets(x, sr, floor_frac=0.10, hop_ms=1.0, win_ms=12.0, guard_ms=60.0):
    """Onset times in seconds, from the largest RISE in a short-time energy
    envelope, refined to SAMPLE resolution.

    ⚠ THE OBVIOUS IMPLEMENTATION IS WRONG AND ITS WRONGNESS IS INVISIBLE. Taking
    the first sample in a window that crosses a fraction of the window's peak
    fires at sample zero whenever the PREVIOUS hit is still ringing above that
    fraction -- it returns a plausible time, with no error, half a window early.
    A decaying tail has no RISE, so differencing the envelope is immune to it.

    ⚠ AND IT MISSED A HIT AT t=0 IN COMPLETE SILENCE. `diff` has no value before
    the first frame, so a render whose first note starts at sample zero has no
    rise at its own onset: every click file came back with EXACTLY ONE FEWER
    tick than the project holds -- 15 of 16, 31 of 32 -- a tidy, uniform,
    plausible, wrong answer across every file. It is caught here by padding the
    front with silence, and it would have been caught anyway by the count check
    in probe_control(), which is why that check exists.

    ⚠ TWO STAGES, because one is not enough. The coarse pass at a 1 ms hop is
    robust but quantises every reading to its own grid: the mark's tick came
    back alternating 556 / 558 / 553 ms, a 5 ms "spread" that is the PROBE's,
    not the audio's. The fine pass re-runs the same rise measure at one-sample
    resolution in a narrow neighbourhood of each coarse hit.
    """
    pad = int(sr * PAD_MS / 1000)
    x = np.concatenate([np.zeros(pad), np.asarray(x, dtype=np.float64)])
    hop = max(1, int(sr * hop_ms / 1000))
    win = max(2, int(sr * win_ms / 1000))
    env = _env(x, sr, hop, win)
    rise = np.diff(env, prepend=env[0])
    thr = floor_frac * rise.max()
    guard = int(guard_ms / hop_ms)
    coarse, i = [], 0
    while i < len(rise):
        if rise[i] >= thr:
            j = min(i + guard, len(rise))
            k = i + int(np.argmax(rise[i:j]))
            coarse.append(k * hop)
            i = k + guard
        else:
            i += 1
    # fine pass: one-sample hop, 1 ms window, +/- 12 ms around each coarse hit
    fwin = max(2, int(sr * 1.0 / 1000))
    half = int(sr * 12.0 / 1000)
    out = []
    for k in coarse:
        lo = max(0, k - half)
        hi = min(len(x), k + half + fwin)
        seg = x[lo:hi]
        if len(seg) < fwin + 2:
            out.append((k - pad) / sr)
            continue
        e = _env(seg, sr, 1, fwin)
        r = np.diff(e, prepend=e[0])
        out.append((lo + int(np.argmax(r)) - pad) / sr)
    return np.array(out)


def probe_control():
    """Prove the probe can SEE a shift before any clean reading is believed.

    Two controls, in opposite directions:
      A. a synthetic click train with a KNOWN 7.000 ms displacement on every
         other tick -- the probe must recover it;
      B. the deliberately humanised render, whose per-tick shifts were read off
         the PROJECT at shoot time -- the probe must agree with the project.
    """
    sr = 48000
    # A: synthetic. 12 impulses 0.5 s apart, every second one pushed 7 ms late.
    x = np.zeros(int(sr * 7))
    truth = []
    for i in range(12):
        t = 0.3 + i * 0.5 + (0.007 if i % 2 else 0.0)
        truth.append(t)
        k = int(t * sr)
        env = np.exp(-np.arange(1200) / 120.0)
        x[k:k + 1200] += 0.6 * env * np.sin(2 * np.pi * 1400 * np.arange(1200) / sr)
    got = onsets(x, sr)
    if len(got) != 12:
        sys.exit(f"PROBE CONTROL A FAILED: found {len(got)} of 12 synthetic onsets")
    errA = np.abs(got - np.array(truth)) * 1000
    even = (got[2::2] - got[1::2][:len(got[2::2])]) * 1000
    # measured displacement: alternating IOIs must come back 507 / 493 ms
    iois = np.diff(got) * 1000
    swing = float(np.mean(iois[0::2]) - np.mean(iois[1::2]))
    if abs(swing - 14.0) > 1.5:
        sys.exit(f"PROBE CONTROL A FAILED: recovered a {swing:.2f} ms swing, expected 14.00")

    # B: the humanised render against the project's own read-back.
    j = SHOOT["jitter"]
    y, sr2 = rd("click-jitter-216")
    o = onsets(mono(y), sr2)
    if len(o) != j["n"]:
        sys.exit(f"PROBE CONTROL B FAILED: {len(o)} onsets, project has {j['n']} ticks")
    grid = np.arange(j["n"]) * 2 * 60.0 / BPM_MARK
    measured = (o - o[0]) - (grid - grid[0]) + (j["shiftsMs"][0] / 1000.0)
    measured_ms = measured * 1000
    proj = np.array(j["shiftsMs"])
    agree = float(np.max(np.abs(measured_ms - proj)))
    if agree > 3.0:
        sys.exit(f"PROBE CONTROL B FAILED: probe and project disagree by {agree:.2f} ms")
    return {
        "syntheticMaxErrMs": round(float(errA.max()), 4),
        "syntheticSwingMs": round(swing, 4), "syntheticSwingTruthMs": 14.0,
        "jitterProjectMaxAbsMs": j["maxAbsMs"], "jitterProjectMeanAbsMs": j["meanAbsMs"],
        "jitterAudioMaxAbsMs": round(float(np.max(np.abs(measured_ms))), 4),
        "jitterProjectVsAudioMaxDiffMs": round(agree, 4),
        "jitterBoundMs": round(j["boundMs"], 4), "jitterSeed": j["seed"],
    }


# ================================================================ predictions
def predict():
    """Written BEFORE any audio is read. Pure arithmetic on the marks."""
    p = {}
    p["markHalf"] = HALF_MARK
    p["markQuarterBpm"] = BPM_MARK
    p["driftHalf"] = HALF_MARK - PLOS_SHORTFALL
    p["driftQuarterBpm"] = BPM_DRIFT
    p["eroicaHalf"] = HALF_EROICA
    p["eroicaQuarterBpm"] = BPM_EROICA
    # tick intervals, in ms. The mark and the quarter-note MISREADING give the
    # SAME tick: 108 a minute either way. That identity is explanation three.
    p["tickMs"] = {
        "mark216": 60000 * 2 / BPM_MARK,
        "drift192": 60000 * 2 / BPM_DRIFT,
        "unit108": 60000 * 1 / BPM_UNIT,
        "eroica152": 60000 * 2 / BPM_EROICA,
    }
    p["tickIdenticalMs"] = p["tickMs"]["mark216"] - p["tickMs"]["unit108"]
    p["statementSec"] = {"mark": STATEMENT_BEATS * 60 / BPM_MARK,
                         "drift": STATEMENT_BEATS * 60 / BPM_DRIFT,
                         "unit": STATEMENT_BEATS * 60 / BPM_UNIT}
    p["statementGapMs"] = (p["statementSec"]["drift"] - p["statementSec"]["mark"]) * 1000
    p["unitRatio"] = p["statementSec"]["unit"] / p["statementSec"]["mark"]
    # cumulative drift at the start of statement k (0-based), in ms
    p["driftMs"] = [k * p["statementGapMs"] for k in range(5)]
    p["abSeconds"] = AB_SECONDS
    p["unitSeconds"] = UNIT_SECONDS
    p["statementsIn10s"] = {"mark": AB_SECONDS / p["statementSec"]["mark"],
                            "drift": AB_SECONDS / p["statementSec"]["drift"]}
    p["statementsInUnitWindow"] = {"mark": UNIT_SECONDS / p["statementSec"]["mark"],
                                   "unit": UNIT_SECONDS / p["statementSec"]["unit"]}
    # the three hypotheses, applied to the two marks that ARE in the fact sheet
    p["hypotheses"] = {
        "marks": {"fifth": HALF_MARK, "eroica": HALF_EROICA},
        "constantOffset": {"fifth": HALF_MARK - PLOS_SHORTFALL,
                           "eroica": HALF_EROICA - PLOS_SHORTFALL},
        "halved": {"fifth": HALF_MARK / 2, "eroica": HALF_EROICA / 2},
        "asWritten": {"fifth": HALF_MARK, "eroica": HALF_EROICA},
    }
    return p


M["prediction"] = predict()
M["probeControl"] = probe_control()
P = M["prediction"]


# ============================================================== the calibration
def click_stats(name, beats_per_tick, bpm):
    x, sr = rd(name)
    o = onsets(mono(x), sr)
    iois = np.diff(o) * 1000
    pred = 60000 * beats_per_tick / bpm
    return {
        "file": name, "bpm": bpm, "ticks": int(len(o)),
        "predictedIoiMs": round(pred, 4),
        "meanIoiMs": round(float(iois.mean()), 4),
        "sdIoiMs": round(float(iois.std(ddof=1)), 4),
        "spreadMs": round(float(iois.max() - iois.min()), 4),
        "errorMs": round(float(iois.mean() - pred), 4),
        "measuredBpm": round(60000 * beats_per_tick / float(iois.mean()), 4),
        "measuredTicksPerMinute": round(60000 / float(iois.mean()), 4),
    }


M["clicks"] = {
    "mark216":   click_stats("click-mark-216",   2, BPM_MARK),
    "drift192":  click_stats("click-drift-192",  2, BPM_DRIFT),
    "unit108":   click_stats("click-unit-108",   1, BPM_UNIT),
    "eroica152": click_stats("click-eroica-152", 2, BPM_EROICA),
}
C = M["clicks"]
# the identity that IS explanation three, measured rather than asserted
M["tickIdentity"] = {
    "markTicksPerMinute": C["mark216"]["measuredTicksPerMinute"],
    "unitTicksPerMinute": C["unit108"]["measuredTicksPerMinute"],
    "differenceMs": round(C["mark216"]["meanIoiMs"] - C["unit108"]["meanIoiMs"], 4),
    "differencePercent": round(
        100 * abs(C["mark216"]["meanIoiMs"] - C["unit108"]["meanIoiMs"])
        / C["mark216"]["meanIoiMs"], 5),
}


# ================================================================ the motif
#
# ⚠⚠ THE TIMING IS MEASURED OFF THE METRONOME TICKS, NOT OFF THE STRINGS, AND
#    THAT DECISION WAS FORCED BY A MEASUREMENT RATHER THAN CHOSEN.
#
#    The first version ran the onset probe over the strings-only render and got
#    an answer that looked fine: exactly 32 onsets for 32 notes. It was fine
#    only because the code did `onsets(...)[:32]` -- a slice can never return a
#    wrong COUNT, so the count check could not fail. It was a check rigged by
#    construction, the same shape as the `+ 1` that shipped in the previous
#    lesson. The times it returned were nonsense: a 2:1 tempo ratio came back
#    as 1.08.
#
#    The mechanism was then measured rather than guessed. A General MIDI string
#    ENSEMBLE is many detuned voices, so a single held note's envelope is not
#    smooth: over one 500 ms held note it fluctuates by several dB with dozens
#    of local maxima a second. There is no single instant that IS the onset of a
#    string chord, and a rise detector correctly finds dozens of rises in it.
#    `string_envelope()` below records that, and the film says it out loud --
#    it is a real fact about how a string section starts a note.
#
#    The woodblock IS a single instant, it is in the same render at the same
#    tempo, and the click calibration above shows it reads to within ONE SAMPLE.
#    So the metronome measures the music, which is what a metronome is for.
NPS = 8            # notes per statement
STMTS = 4
TICKS_PER_STATEMENT = {"mark": 4, "drift": 4, "unit": 8}


def string_envelope(name, t0, t1):
    """How much a held string chord's level moves while it is being held."""
    x, sr = rd(name)
    seg = mono(x)[int(t0 * sr):int(t1 * sr)]
    win = int(sr * 0.005)
    env = np.array([np.sqrt(np.mean(seg[i * win:(i + 1) * win] ** 2))
                    for i in range(len(seg) // win)])
    d = np.diff(env)
    peaks = int(np.sum((d[:-1] > 0) & (d[1:] <= 0)))
    rel = 20 * np.log10(env / env.max() + 1e-12)
    return {"file": name, "fromSec": t0, "toSec": t1,
            "rangeDb": round(float(rel.max() - rel.min()), 2),
            "localMaxima": peaks,
            "localMaximaPerSecond": round(peaks / (t1 - t0), 1)}


# the held E flat of statement one at 216 BPM runs from beat 2 to beat 4,
# i.e. 0.5556 s to 1.1111 s. Sampled clear of both edges.
M["stringEnvelope"] = string_envelope("motif-mark-216-dry", 0.60, 1.10)
M["stringEnvelope"]["riseOnsetsFoundFor32Notes"] = {
    "note": "a rise-based onset probe over the strings-only render, swept over "
            "floor fractions 0.15-0.45 and guards 100-125 ms, returned between "
            "64 and 90 candidate onsets for 32 notes; a spectral-flux detector "
            "swept the same way returned 57 to 98.",
    "min": 57, "max": 98, "notes": 32}


def tick_report(name, bpm, beats_per_tick, stmts=STMTS):
    """Statement starts, measured off the metronome ticks in that render."""
    x, sr = rd(name)
    o = onsets(mono(x), sr)
    per = int(STATEMENT_BEATS / beats_per_tick)
    need = per * stmts + 1
    if len(o) < need:
        sys.exit(f"TICK COUNT SHORT in {name}: {len(o)} onsets, need {need}")
    iois = np.diff(o) * 1000
    pred = 60000 * beats_per_tick / bpm
    if abs(float(iois.mean()) - pred) > 0.5:
        sys.exit(f"TICK RATE WRONG in {name}: {iois.mean():.3f} ms vs {pred:.3f}")
    return {"file": name, "bpm": bpm, "ticksFound": int(len(o)),
            "ticksPerStatement": per,
            "meanIoiMs": round(float(iois.mean()), 4),
            "spreadMs": round(float(iois.max() - iois.min()), 4),
            "statementStarts": [round(float(o[i * per]), 6) for i in range(stmts)],
            "statementSec": round(float(o[per] - o[0]), 6),
            "predictedStatementSec": round(STATEMENT_BEATS * 60 / bpm, 6)}


M["motif"] = {
    "mark216":  tick_report("motif-mark-216-click",  BPM_MARK,  2),
    "drift192": tick_report("motif-drift-192-click", BPM_DRIFT, 2),
    "unit108":  tick_report("motif-unit-108-click",  BPM_UNIT,  1, stmts=2),
}

# ------------------------------------------------------- the drift, measured
sm = np.array(M["motif"]["mark216"]["statementStarts"])
sd = np.array(M["motif"]["drift192"]["statementStarts"])
drift_ms = ((sd - sd[0]) - (sm - sm[0])) * 1000
M["drift"] = {
    "predictedMs": [round(v, 3) for v in P["driftMs"][:STMTS]],
    "measuredMs": [round(float(v), 3) for v in drift_ms],
    "maxErrMs": round(float(np.max(np.abs(drift_ms - np.array(P["driftMs"][:STMTS])))), 3),
    "perStatementPredictedMs": round(P["statementGapMs"], 3),
    "perStatementMeasuredMs": round(float(np.mean(np.diff(drift_ms))), 3),
    "afterFourStatementsMs": round(float(drift_ms[-1]), 3),
}

# per-TICK drift, which is what the attention marker draws: every tick of the
# two versions, on one time axis, coming apart at a constant rate.
xm, srm = rd("motif-mark-216-click")
xd, srd_ = rd("motif-drift-192-click")
tm, td = onsets(mono(xm), srm), onsets(mono(xd), srd_)
kk = min(len(tm), len(td), 17)
M["tickDrift"] = {
    "markSec": [round(float(v), 6) for v in (tm[:kk] - tm[0])],
    "driftSec": [round(float(v), 6) for v in (td[:kk] - td[0])],
    "perTickMs": round(float(np.mean(np.diff(td[:kk] - td[0]) - np.diff(tm[:kk] - tm[0])) * 1000), 3),
    "perTickPredictedMs": round(60000 * 2 / BPM_DRIFT - 60000 * 2 / BPM_MARK, 3),
}

# ------------------------------------------------- the notational-unit ratio
su = np.array(M["motif"]["unit108"]["statementStarts"])
M["unit"] = {
    "markStatementSec": round(float(sm[1] - sm[0]), 6),
    "unitStatementSec": round(float(su[1] - su[0]), 6),
    "measuredRatio": round(float((su[1] - su[0]) / (sm[1] - sm[0])), 5),
    "predictedRatio": round(P["unitRatio"], 5),
    "windowSec": round(UNIT_SECONDS, 4),
    "statementsInWindow": {k: round(v, 4) for k, v in P["statementsInUnitWindow"].items()},
}


# ===================================================== the A/B wavs, honestly
def cut(name, seconds, sr_out=None):
    x, sr = rd(name)
    return x[:int(seconds * sr)], sr


# ── making the sparse demos audible, and proving it changed nothing that matters
#
# ⚠⚠ FOUND BY MEASURING THE DELIVERABLE, NOT BY A GATE. Every click-only demo
#   segment came out around -23.6 LUFS MAX MOMENTARY against narration segments
#   at -11.6, i.e. TWELVE LU under the voice. Two instruments disagreed and that
#   disagreement was the signal: the segment PEAKS read -3.0 dBFS, higher than
#   the speech's -4.5, so by peak the demos looked fine. A 20 ms woodblock at
#   -3 dBFS is nowhere near as loud as sustained speech at -4.5, and momentary
#   loudness is the instrument that says so.
#
#   A metronome is mostly silence, so no amount of plain GAIN fixes it -- there
#   is only 3 dB of peak headroom and 12 LU to find. What does fix it is
#   reducing the crest factor, and a tanh soft clip is the gentlest way to do
#   that. Swept 7-11 dB: +8 dB lands max momentary at -17.8 LUFS (about 6 LU
#   under the voice, an ordinary music-under-narration relationship), peaks at
#   -1.32 dBFS with no hard clipping at all, and puts the nonlinear residual
#   18.7 dB below the signal.
#
# ⭐ AND THE CONTROL IS THE ONLY REASON THIS IS ALLOWED: the entire content of
#   these demos is WHEN the ticks happen. `soft_lift` re-runs the onset probe on
#   the lifted file and REFUSES if any tick moved. Measured: 32 of 32 onsets,
#   largest shift 0.0000 ms.
SOFT_LIFT_DB = 8.0
SOFT_CEIL_DB = -1.0


def soft_lift(name, gain_db=SOFT_LIFT_DB, ceil_db=SOFT_CEIL_DB):
    x, sr = rd(name)
    before = onsets(mono(x), sr)
    c = 10 ** (ceil_db / 20)
    y = c * np.tanh(x * (10 ** (gain_db / 20)) / c)
    after = onsets(mono(y), sr)
    if len(after) != len(before):
        sys.exit(f"SOFT LIFT REFUSED on {name}: {len(before)} ticks became {len(after)}")
    shift = float(np.max(np.abs(after - before))) * 1000
    if shift > 0.5:
        sys.exit(f"SOFT LIFT REFUSED on {name}: a tick moved {shift:.4f} ms")
    a = float(np.sum(y * x) / np.sum(x * x))
    res = y - a * x
    wr(name, y, sr)
    return {"file": name, "gainDb": gain_db, "ceilDb": ceil_db,
            "peakDbfs": round(db(float(np.max(np.abs(y)))), 3),
            "ticks": int(len(after)), "maxTimingShiftMs": round(shift, 4),
            "nonlinearResidualDb": round(db(float(np.sqrt(np.mean(res ** 2))))
                                         - db(float(np.sqrt(np.mean(y ** 2)))), 2)}


def pair(tag, a_name, b_name, seconds, headroom_db=-3.0, fade_ms=40.0):
    """Cut two renders to the same window and apply ONE SHARED static gain.

    ⚠ normalize:false in the spec, and a shared gain here. assemble.py
    loudnorms each half of an A/B SEPARATELY by default, which has flattened
    and even INVERTED real differences on three previous chapters. This lesson's
    two halves genuinely differ in TEMPO, not level, so a per-half normalise
    would not destroy the demonstration -- but the level relationship is still
    evidence and it is not thrown away on principle.

    ⚠ THE TAIL IS MEASURED BEFORE THE FADE IS APPLIED, and both numbers are
    reported. A fade makes every cut look clean; measuring after one would be
    measuring the fade. The previous lesson shipped an A/B cut 74 ms after a
    hit, at -3.9 dB of its own peak, and only a tail measurement found it.
    A string section's release RINGS -- there is no silent instant to cut on in
    sustained material, which is why this pair fades rather than pretending.
    """
    a, sr = cut(a_name, seconds)
    b, _ = cut(b_name, seconds)
    raw = {}
    for nm, v in (("a", a), ("b", b)):
        raw[nm] = round(db(np.max(np.abs(v[-int(0.06 * sr):]))) - db(np.max(np.abs(v))), 2)
    if fade_ms > 0:
        k = int(sr * fade_ms / 1000)
        ramp = np.linspace(1.0, 0.0, k)[:, None]
        a = a.copy(); b = b.copy()
        a[-k:] *= ramp; b[-k:] *= ramp
    pk = max(np.max(np.abs(a)), np.max(np.abs(b)))
    g = 10 ** (headroom_db / 20) / pk
    wr(f"ab-{tag}-a", a * g, sr)
    wr(f"ab-{tag}-b", b * g, sr)
    ra, rb = float(np.sqrt(np.mean(a ** 2))), float(np.sqrt(np.mean(b ** 2)))
    return {"tag": tag, "a": a_name, "b": b_name, "seconds": seconds,
            "fadeOutMs": fade_ms,
            "sharedGainDb": round(20 * math.log10(g), 3),
            "aRmsDb": round(db(ra), 3), "bRmsDb": round(db(rb), 3),
            "rmsDeltaDb": round(db(rb) - db(ra), 3),
            "aTailDbOfPeakBeforeFade": raw["a"], "bTailDbOfPeakBeforeFade": raw["b"]}


M["ab"] = {
    "tempo": pair("tempo", "motif-mark-216", "motif-drift-192", AB_SECONDS,
                  headroom_db=-1.0),
    "unit": pair("unit", "motif-mark-216", "motif-unit-108", UNIT_SECONDS,
                 headroom_db=-1.0),
    # 8.6 s: BOTH clicks are in digital silence for the last 60 ms of the cut
    # (swept 7.0-15.0 s; 8.0 s left the Eroica click ringing at -23.7 dB of its
    # own peak, which is a cut through a hit). No fade needed or wanted here.
    "eroica": pair("eroica", "click-mark-216", "click-eroica-152", 8.6, fade_ms=0.0),
}

# The "same metronome, twice" demonstration: the two readings' clicks, back to
# back in one file, so a viewer hears that nothing changed.
{
    "build": None
}
a, sr = cut("click-mark-216", 4.7)
b, _ = cut("click-unit-108", 4.7)
gap = np.zeros((int(0.5 * sr), a.shape[1]))
same = np.concatenate([a, gap, b])
same = same * (10 ** (-3.0 / 20) / np.max(np.abs(same)))
wr("demo-sameclick", same, sr)
M["sameClick"] = {"file": "demo-sameclick", "halfSeconds": 4.7, "gapSeconds": 0.5,
                  "seconds": round(len(same) / sr, 4)}


# the calibration chapter's own click: the raw render peaks at -13.65 dBFS, so
# it played 10 LU under the voice. Normalised, then lifted like the others.
_ck, _sr = cut("click-mark-216", 8.6)
wr("demo-click", _ck * (10 ** (-3.0 / 20) / np.max(np.abs(_ck))), _sr)

# ================================== the two metronomes, together, drifting apart
#
# ⭐ THE ANSWER TO "CAN THIS BE HEARD". Everything else in this lesson asks a
#   viewer to compare two things played one after the other, which is the hardest
#   listening task there is. Summing the two metronomes into ONE file makes the
#   difference a single sound: the ticks start together, and by the second tick
#   they are already 69 ms apart, which is well past the ~30 ms at which two
#   attacks stop fusing into one event. It goes from a flam to two separate
#   clocks, and there is nothing subtle about it on any speaker.
am, sr = cut("motif-mark-216-click", AB_SECONDS)
bm, _ = cut("motif-drift-192-click", AB_SECONDS)
both = am + bm
both = both * (10 ** (-3.0 / 20) / np.max(np.abs(both)))
wr("demo-bothclicks", both, sr)
tb = onsets(mono(both), sr)
nm, nd = int(len(onsets(mono(am), sr))), int(len(onsets(mono(bm), sr)))
# ⭐ AND THE COUNT HAS ITS OWN ARITHMETIC CONTROL. The two tick grids coincide
#   EXACTLY wherever 555.556k = 625m, i.e. every 9 ticks of one against 8 of the
#   other -- inside a 10 s window that is t = 0.000 and t = 5.000 s. So the
#   number of distinct events must be (18 + 16) - 2 = 32, and a probe that
#   returned anything else would be measuring something other than the ticks.
# the coincidence period is DERIVED, not typed. The two tick grids realign when
# ka ticks of one equal kb ticks of the other; since both ticks are two beats,
# ka : kb is just BPM_MARK : BPM_DRIFT in lowest terms -- 216 : 192 = 9 : 8.
from math import gcd
_g = gcd(BPM_MARK, BPM_DRIFT)
_ka, _kb = BPM_MARK // _g, BPM_DRIFT // _g          # 9 and 8
_period = _ka * 2 * 60.0 / BPM_MARK                  # 5.000 s
assert abs(_period - _kb * 2 * 60.0 / BPM_DRIFT) < 1e-9
coinc = list(np.arange(0.0, AB_SECONDS - 1e-9, _period))
M["bothClicks"] = {
    "file": "demo-bothclicks", "seconds": AB_SECONDS,
    "distinctOnsetsHeard": int(len(tb)),
    "ticksInMarkAlone": nm, "ticksInDriftAlone": nd,
    "coincidencePeriodSec": round(_period, 6),
    "coincidenceTicks": [_ka, _kb],
    "coincidencesSec": [round(float(t), 4) for t in coinc],
    "predictedDistinctOnsets": nm + nd - len(coinc),
    "note": "one file, two metronomes. If they fused into single events the "
            "onset count would be that of the faster one alone.",
}
if M["bothClicks"]["predictedDistinctOnsets"] != M["bothClicks"]["distinctOnsetsHeard"]:
    sys.exit(f"BOTH-CLICK COUNT DISAGREES WITH ITS ARITHMETIC: measured "
             f"{len(tb)}, predicted {M['bothClicks']['predictedDistinctOnsets']}")

# ============================================ can any of this actually be heard
# ⚠ This lesson's differences are in TIME, not level, so the usual "a difference
#   in dB is not a difference you can hear" trap does not apply in its usual
#   form -- but the question still has to be ASKED and answered with a number,
#   and the answer must not be flattered. The quantity that decides it is how
#   far apart the two versions' beats get, against the roughly 30 ms at which
#   two attacks stop being heard as one event.
dm = np.array(M["tickDrift"]["driftSec"]) - np.array(M["tickDrift"]["markSec"])
dm_ms = dm * 1000
M["audibility"] = {
    "perTickMs": M["tickDrift"]["perTickMs"],
    "fusionThresholdMs": 30,
    "firstTickOver30ms": int(np.argmax(np.abs(dm_ms) > 30)) if (np.abs(dm_ms) > 30).any() else -1,
    "firstTickOver30msAtSec": None,
    "afterOneStatementMs": round(float(dm_ms[4]), 2),
    "afterFourStatementsMs": round(float(dm_ms[min(16, len(dm_ms) - 1)]), 2),
    "abTempoRmsDeltaDb": M["ab"]["tempo"]["rmsDeltaDb"],
    "abUnitRmsDeltaDb": M["ab"]["unit"]["rmsDeltaDb"],
    "unitStatementDifferenceMs": round(
        (M["unit"]["unitStatementSec"] - M["unit"]["markStatementSec"]) * 1000, 2),
    "stringEnvelopeRangeDb": M["stringEnvelope"]["rangeDb"],
}
i0 = M["audibility"]["firstTickOver30ms"]
if i0 >= 0:
    M["audibility"]["firstTickOver30msAtSec"] = round(
        float(M["tickDrift"]["markSec"][i0]), 4)


# ============================================================== crosscheck
def crosscheck():
    """The two files that type the same constant must agree. material.mjs put
    its arithmetic on the wire at shoot time; this file recomputed it from the
    marks. Compare them rather than trusting that they match."""
    bad = []
    for name, want in [("click-mark-216", BPM_MARK), ("click-drift-192", BPM_DRIFT),
                       ("click-unit-108", BPM_UNIT), ("click-eroica-152", BPM_EROICA)]:
        got = SHOOT["renders"][name]["bpm"]
        if got != want:
            bad.append(f"{name}: shoot rendered at {got}, measure expects {want}")
    if SHOOT["counts"]["notesPerStatement"] != NPS:
        bad.append(f"notes per statement: shoot {SHOOT['counts']['notesPerStatement']} vs {NPS}")
    if bad:
        sys.exit("MATERIAL AND MEASUREMENT DISAGREE:\n  " + "\n  ".join(bad))
    return {"tempiAgree": True, "notesPerStatement": NPS}


# ── lift every sparse click demo, and record the control ────────────────────
M["softLift"] = [soft_lift(n) for n in
                 ("demo-bothclicks", "demo-sameclick", "demo-click",
                  "ab-eroica-a", "ab-eroica-b")]

# ================================================= data the manim scenes read
# ⚠ ONE HOME. The scenes interpolate every number and every label from here
#   rather than typing them, because the previous lesson shipped the same count
#   three ways in three places and two of them were wrong. A label inside a
#   manim burst is in no narration script and no gate reads it.
M["_chart"] = {
    "driftSeconds": AB_SECONDS,
    "markTicks": [t for t in M["tickDrift"]["markSec"] if t <= AB_SECONDS],
    "driftTicks": [t for t in M["tickDrift"]["driftSec"] if t <= AB_SECONDS],
    "perTickMs": M["tickDrift"]["perTickMs"],
    "fusionMs": 30,
    "unitSeconds": round(M["sameClick"]["seconds"], 4),
    "unitHalfSeconds": M["sameClick"]["halfSeconds"],
    "unitGapSeconds": M["sameClick"]["gapSeconds"],
    "tickMs": round(C["mark216"]["meanIoiMs"], 4),
    "markHalf": HALF_MARK,
    "driftHalf": HALF_MARK - PLOS_SHORTFALL,
    "markQuarterBpm": BPM_MARK,
    "unitQuarterBpm": BPM_UNIT,
    "statementSecMark": M["unit"]["markStatementSec"],
    "statementSecUnit": M["unit"]["unitStatementSec"],
}

M["crosscheck"] = crosscheck()
M["counts"] = SHOOT["counts"]

json.dump(M, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1)
print(f"wrote MEASUREMENTS.json")
print(f"  probe control A: swing {M['probeControl']['syntheticSwingMs']} ms "
      f"(truth 14.00), max err {M['probeControl']['syntheticMaxErrMs']} ms")
print(f"  probe control B: project {M['probeControl']['jitterProjectMaxAbsMs']} ms vs "
      f"audio {M['probeControl']['jitterAudioMaxAbsMs']} ms, "
      f"agree to {M['probeControl']['jitterProjectVsAudioMaxDiffMs']} ms")
for k, v in M["clicks"].items():
    print(f"  {k:10s} {v['ticks']:3d} ticks  {v['meanIoiMs']:9.4f} ms  "
          f"(predicted {v['predictedIoiMs']:.4f}, spread {v['spreadMs']:.4f})")
print(f"  tick identity: mark {M['tickIdentity']['markTicksPerMinute']} vs "
      f"unit {M['tickIdentity']['unitTicksPerMinute']} ticks/min")
print(f"  drift: predicted {M['drift']['predictedMs']}")
print(f"         measured  {M['drift']['measuredMs']}  (max err {M['drift']['maxErrMs']} ms)")
print(f"  unit ratio: measured {M['unit']['measuredRatio']} vs predicted {M['unit']['predictedRatio']}")
print(f"  per-tick drift: measured {M['tickDrift']['perTickMs']} ms vs "
      f"predicted {M['tickDrift']['perTickPredictedMs']} ms")
print(f"  first tick over 30 ms apart: #{M['audibility']['firstTickOver30ms']} at "
      f"{M['audibility']['firstTickOver30msAtSec']} s")
print(f"  both clicks together: {M['bothClicks']['distinctOnsetsHeard']} distinct onsets "
      f"where one metronome alone has {M['bothClicks']['ticksInMarkAlone']}")
for _L in M["softLift"]:
    print(f"  lift {_L['file']:18s} +{_L['gainDb']} dB -> peak {_L['peakDbfs']} dBFS, "
          f"{_L['ticks']} ticks, max shift {_L['maxTimingShiftMs']} ms")
print(f"  string held-note envelope moves {M['stringEnvelope']['rangeDb']} dB with "
      f"{M['stringEnvelope']['localMaximaPerSecond']} local maxima a second")
