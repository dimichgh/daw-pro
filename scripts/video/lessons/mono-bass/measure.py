#!/usr/bin/env python3
"""L8 "Mono Your Bass" — PASS 2. Measure everything the film says, off the
renders shoot.mjs just made, and write MEASUREMENTS.json.

⚠ RUN WITH THE PLUGIN VENV. numpy/scipy live only in
`plugins/narrated-film/.venv/bin/python`; the system python3 has neither, and
its ModuleNotFoundError next to a stale MEASUREMENTS.json from a previous run
reads exactly like "the analysis found nothing".

THE PREDICTION, stated before anything is measured. Summing two copies of the
same signal a delay τ apart multiplies every frequency f by

        H(f) = |cos(π f τ)|          (a comb filter)

so at τ = 6 ms the nulls fall at 83.3, 250, 416.7 … Hz and the peaks at 166.7,
333.3, 500 … Hz. Everything below is that prediction against a render.

⚠ THE CONTROL IS THE 0 ms RENDER, and it is not decoration: the two renders
differ ONLY in a note-start offset, so anything the fold does to the 6 ms file
and not to the 0 ms file is summing, not the instrument, the mix or the
encoder.
"""
import json, os, sys
import numpy as np
from scipy.io import wavfile
from scipy.signal import welch, butter, sosfiltfilt

HERE = os.path.dirname(os.path.abspath(__file__))
AUD = os.path.join(HERE, "audio")
SR = 48000
EPS = 1e-12


def rd(name):
    sr, x = wavfile.read(os.path.join(AUD, name + ".wav"))
    assert sr == SR, f"{name}: {sr} Hz, expected {SR}"
    x = x.astype(np.float64)
    if x.dtype.kind in "iu" or np.max(np.abs(x)) > 4.0:      # ints, if ever
        x = x / 32768.0
    return x


def db(v):
    return float(20 * np.log10(max(float(v), EPS)))


def rms_db(x):
    return db(np.sqrt(np.mean(np.square(x))) if len(x) else 0.0)


def band(x, lo, hi):
    """Zero-phase band filter. Zero phase matters: a causal filter would smear
    the note windows this file measures inside."""
    nyq = SR / 2
    if hi >= nyq * 0.99:
        sos = butter(4, lo / nyq, btype="highpass", output="sos")
    elif lo <= 0:
        sos = butter(4, hi / nyq, btype="lowpass", output="sos")
    else:
        sos = butter(4, [lo / nyq, hi / nyq], btype="bandpass", output="sos")
    return sosfiltfilt(sos, x, axis=0)


def fold(x):
    """Sum to mono the way a mono PA does: (L+R)/2, kept as stereo L=R so the
    film's A/B halves are the same shape as every other segment."""
    m = 0.5 * (x[:, 0] + x[:, 1])
    return m


def lag_ms(x):
    """MEASURED offset between the two channels, by cross-correlation.

    ⚠ THIS IS THE GATE ON THE WHOLE EXPERIMENT. The nudge is applied as a
    fractional-beat note offset; a quantiser or an overlap policy snapping it
    would leave a film arguing about a delay that is not in the audio. Nothing
    else in this build would notice."""
    a, b = x[:, 0], x[:, 1]
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    c = np.fft.irfft(np.fft.rfft(a, n) * np.conj(np.fft.rfft(b, n)), n)
    c = np.concatenate([c[-2000:], c[:2000]])
    k = int(np.argmax(np.abs(c))) - 2000
    return -k / SR * 1000.0           # positive = right channel LATE


def comb_db(f, tau):
    return 20 * np.log10(np.maximum(np.abs(np.cos(np.pi * np.asarray(f) * tau)), 1e-6))


