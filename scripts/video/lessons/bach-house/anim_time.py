#!/usr/bin/env python3
"""THE ATTENTION MARKER: say WHEN to listen and WHERE in the spectrum.

Four MEASURED band envelopes of `full.wav` — the render the viewer is hearing —
one per layer, each in the band that layer actually occupies, with a real-time
playhead crossing all four and each layer's arrival shaded.

⭐ THE WINDOWS ARE DERIVED, NOT CHOSEN BY EYE: each shaded block is the bar
after that layer's first note against the bar before it, at the layer's OWN hit
positions, and the step in decibels is measured, not asserted (measure.py).

⭐ AND THE WHOLE-MIX FIGURE IS CARRIED AS THE CONTRAST, because it is the wrong
instrument and saying so is the point: the hats move the whole mix by
-0.03 dB and their own band by more than twenty.

⚠ run_time == the audio under it: full.wav is 30.968 s and so is this.
⚠ No LaTeX; hand-placed Text only. Readouts use .become().
"""
import json, os
import numpy as np
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))["marker"]
Z = np.load(f"{HERE}/envelopes.npz")
FPS = M["fps"]
TOTAL = M["seconds"]
BAR_S = M["barSeconds"]
ORDER = M["order"]

FONT = "Helvetica Neue"
BG = "#080B10"
DIM, WHITEC = "#7C8798", "#EEF2FF"
COL = {"kick": "#FFC77A", "hats": "#5AD1FF", "clap": "#7DF9D6", "bass": "#A78BFA"}
XL, XR = -4.55, 6.30
ROW_Y = [2.35, 0.85, -0.65, -2.15]
ROW_H = 1.05


def T(*a, **kw):
    return Text(*a, font=FONT, **kw)


def x(t):
    return XL + (XR - XL) * t / TOTAL


class BuildMarker(Scene):
    def construct(self):
        self.camera.background_color = BG
        title = T("WHERE EACH PART LANDS — MEASURED OFF THE RENDER YOU ARE HEARING",
                  font_size=23, color=DIM)
        title.to_edge(UP, buff=0.28).to_edge(LEFT, buff=0.55)
        self.add(title)

        shades = VGroup()
        for i, k in enumerate(ORDER):
            e = np.asarray(Z[k], dtype=float)
            e = e / max(float(e.max()), 1e-12)
            yy = ROW_Y[i]
            self.add(Line([XL, yy, 0], [XR, yy, 0], color="#212934", stroke_width=2))
            t = np.arange(len(e)) / FPS
            self.add(VMobject(color=COL[k], stroke_width=2.2).set_points_as_corners(
                [[x(a), yy + b * ROW_H, 0] for a, b in zip(t[::2], e[::2])]))
            st = M["entrySteps"][k]
            # ⚠ THREE SHORT RIGHT-ALIGNED LINES. One long label ran off the LEFT
            # edge of the frame and photographed as "K 20-110 Hz" / "00-16000 Hz"
            # — found by looking at frame 700 of the first render.
            self.add(T(k.upper(), font_size=20, color=COL[k])
                     .move_to([XL - 0.15, yy + 0.66, 0], aligned_edge=RIGHT))
            self.add(T(band_label(st["band"]), font_size=16, color=DIM)
                     .move_to([XL - 0.15, yy + 0.34, 0], aligned_edge=RIGHT))
            self.add(T(f"enters bar {st['entryBar']}", font_size=14, color=DIM)
                     .move_to([XL - 0.15, yy + 0.05, 0], aligned_edge=RIGHT))
            t0 = st["entrySeconds"]
            shades.add(Rectangle(width=x(t0 + BAR_S) - x(t0), height=ROW_H,
                                 stroke_width=0, fill_color=COL[k], fill_opacity=0.22)
                       .move_to([(x(t0) + x(t0 + BAR_S)) / 2, yy + ROW_H / 2, 0]))
            shades.add(Line([x(t0), yy - 0.1, 0], [x(t0), yy + ROW_H, 0],
                            color=COL[k], stroke_width=2))
        self.add(shades)

        for s in range(0, int(TOTAL) + 1, 5):
            self.add(T(f"{s}", font_size=15, color=DIM).move_to([x(s), -3.22, 0]))
        # ⚠ "seconds" goes ABOVE the axis at the right, not below it: the corner
        # meter is burned into the bottom-right 340x48 of the finished frame.
        self.add(T("seconds", font_size=15, color=DIM)
                 .move_to([x(TOTAL) - 0.05, -2.95, 0], aligned_edge=RIGHT))

        head = ValueTracker(0.0)
        ph = always_redraw(lambda: Line([x(head.get_value()), -3.15, 0],
                                        [x(head.get_value()), 3.05, 0],
                                        color=WHITEC, stroke_width=3))
        self.add(ph)

        # ⚠ NEVER Text("") — no points, and .move_to raises. See anim_loops.py.
        read = T("\u00b7", font_size=24, color=BG)
        read.move_to([XL - 0.15, -3.66, 0], aligned_edge=LEFT)
        self.add(read)

        marks = [(M["entrySeconds"][k], k) for k in ORDER]
        cursor = 0.0
        for t0, k in marks:
            if t0 > cursor:
                self.play(head.animate.set_value(t0), run_time=t0 - cursor,
                          rate_func=linear)
                cursor = t0
            st = M["entrySteps"][k]
            # ⚠ SHORT, AND LEFT-ALIGNED. The corner meter is burned into
            # x 1544-1884, y 996-1044 of the finished 1920x1080 frame — manim
            # units x 4.33-6.84, y -3.73 to -3.38. The first version of this
            # readout ran straight through it. Measured from meter.py's own
            # W_M/H_M/MARGIN, not estimated off a screenshot.
            read.become(T(f"{k.upper()} IN \u2014 own band "
                          f"{st['onHitsStepDb']:+.2f} dB   \u00b7   whole mix "
                          f"{M['wholeMixSteps'][k]:+.2f} dB",
                          font_size=22, color=COL[k])
                        .move_to([XL - 0.15, -3.66, 0], aligned_edge=LEFT))
        self.play(head.animate.set_value(TOTAL), run_time=TOTAL - cursor,
                  rate_func=linear)


def band_label(b):
    """20-110 Hz · 900 Hz-9 kHz · 6-16 kHz — units on the number that needs them."""
    lo, hi = b
    u = lambda v: f"{v/1000:g} kHz" if v >= 1000 else f"{v} Hz"
    if hi < 1000:
        return f"{lo}-{hi} Hz"
    if lo >= 1000:
        return f"{lo/1000:g}-{hi/1000:g} kHz"
    return f"{lo} Hz-{hi/1000:g} kHz"


if __name__ == "__main__":
    print(json.dumps({
        "total": TOTAL,
        "audio": [{"wav": "full.wav", "atSec": 0.0}],
        "entrySeconds": M["entrySeconds"],
        "steps": {k: M["entrySteps"][k]["onHitsStepDb"] for k in ORDER},
        "wholeMix": M["wholeMixSteps"],
    }))
