#!/usr/bin/env python3
"""DEMO 4's chart: the knee, and why you cannot hear it.

⚠️ THIS SCENE EXISTS TO MAKE AN HONEST NEGATIVE POINT, AND IT MUST NOT BE
SOFTENED. The user reported they could not hear the knee comparison on laptop
speakers. They were right, and it is not a speaker fault: the gap is bounded by
the gain computer's own arithmetic and no signal or setting gets past ~2.3 dB.

From `CompressorEffect.swift`, inside the knee:
    target = slope * (over + W/2)^2 / (2W),  slope = 1 - 1/ratio
A hard knee gives 0 below threshold, so the hard-vs-soft gap IS that expression,
and it is largest exactly AT threshold (over = 0):
    max gap = slope * W / 8
At the demo's ratio 4 and knee 24 that is 0.75 * 24 / 8 = 2.25 dB. At the widest
ratio the plugin offers, 20, it is 2.85 dB. Loudness JND is about 1 dB under
ideal conditions and worse on a small speaker, so a 1.5 dB difference is at the
edge of perception BY CONSTRUCTION.

So the chapter's claim is not "listen closely". It is: a soft knee is called
gentle because it IS gentle -- the chart is the only place you will ever see it,
and that is the lesson, not a limitation of the demo.
"""
import json, os
import numpy as np
from manim import *

CYAN, VIOLET, WARM, DIM = "#5AD1FF", "#A78BFA", "#7DF9D6", "#6E7A8A"

THRESH, RATIO, KNEE = -18.0, 4.0, 24.0
SLOPE = 1.0 - 1.0 / RATIO
OP = THRESH - 2.0          # the demo's operating point: a tone 2 dB BELOW
                           # threshold, which is the only place a knee can show
                           # a difference a hard knee cannot also make.


def reduction(level_db, knee_db):
    """The shipped gain computer, transcribed. Returns dB of reduction (>= 0)."""
    over = level_db - THRESH
    if knee_db <= 0:
        return SLOPE * over if over > 0 else 0.0
    if 2 * over <= -knee_db:
        return 0.0
    if 2 * over >= knee_db:
        return SLOPE * over
    t = over + knee_db / 2.0
    return SLOPE * t * t / (2.0 * knee_db)


