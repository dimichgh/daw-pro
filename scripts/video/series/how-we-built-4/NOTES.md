# How We Built a DAW — Part 4

**"How do you know it works? Break it on purpose"**
1920×1080 · built 2026-09-05 · `out/HWB4.mp4`
Brief: `docs/research/design-b7-what-it-took.md` (§4 + §5 of the four-part series).

⛔ **`--finalize` was NOT run.** Nothing was copied to `~/Movies`, no publish
sidecar was written, nothing was uploaded. Nothing was committed and nothing was
staged; HEAD is still `56e26b1`, and
`git status --porcelain -- Sources/DAWEngine/PlaybackGraph.swift` is **empty** —
the file the experiment edited is byte-identical to its pre-build backup.
⚠ `Sources/` and `Tests/` as a whole are **not** clean: 31 entries (26 modified,
5 untracked) were already dirty when this build started — this session's own M35
`view.*` work, none of it mine and none of it touched here.

---

## What this part covers, and what it deliberately does not

| covered | left to another part |
|---|---|
| **falsification** — a fault planted in shipping source, four tests reddening at exactly their own plug-in's latency | the six modules and the one command surface (**Part 1**) |
| the two CONTROLS that stayed green under the plant, and why that is the load-bearing half | the render thread, the deadline, the counter (**Part 2**) |
| a check that **cannot fail**; why green is the weakest colour | the positive control and the four silent failures (**Part 3**) |
| a control built from a **signal simpler than the signal under test** | anything for a professional audience (**B7b**) |
| **§5 — what is still broken**, every item an open `- [ ]` line quoted from the roadmap | |
| the series ending | |

The line against Part 3 is drawn and held: **Part 3 owns "prove the instrument
can find a thing that is there"; Part 4 owns "break the thing and check the test
goes red."** Part 1's "more test than program" hook, its definition of *a test*
and its 223-vs-220 counting anecdote are not reused; Part 2's counter, deadline
and RT-safety audit are not reused. The word "thread" does not appear.

## Chapters

**Computed from the actual `out/segments/*-mux.mp4` durations, not from
`out/timeline.json`** — Part 2 found that file stale across rebuilds. The sum of
segment durations, plus the 4 s intro and 3 s outro, is **824.033 s** against
the file's measured **824.066 s** (33 ms of container rounding). Regenerated
against the shipped 824.1 s build, not an earlier one; `out/chapters.json` holds
the same table. Play segments follow their narration within a stage — verified
by measuring, not assumed: the film at 261.2 s reads **−41.8 dBFS RMS** (the
quiet woodblock demo) and at 243.0 s reads **−18.9** (narration), so
`06-flam-play` starts at 4:21, after its talk. That is ONE boundary measured,
not twenty-five — the sum check proves composition, not order; the ordering is
the tool's, so the one measurement is what tells me which way round the tool
puts them.

| at | stage | beat |
|---|---|---|
| 0:00 | *(intro)* | title card, 4 s |
| 0:04 | `00-open` | what a DAW is · who is talking · **a test you have never seen fail is not evidence** |
| 0:56 | `01-project` | the project on screen — four tracks, 318 notes, 100 BPM |
| 1:17 | *(play)* | twelve seconds of it working |
| 1:30 | `02-green` | 7 924 tests, 709 suites, 270 s, nothing failed — and why that sentence is misleading |
| 2:09 | `03-empty` | the check that cannot fail: an empty list satisfies every rule |
| 2:49 | *(play)* | the manim scene `Vacuous` |
| 3:06 | `05-pdc` | what a plug-in delay is, for a novice; the sample-exact claim |
| 4:02 | `06-flam` | 4096 samples = 85 ms — "here is what that sounds like" |
| 4:21 | *(play)* | six clicks, **landing together** |
| 4:28 | `07-apart` | the same click twice, 85 ms apart. Drummers call it a flam |
| 4:42 | *(play)* | the same six clicks, **doubled** |
| 4:49 | `08-plant` | **the experiment** — line 1393, replaced with zero |
| 5:27 | *(play)* | the manim scene `Falsify` |
| 5:45 | `09-red` | 96 / 256 / 256 / 4096 — each test failed by its own plug-in's delay |
| 6:22 | `10-controls` | the two that stayed green, and why that is the point |
| 7:06 | `11-restore` | putting it back, proved four ways (the "coffee" beat, 1 of 2) |
| 7:49 | `12-probe` | the probe that called a layered saxophone lifeless; 26 green tests |
| 8:29 | `13-ladder` | the two sound banks, measured live during this build |
| 9:09 | `14-blind` | a control simpler than the signal under test |
| 9:49 | `15-comment` | the comment that would have prevented the discovery (the "coffee" beat, 2 of 2) |
| 10:29 | `16-gates` | the gate that refuses to score when its own method fails |
| 11:04 | `17-wedge` | **§5** — a plug-in that freezes the app; legible, not fixed |
| 12:00 | `18-eyes` | **§5** — nothing here has eyes; 3 frames a second |
| 12:42 | *(play)* | the app playing, **filmed at that rate in this build** |
| 12:53 | `19-close` | 131 open items · the four parts · the one idea |
| 13:41 | *(outro)* | end card, 3 s |

