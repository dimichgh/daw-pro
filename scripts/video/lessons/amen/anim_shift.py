#!/usr/bin/env python3
"""ATTENTION MARKER 2 — the timing. Every hit's MEASURED distance from the grid,
plotted against time, with a playhead crossing it at real speed under the audio.

This chapter's whole problem is that its difference is a few milliseconds, which
nobody hears on a laptop speaker in isolation. So the chart carries it: the same
axis shows the humanised take (a few ms) and a deliberately exaggerated one
(dragged snare) so the SCALE of the real thing is visible rather than asserted.

⚠ Positions come from clip.getNotes on the project and were then confirmed in
the rendered audio; nothing here is drawn by hand.
"""
import json, os
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(os.path.join(HERE, "MEASUREMENTS.json")))
BEAT_MS, S16 = M["beat_ms"], M["sixteenth_ms"]
H = M["humanize"]
DRAG = M["drag"]["asked_ms"]
BARS_SHOWN = 4
T_MAX = BARS_SHOWN * 4 * BEAT_MS / 1000.0
LEAD, TAG, GAP = 0.6, 0.5, 0.4
FONT = "Helvetica Neue"
def T(*a, **kw): return Text(*a, font=FONT, **kw)
BG, CYAN, RED, WARM, DIM = "#080B10", "#5AD1FF", "#FF6B6B", "#7DF9D6", "#7C8798"
YL = 34

MAT = json.load(open(os.path.join(HERE, "media", "material.json")))
PTS = []          # (seconds, shift_ms, is_snare)
for nm in ("kick", "snare", "cym"):
    for beat, sh in zip(MAT["humanize"]["after"][nm], M["onsets"][nm]["project_shift_ms"]):
        t = beat * BEAT_MS / 1000.0
        if t <= T_MAX:
            PTS.append((t, sh, nm == "snare"))
SNARE_T = [p[0] for p in PTS if p[2]]


class ShiftOverTime(Scene):
    def construct(self):
        self.camera.background_color = BG
        ax = Axes(x_range=[0, T_MAX, 1.0], y_range=[-YL, YL, 10],
                  x_length=10.6, y_length=4.5,
                  axis_config={"color": "#39424F", "stroke_width": 2}, tips=False)
        ax.to_edge(DOWN, buff=1.05)
        lab = VGroup()
        for xv in range(0, int(T_MAX) + 1):
            lab.add(T(f"{xv}", font_size=18, color=DIM).next_to(ax.c2p(xv, -YL), DOWN, buff=0.14))
        for yv in range(-30, 31, 10):
            lab.add(T(f"{yv:+d}", font_size=18, color=DIM).next_to(ax.c2p(0, yv), LEFT, buff=0.14))
        self.add(ax, lab)
        self.add(T("milliseconds off the grid", font_size=21, color=DIM)
                 .rotate(PI / 2).next_to(ax, LEFT, buff=0.18).shift(LEFT * 0.72))
        self.add(T("seconds", font_size=20, color=DIM).next_to(ax, DOWN, buff=0.58))
        self.add(T("HOW FAR OFF THE GRID, HIT BY HIT", font_size=34, color=WARM)
                 .to_edge(UP, buff=0.30))
        self.add(DashedLine(ax.c2p(0, 0), ax.c2p(T_MAX, 0), color="#39424F", stroke_width=2))
        for y, col in ((H["max_ms_asked"], DIM), (-H["max_ms_asked"], DIM)):
            self.add(DashedLine(ax.c2p(0, y), ax.c2p(T_MAX, y), color=col,
                                stroke_width=1.6, dash_length=0.06))
        self.add(T(f"the jitter that was asked for: ±{H['max_ms_asked']:.2f} ms",
                   font_size=19, color=DIM).next_to(ax.c2p(T_MAX, H["max_ms_asked"]),
                                                    UP, buff=0.06).shift(LEFT * 1.9))
        intro = T(f"a sixteenth note at {M['bpm']:.0f} beats per minute is "
                  f"{S16:.1f} ms — this whole chart is less than a third of one step",
                  font_size=23, color=WARM).next_to(ax, UP, buff=0.24)
        self.play(FadeIn(intro, shift=DOWN * 0.12), run_time=LEAD)

        head = Line(ax.c2p(0, -YL), ax.c2p(0, YL), color=WARM, stroke_width=2.6)
        prev = intro
        for phase in ("human", "drag"):
            if phase == "human":
                dots = VGroup(*[Dot(ax.c2p(t, s), radius=0.055,
                                    color=CYAN if sn else DIM) for t, s, sn in PTS])
                name, note, col = ("the humanised take",
                                   f"largest {H['project_max_abs_ms']:.2f} ms, "
                                   f"average {H['project_mean_abs_ms']:.2f} ms", CYAN)
            else:
                dots = VGroup(*[Dot(ax.c2p(t, DRAG), radius=0.055, color=RED) for t in SNARE_T])
                name, note, col = (f"the snare dragged {DRAG:.0f} ms late",
                                   "the same pattern, moved far enough to be unmissable", RED)
            tag = VGroup(T(name, font_size=28, color=col),
                         T(note, font_size=21, color=col)).arrange(DOWN, buff=0.10)
            tag.next_to(ax, UP, buff=0.20)
            self.play(FadeOut(prev), FadeIn(tag), run_time=TAG)
            prev = tag
            head.move_to(ax.c2p(0, 0)); self.add(head)
            self.play(LaggedStart(*[FadeIn(d, scale=0.6) for d in dots], lag_ratio=0.9 / max(len(dots), 1)),
                      head.animate.move_to(ax.c2p(T_MAX, 0)), run_time=T_MAX, rate_func=linear)
            self.remove(head)
            if phase == "human":
                self.wait(GAP)
                self.play(FadeOut(dots), run_time=0.3)
        self.play(FadeOut(prev), run_time=0.4)
        self.add(T(f"the real drummer's version is the small one. It is a change you "
                   f"can feel and a level meter cannot see.",
                   font_size=24, color=WARM).next_to(ax, UP, buff=0.26))
        self.wait(1.8)


if __name__ == "__main__":
    a = LEAD + TAG
    b = a + T_MAX + GAP + 0.3 + TAG
    print(json.dumps({"scene": "ShiftOverTime", "tMax": T_MAX,
                      "total": b + T_MAX + 0.4 + 1.8,
                      "audio": [{"wav": "ab-q-human.wav", "atSec": round(a, 3), "trim": T_MAX},
                                {"wav": "ab-q-drag.wav", "atSec": round(b, 3), "trim": T_MAX}]},
                     indent=1))
