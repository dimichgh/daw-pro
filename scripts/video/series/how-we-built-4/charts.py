#!/usr/bin/env python3
"""Two MEASURED charts. Neither is drawn by hand.

  chart-plant.png  — the four alignment errors that appeared when one number in
                     shipping source was replaced by zero, read out of
                     logs/plant-01-red.log, against the zeroes from the green run.
  chart-ladder.png — the two sound banks' velocity ladders, measured live on
                     staging 17695 through instrument.probeLiveness.
"""
import json, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
BG, FG, DIM, HOT, OK = "#080b10", "#e8eef6", "#7b8ba0", "#ff6b5e", "#4fd1c5"
plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG,
                     "savefig.facecolor": BG, "text.color": FG,
                     "axes.labelcolor": FG, "xtick.color": DIM, "ytick.color": DIM,
                     "axes.edgecolor": "#22303f", "font.size": 15})

# ── 1. the plant ─────────────────────────────────────────────────────────────
units = ["AUPeakLimiter", "AUDynamicsProcessor", "AUMultibandCompressor", "AUNewTimePitch"]
err = M["plantErrors"]
fig, ax = plt.subplots(figsize=(16, 9), dpi=120)
x = np.arange(len(units))
ax.bar(x - 0.19, [0.4] * 4, 0.36, color=OK, label="as it ships  (error = 0 samples)")
b = ax.bar(x + 0.19, err, 0.36, color=HOT, label="with one number set to zero")
for xi, e in zip(x, err):
    ax.text(xi + 0.19, e * 1.35, f"{e}\n{e/48000*1000:.1f} ms", ha="center",
            va="bottom", color=HOT, fontsize=17, fontweight="bold")
    ax.text(xi - 0.19, 0.5, "0", ha="center", va="bottom", color=OK,
            fontsize=17, fontweight="bold")
ax.set_yscale("log")
ax.set_ylim(0.3, 20000)
ax.set_xticks(x)
ax.set_xticklabels([u.replace("AU", "") for u in units], fontsize=15)
ax.set_ylabel("how far out of line the plug-in's audio landed, in samples")
ax.set_title("EACH TEST FAILED BY EXACTLY ITS OWN PLUG-IN'S DELAY",
             fontsize=24, pad=22, color=FG, fontweight="bold")
ax.legend(loc="upper left", facecolor=BG, edgecolor="#22303f", labelcolor=FG, fontsize=15)
ax.grid(axis="y", color="#16202c", lw=1)
ax.set_axisbelow(True)
for s in ("top", "right"):
    ax.spines[s].set_visible(False)
fig.text(0.5, 0.028, "measured in this build: logs/plant-01-red.log vs logs/plant-00-green.log"
                     "   ·   48,000 samples = 1 second",
         ha="center", color=DIM, fontsize=14)
fig.tight_layout(rect=(0, 0.05, 1, 1))
fig.savefig(f"{HERE}/shots/chart-plant.png")
plt.close(fig)

# ── 2. the ladder ────────────────────────────────────────────────────────────
vel = [25, 60, 95, 127]
fig, (a1, a2) = plt.subplots(1, 2, figsize=(16, 9), dpi=120)
for ax, key, name, col in ((a1, "gm", "Apple's built-in sound bank", HOT),
                           (a2, "gu", "GeneralUser GS", OK)):
    c = M[f"live_{key}_centroids"]
    ax.plot(vel, c, "-o", color=col, lw=4, ms=14)
    for v, y in zip(vel, c):
        ax.annotate(f"{y:.0f} Hz", (v, y), textcoords="offset points",
                    xytext=(0, 16), ha="center", color=col, fontsize=15)
    ax.set_ylim(2050, 2700)
    ax.set_xlim(5, 147)
    ax.set_xticks(vel)
    ax.set_xlabel("how hard the note is played")
    ax.set_title(f"{name}\n{M[f'live_{key}_verdict'].upper()}  ·  "
                 f"{M[f'live_{key}_spread']:.2f} % change  ·  "
                 f"{M[f'live_{key}_groups']} tone"
                 f"{'s' if M[f'live_{key}_groups'] > 1 else ''}",
                 fontsize=19, color=col, pad=18)
    ax.grid(color="#16202c", lw=1)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
a1.set_ylabel("brightness of the sound (Hz)")
fig.suptitle("THE SAME SAXOPHONE NOTE, FROM TWO SOUND BANKS",
             fontsize=25, color=FG, fontweight="bold", y=0.975)
fig.text(0.5, 0.028, f"measured live on staging through instrument.probeLiveness   ·   "
                     f"both got {M['liveRmsSpreadDb']:.0f} dB louder across the same four "
                     f"velocities   ·   only one changed tone",
         ha="center", color=DIM, fontsize=14)
fig.tight_layout(rect=(0, 0.05, 1, 0.94))
fig.savefig(f"{HERE}/shots/chart-ladder.png")
plt.close(fig)
print("  charts: chart-plant.png, chart-ladder.png")
