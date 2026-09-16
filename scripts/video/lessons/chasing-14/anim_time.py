#!/usr/bin/env python3
"""THE ATTENTION MARKER: a playhead sweeping a MEASURED chart at real time.

The answer to "I could not hear it" is not *listen harder*; it is to say WHEN
to listen and WHERE — and, when the honest answer is that you cannot hear it at
all, to show exactly how far under the music it is sitting.

Both pairs of curves are 30 ms RMS levels measure.py computed off the renders:
the MUSIC, and the DISTORTION that the same file's clipping added. Nothing here
is drawn by hand.

⚠ THE SHADED WINDOWS ARE DERIVED, NEVER CHOSEN BY EYE. measure.py keeps every
stretch where the −5 LUFS master's distortion comes within 40 dB of its own
music, merges gaps under 150 ms and drops anything under 200 ms. The 40 dB is a
stated rule of thumb about small speakers, and the film says so out loud.

⚠ run_time MUST equal the span of audio laid underneath. __main__ prints the
sweep offsets as JSON and bursts.py builds the audio from them.

⚠ No LaTeX here: every tick label is a hand-placed Text.
"""
import json, os
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(os.path.join(HERE, "MEASUREMENTS.json")))
K = M["_chart"]["marker"]
T_MAX = K["seconds"]
LEAD, TAG, GAP, TAIL = 1.2, 1.6, 0.5, 2.2

FONT = "Helvetica Neue"
BG = "#080B10"
CYAN, RED, WARM, DIM, SHADE, AMBER = ("#5AD1FF", "#FF6B6B", "#7DF9D6",
                                      "#7C8798", "#1B2733", "#FFB84D")
Y0, Y1 = -62, 4


def T(*a, **kw):
    return Text(*a, font=FONT, **kw)


class ClipOverTime(Scene):
    def construct(self):
        self.camera.background_color = BG
        ax = Axes(x_range=[0, T_MAX, 1.0], y_range=[Y0, Y1, 15],
                  x_length=10.8, y_length=4.35,
                  axis_config={"color": "#39424F", "stroke_width": 2},
                  tips=False)
        ax.to_edge(DOWN, buff=1.78)
        labels = VGroup()
        for xv in range(0, int(T_MAX) + 1):
            labels.add(T(f"{xv}", font_size=18, color=DIM)
                       .next_to(ax.c2p(xv, Y0), DOWN, buff=0.14))
        for yv in (-60, -45, -30, -15, 0):
            labels.add(T(f"{yv}", font_size=18, color=DIM)
                       .next_to(ax.c2p(0, yv), LEFT, buff=0.14))
        self.add(ax, labels)
        # ⚠ ROTATE FIRST, THEN PLACE — next_to() measures the CURRENT bounding
        # box, so rotating after placing swings the label off frame.
        self.add(T("the clipping, relative to the music (dB)", font_size=21,
                   color=DIM).rotate(PI / 2)
                 .next_to(ax, LEFT, buff=0.18).shift(LEFT * 0.5))
        self.add(T("seconds", font_size=20, color=DIM)
                 .next_to(ax, DOWN, buff=0.30).shift(RIGHT * 1.6))
        self.add(T("HOW FAR UNDER THE MUSIC THE CLIPPING SITS",
                   font_size=33, color=WARM).to_edge(UP, buff=0.30))

        for a, b in K["windows"]:
            self.add(Polygon(ax.c2p(a, Y0), ax.c2p(b, Y0), ax.c2p(b, Y1), ax.c2p(a, Y1),
                             stroke_width=0, fill_color=SHADE,
                             fill_opacity=1).set_z_index(-2))

        self.wait(LEAD)

        def trace(vals, col, width, dash=False):
            v = VMobject(color=col, stroke_width=width)
            v.set_points_smoothly([ax.c2p(t, max(min(g, Y1), Y0))
                                   for t, g in zip(K["t"], vals)])
            return v

        thr = DashedLine(ax.c2p(0, K["nearThresholdDb"]),
                         ax.c2p(T_MAX, K["nearThresholdDb"]),
                         color="#8A94A6", stroke_width=2.4, dash_length=0.12)
        # ⚠ CAPTIONS GO UNDER THE AXES, NOT ON THEM. The first cut wrote both
        #   of these across the middle of the plot, straight through the curve.
        #   ⚠ And they stay LEFT of about x = 0.72 of the frame: the film burns
        #   a level meter into the bottom-right corner after assembly.
        note = VGroup(
            T("dashed line — roughly 40 dB under the music, about where a small",
              font_size=17, color="#8A94A6"),
            T("speaker stops delivering it. A rule of thumb, not a measurement.",
              font_size=17, color="#8A94A6"),
            T("−60 is this chart's floor: below it there is no clipping at all.",
              font_size=17, color="#4E5766"),
        # ⚠ SMALLER AND LOWER, and the "seconds" axis label raised to meet it:
        #   at 19 pt in the corner these three lines reached the same pixel row
        #   as the x-axis label, and the frame read "…about where a small
        #   seconds speaker stops delivering it". Found by looking at a frame.
        ).arrange(DOWN, buff=0.07, aligned_edge=LEFT)
        note.to_corner(DL, buff=0.22)
        self.add(thr, note)

        head = Line(ax.c2p(0, Y0), ax.c2p(0, Y1), color=WARM, stroke_width=2.6)
        prior = None
        for tag, col, name, note in (
                ("g14", CYAN, "chasing −14 LUFS",
                 f'it never gets closer than {abs(K["g14"]["closestDb"]):.0f} dB '
                 f'under the music'),
                ("g5", RED, "chasing −5 LUFS",
                 f'now it reaches the music itself — listen in the shaded bars')):
            curve = trace(K[tag]["nearness"], col, 4.4)
            tagg = VGroup(T(name, font_size=28, color=col),
                          T(note, font_size=21, color=col)).arrange(DOWN, buff=0.12)
            tagg.next_to(ax, UP, buff=0.20)
            if prior:
                self.play(FadeOut(prior), run_time=0.35)
            self.play(FadeIn(tagg), run_time=TAG)
            head.move_to(ax.c2p(0, (Y0 + Y1) / 2))
            self.add(head)
            self.play(Create(curve),
                      head.animate.move_to(ax.c2p(T_MAX, (Y0 + Y1) / 2)),
                      run_time=T_MAX, rate_func=linear)
            self.remove(head)
            prior = VGroup(tagg, curve)
            self.wait(GAP)
        self.wait(TAIL)


if __name__ == "__main__":
    a = LEAD + TAG
    b = a + T_MAX + GAP + 0.35 + TAG
    total = b + T_MAX + GAP + TAIL
    print(json.dumps({"scene": "ClipOverTime", "tMax": T_MAX,
                      "total": round(total, 3),
                      "audio": [{"wav": "ab-clip14.wav", "atSec": round(a, 3)},
                                {"wav": "ab-clip5.wav", "atSec": round(b, 3)}],
                      "windows": K["windows"]}, indent=1))
