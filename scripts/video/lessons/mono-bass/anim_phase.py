#!/usr/bin/env python3
"""THE MECHANISM, animated: two copies of one note, one of them late.

⭐ This is the single most important picture in the lesson. Phase cancellation
is far easier to SEE than to hear — two waves sliding out of alignment and
summing to less than either — and the whole audibility fault this rebuild
exists to fix is that the hearing part happens at 82 Hz.

⚠ NO LaTeX ON THIS MACHINE. `Axes(include_numbers=True)` renders numbers
through MathTex and crashes; every label here is a plain `Text`. And `Text("")`
has no points and silently collapses a VGroup.arrange into an overlapping
stack, so nothing here is ever empty.

⚠ THE TIMING IS LOAD-BEARING. The scene runs exactly SPLIT + SPLIT seconds and
the assembler lays `mech.wav` under it — the first half is the 0 ms mono fold,
the second half the 6 ms one. The slide happens AT the switch, so the viewer
sees the copies separate at the instant the sound changes. __main__ prints the
section boundaries; bursts.py builds the audio from them rather than from a
number typed twice.
"""
import json
from manim import *

SPLIT = 8.0                  # seconds per half; total run time = 2 * SPLIT
F_LOW, F_HIGH = 41.20, 82.41  # E1 and E2 — the same note, one octave apart
TAU = 0.006                   # 6 ms
TMAX = 0.030                  # 30 ms of waveform on screen

FONT = "Helvetica Neue"     # manim's default face is a serif; every other
                            # picture in this film is sans, and a font change
                            # mid-film reads as a different video.


def T(*a, **kw):
    """Text in the film's face. ⚠ Text(font=FONT, "x") is a SyntaxError — a
    keyword before a positional — which is why this wrapper exists rather than
    a search-and-replace."""
    return Text(*a, font=FONT, **kw)


# ⚠ THE BOTTOM-RIGHT CORNER IS NOT FREE. shortsmith burns a live level meter
# into it (spec `meter: "br"`), and a CENTRED bottom caption runs straight under
# it — measured on the first cut of this film, where "every peak meets a trough"
# read as "every peak meets a tro". Captions here are pinned to the LEFT edge.
BG = "#080B10"
CYAN, VIOLET, WARM, DIM, RED = "#5AD1FF", "#A78BFA", "#7DF9D6", "#7C8798", "#FF6B6B"


