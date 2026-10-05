"""Part 3's one animated explanation: why a wrong answer is harder than a crash.

Two commands. One never runs at all; the other runs and genuinely finds
nothing. They print the same thing — an empty line — and the empty one is the
answer you were hoping for, which is exactly when you stop checking.

⚠ NO LaTeX in this install: every label is a hand-placed `Text`.
⚠ The film burns a level meter into the BOTTOM-RIGHT corner, so captions are
routed through `_place_cap()` and kept left of x = 4.4.
"""
import json, os, sys
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))

BG, A, B, W, D, GOLD, GRN, RED = ("#0b0d12", "#82cdff", "#b48cff", "#eef2ff",
                                  "#969eaf", "#ffc67a", "#76ffc4", "#ff6b5d")
config.background_color = BG
CAP_RIGHT = 4.4
MONO = "SF Mono"
SANS = "SF Pro Display"


def _place_cap(t):
    t.to_edge(DOWN, buff=0.30)
    if t.get_right()[0] > CAP_RIGHT:
        t.shift(LEFT * (t.get_right()[0] - CAP_RIGHT))
    if t.get_left()[0] < -6.9:
        t.scale_to_fit_width(CAP_RIGHT + 6.9).to_edge(DOWN, buff=0.30)
        t.shift(LEFT * (t.get_right()[0] - CAP_RIGHT))
    return t


def cap(s, colour=W, size=30):
    return _place_cap(Text(s, font=SANS, font_size=size, color=colour))


def panel(w, h, colour=D):
    return RoundedRectangle(width=w, height=h, corner_radius=0.14,
                            stroke_color=colour, stroke_width=2.4,
                            fill_color="#11141b", fill_opacity=1.0)


class Silent(Scene):
    def construct(self):
        title = Text("Two different failures. One picture.",
                     font=SANS, weight=BOLD, font_size=44, color=W)
        title.to_edge(UP, buff=0.5)
        self.play(FadeIn(title, shift=DOWN * 0.2), run_time=0.8)

        # ---- the two commands ------------------------------------------------
        boxA, boxB = panel(6.1, 1.15), panel(6.1, 1.15)
        boxA.move_to([-3.3, 1.75, 0])
        boxB.move_to([-3.3, 0.05, 0])
        txtA = Text("search a file that has three answers", font=SANS,
                    font_size=26, color=W).move_to(boxA.get_center() + UP * 0.24)
        subA = Text("not installed on this machine, so it never runs", font=SANS,
                    font_size=21, color=RED).move_to(boxA.get_center() + DOWN * 0.26)
        txtB = Text("search a file that really has none", font=SANS,
                    font_size=26, color=W).move_to(boxB.get_center() + UP * 0.24)
        subB = Text("the command runs perfectly", font=SANS,
                    font_size=21, color=GRN).move_to(boxB.get_center() + DOWN * 0.26)
        self.play(FadeIn(VGroup(boxA, txtA, subA)), run_time=0.7)
        self.play(FadeIn(VGroup(boxB, txtB, subB)), run_time=0.7)

        # ---- one screen ------------------------------------------------------
        term = panel(4.4, 2.0, A).move_to([3.6, 0.9, 0])
        prompt = Text("$", font=MONO, font_size=30, color=GRN)
        prompt.move_to(term.get_corner(UL) + RIGHT * 0.42 + DOWN * 0.45)
        blank = Text("_", font=MONO, font_size=30, color=D)
        blank.next_to(prompt, RIGHT, buff=0.22)
        self.play(Create(term), FadeIn(VGroup(prompt, blank)), run_time=0.8)

        a1 = Arrow(boxA.get_right(), term.get_left() + UP * 0.35,
                   color=D, stroke_width=4, buff=0.16, max_tip_length_to_length_ratio=0.09)
        a2 = Arrow(boxB.get_right(), term.get_left() + DOWN * 0.35,
                   color=D, stroke_width=4, buff=0.16, max_tip_length_to_length_ratio=0.09)
        self.play(GrowArrow(a1), GrowArrow(a2), run_time=0.9)

        c1 = cap("Both print nothing. Nothing is not a message.", GOLD, 32)
        self.play(Write(c1), run_time=1.1)
        self.wait(1.9)

        # ---- what was actually thrown away ----------------------------------
        self.play(FadeOut(c1), run_time=0.4)
        err = Text(M["grepRealError"], font=MONO, font_size=22, color=RED)
        err.move_to([-3.3, -1.55, 0])
        bin_ = panel(3.1, 0.86, RED).move_to([3.3, -1.55, 0])
        bint = Text("thrown away", font=SANS, font_size=24,
                    color=RED).move_to(bin_.get_center())
        a3 = Arrow(err.get_right(), bin_.get_left(), color=RED, stroke_width=4,
                   buff=0.18, max_tip_length_to_length_ratio=0.10)
        self.play(FadeIn(err), run_time=0.7)
        self.play(GrowArrow(a3), FadeIn(VGroup(bin_, bint)), run_time=0.8)
        c2 = cap("The top one did say something. It was sent nowhere.", RED, 32)
        self.play(Write(c2), run_time=1.1)
        self.wait(2.2)

        # ---- the positive control -------------------------------------------
        self.play(FadeOut(VGroup(err, bin_, bint, a3, c2, boxB, txtB, subB, a2)),
                  run_time=0.7)
        newtitle = Text("The fix: point it at something you know is there.",
                        font=SANS, weight=BOLD, font_size=42, color=W)
        newtitle.to_edge(UP, buff=0.5)
        self.play(Transform(title, newtitle), run_time=0.8)

        rows = VGroup(*[Text(f, font=MONO, font_size=26, color=GRN)
                        for f in M["grepGoodFiles"]])
        rows.arrange(DOWN, aligned_edge=LEFT, buff=0.26)
        if rows.width > term.width - 0.5:
            rows.scale_to_fit_width(term.width - 0.5)
        rows.move_to(term.get_center())
        fixed = Text("run again without the broken wrapper", font=SANS,
                     font_size=21, color=GRN).move_to(subA.get_center())
        self.play(FadeOut(VGroup(prompt, blank)),
                  FadeOut(subA), FadeIn(fixed), run_time=0.5)
        for r in rows:
            self.play(FadeIn(r, shift=RIGHT * 0.15), run_time=0.45)
        c3 = cap(f'Three answers. Now an empty screen would mean something.',
                 GRN, 32)
        self.play(Write(c3), run_time=1.1)
        self.wait(2.4)
