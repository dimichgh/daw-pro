#!/usr/bin/env python3
"""THE CENTREPIECE: the prelude's own note data, drawn twice.

`FigureInvariant` walks the eight bars while `piano124.wav` plays them, and
counts two things bar by bar: how many times the ONSET pattern changes (zero)
and how many times the PITCH SET changes (seven of seven bar lines). The second
count is the positive control for the first — the same comparator, run on the
same data, returns a large number, so the zero is a result and not a broken
test. It also finds the one identical pair, bars 1 and 4.

`NestedLoops` puts the house grid under the same eight bars while the finished
track plays, and labels the three loop lengths the piece already has: the figure
repeats every half bar, the harmony every bar, the phrase every eight.

⚠ EVERYTHING HERE IS READ FROM bars1-8.json AND MEASUREMENTS.json. No pitch, no
onset and no duration is typed into this file.
⚠ NO LaTeX on this machine: every label is a hand-placed Text.
⚠ Numeric readouts use .become(), never Transform — a Transform interpolates
across its whole run_time and every intermediate frame is a half-morphed number.
"""
import json, os
import numpy as np
from manim import *

HERE = os.path.dirname(os.path.abspath(__file__))
BARS = json.load(open(f"{HERE}/bars1-8.json"))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
BAR_S = M["marker"]["barSeconds"]                 # 1.9355 s at 124 BPM
TOTAL = round(8 * BAR_S, 4)                       # 15.4839 s == piano124.wav
BEAT_S = BAR_S / 4

FONT = "Helvetica Neue"
BG = "#080B10"
CYAN, VIOLET, WARM, DIM, GOLD = "#5AD1FF", "#A78BFA", "#7DF9D6", "#7C8798", "#FFC77A"
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def T(*a, **kw):
    return Text(*a, font=FONT, **kw)


def pname(p):
    return f"{NAMES[p % 12]}{p // 12 - 1}"


NOTES = [(b - 1) * 4 + s, p, d] if False else None   # placeholder, see below
NOTES = [[(b - 1) * 4 + s, p, d] for b in range(1, 9) for s, p, d in BARS[str(b)]]
PITCHSETS = [sorted({p for _, p, _ in BARS[str(b)]}) for b in range(1, 9)]
ONSETS = [sorted({round(s, 4) for s, _, _ in BARS[str(b)]}) for b in range(1, 9)]
PMIN, PMAX = min(p for _, p, _ in NOTES) - 2, max(p for _, p, _ in NOTES) + 2

XL, XR = -6.35, 6.35
YB, YT = -0.45, 2.35


def x(beat):
    return XL + (XR - XL) * beat / 32.0


def y(pitch):
    return YB + (YT - YB) * (pitch - PMIN) / (PMAX - PMIN)


def note_rect(start, pitch, length, colour, op):
    w = max(x(start + length) - x(start), 0.055)
    h = (YT - YB) / (PMAX - PMIN) * 1.6
    r = Rectangle(width=w, height=h, stroke_width=0, fill_color=colour, fill_opacity=op)
    r.move_to([x(start) + w / 2, y(pitch), 0])
    return r


def grid():
    g = VGroup()
    for b in range(9):
        g.add(Line([x(b * 4), YB - 0.12, 0], [x(b * 4), YT + 0.12, 0],
                   color="#2A3340", stroke_width=2 if b % 8 else 3))
    for b in range(8):
        g.add(T(f"bar {b+1}", font_size=15, color=DIM)
              .move_to([x(b * 4 + 2), YT + 0.30, 0]))
    return g


class FigureInvariant(Scene):
    def construct(self):
        self.camera.background_color = BG
        title = T("THE SAME FIGURE, EIGHT TIMES", font_size=27, color=DIM)
        title.to_edge(UP, buff=0.34).to_edge(LEFT, buff=0.7)
        sub = T("J. S. Bach, Prelude in C, BWV 846, bars 1-8 — the note data this "
                "film plays", font_size=17, color="#5A6472")
        sub.next_to(title, DOWN, buff=0.12).align_to(title, LEFT)
        self.add(title, sub, grid())

        dim_notes = VGroup(*[note_rect(s, p, d, CYAN, 0.18) for s, p, d in NOTES])
        self.add(dim_notes)

        # the onset comb: sixteen ticks, redrawn under whichever bar is current
        def comb(bar):
            g = VGroup()
            for o in ONSETS[bar]:
                b0 = bar * 4 + o
                g.add(Line([x(b0), -0.95, 0], [x(b0), -0.65, 0],
                           color=GOLD, stroke_width=3))
            g.add(T(f"{len(ONSETS[bar])} onsets", font_size=15, color=GOLD)
                  .move_to([x(bar * 4 + 2), -1.22, 0]))
            return g

        r1 = T("onset pattern  —  changes so far: 0 of 0", font_size=23, color=WARM)
        r2 = T("pitch set  —  changes so far: 0 of 0", font_size=23, color=VIOLET)
        # ⚠ NEVER Text("") — it has no points, and VGroup.arrange / .move_to on it
        # raises "too many indices for array". A middle dot in the background
        # colour is an invisible placeholder that is still a real mobject.
        BLANK = "\u00b7"
        r3 = T(BLANK, font_size=20, color=BG)
        rows = VGroup(r1, r2, r3).arrange(DOWN, aligned_edge=LEFT, buff=0.17)
        rows.to_edge(DOWN, buff=0.40).to_edge(LEFT, buff=0.8)
        # ⚠ CENTRED, NOT RIGHT-ALIGNED. Right-aligned with to_edge the five pitch
        # names grew rightward off the frame and bar 6 photographed as four.
        chord = T(BLANK, font_size=30, color=CYAN).move_to([0.0, -1.95, 0])
        self.add(rows, chord)

        onset_ch = pitch_ch = 0
        hi = VGroup()
        cb = VGroup()
        for b in range(8):
            if b:
                onset_ch += int(ONSETS[b] != ONSETS[b - 1])
                pitch_ch += int(PITCHSETS[b] != PITCHSETS[b - 1])
            self.remove(hi, cb)
            hi = VGroup(*[note_rect(s, p, d, CYAN, 1.0)
                          for s, p, d in NOTES if b * 4 <= s < (b + 1) * 4])
            cb = comb(b)
            # ⚠ .become(), not Transform — see the module docstring.
            r1.become(T(f"onset pattern  —  changes so far: {onset_ch} of {b}",
                        font_size=23, color=WARM)
                      .move_to(r1).align_to(rows, LEFT))
            r2.become(T(f"pitch set  —  changes so far: {pitch_ch} of {b}",
                        font_size=23, color=VIOLET)
                      .move_to(r2).align_to(rows, LEFT))
            same = [j + 1 for j in range(b) if PITCHSETS[j] == PITCHSETS[b]]
            r3.become(T(f"bar {b+1} holds the same five pitches as bar {same[0]}"
                        if same else BLANK, font_size=20,
                        color=GOLD if same else BG)
                      .move_to(r3).align_to(rows, LEFT))
            chord.become(T("   ".join(pname(p) for p in PITCHSETS[b]),
                           font_size=30, color=CYAN).move_to([0.0, -1.95, 0]))
            self.add(hi, cb)
            self.wait(BAR_S)


