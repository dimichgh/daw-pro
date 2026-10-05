"""THE CENTREPIECE. One command travelling the whole path.

JourneyA — the convergence. A button and a message are two different callers
that end up in the SAME function. Every box carries the real file and line,
read from MEASUREMENTS.json, which read them out of the repository with grep.

JourneyB — from that function to air: the model tells the engine to start, the
engine fills the sound card, the speaker moves.

⚠ NO LaTeX; every label is a `Text`. ⚠ Both scenes ASSERT that their diagram
fits the frame — the modules scene shipped a first render that overflowed on
three sides and was a perfectly valid mp4.
"""
import json, os, sys
import numpy as np
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
C = M["convergence"]

BG, A, B, W, D, GOLD, GRN = ("#0b0d12", "#82cdff", "#b48cff", "#eef2ff",
                             "#969eaf", "#ffc67a", "#76ffc4")
config.background_color = BG


def short(where):
    return f'{os.path.basename(where["file"])}:{where["line"]}'


def node(title, sub, mono, w=5.4, h=1.9, colour=A, ts=31):
    r = RoundedRectangle(width=w, height=h, corner_radius=0.14,
                         stroke_color=colour, stroke_width=3,
                         fill_color="#111621", fill_opacity=1)
    parts = [Text(title, font="SF Pro Display", weight=BOLD, font_size=ts, color=W)]
    if sub:
        parts.append(Text(sub, font="SF Pro Display", font_size=21, color=D))
    if mono:
        parts.append(Text(mono, font="SF Mono", font_size=18, color=GOLD))
    g = VGroup(*parts).arrange(DOWN, buff=0.14).move_to(r.get_center())
    return VGroup(r, g)


def fits(scene_name, g):
    if g.get_left()[0] < -7.0 or g.get_right()[0] > 7.0 \
       or g.get_bottom()[1] < -4.0 or g.get_top()[1] > 4.0:
        sys.exit(f"{scene_name}: the diagram runs off the frame")



# ⚠️ MEASURED: the film burns a small level-meter avatar into the BOTTOM-RIGHT
# corner, and it drew straight over the tail of the longest caption ("...follows
# from i|meter"). Nothing in manim knows the meter exists, so the caption has to
# stay out of its lane by construction. The meter's left edge sits at about
# x = +4.7 in manim units; keep captions clear of +4.4 and re-check the left.
CAP_RIGHT = 4.4


def _place_cap(t):
    t.to_edge(DOWN, buff=0.28)
    if t.get_right()[0] > CAP_RIGHT:
        t.shift(LEFT * (t.get_right()[0] - CAP_RIGHT))
    if t.get_left()[0] < -6.9:
        t.scale_to_fit_width(CAP_RIGHT + 6.9).to_edge(DOWN, buff=0.28)
        t.shift(LEFT * (t.get_right()[0] - CAP_RIGHT))
    return t


class JourneyA(Scene):
    def construct(self):
        title = Text("Two callers. One function.", font="SF Pro Display",
                     weight=BOLD, font_size=40, color=W).to_edge(UP, buff=0.35)

        btn = node("You press PLAY", "a button in the window",
                   short(C["button"]), w=5.6)
        msg = node("A message arrives", "on the control socket",
                   short(C["socket"]), w=5.6, colour=B)
        top = VGroup(btn, msg).arrange(RIGHT, buff=1.5)

        js = Text('{"command": "transport.play"}', font="SF Mono",
                  font_size=22, color=B)

        shared = node("play()", "the one place both of them land",
                      short(C["shared"]), w=6.6, h=2.0, colour=GRN, ts=38)
        shared.next_to(top, DOWN, buff=1.9)

        a1 = Arrow(btn[0].get_bottom(), shared[0].get_top() + LEFT * 1.6, buff=0.1,
                   stroke_width=5, color=A, max_tip_length_to_length_ratio=0.15)
        a2 = Arrow(msg[0].get_bottom(), shared[0].get_top() + RIGHT * 1.6, buff=0.1,
                   stroke_width=5, color=B, max_tip_length_to_length_ratio=0.15)

        g = VGroup(top, shared, a1, a2)
        g.scale(min(12.6 / g.width, 5.6 / g.height)).move_to(ORIGIN).shift(DOWN * 0.3)
        fits("JourneyA", g)
        js.next_to(msg, UP, buff=0.22)

        cap = lambda s: _place_cap(
            Text(s, font="SF Pro Display", font_size=25, color=W))

        self.play(FadeIn(title, shift=DOWN * 0.15), run_time=1.0)
        self.play(FadeIn(btn, scale=0.95), run_time=0.8)
        self.wait(1.5)
        self.play(FadeIn(msg, scale=0.95), FadeIn(js, shift=DOWN * 0.15), run_time=0.9)
        self.wait(2.0)
        c1 = cap("Neither one knows the other exists.")
        self.play(FadeIn(c1), run_time=0.6)
        self.wait(1.6)
        self.play(FadeOut(c1), run_time=0.35)
        self.play(FadeIn(shared, scale=0.95), run_time=0.8)
        self.play(GrowArrow(a1), GrowArrow(a2), run_time=1.0)
        c2 = cap("Both of them land in exactly the same function.")
        self.play(FadeIn(c2), run_time=0.6)
        self.wait(3.0)
        self.play(FadeOut(c2), run_time=0.4)
        c3 = cap("That is the whole decision. Everything else follows from it.")
        self.play(FadeIn(c3), run_time=0.6)
        self.wait(3.0)


