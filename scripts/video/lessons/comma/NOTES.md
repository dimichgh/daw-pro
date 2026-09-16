# Lesson 4 rebuild — The Comma

Film 4 of the 8-film rebuild wave. Nothing of the original survived except
`~/Movies/DAW Pro Lesson 4 - The Comma.publish.json` (title, tags, description).
Every number below was measured off **renders made in this session**; the
shipped description's figures were treated as claims to be re-tested, not data
to quote. They all held — which is itself a result worth stating, because on
film 3 the equivalent claim did not.

## The film as built

`out/L4v2.mp4` — **868.2 s (14:28)**, 1920×1080 h264 / 48 kHz AAC stereo,
**52,058,141 bytes (49.6 MB, `wc -c`)**, **−14.6 LUFS / −1.5 dBTP** (verify.py).
**NOT finalized, NOT published.** The spec's `filename` is
`DAW Pro Lesson 4 - The Comma (rebuild)`, deliberately different from the
shipped file, so even a stray `--finalize` could not overwrite it.

Fifteen chapters, **680.6 s of explanation against 180.5 s of demonstration**
(`out/segments/*-mux.mp4`, ffprobe). Chapter starts include the 4 s intro.

```
0:04  00-open          7:34  08-measure   A/B two A's in tune vs the comma
0:48  01-terms         8:50  09-fix       ← the spiral CLOSING, played
1:30  02-ratio         10:02  10-cost-fifth ← the attention marker
2:23  03-cents         11:07  11-cost-third A/B pure vs tempered third
3:02  04-spiral  ← the centrepiece
4:27  05-arith         12:17  12-depth
5:15  06-render        12:58  13-piano
6:33  07-beating       13:44  14-close
```

⚠ Within a stage the order is TALK → A/B → PLAY. Derived, not assumed: the
cumulative `-mux` durations under that ordering reproduce
`out/L4v2.mp4.timeline.json`'s A/B start for `08-measure` (506.28 s) **exactly**,
and the grand total lands at 868.14 s against ffprobe's 868.2 s on the file.

`verify.py` — **all 8 checks ok**, including `A/B separation`:

```
08-measure    src +0.10 -> film +0.10 LU
11-cost-third src -0.30 -> film -0.20 LU
```

Content gate: best-matching stage **0.35** against a worst-matching control
**0.03** — a **10.9× separation** over 6 blind windows, with the omlx speech
server up on 8000 for the whole build (started before shortsmith, killed
pid-exact — 5059 — afterwards; `lsof -nP -iTCP:8000 -sTCP:LISTEN` empty after,
with 17695 still listening as the positive control that the probe works).

## THE FAULT THIS ONE HAD, AND WHAT I DID ABOUT IT

⛔ **This film does NOT have the audibility fault the first three had, and I did
not invent one.** The comma is a pitch difference in the middle of the
spectrum; a laptop speaker reproduces 440 Hz and 446 Hz perfectly well, and a
6 Hz amplitude modulation at a depth of 0.94 is about as audible as an audio
demonstration gets. Going looking for an inaudibility angle here would have
been the same overreach the wave exists to stop.

**Its weakness was explanatory**, and the brief said so: tuning is where a
novice gets lost fastest, and the original carried that argument largely over
static frames. So the whole budget went on pictures that move and numbers that
are measured.

### The centrepiece: a spiral of fifths that fails to close (`anim_spiral.py`)

`SpiralOfFifths`, **37.5 s**, stage `04-spiral` at 3:02. One octave is the whole
way round the circle; twelve pure fifths are walked, each 1.5 s, each spiralling
out one ring, labelled with the note it lands on (A E B F♯ C♯ G♯ D♯ A♯ F C G D
A). **The thirteen notes of `walk.wav` — rendered by the app — play underneath,
one per step**, so the dot you see placed is the note you hear. The twelfth
fifth lands 7.04° past the start ray (23.46/1200 of a turn); a `home` marker is
drawn on the ray at the same radius so the miss reads as an ANGLE rather than as
"a different ring", and the scene ends on an inset at **7×**, labelled as
magnified.

