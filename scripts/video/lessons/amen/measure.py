#!/usr/bin/env python3
"""Every number the Amen film says, measured off the renders shoot.mjs made.

Nothing here is copied from the shipped film's description. The shipped figures
(53 notes; humanize max 7.81 ms, mean 3.54 ms) were treated as prior art and
re-derived from scratch -- the note count came out at 53 independently from the
fact sheet's structural description, and the humanize figures did NOT reproduce
(different seed, and the count is 106 across two passes of the loop).

Writes MEASUREMENTS.json, plus the A/B and chart wavs the film plays.
"""
import json, os, subprocess, sys
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
A, MED = f"{HERE}/audio", f"{HERE}/media"
MAT = json.load(open(f"{MED}/material.json"))
BPM, BEAT_MS, S16_MS = MAT["bpm"], MAT["beatMs"], MAT["sixteenthMs"]
M = {"material": MAT["counts"], "bpm": BPM, "beat_ms": BEAT_MS,
     "sixteenth_ms": S16_MS, "sixteenth_ms_at_170": 15000 / 170,
     "velocities": MAT["velocities"]}


def rd(name):
    x, sr = sf.read(f"{A}/{name}.wav")
    return (x.mean(1) if x.ndim > 1 else x), sr


def db(v):
    return 20 * np.log10(max(float(v), 1e-12))


def ebur128(path):
    """Integrated LUFS + true peak. -hide_banner, because -v error SUPPRESSES
    the ebur128 summary and would hand back a clean, empty, wrong answer."""
    p = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af",
                        "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    out, res = p.stderr, {}
    tail = out[out.rfind("Summary"):]
    for key, tag in (("integratedLufs", "I:"), ("truePeakDbtp", "Peak:")):
        for line in tail.splitlines():
            s = line.strip()
            if s.startswith(tag):
                res[key] = float(s.split()[1])
                break
    if len(res) != 2:
        sys.exit(f"ebur128 parse failed for {path} -- refusing to invent a number")
    return res


# ─────────────────────────────────────────── 1. the velocity law
# PREDICTED FIRST: a General MIDI sound bank scales note amplitude with
# (velocity/127)^2, so level in dB is 40*log10(v/127) relative to velocity 127.
VELS = json.load(open(f"{MED}/_vels.json"))["velocities"]
vel = {}
for nm in ("snare", "kick", "ride", "hat"):
    x, sr = rd(f"vel-{nm}")
    pk = [db(np.abs(x[int(i * .5 * sr):int((i * .5 + .45) * sr)]).max())
          for i in range(len(VELS))]
    ref = pk[-1]                                   # anchor on velocity 127
    pred = [ref + 40 * np.log10(v / 127) for v in VELS]
    vel[nm] = {"velocities": VELS, "measured_db": pk, "predicted_db": pred,
               "err_db": [m - p for m, p in zip(pk, pred)]}
M["velocity_law"] = vel
M["velocity_law_worst_err_db"] = max(
    (abs(e), nm, v) for nm in vel for e, v in zip(vel[nm]["err_db"], VELS))[0]
# ⚠ AND THE LAW IS NOT UNIVERSAL. Measured error against 40*log10(v/127):
#   ride  +/-0.03 dB at all 13 velocities
#   kick  +/-0.09 dB except a -0.7 dB dip at v60-90
#   snare +/-0.02 dB at 11 of 13; at v60 and v70 it is +4.67 dB off, because
#         the bank switches to a DIFFERENT RECORDING of the drum there
#   hat   -7.89 dB at v10, closing steadily to 0 at v127 -- a different curve
# The film's claim is about the SNARE, which is where its ghost notes live, so
# that is the figure it states, with the layer switch named rather than hidden.
M["velocity_law_snare_worst_err_db"] = max(
    abs(e) for e, v in zip(vel["snare"]["err_db"], VELS) if not (55 <= v <= 70))
M["velocity_law_snare_layer_err_db"] = max(
    abs(e) for e, v in zip(vel["snare"]["err_db"], VELS) if 55 <= v <= 70)
