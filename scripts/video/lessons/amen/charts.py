#!/usr/bin/env python3
"""The film's static charts. Every point is read out of MEASUREMENTS.json --
nothing here is drawn by hand, and no chart states a number the file does not
contain."""
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
        # ⚠ keep footnotes clear of x≈0.72: the film burns a level meter into
        # the bottom-RIGHT corner AFTER assembly and it eats text under it.
        # Pass a "\n" and use TWO SHORT LINES rather than one long one.
        t = f.text(0.055, 0.013, foot, color=DIM, fontsize=13, ha="left",
                   va="bottom", linespacing=1.5)
    f.tight_layout(rect=(0, 0.085, 1, 1))
    f.savefig(f"{S}/{name}.png")
    # ⚠⚠ A FOOTNOTE THAT RUNS OFF THE RIGHT EDGE IS INVISIBLE TO EVERY GATE AND
    #   to the string that produced it -- I lengthened this one by one clause and
    #   shipped "The kick h|" against the frame edge, caught only by looking at
    #   the PNG. matplotlib clips silently; nothing raises. So measure the drawn
    #   extent against the figure and refuse. (Must run AFTER savefig: the text's
    #   window extent needs a renderer, which only exists once something drew.)
    if t is not None:
        e = t.get_window_extent(f.canvas.get_renderer())
        w, h = f.canvas.get_width_height()
        # ⚠⚠ AND THE FRAME EDGE IS THE WRONG LIMIT. The comment above has warned
        #   about the burned-in corner meter since the first build, and NOTHING
        #   ENFORCED IT: the footnote in the PREVIOUS BUILD OF THIS REBUILD (8/8
        #   green, never finalized) ran to x=1695 and the meter sat on its last
        #   third. A prose warning is not a gate.
        meter_x = 0.72 * w
        if e.x1 > meter_x or e.x0 < 0 or e.y0 < 0:
            raise SystemExit(
                f"REFUSING {name}.png: the footnote is drawn to x={e.x1:.0f}, past the "
                f"corner meter's keep-out at x={meter_x:.0f} of a {w}px frame. "
                f"Split it across two lines with a newline.")
    plt.close(f)
    print(f"  {name}.png")


# ── 1. the velocity law: predicted curve, measured points, layer switch named
V = M["velocity_law"]
f, ax = frame()
vv = np.array(V["snare"]["velocities"], dtype=float)
ref = V["snare"]["measured_db"][-1]
grid = np.linspace(8, 127, 400)
ax.plot(grid, ref + 40 * np.log10(grid / 127), color=DIM, lw=2.4, ls="--",
        label="predicted:  forty times log ten of (velocity ÷ 127)")
for nm, col, mk in (("snare", CYAN, "o"), ("ride", WARM, "s"),
                    ("kick", GOLD, "^"), ("hat", RED, "D")):
    d = V[nm]
    off = d["measured_db"][-1] - ref
    ax.plot(d["velocities"], np.array(d["measured_db"]) - off, mk + "-", color=col,
            lw=1.6, ms=7, alpha=0.95, label=f"measured: {nm}")
lay = [v for v in vv if M["velocity_law_snare_layer_band"][0] <= v <= M["velocity_law_snare_layer_band"][1]]
ax.axvspan(min(lay) - 2, max(lay) + 2, color="#3A2430", zorder=0)
ax.annotate(f"the snare's sample layer switches here\n"
            f"+{M['velocity_law_snare_layer_err_db']:.2f} dB off the curve",
            xy=(62, ref + 40 * np.log10(62 / 127) + 5), color=RED, fontsize=15,
            ha="center")
for v, lab, col in ((M["ghost_vs_accent"]["ghost_velocity"], "ghost note", WARM),
                    (M["ghost_vs_accent"]["accent_velocity"], "accent", CYAN)):
    ax.axvline(v, color=col, lw=1.4, ls=":")
    ax.text(v + 1.5, -56, f"{lab}\nvelocity {v}", color=col, fontsize=14)
ax.set_xlabel("MIDI velocity", fontsize=17)
ax.set_ylabel("peak level of one hit, dB (aligned at velocity 127)", fontsize=17)
ax.set_title("VELOCITY IS NOT DECIBELS — predicted first, then measured",
             color=WARM, fontsize=25, pad=16, loc="left")
