#!/usr/bin/env python3
"""ATTENTION MARKER — two metronomes, ten seconds, drifting apart.

A playhead sweeping a MEASURED chart at REAL TIME, so the viewer is told WHEN to
listen and WHERE. Every tick position is a time measure.py read back out of the
rendered audio, not a position drawn by hand.

⭐ AND THE AUDIO IS THE TWO METRONOMES SUMMED INTO ONE FILE. This lesson does not
   need the viewer to compare two things played in sequence and remember the
   first: the two clocks are in the same ten seconds, and they start together,
   come apart, and land exactly together again at five seconds. That
   re-coincidence is not decoration -- it is arithmetic (nine ticks of one
   against eight of the other) and it is the chart's own control.

⚠ run_time must equal the audio laid under it. __main__ prints the offsets and
  bursts.py builds the bed from them.
⚠ No LaTeX on this machine: every tick label is a hand-placed Text.
⚠ Every number and label below is interpolated from MEASUREMENTS.json. A label
  inside a manim burst is in no narration script and no gate reads it, so the
  only defence is never typing it twice.
"""
import json, os
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(os.path.join(HERE, "MEASUREMENTS.json")))
C = M["_chart"]
BC = M["bothClicks"]
T_MAX = float(C["driftSeconds"])
LEAD, TAIL = 1.6, 1.4
FONT = "Helvetica Neue"
BG, CYAN, RED, WARM, DIM, GOLD = "#080B10", "#5AD1FF", "#FF6B6B", "#7DF9D6", "#7C8798", "#FFC65A"


def T(*a, **kw):
    return Text(*a, font=FONT, **kw)


X0, X1 = -6.1, 6.1
YA, YB = 1.35, -0.55


def xf(t):
    return X0 + (X1 - X0) * t / T_MAX


class DriftOverTime(Scene):
    def construct(self):
        self.camera.background_color = BG
        self.add(T("TWO METRONOMES, TEN SECONDS", font_size=36, color=WARM)
                 .to_edge(UP, buff=0.34))
        self.add(T(f"marked   half note = {C['markHalf']}", font_size=25, color=CYAN)
                 .move_to([X0 - 0.05, YA + 0.78, 0]).align_to(np.array([X0, 0, 0]), LEFT))
        self.add(T(f"performed   half note = {C['driftHalf']}   "
                   f"(a large study's average shortfall)",
                   font_size=25, color=RED)
                 .move_to([X0 - 0.05, YB - 0.78, 0]).align_to(np.array([X0, 0, 0]), LEFT))

        # the time axis
        axis = Line([X0, YB - 1.5, 0], [X1, YB - 1.5, 0], color="#39424F", stroke_width=2)
        self.add(axis)
        for sec in range(int(T_MAX) + 1):
            x = xf(sec)
            self.add(Line([x, YB - 1.5, 0], [x, YB - 1.62, 0], color="#39424F", stroke_width=2))
            self.add(T(f"{sec}", font_size=19, color=DIM).move_to([x, YB - 1.85, 0]))
        self.add(T("seconds", font_size=21, color=DIM).move_to([0, YB - 2.25, 0]))

        # the ticks, at their MEASURED times
        def row(times, y, col):
            g = VGroup()
            for t in times:
                if t <= T_MAX + 1e-9:
                    g.add(Line([xf(t), y - 0.34, 0], [xf(t), y + 0.34, 0],
                               color=col, stroke_width=6))
            return g

        ra = row(C["markTicks"], YA, CYAN)
        rb = row(C["driftTicks"], YB, RED)
        self.add(ra, rb)

        # where they land on the same instant -- derived, not chosen
        for t in BC["coincidencesSec"]:
            self.add(DashedLine([xf(t), YB - 0.55, 0], [xf(t), YA + 0.55, 0],
                                color=GOLD, stroke_width=3, dash_length=0.09))
        # ⚠ PLACED IN THE GAP BETWEEN THE ROWS, not above the top one: at
        #   YA + 0.95 it collided with the "marked half note" label, which no
        #   gate can see and only pulling a frame revealed.
        self.add(T(f"together again after {BC['coincidenceTicks'][0]} ticks "
                   f"against {BC['coincidenceTicks'][1]}",
                   font_size=21, color=GOLD)
                 .move_to([xf(BC["coincidencesSec"][-1]) + 1.55, 0.42, 0]))

        # ⚠ TWO LINES AND A SMALLER SIZE. As one line at font_size 24 this ran
        #   off BOTH edges of a 1920 px frame and manim clipped it silently --
        #   "ey come apart by ... at about 30 m". Found by pulling a frame.
        cap = T(f"they come apart by {C['perTickMs']:.1f} ms every tick\n"
                f"two attacks stop sounding like one at about {C['fusionMs']} ms",
                font_size=21, color=DIM, line_spacing=0.9)\
            .move_to([0, 2.60, 0])
        self.play(FadeIn(cap, shift=UP * 0.1), run_time=LEAD)

        # the playhead, in REAL TIME against the audio
        head = Line([X0, YB - 1.55, 0], [X0, YA + 0.6, 0], color=WARM, stroke_width=4)
        self.add(head)
        self.play(head.animate.shift(RIGHT * (X1 - X0)), run_time=T_MAX, rate_func=linear)

        done = T(f"{BC['distinctOnsetsHeard']} separate ticks in those ten seconds\n"
                 f"one metronome alone has {BC['ticksInMarkAlone']}",
                 font_size=21, color=WARM, line_spacing=0.9)\
            .move_to([0, 2.60, 0])
        self.play(FadeOut(cap), FadeIn(done), run_time=TAIL)


if __name__ == "__main__":
    print(json.dumps({
        "total": round(LEAD + T_MAX + TAIL, 4),
        "audio": [{"wav": f"{BC['file']}.wav", "atSec": round(LEAD, 4),
                   "trim": round(T_MAX, 4)}],
    }))
