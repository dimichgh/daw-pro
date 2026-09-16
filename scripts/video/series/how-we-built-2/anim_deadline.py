"""The two animated explanations Part 2 needs.

Deadline — audio leaves the machine in small blocks on a fixed schedule. A
block that is not ready in time leaves a hole, and a hole is a click. Every
figure (block size, sample rate, milliseconds) is injected from
MEASUREMENTS.json, which read them off the LIVE engine.

Counter — why "just add one" is not one step, and how two threads lose counts.

⚠ NO LaTeX in this install: `Axes(include_numbers=True)` crashes, so every
label is a hand-placed `Text`. ⚠ `Transform` on a numeric readout is mush
mid-step; numeric readouts use `.become()`.
⚠ The film burns a level-meter avatar into the BOTTOM-RIGHT corner, so every
caption is routed through `_place_cap()` and kept left of x = 4.4.
"""
import json, os, sys
import numpy as np
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))

BG, A, B, W, D, GOLD, GRN, RED = ("#0b0d12", "#82cdff", "#b48cff", "#eef2ff",
                                  "#969eaf", "#ffc67a", "#76ffc4", "#ff6b5d")
config.background_color = BG
CAP_RIGHT = 4.4


def _place_cap(t):
    t.to_edge(DOWN, buff=0.28)
    if t.get_right()[0] > CAP_RIGHT:
        t.shift(LEFT * (t.get_right()[0] - CAP_RIGHT))
    if t.get_left()[0] < -6.9:
        t.scale_to_fit_width(CAP_RIGHT + 6.9).to_edge(DOWN, buff=0.28)
        t.shift(LEFT * (t.get_right()[0] - CAP_RIGHT))
    return t


def cap(s, colour=W, size=30):
    return _place_cap(Text(s, font="SF Pro Display", font_size=size, color=colour))


def fits(name, g):
    if g.get_left()[0] < -7.0 or g.get_right()[0] > 7.0 \
       or g.get_bottom()[1] < -4.0 or g.get_top()[1] > 4.0:
        sys.exit(f"{name}: the diagram runs off the frame")


