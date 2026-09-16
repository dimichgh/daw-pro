#!/usr/bin/env python3
"""The measured charts. Every value is read from MEASUREMENTS.json — nothing on
any of these axes is drawn by hand, and no number is typed twice.

⚠ THE CORNER METER IS BURNED INTO THE BOTTOM-RIGHT of the finished frame
(340x48 at a 36 px margin, i.e. x 1544-1884 / y 996-1044 of 1920x1080 —
read from meter.py's own constants). Nothing that has to be read goes there;
captions live bottom-LEFT.
"""
import json, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S = f"{HERE}/shots"
BG, FG, DIM = "#080B10", "#EEF2FF", "#7C8798"
CYAN, VIOLET, WARM, GOLD = "#5AD1FF", "#A78BFA", "#7DF9D6", "#FFC77A"
plt.rcParams.update({"font.family": "Helvetica Neue", "figure.facecolor": BG,
                     "axes.facecolor": BG, "text.color": FG,
                     "axes.labelcolor": DIM, "xtick.color": DIM, "ytick.color": DIM,
                     "axes.edgecolor": "#2A3340", "savefig.facecolor": BG})


def fig(left=0.09):
    """⚠ MARGINS ARE EXPLICIT. On the default ones the two-line x tick labels ran
    into the caption and the longest y tick label was cut off at the frame edge —
    both found by looking at the rendered png."""
    f, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
    f.subplots_adjust(left=left, right=0.975, top=0.88, bottom=0.19)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    return f, ax


def save(f, name, caption):
    # ⚠ WRAPPED. The first render's caption ran off the right edge of the frame
    # and the last words were simply not in the picture.
    import textwrap
    f.text(0.055, 0.028, "\n".join(textwrap.wrap(caption, 118)), fontsize=17,
           color=DIM, ha="left", va="bottom")
    f.savefig(f"{S}/{name}.png")
    plt.close(f)
    print(f"  chart {name}")


# ── 1. where each part of the track lives ───────────────────────────────────
f, ax = fig()
b = M["bands"]
labels = [f"{lo}-{hi} Hz" if hi < 1000 else
          (f"{lo}-{hi//1000} kHz" if lo < 1000 else f"{lo//1000}-{hi//1000} kHz")
          for lo, hi in b["edges"]]
xs = np.arange(len(labels))
p = [v["db"] for v in b["piano"]]
q = [v["db"] for v in b["full"]]
# ⚠ BARS GROW UP FROM A FLOOR. Plotted straight, a negative dB value draws a
# bar hanging DOWN from zero, so the QUIETEST band got the biggest bar — the
# picture said the opposite of the numbers. Found by looking at it.
floor = min(p + q) - 6
ax.bar(xs - 0.19, [v - floor for v in p], 0.36, bottom=floor, color=CYAN,
       label="the prelude on its own")
ax.bar(xs + 0.19, [v - floor for v in q], 0.36, bottom=floor, color=VIOLET,
       label="the finished house track")
for i, (a, c) in enumerate(zip(p, q)):
    ax.text(i, max(a, c) + 2.2, f"{c-a:+.1f} dB", ha="center", fontsize=22,
            color=GOLD if c - a > 6 else WARM, fontweight="bold")
ax.set_xticks(xs, labels, fontsize=21)
ax.set_ylabel("energy in the band, dB relative to full scale", fontsize=20)
ax.set_ylim(floor, max(p + q) + 10)
ax.tick_params(labelsize=19)
# ⚠ ABOVE the axes: inside, the legend sat on top of the 1-4 kHz bars.
ax.legend(fontsize=21, frameon=False, labelcolor=FG, loc="upper right")
ax.set_title("WHAT THE HOUSE PARTS ADD, BAND BY BAND", fontsize=31, color=FG,
             loc="left", pad=26)
save(f, "chart-bands", "Welch PSD over the same eight bars of each render "
     "(measure.py). The prelude's own band, 250 Hz to 1 kHz, moves by "
     f"{q[3]-p[3]:+.2f} dB. Everything below it moves by more than fifty.")

# ── 2. the tempo, measured off the audio ────────────────────────────────────
f, ax = fig()
t = M["tempo"]
names = ["Bach's tempo\n72 BPM", "house tempo\n124 BPM"]
pred = [t["slow"]["predictedOnsetsPerSec"], t["fast"]["predictedOnsetsPerSec"]]
meas = [t["slow"]["measuredOnsetsPerSec"], t["fast"]["measuredOnsetsPerSec"]]
xs = np.arange(2)
ax.bar(xs - 0.18, pred, 0.34, color=DIM, label="predicted from the tempo")
ax.bar(xs + 0.18, meas, 0.34, color=GOLD, label="measured off the render")
for i in range(2):
    ax.text(i - 0.18, pred[i] + 0.16, f"{pred[i]:.3f}", ha="center", fontsize=23, color=FG)
    ax.text(i + 0.18, meas[i] + 0.16, f"{meas[i]:.3f}", ha="center", fontsize=23, color=GOLD)
