#!/usr/bin/env python3
"""L6 "Chasing −14" — PASS 2. Measure everything the film says, off the renders
shoot.mjs just made, and write MEASUREMENTS.json (plus every A/B wav).

⚠ RUN WITH THE PLUGIN VENV. numpy/scipy/soundfile live only in
`plugins/narrated-film/.venv/bin/python`; the system python3 has none of them,
and a ModuleNotFoundError next to a stale MEASUREMENTS.json from a previous run
reads exactly like "the analysis found nothing".

THE PREDICTION, written down before anything is measured:

  * A static gain of G dB moves integrated loudness by exactly G and the peak by
    exactly G. So reaching −14 LUFS from a mix at L costs G = −14 − L, and the
    peak lands at P + G. Everything above 0 dBFS at that point cannot be stored
    by an integer file and is CLAMPED.
  * Clipping is therefore a subtraction: clipped − clean is zero everywhere the
    signal fitted and non-zero only where it did not.
  * The control for that subtraction is the same subtraction on material that
    never exceeded full scale. It must return the 24-bit QUANTISATION FLOOR
    (about −140 dBFS) and nothing else; a file minus itself must return exactly
    digital silence.

⚠ TWO INSTRUMENTS. Every loudness figure is measured by ffmpeg's ebur128 here
AND by the app's own render.measureLoudness in shoot.mjs (facts.json). They are
compared at the bottom of this file; a disagreement is the signal.
"""
import json, os, re, subprocess, sys
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
AUD = os.path.join(HERE, "audio")
SR = 48000
EPS = 1e-12
FACTS = json.load(open(f"{AUD}/facts.json"))


# ----------------------------------------------------------------- reading
def rd(name):
    """Read a render. soundfile normalises INTEGER files to ±1 and returns
    FLOAT files verbatim — which is the whole point here, because the float
    renders legitimately contain samples above 1.0 and any 'looks like an int,
    divide by 32768' heuristic would silently rescale them."""
    x, sr = sf.read(os.path.join(AUD, name + ".wav"), dtype="float64",
                    always_2d=True)
    assert sr == SR, f"{name}: {sr} Hz, expected {SR}"
    return x


def subtype(name):
    return sf.info(os.path.join(AUD, name + ".wav")).subtype


def db(v):
    return float(20 * np.log10(max(float(v), EPS)))


def rms_db(x):
    return db(np.sqrt(np.mean(np.square(x)))) if len(x) else -np.inf


def peak_db(x):
    return db(np.max(np.abs(x)))


# ------------------------------------------------------- ffmpeg ebur128/astats
_EBU = re.compile(r"^\s*(I|LRA|Peak):\s*(-?[\d.]+|-inf)\s")


def ebur128(path):
    """BS.1770 integrated / loudness range / true peak, from a SECOND
    instrument. ⚠ `-v error` SUPPRESSES the summary — it logs at INFO."""
    p = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", path,
         "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"],
        capture_output=True, text=True)
    tail = p.stderr[p.stderr.rfind("Summary"):]
    out = {}
    for line in tail.splitlines():
        m = _EBU.match(line)
        if m:
            k = {"I": "integratedLufs", "LRA": "loudnessRangeLu",
                 "Peak": "truePeakDbtp"}[m.group(1)]
            if k not in out:
                out[k] = float("-inf") if m.group(2) == "-inf" else float(m.group(2))
    if "integratedLufs" not in out:
        sys.exit(f"ebur128 produced no summary for {path}\n{p.stderr[-1200:]}")
    return out


