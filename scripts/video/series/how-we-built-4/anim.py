"""Part 4's two animated explanations.

  Vacuous — a check that cannot fail. Green, forever, having measured nothing.
  Falsify — the loop this project actually uses: break it on purpose, and check
            that the test notices.

⚠ NO LaTeX in this install: every label is a hand-placed `Text`.
⚠ The film burns a level meter into the BOTTOM-RIGHT corner, so captions are
routed through `_place_cap()` and kept left of x = 4.4.
"""
import json, os
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))

BG, A, B, W, D, GOLD, GRN, RED = ("#0b0d12", "#82cdff", "#b48cff", "#eef2ff",
                                  "#969eaf", "#ffc67a", "#76ffc4", "#ff6b5d")
config.background_color = BG
CAP_RIGHT = 4.4
MONO, SANS = "Menlo", "SF Pro Display"


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


class Caption:
    """⚠ ONE caption on screen at a time. The first cut of Falsify faded out
    everything EXCEPT the caption before writing the next one, so two sentences
    drew on top of each other for two seconds. No gate can see that; I saw it by
    pulling the frame. This holds the live caption and always retires it."""

    def __init__(self, scene):
        self.s, self.cur = scene, None

    def say(self, text, colour=W, rt=0.7):
        new = cap(text, colour)
        if self.cur is not None:
            self.s.play(FadeOut(self.cur), FadeIn(new), run_time=rt)
        else:
            self.s.play(FadeIn(new), run_time=rt)
        self.cur = new

    def clear(self, rt=0.4):
        if self.cur is not None:
            self.s.play(FadeOut(self.cur), run_time=rt)
            self.cur = None


def panel(w, h, colour=D):
    return RoundedRectangle(width=w, height=h, corner_radius=0.14,
                            stroke_color=colour, stroke_width=2.4,
                            fill_color="#11141b", fill_opacity=1.0)


class Vacuous(Scene):
    """A check that cannot fail. It is green because it looked at nothing."""

    def construct(self):
        C = Caption(self)
        title = Text("A check that cannot fail", font=SANS, weight=BOLD,
                     font_size=46, color=W).to_edge(UP, buff=0.5)
        self.play(FadeIn(title, shift=DOWN * 0.2), run_time=0.8)

        rule = Text('"every one of these is fine"', font=SANS, font_size=34, color=GOLD)
        rule.move_to([-1.1, 2.0, 0])
        self.play(Write(rule), run_time=1.0)

        # --- a box with things in it, one of which is wrong ------------------
        box = panel(5.6, 1.9).move_to([-1.1, 0.35, 0])
        self.play(Create(box), run_time=0.7)
        good = [Circle(radius=0.30, stroke_color=GRN, stroke_width=4,
                       fill_color=GRN, fill_opacity=0.30) for _ in range(4)]
        bad = Circle(radius=0.30, stroke_color=RED, stroke_width=4,
                     fill_color=RED, fill_opacity=0.35)
        row = VGroup(*good[:2], bad, *good[2:]).arrange(RIGHT, buff=0.52)
        row.move_to(box.get_center())
        self.play(LaggedStart(*[GrowFromCenter(m) for m in row], lag_ratio=0.15),
                  run_time=1.2)
        verdict = Text("FAILS", font=SANS, weight=BOLD, font_size=40, color=RED)
        verdict.next_to(box, RIGHT, buff=0.7)
        self.play(Indicate(bad, color=RED, scale_factor=1.4),
                  FadeIn(verdict, shift=LEFT * 0.2), run_time=1.1)
        C.say("It looked, and it found the bad one. Good.", D, 0.6)
        self.wait(1.4)

        # --- the same check, on nothing at all -------------------------------
        self.play(FadeOut(row), FadeOut(verdict), run_time=0.7)
        empty = Text("(nothing to check)", font=SANS, font_size=27, color=D)
        empty.move_to(box.get_center())
        self.play(FadeIn(empty), run_time=0.7)
        ok = Text("PASSES", font=SANS, weight=BOLD, font_size=40, color=GRN)
        ok.next_to(box, RIGHT, buff=0.7)
        self.play(FadeIn(ok, shift=LEFT * 0.2), Flash(box, color=GRN, line_length=0.3),
                  run_time=1.0)
        C.say("The same check. The same green. It measured nothing.", GOLD)
        self.wait(1.8)

        # --- the one-line proof ----------------------------------------------
        C.clear()
        self.play(FadeOut(box), FadeOut(empty), FadeOut(ok), FadeOut(rule), run_time=0.6)
        code = Text('[].every(x => false)', font=MONO, font_size=42, color=A)
        arrow = Text("→", font=SANS, font_size=42, color=D)
        val = Text(M["vacuityLive"].split()[0], font=MONO, weight=BOLD,
                   font_size=46, color=GRN)
        g = VGroup(code, arrow, val).arrange(RIGHT, buff=0.5).move_to([-1.0, 0.5, 0])
        self.play(Write(code), run_time=0.9)
        self.play(FadeIn(arrow), FadeIn(val, shift=LEFT * 0.2), run_time=0.8)
        C.say("An empty list satisfies every rule you can write.", W)
        self.wait(2.2)


