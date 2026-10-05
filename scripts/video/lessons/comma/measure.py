#!/usr/bin/env python3
"""Measure every number the film says, off the renders the app just made.

⭐ NOTHING HERE IS PREDICTED-ONLY. Each figure is measured AND its prediction is
carried next to it, so the film can say both and the spec can refuse to build if
a spoken number drifts from either.

⚠ POSITIVE/NEGATIVE CONTROLS EVERYWHERE. A beat-rate estimator run on a signal
that cannot beat MUST return ~0: `control.wav` (one tone), `fifth-pure.wav` and
`third-pure.wav` (exact integer ratios) are those controls, and they are
reported rather than assumed.

⚠ THE THIRD'S BEAT IS NOT IN THE FULL-BAND ENVELOPE. The fundamentals are 114 Hz
apart, far too wide to beat; the beating happens between the ROOT's 5th partial
and the THIRD's 4th, both near 2200 Hz, and the fundamental buries it. So every
interval is measured twice: full-band, and inside a bandpass around the
coinciding partial. The two numbers are the whole reason the comma reads as a
wobble and the tempered third reads as roughness.

⚠ stdlib `wave` cannot read the float wavs the app writes — soundfile only.
⚠ ffmpeg `-v error` suppresses the ebur128 SUMMARY (it logs at INFO); every
call here uses -hide_banner and parses the summary block.
"""
import json, os, re, subprocess, sys
import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfiltfilt, hilbert

HERE = os.path.dirname(os.path.abspath(__file__))
A = f"{HERE}/audio"
MAT = json.load(open(f"{HERE}/material.json"))
REN = json.load(open(f"{HERE}/renders.json"))
SR = 48000


def load(name):
    x, sr = sf.read(f"{A}/{name}.wav")
    if x.ndim > 1:
        x = x.mean(axis=1)
    assert sr == SR, (name, sr)
    return x


def peak_hz(x, sr=SR, lo=50, hi=20000, n=1 << 22):
    """Parabolic-interpolated FFT peak. Resolution far finer than one bin."""
    w = np.hanning(len(x))
    X = np.abs(np.fft.rfft(x * w, n))
    f = np.fft.rfftfreq(n, 1 / sr)
    m = (f >= lo) & (f <= hi)
    k = int(np.argmax(np.where(m, X, 0)))
    a, b, c = np.log(X[k - 1] + 1e-30), np.log(X[k] + 1e-30), np.log(X[k + 1] + 1e-30)
    d = 0.5 * (a - c) / (a - 2 * b + c)
    return float((k + d) * sr / n)


def bp(x, f0, q=0.25, sr=SR):
    """6th-order zero-phase bandpass, +/- q octaves around f0."""
    lo, hi = f0 * 2 ** -q, f0 * 2 ** q
    return sosfiltfilt(butter(6, [lo / (sr / 2), hi / (sr / 2)], btype="band",
                              output="sos"), x)


def beat(x, sr=SR, fmin=0.4, fmax=40.0):
    """Beat rate and modulation depth from the analytic envelope.

    depth = (max-min)/(max+min) on the smoothed envelope -- the classic
    modulation index, 1.0 for two equal tones beating to silence, 0 for none.
    """
    env = np.abs(hilbert(x))
    # smooth at 60 Hz so the estimator cannot chase the carrier
    env = sosfiltfilt(butter(4, 60 / (sr / 2), btype="low", output="sos"), env)
    env = env[int(0.5 * sr):-int(0.5 * sr)]          # drop attack/release
    dc = float(np.mean(env))
    e = env - dc
    n = 1 << 20
    E = np.abs(np.fft.rfft(e * np.hanning(len(e)), n))
    f = np.fft.rfftfreq(n, 1 / sr)
    m = (f >= fmin) & (f <= fmax)
    k = int(np.argmax(np.where(m, E, 0)))
    a, b, c = np.log(E[k-1]+1e-30), np.log(E[k]+1e-30), np.log(E[k+1]+1e-30)
    d = 0.5*(a-c)/(a-2*b+c)
    rate = float((k + d) * SR / n)
    # depth over whole cycles only, so a partial cycle cannot bias min/max
    ncyc = max(1, int((len(env) / sr) * rate))
    seg = env[:int(ncyc / rate * sr)] if rate > 0.2 else env
    mx, mn = float(np.max(seg)), float(np.min(seg))
    depth = (mx - mn) / (mx + mn) if (mx + mn) > 0 else 0.0
    # the peak's height над the local noise floor: is there a beat AT ALL?
    band = E[m]
    prom = float(E[k] / (np.median(band) + 1e-30))
    return dict(rateHz=rate, depth=float(depth), prominence=prom,
                envMean=dc, envelope=None)


