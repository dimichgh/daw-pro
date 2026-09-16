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
- **Lessons**: 1920x1080, full manifest with TALK/PLAY beats. ⭐ **NO LENGTH CAP
  — the explanation decides.** *"The time is not a hard constraint, the quality
  is what should define how much time we need for learning"* (the user,
  2026-09-05, replacing the old 3–8 min rule). If something must go, cut a
  demonstration, never the introduction. The compressor lesson runs 10:07.
- **House standard for a lesson**: `plugins/narrated-film/skills/narrated-film/SKILL.md`
  §"THE HOUSE STANDARD FOR A LESSON". Worked example:
  `docs/research/design-b3-recut.md`.
- **Theme** is a `brand.py --theme` overlay from
  `claude-plugin/skills/demo-film/brand.json`. It moves the accent colour and
  the sub-label only — never the wordmark — so episodes differ without the
  channel changing.
- Facts come from `docs/research/video-facts-{tuning,history,loudness}.md`.
  **Every number on screen must trace to a line in one of those**, with its
  confidence tag. Anything the research marked UNVERIFIED does not go on screen
  as a fact; it gets measured here instead, or it is cut.

## ⛔⛔ PRIORITY QUEUE — set by the user 2026-09-05

1. **B7 — "How We Built a DAW", a FOUR-PART SERIES**, general audience,
   **~15 min PER PART** (upgraded from one film by the user 2026-09-05: *"if we
   need more to fit into, then let's create series of how we did it, 15 mins each
   part"*). Parts: ① what a DAW is + the one command surface · ② the render
   thread is sacred · ③ everything fails silently ← **the strongest; make this
   one first if only one gets made** · ④ make the test fail on purpose + what is
   still broken.
   **The user moved this AHEAD of the remaining lesson rebuilds.** Design:
   `docs/research/design-b7-what-it-took.md`. ⚠️ Every challenge and discovery in
   it must be a REAL one from the record — a fabricated war story would be the
   worst thing this channel could publish, given the series' whole premise is
   measurement over assertion. Its thesis: **this project's characteristic
   failure is a wrong answer that looks exactly like a right one**, and its
   answer is **make the test fail on purpose.**
2. **B7b — the professional companion**, same subject, tech depth. FILED in the
   same doc, not designed. ⚠️ Do not blend the two: the split exists so each is
   pitched at one audience properly.
3. The remaining lesson rebuilds — 7 (Beethoven's Metronome), 9 (The Amen Break),
   10 (Strings That Breathe). Plan: `docs/research/design-lesson-rebuild.md`.
4. A re-meter pass over the four rebuilds finished before the avatar restyle.

## ⭐⭐ TWO STANDING RULES FROM THE USER — 2026-09-05

Given after watching the compressor lesson's first cut. They apply to **every**
video in this program, not just that one.

### 1. Write for a novice, and keep it clear for them

Assume someone learning sound mixing who has never used the control being
demonstrated. Say what it does, why you would want it, and how the demo will
work — **before** demonstrating it. Do not open as though continuing from
something the viewer missed: cut 1 began "This is a compressor…" and read as the
second half of a video that does not exist.

### 2. Check that the produced sounds can REALLY be heard — and if they cannot, WARN the viewer or show it another way

The user could hear no difference at all in cut 1's release and knee
comparisons, on MacBook Pro laptop speakers. **Both complaints were measured
afterwards and both were correct, and neither was a speaker fault:**

- **Release** — the settings differed by 11.5 dB, but at **−39.9 vs −51.5 dBFS**.
  The information lived in the drum *tail*, because between hits nothing else
  was sounding, 25–35 dB below the film's own level. The one thing the chapter
  existed to demonstrate was the one thing inaudible.
- **Knee** — bounded by the gain computer's own arithmetic, `slope · knee / 8`:
  **2.25 dB** at the demo's settings, **2.85 dB** at the widest ratio the plugin
  allows, against a loudness JND near 1 dB. **No signal and no setting could ever
  have made it audible.**

How to obey this:

- ⭐ **A DIFFERENCE IN dB IS NOT A DIFFERENCE YOU CAN HEAR.** Check the absolute
  level the difference lives at, not just its size. A large gap in a −50 dBFS
  tail is inaudible; a small one at −25 dBFS is not. Measure both.
- **Ask whether the effect is BOUNDED before shooting it.** The knee's ceiling
  was derivable from the source in minutes.
- **Fix the source material before reaching for a warning.** Adding a held pad
  under the drums moved the release demo's information up out of the floor. A
  warning is the fallback, not the first move.
- **When it genuinely cannot be heard, say so plainly and make that the lesson**
  ("a soft knee is called gentle because it is gentle"), and carry the point
  visually. Never soften it into "listen closely"; never imply the viewer's ears
  or speakers are at fault.
- **Say WHEN to listen and WHERE** — a playhead sweeping a measured chart at real
  time against the audio, listen-windows shaded and **derived from where the
  settings actually differ, not chosen by eye**.
- **Headphones get a courtesy card, never a gate.** The visuals must carry it.

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
| L5 | Your bass sounds huge. In mono it is 10 dB quieter. | mastering | measured here | **DONE** 144.0 s, verify 7/7 ok. Built in the DAW, not synthesised: one bassline on two hard-panned tracks, only the clip offset changes. Mono fold, 60–110 Hz: 0 ms −37.42 dB, **6 ms −47.58 dB (−10.16)**, 15 ms −39.72 dB. Control: L reads −36.51 dB in all three. `DAW Pro Lesson 8 - Mono Your Bass.mp4`. ⭐ **REBUILT to the house standard 2026-09-05 and NOT shipped** — `scripts/video/lessons/mono-bass/out/L8v2.mp4`, **672.9 s (11:13)**, verify.py **8/8 ok including A/B separation**, `--finalize` NOT run so the published file is untouched. New material (a saw bass, 47 notes, so the comb has harmonics to bite), so the numbers are its own and are NOT the row above: fold 60–110 Hz **0 ms −31.89 / 6 ms −46.87 (−14.98) / 15 ms −35.33 (−3.44) dB**; nine notes predicted from |cos(pi f tau)| and measured within 0.18 dB; above 200 Hz (what a laptop radiates) the same two renders differ by only **−3.20 dB**, and the film says so out loud. Build + every number: `scripts/video/lessons/mono-bass/NOTES.md`. |
| L6 | The Amen break, programmed by hand | remix | history §Amen | **REBUILT TO THE HOUSE STANDARD 2026-09-06** — `scripts/video/lessons/amen/out/L9v2.mp4`, **811.9 s (13:32)**, 45,682,256 B, 1920×1080, **−16.1 LUFS / −1.1 dBTP**, verify **8/8 ok** (incl. A/B separation + content at 14.1× separation), 20 images looked at, brand transcribed off the DELIVERABLE at 28–42 s and 794–808 s with a music-only negative control returning false. **NOT finalized, NOT published — the shipped 154.6 s film is untouched** and the rebuild's `filename` differs so a stray `--finalize` cannot overwrite it. 53 hand-programmed notes (7 kick / 9 snare accents / 5 ghosts / 31 ride / 1 crash), re-derived independently, nothing sampled; the 1969 recording is in copyright into the 2060s and is never touched. **Every figure RE-MEASURED, and the old humanize numbers do NOT reproduce**: largest **8.60 ms**, mean **4.65 ms** over **106** hits (seed 20260906), against a sixteenth of **110.294 ms** — read off the project and confirmed in the audio to 0.50 ms. Velocity law predicted −13.70 dB, measured −13.72. ⚠ Found by looking after all gates were green: two manim beds shipping at **+3.6 LUFS** (PCM_16/scipy dtype bug, film was 6.7 LU under target with every gate ok), **"DAW Crow" for "DAW Pro" at sim 0.923**, and two narration claims contradicted by the frame they describe. ⚠⚠ **A second review pass then found three more, all of which the green gates had already passed**: a `check()` **rigged with a `+ 1`** that hid a real inconsistency (the film called the ghost demo's **6** ghosts "the number of ghost notes in the pattern" when the four-bar pattern has **5** — both stages re-recorded, both counts now checked separately and positive-controlled); the tempo A/B **cut mid-hit** at a round 10.0 s (**−3.9 dB of peak**), now 7.0588 s = exactly 4 bars at 136 and 5 at 170, ending at −42.3 / −56.4 dB; and **three chart footnotes running under the burned-in corner meter** — the velocity one reached x=1695 of 1920 in the previous build of this rebuild (the PUBLISHED 154.6 s film has no such chart and is untouched) — where `charts.py` had carried a prose comment warning about it and **nothing enforced it**. A gate now measures the drawn text extent and refused `chart-audibility`'s previously-green text on its first run. ⚠ A **third** pass then found the same ghost count wrong a **third** way, inside the manim scene's on-screen label (*"five quiet snare hits per two bars"* — it is three per two bars, six over the excerpt); it is now interpolated from `MEASUREMENTS.json` rather than typed. **Nothing automated could see it**: a label inside a video burst is not in any narration script and no gate reads it — only pulling a frame and looking does. ⚠ `instrument.probeLiveness` reports GM kick(36) and closed-hat(42) at **−120.00 dB** while a real render has them at −10.2 / −12.1 dBFS. Notes: `scripts/video/lessons/amen/NOTES.md`. Shipped: `DAW Pro Lesson 9 - The Amen Break.mp4` |
| L7 | Why your strings sound fake | quicktip | measured here | **DONE** 137.2 s, verify 7/7 ok. Same 32 notes twice; only three lanes change — onsets 0.0 → up to 38.2 ms (mean 16.9), velocity flat 90 → 68–111, and a 129-point CC 11 curve. Envelope variation −13.60 → −10.34 dB, both renders within 0.3 LU. `DAW Pro Lesson 10 - Strings That Breathe.mp4` |
| L8 | Beethoven at 128 BPM — four notes, and nothing else | remix | history §Beethoven | ⚠️⚠️ **THE SHIPPED FILM'S HEADLINE NUMBER DOES NOT REPRODUCE — measured 2026-09-05 during the rebuild, and re-measured INDEPENDENTLY by me with a second Welch implementation agreeing to 0.3 dB.** It claims **18 dB** more sub-100 Hz fundamental for the techno version; on rebuilt material it is **7.3 dB**, and in the **60–100 Hz band the ORCHESTRA is marginally LOUDER (−0.6 dB)**. The whole difference lives **below 60 Hz (+33 dB)**, crossing at 73.2 Hz. ⭐ The better thesis, and the one the rebuild argues: **an orchestra is not bass-less, it has a FLOOR, and the sub sits underneath it.** ⚠️ This says what THIS material does; it cannot show the original was wrong about ITS material. **If the rebuild does not replace the shipped film, the shipped film keeps an unsupported number.** | **DONE** 158.4 s, verify 7/7 ok. His four-note cell as a techno riff; the repetition is stated on screen as mine, not his. Orchestral −47.2 dB below 100 Hz vs techno −29.4 dB = 18 dB of fundamental an 1808 orchestra could not make. `DAW Pro Lesson 11 - Beethoven At 128.mp4` |

## Backlog — the user's video ideas, 2026-09-04

Four ideas, in the user's own framing, with what already exists to build them
from and the one thing that is genuinely unknown about each. **None is planned
or scheduled** — this is the durable record so they are not lost, and so the
next planning pass starts from real constraints rather than re-deriving them.

⚠️ **The user pre-empted the format question themselves:** *"a series of shorts
or longs (if short cannot fit the screen as we need to show DAW)"*. That is the
right call and it is measured — a 9:16 frame has to take a COLUMN out of a wide
app window, so a panel-and-its-labels shot does not survive the crop. Anything
whose subject is a piece of the app's UI is a 1920x1080 LESSON, not a Short.

| # | Idea (user's words) | Shape | Build on | The unknown |
|---|---|---|---|---|
| B1 | "Sampling out of some track (take some known trick)" | one lesson | the shipped `sample-flip` skill + M32's whole flip path (keymap varispeed, region playback, mono choke), all measured working | **which trick, and its rights.** The Amen lesson (L6) set the precedent and the limit: it programmed 53 notes by hand and never touched the 1969 recording, in copyright to the 2060s. A "known trick" almost always means a known RECORD. Either the source is ours or it is re-created, and that choice is the lesson's spine, not a footnote. |
| B2 | "Turning a series of phrases into a song using only slices of phrase, including beats" | one lesson | the `meme-song` skill does exactly this — chop a spoken phrase, pitch the fragments into a melody; `clip.sliceToSampler` + `clip.detectTransients` ship | **whose voice.** Our own recorded phrase is the clean answer and needs the user (~10 min) or a synthetic take. Also: "including beats" means the percussion comes from the same phrase — plosives and sibilants as kick and hat — which is the strongest version of the idea and the part most likely to sound bad. Prototype the audio BEFORE writing a word of narration. |
| B3 | "A series explaining all basic controls/knobs in mix panel and why we need them" | a SERIES of lessons — **PROBE EPISODE SHOT AND SHIPPED 2026-09-04. ⚠️ **A SECOND RE-CUT EXISTS AND IS NOT SHIPPED — verified by me 2026-09-05.** `~/Movies/DAW Pro Lesson - The Compressor, Measured.mp4` is **411.5 s, 20.3 MB, timestamped 01:13** and is the EARLIER cut; the cut that answers the user's two viewing notes is `scripts/video/comp/out/B3.mp4`, **607.6 s (10:07), 33.0 MB, 02:46**, all gates green but `--finalize` NOT run. ⚠️ The spec's `filename` is unchanged, so finalizing WILL overwrite the shipped file. Design: `docs/research/design-b3-recut.md` (this pass) and `docs/research/design-b3-compressor-lesson.md` (the original, still in force where the re-cut does not override it); build: `scripts/video/comp/` (`shoot.mjs` + `spec.py`). SERIES VERDICT: MAKE IT, with four named conditions — see the findings below.** | `ui-capture` + `sweepshot.mjs`'s pattern (photograph a control at each value, cut at the narration's pace) | **scope, and it is large.** "All basic controls" across EQ, compressor, gate, reverb, delay, saturator, limiter is easily 8-12 episodes. The right first move is ONE episode built end to end — the compressor is the obvious candidate, four knobs that are genuinely confusing — and then decide whether the series is worth it from something real rather than from a plan. ⭐ And every claim must be MEASURED off a render, the way L5's 10.16 dB mono fold was; "why we need them" is where mixing folklore gets stated as fact. |
| B4 | "Different instruments and their real hearable range and how it is used in mixing and why" | a SERIES of lessons | `frequency_reference` + `fx.spectrum` ship; the session film's 808 chapter already did this shape once (−38.2 dB through a 150 Hz HPF vs −3.7, and 4.6 dB of saturation advantage) | **"real hearable range" is the whole idea and it is the easiest thing here to get wrong.** An instrument's nominal fundamental range, its spectral extent, and what a given SPEAKER reproduces are three different numbers, and mixing advice usually conflates them. Each episode has to name which one it is quoting and measure it. The heartbeat chapter is the proof this reads well: 94 % below 60 Hz, and a phone plays none of it. |

