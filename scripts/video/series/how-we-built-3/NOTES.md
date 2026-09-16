# How We Built a DAW — Part 3

**"Everything fails silently"**
1920×1080 · built 2026-09-05 · `out/HWB3.mp4`
Brief: `docs/research/design-b7-what-it-took.md` (§3 of the four-part series).

⛔ **`--finalize` was NOT run.** Nothing was copied to `~/Movies`, no publish
sidecar was written, nothing was uploaded. Nothing was committed and nothing
was staged.

---

## What this part covers, and what it deliberately does not

| covered | left to another part |
|---|---|
| the four documented silent failures, all re-derived in this build | the six modules, the one command surface (**Part 1**) |
| the **positive control** as the defence | the render thread, the deadline, the counter (**Part 2**) |
| the counting trap: two true numbers, one answer | falsification — planting a fault and watching a test redden (**Part 4**) |
| **an A/B whose two halves are the same file, played to the viewer** | anything for a professional audience (**B7b**) |
| the 6.45 Hz pumping rate that was the drum pattern | |

The line between this part and Part 4 is drawn explicitly and held: **Part 3
owns "prove the instrument can find a thing that is there"; Part 4 owns "break
the thing and check the test goes red."** The close names the second and hands
it over.

Part 1's "more test than program" hook and its 223-vs-220 anecdote are not
reused. Part 2's counter, deadline and audit are not reused. The words
"thread", "block" and "deadline" do not appear.

## Chapters

**Computed from the actual `out/segments/*-mux.mp4` durations, not from
`out/timeline.json`** — Part 2 found that file had gone stale across rebuilds.
The sum of the segment durations is **763.287 s** against the file's measured
**763.333 s** (46 ms of container rounding).

| at | stage | beat |
|---|---|---|
| 0:04 | `00-open` | what a DAW is · who is talking · a crash tells you, a wrong answer does not |
| 1:04 | `01-project` | the project on screen — four tracks, 318 notes, 100 BPM |
| 1:38 | *(play)* | twelve seconds of it working, filmed while the transport ran |
| 1:50 | `02-invisible` | **case 1** — the search that never ran, reproduced live on this machine |
| 2:47 | *(play)* | the manim scene: two failures, one empty screen, then the control |
| 3:06 | `03-control` | the positive control · the "coffee" beat, subverted (1 of 2) |
| 4:00 | `04-quiet` | **case 2** — a compressor demo that was correct and inaudible |
| 4:54 | `05-listen` | where the difference actually lived, on a measured chart |
| 5:47 | *(play)* | ten seconds **at the level it shipped at** |
| 5:57 | `06-lift` | a difference in dB is not a difference you can hear |
| 6:45 | *(play)* | the same two files, **plus 14 dB**, one shared gain |
| 6:55 | `07-meter` | **case 3** — five bars on this film's own corner meter that could never move |
| 7:58 | `08-before` | the counting trap · and then: "listen to this one" |
| 8:45 | *(play)* | the BEFORE |
| 8:51 | `09-after` | "and now the after" |
| 8:58 | *(play)* | the AFTER |
| 9:04 | `10-reveal` | **case 4** — they were the same file · and the frame check that passed a still image |
| 10:12 | `11-shape` | what all four have in common |
| 11:04 | `12-pump` | the pumping rate that was the drums (the "coffee" beat, 2 of 2) |
| 11:52 | `13-close` | the defence in four rules · what Part 4 is |

## The centre of the film: an A/B that is deliberately one file

⭐⭐ **`08-before` and `09-after` play byte-identical audio, on purpose, and the
next chapter says so.** This is the only way to give a viewer the experience the
defect produced. It is built as **two ordinary play stages sharing one loop
path**, NOT as an `ab` block, because `verify.py`'s `check_ab_separation` now
fails an `ab` whose halves are the same audio — correctly, and that gate is
exactly what the chapter is about. `audioprep.py` carries the reasoning in a
comment so a later rebuild does not "fix" it.

Verified in the FINISHED mp4, after AAC, by `filmaudio.py`:

