#!/usr/bin/env python3
"""THE CENTREPIECE: twelve pure fifths walked round the octave, failing to close.

⭐ This is the picture the whole lesson exists to deliver. "Twelve fifths do not
equal seven octaves" is arithmetic a novice cannot check and will not remember;
a line that walks round a circle seven times and then MISSES the place it
started is a thing you can see happen.

⭐ THE SOUND AND THE PICTURE ARE THE SAME EVENT. Each of the thirteen steps runs
for exactly STEP seconds, and `walk.wav` — thirteen notes at 1.5 s each,
rendered by the app's own sampler — is laid under it starting at the instant
step 0 is drawn. So the note you hear IS the dot being placed.

⚠ NO LaTeX ON THIS MACHINE: Axes(include_numbers=True) renders through MathTex
and crashes. Every label here is a plain Text. Text("") has no points and
collapses a VGroup.arrange, so nothing here is ever empty.

⚠ THE MISS IS SMALL ON PURPOSE AND HAS TO BE MAGNIFIED. 23.46 cents of 1200 is
7.04 degrees of arc; at the outer radius that is about a third of a manim unit.
The scene therefore ends on an INSET at 12x, labelled as magnified, rather than
distorting the geometry — a film whose premise is "measure it" cannot draw its
own headline number bigger than it is.
"""
import json, math
from manim import *

STEP = 1.5                    # seconds per fifth == one note of walk.wav
LEAD = 4.0                    # circle is built before the audio starts
TAIL_GAP, TAIL_ZOOM = 7.0, 7.0
LEAD_ET, TAIL_ET = 3.0, 5.0
FIFTH = 1200 * math.log2(3 / 2)
COMMA = 1200 * math.log2((3 / 2) ** 12 / 2 ** 7)
NAMES = ["A", "E", "B", "F#", "C#", "G#", "D#", "A#", "F", "C", "G", "D", "A"]
R0, R1 = 0.95, 2.95
TOTAL_CENTS = 12 * FIFTH

FONT = "Helvetica Neue"
BG = "#080B10"
CYAN, VIOLET, WARM, DIM, RED = "#5AD1FF", "#A78BFA", "#7DF9D6", "#7C8798", "#FF6B6B"


def T(*a, **kw):
    return Text(*a, font=FONT, **kw)


def polar(cents):
    """Angle = position within the octave; radius grows with total distance."""
    th = PI / 2 - (cents % 1200) / 1200 * TAU        # clockwise from 12 o'clock
    r = R0 + (cents / TOTAL_CENTS) * (R1 - R0)
    return np.array([r * math.cos(th), r * math.sin(th), 0.0])


