#!/usr/bin/env python3
"""Every measurement the "Beethoven at 128" rebuild makes, off the renders that
shoot.mjs wrote. Writes MEASUREMENTS.json and every A/B wav the film plays.

⚠ RUN WITH THE PLUGIN VENV. numpy/scipy/soundfile live only in
   plugins/narrated-film/.venv — the system python3 has none of them, and its
   ModuleNotFoundError reads like "found nothing" beside a stale JSON.

⚠ TWO INSTRUMENTS. Every loudness figure is measured by ffmpeg's ebur128 here
   as well as by the app at render time; both go in the file and the gap is
   reported. `ffmpeg -v error` SUPPRESSES the ebur128 summary, which logs at
   INFO — every call below uses -hide_banner -nostats and parses stderr.

⚠ THE HEADLINE BAND IS BELOW 60 Hz, NOT BELOW 100 Hz, AND THAT IS A FINDING.
   The shipped film claimed 18 dB below 100 Hz. Measured on this material the
   gap below 100 Hz is small, because a double-bass section really does put
   73–104 Hz into a room. The gap opens below the double bass's bottom string,
   which is where the honest claim lives. Both bands are measured and the
   60–100 Hz one — where the orchestra WINS — goes on screen too.
"""
import json, os, re, subprocess, sys
import numpy as np
import soundfile as sf
from scipy.signal import welch, butter, sosfilt, sosfiltfilt

HERE = os.path.dirname(os.path.abspath(__file__))
A = f"{HERE}/audio"
SR = 48000
FACTS = json.load(open(f"{A}/facts.json"))
SECS = FACTS["seconds"]

M = {"material": {k: FACTS[k] for k in
                  ("bpm", "bars", "seconds", "notes", "riffNotes",
                   "drumHits", "subNotes")},
     "parts": FACTS["parts"]}
M["material"]["beatMs"] = 60000.0 / FACTS["bpm"]
M["material"]["eighthMs"] = M["material"]["beatMs"] / 2


def rd(name):
    """Read a render as MONO. soundfile returns float for a float wav and
    normalises integer files to ±1, so every level here is dBFS either way."""
    x, sr = sf.read(f"{A}/{name}.wav", always_2d=True)
    assert sr == SR, f"{name}: {sr} Hz, expected {SR}"
    return x.mean(axis=1)


def rms_db(x):
    return float(20 * np.log10(np.sqrt(np.mean(np.square(x))) + 1e-20))


# ------------------------------------------------------------ ffmpeg ebur128
_EBU = re.compile(r"I:\s*(-?[\d.]+) LUFS.*?LRA:\s*(-?[\d.]+) LU.*?Peak:\s*(-?[\d.]+) dBFS",
                  re.S)


def ebur128(name):
    p = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", f"{A}/{name}.wav",
                        "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    tail = p.stderr[p.stderr.rfind("Integrated loudness"):]
    m = _EBU.search(tail)
    if not m:
        sys.exit(f"ebur128 gave no summary for {name} — did -v error suppress it?\n"
                 + p.stderr[-1200:])
    return dict(integratedLufs=float(m.group(1)), lra=float(m.group(2)),
                truePeakDbfs=float(m.group(3)))


# --------------------------------------------------------------- band levels
BANDS = [("sub40", 0, 40), ("sub60", 0, 60), ("sub80", 0, 80), ("sub100", 0, 100),
         ("b60_100", 60, 100), ("b100_200", 100, 200), ("b200up", 200, 24000)]


def band_table(x):
    """Absolute dBFS in each band: the file's full-band RMS scaled by the band's
    share of the Welch power spectrum. Doing it this way (rather than filtering)
    keeps every band on ONE consistent yardstick — the file's own RMS — so the
    numbers add up and a reader can check them."""
    full = rms_db(x)
    f, P = welch(x, SR, nperseg=32768)
    tot = np.trapezoid(P, f)
    out = {"full": full}
    for name, lo, hi in BANDS:
        s = (f >= lo) & (f < hi)
        out[name] = float(full + 10 * np.log10(np.trapezoid(P[s], f[s]) / tot + 1e-30))
    return out


ORCH, TECH = rd("orch"), rd("techno")

M["loudness"] = {}
for name in ("orch", "techno"):
    app = FACTS[name]
    ff = ebur128(name)
    M["loudness"][name] = dict(
        appLufs=app["integratedLufs"], ffmpegLufs=ff["integratedLufs"],
        lufsDelta=round(abs(app["integratedLufs"] - ff["integratedLufs"]), 3),
        appDbtp=app["truePeakDbtp"], lra=ff["lra"])
M["loudness"]["deltaLu"] = round(
    M["loudness"]["orch"]["ffmpegLufs"] - M["loudness"]["techno"]["ffmpegLufs"], 2)

