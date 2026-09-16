#!/usr/bin/env python3
"""The attention marker: say WHEN to listen and WHERE.

Two burst directories, one per half of the flam A/B, each a real-time playhead
over the MEASURED waveforms of both files, with the listen-windows shaded.

⚠ THE SHADED WINDOWS ARE DERIVED, never chosen by eye: they are the spans where
the two renders differ by more than 20 dB below the louder one's peak. Done that
way, the unshaded gaps land exactly on the silence between hits, where there is
nothing to hear in either file.

⚠ run_time MUST equal the audio laid under it. The burst is built at exactly
len(wav)/SR seconds and beds.py asserts the bed matches.
"""
import json, os, shutil, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
FPS = 30
BG, FG, DIM, HOT, OK = "#080b10", "#e8eef6", "#7b8ba0", "#ff6b5e", "#4fd1c5"
plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG,
                     "savefig.facecolor": BG, "text.color": FG,
                     "axes.labelcolor": FG, "xtick.color": DIM, "ytick.color": DIM,
                     "axes.edgecolor": "#22303f", "font.size": 15})

tog, SR = sf.read(f"{HERE}/audio/flam-together-play.wav", always_2d=True)
apt, _ = sf.read(f"{HERE}/audio/flam-apart-play.wav", always_2d=True)
tog, apt = tog.mean(1), apt.mean(1)
n = min(len(tog), len(apt))
tog, apt = tog[:n], apt[:n]
SECS = n / SR
t = np.arange(n) / SR

# envelopes, 5 ms windows
# 20 ms envelope windows: fine enough to separate two hits 85 ms apart, coarse
# enough that each derived listen-window is visible as a band rather than a hair.
ENV_MS = 20
w = int(ENV_MS / 1000 * SR)
def env(x):
    m = len(x) // w * w
    return np.abs(x[:m].reshape(-1, w)).max(1)
et, ea = env(tog), env(apt)
te = np.arange(len(et)) * w / SR

# DERIVED listen-windows: where the two differ meaningfully
diff = np.abs(et - ea)
thr = diff.max() * 10 ** (-20 / 20)
on = diff > thr
spans, i = [], 0
while i < len(on):
    if on[i]:
        j = i
        while j < len(on) and on[j]:
            j += 1
        # ⚠ >=, not >. The first draft used `> 0.02` and every run measured EXACTLY
        # 0.02 s, so the filter rejected all six and the script refused — a strict
        # inequality against a value the data lands on exactly.
        if (j - i) * w / SR >= ENV_MS / 1000 * 1.5:
            spans.append((i * w / SR, j * w / SR))
        i = j
    else:
        i += 1
print(f"  {len(spans)} derived listen-windows, threshold {20*np.log10(10**(-20/20)):.0f} dB "
      f"under the largest difference")
if not len(spans):
    sys.exit("SWEEP REFUSES — no window where the two files differ; there is nothing to point at")

M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
B = json.load(open(f"{HERE}/bursts.json")) if os.path.exists(f"{HERE}/bursts.json") else {}

for name, active in (("flam-together", 0), ("flam-apart", 1)):
    d = f"{HERE}/bursts/{name}"
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    frames = int(round(SECS * FPS))
    fig, axes = plt.subplots(2, 1, figsize=(16, 9), dpi=120, sharex=True)
    for k, (ax, e, lab, col) in enumerate(
            ((axes[0], et, "ONE HIT", OK), (axes[1], ea, "THE SAME HIT, TWICE", HOT))):
        live = (k == active)
        ax.fill_between(te, 0, e, color=col if live else "#2a3442",
                        alpha=1.0 if live else 0.55, lw=0)
        for s, en in spans:
            ax.axvspan(s, en, color="#ffc67a", alpha=0.10 if live else 0.05, lw=0)
        ax.set_ylim(0, max(et.max(), ea.max()) * 1.15)
        ax.set_yticks([])
        ax.text(0.008, 0.80, lab + ("     ◀ PLAYING NOW" if live else ""),
                transform=ax.transAxes, color=col if live else DIM,
                fontsize=21, fontweight="bold")
        for s_ in ("top", "right", "left"):
            ax.spines[s_].set_visible(False)
    axes[1].set_xlabel("seconds")
    axes[0].set_xlim(0, SECS)
    fig.suptitle(f"{M['flamMeasuredGapMs']:.0f} MILLISECONDS APART — "
                 f"WHAT {M['pdcGapSamples']} SAMPLES SOUNDS LIKE",
                 fontsize=25, color=FG, fontweight="bold", y=0.975)
    fig.text(0.5, 0.028, "shaded = where the two renders actually differ, derived from "
                         "the measured envelopes (not chosen by eye)",
             ha="center", color=DIM, fontsize=14)
    fig.tight_layout(rect=(0, 0.05, 1, 0.94))
    lines = [ax.axvline(0, color=FG, lw=2.4) for ax in axes]
    for f in range(frames):
        x = f / FPS
        for ln in lines:
            ln.set_xdata([x, x])
        fig.savefig(f"{d}/f{f:04d}.png")
    plt.close(fig)
    json.dump({"fps": FPS, "frames": frames, "seconds": round(frames / FPS, 3)},
              open(f"{d}/meta.json", "w"), indent=1)
    B[name] = round(frames / FPS, 3)
    print(f"  {name:16s} {frames} frames  {frames/FPS:.3f}s  (audio {SECS:.3f}s)")

json.dump(B, open(f"{HERE}/bursts.json", "w"), indent=1)
