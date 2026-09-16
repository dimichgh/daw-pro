#!/usr/bin/env python3
"""THE ATTENTION MARKER: a real-time playhead over a MEASURED envelope.

⭐ The curve is not drawn. It is the analytic envelope of the ACTUAL RENDER,
band-passed around 1320 Hz — the frequency where the root's third harmonic and
the fifth's second harmonic collide, which is where a mistuned fifth's beating
physically happens. envelopes.npz is written by measure.py and read here; the
same array produced the depth figure the film says out loud.

⭐ THE SHADED WINDOWS ARE DERIVED, NEVER CHOSEN BY EYE. Every stretch where the
measured envelope falls below half its own median is shaded — those are the
instants where the two partials are cancelling, i.e. exactly where there is
something to hear. Choosing them by eye is how a marker ends up marking a moment
where nothing happens.

⚠ run_time MUST equal the audio laid under it. Each half is HALF seconds long
and bursts.py drops ab-fifth-pure.wav at 0 and ab-fifth-et.wav at HALF, read
from the offsets __main__ prints.

⚠ NO LaTeX; hand-placed Text ticks only.
"""
import json, os
import numpy as np
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
HALF = 8.0
FS = 1000.0
FONT = "Helvetica Neue"
BG = "#080B10"
CYAN, VIOLET, WARM, DIM, RED = "#5AD1FF", "#A78BFA", "#7DF9D6", "#7C8798", "#FF6B6B"


def T(*a, **kw):
    return Text(*a, font=FONT, **kw)


def trace(key):
    z = np.load(f"{HERE}/envelopes.npz")
    e = np.asarray(z[key], dtype=float)[:int(HALF * FS)]
    return e / max(float(e.max()), 1e-12)


def windows(e, thresh=0.5, min_ms=40, skip_ms=120):
    """Stretches where the measured envelope is below half its own median.

    ⚠ THE FIRST 120 ms ARE SKIPPED. The note's own attack ramp starts at zero
    and is trivially "below half the median" — it was reported as a listening
    window in the first pass, which would have shaded the one instant where
    there is nothing to compare."""
    m = float(np.median(e))
    below = e < thresh * m
    below[:int(skip_ms / 1000 * FS)] = False
    out, i = [], 0
    while i < len(below):
        if below[i]:
            j = i
            while j < len(below) and below[j]:
                j += 1
            if (j - i) / FS * 1000 >= min_ms:
                out.append((i / FS, j / FS))
            i = j
        else:
            i += 1
    return out


class FifthMarker(Scene):
    def construct(self):
        self.camera.background_color = BG
        pure, temp = trace("fifth_pure"), trace("fifth_et")
        wins = windows(temp)

        ax = Axes(x_range=[0, HALF, 1], y_range=[0, 1.15, 0.25],
                  x_length=11.4, y_length=4.0,
                  axis_config={"color": "#39424F", "stroke_width": 2},
                  # ⚠ PUSHED UP. In the first render the three-line caption
                  # ran straight through the x-axis tick labels — looked at,
                  # then fixed by moving the plot rather than shrinking the text.
                  tips=False).move_to(UP * 0.45)
        xt = VGroup(*[T(f"{v:.0f}", font_size=17, color=DIM)
                      .move_to(ax.c2p(v, 0) + DOWN * 0.3)
                      for v in range(0, int(HALF) + 1)])
        xl = T("seconds", font_size=18, color=DIM).next_to(xt, DOWN, buff=0.05)
        xl.align_to(ax, RIGHT)
        yl = T("level of the 1320 Hz partial", font_size=17, color=DIM)
        yl.rotate(PI / 2).next_to(ax, LEFT, buff=0.28)

        title = T("MEASURED OFF THE RENDER YOU ARE HEARING", font_size=25, color=DIM)
        title.to_edge(UP, buff=0.4).to_edge(LEFT, buff=0.7)

        def curve(e, colour):
            t = np.arange(len(e)) / FS
            return VMobject(color=colour, stroke_width=3).set_points_as_corners(
                [ax.c2p(a, b) for a, b in zip(t[::4], e[::4])])

        head = ValueTracker(0.0)
        ph = always_redraw(lambda: Line(ax.c2p(head.get_value(), 0),
                                        ax.c2p(head.get_value(), 1.15),
                                        color=WHITE, stroke_width=3))

        cap = always_redraw(lambda: T("", font_size=1))   # replaced per phase
        self.add(ax, xt, xl, yl, title)

        # ---- phase 1: the pure fifth, which cannot beat -------------------
        c1 = curve(pure, CYAN)
        l1 = VGroup(T("A pure fifth: 440.000 and 660.000 Hz", font_size=24, color=CYAN),
                    T("exactly three to two — the harmonics land on each other",
                      font_size=20, color=DIM),
                    T("nothing to hear: the line is flat", font_size=21, color=WARM),
                    ).arrange(DOWN, aligned_edge=LEFT, buff=0.14)
        l1.to_edge(DOWN, buff=0.32).to_edge(LEFT, buff=0.8)
        self.add(c1, l1, ph)
        self.play(head.animate.set_value(HALF), run_time=HALF, rate_func=linear)

        # ---- phase 2: the tempered fifth ---------------------------------
        self.remove(c1, l1)
        head.set_value(0.0)
        c2 = curve(temp, VIOLET)
        shades = VGroup(*[Rectangle(
            width=ax.c2p(b, 0)[0] - ax.c2p(a, 0)[0],
            height=ax.c2p(0, 1.15)[1] - ax.c2p(0, 0)[1],
            stroke_width=0, fill_color=RED, fill_opacity=0.16)
            .move_to((ax.c2p(a, 0) + ax.c2p(b, 1.15)) / 2) for a, b in wins])
        l2 = VGroup(T("The tempered fifth: 440.000 and 659.255 Hz", font_size=24,
                      color=VIOLET),
                    T("narrowed by 1.955 cents so the circle can close",
                      font_size=20, color=DIM),
                    T(f"listen in the shaded dips — {len(wins)} of them in "
                      f"{HALF:.0f} seconds", font_size=21, color=RED),
                    ).arrange(DOWN, aligned_edge=LEFT, buff=0.14)
        l2.to_edge(DOWN, buff=0.32).to_edge(LEFT, buff=0.8)
        self.add(shades, c2, l2, ph)
        self.play(head.animate.set_value(HALF), run_time=HALF, rate_func=linear)


if __name__ == "__main__":
    e = trace("fifth_et")
    w = windows(e)
    print(json.dumps({
        "total": 2 * HALF,
        "audio": [{"wav": "ab-fifth-pure.wav", "atSec": 0.0},
                  {"wav": "ab-fifth-et.wav", "atSec": HALF}],
        "windows": len(w),
        "firstWindow": w[0] if w else None,
        "pureWindows": len(windows(trace("fifth_pure")))}))
