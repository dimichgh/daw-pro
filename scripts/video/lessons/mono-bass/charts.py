#!/usr/bin/env python3
"""L8 rebuild — PASS 3a: the matplotlib charts, all of them MEASURED.

Every point plotted here is read out of MEASUREMENTS.json, which measure.py
wrote off the renders. Nothing is illustrated. Where a prediction is shown it
is the closed form 20*log10|cos(pi f tau)| evaluated in measure.py, drawn as a
separate line so the viewer can see the two agree rather than being told.

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

BG, FG, DIM = "#0B0D12", "#EEF2FF", "#7C8798"
CYAN, VIOLET, WARM, AMBER, RED = "#5AD1FF", "#A78BFA", "#7DF9D6", "#FFB84D", "#FF6B6B"
plt.rcParams.update({
    "figure.facecolor": BG, "axes.facecolor": BG, "savefig.facecolor": BG,
    "text.color": FG, "axes.labelcolor": DIM, "xtick.color": DIM,
    "ytick.color": DIM, "axes.edgecolor": "#232A36", "grid.color": "#1A2029",
    "font.size": 17, "axes.titlesize": 26, "figure.dpi": 100,
})


def fig():
    f = plt.figure(figsize=(19.2, 10.8))
    return f


def save(f, name):
    p = os.path.join(SH, name + ".png")
    f.savefig(p, dpi=100)
    plt.close(f)
    print(f"  {name}.png")


# ------------------------------------------------------- 1. the comb spectrum
def comb():
    p = M["_psd"]
    hz = np.array(p["hz"])
    f = fig()
    ax = f.add_axes([0.075, 0.13, 0.90, 0.72])
    ax.semilogx(hz, p["predicted6_db"], color=DIM, lw=2.0, ls="--",
                label="predicted:  20·log10 |cos(π f τ)|,  τ = 6 ms")
    ax.semilogx(hz, p["ratio6_db"], color=CYAN, lw=2.6,
                label="measured:  6 ms mono fold ÷ 0 ms mono fold")
    ax.set_xlim(28, 1100)
    ax.set_ylim(-46, 8)
    ax.grid(True, which="both", lw=0.8)
    ax.set_xlabel("frequency (Hz)")
    ax.set_ylabel("change when summed to mono (dB)")
    ax.set_xticks([30, 50, 80, 100, 200, 300, 500, 800, 1000])
    ax.set_xticklabels(["30", "50", "80", "100", "200", "300", "500", "800", "1k"])
    ax.axhline(0, color="#39424F", lw=1.2)
    for k, nz in enumerate(M["comb_nulls_hz_6ms"]):
        if nz > 1000:
            continue
        ax.axvline(nz, color=RED, lw=1.0, alpha=0.55)
        ax.text(nz, 5.0, f"{nz:g} Hz", color=RED, ha="center", fontsize=15)
    ax.text(0.012, 0.92, "every odd notch is a cancellation; between them, nothing is lost",
            transform=ax.transAxes, color=DIM, fontsize=17)
    ax.legend(loc="lower right", facecolor="#11151C", edgecolor="#232A36",
              labelcolor=FG, fontsize=17)
    f.text(0.075, 0.90, "WHAT SUMMING TO MONO DID, ACROSS THE WHOLE SPECTRUM",
           fontsize=27, color=WARM, weight="bold")
    f.text(0.075, 0.045, "measured off the two renders — the only difference between "
           "them is six milliseconds on one track", fontsize=17, color=DIM)
    save(f, "chart-comb")


# ------------------------------------------------ 2. per note: 9 predictions
def pernote():
    rows = M["per_note_fundamental_fold_db"]
    names = {41.2: "E1", 55.0: "A1", 61.74: "B1", 73.42: "D2", 82.41: "E2",
             92.5: "F#2", 98.0: "G2", 110.0: "A2", 130.81: "C3"}
    lab = [f"{names.get(round(r['hz'], 2), '')}\n{r['hz']:.1f} Hz" for r in rows]
    x = np.arange(len(rows))
    f = fig()
    ax = f.add_axes([0.075, 0.16, 0.90, 0.68])
    ax.bar(x - 0.19, [r["predicted_db"] for r in rows], 0.36, color="#2F3B4C",
           label="predicted, before anything was rendered")
    ax.bar(x + 0.19, [r["measured_db"] for r in rows], 0.36, color=CYAN,
           label="measured off the render")
    for i, r in enumerate(rows):
        ax.text(i + 0.19, r["measured_db"] - 1.4, f"{r['measured_db']:.1f}",
                ha="center", va="top", color=FG, fontsize=15)
    ax.set_xticks(x)
    ax.set_xticklabels(lab)
    ax.set_ylim(-40, 3)
    ax.set_ylabel("fundamental, lost to the mono fold (dB)")
    ax.grid(True, axis="y", lw=0.8)
    ax.axhline(0, color="#39424F", lw=1.2)
    ax.legend(loc="lower left", facecolor="#11151C", edgecolor="#232A36",
              labelcolor=FG, fontsize=17)
    j = int(np.argmin([r["measured_db"] for r in rows]))
    ax.annotate("E2 sits on the notch", xy=(j, rows[j]["measured_db"]),
                xytext=(j - 2.6, -30), color=RED, fontsize=19,
                arrowprops=dict(color=RED, arrowstyle="->", lw=2))
    f.text(0.075, 0.90, "THE SAME DELAY. NINE NOTES. THIRTY-THREE dB OF DIFFERENCE.",
           fontsize=27, color=WARM, weight="bold")
    f.text(0.075, 0.045, "E1 and E2 are the same note one octave apart — and one of "
           "them survives the fold almost untouched", fontsize=17, color=DIM)
    save(f, "chart-pernote")


# ------------------------------------------- 3. one note, harmonic by harmonic
def harmonics():
    rows = M["e2_harmonics"]
    x = np.arange(1, len(rows) + 1)
    f = fig()
    ax = f.add_axes([0.075, 0.16, 0.90, 0.68])
    cols = [RED if r["measured_db"] < -6 else WARM for r in rows]
    ax.bar(x, [r["measured_db"] for r in rows], 0.55, color=cols)
    ax.plot(x, [r["predicted_db"] for r in rows], "o", color=DIM, ms=11,
            label="predicted")
    for r, xi in zip(rows, x):
        ax.text(xi, min(r["measured_db"], 0) - 1.2,
                f"{r['hz']:.0f} Hz", ha="center", va="top", color=DIM, fontsize=15)
        ax.text(xi, min(r["measured_db"], 0) - 3.6,
                f"{r['measured_db']:+.1f}", ha="center", va="top", color=FG, fontsize=16)
    ax.set_xticks(x)
    ax.set_xticklabels([f"harmonic {i}" if i == 1 else str(i) for i in x])
    ax.set_ylim(-40, 4)
    ax.set_ylabel("change when summed to mono (dB)")
    ax.grid(True, axis="y", lw=0.8)
    ax.axhline(0, color="#39424F", lw=1.2)
    ax.legend(loc="lower right", facecolor="#11151C", edgecolor="#232A36",
              labelcolor=FG, fontsize=17)
    f.text(0.075, 0.90, "ONE NOTE, HARMONIC BY HARMONIC — E2 AT 82 Hz",
           fontsize=27, color=WARM, weight="bold")
    f.text(0.075, 0.045, "the odd harmonics land in the notches and vanish; the even "
           "ones land between them and do not move at all", fontsize=17, color=DIM)
    save(f, "chart-harmonics")


# ------------------------------------------------ 4. the three offsets, folded
def offsets():
    """Plot the LOSS, not the absolute level. The first cut of this chart drew
    the absolute band levels as bars hanging down from 0 dB, so the WORST case
    was the LONGEST bar — which reads as "biggest", the opposite of the point."""
    loss = M["fold_loss_vs_0ms_db"]
    vals = [0.0, loss["6"], loss["15"]]
    f = fig()
    ax = f.add_axes([0.13, 0.17, 0.80, 0.64])
    ax.bar(range(3), vals, 0.45, color=[WARM, RED, AMBER])
    for i, v in enumerate(vals):
        ax.text(i, v - 0.8, f"{v:+.2f} dB" if i else "the control",
                ha="center", va="top", color=FG, fontsize=30, weight="bold")
    ax.set_xticks(range(3))
    ax.set_xticklabels(["no offset", "6 ms late", "15 ms late"], fontsize=23)
    ax.set_ylim(-19, 2.5)
    ax.set_ylabel("lost from the mono sum, 60–110 Hz (dB)")
    ax.grid(True, axis="y", lw=0.8)
    ax.axhline(0, color="#39424F", lw=1.4)
    f.text(0.13, 0.885, "THE BIGGER NUDGE IS NOT THE WORSE ONE",
           fontsize=27, color=WARM, weight="bold")
    f.text(0.13, 0.045, "fifteen milliseconds is two and a half times the delay and "
           "does less than a quarter of the damage", fontsize=17, color=DIM)
    save(f, "chart-offsets")


# ------------------------------- 5. what a small speaker gets, stated honestly
def audibility():
    """Two bands, one question: how much of the fault is in the part of the
    spectrum a small speaker actually radiates? Both bars are the LOSS over the
    whole render, so this chart and the headline quote the same numbers."""
    lo_loss = M["fold_loss_vs_0ms_db"]["6"]
    hi_loss = M["laptop_band"]["hp200_full_loss_db"]["6"]
    f = fig()
    ax = f.add_axes([0.12, 0.19, 0.80, 0.60])
    ax.bar([0, 1], [lo_loss, hi_loss], 0.42, color=[RED, AMBER])
    for i, v in enumerate([lo_loss, hi_loss]):
        ax.text(i, v - 0.7, f"{v:.2f} dB", ha="center", va="top",
                color=FG, fontsize=34, weight="bold")
    ax.set_xticks([0, 1])
    ax.set_xticklabels(["60–110 Hz\nthe fundamental — headphones,\nsubwoofer, "
                        "a real speaker",
                        "above 200 Hz\nroughly what a laptop\nspeaker radiates"],
                       fontsize=21)
    ax.set_ylim(-18, 1.5)
    ax.set_ylabel("lost when the 6 ms version is summed to mono (dB)")
    ax.grid(True, axis="y", lw=0.8)
    ax.axhline(0, color="#39424F", lw=1.4)
    f.text(0.12, 0.885, "HOW MUCH OF THIS YOU CAN ACTUALLY HEAR, AND WHERE",
           fontsize=27, color=WARM, weight="bold")
    # ⚠ KEEP FOOTNOTES CLEAR OF x ~ 0.72: the film burns a level meter into the
    # bottom-right corner, and the first cut of this chart had its footnote
    # running underneath it.
    f.text(0.12, 0.05, "on headphones the gap is enormous; on a laptop it is "
           "small but real — both are measured", fontsize=17, color=DIM)
    save(f, "chart-audibility")


if __name__ == "__main__":
    comb(); pernote(); harmonics(); offsets(); audibility()
