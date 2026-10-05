#!/usr/bin/env python3
"""THE MECHANISM: what a gain knob does to a waveform that is already near the
lid, and what "clipping" physically is.

⭐ THIS SCENE IS THE FILM'S ANSWER TO ITS OWN AUDIBILITY FAULT. At a −14 LUFS
target the distortion this lesson is about measures tens of decibels below the
music it hides in — correctly measured, and under a laptop speaker's floor. A
waveform being crushed flat against a lid is, by contrast, obvious in one frame.

Everything drawn is arithmetic, not decoration: the wave is a fixed sum of
sines, the lid is ±1, and the red is exactly `x − clamp(x)`. The GAIN NUMBERS
ARE THE FILM'S OWN, read out of MEASUREMENTS.json.

⚠ No LaTeX on this machine: every tick label is a hand-placed Text, and
Axes(include_numbers=True) crashes.
⚠ Text("") has no points and collapses a VGroup.arrange into an overlapping
stack — space with buff and never add an empty Text.
"""
import json, os
import numpy as np
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(os.path.join(HERE, "MEASUREMENTS.json")))
L14 = M["ladder"][0]

FONT = "Helvetica Neue"
BG = "#080B10"
CYAN, VIOLET, RED, WARM, AMBER, DIM = ("#5AD1FF", "#A78BFA", "#FF6B6B",
                                       "#7DF9D6", "#FFB84D", "#7C8798")

# hold times, all named so __main__ can add them up rather than guess
# ⚠ RISE IS 8.0, NOT 6.0, AND THE REASON IS AUDIO, NOT PACING. bursts.lay()
#   is ADDITIVE: with RISE=6.0 the clipped drop-in landed at 9.6 s while the
#   8-second clean excerpt was still running to 11.1 s, and 1.5 s of the bed
#   was the same passage summed with itself (measured peak 0.766 — it did not
#   clip, but the viewer heard two takes at once in a film about clipping).
#   At 8.0 the rise ends exactly where the clean excerpt ends and the clipped
#   one starts half a second later, cleanly.
LEAD, RISE, HOLD, RESID, TAIL = 2.6, 8.0, 2.6, 4.4, 3.2
T_MAX = 4.0                      # x axis in arbitrary "cycles"


def T(*a, **kw):
    """⚠ Text(font=FONT, "x") is a SyntaxError — a keyword before a positional.
    Hence a wrapper rather than a search-and-replace."""
    return Text(*a, font=FONT, **kw)


def wave(t):
    """A stand-in for music: a fundamental with two partials and a slow
    envelope, normalised so its own peak is exactly 1."""
    y = (np.sin(2 * np.pi * t) + 0.42 * np.sin(2 * np.pi * 2 * t + 0.6)
         + 0.22 * np.sin(2 * np.pi * 3 * t + 1.9))
    y = y * (0.72 + 0.28 * np.sin(2 * np.pi * 0.31 * t + 0.4))
    return y / np.max(np.abs(y))


TS = np.linspace(0, T_MAX, 1400)
# ⚠ SCALED TO THE REAL MIX'S REAL PEAK, so the animation is quantitatively
#   faithful rather than merely illustrative: starting at the dry render's own
#   sample peak means the film's own +6.48 dB lands this wave exactly where it
#   landed the render, and the red areas are the right SIZE, not just the right
#   idea. (The first render started at full scale and clipped grotesquely.)
YS = wave(TS) * 10 ** (M["loudness"]["dry"]["samplePeakDbfs"] / 20)