M["velocity_law_snare_layer_band"] = [55, 70]
M["velocity_law_hat_worst_err_db"] = max(abs(e) for e in vel["hat"]["err_db"])
M["velocity_law_ride_worst_err_db"] = max(abs(e) for e in vel["ride"]["err_db"])
# the same law, excluding the snare's velocity-LAYER region (see NOTES.md): the
# bank switches to a different recording of the drum between v60 and v90 and the
# level jumps off the curve there. That is a real property of a sampled kit, not
# a failure of the law, and the film says so.
M["velocity_law_worst_err_db_excl_layer"] = max(
    abs(e) for nm in vel for e, v in zip(vel[nm]["err_db"], VELS)
    if not (nm == "snare" and 55 <= v <= 70))
gs = vel["snare"]["measured_db"][VELS.index(MAT["velocities"]["ghost"])]
ac = vel["snare"]["measured_db"][VELS.index(MAT["velocities"]["accent"])]
M["ghost_vs_accent"] = {
    "ghost_velocity": MAT["velocities"]["ghost"], "accent_velocity": MAT["velocities"]["accent"],
    "ghost_db": gs, "accent_db": ac, "measured_gap_db": gs - ac,
    "predicted_gap_db": 40 * np.log10(MAT["velocities"]["ghost"] / MAT["velocities"]["accent"])}

# ─────────────────────────────────────────── 2. onsets, measured off the stems
def onsets(sig, sr, expect_s, win_ms=40.0):
    """Where each hit ACTUALLY starts in the audio.

    ⚠ THE FIRST VERSION OF THIS WAS WRONG AND ITS ERROR WAS INVISIBLE ON THREE
    OF FOUR STEMS. It took the first sample in the window crossing 20 % of the
    window's peak -- which, when the PREVIOUS hit's decay is still ringing above
    that fraction, fires at sample zero and reports an onset a whole half-window
    early. Kick and snare (sparse) agreed with the project to under 3 ms; the
    ride (continuous eighths, always ringing) came back with a MEDIAN onset
    -44 ms off and six hits wrong by up to 47 ms. Same code, same return value,
    same absence of any error.

    This version looks for an ATTACK instead: the largest RISE in a short-time
    energy envelope inside the window. A decaying tail has no rise, so it cannot
    be mistaken for a hit."""
    hopn = max(1, int(0.0005 * sr))                  # 0.5 ms
    winn = max(2, int(0.003 * sr))                   # 3 ms
    lag = max(1, int(0.002 / 0.0005))                # compare against 2 ms ago
    out = []
    for t in expect_s:
        a = max(0, int((t - win_ms * 1e-3) * sr))
        b = min(len(sig), int((t + win_ms * 1e-3) * sr))
        if b - a < winn * 2:
            out.append(None); continue
        seg = sig[a:b]
        nf = (len(seg) - winn) // hopn
        if nf <= lag + 1:
            out.append(None); continue
        e = np.array([np.sqrt((seg[i * hopn:i * hopn + winn] ** 2).mean()) for i in range(nf)])
        e = 20 * np.log10(np.maximum(e, 1e-9))
        rise = e[lag:] - e[:-lag]
        if float(np.max(rise)) < 3.0:                # no attack in this window
            out.append(None); continue
        k = int(np.argmax(rise))
        out.append((a + k * hopn) / sr)
    return out


H = MAT["humanize"]
onset = {}
for nm in ("kick", "snare", "cym"):
    before = np.array(H["before"][nm]) * BEAT_MS / 1000.0
    after = np.array(H["after"][nm]) * BEAT_MS / 1000.0
    xq, sr = rd(f"stem-quant-{nm}")
    xh, _ = rd(f"stem-human-{nm}")
    oq = onsets(xq, sr, before)
    oh = onsets(xh, sr, after)
    lat = [(o - t) * 1000 for o, t in zip(oq, before) if o is not None]
    # the render's own fixed attack latency, removed as a common-mode term: what
    # the film claims is the SHIFT, not the absolute onset.
    base = float(np.median(lat))
    meas = [((h - b) * 1000) if (h is not None and b is not None) else None
            for h, b in zip(oh, oq)]
    proj = H["shiftsMs"][nm]
    onset[nm] = {"project_shift_ms": proj, "audio_shift_ms": meas,
                 "attack_latency_ms": base,
                 "agree_max_ms": max(abs(m - p) for m, p in zip(meas, proj) if m is not None),
                 "measured_of": sum(1 for m in meas if m is not None), "notes": len(proj)}
