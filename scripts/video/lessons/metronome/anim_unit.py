#!/usr/bin/env python3
"""MECHANISM — the same number, twice: what a metronome mark does NOT say.

The third explanation for Beethoven's fast marks is that some of them were read
against the wrong NOTE VALUE. This scene shows why that is possible at all, and
it is the one idea in the lesson a viewer can check with their own ears while it
is on screen: the metronome setting is literally the same number, the ticks come
at literally the same rate, and the music underneath runs at half speed.

The audio under it is `demo-sameclick.wav` -- the two readings' metronomes, one
after the other, from the actual renders. They are the same sound. That is the
point.

⚠ run_time must equal the audio laid under it; __main__ prints the offsets.
⚠ No LaTeX: note heads are drawn as primitives, tick labels are hand-placed.
⚠ Every figure is interpolated from MEASUREMENTS.json.
"""
import json, os
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(os.path.join(HERE, "MEASUREMENTS.json")))
C = M["_chart"]
HALF_S = float(C["unitHalfSeconds"])
GAP_S = float(C["unitGapSeconds"])
LEAD, TAIL = 1.5, 2.6
FONT = "Helvetica Neue"
BG, CYAN, RED, WARM, DIM, GOLD = "#080B10", "#5AD1FF", "#FF6B6B", "#7DF9D6", "#7C8798", "#FFC65A"
TICK_S = C["tickMs"] / 1000.0
X0, X1 = -5.9, 5.9
NTICKS = 8


def T(*a, **kw):
    return Text(*a, font=FONT, **kw)


def notehead(filled, colour, scale=1.0):
    """A half note is a HOLLOW oval; a quarter note is a FILLED one. Same stem."""
    head = Ellipse(width=0.42 * scale, height=0.30 * scale, color=colour,
                   stroke_width=5, fill_opacity=1.0 if filled else 0.0,
                   fill_color=colour).rotate(-18 * DEGREES)
    stem = Line([0.19 * scale, 0.02 * scale, 0], [0.19 * scale, 0.92 * scale, 0],
                color=colour, stroke_width=5)
    return VGroup(head, stem)


class SameMetronome(Scene):
    """⚠ THE LAYOUT IS EXPLICIT AND IT TOOK A LOOK AT A FRAME TO GET RIGHT.
    The first version put the quarter-note row at y = -3.35, which is off the
    bottom of a 16:9 manim frame -- the note heads were cut in half -- and then
    faded out that row's own LABEL to make room for the closing caption, so the
    final frame showed an unlabelled row of red notes. Nothing but pulling the
    frame could see either."""

    def construct(self):
        self.camera.background_color = BG
        self.add(T("THE SAME NUMBER, TWICE", font_size=38, color=WARM)
                 .move_to([0, 3.55, 0]))

        xs = [X0 + (X1 - X0) * i / (NTICKS - 1) for i in range(NTICKS)]
        rail = Line([X0 - 0.35, 0.35, 0], [X1 + 0.35, 0.35, 0],
                    color="#39424F", stroke_width=3)
        ticks = VGroup(*[Line([x, 0.05, 0], [x, 0.65, 0], color=WARM, stroke_width=7)
                         for x in xs])
        self.add(rail, ticks)
        self.add(T(f"one tick every {C['tickMs']:.1f} milliseconds — "
                   f"{C['markHalf']} a minute", font_size=24, color=DIM)
                 .move_to([0, -0.25, 0]))
        dial = T(f"metronome set to {C['markHalf']}", font_size=30, color=GOLD)\
            .move_to([0, -0.95, 0])
        self.add(dial)

        readingA = T(f"read as   HALF NOTE = {C['markHalf']}", font_size=30, color=CYAN)\
            .move_to([0, 2.85, 0])
        readingB = T(f"read as   QUARTER NOTE = {C['unitQuarterBpm']}",
                     font_size=30, color=RED).move_to([0, -1.62, 0])
        halves = VGroup(*[notehead(False, CYAN).move_to([x, 1.55, 0]) for x in xs])
        quarters = VGroup(*[notehead(True, RED).move_to([x, -2.42, 0]) for x in xs])

        self.play(FadeIn(readingA), FadeIn(halves, lag_ratio=0.08), run_time=LEAD)
        # ── the first metronome plays here (HALF_S of audio) ──
        self.wait(HALF_S)
        self.play(FadeIn(readingB), FadeIn(quarters, lag_ratio=0.08), run_time=GAP_S)
        # ── the second metronome plays here (HALF_S of audio) ──
        self.wait(HALF_S)

        note = T("the metronome has not moved", font_size=30, color=GOLD)\
            .move_to([0, -0.95, 0])
        self.play(ReplacementTransform(dial, note), run_time=0.8)
        # ⚠ the closing caption goes BELOW the quarter-note row, and readingB
        #   STAYS -- a row of notes with no label is not an explanation.
        # ⚠⚠ THE CORNER METER IS BURNED ON AFTER CONCAT, so NO manim frame can
        #    ever show this collision -- only a frame pulled from the DELIVERABLE.
        #    The first version was one 78-character line centred at x=0, whose
        #    right end ran to about x=+5.0 in manim units; the meter box occupies
        #    roughly x=[4.33, 6.9], y=[-3.4, -3.75], and it printed straight over
        #    "half the speed:". Now two shorter lines shifted left, so the widest
        #    line reaches about x=+2.6 -- 1.7 units clear of the meter.
        bars = T(f"a half note is two quarter notes, so the music\n"
                 f"underneath runs at half speed: "
                 f"{C['statementSecMark']:.2f} s becomes "
                 f"{C['statementSecUnit']:.2f} s",
                 font_size=22, color=WARM, line_spacing=0.9)\
            .move_to([-1.05, -3.62, 0])
        self.play(FadeIn(bars), run_time=TAIL - 0.8)


if __name__ == "__main__":
    a0 = LEAD
    a1 = LEAD + HALF_S + GAP_S
    print(json.dumps({
        "total": round(LEAD + HALF_S + GAP_S + HALF_S + TAIL, 4),
        # ONE file holds both halves back to back with the gap already in it, so
        # the two offsets below cannot disagree with what the scene draws.
        "audio": [{"wav": "demo-sameclick.wav", "atSec": round(a0, 4)}],
        "_halves": [round(a0, 4), round(a1, 4)],
    }))