⭐ **The pattern across all four: they are about the APP and about MEASUREMENT,
which is what this rig is actually good at.** The session film's own lesson
stands — every viewer note on it was about something no gate could see, so
budget for a look at real frames in every one of these, not just for gates.

## Findings from the B3 probe (the compressor lesson)

### Backlog wave 2 — the user's ideas, 2026-09-05

Six more, in the user's framing. Filed, not planned. ⚠️ The wave-1 four (B1–B4)
above are still open; this list does not supersede them.

| # | Idea (user's words) | Shape | The one thing that decides whether it works |
|---|---|---|---|
| B5 | "How AI adds new features, fixes bugs and runs tests in DAW Pro with voice over" | one lesson | **The screen is a terminal, and a terminal is the hardest thing in this rig to film** — 3.5 fps capture of scrolling text is unreadable. This needs the recorder in "Tooling" below, or it needs to be told through the DIFF and the TEST COUNT rather than through the console. ⭐ The honest version has a real failure in it: M35's `RunLoop` fix that ran for 2349 ms and changed nothing is a better story than any success. |
| B6 | "How complex a DAW app is and what it took to build it" | one lesson | **Scale numbers are cheap and boring unless they are ANCHORED.** 7924 tests and 215 wire commands mean nothing alone; "every user-facing capability ships a command, a tool and a test, and here is one being added end to end" means something. Risk: this becomes a brag reel. It must be about the SHAPE of the problem, not the size of it. |
| B7 | "List all features and demonstrate each — except ACE models, they overload the machine" | a SERIES | ⚠️ **The exclusion is a HARD CONSTRAINT the user gave for a measured reason: ACE-Step holds ~80 GB while this video is being produced.** Never boot it for a shoot. Otherwise: `docs/FEATURES.md` is the inventory; the work is choosing which features can be SHOWN in under a minute each. Splits naturally into per-feature episodes (the user's own sub-idea). |
| B8 | "What I can do and what you can do with me and DAW Pro" | one lesson | The division-of-labour film. **The honest line is the interesting one:** the agent can type 1,329 notes in seconds and cannot tell whether they sound good; the user can hear it instantly and would take a day to type it. That is the whole video and it should not be softened into "AI helps you". |
| B9 | "Show what you can do with DAW Pro" — move tabs, add tracks/notes, play, change labels, add/remove instruments, master, save, stems, read MIDI, extend notes, "all visual, play some jokes"; and "can you add 1000 notes and 5 instruments in 4 seconds — I can!" | one lesson, possibly Shorts | ⭐ **KEEP the speed brag** — the 1000-notes boast is a real measurement with a real point (the ONE thing the machine does that a person cannot) and it is funny because it is true. ⚠️ It MUST be timed live, on camera, with the count read back from `project.overview`. ⭐⭐ **AND KEEP THE DANCE — see B9b, which supersedes my earlier "drop the tab-wiggling".** |
| B9b | ⭐⭐ **"I can dance now!" — the user's answer to my objection, and it is better than my objection.** Make dance music, then let the app's own controls do the moves. | one lesson or a Short | **This is the version that works, and the reason is precise: the motion is AUTOMATION, so it carries information.** A fader riding a volume lane, a pan knob sweeping, a filter cutoff opening into the drop, the gain-reduction meter pumping, the playhead travelling — every one of those is a real feature moving because a real automation lane says so. ⭐ **The joke and the feature demo are the SAME ARTEFACT**: the app dances *because* an agent wrote lanes across eight tracks in seconds, which is also the thing being demonstrated. Quantise the automation points to the grid so the controls move ON the beat — that is what reads as dancing rather than drifting. ⚠️ **My earlier objection stands for its actual target and is narrowed, not withdrawn:** a tab dragged back and forth for its own sake is still motion without information. The test is whether the movement is *caused by the music*. ⛔ **THIS IS A RECORDER CASE** — fader motion at ~3.5 fps is a slideshow. |
| B10 | "Musical competitions: one agent enhances another's music, humans vote, in rounds. Opus vs Fable, at different efforts." | a SERIES / a format | ⭐ **The only idea here that is a FORMAT rather than an episode, and the most interesting one.** ⭐⭐ **THE USER SETTLED THE MECHANISM 2026-09-05: *"we have pause to vote on a few variants produced by agent"*** — the round ENDS in a pause, the agent ships A FEW VARIANTS, and the human vote is the verdict. That is [[daw-pro-listening-feedback]]'s standing rule as a video format: 3–4 options differing on ONE axis each, and their pick IS the feedback. It also disposes of the sharpest failure mode — an agent judging music it cannot hear — by never asking it to. The measured axes (loudness, spectral balance, note density) are CONTEXT for the vote, never the verdict. ⚠️ Model-vs-model framing must not become a benchmark claim; it is a demo, n=1 per round. |

⭐⭐ **A NOTE THAT APPLIES TO ALL TEN BACKLOG ITEMS, from the compressor probe:**
the format's ceiling is not the writing, it is that `debug.captureUI` runs at
~3.5 fps. Anything whose subject is MOTION (a terminal scrolling, a drag, a
tab moving, a knob being swept fast) is currently a slideshow. See "Tooling"
in `docs/research/design-b3-compressor-lesson.md` and the session README.

## THE SERIES VERDICT — the question the probe existed to answer

The design's own test is: **can a viewer state the thesis afterwards, not list
seven knobs?** On the built film, yes — and the reason is structural rather
than lucky. The sentence is SPOKEN at t≈8 s and again at t≈322 s, PRINTED on
card 1 (`seven knobs, three jobs`) and card 10, and each of the seven chapter
cards carries its own clause of it as the punch line. The running order enacts
the argument instead of listing knobs: how much → the model's limit → what it
sounds like (twice) → where those two meet → what you do afterwards (twice).

**So: make the series.** But the probe also shows exactly where the shape is
thin, and a knob catalogue is what this becomes if these are not fixed:

- ✅ **Demo 3 (release) WAS the weakest demonstration; it was re-cut on
  2026-09-05 and it now carries its weight.** The retracted 6.45 Hz figure is
  gone and release is PREDICTED like everything else: `CompressorEffect.swift:184`
  makes the release a one-pole with tau = `releaseMs`, so from G dB of reduction
  the time back to within 1 dB of unity is `releaseMs x ln(G)`. Predicted
  **74.55 / 248.49 / 1987.93 ms** at 30 / 100 / 800 ms; measured on the gain curve
  (compressed / dry, SAMPLE BY SAMPLE, not an envelope estimate) **74.57 / 248.49 /
  1987.92**, with the ratio-1 control sitting at 0.0 dB and its recovery time
  correctly UNDEFINED. The material is a gated burst rather than the drum loop —
  a loop cannot show a release because the next hit arrives before the recovery
  finishes, which is now one sentence of narration instead of a missing
  demonstration. ⚠️ Two design notes worth carrying: the burst drops to a QUIET
  TAIL, not to silence, because `compressed/dry` on silence is 0/0 and there
  would be nothing to divide; and the first pass, at 12.2 dB of reduction, had a
  30 ms release that NEVER REACHED −12 dB (deepest −11.934) because a fast
  release starts recovering while the peak detector is still falling. Deepening
  to 13.8 dB fixes it, and the two-crossing timing (−12 dB to −1 dB) is
  independent of depth.
- ⚠️⚠️ **AND THE RE-CUT RETRACTED ITS OWN DEVIATION, WHICH IS NOW THE BEAT.**
  The first pass of the re-cut measured 74.688 ms at 30 ms and put "the
  detector's own 5 ms decay" on the card as the cause. **That was the
  INSTRUMENT, not the compressor.** The gain curve discarded every sample within
  `FLOOR_DB` of a zero crossing; against a −39.67 dBFS tail a −60 dB floor blanks
  ~0.15 ms per half cycle, which finds the −12 crossing EARLY and the −1 crossing
  LATE — both biases pointing long. At a −80 dB floor it reads 74.583, and with
  both crossings interpolated, 74.57 against a 74.55 prediction. The detector's
  decay is real and IS still falling when the release starts; it simply CANCELS
  between two crossings, because after the target reaches 0 the envelope is a
  pure exponential. ⭐ **A deviation with a named cause is only strong if the
  cause was TESTED — the same lesson that retracted 6.45 Hz, one layer deeper,
  and it now sits in the film as its own 40-second beat.**
- ✅ **Chapters 6 and 7 no longer share a clause.** Rather than merging them
  into one ~90 s chapter with three A/Bs, each got its own clause — makeup "puts
  the level back, and that is how every A/B lies", mix "decides how much of the
  compressor you hear". They are genuinely different ideas (one changes the
  LEVEL, the other changes how much of the effect is in the signal at all), and
  the closing card and the closing narration were re-written to match, so the
  spine is now seven clauses for seven chapters.