# ------------------------------------------------------------------ clipping
def clip_stats(x24, xf):
    """Count what the integer file could not store.

    A clipped sample is one pinned at (or a hair inside) full scale in the
    24-bit file WHOSE FLOAT COUNTERPART was outside it. Both conditions matter:
    the first alone would count a legitimate sample that happens to land at full
    scale, the second alone would count a float overshoot that the writer
    happened to round back inside."""
    fs = 1.0 - 1.0 / (2 ** 23)                     # the largest 24-bit value
    pinned = np.abs(x24) >= fs - 1e-9
    over = np.abs(xf) > 1.0
    both = pinned & over
    # the longest unbroken run of pinned samples in either channel — a "flat
    # top" is the visible signature, and its LENGTH is what a listener hears
    runs = []
    for ch in range(both.shape[1]):
        d = np.diff(np.concatenate([[0], both[:, ch].view(np.int8), [0]]))
        s, e = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
        runs.extend((e - s).tolist())
    return {
        "clippedSamples": int(both.sum()),
        "overFullScaleSamples": int(over.sum()),
        "clippedFrames": int(np.any(both, axis=1).sum()),
        "clipRuns": len(runs),
        "longestRunSamples": int(max(runs)) if runs else 0,
        "longestRunMs": (float(max(runs)) / SR * 1000.0) if runs else 0.0,
        "meanRunSamples": float(np.mean(runs)) if runs else 0.0,
        "clippedPercent": float(both.sum()) / both.size * 100.0,
    }


def residual(x24, xf):
    """The clipping, isolated: what the integer file has that the float one
    does not. Everything that fitted subtracts to (quantisation) zero."""
    n = min(len(x24), len(xf))
    return x24[:n] - xf[:n]


# --------------------------------------------------------------- short-term
def short_term(x, win=3.0, hop=0.1):
    """A crude, self-consistent short-term level curve (mono sum, RMS in a
    3 s window) — used ONLY for the shape of the loudness-over-time chart, and
    labelled as RMS rather than as LUFS, which it is not."""
    m = x.mean(axis=1)
    w, h = int(win * SR), int(hop * SR)
    n = (len(m) - w) // h + 1
    t = np.arange(n) * hop + win / 2
    v = np.array([db(np.sqrt(np.mean(m[i * h:i * h + w] ** 2))) for i in range(n)])
    return t, v


def envelope(x, win_ms=20.0):
    m = x.mean(axis=1)
    w = int(win_ms / 1000 * SR)
    k = np.ones(w) / w
    return np.sqrt(np.convolve(m * m, k, mode="same"))


# ============================================================ the measurements
M = {"material": {k: FACTS[k] for k in ("bpm", "bars", "seconds", "notes", "parts")}}

RENDERS = ["dry", "dry24", "g14f", "g1424", "g11f", "g1124", "g8f", "g824",
           "g5f", "g524", "limonly", "mastered", "mastered24",
           "compoff", "compin", "loudwar"]
X = {r: rd(r) for r in RENDERS}
M["subtypes"] = {r: subtype(r) for r in RENDERS}

# ── every render, measured by ffmpeg (the second instrument) ───────────────
M["loudness"] = {r: ebur128(f"{AUD}/{r}.wav") for r in RENDERS}
for r in RENDERS:
    M["loudness"][r]["samplePeakDbfs"] = peak_db(X[r])
    M["loudness"][r]["rmsDbfs"] = rms_db(X[r])
    M["loudness"][r]["crestDb"] = M["loudness"][r]["samplePeakDbfs"] - M["loudness"][r]["rmsDbfs"]
    M["loudness"][r]["plrDb"] = (M["loudness"][r]["samplePeakDbfs"]
                                 - M["loudness"][r]["integratedLufs"])

# ── the app said / ffmpeg said, side by side ──────────────────────────────
M["instrument_agreement"] = []
for key, r in [("dry", "dry"), ("g14f", "g14f"), ("limonly", "limonly"),
               ("mastered", "mastered"), ("loudwar", "loudwar")]:
    app = (FACTS["dry"] if key == "dry" else
           FACTS["limiterOnly"]["measured"] if key == "limonly" else
           FACTS["mastered"]["measured"] if key == "mastered" else
           FACTS["loudwar"]["measured"] if key == "loudwar" else
           next(l["measured"] for l in FACTS["ladder"] if l["tag"] + "f" == key))
    ff = M["loudness"][r]
    M["instrument_agreement"].append({
        "render": r,
        "appLufs": app["integratedLufs"], "ffmpegLufs": ff["integratedLufs"],
        "lufsDelta": app["integratedLufs"] - ff["integratedLufs"],
        "appDbtp": app["truePeakDbtp"], "ffmpegDbtp": ff["truePeakDbtp"],
        "dbtpDelta": app["truePeakDbtp"] - ff["truePeakDbtp"],
    })

