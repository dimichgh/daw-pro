#!/usr/bin/env python3
"""THE MECHANISM: why two nearly-identical pitches pulse.

⭐ Beating is the one part of this lesson a viewer can verify with their own
ears, and it is far easier to SEE than to derive. Two waves at 440 and 446 Hz
slide through each other; where the peaks line up the sum is twice as tall,
where a peak meets a trough it cancels. Six times a second, because they differ
by six cycles a second.

⭐ THE PICTURE AND THE SOUND ARE THE SAME EVENT. The first HALF runs at zero
difference (two A's in tune, from `unison.wav`) and the second at the comma
(`comma.wav`); the switch happens at exactly SPLIT seconds, which is where the
audio changes too. __main__ prints the offsets; bursts.py lays the wavs at them
rather than at a number typed twice.

⚠ THE SCOPE WINDOW IS REAL. It shows 30 ms of genuine 440/446 Hz waveform —
nothing here is slowed down or exaggerated — so the drift you see is the drift
that is happening. What is NOT real-time is the eye: at 30 fps a 6 Hz beat gets
five frames a cycle, which is enough to read as a pulse and is why the envelope
strip underneath is drawn as well.

⚠ NO LaTeX; every label is a plain Text. Bottom-right is reserved for the
burned-in corner meter, so captions are pinned LEFT.
"""
import json
import numpy as np
from manim import *

SPLIT = 12.0
F_A, DF = 440.0, 1200 * 0  # placeholder; DF set below from the ratio
COMMA = 1200 * np.log2((3 / 2) ** 12 / 2 ** 7)
F_B = F_A * 2 ** (COMMA / 1200)
BEAT = F_B - F_A
TMAX = 0.030

FONT = "Helvetica Neue"
BG = "#080B10"
CYAN, VIOLET, WARM, DIM, RED = "#5AD1FF", "#A78BFA", "#7DF9D6", "#7C8798", "#FF6B6B"


def T(*a, **kw):
    return Text(*a, font=FONT, **kw)


class BeatMechanism(Scene):
    def construct(self):
        self.camera.background_color = BG
        t = ValueTracker(0.0)
        live = ValueTracker(0.0)          # 0 = in tune, 1 = comma apart

        # ⚠ TWO AXES, NOT ONE. The first render drew the SUM on top of its own
        # two components in the same box; the white trace was legible but the
        # relationship — "this one is those two added" — was not, and the tick
        # labels ran straight through the waveforms because they were placed at
        # y = 0, which is the MIDDLE of a bipolar plot, not the bottom.
        AXCFG = {"color": "#39424F", "stroke_width": 2}
        ax = Axes(x_range=[0, TMAX, 0.005], y_range=[-1.35, 1.35, 1],
                  x_length=10.2, y_length=2.05, axis_config=AXCFG,
                  tips=False).move_to(UP * 1.55 + LEFT * 0.75)
        ax2 = Axes(x_range=[0, TMAX, 0.005], y_range=[-2.3, 2.3, 1],
                   x_length=10.2, y_length=2.35, axis_config=AXCFG,
                   tips=False).move_to(DOWN * 0.75 + LEFT * 0.75)
        xt = VGroup(*[T(f"{int(v*1000)}", font_size=16, color=DIM)
                      .move_to(ax2.c2p(v, -2.3) + DOWN * 0.28)
                      for v in np.arange(0, TMAX + 1e-9, 0.005)])
        xl = T("milliseconds", font_size=17, color=DIM)
        xl.next_to(xt, DOWN, buff=0.06).align_to(ax2, RIGHT)

        def wave(shift, colour, axes, amp=1.0):
            return always_redraw(lambda: axes.plot(
                lambda x: amp * np.sin(2 * np.pi * F_A * x + shift()),
                x_range=[0, TMAX, TMAX / 900], color=colour, stroke_width=3))

        phase = lambda: 2 * np.pi * BEAT * live.get_value() * t.get_value()
        wa = wave(lambda: 0.0, CYAN, ax)
        wb = wave(phase, VIOLET, ax)
        summ = always_redraw(lambda: ax2.plot(
            lambda x: (np.sin(2 * np.pi * F_A * x)
                       + np.sin(2 * np.pi * F_A * x + phase())),
            x_range=[0, TMAX, TMAX / 900], color=WHITE, stroke_width=4))

        lab_a = T("440.000 Hz", font_size=20, color=CYAN)
        lab_b = always_redraw(lambda: T(
            "440.000 Hz" if live.get_value() < 0.5 else f"{F_B:.3f} Hz",
            font_size=20, color=VIOLET).next_to(lab_a, RIGHT, buff=0.45))
        leg = VGroup(lab_a)
        leg.to_corner(UL, buff=0.42)
        sumlab = T("the two added together — what reaches your ear",
                   font_size=19, color=WHITE)
        sumlab.next_to(ax2, UP, buff=0.06).align_to(ax2, LEFT)

        # the envelope strip: how tall the sum is right now, as a level bar
        bar_bg = Rectangle(width=9.4, height=0.42, color="#26303C", stroke_width=2)
        bar_bg.move_to(DOWN * 2.98 + LEFT * 1.25)
        bar = always_redraw(lambda: Rectangle(
            width=max(0.02, 9.4 * abs(np.cos(phase() / 2))), height=0.42,
            color=WARM, fill_color=WARM, fill_opacity=0.85, stroke_width=0)
            .align_to(bar_bg, LEFT).set_y(bar_bg.get_y()))
        barlab = T("how loud the sum is, right now", font_size=18, color=DIM)
        barlab.next_to(bar_bg, UP, buff=0.12).align_to(bar_bg, LEFT)
        state = always_redraw(lambda: T(
            "both at 440.000 Hz — nothing moves" if live.get_value() < 0.5
            else f"one of them {COMMA:.2f} cents sharp — {BEAT:.2f} pulses a second",
            font_size=23, color=WARM if live.get_value() < 0.5 else RED)
            .to_edge(DOWN, buff=0.3).to_edge(LEFT, buff=0.75))

        self.add(ax, ax2, xt, xl, wa, wb, summ, leg, lab_b, sumlab,
                 bar_bg, bar, barlab, state)
        self.play(t.animate.set_value(SPLIT), run_time=SPLIT, rate_func=linear)
        live.set_value(1.0)
        self.play(t.animate.set_value(2 * SPLIT), run_time=SPLIT, rate_func=linear)


if __name__ == "__main__":
    print(json.dumps({"total": 2 * SPLIT,
                      # ⚠ THE PRE-GAINED PAIR, not the raw renders: ab-unison and ab-comma
                      # carry ONE shared static gain (measure.py), so the level
                      # relationship the film demonstrates survives.
                      "audio": [{"wav": "ab-unison.wav", "atSec": 0.0},
                                {"wav": "ab-comma.wav", "atSec": SPLIT}],
                      "beatHz": BEAT, "commaCents": COMMA}))