class JourneyB(Scene):
    def construct(self):
        title = Text("...and then it makes a sound", font="SF Pro Display",
                     weight=BOLD, font_size=40, color=W).to_edge(UP, buff=0.35)

        n1 = node("play()", "the model says: we are playing now",
                  short(C["shared"]), w=6.2, h=1.7, colour=GRN, ts=32)
        n2 = node("startPlayback()", "the model hands it to the engine",
                  short(C["engine"]), w=6.2, h=1.7, colour=A, ts=32)
        n3 = node("DAWEngine", "keeps the speaker fed, without falling behind",
                  f'{M["modules"][1]["lines"]:,} lines', w=6.2, h=1.7,
                  colour=GOLD, ts=32)
        chain = VGroup(n1, n2, n3).arrange(DOWN, buff=0.62)
        chain.scale(min(6.6 / chain.width, 6.2 / chain.height))
        chain.to_edge(LEFT, buff=0.7).shift(DOWN * 0.25)

        arrows = VGroup(*[Arrow(a[0].get_bottom(), b[0].get_top(), buff=0.07,
                                stroke_width=5, color=D,
                                max_tip_length_to_length_ratio=0.3)
                          for a, b in ((n1, n2), (n2, n3))])

        # the speaker: a measured sine, drawn from real numbers
        ax_w, ax_h = 5.6, 2.4
        xs = np.linspace(0, 1, 700)
        ys = np.sin(2 * np.pi * 5 * xs) * np.exp(-1.4 * xs)
        wave = VMobject(stroke_color=GRN, stroke_width=4)
        wave.set_points_smoothly([np.array([-ax_w / 2 + x * ax_w, y * ax_h / 2, 0])
                                  for x, y in zip(xs, ys)])
        axis = Line([-ax_w / 2, 0, 0], [ax_w / 2, 0, 0], stroke_color="#2a3140",
                    stroke_width=2)
        wgrp = VGroup(axis, wave).move_to(RIGHT * 3.6 + DOWN * 0.55)
        wlab = Text("air moving", font="SF Pro Display", font_size=24, color=GRN)
        wlab.next_to(wgrp, UP, buff=0.3)

        big = Arrow(chain.get_right() + RIGHT * 0.05, wgrp.get_left() + LEFT * 0.1,
                    buff=0.15, stroke_width=6, color=GOLD,
                    max_tip_length_to_length_ratio=0.16)

        fits("JourneyB", VGroup(chain, wgrp, wlab, big))

        cap = lambda s: _place_cap(
            Text(s, font="SF Pro Display", font_size=25, color=W))

        self.play(FadeIn(title, shift=DOWN * 0.15), run_time=1.0)
        self.play(FadeIn(n1, scale=0.95), run_time=0.7)
        self.wait(1.0)
        self.play(FadeIn(n2, scale=0.95), GrowArrow(arrows[0]), run_time=0.8)
        self.wait(1.4)
        self.play(FadeIn(n3, scale=0.95), GrowArrow(arrows[1]), run_time=0.8)
        c1 = cap("The engine is handed a request for the next few thousandths of a second.")
        self.play(FadeIn(c1), run_time=0.6)
        self.wait(2.6)
        self.play(FadeOut(c1), run_time=0.35)

        self.play(GrowArrow(big), FadeIn(axis), FadeIn(wlab), run_time=0.9)
        self.play(Create(wave), run_time=1.6)
        c2 = cap("Miss that deadline and the listener hears a click. That is Part Two.")
        self.play(FadeIn(c2), run_time=0.6)
        self.wait(3.0)
        self.play(FadeOut(c2), run_time=0.4)

        # the dot makes the trip once, end to end
        path = VMobject()
        path.set_points_as_corners([n1[0].get_left() + LEFT * 0.02,
                                    n2[0].get_left() + LEFT * 0.02,
                                    n3[0].get_left() + LEFT * 0.02,
                                    n3[0].get_right(),
                                    wgrp.get_left()])
        dot = Dot(color=GRN, radius=0.13).move_to(path.get_start())
        c3 = cap("One message in. One sound out.")
        self.play(FadeIn(dot), FadeIn(c3), run_time=0.5)
        self.play(MoveAlongPath(dot, path), run_time=2.6, rate_func=rate_functions.ease_in_out_sine)
        self.play(Flash(wgrp.get_left(), color=GRN, line_length=0.3), run_time=0.7)
        self.wait(2.2)
