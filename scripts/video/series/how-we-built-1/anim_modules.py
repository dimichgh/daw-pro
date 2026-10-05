"""The shape of the thing — six modules, DRAWN rather than listed.

⚠ NO LaTeX on this machine: every label is a `Text`; `Axes` is never used.
⚠ `Text("")` collapses a VGroup.arrange, so nothing here is ever empty.
⚠⚠ THE FIRST RENDER OVERFLOWED THE FRAME ON THREE SIDES and was a valid mp4
   the whole way. Every element is therefore built first, grouped, and then
   scaled to fit a measured safe box — and the scene ASSERTS the fit rather
   than trusting the arithmetic.

Every line count is read from MEASUREMENTS.json, so the picture cannot drift
from the repository it describes.
"""
import json, os, sys
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
MOD = {m["name"]: m for m in M["modules"]}

BG, A, B, W, D, GOLD = "#0b0d12", "#82cdff", "#b48cff", "#eef2ff", "#969eaf", "#ffc67a"
config.background_color = BG
SAFE_W, SAFE_H = 12.4, 5.3          # inside a 14.22 x 8 frame, with margins


def box(title, sub, lines, w, colour):
    r = RoundedRectangle(width=w, height=1.9, corner_radius=0.14,
                         stroke_color=colour, stroke_width=3,
                         fill_color="#111621", fill_opacity=1)
    t = Text(title, font="SF Pro Display", weight=BOLD, font_size=32, color=W)
    s = Text(sub, font="SF Pro Display", font_size=22, color=D)
    n = Text(f"{lines:,} lines", font="SF Mono", font_size=19, color=GOLD)
    g = VGroup(t, s, n).arrange(DOWN, buff=0.14).move_to(r.get_center())
    return VGroup(r, g)


class Modules(Scene):
    def construct(self):
        title = Text("Six parts, and one idea that ties them together",
                     font="SF Pro Display", weight=BOLD, font_size=38, color=W)
        title.to_edge(UP, buff=0.35)

        app = box("DAWApp + DAWAppKit", "what you see and click",
                  MOD["DAWApp"]["lines"] + MOD["DAWAppKit"]["lines"], 6.2, A)
        core = box("DAWCore", "the model: tracks, clips, notes, tempo",
                   MOD["DAWCore"]["lines"], 6.2, A)
        eng = box("DAWEngine", "makes the sound, on a deadline",
                  MOD["DAWEngine"]["lines"], 6.2, GOLD)
        stack = VGroup(app, core, eng).arrange(DOWN, buff=0.95)

        ctl = box("DAWControl", "a socket: every action, as a message",
                  MOD["DAWControl"]["lines"], 6.0, B)
        ai = box("AIServices + MCP", "how an AI drives it",
                 MOD["AIServices"]["lines"], 6.0, B)
        side = VGroup(ctl, ai).arrange(DOWN, buff=0.95)
        side.next_to(stack, RIGHT, buff=0.9)
        side.align_to(core, UP)

        a1 = Arrow(app[0].get_bottom(), core[0].get_top(), buff=0.07,
                   stroke_width=4, color=D, max_tip_length_to_length_ratio=0.2)
        a2 = Arrow(core[0].get_bottom(), eng[0].get_top(), buff=0.07,
                   stroke_width=4, color=D, max_tip_length_to_length_ratio=0.2)
        a3 = Arrow(ctl[0].get_left(), core[0].get_right(), buff=0.09,
                   stroke_width=5, color=B, max_tip_length_to_length_ratio=0.16)
        a4 = Arrow(ai[0].get_top(), ctl[0].get_bottom(), buff=0.07,
                   stroke_width=5, color=B, max_tip_length_to_length_ratio=0.28)

        diagram = VGroup(stack, side, a1, a2, a3, a4)
        k = min(SAFE_W / diagram.width, SAFE_H / diagram.height)
        diagram.scale(k).move_to(ORIGIN).shift(DOWN * 0.25)
        # ⚠ ASSERT THE FIT. A frame overflow is a valid mp4 and a wrong picture.
        if diagram.width > SAFE_W + 1e-6 or diagram.height > SAFE_H + 1e-6:
            sys.exit(f"diagram {diagram.width:.2f}x{diagram.height:.2f} exceeds safe box")
        if diagram.get_left()[0] < -6.9 or diagram.get_right()[0] > 6.9:
            sys.exit("diagram runs off the frame horizontally")

        def caption(s):
            return Text(s, font="SF Pro Display", font_size=25,
                        color=W).to_edge(DOWN, buff=0.28)

        self.play(FadeIn(title, shift=DOWN * 0.15), run_time=1.1)
        self.wait(0.7)
        for b, blurb in ((app, "The window. Buttons, faders, the grid you draw notes on."),
                         (core, "The facts of your song. It has never heard a sound."),
                         (eng, "The part with a deadline. This is where it gets hard.")):
            c = caption(blurb)
            self.play(FadeIn(b, scale=0.94), FadeIn(c), run_time=0.85)
            self.wait(1.9)
            self.play(FadeOut(c), run_time=0.35)
        self.play(GrowArrow(a1), GrowArrow(a2), run_time=0.9)
        self.wait(0.9)

        c = caption("Everything the window can do, a message can do too.")
        self.play(FadeIn(ctl, scale=0.94), run_time=0.8)
        self.play(GrowArrow(a3), FadeIn(c), run_time=0.9)
        self.wait(2.3)
        self.play(FadeOut(c), run_time=0.35)

        c2 = caption("An assistant is just one more thing sending messages.")
        self.play(FadeIn(ai, scale=0.94), run_time=0.8)
        self.play(GrowArrow(a4), FadeIn(c2), run_time=0.9)
        self.wait(2.4)
        self.play(FadeOut(c2), run_time=0.4)

        band = SurroundingRectangle(diagram, buff=0.22, color=A, stroke_width=3,
                                    corner_radius=0.2)
        tot = Text(f'{M["swiftLines"]:,} lines of Swift, in {M["swiftFiles"]} files',
                   font="SF Mono", font_size=25, color=A).to_edge(DOWN, buff=0.28)
        self.play(Create(band), FadeIn(tot), run_time=1.2)
        self.wait(2.6)