M["onsets"] = onset
allp = [v for nm in onset for v in onset[nm]["project_shift_ms"]]
alla = [v for nm in onset for v in onset[nm]["audio_shift_ms"] if v is not None]
M["onset_agreement_by_stem_ms"] = {n: onset[n]["agree_max_ms"] for n in onset}
M["humanize"] = {
    "seed": H["seed"], "timing_beats": H["timingBeats"],
    "max_ms_asked": H["maxMsAsked"], "notes": len(allp),
    "project_max_abs_ms": max(abs(v) for v in allp),
    "project_mean_abs_ms": float(np.mean([abs(v) for v in allp])),
    "audio_max_abs_ms": max(abs(v) for v in alla),
    "audio_mean_abs_ms": float(np.mean([abs(v) for v in alla])),
    "agree_max_ms": max(onset[n]["agree_max_ms"] for n in onset),
    "agree_max_kick_snare_ms": max(onset[n]["agree_max_ms"] for n in ("kick", "snare")),
    "max_as_pct_of_sixteenth": 100 * max(abs(v) for v in allp) / S16_MS,
    "mean_as_pct_of_sixteenth": 100 * float(np.mean([abs(v) for v in allp])) / S16_MS,
}
M["drag"] = {"asked_ms": MAT["dragMs"]}

# ─────────────────────────────────────────── 3. loudness of every pair
M["loudness"] = {k: ebur128(f"{A}/{k}.wav") for k in
                 ("s3-skeleton", "s4-ghosts", "s5-bar3straight", "s6-full4",
                  "q-quant", "q-human", "q-drag", "j-170")}
L = M["loudness"]
M["pairs"] = {
    "ghosts_vs_skeleton_lu": L["s4-ghosts"]["integratedLufs"] - L["s3-skeleton"]["integratedLufs"],
    "bar3_vs_straight_lu": L["s6-full4"]["integratedLufs"] - L["s5-bar3straight"]["integratedLufs"],
    "human_vs_quant_lu": L["q-human"]["integratedLufs"] - L["q-quant"]["integratedLufs"],
    "drag_vs_quant_lu": L["q-drag"]["integratedLufs"] - L["q-quant"]["integratedLufs"],
}

# ─────────────────────────────────────────── 4. can a laptop hear it?
def band_rms_db(path, hp=None, lp=None):
    af = []
    if hp: af.append(f"highpass=f={hp}")
    if lp: af.append(f"lowpass=f={lp}")
    af.append("astats=metadata=1")
    p = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af", ",".join(af),
                        "-f", "null", "-"], capture_output=True, text=True)
    # ⚠ ffmpeg prefixes every astats line with "[Parsed_astats_0 @ 0x...] ", so
    # a startswith("RMS level dB") test matches NOTHING and hands back a clean
    # empty list. Search the line instead, and take the LAST value, which is
    # astats' Overall section rather than a single channel.
    vals = [float(l.split("RMS level dB:")[1]) for l in p.stderr.splitlines()
            if "RMS level dB:" in l]
    if not vals:
        sys.exit(f"astats gave no RMS for {path} -- refusing to invent a number")
    return vals[-1]


aud = {}
for k in ("s3-skeleton", "s4-ghosts", "q-quant", "q-human", "q-drag"):
    aud[k] = {"full": band_rms_db(f"{A}/{k}.wav"),
              "hp200": band_rms_db(f"{A}/{k}.wav", hp=200)}
M["audibility"] = {
    "bands": aud,
    "ghosts_full_db": aud["s4-ghosts"]["full"] - aud["s3-skeleton"]["full"],
    "ghosts_hp200_db": aud["s4-ghosts"]["hp200"] - aud["s3-skeleton"]["hp200"],
    "human_full_db": aud["q-human"]["full"] - aud["q-quant"]["full"],
    "human_hp200_db": aud["q-human"]["hp200"] - aud["q-quant"]["hp200"],
    "drag_full_db": aud["q-drag"]["full"] - aud["q-quant"]["full"],
}