```
08-before vs 09-after : level +0.00 dB, correlation +0.9996
CONTROL 08 vs 05-listen: correlation +0.0068
```

(The first build of this film read **+1.0000** here with a control of +0.0063;
after the level rebuild described in "Things found by looking" #10 the same
samples come back at +0.9996. One extra AAC generation, not a change in the
demonstration.)

⚠ **The first control I chose was wrong and read +0.9707.** I used
`01-project`'s play segment — but `same-before.wav` IS the first six seconds of
`mix-clean.wav`, which is what `01-project` plays, so the "control" was the same
music. A control drawn from the same source is not a control. The drum pair is.

Both halves are under **real, synced footage**: a 180-frame burst cut from the
app recording, covering exactly the six seconds of the project those wavs
contain. Both frames read `POSITION 2.1 / TIME 0:02.969` at the same offset —
identical, which is the demonstration.

## Every number stated on screen, and the command that re-derived it

All of these are in `MEASUREMENTS.json` with the command stored beside them
under `_commands`. `spec.py`'s `check()`/`band()` refuse to emit a spec whose
spoken figure disagrees with the measured one.

| number | how it was derived |
|---|---|
| exit **127**, **0 bytes** printed; the working command finds **3** files; the thrown-away error `bash: timeout: command not found` | run live in `measure.py` on this machine against `masterChainHost` in `Sources/` |
| **5** dead meter bands at **36.2 / 41.0 / 52.6 / 67.5 / 98.2 Hz**; **11** bands merely narrower than a bin; **11** would be dead at 72 bands; **0** after the fix | computed from `scripts/video/meter.py`'s own constants (`F_LO/F_HI`, `N_BARS`) and its own window (`win = 2·sr/fps` → 15 Hz bins) |
| the pair: mean gap **6.96 dB**, widest **12.78 dB**, at **−40.74 / −47.70 dBFS**, **24.7 dB** under the film, **73.1 %** digital silence, **1.84 s** of difference | `wav.py` + `measure.py` on `scripts/video/comp/audio/d3-release-{fast,slow}.wav` — the files that actually shipped |
| the record's own **11.5 dB at −39.9 / −51.5 dBFS** | `grep` on `docs/research/design-b3-recut.md:27` |
| **6.45 Hz** three times, retracted; **74.55 / 248.49 / 1987.93** predicted vs **74.57 / 248.49 / 1987.92** measured | `grep` on `CHANGELOG.md:14-21,53` |
| the same-file A/B passing at **+0.00 LU**; `check_ab_separation` exists; still-film pixel floor **0.11** vs real **5.04** | `grep` on the skill file, `verify.py` and `CHANGELOG.md:696` |
| **148** gate scripts, **105** commits | `ls scripts/gates/*.mjs \| wc -l`, `rtk proxy git log --oneline \| wc -l` |
| **4** tracks, **318** notes, **100** BPM | `project.overview` on staging (17695), written into `ids.json` |

### ⚠ My re-measurement and the record disagree, and the film says both