def tone_db(seg, f0):
    """Magnitude of one frequency in one window (Goertzel-by-FFT, Hann)."""
    w = np.hanning(len(seg))
    sp = np.fft.rfft(seg * w)
    fr = np.fft.rfftfreq(len(seg), 1 / SR)
    k = int(np.argmin(np.abs(fr - f0)))
    lo, hi = max(k - 2, 0), min(k + 3, len(sp))
    return db(np.max(np.abs(sp[lo:hi])) / (np.sum(w) / 2))


def st_series(x, lo, hi, hop=0.020, win=0.060):
    """Short-time band RMS in dB — the data the time chart is drawn from."""
    y = band(x, lo, hi)
    h, w = int(hop * SR), int(win * SR)
    out = []
    for i in range(0, len(y) - w, h):
        out.append((round(i / SR, 4), round(rms_db(y[i:i + w]), 2)))
    return out


# --------------------------------------------------------------------- load
riff = json.load(open(os.path.join(AUD, "riff.json")))
BPM, SECS = riff["bpm"], riff["seconds"]
st = {ms: rd(f"st{ms}") for ms in (0, 6, 15)}
single = rd("single")
folds = {ms: fold(v) for ms, v in st.items()}
for ms, m in folds.items():                       # written for the film's A/B
    wavfile.write(os.path.join(AUD, f"fold{ms}.wav"),
                  SR, np.column_stack([m, m]).astype(np.float32))

M = {"_method": "measure.py, off the renders shoot.mjs made; venv python",
     "material": {"bpm": BPM, "seconds": SECS, "notes": riff["noteCount"],
                  "instrument": "polySynth saw, cutoff 1400 Hz",
                  "tracks": "two, hard L / hard R, identical part"}}

# ---------------------------------------------- 1. the offset actually landed
M["offset_measured_ms"] = {str(ms): round(lag_ms(v), 4) for ms, v in st.items()}
M["offset_asked_ms"] = {"0": 0, "6": 6, "15": 15}

# ---------------------------------------------- 2. the control: L is untouched
M["left_channel_rms_dbfs"] = {str(ms): round(rms_db(band(v[:, 0], 60, 110)), 3)
                              for ms, v in st.items()}
M["left_channel_fullband_dbfs"] = {str(ms): round(rms_db(v[:, 0]), 3)
                                   for ms, v in st.items()}

# ---------------------------------------------- 3. the headline: the mono fold
BLO, BHI = 60, 110
M["fold_60_110_dbfs"] = {str(ms): round(rms_db(band(m, BLO, BHI)), 3)
                         for ms, m in folds.items()}
M["fold_loss_vs_0ms_db"] = {str(ms): round(M["fold_60_110_dbfs"][str(ms)]
                                           - M["fold_60_110_dbfs"]["0"], 3)
                            for ms in (6, 15)}
M["fold_fullband_dbfs"] = {str(ms): round(rms_db(m), 3) for ms, m in folds.items()}

# ---------------------------------- 4. the mid-band consequence, MEASURED
# The question the house standard forces: is there anything in the band a
# laptop speaker actually reproduces, and at what ABSOLUTE level does it live?
for lo, hi in ((150, 600), (600, 2000), (20, 100)):
    M[f"fold_{lo}_{hi}_dbfs"] = {str(ms): round(rms_db(band(m, lo, hi)), 3)
                                 for ms, m in folds.items()}
M["midband_150_600_loss_db"] = round(M["fold_150_600_dbfs"]["6"]
                                     - M["fold_150_600_dbfs"]["0"], 3)
M["sub100_loss_db"] = round(M["fold_20_100_dbfs"]["6"] - M["fold_20_100_dbfs"]["0"], 3)

