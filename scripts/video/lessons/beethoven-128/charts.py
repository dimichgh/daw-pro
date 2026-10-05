#!/usr/bin/env python3
"""The matplotlib charts. Every one is drawn from MEASUREMENTS.json / spectra.npz
— nothing here is hand-drawn, and nothing is re-derived from the audio a second
way (which is how a chart and a card start disagreeing).

⚠ RUN WITH THE PLUGIN VENV.
⚠ KEEP THE BOTTOM-RIGHT CORNER CLEAR. shortsmith burns a live level meter into
   the frame at about x > 0.72, y > 0.80 AFTER the segments are built, so any
   footnote there is eaten. Footnotes here are left-aligned and short.
"""
import json, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S = f"{HERE}/shots"
Z = np.load(f"{HERE}/spectra.npz")

BG, FG, GRID = "#0d1117", "#e6edf3", "#232c37"
ORCH_C, TECH_C, HOT, DIM = "#8ab4f8", "#ff7b5a", "#ffd166", "#7d8590"
plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG,
                     "savefig.facecolor": BG, "text.color": FG,
                     "axes.labelcolor": FG, "xtick.color": FG,
                     "ytick.color": FG, "axes.edgecolor": GRID,
                     "font.family": "DejaVu Sans", "font.size": 15})