# ⭐ THE HONEST ONE. A level meter cannot see a timing shift at all, so the
# question "is the humanized version audible" cannot be answered by any of the
# figures above -- they are all ~0 by construction. What IS measurable is how
# far the WAVEFORMS differ: the sample-by-sample difference of the two renders,
# as a level, against the renders' own level.
xq, sr = rd("q-quant"); xh, _ = rd("q-human"); xd, _ = rd("q-drag")
nlen = min(len(xq), len(xh), len(xd))
M["waveform_difference"] = {
    "human_vs_quant_diff_db": db(np.sqrt(((xh[:nlen] - xq[:nlen]) ** 2).mean())),
    "drag_vs_quant_diff_db": db(np.sqrt(((xd[:nlen] - xq[:nlen]) ** 2).mean())),
    "quant_level_db": db(np.sqrt((xq[:nlen] ** 2).mean())),
}
wd = M["waveform_difference"]
wd["human_rel_db"] = wd["human_vs_quant_diff_db"] - wd["quant_level_db"]
wd["drag_rel_db"] = wd["drag_vs_quant_diff_db"] - wd["quant_level_db"]

xsq, sr = rd("stem-quant-snare"); xsd, _ = rd("stem-drag-snare")
nn2 = min(len(xsq), len(xsd))
M["drag"]["snare_stem_diff_rel_db"] = (
    db(np.sqrt(((xsd[:nn2] - xsq[:nn2]) ** 2).mean())) - db(np.sqrt((xsq[:nn2] ** 2).mean())))
# and measured BACK OUT of the audio, by cross-correlating the two snare stems
c = np.correlate(xsd[:nn2] - xsd[:nn2].mean(), xsq[:nn2] - xsq[:nn2].mean(), "full")
M["drag"]["measured_ms"] = float((int(np.argmax(c)) - (nn2 - 1)) / sr * 1000)

# ⭐ ONE QUANTITY, COMPUTED THE SAME WAY FOR EVERY PAIR, so a chart can put them
# side by side without mixing units. "Difference level" = the RMS of (A - B)
# expressed relative to A's own RMS. It answers "how much of the signal actually
# changed", which is the question, and it is defined identically whether the
# change was a level change, a timing change or an extra note. The first version
# of the audibility chart put a LUFS delta and a waveform delta on one dB axis;
# they are not the same quantity and the chart was quietly wrong.
def diff_rel_db(a, b):
    xa, sr = rd(a); xb, _ = rd(b)
    k = min(len(xa), len(xb))
    return (db(np.sqrt(((xb[:k] - xa[:k]) ** 2).mean()))
            - db(np.sqrt((xa[:k] ** 2).mean())))


M["diff_rel_db"] = {
    "ghosts":   diff_rel_db("s3-skeleton", "s4-ghosts"),
    "bar3":     diff_rel_db("s5-bar3straight", "s6-full4"),
    "humanize": diff_rel_db("q-quant", "q-human"),
    "drag":     diff_rel_db("stem-quant-snare", "stem-drag-snare"),
}
M["lufs_delta"] = {
    "ghosts":   M["pairs"]["ghosts_vs_skeleton_lu"],
    "bar3":     M["pairs"]["bar3_vs_straight_lu"],
    "humanize": M["pairs"]["human_vs_quant_lu"],
    "drag":     M["pairs"]["drag_vs_quant_lu"],
}

# ─────────────────────────────────────────── 5. the A/B wavs, one shared gain
# ⚠ normalize:false in the spec, so the levels here ARE what the viewer hears.
# ONE static gain per pair, set from the LOUDER half so nothing clips.
def make_ab(pairs, target_peak_db=-1.5):
    for tag, names in pairs.items():
        sigs = [sf.read(f"{A}/{n}.wav") for n in names]
        pk = max(np.abs(s[0]).max() for s in sigs)
        g = 10 ** (target_peak_db / 20) / max(pk, 1e-9)
        for n, (x, sr) in zip(names, sigs):
            # ⚠⚠ subtype="FLOAT" IS LOAD-BEARING. soundfile defaults a .wav to
            # PCM_16, and bursts.py reads these back with scipy, which returns
            # int16 for a PCM_16 file. Cast to float without dividing and the
            # bed is written at +/-27570 instead of +/-0.84 -- about +89 dB.
            # MEASURED: two manim beds shipped at +3.6 LUFS and the film came
            # out 6.7 LU under target, with the loudness gate, the A/B gate and
            # the content gate all reporting ok. Everything else here is float.
            sf.write(f"{A}/ab-{n}.wav", x * g, sr, subtype="FLOAT")
        M.setdefault("ab_gain_db", {})[tag] = db(g)


