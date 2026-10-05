#!/usr/bin/env python3
"""Every chart in the film, drawn from MEASUREMENTS.json and envelopes.npz.

⭐ MEASURED, NOT DRAWN. Each curve here is an array the measurement pass wrote;
nothing is a hand-shaped illustration of what a beat "looks like".

⚠ BOTTOM-RIGHT IS NOT FREE. shortsmith burns a live level meter into the corner
(spec `meter: "br"`, 340x48 px inset 24 px, so about x 1556-1896 / y 1008-1056
of a 1920x1080 frame). Every chart reserves bottom=0.11 and keeps legends off
the right-hand bottom corner — a previous film in this series had the meter
eating an axis tick label and no gate saw it.
"""
import json, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
Z = np.load(f"{HERE}/envelopes.npz")
FS = 1000.0
S = f"{HERE}/shots"
BG, FG, DIM = "#080B10", "#E7ECF7", "#7C8798"
CYAN, VIOLET, WARM, RED = "#5AD1FF", "#A78BFA", "#7DF9D6", "#FF6B6B"
plt.rcParams.update({
    "figure.facecolor": BG, "axes.facecolor": BG, "savefig.facecolor": BG,
    "text.color": FG, "axes.labelcolor": FG, "xtick.color": DIM,
    "ytick.color": DIM, "axes.edgecolor": "#39424F", "font.family": "Helvetica Neue",
    "axes.titlecolor": FG, "font.size": 15,
})


def fig():
    f = plt.figure(figsize=(19.2, 10.8), dpi=100)
    return f


def save(f, name):
    p = f"{S}/{name}.png"
    f.savefig(p)
    plt.close(f)
    print(f"  {p}")


# ------------------------------------------------------- 1. the fifths ladder
def chart_ladder():
    w = M["walk"]["steps"]
    f = fig()
    ax = f.add_axes([0.08, 0.13, 0.88, 0.76])
    xs = [s["step"] for s in w]
    cents = [s["cents"] for s in w]
    meas = [1200 * np.log2(s["measuredHz"] / 440.0) for s in w]
    ax.plot(xs, cents, "o-", color=CYAN, lw=2.6, ms=9,
            label="where the arithmetic says each fifth lands")
    ax.plot(xs, meas, "x", color=WARM, ms=13, mew=2.6,
            label="where DAW Pro actually rendered it")
    ax.axhline(0, color="#39424F", lw=1.4, ls="--")
    ax.axhline(cents[-1], color=RED, lw=1.4, ls=":")
    ax.annotate("", xy=(12.35, cents[-1]), xytext=(12.35, 0),
                arrowprops=dict(arrowstyle="<->", color=RED, lw=2.2))
    ax.text(12.5, cents[-1] / 2, f'{M["material"]["comma"]:.2f} cents\nshort of home',
            color=RED, fontsize=17, va="center")
    for s in w:
        ax.annotate(["A", "E", "B", "F#", "C#", "G#", "D#", "A#", "F", "C",
                     "G", "D", "A"][s["step"]], (s["step"], s["cents"]),
                    textcoords="offset points", xytext=(0, 14), ha="center",
                    color=DIM, fontsize=13)
    ax.set_xlim(-0.6, 14.4)
    ax.set_ylim(-70, 1290)
    ax.set_xticks(range(13))
    ax.set_xlabel("how many pure fifths you have stacked")
    ax.set_ylabel("position inside the octave, in cents")
    ax.set_title("Twelve pure fifths, folded back into one octave — "
                 f'largest error between arithmetic and render: '
                 f'{M["walk"]["maxErrCents"]:.4f} cents', fontsize=21, pad=18)
    ax.legend(loc="upper left", framealpha=0, fontsize=15)
    ax.grid(color="#1A222D", lw=1)
    save(f, "chart-ladder")


# ------------------------------------------------------- 2. predicted vs measured
def chart_beats():
    B = M["beats"]
    rows = [
        ("two A's in tune\n(the control)", "unison", "full", 0.0),
        ("one A a comma sharp\n440.000 + 446.003 Hz", "comma", "full",
         B["comma"]["predictedHz"]),
        ("a pure fifth\n(the control)", "fifthPure", "band", 0.0),
        ("the tempered fifth\n440.000 + 659.255 Hz", "fifthET", "band",
         B["fifthET"]["predictedHz"]),
        ("a pure major third\n(the control)", "thirdPure", "band", 0.0),
        ("the tempered third\n440.000 + 554.365 Hz", "thirdET", "band",
         B["thirdET"]["predictedHz"]),
    ]
    f = fig()
    ax = f.add_axes([0.30, 0.13, 0.66, 0.76])
    y = np.arange(len(rows))[::-1]
    pred = [r[3] for r in rows]
    meas = []
    for _, k, w, _p in rows:
        d = B[k].get(w) or B[k]["full"]
        meas.append(d["rateHz"] if d["depth"] > 0.02 else 0.0)
    ax.barh(y + 0.19, pred, height=0.34, color="#2E4A5C", label="predicted")
    ax.barh(y - 0.19, meas, height=0.34, color=CYAN, label="measured off the render")
    for i, (p, m) in enumerate(zip(pred, meas)):
        ax.text(max(p, m) + 0.45, y[i], f"{m:.3f} Hz  (predicted {p:.3f})",
                va="center", color=FG, fontsize=15)
    ax.set_yticks(y)
    ax.set_yticklabels([r[0] for r in rows], fontsize=14)
    ax.set_xlim(0, 24)
    ax.set_xlabel("pulses per second")
    ax.set_title("Every beat rate this lesson claims, predicted and then measured\n"
                 "three of the six cannot beat at all — and measure zero",
                 fontsize=21, pad=18)
    # ⚠ NOT lower-right: that is where the longest row's own value label lands,
    # and the first render drew the legend straight through "17.461 Hz". Looked
    # at, then moved to the empty top-right block above the control rows.
    ax.legend(loc="upper right", framealpha=0, fontsize=15)
    ax.grid(axis="x", color="#1A222D", lw=1)
    save(f, "chart-beats")