- ✅ **Demo 6's loudness half is now audible.** The A/B is no longer
  loudness-levelled: one shared static gain (+12.581 dB) is applied to both
  halves with `normalize: false`, so the 19.3 LU collapse PLAYS instead of
  sitting on a card, and the narration says the halves are not levelled. The
  11.65 dB transient claim rides the same un-levelled pair.
- ⭐ **Chapter 2 (the prediction that missed) is the best thing in the episode
  and is NOT part of the thesis.** It is a 28 s methodology digression between
  "how much" and "what it sounds like". It earns its place and it costs the
  spine. ⭐⭐ **THE PROJECT OWNER RULED ON THE TRADE 2026-09-05 AND KEPT IT:**
  "a lesson about measurement that hides its own limit is worse than one that
  digresses for 28 seconds." Do not re-open it; carry the beat into the series.

The strongest demonstration is the knee (chapter 5): a tone two decibels UNDER
the threshold, 0.0 dB with a hard knee and 1.5202 dB with a soft one against a
1.5625 dB prediction. It is the demo nobody does, it needs no adjectives, and
it is the model for what the other episodes should aim at.

### Deviations from `docs/research/design-b3-compressor-lesson.md`

- **Length: 411.5 s (6.9 min) against a stated 3-5 min** — 338.6 s at the first
  ship; the re-cut's PREDICTED release demo and its retraction beat cost 73 s. Narration was cut
  from 1,202 words to 937 and every A/B half from 5.5 s to 3.0-3.5 s; going
  further would have meant dropping a demonstration or the prediction beat.