# ── THE NULL CONTROLS, before any clipping figure is believed ─────────────
selfnull = residual(X["dry24"], X["dry24"])
qnull = residual(X["dry24"], X["dry"])
M["controls"] = {
    "selfSubtractionRmsDbfs": rms_db(selfnull),          # exactly digital silence
    "selfSubtractionNonZeroSamples": int(np.count_nonzero(selfnull)),
    "unclippedSubtractionRmsDbfs": rms_db(qnull),        # the 24-bit floor
    "unclippedSubtractionPeakDbfs": peak_db(qnull),
    "dryClipStats": clip_stats(X["dry24"], X["dry"]),    # must be zero
}

# ── the ladder: clipping at each target ───────────────────────────────────
M["ladder"] = []
for rung in FACTS["ladder"]:
    tag = rung["tag"]
    xf, x24 = X[tag + "f"], X[tag + "24"]
    res = residual(x24, xf)
    prog = rms_db(x24)
    row = {
        "targetLufs": rung["target"],
        "gainDb": rung["gainDb"],
        "gainLinear": rung["gainLinear"],
        "measuredLufs": M["loudness"][tag + "f"]["integratedLufs"],
        "floatPeakDbfs": peak_db(xf),
        "clipped24PeakDbfs": peak_db(x24),
        "programRmsDbfs": prog,
        "residualRmsDbfs": rms_db(res),
        "residualPeakDbfs": peak_db(res),
        "residualBelowProgramDb": rms_db(res) - prog,
        **clip_stats(x24, xf),
    }
    M["ladder"].append(row)

L14 = M["ladder"][0]
L5 = M["ladder"][-1]
M["ladder_span_db"] = L5["residualRmsDbfs"] - L14["residualRmsDbfs"]

# ── the four masters ──────────────────────────────────────────────────────
def master_row(name, label, note):
    l = M["loudness"][name]
    return {"key": name, "label": label, "note": note,
            "integratedLufs": l["integratedLufs"],
            "loudnessRangeLu": l["loudnessRangeLu"],
            "truePeakDbtp": l["truePeakDbtp"],
            "samplePeakDbfs": l["samplePeakDbfs"],
            "plrDb": l["plrDb"]}


M["masters"] = [
    master_row("dry", "the mix, untouched", "nothing on the master bus at all"),
    master_row("g14f", "gain only", f'+{L14["gainDb"]:.2f} dB, nothing else'),
    master_row("limonly", "gain + true-peak limiter",
               f'the same +{FACTS["limiterOnly"]["gainDb"]:.2f} dB into a −1.0 dBTP ceiling'),
    master_row("mastered", "compressor + limiter",
               f'+{FACTS["mastered"]["gainDb"]:.2f} dB, 2:1 from −18 dB, then the same ceiling'),
]
M["loudwar_master"] = master_row("loudwar", "the same chain, chasing −8",
                                 f'+{FACTS["loudwar"]["gainDb"]:.2f} dB')
M["chain"] = {"compressor": FACTS["mastered"]["compressor"],
              "limiter": {"ceilingDb": FACTS["mastered"]["ceilingDb"],
                          "releaseMs": FACTS["mastered"]["releaseMs"],
                          "truePeak": True},
              "masteredGainDb": FACTS["mastered"]["gainDb"],
              "naiveGainDb": L14["gainDb"],
              "loudwarGainDb": FACTS["loudwar"]["gainDb"]}

