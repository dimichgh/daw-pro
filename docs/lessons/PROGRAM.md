# Video program — wave tracker

The state of every planned video. **Update the row after every step.** This file
is what a later session resumes from; the scratchpad is not durable.

A video is `done` only when ALL FIVE hold:

1. `narrate.py` content gate passed (every line transcribed back and scored)
2. `assemble.py` produced a file
3. `verify.py` exited **0** (frame size, A/V drift, distinct frames, audio
   present, loudness, joins, content)
4. **A human-equivalent look** — at least 3 frames inspected. No gate here can
   see a wrong pixel.
5. **Brand substring check** — the transcript literally contains "DAW Pro". An
   aggregate score of 0.9 will happily pass "DW Pro"; measured twice now.

## Conventions

- **Shorts**: 1080x1920, ≤ 60 s, `#Shorts` in the description, 1–2 narration
  lines. Themes `quicktip` / `theory` / `history`.
- **Lessons**: 1920x1080, 3–8 min, full manifest with TALK/PLAY beats.
- **Theme** is a `brand.py --theme` overlay from
  `claude-plugin/skills/demo-film/brand.json`. It moves the accent colour and
  the sub-label only — never the wordmark — so episodes differ without the
  channel changing.
- Facts come from `docs/research/video-facts-{tuning,history,loudness}.md`.
  **Every number on screen must trace to a line in one of those**, with its
  confidence tag. Anything the research marked UNVERIFIED does not go on screen
  as a fact; it gets measured here instead, or it is cut.

## Shorts

| # | Title | Theme | Fact source | Status |
|---|---|---|---|---|
| S1 | Stack twelve fifths and you miss the octave | theory | tuning §Pythagorean comma (EXACT) | **DONE, REBUILT 2026-09-04** from a proper spec (the original had no spec and its assets were gone) — 41.5 s, brand gated on take 2. Old note follows: 38.4 s, 1080x1920, −16.5 LUFS / −1.5 dBTP, verify 6/7 ok + content BROKEN-by-design (38 s < 45 s valid range), 5 frames looked at, brand substring confirmed on take 5 of 7. `~/Movies/DAW Pro Short 1 - The Comma.mp4` |
| S2 | 432 Hz is not ancient | history | tuning §A440 (myth/correction) | **DONE** 44s, sim , verify ok, sheet-checked. `DAW Pro Short 2 - 432 Hz.mp4` |
| S3 | Your major third is 14 cents sharp | theory | tuning §12-TET (EXACT) | **DONE** 33s, sim 0.94/1.00/0.96, verify ok, sheet-checked. `DAW Pro Short 3 - The Sharp Third.mp4` |
| S4 | Spotify turns quiet songs UP | quicktip | loudness §Spotify (platform-stated) | **DONE** 36s, sim 1.00/0.97/1.00, verify ok, sheet-checked. `DAW Pro Short 4 - Normalisation.mp4` |
| S5 | A piano is tuned wrong on purpose | theory | tuning §Railsback | **DONE** 30s, sim 0.98/0.97/0.96, verify ok, sheet-checked. `DAW Pro Short 5 - Stretch Tuning.mp4` |
| S6 | Minus 0.1 dBFS can still clip | quicktip | loudness §true peak (standard) | **DONE** 31s, sim 1.00/1.00/1.00, verify ok, sheet-checked. `DAW Pro Short 6 - True Peak.mp4` |
| S7 | The tone that rises forever | theory | history §Shepard tone | **DONE** 45s, sim 1.00/1.00/0.95, verify ok, sheet-checked. `DAW Pro Short 7 - Shepard Tone.mp4` |
| S8 | The devil's interval was never banned | history | history §tritone (myth/correction) | **DONE** 30s, sim 1.00/0.97/0.96, verify ok, sheet-checked. `DAW Pro Short 8 - The Tritone Myth.mp4` |

| S9 | A guitar is never quite in tune | theory | tuning §12-TET | **DONE** |
| S10 | Two knobs make MIDI drums human | quicktip | DAW Pro humanize semantics | **DONE** |
| S11 | The reverb knob you are not using | quicktip | mixing convention (flagged as such) | **DONE** |
| S12 | Your mix is not bass-light. You are. | theory | loudness §ISO 226:2023 | **DONE** |

