#!/usr/bin/env python3
"""L6 rebuild — PASS 3a: the matplotlib charts, all of them MEASURED.

Every point plotted here is read out of MEASUREMENTS.json, which measure.py
wrote off the renders. Nothing is illustrated and nothing is drawn by hand.

⭐ THIS IS THE FILM'S ANSWER TO ITS OWN AUDIBILITY FAULT. The clipping this
lesson is about lives, at a −14 LUFS target, tens of decibels under the music
it is hiding in — correctly measured, and inaudible on a laptop speaker. A
clipped waveform, on the other hand, is something you can SEE instantly. So the
waveform, the flat top, the ladder and the bill are all charts.

⚠ Run with the plugin venv (matplotlib lives only there).
"""
import json, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(os.path.join(HERE, "MEASUREMENTS.json")))
SH = os.path.join(HERE, "shots")
C = M["_chart"]

BG, FG, DIM = "#0B0D12", "#EEF2FF", "#7C8798"
CYAN, VIOLET, WARM, AMBER, RED = "#5AD1FF", "#A78BFA", "#7DF9D6", "#FFB84D", "#FF6B6B"
plt.rcParams.update({
    "figure.facecolor": BG, "axes.facecolor": BG, "savefig.facecolor": BG,
    "text.color": FG, "axes.labelcolor": DIM, "xtick.color": DIM,
    "ytick.color": DIM, "axes.edgecolor": "#232A36", "grid.color": "#1A2029",
    "font.size": 17, "axes.titlesize": 26, "figure.dpi": 100,
})


def fig():
    return plt.figure(figsize=(19.2, 10.8))


def save(f, name):
    p = os.path.join(SH, name + ".png")
    f.savefig(p, dpi=100)
    plt.close(f)
    print(f"  {name}.png")


# ------------------------------------------------- 1. the waveform and the lid
def waveform():
    w = C["wave"]
    t = np.array(w["t"])
    f = fig()
    f.text(0.06, 0.925, "THE SAME MIX, BEFORE AND AFTER THE GAIN THAT REACHES −14",
           fontsize=27, color=WARM, weight="bold")
    g14 = M["ladder"][0]
    top = f.add_axes([0.06, 0.545, 0.90, 0.335])
    bot = f.add_axes([0.06, 0.145, 0.90, 0.335])

    top.fill_between(t, w["dryLo"], w["dryHi"], color=CYAN, lw=0, alpha=0.85)
    top.set_ylim(-1.62, 1.62)
    top.set_ylabel("sample value")
    top.set_xticklabels([])
    top.text(0.008, 0.93, f'the mix, untouched   ·   '
             f'{M["loudness"]["dry"]["integratedLufs"]:.2f} LUFS   ·   '
             f'peak {M["loudness"]["dry"]["samplePeakDbfs"]:.2f} dBFS',
             transform=top.transAxes, color=CYAN, fontsize=19)

    bot.fill_between(t, w["hotLo"], w["hotHi"], color=VIOLET, lw=0, alpha=0.75)
    over_hi = np.maximum(np.array(w["hotHi"]), 1.0)
    over_lo = np.minimum(np.array(w["hotLo"]), -1.0)
    bot.fill_between(t, 1.0, over_hi, where=over_hi > 1.0, color=RED, lw=0)
    bot.fill_between(t, over_lo, -1.0, where=over_lo < -1.0, color=RED, lw=0)
    bot.set_ylim(-1.62, 1.62)
    bot.set_ylabel("sample value")
    bot.set_xlabel("seconds")
    bot.text(0.008, 0.93, f'+{g14["gainDb"]:.2f} dB   ·   '
             f'{g14["measuredLufs"]:.2f} LUFS   ·   '
             f'peak {g14["floatPeakDbfs"]:.2f} dBFS',
             transform=bot.transAxes, color=VIOLET, fontsize=19)

    for ax in (top, bot):
        for y in (1.0, -1.0):
            ax.axhline(y, color=AMBER, lw=1.6, ls="--")
        ax.grid(True, axis="x", lw=0.8)
        ax.set_xlim(t[0], t[-1])
    bot.text(0.008, 0.035, "everything in red is above full scale — an integer "
             "file has nowhere to put it", transform=bot.transAxes,
             color=RED, fontsize=18)
    top.text(0.80, 0.665, "0 dBFS — full scale", color=AMBER, fontsize=16,
             transform=top.transAxes)
    save(f, "chart-waveform")