- **Demo 3 is not narrated "as a rate in Hz".** The design asked for the
  modulation rate; measurement retracted it. ✅ RESOLVED IN THE RE-CUT: it is
  narrated as a PREDICTED RECOVERY TIME instead — `releaseMs x ln(G)`, checked
  against a per-sample gain curve, with a ratio-1 control whose answer is
  "undefined". The rate in Hz was never a property of the compressor; the
  recovery time is.
- **The gain-reduction meter is never shown live.** The design required that if
  the episode shows it, it must explain that the meter reads the DETECTOR,
  unscaled by `mix` and excluding makeup. The shipped film only ever shows the
  meter at rest (0.0 dB) in panel stills, so no such caveat was needed and none
  is spoken.
- **Threshold values on screen are DERIVED, not the design's prose figures.**
  Thresholds come from the measured dry peak (−15.233022 dBFS), so the panel
  reads −27.2 dB where the design's prose says −18. The narration therefore
  says "twelve decibels above the threshold" and never quotes a number the app
  does not show.

⭐⭐ **THE PIPELINE COULD NOT CARRY THE EPISODE'S MOST IMPORTANT BEAT, and no
gate would have said so.** `assemble.py`'s play segments ran a SINGLE-PASS
`loudnorm`, which is dynamic. Demo 5's whole point is "the compressed take is
louder, and louder wins every blind A/B" — MEASURED, a pair that really
differed by 2.1 LU (−26.7 vs −24.6) came out of that filter at −17.3 vs −18.8:
**not flattened, INVERTED**, so the quieter take would have played back louder
and the lesson would have taught the opposite of its own measurement. Fixed
with an opt-in `"normalize": false` per stage (default unchanged) plus ONE
static pre-gain shared across the pair, chosen from the peaks so nothing
clips. ⚠️ Concatenating the pair into one file does NOT work — that was tried
first and is where the inversion was measured.

