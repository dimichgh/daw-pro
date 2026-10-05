# B3 re-cut — the compressor lesson, second pass

**Status: DESIGNED. Charts and demo-3 audio BUILT and verified. Narration and
assembly NOT yet cut.**

Two notes from the user after watching cut 1, and the whole of this document
exists to answer them:

> Is there a way to show visual, I cannot hear anything different in release and
> knee comparison (using MacBook Pro m5 laptop speakers). [...] Can we use more
> visual with manim or similar demo wherever possible. Also when in the sound you
> want viewer to pay attention as it plays the sound or music, can you use some
> marker alert [...] and where if there is some location

> When you start the video, it goes as "This is a compressor…" like you are
> referencing to something as if it is continuation of something before this
> video. Better introduce what compressor does and why (assume novice person
> learning sound mixing), how you are going to demo and how and then work on it.
> **The time constrains are good, but it is more important to have a balanced
> video vs rushing to fit everything in.**

## ⭐ The finding: they were right BOTH times, and neither was a speaker fault

This is the part to carry forward. Both complaints were measured, and both were
faults in the film, not in the listening.

**Release.** Cut 1's two settings differed by 11.5 dB — but at −39.9 vs
−51.5 dBFS. The information lived in the drum *tail*, because between hits
nothing else was sounding. That is 25–35 dB below the film's own level, i.e.
under a laptop speaker's floor. **The one thing the chapter existed to
demonstrate was the one thing inaudible.**

**Knee.** The gap is bounded by the gain computer's own arithmetic:
`max gap = slope · knee / 8`, largest exactly at the threshold. At the demo's
ratio 4 / knee 24 that is **2.25 dB**; at the widest ratio the plugin offers it
is **2.85 dB**. Loudness JND is about 1 dB ideal and worse on a small speaker.
**No signal and no setting could have made cut 1's knee demo audible.**

## What was rebuilt (done — do not redo)

### Demo 3 re-shot with a pad — `d3pad.mjs`

Pumping is heard on something that *sits under* the hits. A held saw triad was
added at a level you can hear, so the kick ducks **the pad** and the recovery
happens on a sound that is present throughout.

Two calibrations were paid for by measurement and must not be casually changed:

- **Pad gain 0.08.** At 0.42 the pad peaked −9.05 against a −4.82 full mix and
  sat *above* threshold on its own: reduction pinned at 15–18 dB for the entire
  render, never recovering. The pad must clear the threshold by more than the
  knee half-width; it now clears by **4.59 dB**.
- **Ratio 20, not 8.** Ratio 8 measured only 5.9 dB of duck. Depth is the
  audibility lever: a ~7 dB return to an audible level is a gesture; 5 dB is a
  nuance.

Result, measured: **fast lets go completely between hits (median 0.00 dB); slow
never lets go at all — its least-reduced moment in the whole loop is −2.17 dB.**
The pad sits 3.3–4.0 dB louder between hits on the fast setting.

⚠️ **The two renders are DELIBERATELY NOT LOUDNESS-MATCHED.** The 2.7 LU
difference *is* the release still holding the bed down. Matching it away would
convert the lesson into "the kicks stand taller", one step removed from the
point. **One common gain (+9.2 dB) is applied to both, and the film says so on
screen.** This does not contradict demo 5, which compares compressed against
uncompressed *with makeup*; demo 3 compares two settings at equal gain.

Deliverables: `audio/d3p-fast-lvl.wav` (−20.0 LUFS), `audio/d3p-slow-lvl.wav`
(−22.7 LUFS).

### Two manim charts — `anim_release.py`, `anim_knee.py`

Both are **drawn from measured data, not illustrated.** `gaincurve.py` divides
the compressed render by the dry one sample for sample (exact, because `mix=1`
and `makeup=0`), so the release chart *is* the compressor's own gain signal. A
hand-drawn exponential would look identical to a viewer and would be a lie in a
film whose premise is predict-then-measure.

