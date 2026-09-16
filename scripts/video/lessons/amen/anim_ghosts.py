#!/usr/bin/env python3
"""ATTENTION MARKER 1 — the ghost notes: a playhead sweeping a MEASURED chart at
real time, so the viewer is told WHEN to listen and WHERE.

Both curves are short-time broadband levels measure.py computed off the two
renders. ⚠ THE SHADED WINDOWS ARE DERIVED, NEVER CHOSEN BY EYE: every window in
which the ghosted render is more than 6 dB louder than the plain one, gaps under
60 ms merged, anything under 20 ms dropped. The ghost notes are the ONLY
difference between the two files, so every shaded bar IS a ghost note by
construction.

⚠ run_time must equal the audio laid under it. __main__ prints the offsets and
bursts.py builds the bed from them.
⚠ No LaTeX on this machine: every tick label is a hand-placed Text.
"""
import json, os
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(os.path.join(HERE, "MEASUREMENTS.json")))
C = M["_chart"]
T_MAX = float(C["half_seconds"])
LEAD, TAG, GAP = 0.6, 0.5, 0.4
FONT = "Helvetica Neue"
def T(*a, **kw): return Text(*a, font=FONT, **kw)
BG, CYAN, RED, WARM, DIM, SHADE = "#080B10", "#5AD1FF", "#FF6B6B", "#7DF9D6", "#7C8798", "#213448"
Y0, Y1 = -56, -8


class GhostsOverTime(Scene):
    def construct(self):
        self.camera.background_color = BG
        ax = Axes(x_range=[0, T_MAX, 1.0], y_range=[Y0, Y1, 8],
                  x_length=10.6, y_length=4.5,
                  axis_config={"color": "#39424F", "stroke_width": 2}, tips=False)
        ax.to_edge(DOWN, buff=1.05)
        lab = VGroup()
        for xv in range(0, int(T_MAX) + 1):
            lab.add(T(f"{xv}", font_size=18, color=DIM).next_to(ax.c2p(xv, Y0), DOWN, buff=0.14))
        for yv in range(Y0, Y1 + 1, 8):
            lab.add(T(f"{yv}", font_size=18, color=DIM).next_to(ax.c2p(0, yv), LEFT, buff=0.14))
        self.add(ax, lab)
        self.add(T("level of the kit, dB", font_size=21, color=DIM)
                 .rotate(PI / 2).next_to(ax, LEFT, buff=0.18).shift(LEFT * 0.6))
        self.add(T("seconds", font_size=20, color=DIM).next_to(ax, DOWN, buff=0.58))
        self.add(T("WHERE THE GHOST NOTES ARE", font_size=34, color=WARM)
                 .to_edge(UP, buff=0.30))
        for a, b in C["listen_windows"]:
            self.add(Polygon(ax.c2p(a, Y0), ax.c2p(b, Y0), ax.c2p(b, Y1), ax.c2p(a, Y1),
                             stroke_width=0, fill_color=SHADE, fill_opacity=1).set_z_index(-2))
        listen = T(f"the {len(C['listen_windows'])} shaded bars are not chosen by eye — they are "
                   f"every moment the two versions differ by more than {C['threshold_db']:.0f} dB",
                   font_size=23, color=WARM).next_to(ax, UP, buff=0.24)
        self.play(FadeIn(listen, shift=DOWN * 0.12), run_time=LEAD)

        def trace(key, col):
            v = VMobject(color=col, stroke_width=4.0)
            v.set_points_as_corners([ax.c2p(t, max(min(g, Y1), Y0))
                                     for t, g in zip(C["t"], C[key]) if t <= T_MAX])
            return v

        head = Line(ax.c2p(0, Y0), ax.c2p(0, Y1), color=WARM, stroke_width=2.6)
        done = []
        for key, col, name, note in (
                ("skeleton_db", DIM, "without the ghost notes",
                 "kick, snare on two and four, ride — nothing in between"),
                ("ghosts_db", CYAN, "with the ghost notes",
                 # ⚠ THIS LINE ONCE READ "five quiet snare hits per two bars" AND WAS
                 #   WRONG ON BOTH HALVES. This chart is the FOUR-BAR ghost demo
                 #   (`ghostPlain`), which carries SIX ghosts -- three per two bars --
                 #   while FIVE is the count in the real four-bar pattern, a different
                 #   render. Three separate places said this three different ways.
                 #   Derive it; never type it.
                 f"the same take plus {M['material']['ghostDemo']} quiet snare hits "
                 f"over four bars")):
            vm = trace(key, col)
            tag = VGroup(T(name, font_size=28, color=col),
                         T(note, font_size=21, color=col)).arrange(DOWN, buff=0.10)
            tag.next_to(ax, UP, buff=0.20)
            self.play(FadeOut(listen if not done else done[-1][1]), FadeIn(tag), run_time=TAG)
            head.move_to(ax.c2p(0, (Y0 + Y1) / 2)); self.add(head)
            self.play(Create(vm), head.animate.move_to(ax.c2p(T_MAX, (Y0 + Y1) / 2)),
                      run_time=T_MAX, rate_func=linear)
            self.remove(head)
            done.append((vm, tag))
            if key == "skeleton_db":
                vm.set_stroke(opacity=0.55); self.wait(GAP)
        self.play(FadeOut(done[-1][1]), run_time=0.4)
        self.add(T(f"inside a shaded bar the ghosted version is up to "
                   f"{C['max_diff_db']:.0f} dB louder. Everywhere else the two are identical.",
                   font_size=24, color=WARM).next_to(ax, UP, buff=0.26))
        self.wait(1.8)


if __name__ == "__main__":
    a = LEAD + TAG
    b = a + T_MAX + GAP + TAG
    print(json.dumps({"scene": "GhostsOverTime", "tMax": T_MAX,
                      "total": b + T_MAX + 0.4 + 1.8,
                      "audio": [{"wav": "ab-s3-skeleton.wav", "atSec": round(a, 3)},
                                {"wav": "ab-s4-ghosts.wav", "atSec": round(b, 3)}]}, indent=1))