## Lessons

| # | Title | Theme | Fact source | Status |
|---|---|---|---|---|
| L1 | Bach wrote a loop. I just added a kick. | remix | history §BWV 846 | **DONE** 140.2 s, verify 7/7 ok, −17.8 LUFS / −1.5 dBTP, brand gated (take 7 — 6 takes said "DAWB Pro"), 7 frames looked at. `DAW Pro Lesson 5 - Bach House.mp4` |
| L2 | The comma that broke tuning | theory | tuning §1–2 | **DONE** 123.0 s, verify 7/7 ok. **REBUILT 2026-09-03** with `bedEligible:false` — see the bed finding below. `DAW Pro Lesson 4 - The Comma.mp4` |
| L3 | Chasing −14 LUFS, and the bill it comes with | mastering | loudness §1–2 + measured here | **DONE** 169.3 s, verify 7/7 ok. Four masters measured: −20.3/4.4 LU → naive +6.25 dB hits −14.0 but peaks +3.4 dBFS → 1594 clipped samples, distortion isolated at −46.5 dBFS with a −inf null control → comp+limiter −14.2/−1.0 dBTP/1.5 LU. `DAW Pro Lesson 6 - Chasing -14.mp4` |
| L4 | Beethoven's metronome marks are too fast. Nobody knows why. | history | history §Beethoven (DISPUTED) | **DONE** 182.2 s, verify 7/7 ok. Presents all three explanations, none as the answer. Clicks measured back at 108.00/92.00, spread 0.15 ms; the Fifth's motif gap 1.970 s vs 1.680 s against 1.957/1.667 predicted. `DAW Pro Lesson 7 - Beethovens Metronome.mp4` |
| L5 | Your bass sounds huge. In mono it is 10 dB quieter. | mastering | measured here | **DONE** 144.0 s, verify 7/7 ok. Built in the DAW, not synthesised: one bassline on two hard-panned tracks, only the clip offset changes. Mono fold, 60–110 Hz: 0 ms −37.42 dB, **6 ms −47.58 dB (−10.16)**, 15 ms −39.72 dB. Control: L reads −36.51 dB in all three. `DAW Pro Lesson 8 - Mono Your Bass.mp4` |
| L6 | The Amen break, programmed by hand | remix | history §Amen | **DONE** 154.6 s, verify 7/7 ok. 53 programmed notes, nothing sampled; the 1969 recording is in copyright to the 2060s and is never touched. Humanize shift measured off the project: largest 7.81 ms, mean 3.54 ms, against a sixteenth of 110.29 ms. `DAW Pro Lesson 9 - The Amen Break.mp4` |
| L7 | Why your strings sound fake | quicktip | measured here | **DONE** 137.2 s, verify 7/7 ok. Same 32 notes twice; only three lanes change — onsets 0.0 → up to 38.2 ms (mean 16.9), velocity flat 90 → 68–111, and a 129-point CC 11 curve. Envelope variation −13.60 → −10.34 dB, both renders within 0.3 LU. `DAW Pro Lesson 10 - Strings That Breathe.mp4` |
| L8 | Beethoven at 128 BPM — four notes, and nothing else | remix | history §Beethoven | **DONE** 158.4 s, verify 7/7 ok. His four-note cell as a techno riff; the repetition is stated on screen as mine, not his. Orchestral −47.2 dB below 100 Hz vs techno −29.4 dB = 18 dB of fundamental an 1808 orchestra could not make. `DAW Pro Lesson 11 - Beethoven At 128.mp4` |

## Findings from wave 3 (L5-L8)

⚠️⚠️ **A `[ FAIL ]` WAS PRINTED AND THEN IGNORED.** L6 failed verify.py's
true-peak check at −0.3 dBTP and `shortsmith.py` copied it to `~/Movies`
anyway, one line below the word FAIL. **A gate nobody obeys is decoration.**
shortsmith now raises on any `[ FAIL ]` (a `[BROKEN]` still does not block —
that means the probe could not judge, which is the documented state for a
Short).

⭐ **`loudnorm`'s single-pass `TP=` is a target, not a guarantee** — percussion
sails past it. `assemble.py` now measures the finished concat and applies a
**static trim** (not a limiter: if the peak is 0.7 dB high, turn the film down
0.7 dB, reshaping no transient), then re-measures, up to four passes, and
fails loudly if it will not converge.