ax.legend(facecolor=BG, edgecolor="#39424F", labelcolor=FG, fontsize=14, loc="upper left", bbox_to_anchor=(0.005, 0.62))
ax.set_ylim(-60, 0)
_kv = M["velocity_law"]["kick"]["velocities"]
_kd = M["velocity_law"]["kick"]["measured_db"]
_kref = _kd[_kv.index(127)]
_kerr = [(v, d - (_kref + 40 * np.log10(v / 127))) for v, d in zip(_kv, _kd)]
_kdip = [(v, e) for v, e in _kerr if e < -0.2]
_kw = min(e for _, e in _kerr)
save(f, "chart-velocity", f"Measured off {len(vv)} renders per drum. The snare agrees to "
     f"{M['velocity_law_snare_worst_err_db']:.2f} dB away from the layer switch.\n"
     f"The hat follows its own curve (up to {M['velocity_law_hat_worst_err_db']:.1f} dB off); "
     f"the kick dips {abs(_kw):.2f} dB over velocity "
     f"{min(v for v, _ in _kdip)}-{max(v for v, _ in _kdip)}.")

# ── 2. the humanize shifts, against a sixteenth for scale
H = M["humanize"]
shifts = [v for nm in M["onsets"] for v in M["onsets"][nm]["project_shift_ms"]]
f, ax = frame()
ax.bar(range(len(shifts)), shifts, color=[CYAN if s >= 0 else WARM for s in shifts], width=0.85)
for y, lab, col in ((H["max_ms_asked"], f"the jitter asked for: ±{H['max_ms_asked']:.2f} ms", DIM),
                    (-H["max_ms_asked"], None, DIM)):
    ax.axhline(y, color=col, lw=1.4, ls="--")
    if lab:
        ax.text(1, y + 1.2, lab, color=col, fontsize=14)
ax.axhline(M["sixteenth_ms"] / 2, color=RED, lw=2)
ax.text(1, M["sixteenth_ms"] / 2 + 1.6,
        f"halfway to the next step = {M['sixteenth_ms']/2:.2f} ms — past this line a hit is "
        f"closer to the wrong step than to its own", color=RED, fontsize=15)
ax.set_ylim(-62, 62)
ax.set_xlabel(f"each of the {H['notes']} hits, in time order", fontsize=17)
ax.set_ylabel("how far off the grid, milliseconds", fontsize=17)
ax.set_title("HOW FAR OFF THE GRID EVERY HIT ACTUALLY LANDED", color=WARM,
             fontsize=25, pad=16, loc="left")
save(f, "chart-humanize",
     f"Largest {H['project_max_abs_ms']:.2f} ms, average {H['project_mean_abs_ms']:.2f} ms — "
     f"{H['max_as_pct_of_sixteenth']:.1f} % and {H['mean_as_pct_of_sixteenth']:.1f} % of one "
     f"sixteenth note.")   # ⚠ kept short: the burned-in corner meter eats bottom
                           #   text past about x = 0.72 of the frame width.

# ── 3. the honest audibility chart. ONE quantity per bar, plus what a loudness
#      meter says about the same pair -- which is the point of the picture.
D, LU = M["diff_rel_db"], M["lufs_delta"]
rows = [("ghost notes\nquiet snare hits added", "ghosts", CYAN),
        ("bar four\nthe pattern stops repeating", "bar3", WARM),
        (f"the snare dragged\n{M['drag']['asked_ms']:.0f} ms late", "drag", GOLD),
        (f"humanised\nlargest {M['humanize']['project_max_abs_ms']:.1f} ms", "humanize", RED)]
f, ax = frame()
y = np.arange(len(rows))
ax.barh(y - 0.18, [D[r[1]] for r in rows], color=[r[2] for r in rows], height=0.34,
        label="how much of the signal actually changed")
ax.barh(y + 0.18, [abs(LU[r[1]]) for r in rows], color="#39424F", height=0.34,
        label="what a loudness meter sees (integrated LUFS)")
ax.set_yticks(y); ax.set_yticklabels([r[0] for r in rows], fontsize=15)
ax.invert_yaxis()
for i2, r in enumerate(rows):
    v = D[r[1]]
    ax.text(v + (0.6 if v >= 0 else -0.6), i2 - 0.18, f"{v:+.1f} dB", color=r[2],
            fontsize=16, va="center", ha="left" if v >= 0 else "right")
    ax.text(abs(LU[r[1]]) + 0.6, i2 + 0.18, f"{LU[r[1]]:+.1f} LU", color=DIM,
            fontsize=15, va="center")
ax.axvline(1.0, color=GOLD, lw=2, ls="--")
ax.text(1.4, -0.62, "one decibel — the smallest loudness\nchange people reliably notice",
        color=GOLD, fontsize=14, va="top")
ax.set_xlim(-27, 9)
ax.set_xlabel("decibels, relative to the drums' own level", fontsize=17)
ax.set_title("ALL FOUR CHANGED THE MUSIC.\nA LOUDNESS METER SEES NONE OF THEM.",
             color=WARM, fontsize=26, pad=18, loc="left")
ax.legend(facecolor=BG, edgecolor="#39424F", labelcolor=FG, fontsize=14, loc="lower right")
save(f, "chart-audibility",
     "Left bar: the level of (one version minus the other) against the\n"
     "material's own level. Right bar: the same pair's integrated-loudness difference.")
print("charts done")