## The centre of the film: a fault planted in shipping source

⭐⭐ **`plant.sh` ran three test runs and kept all three logs.** It edits
`Sources/DAWEngine/PlaybackGraph.swift` line 1393 —
`chainLatencyActive: chainState.latencySamples,` → `chainLatencyActive: 0,` —
and restores it under an **unconditional `trap … EXIT`**, because a script that
dies after the `sed` leaves a planted fault in shipping code.

```
1. BASELINE      ./scripts/test.sh --filter PDCHostedAURender → 4 tests, all passed
2. PLANT         one line, one number
3. THE RED RUN   4 tests, 2 failed, 5 issues:
                   alignmentError → 96   == 0
                   alignmentError → 256  == 0
                   alignmentError → 256  == 0
                   alignmentError → 4096 == 0
                   pdcLate → 0.5 > 0.9
4. RESTORE + PROOF   cmp exit 0 · planted marker 0 · original line 1 ·
                     git status --porcelain on that file → nothing
5. GREEN AGAIN   4 tests, all passed
```

This reproduces the record (`docs/ROADMAP.md` m25-n) **exactly** — 96 / 256 /
256 / 4096, and the mix leg at 0.5 instead of 1.0.

⭐ **The half that matters most, and it was not in the brief: the two CONTROLS
stayed green under the plant.** The positive control ("every render makes
signal") and the negative control ("a 0-latency AU gets no compensation") both
passed while the two substantive tests reddened. A test that goes red for
everything is a smoke alarm; this rig went red for the fault and stayed green
for what the fault did not touch. That became chapter `10-controls`.

**The restore is proved four ways and not one of them is a return code**, which
is the film's own thesis applied to the film's own experiment.

## Every number stated on screen, and the command that re-derived it

All in `MEASUREMENTS.json`, with the command beside it in
`MEASUREMENTS-commands.json`. `spec.py`'s `check()` / `band()` / `same()` refuse
to emit a spec whose spoken figure disagrees with the measured one.

| number | how it was derived |
|---|---|
| **96 / 256 / 256 / 4096** samples; **5** issues; **2** red, **2** green; mix leg **0.5** | parsed out of `logs/plant-01-red.log`, written by this build |
| **7 924** tests / **709** suites / **270.297 s** / **zero** failures | `./scripts/test.sh` → `logs/fullsuite.log`, my own run, ✘ names de-duplicated |
| **85.333 ms** = 4096 / 48 000; measured spacing **85.33 ms** | `flam.json` + onset detection on the two renders |
| Apple GM DLS **2165.1 / 2167.1 / 2165.1 / 2167.1 Hz** (0.09 %, 1 tone, `static`); GeneralUser GS **2370.7 / 2489.0 / 2556.8 / 2557.3 Hz** (7.87 %, 3 tones, `live`); both across **28.2 dB** | `instrument.probeLiveness` run **live on staging 17695 during this build**, pitch 57, velocities 25/60/95/127 |
| the record's **26** tests, **6.59 %** true vs **0.295 %** measured | `grep` on `docs/ROADMAP.md` m31-f, each with a negative control |
| `[].every(x => false)` → **`true`** | run live: `node -e 'console.log([].every(x=>false), [].some(x=>true))'` → `true false` |
| **148** gate scripts · **105** commits · **131** open items | `ls scripts/gates/*.mjs`, `rtk proxy git log --oneline`, `grep -c '^- \[ \] ('` |
| **3.02 fps**, **331.6 ms** per capture (record says 3.5) | `slowcap.mjs` — 37 captures over 11.936 s with the transport rolling |
| **5** captures found **3** defects | `grep` on `docs/ROADMAP.md` m28-p7 |
| **4** tracks, **318** notes, **100** BPM | `project.overview` on staging |

### ⚠ Where my measurement and the record disagree, the film speaks mine

`debug.captureUI` is recorded in `CHANGELOG.md` at **3.5 fps** (277–284 ms per
frame). My own loop, run tonight with the transport rolling, measured **3.02 fps
/ 331.6 ms**. The narration says "about three frames a second" — my figure — and
the description carries both.

## §5 — every "still hard" item is an OPEN roadmap line, checked

`measure.py`'s `openitem()` **refuses to record an item it cannot find as an
open `- [ ]` line**, because a fixed thing reported as broken is a fabricated war
story in reverse. All four verified open at build time:

- **m23-av-1**, **m23-av-2**, **m23-av-3** — the third-party plug-in that can
  wedge the main actor. The shipped work makes the wedge legible; the roadmap
  says in capitals **"IT DOES NOT UNWEDGE ANYTHING"** (grepped, with a control).
  Out-of-process hosting was measured cheaper than assumed and is unbuilt.
- **m23-cb** — a transport reporting `playing` while the playhead stayed frozen
  and the meters decayed to silence; ruled out as the wedge, still open.

⚠ **The sax-team defects were NOT named**, because I checked and they are fixed
(m28-bug and siblings closed 2026-08-20). Naming them would have been the
mirror-image dishonesty.

## Build chain

```
plant.sh       → THE EXPERIMENT: green → plant → red → restore → green; 3 logs kept
material.mjs   → saves the pre-existing staging session, pins ids, renders mix-full.wav
soft.mjs       → the same render with Drums and Lead excluded (a bed, not a groove)
liveness.mjs   → the two sound-bank ladders, live on staging; adds ONE track and removes it
flam.mjs       → the 85 ms demonstration; temp track, two renders, removed, re-read
shoot.mjs      → app stills (arrange + two piano rolls, aimed by measured pitch range)
slowcap.mjs    → debug.captureUI in a loop while the transport rolls — §5's own footage
reroll.mjs     → reads each clip's pitch range (this is what caught the empty roll)
measure.py     → MEASUREMENTS.json; every grep negative-controlled, every zero refused
audioprep.py   → mix-clean · soft-bed · the flam pair at ONE shared gain (asserted)
charts.py      → chart-plant, chart-ladder (both MEASURED, not drawn)
termcard.py    → the real log output as terminal cards, verbatim
anim.py        → the manim scenes Vacuous and Falsify
sweep.py       → two playhead bursts over the measured flam envelopes, windows DERIVED
bursts.py      → app footage + manim + slowcap → burst dirs
beds.py        → one bed per burst, EXACTLY its length
spec.py        → HWB4.json, refusing to build on a numeric disagreement
shortsmith.py HWB4.json --out-dir out --size 1920x1080
tailcheck.py   → what each take said AFTER its script — POSITIVE-CONTROLLED
wordcheck.py   → transcribes every stage, reads every content word ≥6 letters
locate.py / slots.py / frames.py → where a figure is spoken vs what is on screen
filmaudio.py   → measures the play segments out of the finished mp4, with 4 controls
restore.mjs    → puts staging back and RE-READS to prove it
reselect.mjs   → the one field restore.mjs could not check: the selected clip
```

## Staging hygiene

- Everything ran against **17695**. **Port 17600 was not listening at any point**
  and was never addressed — re-checked at the end with `lsof` and a positive
  control proving `lsof` still sees a listener. `build.mjs` refuses 17600.
- The session already open on staging was **saved first** to the scratchpad as
  `hwb4-staging-preexisting-2026-09-05.dawproj`.
- The project was **read, not built** — the four-track demo this series already
  has on staging (Pad / Bass / Drums / Lead, tempo 100, 318 notes).
- **Two temporary tracks were created and removed** (the liveness probe and the
  flam); both removals were proved by re-reading `project.overview`, not by the
  setter returning. The four real tracks were **muted while the flam rendered
  and un-muted after**, and the un-mute was asserted field by field.
- **Master volume set to 0 while the transport ran** and put back.
- The window was **not** resized: 1600×900 throughout.
- `--app DAWApp` only. **Five leaked node client sockets** were found on 17695 at
  the end — all mine, all named by `ps` before anything was killed — and killed
  pid-exact; the re-read then showed **0** clients with the listener still up as
  a positive control.
- The speech server ran on **port 8768**, derived per the port rule
  (`8000 + ($$ % 900) + 1`), started by `run.sh` (which refuses to start if
  anything is already on that port), killed **pid-exact** at the end
  (pid I started 18771 = pid on port 18771), then the port was re-read and came
  back **free** and `ps -p` came back **gone**. No other speech server was
  running on any port at any point, and none was touched.

## Things found by looking — every one invisible to the build's own return code

### 1. ⭐⭐ A take said "What a day out we is" for "What a DAW is" — in the closing summary

`19-close` scored **sim 0.98**, `factCheck` OK, and shipped the series' key term
mangled in the sentence that recaps all four parts. Nothing caught it, because
**`brandCheck` only ever ran on `00-open`** and four syllables cannot move an
aggregate over two hundred words. `00-open`'s transcript says "DAW" cleanly, so
the voice can say it — this was a bad take, not a bad word. Fixed by
re-recording **and by adding `brandCheck="DAW"` to the closing stage**, so the
gate now covers it. Re-transcribed to confirm: "What a daw is".

### 2. ⭐ "buries" came back as "varies" — a meaning change

`13-ladder`'s script said the wrong weighting *"buries the high harmonics under
the low ones"*. The transcript read *"varies"*. I could not determine from the
audio alone whether the TTS or the recogniser was at fault, so I removed the
ambiguity instead of arguing about it: the word is now **"hides"**, re-recorded,
and the transcript confirms "hides".

### 3. ⭐⭐⭐ My tail-check's positive control FAILED, and Part 3's sweep has the same bug

The check for takes that babble past the end of the script (Part 3's finding #1)
walks backward for the last window containing the script's final words. **With a
real tail present, that window straddles the script end, so it returns only the
few words after the window.** I planted an 11-word tail: it reported **3**.
Every "clean, 1-word overhang" reading it produces is that artefact.

⚠ **This means Part 3's sweep of all fourteen stages — reported as "only those
two were affected (every other stage reports a systematic 1-word anchor
overhang)" — was uncontrolled.** The systematic 1-word overhang *is* the bug.
Part 3's two real tails were found by a different route and are not in doubt;
its clean sweep is.

`tailcheck.py` anchors on the last occurrence of the script's final content word
and **plants a known tail on every stage before reporting anything**, exiting if
it cannot find it. Control now finds 16 of 16 planted words on all 19 stages;
all 19 takes are genuinely clean (0 words after the script's last word).

### 4. ⭐⭐ Eight chapters held ONE still for 35–56 seconds

Found by running `slots.py` and reading the schedule: `03-empty`, `05-pdc`,
`11-restore`, `13-ladder`, `15-comment`, `16-gates`, `17-wedge` and `18-eyes`
each had a shot list of one repeated image, so the whole chapter was a static
frame with a voice over it — the house standard's named failure mode. Six new
cards were appended (indices are positional; appending cannot re-point an
existing stage) and two stages re-pointed at existing images. Every stage but
the 14-second `07-apart` now has at least two distinct stills, and `07-apart`
runs straight into moving footage. **No re-narration was needed** — all 19 takes
were reused unchanged, which the build log states stage by stage.

### 5. ⭐ `build.mjs`'s `shot()` helper writes relative to the APP's cwd, not the caller's

`shot(name)` passes `./shots/<name>.png` to `debug.captureUI`, and **the app**
resolves it — against the repo root. Two captures landed in
`/Users/dsemenov/Views/daw-pro/shots/`, a directory that did not exist before.
Return code `ok`, valid PNGs, correct names, wrong directory. Moved into this
build's `shots/` and the stray directory removed; every capture here now passes
an absolute path. ⚠ **Reported as a defect in a shared script; not fixed by me.**

### 6. A piano roll aimed at the bass photographed an almost-empty grid

`ui-capture` trap 6, hit exactly. `clip.getNotes` measured the ranges: **Bass
29–43 (median 33)**, Pad 53–67, Lead 67–76. The roll's default band shows
roughly 48–79, so 80 bass notes rendered as about eight. `pianoRollCenterPitch:
36` fixed it and the shot now shows the whole line with note names. **I looked
at it** — `md5 | uniq -d` could not have seen this, every shot was distinct.

### 7. ⭐⭐ A grep in `measure.py` returned zero because of a **shell** bug, not an absent string

`grep1()` refused to record a zero, correctly — and the pattern it refused,
`` returns **`true`** ``, IS on line 46 of the file. The cause: the pattern was
shell-quoted with `json.dumps`, which produces a **double-quoted** string, and
bash runs backticks inside double quotes as command substitution. The pattern
that actually ran was `returns ** **`. Fixed with `shlex.quote`. ⚠ Part 3's
`grep1()` has the same `json.dumps` call; it has not bitten there because none
of its patterns contain a backtick, but it is latent.

### 8. `sweep.py` refused to build because of a strict inequality

The derived listen-windows filter required a run **longer than** 0.02 s and
every one of the six runs measured **exactly** 0.02 s, so it found zero windows
and refused. A threshold landing exactly on the data. Now `>=` against a
multiple of the envelope window.

### 9. `audioprep.py` read and wrote the same filename, so re-runs compounded

`soft.wav` was read, attenuated and written back under its own name. The second
run attenuated it again (peak reached −23 dBFS) and nothing errored. Source and
product now have different names.

### 10. Every `node` script hung at the tool's timeout — and none of them had failed

Five scripts "timed out" at 240–300 s having already written every file they
were supposed to write. The cause was `close()` not ending the process, so node
sat on an open handle. Adding `process.exit(0)` fixed it. ⚠ **The reason this
belongs here rather than in a footnote: I nearly filed
`instrument.listSoundBanks` as a hanging command on the strength of it.** An
isolated probe with a positive control measured it at **1 ms**. A hang with no
mechanism is a correlation, and the biggest thing in the log is the most
tempting thing to blame.

### 11. The build REFUSED TO SHIP on a word-perfect take, and it was right to

`13-ladder`'s first pass failed `factCheck` on `twenty-one hundred`. The take was
verbatim; **Whisper writes "2165 hertz"**, and my whitelist only allowed
"twenty-one hundred"/"2100". The gate compares against a TRANSCRIPT, not the
script. Whitelist corrected, with the reason recorded in `spec.py`.

### 12. Cosmetic, not fixed

`16-gates` says "a hundred and forty-eight small scripts" at about 4 s while a
card about that gate's *design* is on screen; the figure itself is not on that
card. It is stated once, clearly, and Part 1 already put 148 on screen.

## The moving footage — the one honest compromise, declared

⛔ **The 30 fps shot of the app playing (`01-project`) was filmed for Part 3
earlier the same day (`play-arrange.mp4`, mtime 2026-09-05 19:00 — checked, not
assumed), of this same project on this same staging instance.** It
was not filmed in this build, and the description says so.

**Why:** the user's screen was **locked** for the whole of this build — "Display
1 Shield" appears in `screenrec --list`'s window list — and a locked screen
delivers no changed frames to ScreenCaptureKit. `screenrec` reported **"ZERO
frames captured; the file is not a recording"** three times rather than writing a
valid-looking empty file, which is the right behaviour and is why I noticed at
all. **I will not unlock someone else's screen**, and I did not use
`caffeinate` to wake the display.

⭐ **What IS filmed in this build is the closing chapter's footage**, and it is
better material than a workaround: `debug.captureUI` in a loop while the
transport rolled, **37 captures over 11.936 s = 3.02 fps**, held at their real
timestamps. The playhead visibly stutters, the narration says the number, and
§5's claim is demonstrated instead of asserted.

## Audibility, checked rather than assumed

The 85 ms demonstration is a **timing** difference, so it must not be carried by
level. Measured out of the finished mp4:

```
06-flam  (together)  rms -42.06  peak -11.50 dBFS
07-apart (doubled)   rms -38.91  peak -11.50 dBFS
level +3.16 dB, correlation +0.6951
```

Both halves share **ONE static gain** (`audioprep.py` asserts the relationship
survives to 0.00e+00 dB) and the spec sets `normalize: false`, so the +3.16 dB is
the extra hits themselves, not a normaliser. **The peaks are identical at −11.50
dBFS** — a sharp mid-band woodblock click, plainly audible on a laptop speaker.
Its RMS is low only because most of the excerpt is silence between hits, which is
why peak is the right figure here and RMS is not.

⚠ **The negative control was chosen by measuring all four candidates and
printing every one**, because Part 3's report labelled a control it had
rejected. Measured: `01-project` +0.001491, `03-empty` +0.002419, `08-plant`
+0.002419, `18-eyes` +0.000972. Control used: **`18-eyes` at +0.000972**,
separation **715×**. ⚠ `03-empty` and `08-plant` read identically because they
play the same bed; they are not independent of each other.

⭐ **The play segments' levels, stated rather than hidden:** `01-project`
−24.33 dBFS RMS and `18-eyes` −24.49 against beds at −17.14, because the two
music segments set `normalize: false` and the beds do not. The "here it is
working" moment is therefore the quietest music in the film — the same finding
Part 3 recorded and, for the same reason, not chased: lifting it is what put the
peaks near the ceiling last time.

## Every spoken word, transcribed back and read

All 19 stage wavs transcribed and **every content word of six letters or more**
checked against the script (`wordcheck.py`, negative control: no transcript
contains "banana"). Residual "missing" words after the two fixes above, all
benign and all read in context:

- Whisper writing number-words as digits (7 924, 709, 270, 4096, 96, 256, 1393,
  2165, 2167, 131, 148, 26, 28, 85)
- British → American: `colour`→`color`, `equaliser`→`equalizer`
- `milliseconds`→`ms`, `PlaybackGraph`→`playback graph`

**No dropped content words and no meaning inversions** after the "buries"/"hides"
fix. The classes Part 2 was bitten by — a lost word at sim 1.00, and "lowest" for
"slowest" — were both looked for specifically.

## Final assembly

- `out/HWB4.mp4` — **824.066 s (13:44)**, 1920×1080, h264 yuv420p 30 fps, aac
  48 kHz stereo, **46,422,463 bytes (44.3 MB)**. `out/HWB4-nometer.mp4` is the
  kept pre-meter master.
- Loudness **re-measured by me** off the finished file, not read from the build
  report: **−16.4 LUFS integrated, −1.5 dBTP, LRA 2.3 LU**.
- `verify.py`, run standalone with all 24 stage joins and against a live speech
  server: **ALL 8 CHECKS PASSED.**
  - streams `v=h264,1920,1080,yuv420p,30/1  a=aac,48000,2  824.1s`
  - a/v drift **21.0 ms** (under one frame)
  - distinct frames **5 of 5** (max 24.30, min 5.11, floor 2.0); **control:
    frame vs itself = 0.00**
  - audio present at all 4 sample points
  - loudness −16.4 LUFS / −1.5 dBTP
  - joins: **worst seam 0.4428 at t = 289.78 s** against an ordinary-frame
    reference of 0.1643 and a **peak-to-inverted-peak control of 1.3735**
  - content: best-matching stage **0.35** vs worst-matching **control 0.03** —
    **13.4× separation** over 6 blind windows
- ⚠ **`check_ab_separation` is ABSENT, not passed** — it reads a `.timeline.json`
  sidecar for `ab` blocks and this film has none: the flam pair is built as two
  ordinary play stages sharing one gain. `filmaudio.py` covers the same ground
  directly and with four controls.
- **The true-peak backstop did not fire.** −1.5 dBTP with margin, as Part 3 got
  after the shared-script fix; no oscillation, no stacked AAC generations.
- Narration gate: **all 19 stages first-take, sim 0.97–1.00**, brand OK on
  `00-open` **and** `19-close`, facts OK on all eleven stages carrying a
  whitelist. `13-ladder` and `19-close` were each re-recorded once for the
  reasons in findings #1 and #2, and both landed first-take again.
- The `⚠ 824.1s is OVER the 60 s Shorts limit` line is shortsmith's Shorts
  advisory and does not apply to a long-form film.
- ⚠ `out/build-report.json`'s narration record: the final build reused all 19
  cached takes, so it reports them as `unchanged, kept` rather than as fresh
  gate results. The per-take figures above come from `logs/build3.log` and
  `logs/build4.log`, which are the builds that actually synthesised them.

## Length, measured rather than estimated

⚠ `spec.py`'s "N min at 150 wpm" estimate is useless: it said **22.4 minutes**
for a film that came out at **13:44**. What IS reliable is a ratio measured on
the shipped siblings — Part 2 776 s / 3040 words and Part 3 763 s / 2999 words,
both **0.255 s of finished film per narration word**. The first draft was 4 224
words = a predicted 18 minutes, and was cut on that arithmetic in three passes
(4 224 → 3 892 → 3 362 → 3 204) before anything was synthesised. Final: 3 204
words, predicted 13:53, **measured 13:44** — the ratio held to 0.9 %.

⚠ **13:44 is 37 s longer than Part 3 (13:07), the longest of the siblings.** I
stopped cutting there deliberately: every remaining candidate was either a §5
open-defect item, the series ending, or one of the two documented eureka beats,
and the design doc's own rule is that a demonstration goes before an
explanation does. The series brief is the user's own words, quoted from the
transcript rather than from memory: *"No limitation in length, but try to keep
it within 15 mins like any other demos."* 13:44 is inside that.

## Staging restored — re-read, field for field

`restore.mjs` ran against **17695 only** and its re-read is the proof, not its
return:

- `project.overview` — 4 tracks **Pad, Bass, Drums, Lead**, **318** notes,
  **0** effects / **0** sends / **0** automation lanes on every track, tempo
  **100**, playhead **0**, `isPlaying false`, master volume **1**, no track
  muted or soloed, **0** markers, loop disabled 0–16.
- `debug.panelLayout` — every field matches the baseline captured before
  anything was changed: `pianoRollPPB 32`, `pianoRollRowHeight 14`,
  `rowHeight 50`, `editorFraction 0.45`, `editorMaximized false`,
  `followPlayhead false`, `pianoRollMinimap true`, `sidebarWidth 260`,
  `mixerInsertsCollapsed false`, `waveformNormalize true`,
  `waveformVerticalZoom 1`, `auditionEnabled true`.
- `debug.windowFrame` — **1600×900**, never resized.
- `debug.captureUI` — Arrange view, no mixer, no modal, transport at 0.
  **I looked at the screenshot.**
- `lsof -nP -iTCP:17695 -sTCP:ESTABLISHED` — **0** clients, with the listener
  still up as a positive control.

⚠ **One drift I found and corrected, and one I could not check.** The
**selected clip** had moved from Lead to Bass, because `shoot.mjs` aimed the
roll at the Bass and nothing aimed it back — a field `restore.mjs` could not
assert because I never recorded it in the baseline. Corrected via `reselect.mjs`
and confirmed by looking at the screenshot: the editor reads "Lead" again, as it
did in the pre-build capture. ⚠ **The same honest drift Parts 1–3 recorded also
applies: the session is now backed by the copy saved before this build started**
(`<scratchpad>/hwb4-staging-preexisting-2026-09-05.dawproj`) — and that
scratchpad is session-scoped, so the backing file will vanish with it. The
session's own content is intact; only its save-path is a copy. Musical content,
tempo, track set, note counts, effect chains and layout are identical; only the
document's backing path changed.

## Deliberate honesty edges — things a viewer could reasonably ask about

- **The plant is real and it happened during this build**, in
  `Sources/DAWEngine/PlaybackGraph.swift`, not in a copy. Three logs are kept
  beside the film. The restore is proved four ways and `git status --porcelain`
  on that one file is empty.
- **The flam is an ILLUSTRATION and the narration says exactly that.** There is
  no "PDC off" switch on the wire and inventing one would be a different
  program, so the film says "this is what eighty-five milliseconds apart sounds
  like", never "this is the bug". The number, 4096 samples, is the real latency
  the real test measures.
- **Chapter 12 to 15 tell a documented incident in the first person.** The
  centroid bug is the project's own record (m31-f); what I did *during this
  build* is re-run the measurement live on both banks, and it reproduced the
  record to four significant figures. The series is narrated as one continuous
  first person by design.
- **Both "eureka" beats are subverted on purpose**, as the brief asks: chapter
  eleven refuses the coffee-shop story and substitutes four verification
  commands; chapter fifteen tells one plainly, and it is a retraction of
  something I wrote myself.

## Things I could not source, and therefore cut

- **A live third-party plug-in wedge.** Reproducing it would mean loading Surge
  XT and hanging the user's staging app for minutes. The film quotes the
  roadmap's own words instead and says the fix is measured and unbuilt.
- **A demonstration of the vacuous check in this repo's own gate corpus.** The
  census tool needs `acorn` at a path that is gitignored, and the census
  document deliberately carries no counts (its own stated reason: "a snapshot's
  numbers can rot faster than its method"). The film describes the sweep and
  demonstrates the axis with `[].every()` run live, rather than claiming a count.
- **The `rtk` shell-hook truncation.** Real, and it bit `measure.py` again here
  (`git log --oneline | wc -l` answers 50 under the hook, 105 through
  `rtk proxy`). It is a fact about my shell, not about this project's record,
  and the series' honesty rule is that the material comes from the project's own
  files.

## Independent verification by the orchestrator — 2026-09-06

Re-measured from `out/HWB4.mp4`; every figure below is mine, not read from the
build report. All agree with it.

| check | measured |
|---|---|
| duration | 824.066 s (13:44) |
| size | 46,422,463 B |
| container | 1920×1080 h264 yuv420p 30 fps, aac 48 kHz stereo |
| integrated loudness | **−16.4 LUFS**, LRA 2.3 LU |
| true peak | **−1.5 dBFS** |
| picture moves | mean \|Δ\| 0.2001 body / 0.1485 over the 3 fps app footage |
| ⭐ negative control | still built from its own frame: **0.0002** (max 0.0016) |
| narration record | `build-report.json` → 19 stages, `verifyFails: []`, `verifyBroken: []` |

### ⭐⭐ The part that mattered most: the planted edit is gone from shipping source

`plant.sh` modified `Sources/DAWEngine/PlaybackGraph.swift:1393` — real product
code — to force a gate red. **Verified restored three independent ways, with a
positive control proving the probes can see a modified file:**

| probe | result |
|---|---|
| the line itself | `chainLatencyActive: chainState.latencySamples` — the original, not `0` |
| `git status --porcelain` on that file | empty |
| `git diff --stat HEAD` on that file | empty |
| ⭐ **positive control** — same two probes on `Sources/DAWApp/DAWProApp.swift` | ` M` and `156 insertions(+), 31 deletions(-)` |

Without that control an empty `git status` proves nothing: a probe that never
looked and a probe that looked and found nothing print the same thing.

### Acted on from this build's findings

**Finding 5 is now fixed in the shared script**, not just worked around locally.
`scripts/video/session/build.mjs` resolved `SHOTS` and `burst()`'s `dir` as
RELATIVE paths, which travel over the wire and are resolved by the **app**
against the app's cwd (the repo root) — so captures landed in
`daw-pro/shots/` while the script believed they were in its own directory, and
`debug.captureUI` returned `ok` with a valid PNG at a plausible name. In
`burst()` it was worse: `dir` was used for BOTH `fs` calls and wire paths, so
the "clear stale frames first" guard cleaned one directory while the app filled
another. Both now go through `path.resolve()`; `node --check` passes and SHOTS
verified absolute from a foreign cwd.

**Still open, reported not fixed** (per-film scripts, both belonging to Part 3):
its `retake.py` shares the tail-anchor bug found here, so Part 3's "clean 1-word
overhang across 14 stages" was uncontrolled and that 1 word is likely the
artefact; and its `measure.py` `grep1()` shell-quotes with `json.dumps`, so a
backtick in a pattern would run as command substitution — latent only because
no Part 3 pattern contains one.