class NestedLoops(Scene):
    def construct(self):
        self.camera.background_color = BG
        title = T("THREE LOOPS, ALREADY IN THE MUSIC", font_size=27, color=DIM)
        title.to_edge(UP, buff=0.34).to_edge(LEFT, buff=0.7)
        sub = T("the same eight bars, under the finished track", font_size=17,
                color="#5A6472")
        sub.next_to(title, DOWN, buff=0.12).align_to(title, LEFT)
        self.add(title, sub, grid())
        self.add(VGroup(*[note_rect(s, p, d, CYAN, 0.55) for s, p, d in NOTES]))

        head = ValueTracker(0.0)
        ph = always_redraw(lambda: Line([x(head.get_value() / BEAT_S), YB - 0.2, 0],
                                        [x(head.get_value() / BEAT_S), YT + 0.2, 0],
                                        color=WHITE, stroke_width=3))
        self.add(ph)

        def lane(row, every_beats, colour, label, secs):
            yy = -1.05 - row * 0.72
            g = VGroup(Line([XL, yy, 0], [XR, yy, 0], color="#212934", stroke_width=2))
            k = 0
            while k * every_beats < 32:
                x0 = x(k * every_beats)
                x1 = x(min((k + 1) * every_beats, 32))
                if every_beats == 1:
                    g.add(Line([x0, yy - 0.12, 0], [x0, yy + 0.12, 0],
                               color=colour, stroke_width=4))
                else:
                    g.add(Rectangle(width=x1 - x0 - 0.03, height=0.22, stroke_width=0,
                                    fill_color=colour, fill_opacity=0.30 if k % 2 else 0.55)
                          .move_to([(x0 + x1) / 2, yy, 0]))
                k += 1
            g.add(T(label, font_size=19, color=colour)
                  .move_to([XL + 0.05, yy + 0.36, 0], aligned_edge=LEFT))
            g.add(T(secs, font_size=17, color=DIM)
                  .move_to([XR - 0.05, yy + 0.36, 0], aligned_edge=RIGHT))
            return g

        LANES = [
            (1, GOLD, "THE KICK — every beat", f"{BEAT_S:.3f} s"),
            (2, WARM, "THE FIGURE — repeats every half bar", f"{2*BEAT_S:.3f} s"),
            (4, VIOLET, "THE HARMONY — one chord a bar", f"{BAR_S:.3f} s"),
            (32, CYAN, "THE PHRASE — eight bars", f"{TOTAL:.3f} s"),
        ]
        seg = TOTAL / 4
        for i, (ev, col, lab, secs) in enumerate(LANES):
            self.add(lane(i, ev, col, lab, secs))
            self.play(head.animate.set_value((i + 1) * seg), run_time=seg,
                      rate_func=linear)


if __name__ == "__main__":
    print(json.dumps({
        "total": TOTAL,
        "audio": [{"wav": "piano124.wav", "atSec": 0.0}],
        "nested": {"total": TOTAL,
                   "audio": [{"wav": "ab-full-src.wav", "atSec": 0.0}]},
        "barSeconds": BAR_S, "beatSeconds": BEAT_S,
        "onsetChanges": sum(1 for i in range(1, 8) if ONSETS[i] != ONSETS[i - 1]),
        "pitchChanges": sum(1 for i in range(1, 8) if PITCHSETS[i] != PITCHSETS[i - 1]),
        "identicalPairs": [(i + 1, j + 1) for i in range(8) for j in range(i + 1, 8)
                           if PITCHSETS[i] == PITCHSETS[j]],
        "onsetsPerBar": len(ONSETS[0]),
    }))