M["bands"] = {"orch": band_table(ORCH), "techno": band_table(TECH)}
M["bands"]["delta"] = {k: round(M["bands"]["techno"][k] - M["bands"]["orch"][k], 2)
                       for k in M["bands"]["orch"]}
M["bands"]["stems"] = {p["name"]: band_table(rd(f"stem-{p['name'].lower()}"))
                       for p in FACTS["parts"]}

# ---- the spectra the centrepiece chart draws, saved so charts.py cannot
#      re-derive them differently from the numbers above
f, Po = welch(ORCH, SR, nperseg=32768)
_, Pt = welch(TECH, SR, nperseg=32768)
np.savez(f"{HERE}/spectra.npz", f=f, orch=Po, techno=Pt)
M["_chart"] = {"spectraNpz": "spectra.npz"}

# ---- where the two curves CROSS, measured rather than eyeballed ------------
sel = (f >= 25) & (f <= 400)
fs_, d = f[sel], 10 * np.log10(Pt[sel] / Po[sel])
# smooth over ~9 bins so a single noisy bin cannot define the crossing
k = np.ones(9) / 9
ds = np.convolve(d, k, mode="same")
cross = [float(fs_[i]) for i in range(1, len(ds)) if ds[i - 1] > 0 >= ds[i]]
M["_chart"]["crossoverHz"] = round(cross[0], 1) if cross else None

# ------------------------------------------------------- THE LAPTOP QUESTION
# What a small speaker actually hands you: the same file with everything under
# 100 Hz taken away. Measured, not assumed — both in plain RMS (which is what
# the missing energy really is) and in LUFS (which is K-weighted, and therefore
# already discounts the bottom octaves — a much smaller number, and that
# difference is itself worth saying out loud).
sos_hp = butter(8, 100, "highpass", fs=SR, output="sos")
M["laptop"] = {}
for name, x in (("orch", ORCH), ("techno", TECH)):
    hp = sosfiltfilt(sos_hp, x)
    sf.write(f"{A}/{name}-hp100.wav", np.stack([hp, hp], axis=1), SR)
    ff_full, ff_hp = ebur128(name), ebur128(f"{name}-hp100")
    M["laptop"][name] = dict(
        fullRmsDb=round(rms_db(x), 2), hpRmsDb=round(rms_db(hp), 2),
        rmsLossDb=round(rms_db(x) - rms_db(hp), 2),
        fullLufs=ff_full["integratedLufs"], hpLufs=ff_hp["integratedLufs"],
        lufsLossLu=round(ff_full["integratedLufs"] - ff_hp["integratedLufs"], 2))

# ------------------------------------------------- THE AUDIBLE PROXY (octave)
# The sub part moved up two octaves, so a laptop can show the SHAPE of the thing
# it cannot reproduce where the thing actually lives. Both renders are the whole
# techno mix minus everything except the sub, so the only difference is pitch.
SO, SU = rd("sub-orig"), rd("sub-up2")
M["proxy"] = dict(orig=band_table(SO), up2=band_table(SU),
                  origLufs=ebur128("sub-orig")["integratedLufs"],
                  up2Lufs=ebur128("sub-up2")["integratedLufs"],
                  origHz=[32.70, 49.00], up2Hz=[130.81, 196.00])
M["proxy"]["origAbove100Db"] = round(M["proxy"]["orig"]["b100_200"], 2)
M["proxy"]["up2Above100Db"] = round(M["proxy"]["up2"]["b100_200"], 2)
# ⭐ THE TWO NUMBERS THE PROXY CHAPTER RESTS ON: moving the part up two octaves
# changes its OVERALL level by essentially nothing, and changes what a small
# speaker can reach by a very great deal.
M["proxy"]["above100GainDb"] = round(
    M["proxy"]["up2"]["b100_200"] - M["proxy"]["orig"]["b100_200"], 2)
M["proxy"]["fullBandDeltaDb"] = round(
    M["proxy"]["up2"]["full"] - M["proxy"]["orig"]["full"], 2)

# ------------------------------------------------------------- the layer rungs
M["layers"] = []
for L in FACTS["layers"]:
    ff = ebur128(L["tag"])
    M["layers"].append(dict(tag=L["tag"], keep=L["keep"],
                            lufs=ff["integratedLufs"],
                            bands=band_table(rd(L["tag"]))))