# THE BILL: loudness bought, dynamic range paid
d, m14, m8 = M["loudness"]["dry"], M["loudness"]["mastered"], M["loudness"]["loudwar"]
M["bill"] = {
    "dryLufs": d["integratedLufs"], "dryLra": d["loudnessRangeLu"],
    "masteredLufs": m14["integratedLufs"], "masteredLra": m14["loudnessRangeLu"],
    "loudwarLufs": m8["integratedLufs"], "loudwarLra": m8["loudnessRangeLu"],
    "loudnessGainedDb": m14["integratedLufs"] - d["integratedLufs"],
    "rangeLostLu": d["loudnessRangeLu"] - m14["loudnessRangeLu"],
    "rangeLostPercent": (1 - m14["loudnessRangeLu"] / d["loudnessRangeLu"]) * 100,
    "loudwarLoudnessGainedDb": m8["integratedLufs"] - d["integratedLufs"],
    "loudwarRangeLostLu": d["loudnessRangeLu"] - m8["loudnessRangeLu"],
    "loudwarRangeLostPercent": (1 - m8["loudnessRangeLu"] / d["loudnessRangeLu"]) * 100,
}

# ── what the compressor actually did: post / pre, sample for sample ───────
off, on = X["compoff"], X["compin"]
n = min(len(off), len(on))
e_off, e_on = envelope(off[:n]), envelope(on[:n])
live = e_off > 10 ** (-60 / 20)
gr = np.zeros(n)
gr[live] = 20 * np.log10(np.maximum(e_on[live], EPS) / np.maximum(e_off[live], EPS))
# ⚠ `gr` is the NET gain the whole unit applied, and this compressor carries
#   +6 dB of makeup — so its median is POSITIVE and calling it "gain reduction"
#   would be a sign error on screen. The reduction is makeup MINUS net.
MAKEUP = FACTS["mastered"]["compressor"]["makeupDb"]
red = MAKEUP - gr[live]
M["compressor_gr"] = {
    "makeupDb": MAKEUP,
    "netMedianDb": float(np.median(gr[live])),
    "netMinDb": float(np.min(gr[live])),
    "reductionMedianDb": float(np.median(red)),
    "reductionMaxDb": float(np.max(red)),
    "reductionP90Db": float(np.percentile(red, 90)),
    "fractionOver3dB": float(np.mean(red > 3.0)),
}

# ── the film's attention-marker windows: DERIVED from where the clipping is ──
#    Every 100 ms window of the −14 master that contains a clipped sample, gaps
#    under 250 ms merged, anything under 200 ms dropped. Nothing chosen by eye.
res14 = residual(X["g1424"], X["g14f"])
hop = int(0.1 * SR)
nz = np.array([np.any(np.abs(res14[i:i + hop]) > 0) for i in range(0, len(res14) - hop, hop)])
wins, run = [], None
for i, v in enumerate(nz):
    if v and run is None:
        run = i
    elif not v and run is not None:
        wins.append([run * 0.1, i * 0.1]); run = None
if run is not None:
    wins.append([run * 0.1, len(nz) * 0.1])
merged = []
for w in wins:
    if merged and w[0] - merged[-1][1] < 0.25:
        merged[-1][1] = w[1]
    else:
        merged.append(list(w))
M["clip_windows_s"] = [w for w in merged if w[1] - w[0] >= 0.2]
M["clip_window_count"] = len(M["clip_windows_s"])

# ============================================================ the A/B excerpts
# ⚠ ONE SHARED STATIC GAIN PER PAIR, and `normalize: false` in the spec. The
# level difference IS the lesson in three of these four pairs; a per-half
# loudnorm would delete it, and a single-pass loudnorm is itself dynamic, which
# on a dynamics lesson makes the normaliser the thing under test.
EX_START, EX_SECS = 21.6, 8.0                 # bars 10-13: drums, bass and lead
a, b = int(EX_START * SR), int((EX_START + EX_SECS) * SR)


def cut(x):
    return x[a:b]


def fade(x, ms=12.0):
    k = int(ms / 1000 * SR)
    r = np.linspace(0, 1, k)[:, None]
    y = x.copy()
    y[:k] *= r
    y[-k:] *= r[::-1]
    return y


def write(name, x, gain_db):
    y = fade(x * 10 ** (gain_db / 20))
    sf.write(f"{AUD}/{name}.wav", y, SR, subtype="FLOAT")
    return {"file": name, "gainDb": gain_db, "peakDbfs": peak_db(y),
            "rmsDbfs": rms_db(y), "lufs": ebur128(f"{AUD}/{name}.wav")["integratedLufs"]}