make_ab({"ghosts": ["s3-skeleton", "s4-ghosts"],
         "bar3": ["s5-bar3straight", "s6-full4"],
         "human": ["q-quant", "q-human", "q-drag"],
         "tempo": ["q-quant", "j-170"]})
M["ab_source_lufs"] = {n: ebur128(f"{A}/ab-{n}.wav")["integratedLufs"]
                       for n in ("s3-skeleton", "s4-ghosts", "s5-bar3straight",
                                 "s6-full4", "q-quant", "q-human", "q-drag", "j-170")}

# ─────────────────────────────────────────── 6. the attention marker's data
# Short-time snare-band level of the ghosts render vs the skeleton, so the
# chart's shaded windows are DERIVED from where the two actually differ rather
# than chosen by eye. Ghost notes are the only difference between the two files,
# so every window that lights up is a ghost note, by construction.
xg, sr = rd("s4-ghosts"); xs, _ = rd("s3-skeleton")
nn = min(len(xg), len(xs))
hop = int(0.005 * sr); win = int(0.020 * sr)
frames = (nn - win) // hop
t = np.arange(frames) * hop / sr
env = lambda x: np.array([db(np.sqrt((x[i * hop:i * hop + win] ** 2).mean())) for i in range(frames)])
eg, es = env(xg), env(xs)
diff = eg - es
THRESH = 6.0
mask = diff > THRESH
wins, i = [], 0
while i < frames:
    if mask[i]:
        j = i
        while j < frames and mask[j]:
            j += 1
        wins.append([float(t[i]), float(t[j - 1])])
        i = j
    else:
        i += 1
merged = []
for w in wins:
    if merged and w[0] - merged[-1][1] < 0.06:
        merged[-1][1] = w[1]
    else:
        merged.append(w)
merged = [w for w in merged if w[1] - w[0] >= 0.02]
M["_chart"] = {
    "t": t.tolist(), "ghosts_db": eg.tolist(), "skeleton_db": es.tolist(),
    "listen_windows": merged, "threshold_db": THRESH,
    "max_diff_db": float(diff.max()), "seconds": float(t[-1]),
}
M["listen_window_count"] = len(merged)
M["listen_max_diff_db"] = float(diff.max())

# the chart's audio bed: skeleton then ghosts, back to back, at the pair's gain
xs2, sr = sf.read(f"{A}/ab-s3-skeleton.wav")
xg2, _ = sf.read(f"{A}/ab-s4-ghosts.wav")
sf.write(f"{A}/chartaudio.wav", np.concatenate([xs2, xg2]), sr)
M["_chart"]["audio_seconds"] = (len(xs2) + len(xg2)) / sr
M["_chart"]["half_seconds"] = len(xs2) / sr

json.dump(M, open(f"{HERE}/MEASUREMENTS.json", "w"), indent=1)
print(f"MEASUREMENTS.json written")
print(f"  notes {M['material']['total']}   sixteenth {S16_MS:.4f} ms")
print(f"  velocity law worst error {M['velocity_law_worst_err_db']:.3f} dB "
      f"({M['velocity_law_worst_err_db_excl_layer']:.3f} dB excluding the snare layer switch)")
print(f"  ghost vs accent  predicted {M['ghost_vs_accent']['predicted_gap_db']:.2f} dB  "
      f"measured {M['ghost_vs_accent']['measured_gap_db']:.2f} dB")
print(f"  humanize  max {M['humanize']['project_max_abs_ms']:.2f} ms  "
      f"mean {M['humanize']['project_mean_abs_ms']:.2f} ms  "
      f"({M['humanize']['max_as_pct_of_sixteenth']:.1f} % / "
      f"{M['humanize']['mean_as_pct_of_sixteenth']:.1f} % of a sixteenth)")
print(f"  project vs audio agree to {M['humanize']['agree_max_ms']:.3f} ms")
print(f"  human vs quant: {M['pairs']['human_vs_quant_lu']:+.2f} LU, "
      f"waveform difference {wd['human_rel_db']:+.2f} dB rel; "
      f"drag {wd['drag_rel_db']:+.2f} dB rel")
print(f"  ghosts vs skeleton: {M['pairs']['ghosts_vs_skeleton_lu']:+.2f} LU, "
      f"hp200 {M['audibility']['ghosts_hp200_db']:+.2f} dB")
print(f"  listen windows {len(merged)}  max diff {diff.max():.2f} dB")