The record says the two release settings differed by **11.5 dB at −39.9 vs
−51.5 dBFS**. My own re-measurement of the same two files, over 20 ms windows,
in the windows where they differ by more than 3 dB, reads a **mean of 6.96 dB**
and a **maximum of 12.78 dB**, at **−40.7 vs −47.7**. Both are true of the same
audio; they are different windows over a signal whose gap varies from hit to
hit. The narration speaks **my** numbers ("about seven decibels, nearly thirteen
at its widest") and the description carries **both**. The absolute level — the
thing that actually mattered — agrees to within a decibel either way.

## Build chain

```
material.mjs   → reads the demo project off staging, pins ids, renders mix-full.wav
soft.mjs       → the same render with Drums and Lead excluded (a bed, not a groove)
shoot.mjs      → app stills; adds a compressor, shoots it at 30 ms and 800 ms, REMOVES it
reshoot.mjs    → re-took app-arrange after the effect editor left the app on MIX
reroll.mjs     → re-aimed the piano roll at the Lead (centre pitch 68)
drive.mjs      → films the app with screenrec while the transport runs → media/play-arrange.mp4
measure.py     → MEASUREMENTS.json, every figure with its command, every grep with a control
audioprep.py   → mix-clean · the pair verbatim · the pair +14 dB · the identical A/B
charts.py      → chart-pair.png, chart-bands.png (both MEASURED, not drawn)
anim_silent.py → the manim scene (Silent)
sweep.py       → two playhead bursts over the level chart, at both levels
bursts.py      → app footage + manim → burst dirs (TRIM measured, not assumed)
beds.py        → one bed per burst, EXACTLY its length
spec.py        → HWB3.json, refusing to build on a numeric disagreement
shortsmith.py HWB3.json --out-dir out --size 1920x1080
retake.py      → the TAIL check the pipeline does not have (see below)
locate.py      → where a phrase is actually spoken, by transcribing 8 s windows
slots.py       → what is on screen when, using assemble.py's OWN still-timer formula
frames.py      → pulls the finished film's frame at each spoken figure → frames/sheet.png
filmaudio.py   → measures the play segments out of the finished mp4, with controls
wordcheck.py   → transcribes every stage and reads every content word
restore.mjs    → puts staging back and RE-READS to prove it
```

Re-run order after any source change: `measure.py` → `audioprep.py` →
`charts.py` → `sweep.py` → `bursts.py` → `beds.py` → `spec.py` → `shortsmith.py`.

⚠ **`measure.py` owns `pairLiftDb` and `audioprep.py` reads it back out of
`MEASUREMENTS.json`.** They were 30 and 14 in one build; `spec.py`'s `check()`
is what caught it. One number, one home.

## Staging hygiene

- Everything ran against **17695**. **Port 17600 (the user's live app) was not
  listening at any point during this build** and was never addressed —
  re-checked at the end with `lsof` and a positive control proving `lsof` works.
  `build.mjs` refuses 17600 outright.
- The session already open on staging was **saved first** to the session
  scratchpad as `hwb3-staging-preexisting-2026-09-05.dawproj`.
- The project was **read, not built** — it is the four-track demo this series
  already has on staging (Pad 48 / Bass 80 / Drums 174 / Lead 16, tempo 100).
- **A compressor was added to Drums and removed again**, and the removal was
  proved by re-reading `project.overview` rather than by `fx.remove` returning.
- **Master volume was set to 0 while filming** and put back — the film's audio
  is rendered offline and nobody asked for the mix out of their speakers.
- The window was **not** resized: 1600×900 throughout, `debug.windowFrame` only
  ever read.
- `--app DAWApp` only. Frame 1 and frame 12 s of the recording were looked at by
  hand: right window, transport running, `MCP 17695`, tempo 100.
- The speech server ran on **port 8802**, derived per the port rule
  (`8000 + ($$ % 900) + 1`), started by `run.sh`, which **refuses to start if
  anything is already on that port**. Killed pid-exact at the end
  (`pid I started = 93504 = pid on port`), then the port was re-read and came
  back **free**, and `ps -p` came back **gone**.

## Things found by looking — every one invisible to the build's own return code

The first assembly reported `[ ok ]` on all seven verify checks.

### 1. ⭐⭐ Two narration takes said every word and then kept talking

`08-before` scored **0.83** and `10-reveal` **0.87** against a floor of 0.80.
Both said their entire script correctly, and then babbled for another
**119 and 115 words**:

```
08-before: "...Listen to this one."  →  "that was at the corner. For yeah. And
           it's the one, so it might be three and then over to size..."
10-reveal: "...a real one about 5."  →  "Action pandemics is the signatures
           between 33 degrees and 45..."
```

Every gate passed them: level, pace, brand, `factCheck`, and similarity — because
a tail of junk on an 1,100-character script cannot move an aggregate below 0.80.
**Nothing in the pipeline looks at what comes after the last scripted word.**

`retake.py` adds that check: it anchors on the script's last four content words,
takes everything the transcript says after them, and re-records until a take has
none. Both re-recorded first take, at **1.00** and **0.99**, with no tail. The
same check was then run over all fourteen stages from their stored transcripts:
**only those two were affected** (every other stage reports a systematic
1-word anchor overhang).

⭐ This is the film's own thesis, inside the film's own production. It is not in
the narration — it happened after the script was written — but it belongs here.

### 2. A shot named `app-arrange` that was a picture of the mixer

`debug.effectEditor` switches the workspace to MIX and nothing switches it back.
`shoot.mjs` called `ui.showMixer {show:false}` once, at the top, then opened the
effect editor, then took its final capture. The result was a valid PNG, a valid
capture, correctly named, and the wrong screen. `md5 | uniq -d` could not see it
— every shot was distinct. **I looked at it.**

### 3. Six shot lists were mistimed against the words

The still timer is `n = round(total/cut); each = total/n`, with `holdLast`
CLAMPING the list — not "spread evenly". Rather than guess, `locate.py`
transcribed 8-second windows of each stage's own wav until the phrase appeared,
and `slots.py` computed the slot boundaries with `assemble.py`'s own formula.
What was wrong:

| stage | the words | what was on screen |
|---|---|---|
| `02-invisible` | "the number one hundred and twenty-seven" (44–46 s) | the FOUR CASES card, not the card that shows `exit 127` |
| `04-quiet` | "**thirty milliseconds** is the fast setting" (28–30 s) | the compressor panel at **RELEASE 800 ms** |
| `06-lift` | the whole 47 s | one chart, held |
| `07-meter` | "36, 41, 53, 68 and 98 hertz" (44–48 s) | the counting card, not the card that lists those frequencies |
| `10-reveal` | "its sibling is even better" (39–41 s) | a card about a later chapter |
| `13-close` | the four rules (8–25 s) | ran 4 s past the card that lists them |

`04-quiet` needed its `cut` dropped to 3.4 s so a slot boundary could fall
between "thirty milliseconds is the fast setting" and "eight hundred
milliseconds is the slow one" — at 6.4 s one slot covered both sentences and no
single picture could be right. After the fix, **eleven frames were pulled from
the finished film at the exact instant each figure is spoken and inspected as a
contact sheet (`frames/sheet.png`). All eleven show the card carrying that
figure**, including a crop of both compressor panels confirming `30 ms` and
`800 ms` under their own words.

### 4. ⭐ The chart under the lifted audio still showed the un-lifted levels

`sweep.py` drew both playhead charts from the original files, so the second pass
— titled "THE SAME TWO FILES, PLUS 14 dB" — displayed traces at −41 dBFS while
the viewer heard them at −27. A picture disagreeing with its own soundtrack, and
nothing measures that. Both sweeps now carry a per-pass gain and the film's own
−16 LUFS line, so the lifted traces visibly rise toward it. Confirmed by pulling
both frames and putting them side by side.

### 5. Four silent zeroes in the measurement script itself

`measure.py`'s first run recorded **four** `grep` results as `0` — the record's
dead-band claim, the skill file's same-file A/B, the pixel floor, and the
retraction's lesson. Every one of them looked like "the record does not say
that". Three were patterns that **spanned a line break in a hard-wrapped
markdown file**; one forgot the backticks around `` `+0.00 LU` ``. In a film
about exactly this failure.

`grep1()` now runs a **negative control on every call** (the same pattern with
`ZZQQ` appended) and **refuses to record a zero** it cannot distinguish from a
broken pattern. All eight greps now return 1 with their controls returning 0.

### 6. `git log --oneline | wc -l` returns 50 on this machine; the truth is 105

The `rtk` shell hook rewrites `git` and truncates the output. Both numbers look
like measurements. `measure.py` runs its git command through `rtk proxy` and
says why in a comment. **This is not in the narration** — it is a fact about my
own tooling, not about the project's record, and the film's honesty rule is that
every claim comes from `docs/`, `CHANGELOG.md` or the code.

### 7. Two leaked control-socket clients on staging

Found **by port**, not by name: `lsof -nP -iTCP:17695` showed 2 ESTABLISHED
client sockets after the build — one from `material.mjs`, and one older
`node -e` probe that had been idle for 2h16m. Both were killed pid-exact; the
re-read then showed **0** clients with the staging listener still up as a
positive control. ⚠ The older one was not started by any script in this
directory; it was an idle wedged client on staging, and I killed it. Recorded
here rather than left unsaid.

### 8. Cosmetic, not fixed

The manim scene's caption *"The top one did say something. It was sent
nowhere."* runs right up to the corner meter's left edge at ~10 s into that
burst. It is readable and does not overlap the text, but it is the tightest
thing in the film. `_place_cap()` keeps captions left of x = 4.4 manim units and
this one is at the limit.

### 9. ⭐⭐ A card said "misspelled"; the narration said "not installed"

Found on a read-through after the film had already passed all eight checks. The
manim scene in chapter two captioned the failing command *"but the command is
misspelled and never runs"*. The narration over it says *"this machine does not
have that first command installed"*. Two different explanations of the same
box, on screen together for about ten seconds, **in the chapter about words on
screen being wrong**. No gate can see this: `sim()` compares the narration to
the *voice*, never to the *picture*. Caption now reads *"not installed on this
machine, so it never runs"*, the scene was re-rendered (18.950 s, unchanged to
the frame, so `beds.py`'s bed-length assertion still held), and the frame was
pulled and looked at.

### 10. ⭐⭐⭐ The first "here it is working" moment was the quietest thing in the film — and the obvious fix turned the whole film down

`out/segments/01-project-play.wav` measured **−26.1 LUFS** in a film that sits
at **−16.4**. Nearly 10 LU under the voice, on the shot that is supposed to say
*this thing works*. Nothing failed: `normalize: false` was set deliberately, and
the pipeline honoured it exactly.

The obvious fix — drop `normalize: false` and let `loudnorm` level it — worked
on its own terms and **cost the film 0.81 dB everywhere else**. Measured, not
guessed: I built the film both ways, kept both long enough to compare, decoded both to mono and
compared them in 5-second windows. 151 of 152 windows differed. Three windows
were **+8.5 to +10.6 dB** (the three play segments, now at −15.8/−16.0/−16.0
LUFS). **Every other window in the film was −0.81 dB**, to within 0.02.

That flat pedestal is `assemble.py`'s true-peak backstop. `loudnorm` reached
−16 LUFS on 18 dB-crest material by compressing it, the resulting peaks pushed
the concat over the −1.0 dBTP ceiling, and the backstop correctly turned **the
whole 12 minutes** down to fix **30 seconds** of it: −16.4/−1.5 became
−17.1/−1.0. Note the direction — *adding louder content made the measured film
quieter*, which is exactly the kind of reading that should stop you. My own
arithmetic said the integrated loudness should have gone **up** about 0.2 LU;
the disagreement between the arithmetic and the meter is what led to the
window-by-window comparison, and the comparison is what showed the pedestal.

The shipped fix is neither: `MIX_TRIM_DB` in `audioprep.py` goes from **−4.0 to
0.0**, a static 4 dB with no dynamics anywhere. Play now sits at **−22.1 LUFS**
(5.7 LU under the voice) with a peak of −3.38 dBFS, the backstop does not fire,
and the film is back to **−16.4 / −1.5**. The identical pair `08`/`09` shares
that one gain, so it stays identical: read back out of the finished mp4 at
**level +0.00 dB, correlation +0.9996**, against a control of **+0.0068**. Both
still land at **−25.1 LUFS** — the first six seconds of the passage are quieter
than the rest of it, and I am reporting that rather than chasing it, because
lifting those two any further is what put the peaks near the ceiling in the
first place.

⚠ I built the film both ways and kept the normalised master only long enough
to do the comparison, then removed it; `out/HWB3.mp4` is the shipped one. The
attribution of the 0.81 dB pedestal to the true-peak backstop is **inference
from mechanism, not a captured print** — I tailed shortsmith's summary and never
saw the backstop's own `true peak … -> total trim` line, and nothing else in the
chain applies a static gain to the whole concat. The window-by-window comparison
is the measurement; the backstop is the model that explains it.

⚠ The A/B halves' correlation moved from **+1.0000** to **+0.9996** with this
rebuild. Same samples in, one more pass of AAC quantisation out. It is not a
regression in the demonstration; it is the codec, and it is worth saying out
loud that a check reading exactly 1.0000 twice was reading a rounding, not a law.

## Every spoken word, transcribed back and read

`sim()` strips numbers by design, so figures are gated only by `factCheck`. All
fourteen stage wavs were therefore transcribed in full and **every content word
of six letters or more** checked against the script (`wordcheck.py`, with a
negative control: no transcript contains "banana").

Residual "missing" words, all benign and all read in context:

- Whisper writing number-words as digits: `318`, `100`, `12`, `127`, `11.5`,
  `30 milliseconds`, `800`, `13`, `25`, `41`, `14 decibels`, `15 hertz`, `36`,
  `98`, `11`, `5`, `148`
- British → American spelling: `defence`→`defense`, `favourite`→`favorite`
- `fiftieth`→`50th`, `chapter's`→`chapters`

**No dropped content words and no meaning inversions.** (Part 2's `10-audit`
lost the word "violations" while scoring 1.00, and its `11-load` said "lowest"
for "slowest"; both would have been caught by this pass, and both classes were
looked for here.)

## Audibility, checked rather than assumed

⚠ **The quiet pass is genuinely almost inaudible, and that is the point — the
narration says so before it plays, not after.** Measured out of the finished
mp4: `05-listen`'s play segment reads **−43.46 dBFS RMS / −20.41 peak**, against
a film at −16.4 LUFS. The lifted pass reads **−29.45 / −6.46**, i.e. exactly
**+14.01 dB**, which is the one shared static gain and nothing else.

The difference is carried **visually** in both passes by a measured chart with a
real-time playhead and derived listen-windows, per the house standard, so a
viewer on laptop speakers who hears nothing in the first pass has still seen
where the information was. The narration never says "listen closely" and never
implies the viewer's speakers are at fault; it says the level is 25 dB under the
voice they are hearing, and that the real fix was to change the material rather
than the volume — which is what the record says happened.

⚠ **The four `audio present` sample points (10/35/60/85 % = 76.3 / 267.2 /
458.0 / 648.8 s) do not land inside the quiet pass** (347.8–357.9 s), so that
check is not evidence about it. `filmaudio.py` measures it directly instead.

⭐ **The music that is *meant* to be heard was checked too, and it was too
quiet.** Every play segment's integrated loudness, measured against a film at
−16.4 LUFS: `01-project` **−22.1**, `08-before` **−25.1**, `09-after` **−25.1**,
`06-lift` **−28.3**, `05-listen` **−42.3** (the last two are the lesson and are
supposed to sit there). The first three were 4 dB lower than this before I
looked — see "Things found by looking" #10 for the measurement and for why the
obvious fix was rejected.

## Final assembly

- `out/HWB3.mp4` — **763.333 s (12:43)**, 1920×1080, h264 yuv420p 30 fps,
  aac 48 kHz stereo, **43,655,284 bytes (41.6 MB)**. `out/HWB3-nometer.mp4` is
  the kept pre-meter master.
- `verify.py`, run standalone with `--joins`, against a speech server on a port
  this build derived and started itself: **ALL 8 CHECKS PASSED**,
  `verifyFails: []`, `verifyBroken: []`.
  - streams `v=h264,1920,1080,yuv420p,30/1  a=aac,48000,2  763.3s`
  - frame size 1920×1080 landscape
  - a/v drift **8.3 ms** (under one frame)
  - distinct frames **5 of 5** (max 39.20, min 3.01, noise floor 2.0); **control:
    frame vs itself = 0.00**
  - audio present at all 4 sample points
  - loudness **−16.4 LUFS / −1.5 dBTP** (LRA 2.4 LU)
  - joins: **worst seam 0.2197 at t = 347.767 s**, against an ordinary-frame
    reference of 0.2708 and a **peak-to-inverted-peak control of 1.2478**. All
    20 stage boundaries were passed in, computed from `chapters.json`, which is
    itself computed from the muxed segment durations rather than read from a
    sidecar.
  - content: best-matching stage **0.35** vs worst-matching **control 0.03** —
    **13.6× separation** over 6 blind windows
- ⚠ **`check_ab_separation` is still absent, not passed.** It reads a
  `.timeline.json` sidecar for `ab` blocks and this film has none, on purpose
  (see the centrepiece section). `filmaudio.py` covers the same ground directly
  and with its own control. The join check, which was absent in the first
  writing of these notes, has now been **run**.
- **`shortsmith.py` refused to ship once before this, and it was right to:**
  four `factCheck` strings were not in the narration (`07-meter` 'eleven' and
  'seventy-two', `08-before` 'zero', `12-pump` 'seventy-four'). The `[BROKEN]`
  path was never hit — the speech server was confirmed listening by `lsof`
  before every run, not by a `curl` that could have been answered by anything.
- The true-peak backstop **did not fire**: the concat landed at −1.5 dBTP by
  itself, so the shipped audio is one AAC generation. See "Things found by
  looking" #10 for what happened when it *did* fire.
- The `⚠ 763.3s is OVER the 60 s Shorts limit` line is shortsmith's Shorts
  advisory and does not apply to a long-form film.
- Narration gate, per stage: **12 of 14 first-take at 0.99–1.00**; `08-before`
  and `10-reveal` were re-recorded (see "Things found by looking" #1) and landed
  at **1.00** and **0.99**. Brand OK on `00-open`; facts OK on all eleven stages
  carrying a `factCheck` whitelist.
- ⚠ **`out/build-report.json`'s `narration` list is empty and is NOT the record
  of that gate.** The film was rebuilt three times with `--skip-narrate` after
  the voice was cached, and each rebuild overwrote the report with a build that
  did no narration. The per-take numbers above come from `build.log` (the first,
  full build) and from `retake.py`'s own output, which is why they are written
  out here in prose rather than pointed at. A file that exists is not a file
  that passed a gate — and a *field* that exists is not a field that was
  measured on the artefact beside it.

## Staging restored — re-read, field for field

`restore.mjs` ran against **17695 only** and its re-read is the proof, not its
return:

- `project.overview` — 4 tracks **Pad (48), Bass (80), Drums (174), Lead (16)**,
  **0 effects, 0 sends, 0 automation lanes** on every track, tempo **100**,
  playhead **0**, `isPlaying false`, master volume **1**, loop **disabled**
  0–16, **0 markers**. Identical to the reading taken before anything was built.
- `debug.panelLayout` — every field matches the baseline: `pianoRollPPB 32`,
  `pianoRollRowHeight 14`, `rowHeight 50`, `editorFraction 0.45`,
  `editorMaximized false`, `followPlayhead false`, `pianoRollMinimap true`,
  `sidebarWidth 260`, `mixerInsertsCollapsed false`, `waveformNormalize true`,
  `waveformVerticalZoom 1`, `auditionEnabled true`.
- `debug.windowFrame` — **1600×900**, never resized.
- `debug.captureUI` — Arrange view, no mixer, no modal, transport at 0.
  **I looked at the screenshot.**
- `lsof -nP -iTCP:17695` — **0** ESTABLISHED client sockets, with the staging
  listener still up as a positive control.

⚠ **One honest drift, the same one Parts 1 and 2 recorded.** The session is now
backed by the copy saved before this build started
(`<scratchpad>/hwb3-staging-preexisting-2026-09-05.dawproj`). Musical content,
tempo, track set, note counts, effect chains and layout are identical; only the
document's backing path changed. The title before this build was Part 2's own
saved file.

### 11. ⭐ `filmaudio.py` printed the name of the control it had rejected

The centrepiece proof prints a negative control. Line 56 computes it from
`res["05-listen"]` — the unrelated drum pair. Line 59 printed it labelled
`CONTROL 08 vs 01-play`, which is the control I had explicitly **rejected**
three lines above in a comment explaining why it was invalid. The number was
right, the probe was right, and the label named the wrong file; those notes then
quoted the label. Found on a read-through of my own output after eight checks
had passed. Label fixed and the script re-run; the value is unchanged at
**+0.0068** because the computation never changed.

## Deliberate honesty edges — things a viewer could reasonably ask about

- **Chapter two is told in the first person, and it is a documented incident,
  not a thing that happened to me during this build.** The narration says *"I
  asked that question… and I concluded that this thing had no mentions
  anywhere. It had three."* The incident is the project's own, written down in
  `CLAUDE.md` §"This machine" as a search that reported no writers for a file
  with three. What I did *during this build* is reproduce the mechanism live —
  same shape, same shell, same thrown-away error — and the symbol on screen was
  chosen because it has three homes, like the original. The exit code 127, the
  0 bytes, and the string `bash: timeout: command not found` are all from that
  live reproduction. The series is narrated as one continuous first person by
  design; this is the one place where that voice is speaking about the record
  rather than about the last hour, and it is worth having said so.
- **The two "eureka" beats are subverted on purpose.** Chapter three opens by
  refusing the coffee-shop story outright; chapter twelve tells one plainly,
  and it is a retraction. The brief asked for the honest form of that beat and
  the source document gives it.

## Things I could not source, and therefore cut

- **A live reproduction of the meter's dead bars.** `scripts/video/meter.py` is
  untracked, so there is no old version in git to run. The five dead bands are
  **recomputed from the current file's own constants and window size** at the
  old density of 48 — which reproduces the record's finding exactly (5 dead, at
  the same five frequencies) — rather than replayed. The film says the count and
  the frequencies, not "I ran the old code".
- **The record's exact −39.9 / −51.5 figures as my own.** I could not reproduce
  the window they came from, so the narration speaks the numbers I measured and
  the description carries both sets.
- **Anything about how the tests are structured or the gate corpus works.** That
  is Part 4 and is named as such rather than spent. The only figure borrowed
  from it is the count of gate scripts, 148, as a closing scale line.
- **The `rtk` truncation finding.** Real, and mine, and it happened during this
  build — but it is a fact about my shell, not about this project's record, and
  the honesty rule for this series is that the material comes from the project's
  own files.

## Independent verification by the orchestrator — 2026-09-05

Re-measured from `out/HWB3.mp4`, not read from the build's own report.

| check | measured | agreement |
|---|---|---|
| duration | 763.333 s (12:43) | matches |
| size | 43,655,284 B | matches |
| container | 1920×1080 h264 yuv420p 30 fps, aac 48 kHz stereo | matches |
| integrated loudness | **−16.4 LUFS**, LRA 2.4 LU | matches |
| true peak | **−1.5 dBFS** | matches — and see below |
| picture moves | mean \|Δ\| 0.6017 body / 0.1495 under a play segment | — |
| ⭐ negative control | a still built from its own frame: **0.0000** (max 0.0004) | — |

⭐ **The centrepiece claim holds, and the control choice was the hard part.**
`08-before` vs `09-after`, decoded from the finished muxed segments:
**Δ +0.00 dB, correlation +1.000000** — the same audio, as claimed.
The negative controls are the interesting part:

| control | corr vs `08-before` |
|---|---|
| `05-listen-play` (the one the build used) | **+0.006358** |
| `02-invisible-play` | +0.620204 |
| `01-project-play` | **+0.956545** |

⚠️ **`01-project-play` would have been a WORTHLESS control at +0.96** — it is
largely the same material. The build rejected it in a comment and used
`05-listen`; that judgement was right, and finding #11 (the print *labelled* the
rejected control while computing the accepted one) was a label bug over correct
reasoning, not a measurement error. **Had the label been believed, a 0.006
control would have been reported as coming from a source that actually scores
0.96.**

⭐ **First film built through the fixed true-peak backstop, and it shows.**
−1.5 dBTP with margin, where every earlier film in this tree lands at exactly
−1.0 (Lesson 8's rebuild, measured today: −1.0 dBFS, zero margin).

The bottom-left fragment visible at 171 s ("Bo˥") is **not** a defect — frames
sampled at 170.0 / 170.5 / 171.5 / 172.5 / 174.0 / 176.0 s show a typewriter
caption mid-write ("Both print nothing. Nothing…"). Finding #9's fix is in the
shipped file: the card at 171 s reads "not installed on this machine, so it
never runs", matching the voice.