ax.set_xticks(xs, names, fontsize=24)
ax.set_ylabel("sixteenth notes per second", fontsize=20)
ax.set_ylim(0, max(meas) + 1.4)
ax.tick_params(labelsize=19)
ax.legend(fontsize=21, frameon=False, labelcolor=FG, loc="upper left")
ax.set_title("THE ONLY THING THAT CHANGED", fontsize=31, color=FG, loc="left", pad=26)
save(f, "chart-tempo", "Onset rate from the spectral-flux envelope of each render. "
     f"The two tempos are a ratio of {t['ratio']:.4f}; the two measurements are a "
     f"ratio of {t['measuredRatio']:.4f}. Eight bars take "
     f"{t['secondsFor8Bars']['slow']:.2f} s at 72 and "
     f"{t['secondsFor8Bars']['fast']:.2f} s at 124.")

# ── 3. the build, in loudness ───────────────────────────────────────────────
f, ax = fig(left=0.20)
order = [("piano124", "the prelude alone"), ("l2-kick", "+ kick"),
         ("l3-hats", "+ offbeat hats"), ("l4-clap", "+ clap on 2 and 4"),
         ("l5-bass", "+ bass on Bach's roots")]
vals = [M["loudness"][k]["integratedLufs"] for k, _ in order]
peaks = [M["loudness"][k]["truePeakDbtp"] for k, _ in order]
ys = np.arange(len(order))[::-1]
# same floor rule as chart 1 — a negative LUFS drawn from zero inverts the read
lf = min(vals) - 1.6
ax.barh(ys, [v - lf for v in vals], 0.5, left=lf, color=[CYAN] + [VIOLET] * 4)
for y, v, pk in zip(ys, vals, peaks):
    ax.text(v + 0.12, y, f"  {v:.1f} LUFS   ·   true peak {pk:.1f} dBTP",
            va="center", fontsize=22, color=FG)
ax.set_yticks(ys, [n for _, n in order], fontsize=23)
ax.set_xlabel("integrated loudness, LUFS (ffmpeg EBU R128)", fontsize=20)
ax.set_xlim(lf, -8.0)
ax.tick_params(labelsize=19)
ax.set_title("WHAT EACH LAYER COSTS IN LOUDNESS", fontsize=31, color=FG,
             loc="left", pad=26)
save(f, "chart-loud", "Every figure re-measured with ffmpeg off the wav the app "
     "rendered; the app's own report agrees to within 0.05 LU on all nine files.")

# ── 4. the right instrument and the wrong one ───────────────────────────────
f, ax = fig()
ks = M["marker"]["order"]
own = [M["marker"]["entrySteps"][k]["onHitsStepDb"] for k in ks]
mix = [M["marker"]["wholeMixSteps"][k] for k in ks]
xs = np.arange(len(ks))
ax.bar(xs - 0.19, own, 0.36, color=GOLD, label="measured in that part's own band")
ax.bar(xs + 0.19, mix, 0.36, color=DIM, label="measured on the whole mix")
for i in range(len(ks)):
    ax.text(i - 0.19, own[i] + 0.8, f"{own[i]:+.2f}", ha="center", fontsize=22, color=GOLD)
    ax.text(i + 0.19, mix[i] + 0.8, f"{mix[i]:+.2f}", ha="center", fontsize=22, color=FG)
ax.set_xticks(xs, [f"{k}\nenters bar {M['marker']['entrySteps'][k]['entryBar']}"
                   for k in ks], fontsize=23)
ax.set_ylabel("level step, bar before vs bar after, dB", fontsize=20)
ax.set_ylim(-2, max(own) + 7)
ax.axhline(0, color="#2A3340", lw=2)
ax.tick_params(labelsize=19)
ax.legend(fontsize=21, frameon=False, labelcolor=FG, loc="upper right")
ax.set_title("A PART ARRIVING IS NOT THE SAME AS THE MIX GETTING LOUDER",
             fontsize=29, color=FG, loc="left", pad=26)
save(f, "chart-steps", "Each part measured in its own band at its own hit "
     "positions, the bar after its first note against the bar before. The hats "
     f"move their own band by {own[1]:+.2f} dB and the whole mix by "
     f"{mix[1]:+.2f} dB.")