# ---------------------------------- 5. per note: predicted against measured
PITCH_HZ = lambda p: 440.0 * 2 ** ((p - 69) / 12.0)
beat_s = 60.0 / BPM
per_note, seen = [], {}
for nt in riff["notes"]:
    p = nt["pitch"]
    if p in seen:
        continue
    t0 = nt["startBeat"] * beat_s + 0.030
    ln = min(nt["lengthBeats"] * beat_s - 0.060, 0.200)
    if ln < 0.100:
        continue
    a, b = int(t0 * SR), int((t0 + ln) * SR)
    f0 = PITCH_HZ(p)
    d0, d6 = tone_db(folds[0][a:b], f0), tone_db(folds[6][a:b], f0)
    seen[p] = True
    per_note.append({"pitch": p, "hz": round(f0, 2),
                     "predicted_db": round(float(comb_db(f0, 0.006)), 2),
                     "measured_db": round(d6 - d0, 2),
                     "atBeat": nt["startBeat"]})
M["per_note_fundamental_fold_db"] = sorted(per_note, key=lambda r: r["hz"])
M["per_note_note"] = ("fold of the FUNDAMENTAL only, 6 ms vs 0 ms, in a 200 ms "
                      "window inside the note. predicted = 20log10|cos(pi f tau)|")

# ---------------------------------- 6. the spectrum: measured PSD ratio
f, p0 = welch(folds[0], SR, nperseg=1 << 15, noverlap=1 << 14)
_, p6 = welch(folds[6], SR, nperseg=1 << 15, noverlap=1 << 14)
_, p15 = welch(folds[15], SR, nperseg=1 << 15, noverlap=1 << 14)
sel = (f >= 25) & (f <= 1200)
M["_psd"] = {"hz": [round(x, 2) for x in f[sel]],
             "ratio6_db": [round(10 * np.log10((b + EPS) / (a + EPS)), 3)
                           for a, b in zip(p0[sel], p6[sel])],
             "ratio15_db": [round(10 * np.log10((b + EPS) / (a + EPS)), 3)
                            for a, b in zip(p0[sel], p15[sel])],
             "predicted6_db": [round(x, 3) for x in comb_db(f[sel], 0.006)],
             "predicted15_db": [round(x, 3) for x in comb_db(f[sel], 0.015)]}
M["comb_nulls_hz_6ms"] = [round((2 * k + 1) / (2 * 0.006), 1) for k in range(4)]
M["comb_nulls_hz_15ms"] = [round((2 * k + 1) / (2 * 0.015), 1) for k in range(4)]

# ---------------------------------- 7. the time chart + DERIVED listen windows
CH_T0, CH_LEN = 12.0, 7.2            # bars 7-8 + : where E1 and E2 alternate
a, b = int(CH_T0 * SR), int((CH_T0 + CH_LEN) * SR)
s0 = st_series(folds[0][a:b], 40, 130)
s6 = st_series(folds[6][a:b], 40, 130)
diff = [(t, round(y0 - y6, 2)) for (t, y0), (_, y6) in zip(s0, s6)]
# ⚠ DERIVED, NEVER CHOSEN BY EYE: every window in which the 6 ms fold is more
# than 6 dB quieter in the low band than the 0 ms one, merged across gaps
# shorter than 120 ms and dropped if shorter than 150 ms.
THR = 6.0
win, cur = [], None
for t, d in diff:
    if d > THR:
        cur = [t, t] if cur is None else [cur[0], t]
    elif cur is not None:
        win.append(cur); cur = None
if cur is not None:
    win.append(cur)
merged = []
for w in win:
    if merged and w[0] - merged[-1][1] < 0.12:
        merged[-1][1] = w[1]
    else:
        merged.append(list(w))
merged = [[round(x, 3), round(y, 3)] for x, y in merged if y - x >= 0.15]
M["_chart"] = {"t0": CH_T0, "len": CH_LEN, "band": [40, 130],
               "s0": s0, "s6": s6, "threshold_db": THR, "windows": merged,
               "max_diff_db": round(max(d for _, d in diff), 2)}

# ---------------------------------- 8. the A/B excerpt, and its shared gain
# ⚠ ONE gain on BOTH halves. The level difference IS the lesson; per-half
# loudnorm would flatten it, which is the trap the A/B separation gate exists
# for. The gain is chosen from the LOUDER half so neither half clips.
EX_T0, EX_LEN = 12.0, 8.0
ea, eb = int(EX_T0 * SR), int((EX_T0 + EX_LEN) * SR)
peak = max(np.max(np.abs(folds[0][ea:eb])), np.max(np.abs(folds[6][ea:eb])),
           np.max(np.abs(folds[15][ea:eb])))