# --------------------------------------------------------- 2. one flat top
def flattop():
    z = C["zoom"]
    t = np.array(z["t_ms"])
    f = fig()
    ax = f.add_axes([0.075, 0.15, 0.90, 0.68])
    ax.axhspan(1.0, 1.6, color=RED, alpha=0.07)
    ax.plot(t, z["float"], color=VIOLET, lw=2.6,
            label="what the mix actually asked for (32-bit float)")
    ax.plot(t, z["int24"], color=RED, lw=3.4,
            label="what a 24-bit file can store")
    ax.axhline(1.0, color=AMBER, lw=1.6, ls="--")
    ax.axhline(-1.0, color=AMBER, lw=1.6, ls="--")
    ax.set_xlim(t[0], t[-1])
    lim = max(1.25, float(np.max(np.abs(z["float"]))) * 1.08)
    ax.set_ylim(-lim, lim)
    ax.set_xlabel("milliseconds (0 = the start of the longest clipped run)")
    ax.set_ylabel("sample value")
    ax.grid(True, lw=0.8)
    ax.legend(loc="lower right", facecolor="#11151C", edgecolor="#232A36",
              labelcolor=FG, fontsize=18)
    ax.text(0.012, 0.93, f'{z["runSamples"]} samples in a row, pinned flat '
            f'({z["runSamples"] / 48.0:.2f} ms), at {z["atSeconds"]:.2f} s',
            transform=ax.transAxes, color=RED, fontsize=19)
    f.text(0.075, 0.90, "THE LONGEST FLAT TOP IN THE −14 MASTER",
           fontsize=27, color=WARM, weight="bold")
    f.text(0.075, 0.05, "a curve replaced by a straight line — that straight "
           "line is the distortion, and it is a shape, not a level",
           fontsize=17, color=DIM)
    save(f, "chart-flattop")


# ------------------------------------------------------- 3. the four masters
def masters():
    rows = M["masters"] + [M["loudwar_master"]]
    names = ["the mix\nuntouched", "gain only\n(clips)", "gain +\nlimiter",
             "compressor\n+ limiter", "the same,\nchasing −8"]
    lufs = [r["integratedLufs"] for r in rows]
    tp = [r["truePeakDbtp"] for r in rows]
    lra = [r["loudnessRangeLu"] for r in rows]
    cols = [CYAN, RED, AMBER, WARM, VIOLET]
    f = fig()
    f.text(0.06, 0.925, "FIVE MASTERS OF ONE MIX, EVERY NUMBER OFF THE RENDER",
           fontsize=27, color=WARM, weight="bold")
    x = np.arange(len(rows))

    # ⚠ BARS OF A NEGATIVE QUANTITY. Hanging these down from zero makes the
    #   QUIETEST master the LONGEST bar, which reads as "biggest" — the same
    #   trap the mono lesson's first offsets chart fell into. They grow UP from
    #   a floor instead, so louder is taller.
    FLOOR = -24
    a1 = f.add_axes([0.06, 0.545, 0.41, 0.33])
    a1.bar(x, [v - FLOOR for v in lufs], bottom=FLOOR, color=cols, width=0.62,
           zorder=3)
    a1.axhline(-14, color=FG, lw=1.4, ls="--", zorder=1)
    a1.text(-0.44, -13.4, "−14 LUFS", color=FG, fontsize=16, ha="left")
    a1.set_ylim(FLOOR, 2.4)
    a1.set_ylabel("integrated loudness (LUFS)")
    a1.set_xticks(x); a1.set_xticklabels([])
    for i, v in enumerate(lufs):
        a1.text(i, v + 0.85, f"{v:.2f}", ha="center", color=FG, fontsize=17,
                zorder=4)
    a1.grid(True, axis="y", lw=0.8)

    a2 = f.add_axes([0.565, 0.545, 0.41, 0.33])
    a2.bar(x, tp, color=cols, width=0.62)
    a2.axhline(0, color=AMBER, lw=1.8, ls="--")
    a2.text(len(rows) - 0.45, 0.35, "0 dBFS", color=AMBER, fontsize=16, ha="right")
    a2.axhline(-1, color=FG, lw=1.2, ls=":")
    a2.set_ylim(-4.2, 5.4)
    a2.set_ylabel("true peak (dBTP)")
    a2.set_xticks(x); a2.set_xticklabels([])
    for i, v in enumerate(tp):
        a2.text(i, v + (0.22 if v >= 0 else -0.55), f"{v:+.2f}", ha="center",
                color=FG, fontsize=17)
    a2.grid(True, axis="y", lw=0.8)

    a3 = f.add_axes([0.06, 0.205, 0.915, 0.28])
    a3.bar(x, lra, color=cols, width=0.62)
    a3.set_ylabel("loudness range (LU)")
    a3.set_xticks(x); a3.set_xticklabels(names, fontsize=18, color=FG)
    a3.set_ylim(0, max(lra) * 1.32)
    for i, v in enumerate(lra):
        a3.text(i, v + max(lra) * 0.03, f"{v:.2f}", ha="center", color=FG, fontsize=17)
    a3.grid(True, axis="y", lw=0.8)
    f.text(0.06, 0.030, "loudness range is how much the loudness MOVES.\n"
           "The top row is what you bought; the bottom row is what you paid.",
           fontsize=18, color=DIM)
    save(f, "chart-masters")


