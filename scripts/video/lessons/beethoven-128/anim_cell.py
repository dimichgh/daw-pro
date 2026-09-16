#!/usr/bin/env python3
"""THE MECHANISM: what a motif is, and what "development" means — animated,
because a static picture of four notes with a voice over it is exactly the thing
this rebuild exists to replace.

Five beats:
  1. the cell itself — three short notes on one pitch, then a longer one lower
  2. the same shape moved to two new pitches, unchanged in every other way
  3. the pitches taken away entirely, so only the rhythm is left
  4. the pitches restored
  5. the room arriving underneath while the cell does not move

⚠ NO LaTeX ON THIS MACHINE. Every label is a hand-placed `Text` — an `Axes`
with `include_numbers=True` renders through MathTex and crashes.
⚠ `Text("")` has no points and silently collapses a VGroup.arrange into one
overlapping stack. Space with `buff` instead of blank lines.
⚠ Captions are LEFT-aligned and stay clear of the bottom-right corner, where
the film burns a level meter in after assembly.
⚠ run_time MUST equal the span of audio laid under it. __main__ prints the
offsets and bursts.py builds the bed from THOSE, never from a number typed twice.
"""
import json, os
from manim import *

FONT = "Helvetica Neue"
BG = "#080B10"
CELL_C, SEQ_C, RHY_C, DRUM_C = "#5AD1FF", "#7DF9D6", "#FFB84D", "#FF6B6B"
DIM, WARM = "#7C8798", "#7DF9D6"

LEAD, DRAW, HOLD = 1.0, 1.5, 2.5
CAP, SEQ, STRIP_A, STRIP_B, STACK, BUILD, TAIL = 2.2, 3.2, 2.8, 2.8, 2.0, 12.0, 1.5

EW, RH = 0.52, 0.40          # width of one eighth note, height of one pitch row


def T(*a, **kw):
    return Text(*a, font=FONT, **kw)


def cell(x0, hi_row, lo_row, colour, label_hi=None, label_lo=None):
    """One bar of the cell: an eighth rest, three short notes on `hi_row`, then
    one four-eighths note on `lo_row`. Rows are counted UP from the baseline."""
    g = VGroup()
    for i in (1, 2, 3):
        g.add(Rectangle(width=EW * 0.82, height=RH * 0.8,
                        fill_color=colour, fill_opacity=1, stroke_width=0)
              .move_to([x0 + (i + 0.41) * EW, hi_row * RH, 0]))
    g.add(Rectangle(width=EW * 3.9, height=RH * 0.8,
                    fill_color=colour, fill_opacity=1, stroke_width=0)
          .move_to([x0 + 6.0 * EW, lo_row * RH, 0]))
    if label_hi:
        g.add(T(label_hi, font_size=20, color=colour)
              .move_to([x0 + 2.4 * EW, hi_row * RH + 0.42, 0]))
    if label_lo:
        g.add(T(label_lo, font_size=20, color=colour)
              .move_to([x0 + 6.0 * EW, lo_row * RH + 0.42, 0]))
    return g


def drum_row(x0, bars, row, step, colour, offset=0.0):
    g = VGroup()
    for b in range(bars):
        for i in range(int(8 / step)):
            g.add(Rectangle(width=EW * 0.30, height=RH * 0.55,
                            fill_color=colour, fill_opacity=1, stroke_width=0)
                  .move_to([x0 + (b * 8 + i * step + offset + 0.15) * EW,
                            row * RH, 0]))
    return g