def lufs(path):
    p = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path,
                        "-filter_complex", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    tail = p.stderr[-2500:]
    g = re.search(r"I:\s*(-?\d+\.\d+) LUFS", tail)
    t = re.search(r"Peak:\s*(-?\d+\.\d+) dBFS", tail)
    if not g:
        sys.exit(f"ebur128 gave no summary for {path}:\n{tail}")
    return dict(lufs=float(g.group(1)), truePeak=float(t.group(1)) if t else None)


out = {"_source": "measure.py over audio/ rendered by DAW Pro staging 17695"}

# ---------------------------------------------------------------- 1. tuning
# Does the app's sampler put the tones where the arithmetic says? Every zone's
# rendered frequency against its predicted one.
tun = {}
sole = {
    "a440": ("single", 440.0, dict(lo=380, hi=520)),
    "sawRoot": ("saw-alone", 440.0, dict(lo=380, hi=520)),
}
for k, (f, pred, kw) in sole.items():
    got = peak_hz(load(f)[int(1*SR):int(9*SR)], **kw)
    tun[k] = dict(measuredHz=got, predictedHz=pred, errCents=1200*np.log2(got/pred))
# the comma pair: two peaks near 440 and 446 -- resolve them by窗口ing narrowly
cx = load("comma")[int(1*SR):int(11*SR)]
tun["commaLow"] = dict(measuredHz=peak_hz(cx, lo=436, hi=443), predictedHz=440.0)
tun["commaHigh"] = dict(measuredHz=peak_hz(cx, lo=443.5, hi=452),
                        predictedHz=MAT["hz"]["commaA"])
for nm, f, lo, hi, pred in (
        ("fifthPure", "fifth-pure", 645, 675, MAT["hz"]["fifthPure"]),
        ("fifthET", "fifth-et", 645, 675, MAT["hz"]["fifthET"]),
        ("thirdPure", "third-pure", 540, 562, MAT["hz"]["thirdPure"]),
        ("thirdET", "third-et", 540, 562, MAT["hz"]["thirdET"])):
    got = peak_hz(load(f)[int(1*SR):int(11*SR)], lo=lo, hi=hi)
    tun[nm] = dict(measuredHz=got, predictedHz=pred,
                   errCents=1200*np.log2(got/pred))
for k, v in tun.items():
    if "errCents" not in v:
        v["errCents"] = 1200*np.log2(v["measuredHz"]/v["predictedHz"])
out["tuning"] = tun

# ---------------------------------------------------------------- 2. beating
# Each pair measured FULL-BAND and inside a bandpass around the partial where
# the two tones actually collide.
PARTIAL = {"fifth": MAT["partial"]["fifth"], "third": MAT["partial"]["third"]}
beats = {}
cases = [
    # THE TWO NEGATIVE CONTROLS for the unison demo: one tone (which cannot
    # beat at all) and TWO tones at exactly the same pitch (which is the
    # film's actual A/B "before" — same timbre, same level, same note count).
    ("single",      "single",      None,               0.0),
    ("unison",      "unison",      None,               0.0),
    ("comma",       "comma",       None,               MAT["predict"]["unison"]),
    ("sawAlone",    "saw-alone",   PARTIAL["fifth"],   0.0),
    ("fifthPure",   "fifth-pure",  PARTIAL["fifth"],   MAT["predict"]["fifthPure"]),
    ("fifthET",     "fifth-et",    PARTIAL["fifth"],   MAT["predict"]["fifthET"]),
    ("thirdPure",   "third-pure",  PARTIAL["third"],   MAT["predict"]["thirdPure"]),
    ("thirdET",     "third-et",    PARTIAL["third"],   MAT["predict"]["thirdET"]),
]
for key, fname, part, pred in cases:
    x = load(fname)
    full = beat(x)
    rec = dict(predictedHz=pred, full=full)
    if part:
        rec["band"] = beat(bp(x, part))
        rec["partialHz"] = part
    beats[key] = rec
