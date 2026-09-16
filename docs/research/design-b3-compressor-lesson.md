# B3 probe — "Seven knobs, and only two of them decide how much"

**Status: DESIGNED, NOT SHOT.** This is the single episode that decides whether
the mix-panel series (backlog B3, `docs/lessons/PROGRAM.md`) is worth making.
Build this one end to end, look at it, and then decide — not from a plan.

## Why the compressor is the right probe

It is the control people most often use without understanding, it has the most
knobs of anything in our chain (**seven**), and — the reason it beats every
other candidate — **its behaviour is arithmetic, so every claim in the episode
can be predicted before it is measured and then checked against the render.**
An episode about reverb would rest on adjectives. This one cannot.

The built-in soft-knee compressor (`CompressorParams`,
`Sources/DAWCore/Effects.swift:353`) exposes:

| param | range | default |
|---|---|---|
| `thresholdDb` | −60…0 | −18 |
| `ratio` | 1…20 | 4 |
| `attackMs` | 0.1…200 | 10 |
| `releaseMs` | 5…2000 | 100 |
| `kneeDb` | 0…24 | 6 |
| `makeupDb` | 0…24 | 0 |
| `mix` | 0…1 | 1 |

## The thesis

**Threshold and ratio decide HOW MUCH gain reduction. Attack and release decide
what it SOUNDS like. Knee decides where the two meet. Makeup and mix are not
compression at all — they are what you do about it afterwards.**

That split is the spine, and it is why the episode is not a knob tour.

## Six demonstrations, each with the number predicted BEFORE it is measured

⭐ **The gate that makes this episode different: for the first four, the answer
is computable from the parameters alone. Write the prediction into
`MEASUREMENTS.json` FIRST, then render and measure, then show both on screen.**
If a measurement disagrees with its prediction, that is either a bug in our
compressor or an error in the lesson — and either one is worth more than the
episode.

1. **Threshold + ratio → how much.** For a steady tone above threshold, gain
   reduction is `(inputDb − thresholdDb) × (1 − 1/ratio)`. A −6 dBFS tone at
   threshold −18, ratio 4 predicts **9.0 dB** of reduction. Render, measure
   output level, subtract. ⚠️ Use a STEADY tone here, not a drum — a transient
   brings attack into it and the arithmetic stops being clean, which is exactly
   the confusion the next demo exists to introduce deliberately.
2. **Attack → what survives.** Same drum hit at `attackMs` 0.1 vs 50. Measure
   the peak of the first 5 ms against the peak of the body. Fast attack flattens
   the click; slow lets it through and only squashes what follows. **This is the
   knob people think is "how fast it works" and it is really "how much of the
   transient you keep".**
3. **Release → pumping, measured as a rate.** Same loop at `releaseMs` 30 vs
   800. Take the level envelope between hits and measure its modulation depth in
   dB and its rate in Hz. Pumping is not a vibe; it is a number, and the number
   is the tempo.
4. **Knee — the demo nobody does.** Hard (`kneeDb` 0) vs soft (24) at the SAME
   threshold, with a tone **just BELOW** threshold. Hard knee: 0.0 dB of
   reduction. Soft knee: a measurable non-zero. That single pair explains knee
   better than any curve diagram: **a soft knee starts working before you cross
   the line.**
5. **Makeup → why every A/B you have heard is a lie.** The compressed version
   with makeup is LOUDER, and louder always wins a blind comparison. Play the
   pair twice: once as everyone demos it, once **loudness-matched** with
   `render.measureLoudness`. State the LUFS of both takes on screen. ⚠️ This is
   the episode's honesty beat and it must not be softened.
6. **Mix → the thing that used to cost a second track.** `mix` 1.0 vs 0.4 at a
   crushing setting (low threshold, high ratio). Measure BOTH the surviving
   transient peak AND the short-term loudness of the body, and show that
   parallel raises the second without flattening the first — which fully wet
   compression cannot do. Cite the shipped semantics: makeup lives in the WET
   path only, and `mix: 0` is a bit-exact bypass.

## Controls that must be rendered, not asserted

- **A `ratio: 1` control render** for demo 1. Ratio 1 is unity — reduction must
  measure 0.0 dB. Without it, "9.0 dB" is a number with nothing to fail against.
  (The thunder chapter of the session film is the precedent: the automation-OFF
  render is what proved the filter was doing the work.)
- **A `mix: 0` control render** for demo 6, asserted bit-exact against the dry
  input. The docs claim bit-exact bypass; an episode that repeats that claim
  should verify it.
- **The gain-reduction meter reports the DETECTOR's reduction, unscaled by
  `mix` and excluding makeup.** At `mix: 0` the meter still shows reduction while
  the effect passes silence-through. That is deliberate and documented — if the
  episode shows the meter at all, it must say so or it teaches a wrong reading.

## Format

**1920×1080 lesson, 3–5 minutes.** Not a Short: the subject is a panel with
seven labelled controls, and a 9:16 crop takes a COLUMN out of a wide window —
measured while cutting the session film.

Every parameter change is SHOWN being made (`sweepshot.mjs`'s pattern: step the
value, photograph each step, cut at the narration's pace), and every demo
segment shows the app PLAYING it (`burst()` in `scripts/video/session/build.mjs`),
with the corner meter on (`"meter": "br"`). The user's standing note from the
session film applies: *"you need to show that you did the work in DAW, not just
saying it"*.

⚠️ **The roll must be pointed at its notes** — `burst()` now sends the clip's
median pitch, but a kick loop at C1 is exactly the case that used to photograph
an empty grid.

## Source material

One programmed drum loop, written note by note in the app — no sample. It has to
be percussive (demos 2, 3 and 6 need transients) and steady (demo 3 needs a
regular gap to measure the envelope in). Plus one steady tone for demos 1 and 4,
where a transient would pollute the arithmetic.

## What would make me NOT make the series

If, after building this, the six demonstrations feel like six disconnected
measurements rather than one argument, the series is a knob catalogue and should
not be made. The test is whether a viewer can state the thesis afterwards — not
whether they can list seven knobs.