class SpiralOfFifths(Scene):
    def construct(self):
        self.camera.background_color = BG
        C = np.array([-2.7, -0.25, 0.0])

        title = T("ONE OCTAVE, ALL THE WAY ROUND", font_size=26, color=DIM)
        title.to_edge(UP, buff=0.45).to_edge(LEFT, buff=0.7)
        ring = Circle(radius=R1 + 0.42, color="#26303C", stroke_width=2).move_to(C)
        ticks, labs = VGroup(), VGroup()
        for i in range(12):
            th = PI / 2 - i / 12 * TAU
            u = np.array([math.cos(th), math.sin(th), 0.0])
            ticks.add(Line(C + u * (R1 + 0.26), C + u * (R1 + 0.42),
                           color="#334050", stroke_width=2))
            # ⚠ NOT AT THE TOP. i == 0 sits directly under the title and the two
            # collided in the first render — looked at, not inferred. The top of
            # the circle is also where the start and the miss both live, so it
            # is the one place that must stay uncluttered.
            if i in (2, 3, 4, 5, 6, 7, 8, 9, 10):
                labs.add(T(f"{i*100}", font_size=15, color="#4C596B")
                         .move_to(C + u * (R1 + 0.72)))
        self.add(title)
        self.play(Create(ring), run_time=1.0)
        self.play(FadeIn(ticks), FadeIn(labs), run_time=0.8)
        cap = VGroup(
            T("each mark is 100 cents — a semitone", font_size=21, color=DIM),
            T("a pure fifth is 701.955 cents, so every step", font_size=21, color=DIM),
            T("lands seven marks on and a little past", font_size=21, color=DIM),
        ).arrange(DOWN, aligned_edge=LEFT, buff=0.16)
        cap.to_edge(RIGHT, buff=0.75).shift(UP * 1.35)
        self.play(FadeIn(cap), run_time=1.0)
        self.wait(max(0.1, LEAD - 2.8))

        # ---- the walk: thirteen steps, one per note of walk.wav -------------
        start = polar(0.0)
        dot0 = Dot(C + start, radius=0.075, color=WARM)
        ray = DashedLine(C, C + polar(0.0) / np.linalg.norm(polar(0.0)) * (R1 + 0.2),
                         color="#3B4655", stroke_width=2, dash_length=0.09)
        lab0 = T("A", font_size=24, color=WARM).next_to(dot0, LEFT, buff=0.16)
        counter = T("fifths: 0", font_size=24, color=DIM)
        # ⚠ LEFT-ALIGNED AND PULLED IN. The readout is Transform'd to longer
        # strings ("23.5 cents"), which grow RIGHTWARD from the left edge; set
        # flush to the right margin it ran off the frame in the first render.
        counter.to_edge(RIGHT, buff=1.55).shift(DOWN * 0.55)
        cents_r = T("0.0 cents", font_size=27, color=WHITE)
        cents_r.next_to(counter, DOWN, buff=0.28, aligned_edge=LEFT)
        self.play(FadeIn(ray), FadeIn(dot0), FadeIn(lab0), FadeIn(counter),
                  FadeIn(cents_r), run_time=STEP)

        prev, dots = start, [dot0]
        for k in range(1, 13):
            cents = k * FIFTH
            here = polar(cents)
            arc = ParametricFunction(
                lambda t, a=(k - 1) * FIFTH: C + polar(a + t * FIFTH),
                t_range=[0, 1], color=CYAN, stroke_width=4)
            d = Dot(C + here, radius=0.065, color=CYAN if k < 12 else RED)
            u = here / np.linalg.norm(here)
            lb = T(NAMES[k], font_size=21, color=CYAN if k < 12 else RED)
            lb.move_to(C + here + u * 0.34)
            # ⚠⚠ NOT Transform. A Transform runs for the WHOLE run_time, so at
            # 30 fps every one of the 45 frames in a 1.5 s step showed the two
            # readouts MID-MORPH — overlapping glyphs, a ghost digit behind a
            # real one, "702.0 cents" rendered as unreadable mush. Caught by
            # pulling frames out of the finished film and looking at them; no
            # gate can see it, and the end-of-step frames I had checked were all
            # clean. A READOUT IS A NUMBER: it changes instantly and then holds.
            counter.become(T(f"fifths: {k}", font_size=24, color=DIM)
                           .move_to(counter, aligned_edge=LEFT))
            cents_r.become(T(f"{cents % 1200:.1f} cents", font_size=27,
                             color=WHITE if k < 12 else RED)
                           .move_to(cents_r, aligned_edge=LEFT))
            self.play(Create(arc), FadeIn(d), FadeIn(lb),
                      run_time=STEP, rate_func=linear)
            prev, dots = here, dots + [d]

        # ---- the miss --------------------------------------------------------
        end = polar(12 * FIFTH)
        # ⭐ A MARKER ON THE START RAY AT THE SAME RADIUS. Without it the miss
        # reads as "a different turn of the spiral" rather than as an ANGLE, and
        # the angle is the whole point. Two dots at one radius, seven degrees
        # apart, is the picture.
        home = np.linalg.norm(end) * np.array([0.0, 1.0, 0.0])
        homedot = Dot(C + home, radius=0.065, color=WARM)
        homelab = T("home", font_size=18, color=WARM).move_to(C + home * 1.09
                                                              + LEFT * 0.92)
        gap = Arc(radius=np.linalg.norm(end), start_angle=PI / 2 - COMMA / 1200 * TAU,
                  angle=COMMA / 1200 * TAU, color=RED, stroke_width=7).move_arc_center_to(C)
        msg = VGroup(
            T("twelve pure fifths", font_size=27, color=CYAN),
            T("seven octaves and a bit more", font_size=27, color=DIM),
            T("the line does not come home", font_size=27, color=RED),
        ).arrange(DOWN, aligned_edge=LEFT, buff=0.18)
        msg.to_edge(RIGHT, buff=0.75).shift(DOWN * 1.9)
        self.play(FadeIn(homedot), FadeIn(homelab), run_time=0.8)
        self.play(Create(gap), FadeIn(msg), Flash(C + end, color=RED, line_length=0.3),
                  run_time=2.0)
        self.wait(TAIL_GAP - 2.8)

        # ---- the inset, honestly labelled -----------------------------------
        # ⚠ THE FIRST BUILD PUT THIS OVER THE READOUTS AND RAN OFF THE FRAME at
        # 12x. Looked at, then fixed twice: the magnification is 7x (the widest
        # that fits inside the box) and everything it would sit on top of is
        # faded out first. A film that cannot draw its own headline number
        # inside the frame has no business quoting it.
        self.play(FadeOut(cap), FadeOut(msg), FadeOut(counter), FadeOut(cents_r),
                  run_time=0.8)
        Z = 7.0
        arc_len = np.linalg.norm(end) * COMMA / 1200 * TAU
        box = Rectangle(width=5.3, height=2.9, color="#2A3442", stroke_width=2,
                        fill_color="#0C111A", fill_opacity=1.0)
        box.to_edge(RIGHT, buff=0.55)
        bc = box.get_center()
        p_start = bc + LEFT * (arc_len * Z / 2) + DOWN * 0.15
        p_end = p_start + RIGHT * (arc_len * Z)
        seg = Line(p_start + UP * 0.6, p_start + DOWN * 0.6, color=WARM, stroke_width=5)
        seg2 = Line(p_end + UP * 0.6, p_end + DOWN * 0.6, color=RED, stroke_width=5)
        span = DoubleArrow(p_start, p_end, color=RED, stroke_width=3, buff=0,
                           tip_length=0.16)
        cl = T(f"{COMMA:.2f} cents", font_size=27, color=RED).next_to(span, DOWN, buff=0.22)
        lab_a = T("home", font_size=20, color=WARM).next_to(seg, UP, buff=0.14)
        lab_b = T("landed", font_size=20, color=RED).next_to(seg2, UP, buff=0.14)
        mag = T("the gap between those two dots, magnified 7x",
                font_size=19, color=DIM).next_to(box, DOWN, buff=0.22)
        self.play(FadeIn(box), FadeIn(seg), FadeIn(seg2), FadeIn(lab_a), FadeIn(lab_b),
                  run_time=1.2)
        self.play(GrowFromCenter(span), FadeIn(cl), FadeIn(mag), run_time=1.2)
        self.wait(TAIL_ZOOM - 3.2)


