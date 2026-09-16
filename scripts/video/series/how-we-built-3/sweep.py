#!/usr/bin/env python3
"""The attention marker: a playhead crossing the MEASURED level chart in real
time, so the moment the viewer is told to listen and the moment the two
settings differ are the same moment.

Two bursts, one per pass, because the two passes are the same audio at two
levels and identical pictures under them would read as a stuck video. The
shaded listen-windows are DERIVED from where the settings actually differ.
"""
import json, os, shutil, sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import wav                                                     # noqa: E402

M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
CA = "/Users/dsemenov/Views/daw-pro/scripts/video/comp/audio"
FPS = 30
BG, FG, DIM = "#0b0d12", "#eef2ff", "#9aa2b1"
BLUE, ORANGE, RED = "#82cdff", "#ffb066", "#ff6b7c"

sr, f, _ = wav.read(f"{CA}/d3-release-fast.wav")
_, s, _ = wav.read(f"{CA}/d3-release-slow.wav")
n = min(len(f), len(s))
secs = n / sr
ef, w = wav.env_db(f[:n], sr, 20.0)
es, _ = wav.env_db(s[:n], sr, 20.0)
t = np.arange(len(ef)) * w / sr
sig = (ef - es > 3.0) & (ef > -70.0)
d = np.diff(sig.astype(int))
spans = list(zip(sorted(list(np.where(d == 1)[0] + 1) + ([0] if sig[0] else [])),
                 sorted(list(np.where(d == -1)[0] + 1) + ([len(sig)] if sig[-1] else []))))

plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG,
                     "savefig.facecolor": BG, "text.color": FG,
                     "axes.labelcolor": FG, "xtick.color": DIM,
                     "ytick.color": DIM, "font.size": 16})

# ⚠ THE SECOND CHART MUST BE DRAWN AT THE LEVEL THE SECOND PASS IS PLAYED AT.
# The first build drew BOTH from the original files, so the chart under the
# lifted audio still read -41 dBFS while the viewer was hearing it 14 dB louder
# — a picture disagreeing with its own soundtrack, which nothing measures.
PASSES = [("pair-sweep", "AT THE LEVEL IT SHIPPED AT",
           "every shaded stripe is a moment the two settings differ", 0.0),
          ("pair-sweep-lift", f'THE SAME TWO FILES, PLUS {M["pairLiftDb"]:.0f} dB',
           "one shared gain on both halves — nothing between them has moved",
           float(M["pairLiftDb"]))]

bj = json.load(open(f"{HERE}/bursts.json")) if os.path.exists(f"{HERE}/bursts.json") else {}
for name, title, cap, gain in PASSES:
    out = f"{HERE}/bursts/{name}"
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    fig, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
    fig.subplots_adjust(left=0.085, right=0.975, top=0.815, bottom=0.135)
    for a, b in spans:
        ax.axvspan(t[a], t[min(b, len(t) - 1)], color="#ffffff", alpha=0.085, lw=0)
    ax.plot(t, np.maximum(ef + gain, -78), color=BLUE, lw=2.0, label="release 30 ms  (fast)")
    ax.plot(t, np.maximum(es + gain, -78), color=ORANGE, lw=2.0, label="release 800 ms  (slow)")
    ax.axhline(M["filmLufs"], color=RED, lw=2.0, ls="--")
    ax.text(0.15, M["filmLufs"] + 2.4, "the level of the voice in this film",
            color=RED, fontsize=15)
    ax.set_xlim(0, secs)
    ax.set_ylim(-78, 0)
    ax.set_xlabel("seconds")
    ax.set_ylabel("level, dBFS  (20 ms windows)")
    ax.set_yticks([0, -20, -40, -60])
    ax.grid(color="#1b2130", lw=0.8)
    ax.legend(loc="upper right", frameon=False, fontsize=17)
    fig.text(0.085, 0.905, title, fontsize=30, color=FG, weight="bold")
    fig.text(0.085, 0.858, cap, fontsize=17, color=DIM)
    fig.text(0.055, 0.035, "the playhead is in real time", color="#5d6675", fontsize=15)
    head = ax.axvline(0.0, color="#5dd0ff", lw=2.6)
    N = int(round(secs * FPS))
    for i in range(N):
        head.set_xdata([i / FPS, i / FPS])
        fig.savefig(f"{out}/f{i+1:04d}.png")
    plt.close(fig)
    json.dump({"fps": FPS, "frames": N, "seconds": round(N / FPS, 3)},
              open(f"{out}/meta.json", "w"), indent=1)
    bj[name] = round(N / FPS, 3)
    print(f"  {name:18s} {N} frames  {N/FPS:.2f}s  (audio {secs:.2f}s)")

json.dump(bj, open(f"{HERE}/bursts.json", "w"), indent=1)