class ClipCeiling(Scene):
    def construct(self):
        self.camera.background_color = BG
        ax = Axes(x_range=[0, T_MAX, 1.0], y_range=[-2.2, 2.2, 1.0],
                  x_length=11.0, y_length=4.9,
                  axis_config={"color": "#39424F", "stroke_width": 2},
                  tips=False)
        ax.shift(DOWN * 0.55)
        self.add(ax)
        for yv in (-2, -1, 0, 1, 2):
            self.add(T(f"{yv:+d}" if yv else "0", font_size=19, color=DIM)
                     .next_to(ax.c2p(0, yv), LEFT, buff=0.16))

        lid_hi = DashedLine(ax.c2p(0, 1), ax.c2p(T_MAX, 1), color=AMBER,
                            stroke_width=3, dash_length=0.13)
        lid_lo = DashedLine(ax.c2p(0, -1), ax.c2p(T_MAX, -1), color=AMBER,
                            stroke_width=3, dash_length=0.13)
        lid_txt = T("0 dBFS — the highest number the file can hold",
                    font_size=22, color=AMBER)
        lid_txt.next_to(ax.c2p(T_MAX, 1), UP, buff=0.12).shift(LEFT * 3.1)
        title = T("TURNING IT UP, AND WHAT THE LID DOES",
                  font_size=34, color=WARM).to_edge(UP, buff=0.30)
        self.add(title, lid_hi, lid_lo, lid_txt)

        g = ValueTracker(1.0)
        gmax = 10 ** (L14["gainDb"] / 20)

        def curve_clean():
            y = np.clip(YS * g.get_value(), -2.15, 2.15)
            v = VMobject(color=VIOLET, stroke_width=2.0, stroke_opacity=0.55)
            v.set_points_smoothly([ax.c2p(t, yy) for t, yy in zip(TS, y)])
            return v

        def curve_stored():
            y = np.clip(YS * g.get_value(), -1.0, 1.0)
            v = VMobject(color=CYAN, stroke_width=4.6)
            v.set_points_smoothly([ax.c2p(t, yy) for t, yy in zip(TS, y)])
            return v

        def lost():
            y = YS * g.get_value()
            grp = VGroup()
            over = np.abs(y) > 1.0
            if not over.any():
                return grp
            d = np.diff(np.concatenate([[0], over.view(np.int8), [0]]))
            for a, b in zip(np.flatnonzero(d == 1), np.flatnonzero(d == -1)):
                seg = slice(a, b)
                sgn = np.sign(y[seg][0])
                pts = ([ax.c2p(t, min(2.15, max(-2.15, yy)))
                        for t, yy in zip(TS[seg], y[seg])]
                       + [ax.c2p(t, sgn) for t in TS[seg][::-1]])
                grp.add(Polygon(*pts, stroke_width=0, fill_color=RED,
                                fill_opacity=0.85))
            return grp

        clean = always_redraw(curve_clean)
        stored = always_redraw(curve_stored)
        red = always_redraw(lost)
        self.add(clean, stored, red)

        cap = T("this is the mix, at its own measured peak, inside the lid",
                font_size=25, color=CYAN)
        # ⚠ LEFT-ALIGNED, and kept clear of about x = 0.72 of the frame: the
        #   film burns a level meter into the bottom-right corner afterwards,
        #   and a centred caption runs straight under it.
        cap.next_to(ax, DOWN, buff=0.42).to_edge(LEFT, buff=0.55)
        gain_lbl = always_redraw(
            lambda: T(f"gain  +{20 * np.log10(g.get_value()):4.2f} dB",
                      font_size=30, color=WARM).next_to(ax, UP, buff=0.12)
            .shift(LEFT * 4.1))
        self.add(gain_lbl)
        self.play(FadeIn(cap, shift=UP * 0.1), run_time=LEAD)

        cap2 = T(f'+{L14["gainDb"]:.2f} dB is what this mix needs to reach '
                 f'−14 LUFS', font_size=25, color=VIOLET).move_to(cap, aligned_edge=LEFT)
        self.play(FadeOut(cap), FadeIn(cap2), run_time=0.5)
        self.play(g.animate.set_value(gmax), run_time=RISE, rate_func=linear)

        cap3 = T("everything in red is gone — the file stores the flat line "
                 "instead", font_size=25, color=RED).move_to(cap, aligned_edge=LEFT)
        self.play(FadeOut(cap2), FadeIn(cap3), run_time=0.5)
        self.wait(HOLD)

        # ── the residual: what the flattening ADDED, drawn as its own signal.
        y = YS * gmax
        diff = np.clip(y, -1, 1) - y
        # ⚠ SCALE IT TO FIT, and say by how much. The first render multiplied
        #   the difference by a fixed six and the trace shot straight off the
        #   top of the frame — found by looking at a frame, not by any gate.
        k = 0.62 / max(float(np.max(np.abs(diff))), 1e-9)
        resid = VMobject(color=RED, stroke_width=4.0)
        resid.set_points_smoothly([ax.c2p(t, yy * k - 1.62)
                                   for t, yy in zip(TS, diff)])
        cap4 = VGroup(
            T("the difference on its own, drawn larger so you can see it:",
              font_size=24, color=RED),
            T("a buzz that was not in the music", font_size=24, color=RED),
        ).arrange(DOWN, buff=0.12, aligned_edge=LEFT)
        # ⚠ UP, NOT DOWN. A two-line VGroup centred where the one-line caption sat
        #   ran off the BOTTOM of the frame — the second line was half a line
        #   of pixels in the exported still. Found by looking at the still.
        cap4.move_to(cap, aligned_edge=LEFT).shift(UP * 0.20)
        self.play(FadeOut(cap3), FadeIn(cap4),
                  clean.animate.set_stroke(opacity=0.18),
                  Create(resid), run_time=RESID)
        self.wait(TAIL)


if __name__ == "__main__":
    total = LEAD + 0.5 + RISE + 0.5 + HOLD + RESID + TAIL
    print(json.dumps({"scene": "ClipCeiling", "total": round(total, 3),
                      "audio": [{"wav": "ab-clean14.wav", "atSec": round(LEAD + 0.5, 3)},
                                {"wav": "ab-clip14.wav",
                                 "atSec": round(LEAD + 0.5 + RISE + 0.5, 3)}]},
                     indent=1))