The knee chart transcribes the shipped gain computer and **predicts 1.5625 dB
where the render measured 1.52** — 0.04 dB apart. Show both numbers.

## ⭐ The attention marker — one device, used the same way every time

The answer to "I couldn't hear it" is not *listen harder*. It is to say **when**
to listen and **where**.

1. **A playhead sweeps the chart at real time** while the viewer hears the
   matching audio. ⚠️ `run_time` **must** equal the span of audio laid under it —
   a playhead pointing at the wrong instant is worse than no marker at all.
   `anim_release.py` prints the sweep start times as JSON for the assembler;
   use them, do not eyeball the sync.
2. **The listen-windows are shaded on the plot**, and they are **derived, not
   chosen by eye**: every window where the two settings differ by more than
   3 dB. The unshaded slivers between them are the hits themselves, where both
   settings clamp equally and there is nothing to hear.
3. **A warm-coloured line names the thing to listen to** — "listen HERE — the pad
   between the hits (5.7 dB apart)" — before the sound starts, not during it.

Reuse this device in any later chapter that asks the viewer to hear something.

**Headphones:** one short card near the top ("headphones help in the release and
knee chapters"), as a courtesy — **not** a gate. The visuals must carry both
chapters without them, and after this re-cut they do.

## The new opening — chapter 0, and it is NOT a tightened first line

Cut 1 opened "This is a compressor…", which reads as a continuation of something
the viewer missed. Replace it with a real introduction, written for someone
learning mixing who has never used one:

1. **What it does** — turns the loud parts down, automatically. A hand riding a
   fader, that never gets tired and reacts in milliseconds.
2. **Why you would want that** — so the quiet parts are not lost and the loud
   parts do not jump out; so a part sits in a mix; and only then, so the whole
   thing can be made louder without clipping. Makeup is *why* compression became
   synonymous with loudness — that is demo 5's honesty beat, so plant it here.
3. **What the seven knobs split into** — the film's spine, stated up front:
   *threshold and ratio decide HOW MUCH. Attack and release decide what it SOUNDS
   like. Knee decides where those two meet. Makeup and mix are not compression at
   all — they are what you do about it afterwards.*
4. **How this demo works** — every number is **predicted from the parameters
   before anything is rendered**, then measured off the render, and both go on
   screen. If they disagree, that is a bug in the compressor or an error in the
   lesson, and either is worth more than the episode.

A small manim diagram fits at (1): a level line crossing a threshold, and the
part above it being pushed down.

⭐ **The user's instruction on length is explicit: balance beats fitting
everything in.** Let the film run past five minutes rather than compress the
introduction. **If something must go, shorten or drop a demo — demo 6 (mix) is
the most detachable — never the intro.**

## What the two rebuilt chapters must now SAY

**Release.** Not "listen to the pumping". Say: *the pad is what to listen to; on
the fast setting it comes all the way back between every hit, on the slow one it
never comes back at all* — with the chart showing exactly that, and the
least-reduced numbers (0.00 dB vs −2.17 dB) on screen.

**Knee.** ⚠️ **State plainly that you will not hear it on laptop speakers.** Give
the bound — 2.25 dB here, 2.85 dB at the widest setting this plugin allows — and
land it as the lesson: **a soft knee is called gentle because it is gentle.** Do
not soften this into "listen closely", and do not imply the viewer's ears or
speakers are at fault. The chart is the only place this difference will ever be
visible, and saying so is the honest version of the chapter.

## Still true from cut 1

Everything in `design-b3-compressor-lesson.md` that this document does not
override still stands: the six demonstrations, the predict-then-measure gate,
the `ratio: 1` and `mix: 0` control renders, the note that the GR meter reports
the detector's reduction unscaled by `mix`, 1920×1080, and the standing rule
that every parameter change is SHOWN being made in the app rather than asserted.