M["ab"] = {}

# 1. LOUDER WINS — the mix against the −14 master, NOT loudness matched.
#    One shared gain, chosen from the LOUDER of the two so nothing clips.
g_pair1 = -1.0 - peak_db(cut(X["mastered"]))
M["ab"]["unmatched"] = {"sharedGainDb": g_pair1,
                        "before": write("ab-dry", cut(X["dry"]), g_pair1),
                        "after": write("ab-mastered", cut(X["mastered"]), g_pair1)}
M["ab"]["unmatched"]["deltaLu"] = (M["ab"]["unmatched"]["after"]["lufs"]
                                   - M["ab"]["unmatched"]["before"]["lufs"])

# 2. THE SAME PAIR, LOUDNESS MATCHED — the master pulled down by exactly the
#    measured difference, so the only thing left to judge is what the chain did.
match = M["ab"]["unmatched"]["before"]["lufs"] - M["ab"]["unmatched"]["after"]["lufs"]
M["ab"]["matched"] = {"matchOffsetDb": match,
                      "before": write("ab-dryM", cut(X["dry"]), g_pair1),
                      "after": write("ab-masteredM", cut(X["mastered"]), g_pair1 + match)}
M["ab"]["matched"]["deltaLu"] = (M["ab"]["matched"]["after"]["lufs"]
                                 - M["ab"]["matched"]["before"]["lufs"])

# 3. CLEAN vs CLIPPED at −14 — the pair the shipped film asked people to hear.
g14 = -1.0 - peak_db(cut(X["g14f"]))
M["ab"]["clip14"] = {"sharedGainDb": g14,
                     "before": write("ab-clean14", cut(X["g14f"]), g14),
                     "after": write("ab-clip14", cut(X["g1424"]), g14)}
M["ab"]["clip14"]["deltaLu"] = (M["ab"]["clip14"]["after"]["lufs"]
                                - M["ab"]["clip14"]["before"]["lufs"])

# 4. THE SAME PAIR at the −5 rung, where the artefact is 20-odd dB louder.
g5 = -1.0 - peak_db(cut(X["g5f"]))
M["ab"]["clip5"] = {"sharedGainDb": g5,
                    "before": write("ab-clean5", cut(X["g5f"]), g5),
                    "after": write("ab-clip5", cut(X["g524"]), g5)}
M["ab"]["clip5"]["deltaLu"] = (M["ab"]["clip5"]["after"]["lufs"]
                               - M["ab"]["clip5"]["before"]["lufs"])

# 5. THE DISTORTION ON ITS OWN, at a STATED gain. Nothing is hidden here: this
#    is the −14 master's residual turned up until it can be heard, and the film
#    says by how much.
# ⚠ ONE SHARED GAIN ACROSS BOTH RESIDUALS, set from the LOUDER of the two so
#   neither clips. Normalising them separately would have made the −14 master's
#   distortion sound exactly as loud as the −5 master's, which is the opposite
#   of what this pair exists to show — and MEASURED: at a per-file gain the −5
#   residual came out at +3.12 dBFS, clipping inside the film itself.
res_cut = cut(res14)
res5 = residual(X["g524"], X["g5f"])
res5_cut = cut(res5)
RES_GAIN = round(-3.0 - peak_db(res5_cut), 1)
M["ab"]["isolated14"] = {**write("resid14", res_cut, RES_GAIN),
                         "sourceRmsDbfs": rms_db(res_cut)}
M["ab"]["isolated5"] = {**write("resid5", res5_cut, RES_GAIN),
                        "sourceRmsDbfs": rms_db(res5_cut),
                        "note": "the SAME gain as the −14 residual, deliberately"}
M["ab"]["isolatedDeltaDb"] = (M["ab"]["isolated5"]["rmsDbfs"]
                              - M["ab"]["isolated14"]["rmsDbfs"])