⚠️⚠️ **`amix` QUIETLY TOOK 6 dB OFF EVERY NARRATED LINE THAT HAD A BED.**
ffmpeg's `amix` divides each input by the number of inputs, so mixing a bed
under a voice that had just been loudness-normalised to a target undid the
normalisation — bedded stages sat 4.4–6.0 dB below unbedded ones in the same
film, an audible drop exactly when the music came in. Nothing caught it: every
gate measures the film as a whole, and no gate compares one stage against
another. Fixed with `normalize=0` (the bed already carries its own explicit
`volume=`). **Found only because the bed A/B was built as a real experiment —
same video, same voice takes, one flag different — which made a 5 dB step
impossible to miss.** The `amix` default is the trap: it re-levels when you
asked it to mix.

⚠️ **The retry loop is a MITIGATION, not an explanation.** A single static trim
of exactly the measured excess sometimes did not land the peak where the
arithmetic says it should — most likely the AAC re-encode each pass moves the
true peak again, but that was never measured, only assumed. It converges in
practice (every one of the twenty landed at or under −1.0 dBTP within four
passes) and the loop refuses to ship if it does not. **Do not read the loop as
a solved problem;** if it ever stops converging, the unexplained part is where
to look first.

⚠️⚠️ **A FAILED SHELL LOOP PRINTED A FULL TABLE OF NUMBERS.** Every ffmpeg call
in a delay sweep errored, and the report still printed `+37.08 dB` for all
eight rows — that figure was arithmetic on an empty string. **Never compute a
column from a command whose success you did not test;** `test -s` on the output
first, and print "NOT CREATED" instead of a number.

⚠️⚠️ **AN ffmpeg NULL TEST GAVE A FALSE PASS.** A `channelsplit`/`adelay`/`join`
graph nulled to −inf against a DAW render, "proving" a synthesis matched it.
Direct sample comparison said the two differed by 0.116 — and the same
filtergraph shape demonstrably failed silently minutes later. **The simple
instrument (max |a−b|) beat the clever one.** The measurement was redone from
real DAW renders instead, with a control that passed: the untouched left
channel read −36.51 dB in all three.

⭐ **CC 11 RESTS AT 127, NOT 0.** A "sensible-looking" expression lane is a
broad attenuation of the whole track, not a shaping. Draw it near full and dip
only where you want less. (The wire reference warns about this and it cost a
finished mix 1.25 LU once already.)

⭐ **A LAYERED ARRANGEMENT NEEDS A PURPOSE-CUT EXCERPT.** Both L1 and L8 build
in layers over 16 bars, so the A/B has to be cut from where everything is
already playing — bar 5 for L1, bar 7 for L8 — and run 8–10 s a side.

## Standing constraints for this program

- **Port 17600 is the user's LIVE app.** Anything that drives it is serialised —
  one at a time — or two runs photograph each other's dialogs.
- **Never `project_new` with `discardChanges` on their session.** Check
  `project_overview` for unsaved state first and work in a project I create and
  name.
- **No recordings.** The Amen break is programmed as MIDI; the Bach is
  hand-entered. A public-domain COMPOSITION is not a public-domain MIDI FILE or
  EDITION — that distinction is in the history research doc.
- **Nothing is committed** without the user's explicit word.
- Kill the speech server on port 8000 pid-exact at the end of every wave.

## Findings from wave 1 (S1)

⚠️ **"This is DAW Pro." at the END of a line is hard for the model.** Four of
five takes said "DW Pro" or "DAO Pro" while scoring 0.78–0.88 on the aggregate —
comfortably passing. Only the explicit substring check caught it. Either budget
the retries, or put the product name somewhere other than the final phrase.

⚠️ **`verify.py`'s content gate cannot judge a Short** and says so: below 3
stages or 45 s it reports BROKEN, not ok. For Shorts the content evidence is
`narrate.py`'s per-line score plus the brand substring check — record both.

## Findings from wave 2 (L1, L3, L4, and two user corrections)