⭐ **And the gap is HEARD as it is drawn.** `play-walk.wav` ends at 23.5 s, which
is exactly where the miss is revealed; `ab-comma.wav` — the two A's the walk
started and ended on, played together — is laid from there. Verified in the
finished mp4, not just in the plan: the window **253.1–261.1 s** of `L4v2.mp4`
measures **6.008 Hz** (predicted 6.003). Negative control: a pure-narration
window at 120 s measures 0.687 Hz — a syllabic rate, not a beat. (Depth does not
discriminate here; speech is bursty and reads high. The RATE is the test.)
Before this change the last fourteen seconds of the centrepiece were silent.

`SpiralCloses`, **27.5 s**, stage `09-fix` at 8:39, is the payoff and is the
same walk again with every fifth at exactly 700 cents, **under `walk-et.wav`** —
so the fix is played as well as drawn, and the thirteenth note is audibly the A
we started on. The pure walk is drawn underneath as a ghost with its endpoint
marked, because at this scale 1.955 cents a step is invisible and only the
endpoints show the difference.

### The other two animations

* `anim_beat.py` `BeatMechanism`, **24 s**, stage `07-beating`: 30 ms of real
  440/446 Hz waveform on one axis, their SUM on a second axis below, and a level
  bar for the sum's instantaneous height. First half both tones at 440.000 (the
  bar sits still); at 12.0 s one goes sharp by the comma and everything moves.
  The audio switches at the same instant (`ab-unison.wav` at 0, `ab-comma.wav`
  at 12.0 — offsets printed by the scene and read by `bursts.py`, never typed
  twice).
* `anim_time.py` `FifthMarker`, **16 s**, stage `10-cost-fifth`: THE ATTENTION
  MARKER. A real-time playhead over the **measured** envelope of the render,
  band-passed at 1320 Hz. First 8 s the pure fifth (flat — an exact 3:2 cannot
  beat), then 8 s of the tempered fifth with **11 shaded dips**. ⭐ The windows
  are DERIVED — every stretch where the measured envelope falls below half its
  own median — and the derivation finds **0** windows on the pure control, which
  is what makes the 11 mean something.

## Measured numbers, and the commands that produced them

Everything is in `MEASUREMENTS.json`, written by `measure.py` (Welch/FFT peak
with parabolic interpolation, 6th-order zero-phase bandpass, analytic-envelope
beat estimator) over `audio/*.wav`, all of which came out of `render.bounce` on
staging 17695.

### The app puts every tone exactly where the arithmetic says

`tuneCents` on a sampler zone, varispeeding one generated 440.000 Hz sine (or
saw). Measured back by FFT peak:

| tone | rendered | predicted | error |
|---|---|---|---|
| A | 440.0000 Hz | 440.0000 | **−0.0000 cents** |
| the comma-sharp A | 446.0030 Hz | 446.0030 | +0.0000 |
| pure fifth | 660.0000 Hz | 660.0000 | −0.0000 |
| tempered fifth | 659.2551 Hz | 659.2551 | −0.0000 |
| pure third | 550.0000 Hz | 550.0000 | −0.0000 |
| tempered third | 554.3653 Hz | 554.3653 | +0.0000 |

Plus the thirteen notes of the pure walk (**max error 0.0000 cents**) and the
thirteen of the tempered walk (**max 0.0000 cents**, ending at **440.0000 Hz**,
−0.0000 cents from A). Twenty-one distinct tones, all exact to four decimal
places in cents. That is what licenses the film to say its distances are
measurements rather than settings.

### The comma itself

Derived, never quoted: `1200·log2((3/2)^12 / 2^7)` = 531441/524288 =
**23.460010 cents**. `spec.py`'s `check()` refuses to emit a spec if any spoken
figure has drifted from `MEASUREMENTS.json`; there are 27 such assertions.

### Beat rates — three predictions, three measurements, three controls

