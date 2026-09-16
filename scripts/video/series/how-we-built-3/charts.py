#!/usr/bin/env python3
"""The film's two measured charts. MEASURED, never drawn: both are computed
from the same numbers MEASUREMENTS.json carries, so a chart cannot disagree
with the narration that reads it.

⚠ THE CORNER METER lives in the bottom-right eighth of the frame. Everything
here is anchored left of x = 0.62 or above y = 0.25 in figure coordinates.
"""
import json, os, sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import wav                                                     # noqa: E402

M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
CA = "/Users/dsemenov/Views/daw-pro/scripts/video/comp/audio"
BG, FG, DIM = "#0b0d12", "#eef2ff", "#9aa2b1"
BLUE, ORANGE, RED = "#82cdff", "#ffb066", "#ff6b7c"
plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG,
                     "text.color": FG, "axes.labelcolor": FG,
                     "xtick.color": DIM, "ytick.color": DIM,
                     "axes.edgecolor": "#2a3140", "font.size": 15})

# ── 1. the difference that was real and inaudible ────────────────────────────
sr, f, _ = wav.read(f"{CA}/d3-release-fast.wav")
_, s, _ = wav.read(f"{CA}/d3-release-slow.wav")
n = min(len(f), len(s))
ef, w = wav.env_db(f[:n], sr, 20.0)
es, _ = wav.env_db(s[:n], sr, 20.0)
t = np.arange(len(ef)) * w / sr
sig = (ef - es > 3.0) & (ef > -70.0)

fig, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
fig.subplots_adjust(left=0.085, right=0.975, top=0.815, bottom=0.115)

# The listen-windows are DERIVED from where the two settings actually differ --
# never chosen by eye. Draw them first, under the traces.
d = np.diff(sig.astype(int))
starts = list(np.where(d == 1)[0] + 1) + ([0] if sig[0] else [])
ends = list(np.where(d == -1)[0] + 1) + ([len(sig)] if sig[-1] else [])
for a, b in zip(sorted(starts), sorted(ends)):
    ax.axvspan(t[a], t[min(b, len(t) - 1)], color="#ffffff", alpha=0.085, lw=0)

ax.plot(t, np.maximum(ef, -78), color=BLUE, lw=2.0, label="release 30 ms  (fast)")
ax.plot(t, np.maximum(es, -78), color=ORANGE, lw=2.0, label="release 800 ms  (slow)")
ax.axhline(M["filmLufs"], color=RED, lw=2.0, ls="--")
ax.text(0.18, M["filmLufs"] + 2.2, "the level of the voice in this film  "
        f'({M["filmLufs"]:.0f} LUFS)', color=RED, fontsize=17)
lvl = M["pairDiffLevelFast"]
ax.annotate("", xy=(0.12, M["filmLufs"]), xytext=(0.12, lvl),
            arrowprops=dict(arrowstyle="<->", color=DIM, lw=1.6))
ax.text(0.30, (M["filmLufs"] + lvl) / 2 - 1.0,
        f'{M["pairBelowFilm"]:.0f} dB', color=DIM, fontsize=17)

ax.set_xlim(0, t[-1])
ax.set_ylim(-78, 0)
ax.set_xlabel("seconds")
ax.set_ylabel("level, dBFS  (20 ms windows)")
ax.set_yticks([0, -20, -40, -60])
ax.grid(color="#1b2130", lw=0.8)
ax.legend(loc="upper right", frameon=False, fontsize=17)
fig.text(0.085, 0.945, "THE DIFFERENCE WAS REAL. IT LIVED HERE.",
         fontsize=30, color=FG, weight="bold")
fig.text(0.085, 0.898,
         f'shaded: the {M["pairDiffSeconds"]:.2f} s in which the two settings differ by more '
         f'than 3 dB — derived from the audio, not chosen by eye.',
         fontsize=17, color=DIM)
fig.text(0.085, 0.862,
         f'mean gap {M["pairDiffDb"]:.1f} dB, widest {M["pairDiffDbMax"]:.1f} dB — '
         f'and all of it at about {M["pairDiffLevelFast"]:.0f} dBFS.',
         fontsize=17, color=DIM)
fig.text(0.085, 0.032,
         f'measured from the two wavs that shipped in the lesson · '
         f'{M["pairSilentFraction"]:.0f}% of the excerpt is digital silence in both',
         fontsize=14, color="#5d6675")
fig.savefig(f"{HERE}/shots/chart-pair.png", facecolor=BG)
plt.close(fig)
print("  chart-pair.png")

# ── 2. the five dead bars ────────────────────────────────────────────────────
SR, FPS = 48000, 30
win = int(SR / FPS * 2)
fr = np.fft.rfftfreq(win, 1 / SR)
edges = np.geomspace(M["meterFLo"], M["meterFHi"], M["meterBarsOld"] + 1)
masks = [(fr >= edges[k]) & (fr < edges[k + 1]) for k in range(M["meterBarsOld"])]
centres = np.sqrt(edges[:-1] * edges[1:])
dead = [k for k, m in enumerate(masks) if not m.any()]

fig, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
fig.subplots_adjust(left=0.085, right=0.975, top=0.815, bottom=0.115)
HI = 260.0
for k in range(M["meterBarsOld"]):
    if edges[k] > HI:
        break
    col = RED if k in dead else "#2f3a4d"
    ax.add_patch(Rectangle((edges[k], 0), edges[k + 1] - edges[k], 1.0,
                           facecolor=col, edgecolor=BG, lw=1.4))
for b in fr[(fr > 0) & (fr <= HI)]:
    ax.axvline(b, color=BLUE, lw=1.2, alpha=0.85)
ax.plot([], [], color=BLUE, lw=1.6, label=f'the analysis grid — one line every {M["meterBinHz"]:.0f} Hz')
ax.add_patch(Rectangle((0, 0), 0, 0, facecolor=RED, label="a band with NO line inside it: it can only draw zero"))
for k in dead:
    ax.text(centres[k], 1.10, f"{centres[k]:.0f}", color=RED, fontsize=16,
            ha="center", rotation=0)
ax.set_xlim(M["meterFLo"], HI)
ax.set_ylim(0, 1.45)
ax.set_xscale("log")
ax.set_xticks([30, 40, 50, 60, 80, 100, 150, 200, 250])
ax.set_xticklabels(["30", "40", "50", "60", "80", "100", "150", "200", "250"])
ax.set_yticks([])
ax.set_xlabel("frequency, hertz")
ax.grid(False)
ax.legend(loc="upper right", frameon=False, fontsize=17)
fig.text(0.085, 0.945, "FIVE BARS THAT COULD NEVER MOVE",
         fontsize=30, color=FG, weight="bold")
fig.text(0.085, 0.898,
         f'{M["meterBarsOld"]} log-spaced bands against a {M["meterBinHz"]:.0f} Hz analysis grid.',
         fontsize=17, color=DIM)
fig.text(0.085, 0.862,
         "Five of them are narrower than the gap between two lines and contain none: "
         + ", ".join(f'{h:.0f}' for h in M["meterDeadOldHz"]) + " Hz.",
         fontsize=17, color=DIM)
fig.text(0.085, 0.032,
         "computed from scripts/video/meter.py's own constants and window size",
         fontsize=14, color="#5d6675")
fig.savefig(f"{HERE}/shots/chart-bands.png", facecolor=BG)
plt.close(fig)
print("  chart-bands.png")