# ------------------------------------------- 4. the ladder: how loud a clip is
def ladder():
    rows = M["ladder"]
    tg = [r["targetLufs"] for r in rows]
    res = [r["residualRmsDbfs"] for r in rows]
    rel = [r["residualBelowProgramDb"] for r in rows]
    clipped = [r["clippedSamples"] for r in rows]
    f = fig()
    f.text(0.06, 0.925, "HOW LOUD THE CLIPPING IS, AT FOUR LOUDNESS TARGETS",
           fontsize=27, color=WARM, weight="bold")

    a1 = f.add_axes([0.06, 0.215, 0.41, 0.64])
    a1.plot(tg, rel, color=RED, lw=3.0, marker="o", ms=13)
    for x, y in zip(tg, rel):
        a1.text(x, y + 1.6, f"{y:.1f} dB", ha="center", color=FG, fontsize=17)
    a1.axhspan(-90, -40, color=DIM, alpha=0.10)
    a1.text(-13.0, -42.5, "below about 40 dB under the music a laptop speaker\n"
            "will not deliver it — a rule of thumb, not a measurement",
            color=DIM, fontsize=15, ha="left", va="top")
    a1.set_xlim(-15.0, -4.0)
    a1.set_ylim(min(rel) - 10, max(rel) + 7)
    a1.set_xticks(tg)
    a1.set_xticklabels([f"{t}" for t in tg])
    a1.set_xlabel("loudness target (LUFS) — louder to the right")
    a1.set_ylabel("distortion, relative to the music (dB)")
    a1.grid(True, lw=0.8)

    a2 = f.add_axes([0.565, 0.215, 0.41, 0.64])
    a2.bar(range(len(tg)), clipped, color=RED, width=0.6)
    a2.set_yscale("log")
    a2.set_xticks(range(len(tg)))
    a2.set_xticklabels([f"{t}" for t in tg])
    a2.set_xlabel("loudness target (LUFS)")
    a2.set_ylabel("clipped samples (log scale)")
    for i, v in enumerate(clipped):
        a2.text(i, v * 1.25, f"{v:,}", ha="center", color=FG, fontsize=17)
    a2.set_ylim(max(1, min(clipped) * 0.4), max(clipped) * 6)
    a2.grid(True, axis="y", lw=0.8)

    f.text(0.06, 0.035, f'the distortion itself runs from '
           f'{rows[0]["residualRmsDbfs"]:.1f} dBFS at −14 to '
           f'{rows[-1]["residualRmsDbfs"]:.1f} dBFS at −5:\n'
           f'a span of {M["ladder_span_db"]:.1f} dB, from one mix',
           fontsize=18, color=DIM)
    save(f, "chart-ladder")


# ------------------------------------------------ 5. loudness against range
def bill():
    rows = M["masters"] + [M["loudwar_master"]]
    names = ["the mix, untouched", "gain only (clips)", "gain + limiter",
             "compressor + limiter", "chasing −8"]
    cols = [CYAN, RED, AMBER, WARM, VIOLET]
    f = fig()
    ax = f.add_axes([0.075, 0.145, 0.90, 0.70])
    # ⚠ hand-placed offsets: four of the five masters land within 1.2 LU of
    #   each other and the default "above, centred" wrote them on top of one
    #   another — found by looking at the picture, not by any gate.
    offs = [(0, 28, "center"), (26, 34, "left"), (-26, 30, "right"),
            (0, -62, "center"), (0, 30, "center")]
    for r, nm, c, (dx, dy, ha) in zip(rows, names, cols, offs):
        ax.scatter(r["integratedLufs"], r["loudnessRangeLu"], s=420, color=c, zorder=3)
        ax.annotate(f'{nm}\n{r["integratedLufs"]:.2f} LUFS · {r["loudnessRangeLu"]:.2f} LU',
                    (r["integratedLufs"], r["loudnessRangeLu"]),
                    textcoords="offset points", xytext=(dx, dy), ha=ha,
                    color=c, fontsize=18)
    keep = [rows[0], rows[3], rows[4]]
    ax.plot([r["integratedLufs"] for r in keep], [r["loudnessRangeLu"] for r in keep],
            color=DIM, lw=1.6, ls="--", zorder=1)
    ax.set_xlabel("integrated loudness (LUFS) — louder to the right")
    ax.set_ylabel("loudness range (LU) — more dynamic upwards")
    ax.grid(True, lw=0.8)
    ax.set_ylim(0.2, max(r["loudnessRangeLu"] for r in rows) * 1.55)
    ax.set_xlim(min(r["integratedLufs"] for r in rows) - 1.6,
                max(r["integratedLufs"] for r in rows) + 2.4)
    f.text(0.075, 0.90, "WHAT LOUDNESS COSTS: EVERY STEP RIGHT IS A STEP DOWN",
           fontsize=27, color=WARM, weight="bold")
    b = M["bill"]
    f.text(0.075, 0.055,
           f'{b["loudnessGainedDb"]:.2f} dB louder cost {b["rangeLostLu"]:.2f} LU '
           f'({b["rangeLostPercent"]:.0f}% of the range).  '
           f'Chasing −8 cost {b["loudwarRangeLostLu"]:.2f} LU '
           f'({b["loudwarRangeLostPercent"]:.0f}%).',
           fontsize=19, color=DIM)  # kept left of x=0.70: the corner meter
    save(f, "chart-bill")