| configuration | predicted | measured | depth | where measured |
|---|---|---|---|---|
| one A alone | — | — | **0.0000** | whole sound (control) |
| **two A's in tune** | 0.000 | — | **0.0000** | whole sound (control) |
| **the comma** 440 + 446.003 | **6.003 Hz** | **6.003 Hz** | **0.9367** | whole sound |
| a pure 3:2 fifth | 0.000 | — | **0.0000** | 1320 Hz band (control) |
| **the tempered fifth** | **1.490 Hz** | **1.490 Hz** | 0.6674 | 1320 Hz band |
| a pure 5:4 third | 0.000 | — | **0.0069** | 2200 Hz band (control) |
| **the tempered third** | **17.461 Hz** | **17.461 Hz** | 0.6986 | 2200 Hz band |

Predictions and measurements agree to three decimal places on all three.
`—` means the estimator found no peak worth reporting: with depth at or below
0.007 the "rate" it returns is the edge of its own search band and is
meaningless, which is exactly the right answer for a signal that cannot beat.

### Why one wobbles and the other is only rough

The comma beats between the FUNDAMENTALS, so the whole sound modulates: depth
**0.9367**. The tempered third beats inside ONE harmonic, so the whole sound
modulates by only **0.0093** — **101× shallower** — while inside the 2200 Hz
band it is 0.6986. That is the chapter-12 argument, and it is measured rather
than asserted.

### The demonstration survives assembly — checked on the DELIVERABLE

⭐ `verify_film.py` exists because verify.py's A/B separation check compares
**loudness**, and this film's demonstration is a **beat rate**, which loudness
cannot see. It pulls each A/B half's audio back out of the finished mp4 at the
position `L4v2.mp4.timeline.json` records and re-runs the same estimator:

```
08-measure    BEFORE  depth 0.0289 (flat, as it must be)
08-measure    AFTER   5.997 Hz  depth 0.9399   (source: 6.003 Hz)
11-cost-third BEFORE  depth 0.0265 (flat)
11-cost-third AFTER  17.441 Hz  depth 0.7016   (source: 17.461 Hz, 2200 Hz band)
```

### Loudness of the A/B pairs

Each pair carries **ONE shared static gain** (peak-normalised by the louder
member) and `normalize: false`, because `assemble.py`'s per-half single-pass
loudnorm is DYNAMIC and a 6 Hz amplitude modulation is exactly the thing it
would flatten.

```
unison  ×2.2477   ab-unison     −9.60 LUFS   ab-comma      −9.70   Δ −0.10 LU
fifth   ×2.2503   ab-fifth-pure −11.90       ab-fifth-et   −11.50  Δ +0.40 LU
third   ×2.2496   ab-third-pure −11.90       ab-third-et   −11.60  Δ +0.30 LU
walk    ×2.5839   play-walk     −11.30       play-walk-et  −11.30  Δ  0.00 LU
```

## The material

Hand-written; **no generation model was used for any of it.** Two source files,
`mktones.py`: a 24 s sine at exactly 440.000 Hz and a 24 s band-limited saw
(harmonics to 8 kHz, so the 4th and 5th partials that make the third's beating
exist and nothing aliases under varispeed). Everything else is the app: seven
sampler tracks, 27 zones, and one MIDI note per demonstration.

⭐ **The A/B "before" is a properly controlled one.** A 14th zone at pitch 82 is
a SECOND A 440, so the before half is two tones of the same timbre at the same
level differing ONLY by the comma — not one tone against two.

⭐ **And it starts a quarter of a cycle late** (`startFrame: 27`, = 48000/440/4).
Two phase-coherent copies of one sine sum to +6 dB while a beating pair averages
+3, so the naive control rendered **3.0 LU LOUDER** than the demo and the viewer
would have heard "the in-tune one is louder" — an artefact of perfect coherence,
not a fact about tuning. 90° is the exact offset at which two equal sines have
the same RMS as a beating pair. MEASURED: −13.66 against −13.73 LUFS, 0.07 LU
apart.

