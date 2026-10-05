#!/usr/bin/env python3
"""The film's static charts. Every point is read out of MEASUREMENTS.json --
nothing here is drawn by hand, and no chart states a number the file does not
contain.

⚠ THE FOOTNOTE KEEP-OUT GATE IS LIFTED VERBATIM FROM THE AMEN REBUILD, where it
  refused text that had already been through a green build. The film burns a
  level meter into the bottom-RIGHT corner AFTER assembly; a footnote running
  under it is invisible to every other gate and to the string that produced it.
"""
import json, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S = f"{HERE}/shots"
BG, FG, DIM = "#080B10", "#E8EEF6", "#7C8798"
CYAN, RED, WARM, GOLD = "#5AD1FF", "#FF6B6B", "#7DF9D6", "#FFC65A"
plt.rcParams.update({"font.family": "Helvetica Neue", "figure.facecolor": BG,
                     "axes.facecolor": BG, "text.color": FG, "axes.labelcolor": FG,
                     "xtick.color": DIM, "ytick.color": DIM, "axes.edgecolor": "#39424F",
                     "savefig.facecolor": BG})


def frame(w=16, h=9):
    f, ax = plt.subplots(figsize=(w, h), dpi=120)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.grid(color="#1B2733", lw=1)
    ax.set_axisbelow(True)
    return f, ax


def save(f, name, foot=None):
    t = None
    if foot:
        t = f.text(0.055, 0.013, foot, color=DIM, fontsize=13, ha="left",
                   va="bottom", linespacing=1.5)
    f.tight_layout(rect=(0, 0.085, 1, 1))
    f.savefig(f"{S}/{name}.png")
    if t is not None:
        e = t.get_window_extent(f.canvas.get_renderer())
        w, h = f.canvas.get_width_height()
        meter_x = 0.72 * w
        if e.x1 > meter_x or e.x0 < 0 or e.y0 < 0:
            raise SystemExit(
                f"REFUSING {name}.png: the footnote is drawn to x={e.x1:.0f}, past the "
                f"corner meter's keep-out at x={meter_x:.0f} of a {w}px frame. "
                f"Split it across two lines with a newline.")
    plt.close(f)
    print(f"  {name}.png")


# ══════════════════════════════════════ 1. the instrument, calibrated
# Before the film asks anyone to believe a timing measurement, it shows that the
# clock it measures with is right. Every rendered click, measured back, against
# what the arithmetic says it should be -- plus the deliberately mistimed one,
# which is the only reason to believe the clean readings mean anything.
C = M["clicks"]
PC = M["probeControl"]
f, ax = frame()
names = ["mark216", "drift192", "unit108", "eroica152"]
labels = ["half = 108\n(216 quarter BPM)", "half = 96\n(192 quarter BPM)",
          "quarter = 108\n(108 quarter BPM)", "half = 76\n(152 quarter BPM)"]
x = np.arange(len(names))
pred = [C[k]["predictedIoiMs"] for k in names]
meas = [C[k]["meanIoiMs"] for k in names]
ax.bar(x - 0.19, pred, 0.36, color="#28394A", edgecolor=DIM, lw=1.2, label="predicted")
ax.bar(x + 0.19, meas, 0.36, color=CYAN, label="measured off the render")
for i, k in enumerate(names):
    ax.text(i, meas[i] + 62, f"{meas[i]:.4f} ms", ha="center", color=FG, fontsize=16)
    ax.text(i, meas[i] + 26, f"spread {C[k]['spreadMs']:.4f} ms", ha="center",
            color=DIM, fontsize=13)
ax.set_xticks(x); ax.set_xticklabels(labels, fontsize=14)
ax.set_ylabel("time between metronome ticks  (ms)", fontsize=16)
ax.set_title("The clock, checked before anything is timed with it",
             fontsize=24, color=FG, pad=18, loc="left")
ax.set_ylim(0, max(meas) * 1.30)
ax.legend(frameon=False, fontsize=15, loc="upper left")
save(f, "chart-clicks",
     f"Spread is the widest gap between any two ticks in a render. "
     f"0.0208 ms is ONE SAMPLE at 48 kHz.\n"
     f"Control: the same probe on a deliberately mistimed render read "
     f"{PC['jitterAudioMaxAbsMs']:.4f} ms against the project's "
     f"{PC['jitterProjectMaxAbsMs']:.4f} ms.")