# ------------------------------------------------- THE ATTENTION MARKER TRACE
# ⚠ THE FIRST DESIGN OF THIS WAS USELESS AND THE MEASUREMENT SAID SO. Sweeping
# the orchestral render against the techno one below 60 Hz produced ONE shaded
# window covering the entire eight seconds — the techno sub is simply on the
# whole time and the orchestra is simply never there. A marker with nothing
# unshaded says nothing about WHEN to listen.
#
# So the marker sweeps the TECHNO RENDER'S FIRST TWELVE SECONDS instead, where
# the room arrives one strip at a time. Two traces: the level under 60 Hz and
# the level above 100 Hz. The second one is the control — it barely moves, which
# is what proves that what changes at 7.5 s is only down at the bottom. The
# shaded window is DERIVED: every stretch where the sub-60 trace stands more
# than 15 dB above its own pre-sub baseline.
MK_FROM, MK_SECS = 0.0, 12.0
HOP = 0.04
sos_lp = butter(8, 60, "lowpass", fs=SR, output="sos")


def trace(x, sos, t0=MK_FROM, dur=MK_SECS):
    y = sosfiltfilt(sos, x)[int(t0 * SR):int((t0 + dur) * SR)]
    W = int(HOP * SR)
    n = len(y) // W
    return np.array([20 * np.log10(np.sqrt(np.mean(y[i * W:(i + 1) * W] ** 2)) + 1e-12)
                     for i in range(n)])


low = trace(TECH, sos_lp)
high = trace(TECH, sos_hp)
t = np.arange(len(low)) * HOP

# where each strip actually STARTS, measured off its own stem rather than read
# off the score — a note that failed to render would move the marker and say so
onsets = {}
for nm in ("Riff", "Kick", "Hats", "Clap", "Sub"):
    st = rd(f"stem-{nm.lower()}")
    idx = np.argmax(np.abs(st) > 3e-4)
    onsets[nm] = round(float(idx) / SR, 3)

base = float(np.median(low[t < onsets["Sub"] - 0.2]))
hot = low > base + 15.0
wins, i = [], 0
while i < len(hot):
    if hot[i]:
        j = i
        while j + 1 < len(hot) and hot[j + 1]:
            j += 1
        wins.append([float(t[i]), float(t[j] + HOP)])
        i = j + 1
    else:
        i += 1
merged = []
for w in wins:
    if merged and w[0] - merged[-1][1] < 0.15:
        merged[-1][1] = w[1]
    else:
        merged.append(w)
merged = [w for w in merged if w[1] - w[0] >= 0.25]
M["marker"] = dict(fromSeconds=MK_FROM, seconds=MK_SECS, hopSeconds=HOP,
                   baselineDb=round(base, 2), thresholdDb=15.0, windows=merged,
                   onsets=onsets,
                   liftDb=round(float(np.median(low[t >= onsets["Sub"] + 0.2])) - base, 2),
                   # ⚠ THE CONTROL WINDOW HAS TO STOP AT THE CLAP. The clap
                   # arrives 2.3 s AFTER the sub, so an "after" window running to
                   # the end measures the clap as well and the control stops
                   # being a control. Both windows sit between hats and clap.
                   highLiftDb=round(
                       float(np.median(high[(t >= onsets["Sub"] + 0.2)
                                            & (t < onsets["Clap"] - 0.2)]))
                       - float(np.median(high[(t > onsets["Hats"] + 0.2)
                                              & (t < onsets["Sub"] - 0.2)])), 2),
                   lowLiftControlDb=round(
                       float(np.median(low[(t >= onsets["Sub"] + 0.2)
                                           & (t < onsets["Clap"] - 0.2)]))
                       - float(np.median(low[(t > onsets["Hats"] + 0.2)
                                             & (t < onsets["Sub"] - 0.2)])), 2),
                   low=[round(float(v), 2) for v in low],
                   high=[round(float(v), 2) for v in high])

# ----------------------------------------------------------------- A/B wavs
# ⚠ ONE SHARED STATIC GAIN PER PAIR, never per-half loudnorm. The level
# difference IS the lesson in two of these three pairs, and assemble.py's
# default would flatten it. Every stage that plays one of these sets
# normalize:false.
def excerpt(x, t0, dur):
    return x[int(t0 * SR):int((t0 + dur) * SR)]


def shared_gain(chunks, headroom_db=-1.0):
    pk = max(float(np.abs(c).max()) for c in chunks)
    return 10 ** (headroom_db / 20) / max(pk, 1e-9)


def write_pair(tag, a, b, gain):
    out = []
    for name, x in ((f"{tag}-a", a), (f"{tag}-b", b)):
        y = x * gain
        sf.write(f"{A}/{name}.wav", np.stack([y, y], axis=1), SR)
        out.append(dict(file=name, rmsDb=round(rms_db(y), 2),
                        lufs=ebur128(name)["integratedLufs"]))
    return dict(gainDb=round(20 * np.log10(gain), 2),
                a=out[0], b=out[1],
                deltaLu=round(out[1]["lufs"] - out[0]["lufs"], 2))


