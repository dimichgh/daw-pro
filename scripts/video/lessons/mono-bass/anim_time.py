#!/usr/bin/env python3
"""THE ATTENTION MARKER: a playhead sweeping a MEASURED chart at real time.

The answer to "I could not hear it" is not *listen harder*; it is to say WHEN
to listen and WHERE. Both curves here are short-time band levels that measure.py
computed off the two renders — nothing is drawn by hand.

⚠ THE SHADED WINDOWS ARE DERIVED, NEVER CHOSEN BY EYE. measure.py keeps every
window in which the 6 ms mono fold is more than 6 dB quieter in 40–130 Hz than
the 0 ms one, merges gaps under 120 ms and drops anything under 150 ms. The
unshaded slivers between them are the notes where the two versions behave the
same and there is nothing to hear.

⚠ run_time MUST equal the span of audio laid underneath. __main__ prints the
sweep offsets as JSON and bursts.py builds the audio from them — a playhead
pointing at the wrong instant is worse than no marker at all.

⚠ No LaTeX here: every tick label is a hand-placed Text.
"""
import json, os
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(os.path.join(HERE, "MEASUREMENTS.json")))
C = M["_chart"]
T_MAX = C["len"]
LEAD, TAG = 0.6, 0.4          # fade-in, then the per-series tag
GAP = 0.4                     # between the two sweeps

FONT = "Helvetica Neue"     # manim's default face is a serif; every other
                            # picture in this film is sans, and a font change
                            # mid-film reads as a different video.


def T(*a, **kw):
    """Text in the film's face. ⚠ Text(font=FONT, "x") is a SyntaxError — a
    keyword before a positional — which is why this wrapper exists rather than
    a search-and-replace."""
    return Text(*a, font=FONT, **kw)
BG = "#080B10"
CYAN, RED, WARM, DIM, SHADE = "#5AD1FF", "#FF6B6B", "#7DF9D6", "#7C8798", "#1B2733"
Y0, Y1 = -58, -18


class FoldOverTime(Scene):
    def construct(self):
        self.camera.background_color = BG
        ax = Axes(x_range=[0, T_MAX, 1.0], y_range=[Y0, Y1, 10],
                  x_length=10.6, y_length=4.6,
                  axis_config={"color": "#39424F", "stroke_width": 2,
                               "include_ticks": True}, tips=False)
        ax.to_edge(DOWN, buff=1.05)
        labels = VGroup()
        for xv in range(0, int(T_MAX) + 1):
            labels.add(T(f"{xv}", font_size=18, color=DIM)
                       .next_to(ax.c2p(xv, Y0), DOWN, buff=0.14))
        for yv in range(Y0, Y1 + 1, 10):
            labels.add(T(f"{yv}", font_size=18, color=DIM)
                       .next_to(ax.c2p(0, yv), LEFT, buff=0.14))
        self.add(ax, labels)
        # ⚠ ROTATE FIRST, THEN PLACE. next_to() measures the mobject's CURRENT
        # bounding box, so rotating afterwards swings a wide label off the frame
        # — the first render of this scene had no y-axis label at all.
        self.add(T("level of the bass, 40–130 Hz (dB)", font_size=21,
                      color=DIM).rotate(PI / 2).next_to(ax, LEFT, buff=0.18)
                 .shift(LEFT * 0.55))     # clear of the tick numbers, which
                                          # next_to(ax) cannot see
        self.add(T("seconds", font_size=20, color=DIM).next_to(ax, DOWN, buff=0.58))
        self.add(T("WHAT THE MONO SUM DID, NOTE BY NOTE",
                      font_size=33, color=WARM).to_edge(UP, buff=0.32))

        for a, b in C["windows"]:
            self.add(Polygon(ax.c2p(a, Y0), ax.c2p(b, Y0), ax.c2p(b, Y1), ax.c2p(a, Y1),
                             stroke_width=0, fill_color=SHADE,
                             fill_opacity=1).set_z_index(-2))

        listen = T(f"listen in the shaded bars — up to "
                      f"{C['max_diff_db']:.0f} dB of bass disappears there",
                      font_size=25, color=WARM).next_to(ax, UP, buff=0.26)
        self.play(FadeIn(listen, shift=DOWN * 0.12), run_time=LEAD)

        def trace(key, col):
            vm = VMobject(color=col, stroke_width=4.2)
            vm.set_points_smoothly([ax.c2p(t, max(g, Y0)) for t, g in C[key]])
            return vm

        head = Line(ax.c2p(0, Y0), ax.c2p(0, Y1), color=WARM, stroke_width=2.6)
        done = []
        for key, col, name, note in (
                ("s0", WARM, "no offset", "every note arrives at full weight"),
                ("s6", RED, "6 ms late", "the notes on the notch fall off a cliff")):
            vm = trace(key, col)
            tag = VGroup(T(name, font_size=28, color=col),
                         T(note, font_size=21, color=col)).arrange(DOWN, buff=0.10)
            tag.next_to(ax, UP, buff=0.22)
            self.play(FadeOut(listen if not done else done[-1][1]), FadeIn(tag),
                      run_time=TAG)
            head.move_to(ax.c2p(0, (Y0 + Y1) / 2))
            self.add(head)
            self.play(Create(vm), head.animate.move_to(ax.c2p(T_MAX, (Y0 + Y1) / 2)),
                      run_time=T_MAX, rate_func=linear)
            self.remove(head)
            done.append((vm, tag))
            if key == "s0":
                vm.set_stroke(opacity=0.5)
                self.wait(GAP)

        self.play(FadeOut(done[-1][1]), done[0][0].animate.set_stroke(opacity=1.0),
                  run_time=0.5)
        self.add(T("same notes, same instrument, same performance — one track "
                      "six milliseconds late", font_size=24, color=DIM)
                 .next_to(ax, UP, buff=0.28))
        self.wait(1.6)


if __name__ == "__main__":
    a = LEAD + TAG
    b = a + T_MAX + GAP + TAG
    print(json.dumps({"scene": "FoldOverTime", "tMax": T_MAX,
                      "total": b + T_MAX + 0.5 + 1.6,
                      "audio": [{"wav": "chart0.wav", "atSec": round(a, 3)},
                                {"wav": "chart6.wav", "atSec": round(b, 3)}],
                      "windows": C["windows"]}, indent=1))