# ---------------------------------- the attention marker's data, all DERIVED
#   For each of the two rungs the film plays, the level of the DISTORTION and
#   the level of the MUSIC, both as 30 ms RMS across the same 8 s excerpt.
#   ⚠ THE SHADED WINDOWS ARE NOT CHOSEN BY EYE: they are every stretch where the
#   −5 master's distortion comes within 40 dB of its own music, gaps under
#   150 ms merged, anything under 200 ms dropped. 40 dB is stated in the film as
#   a rule of thumb about small speakers, not as a measurement.
def st_curve(x, win_ms=80.0, hop_ms=20.0):
    m = x.mean(axis=1)
    w, h = int(win_ms / 1000 * SR), int(hop_ms / 1000 * SR)
    n = max(0, (len(m) - w) // h + 1)
    t = np.arange(n) * (hop_ms / 1000.0)
    v = np.array([db(np.sqrt(np.mean(m[i * h:i * h + w] ** 2))) for i in range(n)])
    return t, v


mk = {}
_t = None
for tag, rung in (("g14", M["ladder"][0]), ("g5", M["ladder"][-1])):
    prog_x = X[tag + "24"][a:b]
    res_x = residual(X[tag + "24"], X[tag + "f"])[a:b]
    _t, prog_v = st_curve(prog_x)
    _, res_v = st_curve(res_x)
    near = np.maximum(res_v - prog_v, -60.0)      # how far under the music
    mk[tag] = {"program": prog_v.tolist(), "residual": res_v.tolist(),
               "nearness": near.tolist(), "targetLufs": rung["targetLufs"],
               "closestDb": float(near.max()),
               "medianDb": float(np.median(near))}
gap = np.array(mk["g5"]["nearness"])
near = gap > -40.0
wins, run = [], None
for i, v in enumerate(near):
    if v and run is None:
        run = i
    elif not v and run is not None:
        wins.append([run * 0.02, i * 0.02]); run = None
if run is not None:
    wins.append([run * 0.02, len(near) * 0.02])
merged = []
for w in wins:
    if merged and w[0] - merged[-1][1] < 0.15:
        merged[-1][1] = w[1]
    else:
        merged.append(list(w))
MARK = {"t": _t.tolist(), "seconds": float(_t[-1]) if len(_t) else 0.0,
        "windows": [[round(x, 3) for x in w] for w in merged if w[1] - w[0] >= 0.2],
        "nearThresholdDb": -40.0, **mk}
MARK["maxNearnessDb"] = float(gap.max())
MARK["floorDb"] = -60.0


# ----------------------------------------------------- data the charts plot
def decimate_peak(x, n=1600):
    """Peak-preserving decimation. ⚠ A plain stride would MISS the clipped
    samples entirely — they are a few hundred out of nearly two million — and
    the chart would show a waveform politely under the ceiling."""
    m = x.mean(axis=1) if x.ndim > 1 else x
    k = max(1, len(m) // n)
    t = np.arange(0, len(m) - k, k) / SR
    hi = np.array([m[i:i + k].max() for i in range(0, len(m) - k, k)])
    lo = np.array([m[i:i + k].min() for i in range(0, len(m) - k, k)])
    return t.tolist(), hi.tolist(), lo.tolist()


t_w, hi_d, lo_d = decimate_peak(X["dry"])
_, hi_h, lo_h = decimate_peak(X["g14f"])
_, hi_c, lo_c = decimate_peak(X["g1424"])

# the single worst flat top, found by looking for the longest pinned run
both14 = (np.abs(X["g1424"]) >= 1.0 - 1.0 / 2 ** 23) & (np.abs(X["g14f"]) > 1.0)
anych = np.any(both14, axis=1)
d = np.diff(np.concatenate([[0], anych.view(np.int8), [0]]))
st_i, en_i = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
j = int(np.argmax(en_i - st_i))
c0, c1 = int(st_i[j]), int(en_i[j])
pad = 90
z0, z1 = max(0, c0 - pad), min(len(X["g14f"]), c1 + pad)
ch = int(np.argmax(np.abs(X["g14f"][c0:c1]).max(axis=0)))

t_gr = (np.arange(0, n, 480) / SR).tolist()
gr_dec = gr[::480].tolist()

st_t, st_dry = short_term(X["dry"])
_, st_mast = short_term(X["mastered"])
_, st_lw = short_term(X["loudwar"])

M["_chart"] = {
    "wave": {"t": t_w, "dryHi": hi_d, "dryLo": lo_d,
             "hotHi": hi_h, "hotLo": lo_h, "clipHi": hi_c, "clipLo": lo_c},
    "zoom": {"t_ms": ((np.arange(z0, z1) - c0) / SR * 1000).tolist(),
             "float": X["g14f"][z0:z1, ch].tolist(),
             "int24": X["g1424"][z0:z1, ch].tolist(),
             "runSamples": c1 - c0, "atSeconds": c0 / SR},
    "gr": {"t": t_gr, "db": gr_dec},
    "shortterm": {"t": st_t.tolist(), "dry": st_dry.tolist(),
                  "mastered": st_mast.tolist(), "loudwar": st_lw.tolist()},
    "marker": MARK,
}

# beds for the two manim scenes (built by bursts.py from the scene's own
# printed offsets; these are the raw materials)
M["_chart"].update({"excerptStart": EX_START, "excerptSeconds": EX_SECS,
                    "residualPlaybackGainDb": RES_GAIN})

json.dump(M, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1)

# --------------------------------------------------------------------- report
print(f"controls   self-subtraction {M['controls']['selfSubtractionRmsDbfs']:.1f} dB "
      f"({M['controls']['selfSubtractionNonZeroSamples']} non-zero samples)")
print(f"           unclipped 24-bit minus float {M['controls']['unclippedSubtractionRmsDbfs']:.1f} dB")
print(f"           dry 24-bit clipped samples {M['controls']['dryClipStats']['clippedSamples']}")
print("masters")
for m in M["masters"]:
    print(f"  {m['label']:<28} {m['integratedLufs']:7.2f} LUFS  "
          f"{m['truePeakDbtp']:6.2f} dBTP  LRA {m['loudnessRangeLu']:.2f}")
lw = M["loudwar_master"]
print(f"  {lw['label']:<28} {lw['integratedLufs']:7.2f} LUFS  "
      f"{lw['truePeakDbtp']:6.2f} dBTP  LRA {lw['loudnessRangeLu']:.2f}")
print("ladder")
for r in M["ladder"]:
    print(f"  {r['targetLufs']:>3} LUFS  +{r['gainDb']:5.2f} dB  peak {r['floatPeakDbfs']:6.2f}  "
          f"clipped {r['clippedSamples']:>7}  resid {r['residualRmsDbfs']:7.2f} dBFS  "
          f"({r['residualBelowProgramDb']:6.2f} dB under the music)")
q = M["compressor_gr"]
print(f"compressor  reduction median {q['reductionMedianDb']:.2f} dB, "
      f"deepest {q['reductionMaxDb']:.2f} dB, over 3 dB "
      f"{q['fractionOver3dB']*100:.0f}% of the time  (net median "
      f"{q['netMedianDb']:+.2f} dB with +{q['makeupDb']:.0f} makeup)")
print(f"bill  {M['bill']['loudnessGainedDb']:.2f} dB louder cost "
      f"{M['bill']['rangeLostLu']:.2f} LU ({M['bill']['rangeLostPercent']:.0f}%)")
print(f"      chasing -8 cost {M['bill']['loudwarRangeLostLu']:.2f} LU "
      f"({M['bill']['loudwarRangeLostPercent']:.0f}%)")
print("instrument agreement (app vs ffmpeg)")
for r in M["instrument_agreement"]:
    print(f"  {r['render']:<10} LUFS {r['lufsDelta']:+.2f}   dBTP {r['dbtpDelta']:+.2f}")
print(f"clip windows {M['clip_window_count']}  |  marker windows "
      f"{len(MARK['windows'])}, closest approach {MARK['maxNearnessDb']:.1f} dB")
print(f"-> {HERE}/MEASUREMENTS.json")