⚠️⚠️ **THE OUTRO CLAIMED SOMETHING FALSE ON EVERY VIDEO.** `brand.json`'s
`line2` read "Written, mixed and measured in DAW Pro" — true for L1 and L3,
**not** true for the twelve Shorts, L2 or L4, whose audio is generated in
Python. It now reads **"Every number in this video was measured, not
estimated"**, which is the channel's actual promise and is true of all of them.
**All 16 shipped videos were re-rendered.** S1 had no spec and its build assets
were gone, so it was rebuilt from a new one. ⭐ **A boilerplate claim inherits
the credibility of the careful work around it — check it against every episode
it will appear on, not just the one being made.**

⚠️⚠️ **AN A/B WINDOW MUST LAND WHERE THE THING BEING DEMONSTRATED IS HAPPENING
— the user caught this on L1.** The A/B halves were 6 s, but the arrangement
entered in layers at bars 3, 4 and 5, so the "after" clip ended just as the clap
and bass arrived: the viewer heard the setup and none of the payoff. Fixed by
cutting the excerpt to start at bar 5 and running 10 s a side, verified by
band energy (+14.6 dB below 100 Hz, +18.4 dB above 9 kHz vs the piano alone).
⭐ **A LAYERED ARRANGEMENT AND A SHORT EXCERPT ARE IN DIRECT CONFLICT** — decide
which section the excerpt shows before choosing where the layers enter.

⚠️ **THREE STAGES SHARING ONE CARD READS AS A FROZEN VIDEO.** L4's demo run
put `distinct frames` at 3 of 5 with a 0.00 minimum. Giving each stage its own
card took it to 5 of 5, minimum 3.33. The gate caught it; a human would have
too, and both should.

⚠️ **I MEASURED THE SAME CLICK TRACK WRONG TWICE.** First by timing between
signal PEAKS (a 35 ms click at 1600 Hz has dozens, so the surviving gaps ran
last-peak-to-next-first-peak — 112.87 bpm for a 108 bpm file). Then by
thresholding `|y|` directly, which a sine crosses twice per cycle — 120000 bpm,
1027 "clicks". **An amplitude envelope is a SMOOTHED |y|, never a raw one.**
Correct on the third try: 108.00 and 92.00, spread 0.15 ms, silence → 0 clicks.
⭐ **Both wrong answers looked plausible enough to publish; the generator was
right all three times.**


⚠️⚠️ **A DEMONSTRATION IS NOT A BED — the user reported this on Lesson 4.**
`assemble.py` carried each stage's audio on under the NEXT stage's narration.
That is right for music and wrong for a measurement: the tuning lesson's
beating test tones kept droning while the speaker talked. Stages whose audio is
evidence rather than music now set **`"bedEligible": false`**, and the bed stops
when the demo does. Verified with a control: re-assembling the same manifest
with the flag stripped still beats at **6.03 Hz** under the narration; with it,
0.55 Hz (syllable rate, no tone). The detector's positive control on
`clash.wav` reads 6.00 Hz.

⚠️ **`factCheck` rejected eight PERFECT takes** of "seventy two beats per
minute" because the transcriber writes "72". The number, the delivery and the
take were all correct and the GATE was wrong. A `factCheck` entry may now be a
LIST of acceptable spellings; any one satisfies it. This loosens which FORM
counts, never whether the number must be there — control-tested both ways.

⚠️ **The brand trap fired again, harder.** "DAWB Pro" at an aggregate of 0.98,
and six takes in a row missed it once the product name sat in the final phrase.
Moving the name off the last sentence AND gating it with `brandCheck` fixed it
on take 7. **Both halves were needed.**

⭐ **A/B stages take `beforeShots`/`afterShots`** (card indices). Without them
both halves show the same still and only the badge differs, which reads as a
frozen video.

⭐ **Reuse is where the budget is.** L3 masters L1's own house render; L4 and L8
share one hand-written Beethoven excerpt. Three lessons, one composition pass.

⚠️ `ffmpeg`'s `astats reset=N` counts FRAMES, not samples — `reset=96000` gave
375 blocks, not 2-second ones. Use `asetnsamples=96000,astats=…:reset=1`.

⭐ **Sharp signs fall back to "#"** in SFNS via PIL ("F#", not "F♯"). Readable,
so accepted, but do not put a ♯ anywhere it has to look typeset.