AB_FROM, AB_SECS = 15.0, 8.0
M["ab"] = {}
eo, et = excerpt(ORCH, AB_FROM, AB_SECS), excerpt(TECH, AB_FROM, AB_SECS)
M["ab"]["versions"] = write_pair("ab-ver", eo, et, shared_gain([eo, et]))

ef = et
eh = excerpt(sosfiltfilt(sos_hp, TECH), AB_FROM, AB_SECS)
M["ab"]["laptop"] = write_pair("ab-lap", ef, eh, shared_gain([ef, eh]))

es, eu = excerpt(SO, AB_FROM, AB_SECS), excerpt(SU, AB_FROM, AB_SECS)
M["ab"]["proxy"] = write_pair("ab-sub", es, eu, shared_gain([es, eu]))

# the clean play-segment excerpts (mono→stereo, one shared gain with the pair
# they belong to so nothing jumps between a talk and a play beat)
for tag, x, t0, dur in (("play-orch", ORCH, AB_FROM, AB_SECS),
                        ("play-techno", TECH, AB_FROM, AB_SECS),
                        ("play-build", TECH, 0.0, 12.0)):
    y = excerpt(x, t0, dur)
    y = y * shared_gain([y])
    sf.write(f"{A}/{tag}.wav", np.stack([y, y], axis=1), SR)

# ⚠ THE CELL EXCERPT COMES FROM THE RIFF-ONLY RENDER, NOT THE MIX. Cut from
# techno.wav it would contain the kick, which enters at bar 2 = 1.875 s — and
# the animation it plays under draws nothing but the cell while the narration
# says "you are hearing the cell itself". Two bars of the riff, alone.
cell = excerpt(rd("l1-riff"), 0.0, 3.75)
cell = cell * shared_gain([cell])
sf.write(f"{A}/play-cell.wav", np.stack([cell, cell], axis=1), SR)

json.dump(M, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1)

# ------------------------------------------------------------------- report
print(f"MEASUREMENTS.json  ({os.path.getsize(f'{HERE}/MEASUREMENTS.json'):,} bytes)")
print(f"\nloudness   orch {M['loudness']['orch']['ffmpegLufs']:.2f} LUFS   "
      f"techno {M['loudness']['techno']['ffmpegLufs']:.2f} LUFS   "
      f"delta {M['loudness']['deltaLu']:+.2f} LU")
print(f"app vs ffmpeg: orch {M['loudness']['orch']['lufsDelta']:.2f}  "
      f"techno {M['loudness']['techno']['lufsDelta']:.2f} LU apart")
print("\nband            orch   techno    delta")
for k, _, _ in [("full", 0, 0)] + [(b[0], 0, 0) for b in BANDS]:
    print(f"  {k:9s} {M['bands']['orch'][k]:7.2f} {M['bands']['techno'][k]:8.2f} "
          f"{M['bands']['delta'][k]:+8.2f}")
print(f"\ncrossover: {M['_chart']['crossoverHz']} Hz")
print(f"\nlaptop (high-passed at 100 Hz):")
for k, v in M["laptop"].items():
    print(f"  {k:7s} RMS loss {v['rmsLossDb']:5.2f} dB   LUFS loss {v['lufsLossLu']:5.2f} LU")
print(f"\nproxy: +{M['proxy']['above100GainDb']:.2f} dB above 100 Hz for "
      f"{M['proxy']['fullBandDeltaDb']:+.2f} dB of overall level")
print(f"proxy: sub as written {M['proxy']['orig']['full']:.2f} dB "
      f"({M['proxy']['origAbove100Db']:.2f} above 100 Hz), "
      f"up two octaves {M['proxy']['up2']['full']:.2f} dB "
      f"({M['proxy']['up2Above100Db']:.2f} above 100 Hz)")
print(f"\nmarker: {len(merged)} windows, baseline {M['marker']['baselineDb']:.2f} dB, "
      f"sub lifts <60 Hz by {M['marker']['liftDb']:+.2f} dB "
      f"while >100 Hz moves {M['marker']['highLiftDb']:+.2f} dB")
print("  onsets: " + "  ".join(f"{k} {v:.3f}s" for k, v in M['marker']['onsets'].items()))
for w in merged:
    print(f"   {w[0]:5.2f} – {w[1]:5.2f} s")
print("\nA/B pairs (source deltas the film's gate will be judged against):")
for k, v in M["ab"].items():
    print(f"  {k:9s} gain {v['gainDb']:+6.2f} dB   "
          f"a {v['a']['lufs']:7.2f}  b {v['b']['lufs']:7.2f}  delta {v['deltaLu']:+6.2f} LU")
print("\nlayers:")
for L in M["layers"]:
    print(f"  {L['tag']:9s} {L['lufs']:7.2f} LUFS   <60 {L['bands']['sub60']:7.2f}   "
          f"{'+'.join(L['keep'])}")