⭐ **The walk's MIDI pitches are the notes the fifths land on**, not a chromatic
run: A E B F♯ C♯ G♯ D♯ A♯ F C G D A, on MIDI 69–81 with each zone's `rootPitch`
equal to its own pitch (so keymap varispeed is exactly 1 and `tuneCents` is the
only thing setting the frequency). The piano roll therefore draws the actual
circle of fifths as a zig-zag, which is what the narration describes.

## Build chain

```
python3 mktones.py            # the two source tones
node    material.mjs          # -> material.json (every cent value, derived)
node    shoot.mjs             # project, 10 renders, 8 stills, 2 captureUI bursts
python3 measure.py            # -> MEASUREMENTS.json, envelopes.npz, every A/B wav
python3 charts.py             # 4 charts into shots/
python3 bursts.py             # 4 manim scenes -> bursts/ + their beds
python3 spec.py               # -> L4v2.json  (12 cards, 15 stages, 2803 words)
../../shortsmith.py L4v2.json --out-dir out     # NO --finalize
python3 verify_film.py        # the beat rates, re-measured off the mp4
node    restore.mjs <path>    # put staging back
```

Everything heavy that is generated (`out/`, `bursts/`, `manim/`, `media/`,
`*.wav`, `shots/`) is covered by the `.gitignore` lines the mono-bass pilot
added. The retained chain (`*.mjs`, `*.py`, `L4v2.json`, `MEASUREMENTS.json`,
`material.json`, `renders.json`, `NOTES.md`) is not ignored and is committable;
neither is `envelopes.npz` (regenerable by `measure.py`). Same as the three
reference rebuilds, none of which is tracked either. **I committed nothing.**

## Traps hit, in the order they bit

1. ⛔⛔ **BOTH A/B HALVES POINTED AT THE SAME WAV, and every gate passed it.**
   `assemble.py` takes BEFORE from `ab["before"]` and **AFTER from the stage's
   own `loop`**. I set both to `ab-unison.wav`, so the first complete build
   alternated one file against itself — the comma was never played, only the
   badge changed — and `A/B separation` reported `+0.00 -> +0.00 LU`, **green**,
   because the halves genuinely did not differ. Found by reading
   `L4v2.mp4.timeline.json`, which names the wav each half used. *A check that
   compares the film to its sources cannot see a wrong source.*
2. **The corner meter's own kind of defect, one chart down.** `chart-depth`'s
   explanatory caption was placed inside the axes and rendered BEHIND the bars —
   dark grey on purple, unreadable. Found by pulling the frame at 760 s out of
   the finished mp4 and looking at it. Moved to the figure's bottom-LEFT, which
   is the one corner the burned-in meter never occupies. Checked the
   bottom-right of all four charts in the deliverable: clear.
3. **`chart-beats`' legend sat on top of the longest row's value label**
   ("17.461 Hz"). Same method, same fix.
4. **The sampler card photographs USELESSLY without a selected zone.** With no
   `zoneId` it reads "Pick a zone above to tune its pitch" and the TUNE readout
   is not on screen at all. Worse, ⚠ **neither `debug.samplerEditor`'s state
   response NOR `instrument.describeSampler` carries zone ids** — describe
   returns a `zoneSummary` (counts and coverage) and no per-zone array.
   `project.snapshot` is the only read path to one.
5. **A re-run of `shoot.mjs` silently reverted the fixed sampler shot**, because
   the fix lived in a second script. Folded back into `shoot.mjs` and the second
   script deleted, so one run reproduces everything.
6. **`render.bounce` timed out at 30 s** once the seventh track was added
   (`dawctl.mjs` defaults `DAW_TIMEOUT_MS` to 30000). Not a hang — the app was
   fine and still listening. `DAW_TIMEOUT_MS=180000` is now the documented way
   to run `shoot.mjs`.
7. **The burst builder's silence check cannot express "exactly abutting".** The
   inherited `lay()` scored a zero-length gap as `1.0` and killed the build — a
   check no correct layout can satisfy. Now handled explicitly, with the two
   neighbours still required to be non-silent as the control.
8. **And that control then fired for real.** `play-walk.wav` was cut to the
   render's 20.0 s while the thirteen notes finish at 19.5 s, so the quarter
   second before the comma pair was digital silence. Cut to `13 × 1.5` instead.
