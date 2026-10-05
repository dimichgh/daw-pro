#!/usr/bin/env python3
"""Measure every number the film says, off the renders made in this session.

Writes MEASUREMENTS.json, envelopes.npz, and the four pre-gained A/B wavs.

⭐ TWO INSTRUMENTS ON THE LOUDNESS. The app's own render report is recorded in
renders.json; this re-measures the same files with ffmpeg's EBU R128 analyser.
Where they disagree the film says the ffmpeg figure and NOTES says both.

⚠ `ffmpeg -v error` SUPPRESSES the ebur128 summary (it logs at INFO). Every
call here uses -hide_banner and parses the summary block.
"""
import json, os, re, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
A = f"{HERE}/audio"
SR = 48000
R = json.load(open(f"{HERE}/renders.json"))


def read_wav(path):
    """Decode to float32 mono and stereo through ffmpeg (the wavs are 32-bit float)."""
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-v", "error", "-i", path,
                          "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
                         capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype="<f4").reshape(-1, 2)
    return x, x.mean(axis=1)


def ebur128(path):
    out = subprocess.run(["ffmpeg", "-hide_banner", "-i", path,
                          "-af", "ebur128=framelog=quiet:peak=true", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    g = lambda k: (float(m.group(1)) if (m := re.search(rf"{k}:\s+(-?\d+\.?\d*)", out)) else None)
    return {"integratedLufs": g("I"), "truePeakDbtp": g("Peak"),
            "lra": g("LRA")}


def band_db(mono, lo, hi):
    """Energy in a band, in dB relative to full scale, by Welch PSD."""
    n = 8192
    w = np.hanning(n)
    step = n // 2
    acc = np.zeros(n // 2 + 1)
    k = 0
    for i in range(0, len(mono) - n, step):
        acc += np.abs(np.fft.rfft(mono[i:i + n] * w)) ** 2
        k += 1
    psd = acc / max(k, 1)
    f = np.fft.rfftfreq(n, 1 / SR)
    sel = (f >= lo) & (f < hi)
    tot = psd.sum()
    return 10 * np.log10(psd[sel].sum() / (n * n / 4) + 1e-20), psd[sel].sum() / (tot + 1e-30)


def onset_env(mono, hop=480):
    """Half-wave-rectified spectral flux at 100 Hz, the standard onset strength."""
    n = 2048
    w = np.hanning(n)
    frames = range(0, len(mono) - n, hop)
    S = np.array([np.abs(np.fft.rfft(mono[i:i + n] * w)) for i in frames])
    d = np.diff(S, axis=0)
    return np.maximum(d, 0).sum(axis=1)


def onset_rate(mono, lo=2.0, hi=14.0, hop=480):
    """The dominant repetition rate of the onset envelope, in onsets per second."""
    e = onset_env(mono, hop)
    e = e - e.mean()
    if not np.any(e):
        return None, 0.0
    N = 1 << int(np.ceil(np.log2(len(e) * 4)))
    P = np.abs(np.fft.rfft(e * np.hanning(len(e)), N)) ** 2
    f = np.fft.rfftfreq(N, hop / SR)
    sel = (f >= lo) & (f <= hi)
    i = np.argmax(P[sel])
    idx = np.where(sel)[0][i]
    # parabolic interpolation on the log-power peak
    a, b, c = np.log(P[idx - 1] + 1e-30), np.log(P[idx] + 1e-30), np.log(P[idx + 1] + 1e-30)
    d = 0.5 * (a - c) / (a - 2 * b + c + 1e-30)
    df = f[1] - f[0]
    return float(f[idx] + d * df), float(P[idx] / (P[sel].sum() + 1e-30))


def rms_env(mono, fps=50):
    hop = SR // fps
    n = len(mono) // hop
    return np.array([np.sqrt((mono[i * hop:(i + 1) * hop] ** 2).mean() + 1e-20)
                     for i in range(n)])


M = {"renderReport": R["renders"], "balance": R["balance"], "counts": R["counts"],
     "bpm": R["bpm"], "entry": R["entry"], "roots": R["roots"],
     "barPitches": R["barPitches"], "bassDrop": R["bassDrop"],
     "tempoChangeMovedNothing": R["tempoChangeMovedNothing"],
     "pianoNotes": R["pianoNotes"]}

# ── the invariance claim, with its own positive control ─────────────────────
onsets = [[round(o, 4) for o in b] for b in R["barOnsets"]]
pitches = R["barPitches"]
onset_changes = sum(1 for i in range(1, 8) if onsets[i] != onsets[i - 1])
pitch_changes = sum(1 for i in range(1, 8) if pitches[i] != pitches[i - 1])
identical_pairs = [(i + 1, j + 1) for i in range(8) for j in range(i + 1, 8)
                   if pitches[i] == pitches[j]]
M["invariance"] = {
    "onsetsPerBar": len(onsets[0]), "onsetVector": onsets[0],
    "onsetChangesAcross8Bars": onset_changes,
    "pitchChangesAcross8Bars": pitch_changes,
    "identicalPitchBarPairs": identical_pairs,
    "note": "the SAME comparator run on the pitch vectors returns 7 changes and "
            "finds bars 1 and 4 identical, which is the positive control that a "
            "0 on the onset vectors means something",
}

# ── ⛔ THE DROPOUT GATE ──────────────────────────────────────────────────────
# The SoundFont path collapsed on this material (see material.mjs). Every part
# is checked bar by bar and the build is REFUSED if any of them is uneven,
# because a dropout renders as a perfectly valid, perfectly quiet wav.
def per_bar(path, bars, bar_s=None):
    _, x = read_wav(path)
    bs = bar_s or R["barSecondsHouse"]
    out = []
    for b in range(bars):
        seg = x[int(b * bs * SR):int((b + 1) * bs * SR)]
        if len(seg) < SR // 10:
            break
        out.append(round(float(20 * np.log10(np.sqrt((seg ** 2).mean()) + 1e-12)), 2))
    return out

M["evenness"] = {}
for name, path, bars in [("piano124", f"{A}/piano124.wav", 8),
                         ("probe-Prelude", f"{A}/probe-Prelude.wav", 4),
                         ("probe-Kick", f"{A}/probe-Kick.wav", 4),
                         ("probe-Hats", f"{A}/probe-Hats.wav", 4),
                         ("probe-Clap", f"{A}/probe-Clap.wav", 4),
                         ("probe-Bass", f"{A}/probe-Bass.wav", 4)]:
    v = per_bar(path, bars)
    spread = round(max(v) - min(v), 2)
    M["evenness"][name] = {"perBarDb": v, "spreadDb": spread}
    print(f"  evenness {name:15s} spread {spread:5.2f} dB  " + " ".join(f"{x:6.1f}" for x in v))
    if spread > 6.0:
        sys.exit(f"REFUSING — {name} varies by {spread} dB bar to bar: an instrument "
                 f"is dropping out. Per-bar dB: {v}")

# ── loudness, re-measured ───────────────────────────────────────────────────
M["loudness"] = {}
for name, r in R["renders"].items():
    if name.startswith("probe-"):
        continue
    e = ebur128(r["path"])
    e["appLufs"] = r["lufs"]
    e["deltaVsApp"] = None if e["integratedLufs"] is None else round(e["integratedLufs"] - r["lufs"], 2)
    M["loudness"][name] = e
    print(f"  {name:16s} ffmpeg {e['integratedLufs']} LUFS  app {r['lufs']:.2f}  "
          f"peak {e['truePeakDbtp']}")

# ── spectra: where each part of the track lives ─────────────────────────────
_, piano = read_wav(f"{A}/ab-piano-src.wav")
_, full = read_wav(f"{A}/ab-full-src.wav")
BANDS = [(20, 60), (60, 100), (100, 250), (250, 1000), (1000, 4000), (4000, 20000)]
M["bands"] = {"edges": BANDS, "piano": [], "full": []}
for lo, hi in BANDS:
    d1, s1 = band_db(piano, lo, hi)
    d2, s2 = band_db(full, lo, hi)
    M["bands"]["piano"].append({"lo": lo, "hi": hi, "db": round(d1, 2), "share": round(s1, 5)})
    M["bands"]["full"].append({"lo": lo, "hi": hi, "db": round(d2, 2), "share": round(s2, 5)})
    print(f"  band {lo:5d}-{hi:<5d}  piano {d1:7.2f} dB  full {d2:7.2f} dB  Δ {d2-d1:+.2f}")

sub_p, _ = band_db(piano, 0, 100)
sub_f, _ = band_db(full, 0, 100)
tot_p, _ = band_db(piano, 0, 24000)
tot_f, _ = band_db(full, 0, 24000)
M["sub100"] = {"pianoFull": round(tot_p, 2), "pianoSub": round(sub_p, 2),
               "pianoDown": round(tot_p - sub_p, 2),
               "mixFull": round(tot_f, 2), "mixSub": round(sub_f, 2),
               "mixDown": round(tot_f - sub_f, 2)}
print(f"  sub-100 Hz: piano {sub_p:.2f} vs whole {tot_p:.2f} ({tot_p-sub_p:.1f} dB down); "
      f"mix {sub_f:.2f} vs {tot_f:.2f} ({tot_f-sub_f:.1f} dB down)")

# ── the tempo, measured off the audio rather than read off the field ────────
_, p72 = read_wav(f"{A}/piano72.wav")
_, p124 = read_wav(f"{A}/piano124.wav")
r72, c72 = onset_rate(p72)
r124, c124 = onset_rate(p124)
M["tempo"] = {
    "slow": {"bpm": R["bpm"]["bach"], "predictedOnsetsPerSec": R["bpm"]["bach"] / 60 * 4,
             "measuredOnsetsPerSec": round(r72, 4), "peakShare": round(c72, 4)},
    "fast": {"bpm": R["bpm"]["house"], "predictedOnsetsPerSec": R["bpm"]["house"] / 60 * 4,
             "measuredOnsetsPerSec": round(r124, 4), "peakShare": round(c124, 4)},
    "ratio": round(R["bpm"]["house"] / R["bpm"]["bach"], 4),
    "measuredRatio": round(r124 / r72, 4),
    "secondsFor8Bars": {"slow": round(R["secs8Bach"], 3), "fast": round(R["secs8House"], 3)},
}
print(f"  tempo: 72 -> {r72:.3f} onsets/s (predicted {R['bpm']['bach']/60*4:.3f}), "
      f"124 -> {r124:.3f} (predicted {R['bpm']['house']/60*4:.3f})")

# ── the A/B pairs: ONE shared static gain each, normalize:false in the spec ──
def pair(tag, a_name, b_name):
    xa, _ = read_wav(f"{A}/{a_name}.wav")
    xb, _ = read_wav(f"{A}/{b_name}.wav")
    g = 0.70 / max(np.abs(xa).max(), np.abs(xb).max())
    out = {}
    for label, x, src in (("a", xa, a_name), ("b", xb, b_name)):
        p = f"{A}/ab-{tag}-{label}.wav"
        subprocess.run(["ffmpeg", "-hide_banner", "-v", "error", "-y",
                        "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", "-",
                        "-c:a", "pcm_f32le", p], input=(x * g).astype("<f4").tobytes(),
                       check=True)
        e = ebur128(p)
        out[label] = {"path": p, "source": src, **e}
    out["sharedGain"] = round(float(g), 5)
    out["deltaLu"] = round(out["b"]["integratedLufs"] - out["a"]["integratedLufs"], 2)
    print(f"  A/B {tag}: gain x{g:.4f}  {out['a']['integratedLufs']} -> "
          f"{out['b']['integratedLufs']} LUFS  (Δ {out['deltaLu']:+.2f} LU)")
    return out

M["ab"] = {"tempo": pair("t", "piano72", "piano124"),
           "build": pair("b", "ab-piano-src", "ab-full-src")}
# ⚠ THE TRAP: assemble takes BEFORE from ab["before"] and AFTER from the stage's
# own `loop`. Assert here that no pair ever names one file twice.
for k, v in M["ab"].items():
    assert v["a"]["path"] != v["b"]["path"], k
    assert v["a"]["source"] != v["b"]["source"], k

# ── envelopes for the attention marker ──────────────────────────────────────
# ⭐ FOUR BAND ENVELOPES, NOT ONE. The whole-mix level is the WRONG instrument
# here: measured on this render, the hats' arrival moves the overall level by
# -0.03 dB and the clap's by +0.15 dB, because they are spectral events, not
# level events. Each layer is therefore measured in ITS OWN band, and the
# shaded window on screen is the bar after its entry against the bar before.
def band_env(x, lo, hi, fps=50):
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1 / SR)
    X[(f < lo) | (f >= hi)] = 0
    y = np.fft.irfft(X, n)
    hop = SR // fps
    return np.array([np.sqrt((y[i * hop:(i + 1) * hop] ** 2).mean() + 1e-20)
                     for i in range(n // hop)])

_, fullmix = read_wav(f"{A}/full.wav")
bar_s = R["barSecondsHouse"]
entries = {k: (v - 1) * bar_s for k, v in R["entry"].items()}
LAYER_BAND = {"kick": (20, 110), "bass": (120, 400), "clap": (900, 9000),
              "hats": (6000, 16000)}
envs = {"mix": rms_env(fullmix, fps=50)}
for k, (lo, hi) in LAYER_BAND.items():
    envs[k] = band_env(fullmix, lo, hi)

steps = {}
for k, t in entries.items():
    e = envs[k]
    i0, i1, i2 = int((t - bar_s) * 50), int(t * 50), int((t + bar_s) * 50)
    a = float(np.sqrt((e[max(i0, 0):i1] ** 2).mean()))
    b = float(np.sqrt((e[i1:i2] ** 2).mean()))
    pa = float(e[max(i0, 0):i1].max()); pb = float(e[i1:i2].max())
    # ⭐ AND AT THE LAYER'S OWN HIT POSITIONS. A clap is two events a bar; its
    # contribution to a bar AVERAGE is nothing (+0.04 dB measured), which is a
    # fact about averaging, not about the clap. Each layer is therefore also
    # measured in the 150 ms after each of ITS OWN onsets, before vs after.
    beat_s = bar_s / 4
    HITS = {"kick": [0, 1, 2, 3], "hats": [0.5, 1.5, 2.5, 3.5],
            "clap": [1, 3], "bass": [0.5, 1.5, 2.5, 3.5]}
    def hits_rms(t0):
        acc = []
        for h in HITS[k]:
            j = int((t0 + h * beat_s) * 50)
            acc.append(e[j:j + 8] ** 2)
        return float(np.sqrt(np.concatenate(acc).mean()))
    ha, hb = hits_rms(t - bar_s), hits_rms(t)
    steps[k] = {"band": LAYER_BAND[k], "beforeDb": round(20 * np.log10(a), 2),
                "afterDb": round(20 * np.log10(b), 2),
                "stepDb": round(20 * np.log10(b / a), 2),
                "peakBeforeDb": round(20 * np.log10(pa), 2),
                "peakAfterDb": round(20 * np.log10(pb), 2),
                "peakStepDb": round(20 * np.log10(pb / pa), 2),
                "onHitsBeforeDb": round(20 * np.log10(ha), 2),
                "onHitsAfterDb": round(20 * np.log10(hb), 2),
                "onHitsStepDb": round(20 * np.log10(hb / ha), 2),
                "entrySeconds": round(t, 3), "entryBar": R["entry"][k]}
    print(f"  entry {k:5s} bar {R['entry'][k]:2d} at {t:6.3f}s, {LAYER_BAND[k][0]}-"
          f"{LAYER_BAND[k][1]} Hz: {steps[k]['beforeDb']:.2f} -> "
          f"{steps[k]['afterDb']:.2f} dB  (rms step {steps[k]['stepDb']:+.2f} dB, on-hits step {steps[k]['onHitsStepDb']:+.2f} dB)")

mixsteps = {}
for k, t in entries.items():
    e = envs["mix"]
    i0, i1, i2 = int((t - bar_s) * 50), int(t * 50), int((t + bar_s) * 50)
    a = float(np.sqrt((e[max(i0, 0):i1] ** 2).mean()))
    b = float(np.sqrt((e[i1:i2] ** 2).mean()))
    mixsteps[k] = round(20 * np.log10(b / a), 2)
print("  whole-mix steps (the WRONG instrument, kept as the contrast): "
      + ", ".join(f"{k} {v:+.2f} dB" for k, v in mixsteps.items()))

M["marker"] = {"fps": 50, "frames": int(len(envs["mix"])),
               "seconds": round(len(envs["mix"]) / 50, 3),
               "barSeconds": round(bar_s, 4),
               "entrySeconds": {k: round(v, 3) for k, v in entries.items()},
               "bands": LAYER_BAND, "entrySteps": steps, "wholeMixSteps": mixsteps,
               "order": ["kick", "hats", "clap", "bass"]}
np.savez_compressed(f"{HERE}/envelopes.npz", **{k: v.astype("float32") for k, v in envs.items()})
print(f"  marker: {len(envs['mix'])} frames at 50 fps = {len(envs['mix'])/50:.2f} s")

json.dump(M, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1)
print(f"  wrote {HERE}/MEASUREMENTS.json")