G = 10 ** (-1.0 / 20) / max(peak, EPS)         # land the louder half at -1 dBFS
for ms in (0, 6, 15):
    seg = folds[ms][ea:eb] * G
    fadeN = int(0.02 * SR)
    seg[:fadeN] *= np.linspace(0, 1, fadeN)
    seg[-fadeN:] *= np.linspace(1, 0, fadeN)
    wavfile.write(os.path.join(AUD, f"ab{ms}.wav"), SR,
                  np.column_stack([seg, seg]).astype(np.float32))
M["ab_excerpt"] = {"fromSec": EX_T0, "seconds": EX_LEN,
                   "shared_gain_db": round(db(G), 3),
                   "rms_dbfs": {str(ms): round(rms_db(folds[ms][ea:eb] * G), 3)
                                for ms in (0, 6, 15)},
                   "low_40_130_dbfs": {str(ms): round(rms_db(band(folds[ms][ea:eb] * G, 40, 130)), 3)
                                       for ms in (0, 6, 15)},
                   "mid_150_600_dbfs": {str(ms): round(rms_db(band(folds[ms][ea:eb] * G, 150, 600)), 3)
                                        for ms in (0, 6, 15)}}

# ---------------------------------- 9. the chart's own audio (0 ms then 6 ms)
ca, cb = int(CH_T0 * SR), int((CH_T0 + CH_LEN) * SR)
cpk = max(np.max(np.abs(folds[0][ca:cb])), np.max(np.abs(folds[6][ca:cb])))
CG = 10 ** (-1.0 / 20) / max(cpk, EPS)
for ms in (0, 6):
    seg = folds[ms][ca:cb] * CG
    wavfile.write(os.path.join(AUD, f"chart{ms}.wav"), SR,
                  np.column_stack([seg, seg]).astype(np.float32))
M["chart_audio_gain_db"] = round(db(CG), 3)

# ------------------- 10. WHAT A SMALL SPEAKER ACTUALLY GETS, measured
# ⚠ THE HOUSE STANDARD'S QUESTION, and the reason this rebuild exists: a
# difference in dB is not a difference you can hear. A laptop speaker is
# effectively a high-pass around 150-200 Hz, so measure the A/B halves through
# one and report BOTH numbers rather than quoting the big one and hoping.
M["laptop_band"] = {
    "_what": "A/B halves high-passed at 200 Hz — roughly what a laptop radiates",
    "hp200_dbfs": {str(ms): round(rms_db(band(folds[ms][ea:eb] * G, 200, 20000)), 3)
                   for ms in (0, 6, 15)},
}
M["laptop_band"]["hp200_loss_6ms_db"] = round(
    M["laptop_band"]["hp200_dbfs"]["6"] - M["laptop_band"]["hp200_dbfs"]["0"], 3)
# and over the WHOLE render, so the film quotes ONE set of numbers rather than
# excerpt figures next to whole-render ones.
M["laptop_band"]["hp200_full_dbfs"] = {str(ms): round(rms_db(band(m, 200, 20000)), 3)
                                       for ms, m in folds.items()}
M["laptop_band"]["hp200_full_loss_db"] = {
    str(ms): round(M["laptop_band"]["hp200_full_dbfs"][str(ms)]
                   - M["laptop_band"]["hp200_full_dbfs"]["0"], 3) for ms in (6, 15)}