⚠️⚠️ **A/V DRIFT: THREE WRONG DIAGNOSES BEFORE THE RIGHT ONE, and two of them
were "fixes" that made it worse.** The gate failed at 521 ms, then 875 ms.
(1) Trimming the stills track to an exact `total` — wrong, the truncation
happens later. (2) Having `talk_audio` return the written file's duration
instead of the vo's — wrong, they are equal; loudnorm does not change length
here. (3) The real cause, found only by probing the concat in isolation:
`meter.py` RE-ENCODES the video at a constant `-r fps`, and its input is a
concat whose last frames are HELD, so the container's 338.520 s of video
(10129 packets = 337.63 s of frames) collapsed to 337.667 s while the audio
stayed at 338.541 s. `meter.py` now pads with a cloned last frame and cuts the
result to the AUDIO's duration: **8.0 ms**. ⭐ The earlier `shortest=1` guard in
that same file fixed the OPPOSITE case and could not see this one — a guard
against a known failure is not a guard against its mirror image.

⭐ **THE BURSTS PHOTOGRAPHED THE MIXER.** `debug.effectEditor` selects the MIX
tab and nothing in `burst()` selects it back, so 21 frames of "the app playing"
were three channel strips: no arrangement, no playhead, no notes. Every gate
passed them. `ui.showMixer {show: false}` before the burst is the fix, and it
must come BEFORE `burst()`'s own panel work. **Found by looking at one frame.**