def fig(w=16, h=9):
    f, ax = plt.subplots(figsize=(w, h), dpi=120)
    ax.grid(color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    return f, ax


def save(f, name, bottom=0.03):
    # ⚠ THE ASSEMBLER BURNS A LEVEL METER INTO THE BOTTOM-RIGHT CORNER after
    # this chart is a still. MEASURED off the finished film: the meter box
    # covers x 1480–1885, y 985–1045 of the 1920x1080 frame — i.e. the bottom
    # 3.2–8.8 % of the figure, right of x = 0.77. Two of these charts had their
    # RIGHTMOST x-axis tick label ("above 200 Hz") sitting at y ≈ 1005 and the
    # meter ate it. Found by pulling the frame and looking, not by any gate.
    # `bottom` reserves enough figure to lift the tick labels clear.
    f.tight_layout(rect=[0.01, bottom, 0.99, 0.95])
    p = f"{S}/{name}.png"
    f.savefig(p)
    plt.close(f)
    print(f"  {name}.png")


def smooth(P, k=15):
    return np.convolve(P, np.ones(k) / k, mode="same")


def psd_db(P):
    return 10 * np.log10(smooth(P) + 1e-30)


f_, Po, Pt = Z["f"], Z["orch"], Z["techno"]
sel = (f_ >= 20) & (f_ <= 16000)
FQ, DO, DT = f_[sel], psd_db(Po)[sel], psd_db(Pt)[sel]

B = M["bands"]
CROSS = M["_chart"]["crossoverHz"]

# ── 1. THE CENTREPIECE: the two spectra, with the band that matters shaded ──
f, ax = fig()
ax.semilogx(FQ, DO, color=ORCH_C, lw=2.4, label="orchestral — strings in three octaves")
ax.semilogx(FQ, DT, color=TECH_C, lw=2.4, label="techno — same notes, plus the room")
lo = min(DO.min(), DT.min())
ax.axvspan(20, 60, color=HOT, alpha=0.10)
ax.axvline(41.2, color=DIM, ls=":", lw=1.6)
# ⚠ EVERY ONE OF THESE IS PLACED IN DATA COORDINATES, IN A REGION MEASURED TO BE
# EMPTY. The first render put the stat block through the techno curve and ran the
# 41.2 Hz caption straight through the crossover caption; both were found by
# looking at the frame, not by any gate.
ax.text(21, -86, "BELOW 60 Hz", color=HOT, fontsize=19, fontweight="bold",
        va="bottom")
ax.text(21, -89,
        f"techno {B['techno']['sub60']:.1f} dB\norchestral {B['orch']['sub60']:.1f} dB\n"
        f"{B['delta']['sub60']:+.1f} dB",
        color=HOT, fontsize=16, va="top")
if CROSS:
    ax.axvline(CROSS, color=FG, ls="--", lw=1.4, alpha=0.55)
    # ⚠ BOTH LINE CAPTIONS LIVE IN THE EMPTY BOTTOM-MIDDLE. Placed beside their
    # own lines they ran through the orchestral curve and through each other.
    ax.text(210, -97,
            f"dashed line — the two cross at {CROSS:.0f} Hz; above it the "
            f"orchestra is louder",
            color=FG, fontsize=13, alpha=0.85, va="center", ha="left")
    ax.text(210, -107,
            "dotted line — about 41 Hz, the bottom string of a double bass: the floor of this scoring",
            color=DIM, fontsize=13, va="center", ha="left")
ax.set_xlim(20, 16000)
ax.set_ylim(-120, DT.max() + 4)
ax.set_xlabel("frequency (Hz)  —  logarithmic")
ax.set_ylabel("power spectral density (dB)")
ax.set_title("The same four notes, measured. Two renders, one project, one tempo.",
             fontsize=20, pad=16, loc="left")
ax.xaxis.set_major_locator(FixedLocator([20, 50, 100, 200, 500, 1000, 5000, 10000]))
ax.set_xticklabels(["20", "50", "100", "200", "500", "1k", "5k", "10k"])
ax.legend(loc="upper right", facecolor=BG, edgecolor=GRID, labelcolor=FG, fontsize=15)
f.text(0.012, 0.012, "Welch PSD, 32768-point, from the two renders. "
       "Shaded: the band under 60 Hz.", color=DIM, fontsize=12, ha="left")
save(f, "chart-spectrum")

# ── 2. the band table as bars, growing UP from a floor ─────────────────────
#    ⚠ Hanging negative dB bars DOWN from zero makes the QUIETEST bar the
#    longest, which reads as "biggest". These grow up from a fixed floor.
f, ax = fig(16, 9)
KEYS = [("sub40", "under 40 Hz"), ("sub60", "under 60 Hz"),
        ("b60_100", "60 – 100 Hz"), ("b100_200", "100 – 200 Hz"),
        ("b200up", "above 200 Hz"), ("full", "the whole file")]
FLOOR = -60
x = np.arange(len(KEYS))
vo = [B["orch"][k] for k, _ in KEYS]
vt = [B["techno"][k] for k, _ in KEYS]
ax.bar(x - 0.19, [v - FLOOR for v in vo], 0.36, bottom=FLOOR, color=ORCH_C,
       label="orchestral")
ax.bar(x + 0.19, [v - FLOOR for v in vt], 0.36, bottom=FLOOR, color=TECH_C,
       label="techno")
for i, (a, b) in enumerate(zip(vo, vt)):
    ax.text(i - 0.19, a + 1.2, f"{a:.1f}", ha="center", color=ORCH_C, fontsize=13)
    ax.text(i + 0.19, b + 1.2, f"{b:.1f}", ha="center", color=TECH_C, fontsize=13)
    # ⚠ THE DELTA LABEL GOES ABOVE THE TALLER BAR, NOT NEAR THE FLOOR. The
    # first render put it at FLOOR+2.5, i.e. INSIDE both bars, where the text
    # was half-hidden by them — visible only by looking at the frame.
    d = b - a
    ax.text(i, max(a, b) + 4.5, f"{d:+.1f} dB", ha="center",
            color=HOT if d > 6 else DIM, fontsize=16, fontweight="bold")
ax.set_xticks(x)
ax.set_xticklabels([n for _, n in KEYS])
ax.set_ylim(FLOOR, 0)
ax.set_ylabel("level in that band (dBFS)")
ax.set_title("Where the difference actually is — and where it is not",
             fontsize=20, pad=16, loc="left")
# ⚠ "lower right" sat ON TOP of the last pair of bars — every bar here runs to
# the floor, so the only empty space is above the shortest pair.
ax.legend(loc="upper left", facecolor=BG, edgecolor=GRID, labelcolor=FG, fontsize=15)
f.text(0.012, 0.012, "Bars grow up from a −60 dB floor. Numbers under each pair "
       "are techno minus orchestral.", color=DIM, fontsize=12, ha="left")
save(f, "chart-bands", bottom=0.11)

# ── 3. what a laptop hands you ─────────────────────────────────────────────
LP = M["laptop"]["techno"]
f, ax = fig()
hp = FQ >= 100
ax.semilogx(FQ, DT, color=TECH_C, lw=2.4, label="the techno render, as it is")
DTH = DT.copy()
DTH[FQ < 100] = np.nan
ax.semilogx(FQ, DTH, color=HOT, lw=3.0, ls="--",
            label="what is left above 100 Hz")
ax.axvspan(20, 100, color=DIM, alpha=0.16)
ax.text(23, DT.max() - 3, "your laptop speaker\nbarely delivers this part",
        color=FG, fontsize=15, va="top")
ax.text(23, DT.min() + 12,
        f"taking it away costs\n{LP['rmsLossDb']:.1f} dB of actual level\n"
        f"but only {LP['lufsLossLu']:.1f} LU of LOUDNESS",
        color=HOT, fontsize=14, va="bottom")
ax.set_xlim(20, 16000)
ax.set_ylim(DT.min(), DT.max() + 4)
ax.set_xlabel("frequency (Hz)  —  logarithmic")
ax.set_ylabel("power spectral density (dB)")
ax.set_title("The part of this file you are probably not hearing", fontsize=20,
             pad=16, loc="left")
ax.xaxis.set_major_locator(FixedLocator([20, 50, 100, 200, 500, 1000, 5000, 10000]))
ax.set_xticklabels(["20", "50", "100", "200", "500", "1k", "5k", "10k"])
ax.legend(loc="upper right", facecolor=BG, edgecolor=GRID, labelcolor=FG, fontsize=15)
f.text(0.012, 0.012, "8th-order Butterworth high-pass at 100 Hz, applied to the "
       "render and re-measured.", color=DIM, fontsize=12, ha="left")
save(f, "chart-laptop")

# ── 4. the room arriving, one strip at a time ──────────────────────────────
f, ax = fig()
L = M["layers"]
names = ["riff\nalone", "+ kick", "+ hats", "+ clap", "+ sub"]
x = np.arange(len(L))
# ⚠ THE FLOOR HAS TO SIT UNDER THE SMALLEST VALUE. At −45 the riff-alone <60 Hz
# figure (−62.4) had NO BAR AT ALL and its label was drawn outside the axes,
# floating in the margin. Derived from the data now, not typed.
FL = 5 * np.floor((min([l["lufs"] for l in L]
                       + [l["bands"]["sub60"] for l in L]) - 4) / 5)
ax.bar(x - 0.19, [l["lufs"] - FL for l in L], 0.36, bottom=FL, color=TECH_C,
       label="loudness (LUFS)")
ax.bar(x + 0.19, [l["bands"]["sub60"] - FL for l in L], 0.36, bottom=FL,
       color=HOT, label="level under 60 Hz (dBFS)")
for i, l in enumerate(L):
    ax.text(i - 0.19, l["lufs"] + 0.8, f"{l['lufs']:.1f}", ha="center",
            color=TECH_C, fontsize=13)
    ax.text(i + 0.19, l["bands"]["sub60"] + 0.8, f"{l['bands']['sub60']:.1f}",
            ha="center", color=HOT, fontsize=13)
ax.set_xticks(x)
ax.set_xticklabels(names)
ax.set_ylim(FL, 0)
ax.set_ylabel("dB")
ax.set_title("The cell never changes. Everything around it does.", fontsize=20,
             pad=16, loc="left")
# "lower right" sat on top of the +sub pair — every bar runs to the floor.
ax.legend(loc="upper left", facecolor=BG, edgecolor=GRID, labelcolor=FG, fontsize=15)
f.text(0.012, 0.012, "Each rung is the one before it plus one more strip, "
       "rendered separately.", color=DIM, fontsize=12, ha="left")
save(f, "chart-layers")

# ── 5. the audible proxy: the same part, two octaves up ────────────────────
P = M["proxy"]
f, ax = fig()
KEYS2 = [("sub40", "under 40 Hz"), ("sub60", "under 60 Hz"),
         ("sub100", "under 100 Hz"), ("b100_200", "100 – 200 Hz"),
         ("b200up", "above 200 Hz")]
FL = -95
x = np.arange(len(KEYS2))
a = [P["orig"][k] for k, _ in KEYS2]
b = [P["up2"][k] for k, _ in KEYS2]
ax.bar(x - 0.19, [v - FL for v in a], 0.36, bottom=FL, color=TECH_C,
       label="the sub as written — 32.7 and 49 Hz")
ax.bar(x + 0.19, [v - FL for v in b], 0.36, bottom=FL, color="#79d17a",
       label="the same part two octaves up — 131 and 196 Hz")
for i, (u, v) in enumerate(zip(a, b)):
    ax.text(i - 0.19, u + 2, f"{u:.1f}", ha="center", color=TECH_C, fontsize=13)
    ax.text(i + 0.19, v + 2, f"{v:.1f}", ha="center", color="#79d17a", fontsize=13)
ax.axvspan(2.5, 4.5, color=FG, alpha=0.05)
# ⚠ AT FL+6 THIS RAN BEHIND THE BARS. The only free band in a full-height bar
# chart is above the tallest bar.
ax.text(3.5, -8, "a small speaker starts working here", ha="center",
        color=DIM, fontsize=15)
ax.set_xticks(x)
ax.set_xticklabels([n for _, n in KEYS2])
ax.set_ylim(FL, 0)
ax.set_ylabel("level in that band (dBFS)")
ax.set_title("Same rhythm, same notes, moved to where you can hear them",
             fontsize=20, pad=16, loc="left")
ax.legend(loc="upper left", facecolor=BG, edgecolor=GRID, labelcolor=FG, fontsize=14)
f.text(0.012, 0.012, "Both are the same render with everything except the sub "
       "silenced; only the pitch differs.", color=DIM, fontsize=12, ha="left")
save(f, "chart-proxy", bottom=0.11)
print("charts done")
