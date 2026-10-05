#!/usr/bin/env python3
"""THE ATTENTION MARKER: a playhead sweeping a MEASURED chart at real time.

The film's headline lives below 60 Hz, which is the band the viewer's laptop
cannot deliver. So rather than asking anyone to listen harder, this says WHEN
the thing arrives and WHERE it is, and draws it.

Two curves, both 40 ms RMS levels measure.py computed off the SAME twelve
seconds of the techno render that plays underneath:

  * the level BELOW 60 Hz — the thing being claimed
  * the level ABOVE 100 Hz — the CONTROL. It barely moves, which is what proves
    that the change at seven and a half seconds is only at the bottom.

⚠ THE SHADED WINDOW IS DERIVED, NEVER CHOSEN BY EYE. measure.py keeps every
stretch where the sub-60 trace stands more than 15 dB above its own pre-sub
baseline, merges gaps under 150 ms and drops anything under 250 ms.

⚠ The layer-arrival marks are measured off each STEM's first non-silent sample,
not read off the score — a part that failed to render would move the mark.

⚠ NO LaTeX: every tick label is a hand-placed Text.
⚠ run_time MUST equal the audio laid under it. __main__ prints the offset.
"""
import json, os
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(os.path.join(HERE, "MEASUREMENTS.json")))
K = M["marker"]
T_MAX = K["seconds"]
HOP = K["hopSeconds"]
LEAD, TAG, TAIL = 1.4, 2.0, 2.2

FONT = "Helvetica Neue"
BG = "#080B10"
LOW_C, HIGH_C, WARM, DIM, SHADE = "#FFB84D", "#5AD1FF", "#7DF9D6", "#7C8798", "#1B2733"
Y0, Y1 = -70, -10


def T(*a, **kw):
    return Text(*a, font=FONT, **kw)


class SubOverTime(Scene):
    def construct(self):
        self.camera.background_color = BG
        ax = Axes(x_range=[0, T_MAX, 1.0], y_range=[Y0, Y1, 10],
                  x_length=10.8, y_length=4.2,
                  axis_config={"color": "#39424F", "stroke_width": 2},
                  tips=False)
        ax.to_edge(DOWN, buff=1.85)
        labels = VGroup()
        for xv in range(0, int(T_MAX) + 1):
            labels.add(T(f"{xv}", font_size=18, color=DIM)
                       .next_to(ax.c2p(xv, Y0), DOWN, buff=0.14))
        for yv in (-70, -60, -50, -40, -30, -20, -10):
            labels.add(T(f"{yv}", font_size=18, color=DIM)
                       .next_to(ax.c2p(0, yv), LEFT, buff=0.14))
        self.add(ax, labels)
        # ⚠ ROTATE FIRST, THEN PLACE — next_to() measures the CURRENT bounding
        # box, so rotating after placing swings the label off frame.
        self.add(T("level in that band (dBFS)", font_size=21, color=DIM)
                 .rotate(PI / 2).next_to(ax, LEFT, buff=0.18).shift(LEFT * 0.5))
        self.add(T("seconds from the top of the track", font_size=20, color=DIM)
                 .next_to(ax, DOWN, buff=0.34).shift(RIGHT * 1.9))
        self.add(T("WHERE THE BOTTOM OCTAVE ARRIVES", font_size=33, color=WARM)
                 .to_edge(UP, buff=0.30))

        for a, b in K["windows"]:
            self.add(Polygon(ax.c2p(a, Y0), ax.c2p(b, Y0), ax.c2p(b, Y1),
                             ax.c2p(a, Y1), stroke_width=0, fill_color=SHADE,
                             fill_opacity=1).set_z_index(-2))

        # the layer arrivals, measured off the stems
        marks = VGroup()
        for name, tsec in sorted(K["onsets"].items(), key=lambda kv: kv[1]):
            # skip anything in the first half second — the riff starts at 0.23 s
            # and its label lands on top of the y-axis numbers
            if tsec > T_MAX or tsec < 0.5:
                continue
            marks.add(DashedLine(ax.c2p(tsec, Y0), ax.c2p(tsec, Y1 - 4),
                                 color="#4E5766", stroke_width=1.8,
                                 dash_length=0.09))
            marks.add(T(name.lower(), font_size=17, color="#8A94A6")
                      .next_to(ax.c2p(tsec, Y1 - 4), UP, buff=0.06))
        self.add(marks)

        # ⚠ CAPTIONS UNDER THE AXES, LEFT-ALIGNED, clear of x ≈ 0.72 where the
        # film burns a level meter into the corner after assembly.
        note = VGroup(
            T("Shaded — worked out from the measurements, not chosen by eye:",
              font_size=17, color="#8A94A6"),
            T("every stretch where the bottom band stands more than fifteen",
              font_size=17, color="#8A94A6"),
            T("decibels above where it sat before the sub arrived.",
              font_size=17, color="#8A94A6"),
        ).arrange(DOWN, buff=0.07, aligned_edge=LEFT).to_corner(DL, buff=0.22)
        self.add(note)

        self.wait(LEAD)

        # ⚠ THE KEY LIVES HERE, ABOVE THE AXES, AND IS THE CAPTION. A separate
        # legend block inside the plot was drawn straight through the curves AND
        # through the layer-arrival labels — found by looking at the frame.
        tag = VGroup(
            T("the same twelve seconds, two bands", font_size=28, color=WARM),
            T(f"below 60 Hz — it lifts {K['liftDb']:+.1f} dB when the sub arrives",
              font_size=22, color=LOW_C),
            T(f"above 100 Hz — the control; it moves {K['highLiftDb']:+.1f} dB",
              font_size=22, color=HIGH_C),
        ).arrange(DOWN, buff=0.10).next_to(ax, UP, buff=0.16)
        self.play(FadeIn(tag), run_time=TAG)

        t = [i * HOP for i in range(len(K["low"]))]

        def curve(vals, col, width):
            v = VMobject(color=col, stroke_width=width)
            v.set_points_smoothly([ax.c2p(x, max(min(g, Y1), Y0))
                                   for x, g in zip(t, vals)])
            return v

        low = curve(K["low"], LOW_C, 4.4)
        high = curve(K["high"], HIGH_C, 3.0)
        head = Line(ax.c2p(0, Y0), ax.c2p(0, Y1), color=WARM, stroke_width=2.6)
        head.move_to(ax.c2p(0, (Y0 + Y1) / 2))
        self.add(head)
        self.play(Create(low), Create(high),
                  head.animate.move_to(ax.c2p(T_MAX, (Y0 + Y1) / 2)),
                  run_time=T_MAX, rate_func=linear)
        self.remove(head)
        self.wait(TAIL)


if __name__ == "__main__":
    a = LEAD + TAG
    print(json.dumps({"scene": "SubOverTime", "tMax": T_MAX,
                      "total": round(a + T_MAX + TAIL, 3),
                      "audio": [{"wav": "play-build.wav", "atSec": round(a, 3)}],
                      "windows": K["windows"]}, indent=1))