⭐ **THE BEFORE/AFTER BADGE SAT ON THE VALUE THE A/B EXISTED TO SHOW.**
`assemble.py` burns it at `H*0.82` — a band documented as empty in the mixer,
the arrange view and the session film's panel crops. It is not empty in a
compressor-panel crop: it landed exactly on the MIX readout in demo 6. Fixed
with a taller crop box for A/B halves only (`PANELAB` in `scripts/video/comp/spec.py`),
leaving the badge band below the panel. Again: only extracting the frame and
looking at it found this.

⭐ **A SHORT LINE'S WORDS-PER-MINUTE IS NOT A LIE DETECTOR.** The substantive
stages sit at 211-248 wpm, inside the band this program measured before. The
three outliers (155-176 wpm) are all 9-18-word chapter prologs, where one
second of trailing silence swings the figure by 50 wpm; silence-trimmed they
are 172-216 wpm, and all three transcribed verbatim (sim 1.00). **Apply the wpm
check to lines long enough for it to mean something.**

⭐ **The two dry-material figures the whole episode hangs off (`−15.233022` and
`−10.590619` dBFS) were re-measured off the rendered files before the spec was
written, and every LUFS/peak in `MEASUREMENTS.json` reproduced exactly.** The
panel therefore shows `−27.2 dB` where the design's prose says "threshold −18":
the threshold is DERIVED from the measured peak, so the narration says "twelve
decibels above the threshold" and never quotes a number the app does not show.

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