out["beats"] = beats

# ---------------------------------------------------------------- 3. loudness
out["loudness"] = {n: lufs(f"{A}/{n}.wav") for n in
                   ("walk", "walk-et", "single", "unison", "comma", "saw-alone",
                    "fifth-pure", "fifth-et", "third-pure", "third-et")}

# ---------------------------------------------------------------- 4. the walk
# Onsets and the frequency of each of the thirteen notes, so the ladder chart is
# measured off the render rather than drawn from the arithmetic.
w = load("walk")
env = sosfiltfilt(butter(4, 30/(SR/2), btype="low", output="sos"), np.abs(hilbert(w)))
steps = []
for k in range(13):
    t0 = k * 1.5 + 0.25
    seg = w[int(t0*SR):int((t0 + 1.1)*SR)]
    f = peak_hz(seg, lo=420, hi=900)
    pred = MAT["a4"] * 2 ** (MAT["walk"][k]["cents"] / 1200)
    steps.append(dict(step=k, tSec=k*1.5, measuredHz=f, predictedHz=pred,
                      cents=MAT["walk"][k]["cents"],
                      errCents=1200*np.log2(f/pred)))
# the SAME thirteen steps in equal temperament: the last one must come back to
# exactly 440, which is the whole claim of the fix chapter.
we = load("walk-et")
esteps = []
for k in range(13):
    t0 = k * 1.5 + 0.25
    f_ = peak_hz(we[int(t0*SR):int((t0 + 1.1)*SR)], lo=420, hi=900)
    pred = MAT["a4"] * 2 ** (((k * 700) % 1200) / 1200)
    esteps.append(dict(step=k, measuredHz=f_, predictedHz=pred,
                       cents=(k * 700) % 1200, errCents=1200*np.log2(f_/pred)))
out["walk"] = dict(steps=steps, stepSeconds=1.5,
                   maxErrCents=max(abs(s["errCents"]) for s in steps),
                   et=dict(steps=esteps,
                           maxErrCents=max(abs(s["errCents"]) for s in esteps),
                           finalHz=esteps[-1]["measuredHz"],
                           finalErrCentsFromA=1200*np.log2(esteps[-1]["measuredHz"]/440.0)))

# ---------------------------------------------------------------- 5. envelopes
# Saved for charts.py so the chart is drawn from the same arrays these numbers
# came from, not from a second computation.
def env_of(fname, part=None, secs=8.0):
    x = load(fname)[:int(secs*SR)]
    if part:
        x = bp(x, part)
    e = np.abs(hilbert(x))
    e = sosfiltfilt(butter(4, 60/(SR/2), btype="low", output="sos"), e)
    return e[::48]                      # 1 kHz, plenty for a 20 Hz beat
np.savez_compressed(f"{HERE}/envelopes.npz",
                    single=env_of("single"), unison=env_of("unison"),
                    comma=env_of("comma"),
                    fifth_pure=env_of("fifth-pure", PARTIAL["fifth"]),
                    fifth_et=env_of("fifth-et", PARTIAL["fifth"]),
                    third_pure=env_of("third-pure", PARTIAL["third"]),
                    third_et=env_of("third-et", PARTIAL["third"]),
                    third_et_full=env_of("third-et"),
                    walk=env_of("walk", secs=20.0), fs=np.array([1000.0]))

out["material"] = MAT
out["renders"] = REN
json.dump(out, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1)

print("== tuning (app render vs arithmetic) ==")
for k, v in tun.items():
    print(f"  {k:11s} {v['measuredHz']:10.4f} Hz  pred {v['predictedHz']:10.4f}  "
          f"err {v['errCents']:+.4f} cents")
print("== beating ==")
for k, v in beats.items():
    b = v.get("band") or v["full"]
    tag = "band" if "band" in v else "full"
    print(f"  {k:11s} pred {v['predictedHz']:7.3f} Hz | {tag} rate "
          f"{b['rateHz']:7.3f} depth {b['depth']:.4f} prom {b['prominence']:8.1f}"
          f" | full rate {v['full']['rateHz']:7.3f} depth {v['full']['depth']:.4f}")
