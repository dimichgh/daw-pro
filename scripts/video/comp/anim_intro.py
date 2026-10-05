#!/usr/bin/env python3
"""CHAPTER 0's diagram: what a compressor does, in one picture.

A level line, a threshold, and the part above the threshold pushed down.

⚠️ IT IS DRAWN FROM MEASURED RENDERS, NOT INVENTED. `introenv.py` takes the peak
envelope of the SAME two files demo 3 plays -- the dry loop and the same loop
through the compressor -- so the opening picture of a predict-then-measure film
is not the one hand-drawn thing in it. The 6.55 dB the peaks come down by is a
measured maximum, not a chosen one.

⚠️ NO LaTeX ON THIS MACHINE. `include_numbers=True` on Axes renders through
MathTex and crashes; every tick label here is a hand-placed Text. And never
space a VGroup with Text("") -- it has no points and collapses arrange() into an
overlapping stack.
"""
import json, os
import numpy as np
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
D = json.load(open(os.path.join(HERE, "introenv.json")))
THRESH = -18.865          # d3pad.mjs's own threshold: measured dry peak - 9 dB
T_MAX, LO, HI = 3.0, -30.0, -8.0
CYAN, VIOLET, WARM, DIM = "#5AD1FF", "#A78BFA", "#7DF9D6", "#6E7A8A"


class WhatItDoes(Scene):
    def construct(self):
        self.camera.background_color = "#080B10"
        ax = Axes(x_range=[0, T_MAX, 0.5], y_range=[LO, HI, 4],
                  x_length=10.6, y_length=4.4,
                  axis_config={"color": DIM, "stroke_width": 2, "include_ticks": True},
                  tips=False)
        ax.to_edge(DOWN, buff=1.05)
        self.add(ax)
        for yv in (-28, -24, -20, -16, -12):
            self.add(Text(f"{yv}", font_size=17, color=DIM)
                     .next_to(ax.c2p(0, yv), LEFT, buff=0.14))
        self.add(Text("level (dB)", font_size=20, color=DIM)
                 .next_to(ax, LEFT, buff=0.12).rotate(PI / 2))
        self.add(Text("time", font_size=20, color=DIM).next_to(ax, DOWN, buff=0.34))
        self.add(Text("what a compressor does", font_size=34, color=WARM)
                 .to_edge(UP, buff=0.35))

        def trace(key, col, width=4.0):
            pts = [ax.c2p(t, min(max(v, LO), HI)) for t, v in D[key] if t <= T_MAX]
            vm = VMobject(color=col, stroke_width=width)
            vm.set_points_smoothly(pts)
            return vm

        # ① the signal, untouched
        cap = Text("a sound, as it was played", font_size=25, color=CYAN)
        cap.next_to(ax, UP, buff=0.26)
        dry = trace("dry", CYAN)
        self.play(FadeIn(cap), Create(dry), run_time=1.6)
        self.wait(0.7)

        # ② the line you choose
        line = DashedLine(ax.c2p(0, THRESH), ax.c2p(T_MAX, THRESH),
                          color=WARM, stroke_width=2.4, dash_length=0.1)
        # ⚠ OUTSIDE the plot. The first cut put this label inside the axes and it
        # sat directly on the peaks the diagram exists to show -- found by
        # extracting the frame and looking at it.
        lab = Text("threshold", font_size=21, color=WARM)
        lab.next_to(ax.c2p(T_MAX, THRESH), RIGHT, buff=0.16)
        cap2 = Text("above this line is what counts as loud", font_size=25, color=WARM)
        cap2.next_to(ax, UP, buff=0.26)
        self.play(FadeOut(cap), FadeIn(cap2), Create(line), FadeIn(lab), run_time=1.1)
        self.wait(0.7)

        # ③ the part above it is pushed down — the arrows are the whole idea
        wet = trace("compressed", VIOLET)
        cap3 = Text("the part above the line is turned down", font_size=25, color=VIOLET)
        cap3.next_to(ax, UP, buff=0.26)
        # ⚠ ONE ARROW PER HIT, at the window where the reduction is DEEPEST --
        # not every Nth window. The first cut drew "every 12th window with more
        # than 3 dB of reduction" and those two conditions almost never
        # coincided: exactly ONE arrow reached the screen, on a diagram whose
        # entire subject is the arrows.
        wetmap = dict(D["compressed"])
        arrows, BIN = VGroup(), 0.375
        best = {}
        for t, v in D["dry"]:
            if t > T_MAX:
                break
            d = v - wetmap.get(t, v)
            k = int(t / BIN)
            if d > 3.0 and d > best.get(k, (0, 0, 0))[0]:
                best[k] = (d, t, v)
        for d, t, v in best.values():
            arrows.add(Arrow(ax.c2p(t, v), ax.c2p(t, wetmap[t]), color=VIOLET,
                             stroke_width=3.5, buff=0.02,
                             max_tip_length_to_length_ratio=0.32))
        self.play(FadeOut(cap2), FadeIn(cap3), run_time=0.4)
        self.play(Create(wet), run_time=1.4)
        self.play(*[GrowArrow(a) for a in arrows], run_time=0.8)
        self.wait(0.9)

        # ④ and the quiet parts do not move
        quiet = Text("the quiet parts do not move at all", font_size=24, color=DIM)
        quiet.next_to(ax, UP, buff=0.26)
        self.play(FadeOut(cap3), FadeIn(quiet), dry.animate.set_stroke(opacity=0.45),
                  run_time=0.7)
        self.wait(1.0)

        foot = VGroup(
            Text("a hand on a fader that never gets tired,", font_size=26, color=WARM),
            Text("and that reacts in a thousandth of a second", font_size=26, color=WARM),
        ).arrange(DOWN, buff=0.14).to_edge(DOWN, buff=0.14)
        self.play(FadeIn(foot, shift=UP * 0.12), run_time=0.6)
        self.wait(1.6)


if __name__ == "__main__":
    dry = np.array([v for _, v in D["dry"]])
    wet = np.array([v for _, v in D["compressed"]])
    print(json.dumps({"thresholdDb": THRESH,
                      "dryPeakDb": round(float(dry.max()), 2),
                      "compressedPeakDb": round(float(wet.max()), 2),
                      "maxWindowReductionDb": round(float((dry - wet).max()), 2),
                      "source": "d3p-dry.wav / d3p-fast.wav, 10 ms peak envelope"},
                     indent=2))