class Deadline(Scene):
    def construct(self):
        blk = M["blockFrames"]
        ms = M["blockMilliseconds"]
        sr = M["sampleRate"]

        title = Text("The sound card asks. It does not wait.",
                     font="SF Pro Display", weight=BOLD, font_size=44, color=W)
        title.to_edge(UP, buff=0.55)
        self.play(FadeIn(title, shift=DOWN * 0.2), run_time=0.8)

        # the sound card, on the right
        card = RoundedRectangle(width=2.5, height=2.2, corner_radius=0.16,
                                stroke_color=A, stroke_width=3,
                                fill_color="#111621", fill_opacity=1)
        card.move_to(RIGHT * 4.6 + UP * 0.35)
        clab = VGroup(Text("SOUND CARD", font="SF Mono", font_size=20, color=A),
                      Text("→ speaker", font="SF Pro Display", font_size=22, color=D)
                      ).arrange(DOWN, buff=0.16).move_to(card.get_center())
        self.play(FadeIn(card), FadeIn(clab), run_time=0.6)

        c1 = cap(f"Every {ms:.2f} thousandths of a second, it wants the next block.")
        self.play(FadeIn(c1), run_time=0.5)

        # a queue of blocks marching in
        def block(i, colour=GRN):
            r = RoundedRectangle(width=1.15, height=1.15, corner_radius=0.1,
                                 stroke_color=colour, stroke_width=3,
                                 fill_color="#131a24", fill_opacity=1)
            t = Text(str(i), font="SF Mono", font_size=26, color=colour).move_to(r.get_center())
            return VGroup(r, t)

        row = VGroup(*[block(i) for i in range(1, 6)]).arrange(RIGHT, buff=0.38)
        row.move_to(LEFT * 2.0 + UP * 0.35)
        fits("Deadline", VGroup(row, card))
        self.play(LaggedStart(*[FadeIn(b, shift=RIGHT * 0.3) for b in row],
                              lag_ratio=0.18), run_time=1.3)

        sub = Text(f"one block = {blk} numbers per ear  ·  {sr:,} of them every second",
                   font="SF Mono", font_size=24, color=GOLD)
        sub.next_to(row, DOWN, buff=0.65)
        # keep it inside the frame: the row is left of centre, the text is wide
        if sub.get_left()[0] < -6.6:
            sub.shift(RIGHT * (-6.6 - sub.get_left()[0]))
        if sub.get_right()[0] > 6.6:
            sub.scale_to_fit_width(13.0).move_to(np.array([0, sub.get_center()[1], 0]))
        self.play(FadeIn(sub), run_time=0.5)
        self.wait(2.2)
        self.play(FadeOut(c1), run_time=0.3)

        # four blocks arrive on time
        c2 = cap("On time, four times running. Nobody notices software that works.")
        self.play(FadeIn(c2), run_time=0.5)
        for i in range(4):
            b = row[i]
            self.play(b.animate.move_to(card.get_center()).scale(0.35).set_opacity(0.0),
                      run_time=0.45, rate_func=rate_functions.ease_in_sine)
        self.wait(1.0)
        self.play(FadeOut(c2), run_time=0.3)

        # the fifth is late
        late = row[4]
        self.play(late[0].animate.set_stroke(RED), late[1].animate.set_color(RED),
                  run_time=0.5)
        c3 = cap("The fifth one is not ready. The card does not wait for it.")
        self.play(FadeIn(c3), run_time=0.5)
        hole = RoundedRectangle(width=1.15, height=1.15, corner_radius=0.1,
                                stroke_color=RED, stroke_width=3,
                                stroke_opacity=0.9, fill_opacity=0)
        hole.move_to(card.get_left() + LEFT * 1.1 + UP * 0.0)
        hlab = Text("nothing", font="SF Pro Display", font_size=20, color=RED)
        hlab.move_to(hole.get_center())
        self.play(FadeIn(hole), FadeIn(hlab), run_time=0.5)
        self.wait(1.8)
        self.play(FadeOut(c3), run_time=0.3)

        # what it sounds like: a waveform with a square step in it
        self.play(FadeOut(row), FadeOut(sub), FadeOut(hole), FadeOut(hlab),
                  FadeOut(card), FadeOut(clab), run_time=0.6)
        x = np.linspace(-5.2, 4.3, 900)
        y = 0.62 * np.sin(x * 7.0) * np.exp(-0.02 * (x + 6) ** 2)
        gap = (x > -0.35) & (x < 0.6)
        yb = y.copy(); yb[gap] = 0.0
        wave = VMobject(stroke_color=A, stroke_width=3)
        wave.set_points_as_corners([np.array([xi, yi + 0.2, 0]) for xi, yi in zip(x, y)])
        broke = VMobject(stroke_color=RED, stroke_width=4)
        broke.set_points_as_corners([np.array([xi, yi - 1.9, 0]) for xi, yi in zip(x, yb)])
        # ⚠ LOOKED AT: labels placed with next_to(..., LEFT) ran off the left
        # edge of the frame and rendered as "sound" / "ole in it". They sit
        # ABOVE each trace now, anchored to the frame's left margin.
        l1 = Text("the sound", font="SF Mono", font_size=24, color=A)
        l1.move_to(np.array([-5.4, 1.35, 0]), aligned_edge=LEFT)
        l2 = Text("with a hole in it", font="SF Mono", font_size=24, color=RED)
        l2.move_to(np.array([-5.4, -0.75, 0]), aligned_edge=LEFT)
        self.play(Create(wave), run_time=1.2)
        self.play(Create(broke), run_time=1.2)
        c4 = cap("Two vertical steps where there should be a curve. That is a click.")
        self.play(FadeIn(c4), FadeIn(l1), FadeIn(l2), run_time=0.6)
        for xx in (-0.35, 0.6):
            self.play(Flash(np.array([xx, -1.9, 0]), color=RED, line_length=0.35),
                      run_time=0.5)
        self.wait(2.6)