print("== loudness ==")
for k, v in out["loudness"].items():
    print(f"  {k:11s} {v['lufs']:7.2f} LUFS  peak {v['truePeak']}")
print(f"== walk: max frequency error {out['walk']['maxErrCents']:+.4f} cents; "
      f"tempered walk max {out['walk']['et']['maxErrCents']:+.4f}, ends at "
      f"{out['walk']['et']['finalHz']:.4f} Hz "
      f"({out['walk']['et']['finalErrCentsFromA']:+.4f} cents from A) ==")

# ---------------------------------------------------------------- 6. excerpts
# ⭐ ONE SHARED STATIC GAIN PER PAIR. Every A/B in this film is a comparison of
# BEAT DEPTH, and `assemble.py` loudnorm-normalises each half separately unless
# the stage opts out — single-pass loudnorm is DYNAMIC, so on a signal whose
# whole point is a 6 Hz amplitude modulation it becomes the thing under test.
# Each pair is peak-normalised by the LOUDER member's peak, and the identical
# scalar is applied to both, so the relative level survives exactly.
PAIRS = {
    "unison": (("unison", "comma"), 12.0),
    "fifth": (("fifth-pure", "fifth-et"), 8.0),
    "third": (("third-pure", "third-et"), 8.0),
}
TARGET_PEAK = 10 ** (-3.0 / 20)
ex = {}
for tag, ((a, b), secs) in PAIRS.items():
    xa, xb = load(a)[:int(secs*SR)], load(b)[:int(secs*SR)]
    g = TARGET_PEAK / max(float(np.abs(xa).max()), float(np.abs(xb).max()))
    for nm, x in ((a, xa), (b, xb)):
        sf.write(f"{A}/ab-{nm}.wav", (x*g).astype(np.float32), SR)
    ex[tag] = dict(gain=float(g), seconds=secs,
                   files=[f"ab-{a}.wav", f"ab-{b}.wav"],
                   lufs={nm: lufs(f"{A}/ab-{nm}.wav")["lufs"] for nm in (a, b)})
    ex[tag]["deltaLu"] = round(ex[tag]["lufs"][b] - ex[tag]["lufs"][a], 2)
# The two walks — pure and tempered — are themselves an A/B (the film plays
# one, then the other), so they get ONE shared static gain like every other pair.
# ⚠ CUT TO THE NOTES, NOT TO THE RENDER LENGTH. The renders are 20.0 s but the
# thirteen notes finish at 19.5 s, so the last half second is digital silence —
# which made the burst builder's abutment control (the excerpt before must not
# be silent) fire, correctly, when the comma pair was laid straight after it.
WALK_SECS = 13 * 1.5
xw, xe = load("walk")[:int(WALK_SECS*SR)], load("walk-et")[:int(WALK_SECS*SR)]
gw = TARGET_PEAK / max(float(np.abs(xw).max()), float(np.abs(xe).max()))
sf.write(f"{A}/play-walk.wav", (xw*gw).astype(np.float32), SR)
sf.write(f"{A}/play-walk-et.wav", (xe*gw).astype(np.float32), SR)
ex["walk"] = dict(gain=float(gw), seconds=len(xw)/SR,
                  files=["play-walk.wav", "play-walk-et.wav"],
                  lufs={n: lufs(f"{A}/{n}.wav")["lufs"]
                        for n in ("play-walk", "play-walk-et")})
ex["walk"]["deltaLu"] = round(ex["walk"]["lufs"]["play-walk-et"]
                              - ex["walk"]["lufs"]["play-walk"], 2)
out["excerpts"] = ex
json.dump(out, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1)
print("== A/B pairs (ONE shared static gain each) ==")
for k, v in ex.items():
    if "lufs" in v:
        print(f"  {k:8s} gain x{v['gain']:.4f}  " +
              "  ".join(f"{n} {l:.2f} LUFS" for n, l in v["lufs"].items()) +
              f"   delta {v['deltaLu']:+.2f} LU")