class Falsify(Scene):
    """Green, red, green. Only the middle step gives the green a meaning."""

    def construct(self):
        C = Caption(self)
        title = Text("Break it on purpose", font=SANS, weight=BOLD,
                     font_size=46, color=W).to_edge(UP, buff=0.5)
        self.play(FadeIn(title, shift=DOWN * 0.2), run_time=0.8)

        prog = panel(4.4, 2.6).move_to([-3.9, 0.6, 0])
        test = panel(4.9, 2.6).move_to([1.9, 0.6, 0])
        plab = Text("the program", font=SANS, font_size=26, color=D)
        tlab = Text("the test", font=SANS, font_size=26, color=D)
        plab.next_to(prog, UP, buff=0.16)
        tlab.next_to(test, UP, buff=0.16)
        num = Text("4096", font=MONO, weight=BOLD, font_size=44, color=A)
        num.move_to(prog.get_center())
        ans = Text("lines up", font=SANS, font_size=30, color=GRN)
        ans.move_to(test.get_center())
        link = Arrow(prog.get_right(), test.get_left(), buff=0.16,
                     stroke_width=4, color=D)
        self.play(Create(prog), Create(test), FadeIn(plab), FadeIn(tlab),
                  GrowArrow(link), run_time=1.0)
        self.play(FadeIn(num), run_time=0.5)
        self.play(FadeIn(ans), Flash(test, color=GRN, line_length=0.3), run_time=0.9)
        lamp = Text("GREEN", font=SANS, weight=BOLD, font_size=36, color=GRN)
        lamp.next_to(test, DOWN, buff=0.55)
        self.play(FadeIn(lamp), run_time=0.5)
        C.say("So far this proves nothing. A test that always passes "
              "looks like this too.", D, 0.8)
        self.wait(1.8)

        # --- plant ------------------------------------------------------------
        zero = Text("0", font=MONO, weight=BOLD, font_size=52, color=RED)
        zero.move_to(prog.get_center())
        self.play(Transform(num, zero), Indicate(prog, color=RED, scale_factor=1.06),
                  run_time=1.0)
        C.say("One number, in shipping code, replaced by zero.", RED)
        self.wait(1.0)

        errs = M["plantErrors"]
        rows = VGroup(*[Text(f"out by {e} samples", font=MONO, font_size=23, color=RED)
                        for e in errs]).arrange(DOWN, buff=0.16, aligned_edge=LEFT)
        rows.move_to(test.get_center())
        red = Text("RED", font=SANS, weight=BOLD, font_size=36, color=RED)
        red.move_to(lamp.get_center())
        self.play(FadeOut(ans), FadeIn(rows), Transform(lamp, red),
                  Flash(test, color=RED, line_length=0.3), run_time=1.2)
        C.say("Four failures, each one exactly its own plug-in's delay.", GOLD, 0.8)
        self.wait(2.0)

        # --- restore ----------------------------------------------------------
        back = Text("4096", font=MONO, weight=BOLD, font_size=44, color=A)
        back.move_to(prog.get_center())
        ans2 = Text("lines up", font=SANS, font_size=30, color=GRN)
        ans2.move_to(test.get_center())
        grn = Text("GREEN", font=SANS, weight=BOLD, font_size=36, color=GRN)
        grn.move_to(lamp.get_center())
        self.play(Transform(num, back), FadeOut(rows), FadeIn(ans2),
                  Transform(lamp, grn), run_time=1.2)
        C.say("Now the green means something. It is the same green.", W, 0.8)
        self.wait(2.4)
