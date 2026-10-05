#!/usr/bin/env python3
"""DEMO 3's chart: what a release time actually does, drawn from measured gain.

⚠️ EVERY POINT IS MEASURED, not drawn. `gaincurve.py` divides the compressed
render by the dry one sample for sample (exact, because mix=1 and makeup=0), so
the curve on screen IS the compressor's own gain signal. A hand-drawn
exponential would look the same to a viewer and would be a lie in a film whose
premise is predict-then-measure.

⭐ THE ATTENTION MARKER LIVES HERE. The user could not hear the difference and
was right to say so; the answer is not "listen harder", it is to say WHEN to
listen and WHERE. A playhead sweeps the chart AT REAL TIME against the same
audio the viewer is hearing, and the gaps between kicks -- the only place the
two settings differ -- are shaded and labelled. `run_time` MUST equal the span
of audio underneath or the playhead is pointing at the wrong moment, which is
worse than no marker at all.
"""
import json, os
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = json.load(open(os.path.join(HERE, "gaincurve.json")))

T_MAX = 3.0          # the first 3 s of the loop -- two kicks and two snares.
                     # MUST match the audio window the assembler lays under it.
CYAN, VIOLET, WARM, DIM = "#5AD1FF", "#A78BFA", "#7DF9D6", "#6E7A8A"
SHADE = "#1B2733"

# ⚠️ DERIVED FROM THE TWO CURVES, NOT CHOSEN BY EYE. These are every window in
# which the fast setting is more than 3 dB less reduced than the slow one --
# i.e. literally where the two settings differ, which is the only defensible
# definition of "listen here". Measured peak difference 5.7 dB. The unshaded
# slivers between them are the hits themselves, where both settings are
# clamping equally and there is nothing to hear.
GAPS = [(0.05, 0.60), (0.65, 1.24), (1.55, 1.80), (1.84, 2.40), (2.45, 3.00)]


def series(name):
    return [(t, g) for t, g in DATA[name] if t <= T_MAX]


class ReleaseCurve(Scene):
    def construct(self):
        self.camera.background_color = "#080B10"
        ax = Axes(x_range=[0, T_MAX, 0.5], y_range=[-8, 1, 2],
                  x_length=11, y_length=4.6,
                  axis_config={"color": DIM, "stroke_width": 2,
                               "include_ticks": True, "font_size": 20},
                  tips=False)
        ax.to_edge(DOWN, buff=1.0)

        # ⚠️ Hand-placed as Text. `include_numbers` renders each number through
        # MathTex, which wants a LaTeX install this machine does not have -- and
        # the first cut of this chart shipped with ticks and NO numbers, a
        # measurement chart refusing to say what its own scale is.
        labels = VGroup()
        for xv in (0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0):
            labels.add(Text(f"{xv:.1f}", font_size=18, color=DIM)
                       .next_to(ax.c2p(xv, -8), DOWN, buff=0.14))
        for yv in (0, -2, -4, -6, -8):
            labels.add(Text(f"{yv}", font_size=18, color=DIM)
                       .next_to(ax.c2p(0, yv), LEFT, buff=0.14))
        self.add(ax, labels)
        self.add(Text("gain reduction (dB)", font_size=21, color=DIM)
                 .next_to(ax, LEFT, buff=0.15).rotate(PI / 2))
        self.add(Text("seconds", font_size=21, color=DIM).next_to(ax, DOWN, buff=0.6))

        # 0 dB is the line the whole chapter is about: at 0 the compressor has
        # LET GO. Fast touches it between every hit; slow never reaches it.
        zero = DashedLine(ax.c2p(0, 0), ax.c2p(T_MAX, 0),
                          color=DIM, stroke_width=1.6, dash_length=0.08)
        self.add(zero, Text("0 = let go", font_size=19, color=DIM)
                 .next_to(ax.c2p(T_MAX, 0), RIGHT, buff=0.12))

        # THE LISTEN WINDOWS, shaded before anything moves so the viewer knows
        # where to point their ears before the sound starts.
        for a, b in GAPS:
            self.add(Polygon(ax.c2p(a, -8), ax.c2p(b, -8), ax.c2p(b, 1), ax.c2p(a, 1),
                             stroke_width=0, fill_color=SHADE, fill_opacity=1).set_z_index(-2))
        listen = Text("listen HERE — the pad between the hits (5.7 dB apart)",
                      font_size=24, color=WARM).next_to(ax, UP, buff=0.28)

        title = Text("release: how fast the compressor lets go",
                     font_size=33, color=WARM).to_edge(UP, buff=0.35)
        self.add(title)
        self.play(FadeIn(listen, shift=DOWN * 0.15), run_time=0.5)

        def trace(name, col):
            vm = VMobject(color=col, stroke_width=4.5)
            vm.set_points_smoothly([ax.c2p(t, g) for t, g in series(name)])
            return vm

        head = Line(ax.c2p(0, -8), ax.c2p(0, 1), color=WARM, stroke_width=2.5)
        done = []
        for name, col, note in (
                ("30 ms", CYAN, "back to zero between every hit"),
                ("800 ms", VIOLET, "never gets back to zero at all")):
            vm = trace(name, col)
            tag = VGroup(Text(name, font_size=27, color=col),
                         Text(note, font_size=20, color=col)).arrange(DOWN, buff=0.1)
            tag.next_to(ax, UP, buff=0.28)
            self.play(FadeOut(listen) if not done else FadeOut(done[-1][1]),
                      FadeIn(tag), run_time=0.35)
            head.move_to(ax.c2p(0, -3.5))
            self.add(head)
            # REAL TIME. run_time == T_MAX, linear: the playhead is on the same
            # instant the viewer is hearing, or the marker is a lie.
            self.play(Create(vm),
                      head.animate.move_to(ax.c2p(T_MAX, -3.5)),
                      run_time=T_MAX, rate_func=linear)
            self.remove(head)
            done.append((vm, tag))
            if name == "30 ms":
                vm.set_stroke(opacity=0.45)

        self.play(FadeOut(done[-1][1]), done[0][0].animate.set_stroke(opacity=1.0),
                  run_time=0.4)
        for vm, name, col, y in ((done[0][0], "30 ms", CYAN, 0.55),
                                 (done[1][0], "800 ms", VIOLET, -5.6)):
            self.add(Text(name, font_size=25, color=col).move_to(ax.c2p(2.72, y)))
        self.play(FadeIn(Text("same compressor, same gain — only the release changed",
                              font_size=23, color=DIM).next_to(ax, UP, buff=0.3)),
                  run_time=0.5)
        self.wait(1.4)


if __name__ == "__main__":
    # The assembler needs to know WHERE the real-time sweeps start, so the audio
    # can be laid under the playhead instead of near it.
    lead = 0.5 + 0.35
    print(json.dumps({
        "tMax": T_MAX,
        "sweeps": [{"label": "30 ms", "audio": "d3p-fast-lvl.wav", "startSec": round(lead, 3)},
                   {"label": "800 ms", "audio": "d3p-slow-lvl.wav",
                    "startSec": round(lead + T_MAX + 0.35, 3)}],
        "gaps": GAPS}, indent=2))
