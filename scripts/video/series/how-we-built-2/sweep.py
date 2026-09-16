#!/usr/bin/env python3
"""A moving shot for the broken twelve seconds: the waveform with a playhead
crossing it in real time, so the gap the viewer SEES and the click they HEAR
land at the same instant.

⚠ THIS EXISTS BECAUSE OF SOMETHING I LOOKED AT. The first assembly played the
broken audio under a static card — correct, and a wasted opportunity, because
the one moment the film has a visible cause and an audible effect was spent on
a bullet list. Nothing measured that; I pulled the frame and looked.

The playhead position is frame / fps, straight through to the same time axis
the waveform is drawn on, so it cannot drift from the audio it is under.
"""
import json, os, shutil, sys
import numpy as np
import soundfile as sf
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
D = json.load(open(f"{HERE}/dropout.json"))
FPS = 30
BG, FG, DIM, HOT = "#0b0d10", "#e8ecf2", "#7a8291", "#ff6b5d"

x, sr = sf.read(f"{HERE}/audio/mix-broken.wav", always_2d=True)
mono = x.mean(1)
t = np.arange(len(mono)) / sr
secs = len(mono) / sr
n = int(round(secs * FPS))

out = f"{HERE}/bursts/broken-sweep"
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)

plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG,
                     "savefig.facecolor": BG, "text.color": FG,
                     "axes.labelcolor": FG, "xtick.color": DIM,
                     "ytick.color": DIM, "font.size": 17})
fig, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
ax.plot(t, mono, lw=0.5, color=HOT)
ax.set_xlim(0, secs); ax.set_ylim(-1.08, 1.08)
ax.set_xlabel("seconds", fontsize=22, labelpad=12)
ax.set_yticks([])
for sp in ("top", "right", "left"):
    ax.spines[sp].set_visible(False)
ax.spines["bottom"].set_color(DIM)
ax.set_title(f'{len(D["dropouts"])} blocks of {D["blockFrames"]} samples, '
             "replaced with silence", fontsize=30, color=FG, pad=24)
for d in D["dropouts"]:
    ax.axvline(d["startSeconds"], color=HOT, lw=1.6, alpha=0.85)
    ax.annotate(f'{d["milliseconds"]:.2f} ms', (d["startSeconds"], 0.93),
                color=HOT, fontsize=17, ha="center",
                xytext=(0, 6), textcoords="offset points")
# ⚠ the corner avatar lives bottom-right: caption stays left
fig.text(0.055, 0.045, "the playhead is in real time; each mark is one missed block",
         color=DIM, fontsize=19)
fig.tight_layout(rect=(0, 0.075, 0.94, 1))
head = ax.axvline(0.0, color="#5dd0ff", lw=2.6)

for i in range(n):
    head.set_xdata([i / FPS, i / FPS])
    fig.savefig(f"{out}/f{i+1:04d}.png")
plt.close(fig)
json.dump({"fps": FPS, "frames": n, "seconds": round(n / FPS, 3)},
          open(f"{out}/meta.json", "w"), indent=1)
b = json.load(open(f"{HERE}/bursts.json"))
b["broken-sweep"] = round(n / FPS, 3)
json.dump(b, open(f"{HERE}/bursts.json", "w"), indent=1)
print(f"  broken-sweep {n} frames  {n/FPS:.2f}s  (audio {secs:.2f}s)")