class PhaseSlide(Scene):
    def construct(self):
        self.camera.background_color = BG
        tau = ValueTracker(0.0)
        freq = ValueTracker(F_HIGH)

        ax = Axes(x_range=[0, TMAX, 0.005], y_range=[-2.4, 2.4, 1],
                  x_length=10.8, y_length=4.3,
                  axis_config={"color": "#39424F", "stroke_width": 2,
                               "include_ticks": True},
                  tips=False).move_to(DOWN * 0.35)
        ticks = VGroup(*[T(f"{int(v*1000)}", font_size=17, color=DIM)
                         .next_to(ax.c2p(v, -2.4), DOWN, buff=0.12)
                         for v in (0, 0.005, 0.010, 0.015, 0.020, 0.025, 0.030)])
        self.add(ax, ticks,
                 T("milliseconds", font_size=19, color=DIM).next_to(ax, DOWN, buff=0.52))

        def wave(shift_fn, colour, width, amp=1.0):
            return always_redraw(lambda: ax.plot(
                lambda t: amp * np.sin(2 * np.pi * freq.get_value() * (t - shift_fn())),
                x_range=[0, TMAX, TMAX / 900], color=colour, stroke_width=width))

        # ⚠ DIFFERENT WIDTHS ON PURPOSE. At delay 0 the two copies are exactly
        # on top of each other, and equal widths photographed as ONE curve — the
        # viewer sees two lines where the caption says three.
        left = wave(lambda: 0.0, CYAN, 5.4)
        right = wave(lambda: tau.get_value(), VIOLET, 2.4)
        summed = always_redraw(lambda: ax.plot(
            lambda t: (np.sin(2 * np.pi * freq.get_value() * t)
                       + np.sin(2 * np.pi * freq.get_value() * (t - tau.get_value()))),
            x_range=[0, TMAX, TMAX / 900], color=WARM, stroke_width=6.0))

        title = T("TWO COPIES OF ONE NOTE. ONE OF THEM LATE.",
                     font_size=34, color=WARM).to_edge(UP, buff=0.30)
        key = VGroup(
            T("left channel", font_size=22, color=CYAN),
            T("right channel", font_size=22, color=VIOLET),
            T("what a mono speaker plays — the two added together",
                 font_size=22, color=WARM),
        ).arrange(DOWN, aligned_edge=LEFT, buff=0.16).to_corner(UL, buff=0.42).shift(DOWN * 0.55)

        def readout():
            f = freq.get_value()
            t = tau.get_value()
            g = 20 * np.log10(max(abs(np.cos(np.pi * f * t)), 1e-6))
            return VGroup(
                T(f"note  {f:.1f} Hz" + ("   (E2)" if f > 60 else "   (E1)"),
                     font_size=25, color=DIM),
                T(f"delay  {t*1000:.1f} ms", font_size=25, color=VIOLET),
                T(f"the sum  {g:+.1f} dB", font_size=29,
                     color=RED if g < -6 else WARM),
            ).arrange(DOWN, aligned_edge=RIGHT, buff=0.16).to_corner(UR, buff=0.42).shift(DOWN * 0.55)

        panel = always_redraw(readout)

        # ── FIRST HALF: aligned. The sum is BIGGER than either copy, and saying
        #    so out loud is the setup for the second half being smaller.
        self.add(title)
        self.play(FadeIn(key), Create(left), Create(right), run_time=1.0)
        self.play(Create(summed), FadeIn(panel), run_time=1.0)
        note1 = T("in step, so they add up — two copies are louder than one",
                     font_size=25, color=DIM).to_edge(DOWN, buff=0.30).to_edge(LEFT, buff=0.55)
        self.play(FadeIn(note1), run_time=0.7)
        self.wait(SPLIT - 2.7)

        # ── THE SWITCH, on the beat: the audio changes to the 6 ms fold at
        #    exactly this instant, so the picture and the sound separate together.
        self.play(FadeOut(note1), tau.animate.set_value(TAU), run_time=1.6,
                  rate_func=smooth)
        gone = T("half a cycle apart at 82 Hz — every peak meets a trough",
                    font_size=25, color=RED).to_edge(DOWN, buff=0.30).to_edge(LEFT, buff=0.55)
        self.play(FadeIn(gone), run_time=0.6)
        self.wait(2.0)

        # ── SAME DELAY, LOWER NOTE. Nothing moves except the pitch, and the
        #    cancellation mostly goes away. This is the whole "it depends on the
        #    note" finding, in one gesture.
        self.play(FadeOut(gone), run_time=0.4)
        low = T("same six milliseconds — one octave lower",
                   font_size=25, color=CYAN).to_edge(DOWN, buff=0.30).to_edge(LEFT, buff=0.55)
        self.play(freq.animate.set_value(F_LOW), FadeIn(low), run_time=1.4)
        self.wait(SPLIT - 6.0)
        self.play(FadeOut(low), run_time=0.4)
        self.add(T("a delay is not a volume control — it hits some notes and "
                      "spares others", font_size=26, color=WARM)
                 .to_edge(DOWN, buff=0.30).to_edge(LEFT, buff=0.55))
        self.wait(1.6)


if __name__ == "__main__":
    # ⚠ 2*SPLIT + 2.0: the closing caption holds for two seconds after the
    # audio ends. MEASURED — the first version printed 2*SPLIT and bursts.py
    # caught the render at 18.00 s against a printed 16.00 s.
    print(json.dumps({"scene": "PhaseSlide", "split": SPLIT,
                      "total": 2 * SPLIT + 2.0,
                      "audio": [{"wav": "ab0.wav", "atSec": 0.0},
                                {"wav": "ab6.wav", "atSec": SPLIT}]}, indent=1))