# ------------------------------------- 6. what the compressor actually did
def gr():
    g = C["gr"]
    f = fig()
    ax = f.add_axes([0.075, 0.145, 0.90, 0.70])
    q = M["compressor_gr"]
    red = [q["makeupDb"] - v for v in g["db"]]
    ax.plot(g["t"], red, color=WARM, lw=2.0)
    ax.fill_between(g["t"], red, 0, color=WARM, alpha=0.18)
    ax.axhline(0, color="#39424F", lw=1.4)
    ax.axhline(q["reductionMedianDb"], color=AMBER, lw=1.6, ls="--")
    ax.text(0.012, q["reductionMedianDb"] + 0.28,
            f'median {q["reductionMedianDb"]:.2f} dB',
            transform=ax.get_yaxis_transform(), ha="left", color=AMBER, fontsize=18)
    ax.set_xlabel("seconds")
    ax.set_ylabel("gain reduction (dB) — more reduction upwards")
    ax.set_xlim(0, max(g["t"]))
    ax.set_ylim(-0.5, max(red) * 1.12)
    ax.grid(True, lw=0.8)
    f.text(0.075, 0.90, "THE COMPRESSOR'S OWN GAIN, MEASURED — NOT DRAWN",
           fontsize=27, color=WARM, weight="bold")
    f.text(0.075, 0.042, "one render with the compressor bypassed, one with it "
           "engaged, at the same drive,\ndivided sample for sample. Up to "
           f'{q["reductionMaxDb"]:.2f} dB on the loudest moments, with '
           f'+{q["makeupDb"]:.0f} dB of makeup put back after.',
           fontsize=18, color=DIM)
    save(f, "chart-gr")


# --------------------------------------- 7. the range collapse, over time
def overtime():
    s = C["shortterm"]
    # ⚠ THE FIRST FOUR SECONDS ARE THE INTRO — pad alone, no drums — and a
    #   3 s window sitting on them reads about 12 dB below the body of the
    #   track. Including them made the untouched mix's span LOOK like 12.4 dB
    #   next to a measured loudness RANGE of 3.7 LU, two numbers on screen that
    #   appear to contradict each other. The chart shows the body of the track
    #   and says so.
    t = np.array(s["t"])
    keep = t >= 4.5
    tt = t[keep]
    f = fig()
    ax = f.add_axes([0.075, 0.155, 0.90, 0.69])
    series = (("dry", CYAN, "the mix, untouched"),
              ("mastered", WARM, "compressor + limiter (−14)"),
              ("loudwar", VIOLET, "the same chain, chasing −8"))
    for k, c, lab in series:
        ax.plot(tt, np.array(s[k])[keep], color=c, lw=2.8, label=lab)
    ax.set_xlabel("seconds")
    ax.set_ylabel("short-term level, 3 s window (dB RMS)")
    ax.set_xlim(tt.min(), tt.max() * 1.045)
    ax.grid(True, lw=0.8)
    ax.legend(loc="lower left", facecolor="#11151C", edgecolor="#232A36",
              labelcolor=FG, fontsize=18)
    xa = tt.max() * 1.012
    for k, c, _ in series:
        v = np.array(s[k])[keep]
        ax.annotate("", xy=(xa, v.max()), xytext=(xa, v.min()),
                    arrowprops=dict(arrowstyle="<->", color=c, lw=2.0))
        ax.text(xa - 0.35, (v.max() + v.min()) / 2, f"{v.max() - v.min():.1f} dB",
                color=c, fontsize=17, ha="right", va="center")
    f.text(0.075, 0.90, "THE SAME PERFORMANCE, FLATTENED",
           fontsize=27, color=WARM, weight="bold")
    f.text(0.075, 0.045, "RMS in a three-second window — not LUFS, and labelled that "
           "way on purpose;\nthe intro, before the drums, is left out. The shape is "
           "the point.", fontsize=18, color=DIM)
    save(f, "chart-overtime")


if __name__ == "__main__":
    waveform(); flattop(); masters(); ladder(); bill(); gr(); overtime()