class SpiralCloses(Scene):
    """The fix, walked step by step so it can be HEARD as well as seen.

    ⭐ Thirteen steps again, 1.5 s each, under `walk-et.wav` — the SAME thirteen
    notes rendered by the app with every fifth at exactly 700 cents. The pure
    walk's ghost is drawn underneath so the two are directly comparable, and the
    last step lands on the dashed home ray instead of past it. A viewer who
    heard the pure walk end sharp hears this one end in tune.
    """

    def construct(self):
        self.camera.background_color = BG
        C = np.array([-2.7, -0.25, 0.0])
        NARROW = FIFTH - 700.0

        def polar_et(cents):
            th = PI / 2 - (cents % 1200) / 1200 * TAU
            r = R0 + (cents / (12 * 700.0)) * (R1 - R0)
            return np.array([r * math.cos(th), r * math.sin(th), 0.0])

        ring = Circle(radius=R1 + 0.42, color="#26303C", stroke_width=2).move_to(C)
        title = T("THE FIX: TAKE THE ERROR AND SPREAD IT", font_size=26, color=DIM)
        title.to_edge(UP, buff=0.45).to_edge(LEFT, buff=0.7)
        ray = DashedLine(C, C + np.array([0, R1 + 0.2, 0]), color="#3B4655",
                         stroke_width=2, dash_length=0.09)
        # ⚠ THE TWO SPIRALS SIT ALMOST ON TOP OF EACH OTHER — 1.955 cents a step
        # is invisible at this scale, and that IS the finding. The ghost is
        # there for the ENDPOINT comparison, which is the only place it shows.
        pure = VGroup(*[ParametricFunction(
            lambda t, a=k * FIFTH: C + polar(a + t * FIFTH), t_range=[0, 1],
            color="#3E6C8A", stroke_width=3) for k in range(12)])
        pend = Dot(C + polar(12 * FIFTH), radius=0.075, color=RED)
        plab = T("where the pure walk ended", font_size=18, color=RED)
        plab.next_to(pend, RIGHT, buff=0.22)
        cap = VGroup(
            T(f"every fifth narrowed by {NARROW:.3f} cents", font_size=23, color=WARM),
            T("about a fiftieth of a semitone, each time", font_size=20, color=DIM),
            T("twelve of them add up to the whole comma", font_size=20, color=DIM),
        ).arrange(DOWN, aligned_edge=LEFT, buff=0.16)
        cap.to_edge(RIGHT, buff=0.75).shift(UP * 1.5)

        self.add(title, ring, ray)
        self.play(Create(pure), FadeIn(pend), FadeIn(plab), FadeIn(cap),
                  run_time=LEAD_ET)

        counter = T("tempered fifths: 0", font_size=23, color=DIM)
        # ⚠ buff sized for the LONGEST string it will hold ("...: 12"), because
        # the readout is left-anchored and grows rightward; at 1.35 the twelfth
        # step ran off the frame.
        counter.to_edge(RIGHT, buff=2.45).shift(DOWN * 0.9)
        cents_r = T("0.0 cents", font_size=27, color=WARM)
        cents_r.next_to(counter, DOWN, buff=0.26, aligned_edge=LEFT)
        d0 = Dot(C + polar_et(0.0), radius=0.075, color=WARM)
        self.play(FadeIn(d0), FadeIn(counter), FadeIn(cents_r),
                  run_time=STEP, rate_func=linear)
        for k in range(1, 13):
            cents = k * 700.0
            arc = ParametricFunction(
                lambda t, a=(k - 1) * 700.0: C + polar_et(a + t * 700.0),
                t_range=[0, 1], color=WARM, stroke_width=4)
            d = Dot(C + polar_et(cents), radius=0.065, color=WARM)
            counter.become(T(f"tempered fifths: {k}", font_size=23, color=DIM)
                           .move_to(counter, aligned_edge=LEFT))   # see 04-spiral
            cents_r.become(T(f"{cents % 1200:.1f} cents", font_size=27, color=WARM)
                           .move_to(cents_r, aligned_edge=LEFT))
            self.play(Create(arc), FadeIn(d), run_time=STEP, rate_func=linear)

        done = T("exactly home — 0.0 cents, and it sounds it", font_size=25, color=WARM)
        done.to_edge(RIGHT, buff=0.75).shift(DOWN * 2.4)
        self.play(FadeIn(done),
                  Flash(C + polar_et(12 * 700.0), color=WARM, line_length=0.38),
                  run_time=1.6)
        self.wait(TAIL_ET - 1.6)


if __name__ == "__main__":
    # The build chain reads these offsets rather than re-typing them.
    total = LEAD + 13 * STEP + TAIL_GAP + TAIL_ZOOM
    et_total = LEAD_ET + 13 * STEP + TAIL_ET
    print(json.dumps({"total": round(total, 3),
                      # ⭐ AND THE GAP IS HEARD AS IT IS DRAWN. play-walk.wav
                      # runs 19.5 s from LEAD, so it ends at 23.5 s — exactly
                      # where the miss is revealed. ab-comma.wav (the two A's
                      # the walk started and ended on, played together) is laid
                      # from there, so the viewer sees the seven-degree gap and
                      # hears it beat at the same instant. Without it the last
                      # fourteen seconds of the centrepiece were silent.
                      "audio": [{"wav": "play-walk.wav", "atSec": LEAD},
                                {"wav": "ab-comma.wav", "atSec": LEAD + 19.5}],
                      "closes": {"total": round(et_total, 3),
                                 "audio": [{"wav": "play-walk-et.wav",
                                            "atSec": LEAD_ET}]}}))