class KneeCurve(Scene):
    def construct(self):
        self.camera.background_color = "#080B10"
        ax = Axes(x_range=[-36, -2, 6], y_range=[-36, -2, 6],
                  x_length=8.2, y_length=5.0,
                  axis_config={"color": DIM, "stroke_width": 2, "font_size": 20},
                  tips=False)
        ax.to_edge(DOWN, buff=1.25).shift(LEFT * 1.5)
        self.add(ax)
        for v in (-36, -30, -24, -18, -12, -6):
            self.add(Text(f"{v}", font_size=17, color=DIM)
                     .next_to(ax.c2p(v, -36), DOWN, buff=0.12))
            self.add(Text(f"{v}", font_size=17, color=DIM)
                     .next_to(ax.c2p(-36, v), LEFT, buff=0.12))
        self.add(Text("input (dB)", font_size=20, color=DIM).next_to(ax, DOWN, buff=0.42))
        self.add(Text("output (dB)", font_size=20, color=DIM)
                 .next_to(ax, LEFT, buff=0.12).rotate(PI / 2))

        self.add(Text("the knee: where compression starts",
                      font_size=32, color=WARM).to_edge(UP, buff=0.35))

        # threshold marker
        thr = DashedLine(ax.c2p(THRESH, -36), ax.c2p(THRESH, -2),
                         color=DIM, stroke_width=1.5, dash_length=0.07)
        self.add(thr, Text("threshold", font_size=19, color=DIM)
                 .next_to(ax.c2p(THRESH, -2), UP, buff=0.08))

        def curve(knee, col):
            pts = []
            x = -36.0
            while x <= -2.0:
                pts.append(ax.c2p(x, x - reduction(x, knee)))
                x += 0.25
            vm = VMobject(color=col, stroke_width=4.5)
            vm.set_points_smoothly(pts)
            return vm

        hard, soft = curve(0.0, CYAN), curve(KNEE, VIOLET)
        self.play(Create(hard), run_time=1.1)
        self.add(Text("hard knee", font_size=22, color=CYAN).move_to(ax.c2p(-8.0, -13.5)))
        self.play(Create(soft), run_time=1.1)
        self.add(Text("soft knee", font_size=22, color=VIOLET).move_to(ax.c2p(-8.0, -24.0)))
        self.wait(0.4)

        # THE OPERATING POINT — a tone 2 dB BELOW threshold. A hard knee does
        # nothing here at all; the soft knee has already started working. That
        # is the entire idea of a knee, and it is worth one clear callout.
        gap = reduction(OP, KNEE) - reduction(OP, 0.0)
        dot_h = Dot(ax.c2p(OP, OP - reduction(OP, 0.0)), color=CYAN, radius=0.07)
        dot_s = Dot(ax.c2p(OP, OP - reduction(OP, KNEE)), color=VIOLET, radius=0.07)
        brace = Line(dot_h.get_center(), dot_s.get_center(), color=WARM, stroke_width=3)
        self.play(FadeIn(dot_h), FadeIn(dot_s), Create(brace), run_time=0.7)
        self.play(FadeIn(Text("2 dB below threshold", font_size=18, color=DIM)
                         .next_to(brace, LEFT, buff=0.18)), run_time=0.4)

        head = VGroup(Text(f"{gap:.2f} dB", font_size=42, color=WARM),
                      Text("the entire difference", font_size=20, color=DIM)
                      ).arrange(DOWN, buff=0.1, aligned_edge=LEFT)
        mid = VGroup(Text("hard knee: nothing here", font_size=19, color=CYAN),
                     Text("soft knee: already working", font_size=19, color=VIOLET)
                     ).arrange(DOWN, buff=0.12, aligned_edge=LEFT)
        foot = VGroup(Text("widest it can EVER be:", font_size=18, color=DIM),
                      Text(f"{SLOPE * KNEE / 8:.2f} dB, at the threshold",
                           font_size=20, color=WARM)
                      ).arrange(DOWN, buff=0.1, aligned_edge=LEFT)
        panel = VGroup(head, mid, foot).arrange(DOWN, buff=0.42, aligned_edge=LEFT)
        panel.to_edge(RIGHT, buff=0.45).shift(DOWN * 0.35)
        self.play(FadeIn(panel, shift=LEFT * 0.2), run_time=0.6)

        # The honest close. Do not soften this.
        self.play(FadeIn(Text("you will not hear this on laptop speakers — "
                              "that is why it is called gentle",
                              font_size=22, color=WARM).to_edge(DOWN, buff=0.16)),
                  run_time=0.6)

        # ⭐ THE ATTENTION MARKER, same device as the release chart: the viewer is
        # told WHICH tone is playing and for HOW LONG, with a real-time head, and
        # the operating point on the curve is ringed while its tone sounds. The
        # difference is 1.52 dB and they are not expected to hear it — the marker
        # exists so they know they were listening to the right thing when they
        # could not. `run_time` MUST equal the audio window laid under it.
        LISTEN = 3.0
        for label, col, dot in (("HARD KNEE", CYAN, dot_h),
                                ("SOFT KNEE", VIOLET, dot_s)):
            cue = Text(f"now playing:  {label}", font_size=27, color=col)
            cue.move_to([0.0, 3.02, 0.0])
            p0, p1 = np.array([-3.4, 2.58, 0.0]), np.array([3.4, 2.58, 0.0])
            track = Line(p0, p1, color=DIM, stroke_width=2.5)
            head = Dot(p0, color=col, radius=0.1)
            ring = Circle(radius=0.2, color=col, stroke_width=4).move_to(dot.get_center())
            self.add(cue, track, head, ring)
            self.play(head.animate.move_to(p1), run_time=LISTEN, rate_func=linear)
            self.remove(cue, track, head, ring)
        self.wait(0.9)


if __name__ == "__main__":
    print(json.dumps({
        "thresholdDb": THRESH, "ratio": RATIO, "kneeDb": KNEE,
        "operatingPointDb": OP,
        "gapAtOperatingPointDb": round(reduction(OP, KNEE) - reduction(OP, 0.0), 4),
        "maxPossibleGapDb": round(SLOPE * KNEE / 8, 4),
        "maxAtRatio20Db": round((1 - 1 / 20) * KNEE / 8, 4),
        # The assembler needs to know WHERE the two listen windows start, so the
        # tones sit UNDER their own marker instead of near it. Summed from the
        # scene's own run_times: 1.1 + 1.1 + 0.4 + 0.7 + 0.4 + 0.6 + 0.6 = 4.9.
        "listen": [{"label": "HARD KNEE", "audio": "d4-hard.wav", "startSec": 4.9},
                   {"label": "SOFT KNEE", "audio": "d4-soft.wav", "startSec": 7.9}],
        "listenSeconds": 3.0,
        "totalSec": 11.8}, indent=2))