class Counter(Scene):
    def construct(self):
        title = Text("Adding one is not one step",
                     font="SF Pro Display", weight=BOLD, font_size=46, color=W)
        title.to_edge(UP, buff=0.55)
        self.play(FadeIn(title, shift=DOWN * 0.2), run_time=0.8)

        box = RoundedRectangle(width=2.6, height=1.6, corner_radius=0.16,
                               stroke_color=A, stroke_width=3,
                               fill_color="#111621", fill_opacity=1)
        box.move_to(UP * 0.55)
        lbl = Text("THE COUNT", font="SF Mono", font_size=20, color=D)
        lbl.next_to(box, UP, buff=0.2)
        val = Text("5", font="SF Mono", font_size=54, color=GOLD).move_to(box.get_center())
        self.play(FadeIn(box), FadeIn(lbl), FadeIn(val), run_time=0.7)

        steps = VGroup(Text("1.  read the number", font="SF Mono", font_size=26, color=W),
                       Text("2.  add one to it", font="SF Mono", font_size=26, color=W),
                       Text("3.  write it back", font="SF Mono", font_size=26, color=W)
                       ).arrange(DOWN, aligned_edge=LEFT, buff=0.22)
        steps.move_to(LEFT * 3.6 + UP * 0.55)
        fits("Counter", VGroup(steps, box))
        self.play(LaggedStart(*[FadeIn(s, shift=RIGHT * 0.2) for s in steps],
                              lag_ratio=0.3), run_time=1.2)
        c1 = cap("Three steps, and anything can happen between them.")
        self.play(FadeIn(c1), run_time=0.5)
        self.wait(2.2)
        self.play(FadeOut(c1), FadeOut(steps), run_time=0.4)

        # two workers
        def worker(name, colour, pos):
            r = RoundedRectangle(width=3.0, height=1.15, corner_radius=0.14,
                                 stroke_color=colour, stroke_width=3,
                                 fill_color="#131a24", fill_opacity=1).move_to(pos)
            t = Text(name, font="SF Mono", font_size=24, color=colour).move_to(r.get_center())
            return VGroup(r, t)

        wa = worker("worker one", GRN, LEFT * 4.0 + DOWN * 1.9)
        wb = worker("worker two", B, RIGHT * 4.0 + DOWN * 1.9)
        self.play(FadeIn(wa), FadeIn(wb), run_time=0.6)

        def note(txt, at, colour):
            t = Text(txt, font="SF Mono", font_size=22, color=colour)
            t.next_to(at, UP, buff=0.22)
            return t

        c2 = cap("Both read the same five, at the same moment.")
        self.play(FadeIn(c2), run_time=0.5)
        na = note("reads 5", wa, GRN); nb = note("reads 5", wb, B)
        self.play(FadeIn(na), FadeIn(nb), run_time=0.7)
        self.wait(1.6)
        # ⚠ `.become()` MUTATES and returns the mobject; it is not an
        # animation and passing it to play() is a TypeError. It is still the
        # right tool for a numeric readout (Transform renders mush mid-step),
        # so it is called outside play() and the beat is held with wait().
        na.become(note("makes 6", wa, GRN))
        nb.become(note("makes 6", wb, B))
        self.add(na, nb)
        self.wait(0.7)
        self.wait(1.2)
        self.play(FadeOut(c2), run_time=0.3)
        c3 = cap("Both write six. Two events happened. The count went up by one.")
        self.play(FadeIn(c3), run_time=0.5)
        val.become(Text("6", font="SF Mono", font_size=54,
                        color=RED).move_to(box.get_center()))
        self.add(val)
        self.wait(0.6)
        self.play(Flash(box.get_center(), color=RED, line_length=0.4), run_time=0.7)
        self.wait(2.4)
        self.play(FadeOut(c3), FadeOut(na), FadeOut(nb), run_time=0.4)

        lost = Text(f'{M["counterLossPercent"]}% of the counts, gone',
                    font="SF Pro Display", weight=BOLD, font_size=44, color=RED)
        lost.move_to(DOWN * 0.35)
        sub = Text("measured with eight workers, on this project",
                   font="SF Pro Display", font_size=26, color=D)
        sub.next_to(lost, DOWN, buff=0.3)
        self.play(FadeOut(box), FadeOut(lbl), FadeOut(val),
                  FadeOut(wa), FadeOut(wb), run_time=0.5)
        self.play(FadeIn(lost, scale=0.95), run_time=0.8)
        self.play(FadeIn(sub), run_time=0.5)
        self.wait(2.0)
        fix = Text("the fix is one instruction that does all three at once",
                   font="SF Pro Display", font_size=30, color=GRN)
        fix.next_to(sub, DOWN, buff=0.55)
        self.play(FadeIn(fix), run_time=0.6)
        self.wait(2.6)