# ------------------------------------------------------- 3. depth
def chart_depth():
    B = M["beats"]
    labels = ["the comma\n440 vs 446 Hz", "the tempered fifth\n440 vs 659.255 Hz",
              "the tempered third\n440 vs 554.365 Hz"]
    full = [B["comma"]["full"]["depth"], B["fifthET"]["full"]["depth"],
            B["thirdET"]["full"]["depth"]]
    band = [B["comma"]["full"]["depth"], B["fifthET"]["band"]["depth"],
            B["thirdET"]["band"]["depth"]]
    f = fig()
    ax = f.add_axes([0.09, 0.15, 0.87, 0.72])
    x = np.arange(3)
    ax.bar(x - 0.2, band, 0.38, color=VIOLET,
           label="inside the harmonic where the two tones actually collide")
    ax.bar(x + 0.2, full, 0.38, color=CYAN,
           label="in the whole sound, which is what you hear")
    for i in range(3):
        ax.text(x[i] - 0.2, band[i] * 1.14, f"{band[i]:.4f}", ha="center",
                color=VIOLET, fontsize=16)
        ax.text(x[i] + 0.2, full[i] * 1.14, f"{full[i]:.4f}", ha="center",
                color=CYAN, fontsize=16)
    ax.set_yscale("log")
    ax.set_ylim(3e-3, 4.0)
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=15)
    ax.set_ylabel("how deep the pulsing is  (1 = swings all the way to silence)")
    ratio = full[0] / full[2]
    ax.set_title("Why one of these wobbles and the others just sound rough\n"
                 f"the comma's pulsing is {ratio:.0f}x deeper in the whole sound "
                 f"than the tempered third's", fontsize=21, pad=18)
    ax.legend(loc="upper right", framealpha=0, fontsize=15)
    ax.grid(axis="y", color="#1A222D", lw=1)
    # ⚠ NOT INSIDE THE AXES. Placed under the first pair it was drawn BEHIND the
    # bars and was unreadable in the finished film — found by pulling the frame
    # at 760 s out of the mp4 and looking at it. Bottom-LEFT of the figure,
    # because bottom-right is the burned-in meter's.
    f.text(0.09, 0.045,
           "The comma's two bars are the same number, and that is the point: its "
           "beating IS the whole sound,\nso there is no separate harmonic to look "
           "inside. Every figure here came off the renders you have been hearing.",
           fontsize=15, color=DIM)
    save(f, "chart-depth")


# ------------------------------------------------------- 4. measured envelopes
def chart_envelopes():
    f = fig()
    panes = [("unison", "comma", "The comma, 440.000 against 446.003 Hz",
              M["beats"]["comma"]["full"]["rateHz"], "the whole sound"),
             ("fifth_pure", "fifth_et",
              "The tempered fifth, at the 1320 Hz harmonic",
              M["beats"]["fifthET"]["band"]["rateHz"], "one harmonic"),
             ("third_pure", "third_et",
              "The tempered third, at the 2200 Hz harmonic",
              M["beats"]["thirdET"]["band"]["rateHz"], "one harmonic")]
    for i, (ck, tk, title, rate, where) in enumerate(panes):
        ax = f.add_axes([0.07, 0.72 - i * 0.235, 0.90, 0.18])
        for k, col, lab in ((ck, "#3E6C8A", "pure — the control"),
                            (tk, RED if i else WARM, "as measured")):
            e = np.asarray(Z[k], dtype=float)[:int(4.0 * FS)]
            e = e / max(float(e.max()), 1e-12)
            ax.plot(np.arange(len(e)) / FS, e, color=col, lw=1.8, label=lab)
        ax.set_xlim(0, 4)
        ax.set_ylim(0, 1.2)
        ax.set_yticks([])
        ax.set_title(f"{title}  —  {rate:.3f} pulses a second, measured in {where}",
                     fontsize=17, loc="left", pad=6)
        if i == 2:
            ax.set_xlabel("seconds")
        else:
            ax.set_xticklabels([])
        # ⚠ NO PER-PANE LEGEND. The traces reach full height at the right-hand
        # end of every pane, so an in-axes legend sat on top of the data in all
        # three. One figure-level legend, above the panes, instead.
        if i == 0:
            f.legend(*ax.get_legend_handles_labels(), loc="upper right",
                     bbox_to_anchor=(0.97, 0.995), framealpha=0, fontsize=15,
                     ncol=2)
        ax.grid(color="#1A222D", lw=1)
    f.text(0.07, 0.955, "Four seconds of each render, as measured",
           fontsize=23, color=FG)
    f.text(0.07, 0.055, "Every flat line is a control: an exact whole-number "
                        "ratio, which cannot beat. Nothing here was drawn by hand.",
           fontsize=15, color=DIM)
    save(f, "chart-envelopes")


if __name__ == "__main__":
    chart_ladder(); chart_beats(); chart_depth(); chart_envelopes()