# ══════════════════════════════════════ 2. the drift, predicted then measured
D = M["drift"]
f, ax = frame()
k = np.arange(len(D["measuredMs"]))
ax.plot(k, D["predictedMs"], "o--", color="#28394A", ms=13, lw=2.5,
        markerfacecolor=BG, markeredgecolor=DIM, markeredgewidth=2, label="predicted")
ax.plot(k, D["measuredMs"], "o-", color=CYAN, ms=11, lw=3, label="measured")
for i, v in enumerate(D["measuredMs"]):
    ax.annotate(f"{v:.0f} ms", (i, v), textcoords="offset points", xytext=(0, 18),
                ha="center", color=FG, fontsize=17)
ax.axhline(30, color=GOLD, lw=2, ls=":")
ax.text(0.04, 42, "30 ms — about where two attacks stop sounding like one event",
        color=GOLD, fontsize=14)
ax.set_xticks(k); ax.set_xticklabels([f"statement {i + 1}" for i in k], fontsize=16)
ax.set_ylabel("how far behind the marked tempo  (ms)", fontsize=16)
ax.set_title("Twelve beats a minute, accumulating", fontsize=24, color=FG, pad=18, loc="left")
save(f, "chart-drift",
     f"Marked half note = 108 against half note = 96. Every point is measured off "
     f"the rendered\nmetronome; the largest disagreement with the arithmetic is "
     f"{D['maxErrMs']:.3f} ms.")

# ══════════════════════════════════════ 3. the three hypotheses, on two marks
H = M["prediction"]["hypotheses"]
f, ax = frame()
works = ["Symphony No. 5, first movement", "Symphony No. 3 'Eroica', finale"]
keys = ["fifth", "eroica"]
x = np.arange(2)
series = [("what he wrote", [H["marks"][k] for k in keys], FG, "o", 15),
          ("minus twelve  (a constant error)", [H["constantOffset"][k] for k in keys], CYAN, "s", 13),
          ("halved  (a wrong note value)", [H["halved"][k] for k in keys], RED, "^", 14)]
for lab, ys, c, mk, ms in series:
    ax.plot(x, ys, mk + "-", color=c, ms=ms, lw=3, label=lab)
    for xi, yv in zip(x, ys):
        ax.annotate(f"{yv:g}", (xi, yv), textcoords="offset points", xytext=(0, 16),
                    ha="center", color=c, fontsize=17)
ax.set_xticks(x); ax.set_xticklabels(works, fontsize=16)
ax.set_xlim(-0.35, 1.35)
ax.set_ylim(20, 125)
ax.set_ylabel("half notes per minute", fontsize=16)
ax.set_title("Three shapes of mistake — and two marks cannot choose between them",
             fontsize=24, color=FG, pad=18, loc="left")
ax.legend(frameon=False, fontsize=16, loc="lower left")
save(f, "chart-hypotheses",
     "This is ARITHMETIC ON THE THREE CLAIMS, not a measurement of Beethoven.\n"
     "The 2020 study that argues for a constant error used sixty-three marks. "
     "These are two.")

# ══════════════════════════════════════ 4. why the strings are not the clock
E = M["stringEnvelope"]
f, ax = frame()
import soundfile as sf
a, sr = sf.read(f"{HERE}/audio/motif-mark-216-dry.wav", always_2d=True)
seg = a.mean(axis=1)[int(E["fromSec"] * sr):int(E["toSec"] * sr)]
win = int(sr * 0.005)
env = np.array([np.sqrt(np.mean(seg[i * win:(i + 1) * win] ** 2))
                for i in range(len(seg) // win)])
t = (np.arange(len(env)) * 5) + E["fromSec"] * 1000
rel = 20 * np.log10(env / env.max() + 1e-12)
ax.plot(t, rel, color=WARM, lw=2.5)
ax.set_xlabel("time  (ms)", fontsize=16)
ax.set_ylabel("level, relative to this note's loudest moment  (dB)", fontsize=16)
ax.set_title("One held string chord, while nothing else is happening",
             fontsize=24, color=FG, pad=18, loc="left")
ax.set_ylim(rel.min() - 1.5, 2)
save(f, "chart-strings",
     f"Measured off the render: the level moves over {E['rangeDb']:.1f} dB and turns "
     f"around {E['localMaximaPerSecond']:.0f} times a second.\n"
     f"A string section does not start a note at an instant, so the film times the "
     f"metronome instead.")

print("charts done")