# ------------------- 10b. THE 6 ms vs 15 ms A/B, judged the same way
# ⚠ THIS PAIR IS THE SUBTLE ONE AND THE FILM HAS TO SAY SO. Their integrated
# loudness differs by well under 1 LU, so a viewer on a small speaker will hear
# almost nothing — exactly the fault this rebuild exists to fix, so it is
# measured here and stated on screen rather than discovered by a viewer.
M["six_vs_fifteen"] = {
    "low_40_130_db": round(M["ab_excerpt"]["low_40_130_dbfs"]["15"]
                           - M["ab_excerpt"]["low_40_130_dbfs"]["6"], 3),
    "hp200_db": round(M["laptop_band"]["hp200_dbfs"]["15"]
                      - M["laptop_band"]["hp200_dbfs"]["6"], 3)}

# ------------------- 11. ONE NOTE, HARMONIC BY HARMONIC
# E2 is the note that lands on the null. Its fundamental (82.4) is annihilated
# AND its third harmonic (247) sits on the 250 Hz null; its second (165) sits
# on the 167 Hz PEAK and survives untouched. That is what "combed" means and it
# is the single clearest picture in the lesson.
E2_MIDI = 40
e2 = next(n for n in riff["notes"] if n["pitch"] == E2_MIDI and n["lengthBeats"] >= 0.9)
t0 = e2["startBeat"] * beat_s + 0.030
a2, b2 = int(t0 * SR), int((t0 + 0.42) * SR)
f0 = PITCH_HZ(E2_MIDI)
M["e2_harmonics"] = [{"n": k, "hz": round(f0 * k, 2),
                      "predicted_db": round(float(comb_db(f0 * k, 0.006)), 2),
                      "measured_db": round(tone_db(folds[6][a2:b2], f0 * k)
                                           - tone_db(folds[0][a2:b2], f0 * k), 2),
                      "level0_dbfs": round(tone_db(folds[0][a2:b2], f0 * k), 2)}
                     for k in range(1, 9)]
M["e2_atBeat"] = e2["startBeat"]

json.dump(M, open(os.path.join(HERE, "MEASUREMENTS.json"), "w"), indent=1)

# ------------------------------------------------------------------- report
print(f"offset measured ms   {M['offset_measured_ms']}")
print(f"L control 60-110     {M['left_channel_rms_dbfs']}")
print(f"fold 60-110          {M['fold_60_110_dbfs']}")
print(f"fold loss vs 0 ms    {M['fold_loss_vs_0ms_db']}")
print(f"fold 20-100          {M['fold_20_100_dbfs']}   loss {M['sub100_loss_db']}")
print(f"fold 150-600         {M['fold_150_600_dbfs']}  loss {M['midband_150_600_loss_db']}")
print(f"fold 600-2000        {M['fold_600_2000_dbfs']}")
print(f"nulls 6 ms           {M['comb_nulls_hz_6ms']}")
print("per note (Hz, predicted, measured):")
for r in M["per_note_fundamental_fold_db"]:
    print(f"   {r['hz']:8.2f}  {r['predicted_db']:8.2f}  {r['measured_db']:8.2f}")
print(f"chart windows        {M['_chart']['windows']}  max diff "
      f"{M['_chart']['max_diff_db']} dB")
print(f"A/B shared gain      {M['ab_excerpt']['shared_gain_db']:+.2f} dB")
print(f"A/B rms              {M['ab_excerpt']['rms_dbfs']}")
print(f"A/B low 40-130       {M['ab_excerpt']['low_40_130_dbfs']}")
print(f"A/B mid 150-600      {M['ab_excerpt']['mid_150_600_dbfs']}")
print(f"laptop band hp200    {M['laptop_band']['hp200_dbfs']}  loss "
      f"{M['laptop_band']['hp200_loss_6ms_db']}")
print(f"6 ms vs 15 ms         {M['six_vs_fifteen']}")
print("E2, harmonic by harmonic (n, Hz, predicted, measured, level in 0 ms fold):")
for r in M["e2_harmonics"]:
    print(f"   {r['n']}  {r['hz']:8.2f}  {r['predicted_db']:8.2f}  "
          f"{r['measured_db']:8.2f}   {r['level0_dbfs']:8.2f}")