class CellScene(Scene):
    def construct(self):
        self.camera.background_color = BG
        title = T("THE CELL", font_size=38, color=WARM).to_edge(UP, buff=0.34)
        self.add(title)

        X0 = -6.4
        base = VGroup()
        for r in (-3, -2, -1, 0, 1, 2):
            base.add(Line([X0 - 0.2, r * RH, 0], [X0 + 24.4 * EW, r * RH, 0],
                          color="#1B2733", stroke_width=1.4))
        self.add(base)
        self.wait(LEAD)   # the audio bed drops in HERE — see __main__

        c1 = cell(X0, 2, 0, CELL_C, "G  G  G", "E♭")
        self.play(FadeIn(c1, shift=UP * 0.2), run_time=DRAW)

        cap = VGroup(
            T("Three short notes on ONE pitch, then a longer one lower down.",
              font_size=25, color=DIM),
            T("Not a tune. A rhythm, with a pitch attached.",
              font_size=25, color=DIM),
        ).arrange(DOWN, buff=0.16, aligned_edge=LEFT).to_corner(DL, buff=0.5)
        self.play(FadeIn(cap), run_time=0.5)
        self.wait(HOLD - 0.5)

        # ── 2. the same shape, moved ───────────────────────────────────────
        cap2 = VGroup(
            T("Now he moves it — and changes nothing else about it.",
              font_size=25, color=DIM),
            T("Same rhythm. Same shape. New pitches.", font_size=25, color=DIM),
        ).arrange(DOWN, buff=0.16, aligned_edge=LEFT).to_corner(DL, buff=0.5)
        self.play(FadeOut(cap), FadeIn(cap2), run_time=CAP * 0.35)
        c2 = cell(X0 + 8 * EW, 1, -1, SEQ_C, "F  F  F", "D")
        c3 = cell(X0 + 16 * EW, 3, 2, SEQ_C, "A♭ A♭ A♭", "G")
        self.play(FadeIn(c2, shift=RIGHT * 0.3), run_time=SEQ * 0.35)
        self.play(FadeIn(c3, shift=RIGHT * 0.3), run_time=SEQ * 0.35)
        self.wait(SEQ * 0.30 + CAP * 0.65)

        # ── 3. take the pitches away ───────────────────────────────────────
        cap3 = VGroup(
            T("Take the pitches away and it still says the same thing.",
              font_size=25, color=RHY_C),
            T("Three short, one long. That is the whole idea.",
              font_size=25, color=RHY_C),
        ).arrange(DOWN, buff=0.16, aligned_edge=LEFT).to_corner(DL, buff=0.5)
        flat = VGroup(cell(X0, 0, 0, RHY_C),
                      cell(X0 + 8 * EW, 0, 0, RHY_C),
                      cell(X0 + 16 * EW, 0, 0, RHY_C))
        self.play(FadeOut(cap2), FadeIn(cap3),
                  ReplacementTransform(VGroup(c1, c2, c3), flat),
                  run_time=STRIP_A)
        self.wait(STRIP_B)

        # ── 4. put them back ───────────────────────────────────────────────
        back = VGroup(cell(X0, 2, 0, CELL_C), cell(X0 + 8 * EW, 1, -1, CELL_C),
                      cell(X0 + 16 * EW, 3, 2, CELL_C))
        cap4 = VGroup(
            T("State it. Do not change it. Change everything around it.",
              font_size=27, color=WARM),
            T("Which is also, almost exactly, how a techno record is built.",
              font_size=25, color=DIM),
        ).arrange(DOWN, buff=0.16, aligned_edge=LEFT).to_corner(DL, buff=0.5)
        self.play(FadeOut(cap3), FadeIn(cap4),
                  ReplacementTransform(flat, back), run_time=STACK)

        # ── 5. the room arrives underneath, and the cell does not move ─────
        title2 = T("THE CELL DOES NOT MOVE", font_size=38, color=WARM)
        title2.to_edge(UP, buff=0.34)
        kick = drum_row(X0, 3, -2, 2.0, DRUM_C)
        hats = drum_row(X0, 3, -3, 2.0, "#8A94A6", offset=1.0)
        self.play(Transform(title, title2), run_time=0.6)
        self.play(FadeIn(kick, shift=UP * 0.15), run_time=1.2)
        self.play(FadeIn(hats, shift=UP * 0.15), run_time=1.2)
        self.wait(BUILD - 3.0)
        self.wait(TAIL)


if __name__ == "__main__":
    # Every play/wait in construct() sums to exactly these constants — the
    # fractional splits inside a beat cancel out. bursts.py compares this
    # printed total against the RENDER's real length and says so if they differ.
    a = LEAD                       # the cell alone, drawn and held
    b = LEAD + DRAW + HOLD + CAP + SEQ + STRIP_A + STRIP_B + STACK
    total = b + BUILD + TAIL
    print(json.dumps({"scene": "CellScene",
                      "total": round(total, 3),
                      "audio": [{"wav": "play-cell.wav", "atSec": round(a, 3)},
                                {"wav": "play-build.wav", "atSec": round(b, 3)}]},
                     indent=1))