9. **The film-level beat check's own first result was the fade ramp.** Trimming
   0.6 s off each A/B half left assemble's fade in the window and BOTH controls
   measured a depth of **exactly 0.247** — identical to four decimal places
   across two unrelated pairs, which is what gave it away. Trimming 1.2 s / 1.0 s
   gives 0.0289 and 0.0265.
10. **`13-piano`'s factCheck named a phrase the narration did not contain**
    ("out of tune" — the script says "in pure tune"). Refused at build time,
    which is the gate working.
11. **Whisper writes digits back even when the script spells them out.**
    `00-open` burned eight takes because its facts were `['twelve']` and
    `['seven octaves']` while the transcript said "12" and "7 octaves". Every
    numeric factCheck now carries its digit twin.
12. ⛔ **`Transform` ON A NUMERIC READOUT RENDERS AS MUSH FOR THE WHOLE STEP.**
    A manim `Transform` interpolates across its entire `run_time`, so at 30 fps
    **all 45 frames of a 1.5 s step** showed the counter and the cents readout
    mid-morph — overlapping glyphs, a ghost digit behind a real one, a count
    that read "1 1", "702.0 cents" as unreadable smear. Both spiral scenes did
    it, for 24 of their 25 steps. Found by pulling a frame at **585 s** out of
    the *finished film* and looking at it; the end-of-step frames I had been
    checking were all clean, which is exactly why it survived four builds.
    Replaced with `.become()` immediately before the step's animation, so the
    number changes instantly and then holds, and re-checked at steps 0, 1, 4, 8
    and 12.
13. **manim layout, all found by looking at frames:** the readout `23.5 cents`
    ran off the right edge (Transform grows text rightward from its left edge);
    the `0` cents tick collided with the title; the inset at 12× overflowed the
    frame and sat on top of two other text blocks; the beat scene drew the sum
    on top of its own components and put its x-tick labels at y=0, which on a
    bipolar plot is the MIDDLE; the marker scene's three-line caption ran
    through its x-axis labels.

## Judgment calls made while the user was asleep

* **Did not go looking for an audibility fault.** The brief said this film does
  not have one and the measurements agree: the comma is a 6 Hz modulation at
  depth 0.94 in the middle of the spectrum. What IS said about audibility is the
  thing the numbers actually show — the tempered third's beating is 101×
  shallower in the whole sound, which is why it reads as roughness.
* **Spent the length on explanation.** 14:28, of which 680.6 s is talk. Five
  chapters (01, 02, 03, 06, 12) exist purely to make the argument followable,
  and 06 exists to make the method checkable.
* **Made the fix audible, not just visible.** Adding the ET walk cost a seventh
  track and a re-shoot; it is the difference between being told the circle
  closes and hearing it close.
* **Level-matched the A/B by PHASE rather than by gain** (trap above), so no
  post-hoc gain was applied to one half of a pair.
* **No generation model** for any material, per the standing rule.
* ⛔ **The film never mentions that a previous version of it exists**, per the
  ruling recorded in the beethoven-128 notes.

## What I could not do / known weaknesses

* **`verify.py`'s A/B separation check is nearly vacuous on this film.** Its
  pairs are deliberately level-matched (0.10 / 0.30 LU), so the comparison it
  makes is between two small numbers. It passes honestly, but the substantive
  protection here is `normalize: false` plus `verify_film.py`, which measures the
  thing the film is actually demonstrating.
* **Per-take narration scores come from the build gate's own log**, not from an
  independent re-transcription: `00-open` take 2 sim 0.99 (brand OK), then
  0.99 / 0.99 / 1.00 / 1.00 / 1.00 / 0.99 / 1.00 / 0.98 / 0.99 / **0.94** /
  0.98 / 1.00 / 1.00 / 1.00 take 5 (brand OK). `04-spiral` was re-recorded once
  after its narration changed: take 1, sim 1.00.
