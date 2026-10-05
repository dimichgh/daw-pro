#!/usr/bin/env python3
"""The one chart Part 2 states numbers off: the deadline, and how much of it
this project actually used. Every value is read from MEASUREMENTS.json, which
read it off the LIVE engine on the staging app.

⚠ The film burns a level-meter avatar into the BOTTOM-RIGHT corner; nothing in
matplotlib knows that. Captions stay left, and the bottom-right eighth of the
canvas is deliberately left empty.
"""
import json, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
BG, FG, DIM, A, HOT, GRN = "#0b0d10", "#e8ecf2", "#7a8291", "#5dd0ff", "#ff6b5d", "#76ffc4"
plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG,
                     "savefig.facecolor": BG, "text.color": FG,
                     "axes.labelcolor": FG, "xtick.color": DIM,
                     "ytick.color": DIM, "font.size": 17})

budget = M["blockMilliseconds"]
peak = M["peakCallbackMs"]
avg = budget * M["averageLoadPercent"] / 100.0

fig, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
ax.barh([2], [budget], height=0.55, color="#1b2634", edgecolor=A, linewidth=2.5)
ax.barh([1], [peak], height=0.55, color=HOT, alpha=0.85)
ax.barh([0], [avg], height=0.55, color=GRN, alpha=0.85)
ax.set_yticks([2, 1, 0])
ax.set_yticklabels(["THE DEADLINE\nfor one block",
                    "SLOWEST BLOCK\nmeasured",
                    "TYPICAL BLOCK\nmeasured"], fontsize=20, color=FG)
ax.set_xlabel("thousandths of a second", fontsize=22, labelpad=14)
ax.set_xlim(0, budget * 1.12)
for sp in ("top", "right", "left"):
    ax.spines[sp].set_visible(False)
ax.spines["bottom"].set_color(DIM)
for y, v, col in ((2, budget, A), (1, peak, HOT), (0, avg, GRN)):
    ax.text(v + budget * 0.012, y, f"{v:.2f} ms", va="center",
            fontsize=24, color=col)
ax.set_title(f'{M["blockFrames"]} samples at {M["sampleRate"]:,} a second, '
             "over and over", fontsize=30, color=FG, pad=26)
fig.text(0.055, 0.055,
         f'measured on this project: {M["windowCallbacks"]:,} blocks in '
         f'{M["windowSeconds"]:.1f} seconds, {M["windowOverruns"]} of them late',
         color=DIM, fontsize=20)
fig.tight_layout(rect=(0, 0.08, 0.93, 1))
fig.savefig(f"{HERE}/shots/chart-budget.png")
print("  chart-budget.png  budget %.3f  peak %.3f  avg %.3f"
      % (budget, peak, avg))