* **Spot transcription of the deliverable** (whisper-large-v3-turbo, same
  server): 330–350 s returns "…The tune knob reads plus 702 cents…" — the value
  the panel is showing at that instant; 836–854 s returns "…built, rendered and
  measured in DAW Pro. Thanks for watching." — brand correct.
  **Negative control**, 500–516 s (a window of pure test tones with no speech in
  it): "Thank you." — the documented babble artefact, i.e. the probe correctly
  finds no speech where there is none.
* **The `walkplay` burst is captureUI at 2.94 fps**, so the playhead on stage 06
  moves in visible steps rather than smoothly. The screen recorder would have
  been smoother; I did not use it, because the piano-roll framing the burst
  gives (clip-scoped, scrolled to the notes' median pitch) is the framing the
  chapter needs and the recorder captures the whole window. First frame checked:
  it shows the DAW's piano roll with the walk's notes, and frame 30 reads TIME
  0:09.849, matching 9.85 s of the burst's own measured rate.
* **`02-ratio` plays a pure fifth under narration that has just described it**,
  which is the only place a demonstration and its explanation overlap; every
  other demo waits for the sentence to finish.
* **The chart-ladder's 23.46-cent arrow is 23 cents out of 1290 on screen** and
  is annotated rather than legible as a gap. That is deliberate — the magnified
  version is the spiral scene's inset — but on its own the chart understates it.
* **`instrument.setSamplerZones` is not a wire command** (the merge-by-id path
  is MCP-only, `instrument_set_sampler_zones`, bridging to
  `track.setInstrument`). Zones here are always sent as a complete map.
* The staging session that was open before this work was saved to
  `…/scratchpad/staging-before-comma.dawproj` and **reopened and verified by
  re-reading**: tempo 100, tracks Pad / Bass / Drums / Lead, playhead 0, master
  volume 1, `warnings: []`. ⭐ The panel layout was **read before anything was
  changed** and restored to the user's own values, field for field, then
  re-read: `pianoRollPPB 32, pianoRollRowHeight 14, rowHeight 50,
  editorFraction 0.45, editorMaximized false, followPlayhead false,
  pianoRollMinimap true, sidebarWidth 260, waveformNormalize true,
  waveformVerticalZoom 1, mixerInsertsCollapsed false, auditionEnabled true` —
  identical to the pre-work read. The mixer is closed and the sampler card is
  closed. Port 17600 was never contacted (it was not even listening); every
  command went to 17695 through `session/build.mjs`, which refuses 17600.

## Final-build note

The last rebuild (fixing trap 12) ran `--skip-narrate` with the speech server
already killed, and `verify.py`'s content check reported **BROKEN**, not `ok` —
the documented silent downgrade. The server was restarted and `verify.py` re-run
against the FINAL `out/L4v2.mp4`: **ALL 8 CHECKS PASSED**, content
**0.35 vs 0.03, 10.9× over 6 blind windows**. The server (pid 15863) was then
killed pid-exact; `lsof -nP -iTCP:8000 -sTCP:LISTEN` is empty, with 17695 still
listening as the control that the probe works. Port **17600 was never listening
at any point** in this session and was never contacted.

## The last thing found, and it was a false claim on screen

The method chapter, `06-render`, existed to make the film checkable: *here is
exactly how every sound was made, so you can audit it.* It said, in narration
and on card 5 and in the description:

> There is one audio file: a sine wave … every single pitch you hear in this
> lesson is that same one file with a different number in that box.

**That was false, and the panel behind the voice said so.** `mktones.py` writes
**two** files. `shoot.mjs` gives the walk and the two A's `sine440.wav`
(lines 19/34/41) and gives the root, the fifths and the thirds `saw440.wav`
(lines 78–82) — because the beating in a fifth or a third lives between
*harmonics*, and a sine wave has none to collide. The frame at 326 s, at the
moment the voice says "that same one file", shows the zone list reading
`saw440.wav`. My own NOTES already said "Two source files." Nothing compared
them; no gate can.

Fixed in narration, on card 5, and in the description, and the corrected claim
is now *load-bearing on a gate*: `06-render`'s `factCheck` carries
`["sawtooth", "saw tooth", "saw-tooth"]`, so a build in which the two-file
correction is not actually spoken is refused. It passed take 1, sim 0.98,
facts OK (3).

Two other things went with that re-narration:

* `10-cost-fifth` said 440 and 659.255 Hz are "two hundred hertz apart". They
  are 219.255 Hz apart. Now "over two hundred".
* "twenty one tones" → "twenty one **measurements**". Three of the twenty one
  are the same 440.000 Hz (the sine root, the saw root, and the comma pair's
  lower note), so they are not twenty one *distinct* tones. The error figure
  was always right; the noun was not.

### And the A/B stills described the wrong half

Both A/B stages showed, over the **BEFORE** audio, a card that states the
**AFTER**'s result — card 6 ("6.003 PULSES A SECOND") over the two in-tune A's,
and card 8 ("what the fix costs") over the *pure* third. The badge said BEFORE
while the picture argued the AFTER.

* `08-measure` BEFORE → `roll-beat.png`, the two notes actually sounding.
* `11-cost-third` → the two sampler cards *are* the A/B: same `saw440.wav`,
  **TUNE +386 cents** (pure) against **+400** (tempered). Both crops were
  pulled and looked at before being wired in. You now watch the number change
  while you hear it change, which is a better shot than either card was.

Re-verified after the rebuild, not assumed: `verify.py` 8/8 with the content
gate **ok** (0.32 vs 0.03, 12.2× over 6 blind windows — not BROKEN; omlx was up
on pid 16556 for the build and killed pid-exact after, with 17695 as the
positive control and 17600 never listening at any point), and `verify_film.py`
green on the shifted A/B positions: `08-measure` BEFORE depth 0.0289 /
AFTER **5.997 Hz** depth 0.9399; `11-cost-third` BEFORE depth 0.0265 /
AFTER **17.441 Hz** depth 0.7016.

### One weakness withdrawn

An earlier note listed "02-ratio plays a pure fifth under narration" as a
weakness. It is not one — the house order within a stage is TALK → A/B → PLAY,
so the fifth plays *after* its explanation, not under it. The note was wrong
about the film, not the film wrong about itself.


### And the same fault once more, in the shot list

Fixing the words exposed a second half of the same bug. `06-render` READS A
VALUE OFF A CONTROL — "the tune knob reads plus seven hundred and two cents" —
and the house rule is that the control must be on screen when it does.
`shots=[5, SAMPLER_5, ROLL_ZOOM]` with `holdLast=True` does not do that.
`assemble.stills()` cuts the 58.4 s talk into `n = round(58.4/7.0) = 8` slots of
7.3 s and holds only the LAST, so the sampler card was on screen **7.3-14.6 s**
while the value is spoken at **~25.8-31.5 s** (char-proportion estimate over the
narration). Confirmed in pixels, not by the estimate: the frame at **340 s** of
the previous build showed the PIANO ROLL under the words "on screen now".

Re-ordered to `[5, ROLL_ZOOM, SAMPLER_5]`, which holds the card from 14.6 s to
the end of the stage. Re-checked in the finished film at **335, 343 and 350 s**:
the card is up at all three, and the frame at 343 s reads `saw440.wav` and
**+702 cents** — the file the corrected narration now names, and the value it
quotes, both legible under the words. Stage durations are unchanged by a
re-ordering, so the chapter table above still holds.

Final: **868.2 s**, **52,058,141 bytes**, `verify.py` 8/8 with content **ok**
(0.32 vs 0.03, 12.2×; omlx pid 17952 up for the build, killed pid-exact, 17695
positive control still listening, 17600 never listening at any point), and
`verify_film.py` green on all four halves.

⚠ The lesson here is the one the house standard already states and I still had
to be shown twice in one sitting: **a card, a panel and a sentence can each be
individually correct and still disagree with each other, and no gate in this
pipeline compares them.** Both halves of this bug — the words claiming one file,
and the control not being on screen when its value is read — passed every
automated check in the build. Only looking at the frame found either.
