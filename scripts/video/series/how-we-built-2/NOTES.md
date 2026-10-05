# How We Built a DAW — Part 2

**"The render thread is sacred"**
1920×1080 · built 2026-09-05 · `out/HWB2.mp4`
Brief: `docs/research/design-b7-what-it-took.md` (§2 of the four-part series).

⛔ **`--finalize` was NOT run.** Nothing was copied to `~/Movies`, no publish
sidecar was written, nothing was uploaded. Nothing was committed.

---

## What this part covers, and what it deliberately does not

| covered | left to another part |
|---|---|
| sample, block, sample rate — from the LIVE engine | the six modules, the one command surface (**Part 1**) |
| what a thread is, and why audio gets a special one | the four documented silent failures (**Part 3**) |
| **a constructed buffer dropout, played** | falsification testing, the gate corpus (**Part 4**) |
| the four forbidden operations, with the *why* of each | anything for a professional audience (**B7b**) |
| the counter that lost 45 % of its counts, and the re-attribution | |
| the RT-safety audit: 0 violations, 6 watch items, dated | |

Part 1's architecture is never re-taught; the words "module", "socket" and
"command surface" do not appear. Part 3's anecdotes are untouched. Part 1's
own eureka (223 vs 220 tools) is not reused.

## Chapters

| # | stage | beat |
|---|---|---|
| 1 | `00-open` | what a DAW is · who is talking · sound is due on a schedule |
| 2 | `01-block` | sample, sample rate, block — 512 at 48,000 = 10.67 ms, read LIVE |
| 3 | `02-thread` | what a thread is · the audio thread's contract → the manim animation |
| 4 | `03-clean` | the project, and twelve seconds of it playing correctly |
| 5 | `04-broken` | **exactly how the broken file was made**, then the same twelve seconds |
| 6 | `05-zoom` | why 10.67 ms of silence is loud: the two vertical steps |
| 7 | `06-rule` | the rule that forbids most of programming |
| 8 | `07-why` | memory · locks · logging · waiting — one plain sentence of *why* each |
| 9 | `08-counter` | atomic, defined · the counter that lost 45 % → the manim animation |
| 10 | `09-reattrib` | the fix that changed nothing, and what that meant (the "coffee" beat) |
| 11 | `10-audit` | 47 sites, 8 families, 0 violations, 6 watch items — dated |
| 12 | `11-load` | 41 tracks at 14 % of a core · this project's own live numbers |
| 13 | `12-close` | what Parts 3 and 4 are |

## The centre of the film: how the dropout was built

⭐ **The engine was NOT crashed, stalled or starved, and the film says so in
the same breath as it plays the result.** `04-broken`'s narration states the
method before the audio, not after.

`dropout.py`:

1. The project is rendered offline to a 24-bit 48 kHz WAV over the control
   socket (`render.mixdown`, 19.2 s, staging port 17695).
2. The first **12.0 s** is taken as the excerpt — the same twelve seconds the
   moving shot of the app shows, so the clean half of the demonstration is
   what the viewer is watching.
3. Three separate **512-frame** blocks are overwritten with zeros, each landed
   on a block boundary the way the engine's own blocks fall:

   ```
   zeroed block at frame 122368 = 2.5493 s   (10.667 ms)
   zeroed block at frame 266240 = 5.5467 s   (10.667 ms)
   zeroed block at frame 410112 = 8.5440 s   (10.667 ms)
   ```

4. **Both files are read back from disk and compared.** `dropout.py` refuses
   to continue unless exactly `512 × 3 = 1536` sample frames differ, in
   exactly three runs of exactly 512, and unless the first zeroed block really
   is zero:

   ```
   differing frames 1536 (expected 1536)  runs [(122368, 512), (266240, 512), (410112, 512)]
   ```

5. `measure.py` refuses to write `MEASUREMENTS.json` if the block size the
   dropout was built at disagrees with the block size the **live engine**
   reports, so the demonstration cannot drift from the deadline it illustrates.

Both play segments are `normalize: false` and `bedEligible: false` — the two
halves are the same passage at the same level, and the click is not allowed to
linger as a bed under the next stage's narration.

⚠ **The 512-frame block size is not an assumption.** `engine.performanceStats`
on the running app reports `quantumFrames: 512` and `sampleRate: 48000`.

## Every number stated on screen, and the command that re-derived it

All of these are in `MEASUREMENTS.json` **with the command stored beside them**
under `_commands`; `spec.py`'s `check()`/`band()` refuse to emit a spec whose
spoken figure disagrees with the measured one — and `band()` exists because
several of these are read live and move a little between runs, so the check has
to test the **spoken form** ("under three thousandths of a second"), not a
number the narration never says.

| number | how it was derived |
|---|---|
| 512 samples per block, 48,000 samples a second | `engine.performanceStats` on staging (17695), `quantumFrames` / `sampleRate` |
| 10.67 ms deadline | 1000 × 512 ÷ 48000, computed in `measure.py` from the two live reads |
| six render blocks | measured call rate ÷ (sampleRate ÷ blockFrames); landed on **6.00** (five instrument tracks + the master mix) |
| the live window: blocks answered, none late, slowest call, average load | one `engine.performanceStats {reset:true}` → 6 s of playing → `{reset:false}` |
| 3 dropouts × 512 samples, 1,536 frames changed | `dropout.py`, verified by re-reading both files |
| 47 sites in 8 families, 0 violations, 6 watch items, 2026-07-10 | `grep` on `docs/research/audit-rt-safety.md` (see the trap below) |
| 45 % of the counts lost, 8 threads × 20,000 | `grep` on `docs/ARCHITECTURE.md` **and** `docs/ROADMAP.md`; `measure.py` refuses to build if the two records disagree. Thread/iteration counts grepped out of `Tests/DAWEngineTests/EnginePerformanceTests.swift` |
| 597 calls a second before and after the fix; 1,394 due | `grep` on `docs/research/perf-c-load-profile.md` |
| 41 tracks, 14 % of one core, 22.9× realtime offline | `grep` on `docs/research/perf-c-load-profile.md` |
| 5 tracks, 228 notes, 100 BPM | `ids.json`, written by `material.mjs` as it created them |

### ⚠ The watch-item count has a trap, and counting the wrong thing gives 5

`audit-rt-safety.md`'s summary says **`Watch list (6)`** and lists six numbered
entries. But only **five table cells** read `**WATCH**`, covering four distinct
sites — two of the six list entries are notes attached to rows whose verdict is
`SAFE`. Counting cells returns 5 and would have "corrected" a figure that is
right. `measure.py` measures **both** and refuses to build unless the numbered
list agrees with the header:

```
auditWatchListed  6      auditWatchCells  5
```

The film says "six watch items", which is the list.

⭐ Part 1 **cut** this figure for want of a source. It is restored here because
it was verified in this build, by two independent counts with a stated rule for
which one is the answer.

### ⚠ 45 % and 57 % are different numbers and the wrong one is easy to grab

`EnginePerformanceTests.swift:145`'s own comment says the old code "lost 57 %
of increments at 16 debug tracks". **That is not this film's number.** 57 %
is the live sixteen-track debug reading (100 − 43), and perf-d later
re-attributed it to *real dropped device cycles*, not lost counts — which is
the story `09-reattrib` tells. The film's 45 % is the **in-process 8-thread
falsification**, recorded in `ARCHITECTURE.md:50` and `ROADMAP.md:175`.

The narration is also careful about what the test does: the test asserts
exactness. The 45 % was measured by **putting the old code back** and watching
the test go red. The film says it that way.

## The "eureka" beat — one, and it is Part 2's own

Per the brief: the coffee is subverted, not performed, and used **once**.

`09-reattrib`: the counter was fixed, the count became provably exact, and the
suspicious reading *did not move* — so those calls had genuinely never
happened. Real missed deadlines, wearing the costume of a counting bug. The
line is "This is the point where I am supposed to tell you that I stepped away
for a coffee and it came to me. I do not drink coffee. What actually happened
is that fixing the bug did not change the number, and a fix that changes
nothing is telling you something."

Part 3's four cases and Part 1's 223-vs-220 anecdote are both left alone.

## Build chain

```
material.mjs   → builds the demo project over the socket (5 tracks, 228 hand-written notes) → ids.json
shoot.mjs      → app stills via debug.captureUI
drive.mjs      → films the app with screenrec while the transport runs → media/play-arrange.mp4
dropout.py     → mix-clean.wav / mix-broken.wav + wave-full.png / wave-zoom.png → dropout.json
measure.py     → MEASUREMENTS.json, every figure with its command (LIVE engine read)
anim_deadline.py → the two manim scenes (Deadline, Counter)
bursts.py      → explodes every moving source into bursts/ → bursts.json
beds.py        → one audio bed per burst, EXACTLY its length
charts.py      → chart-budget.png, from the live measurement
spec.py        → HWB2.json, refusing to build on a numeric disagreement
shortsmith.py HWB2.json --out-dir out --size 1920x1080
restore.mjs    → puts staging back and re-reads to prove it
```

Re-run order after any source change: `dropout.py` → `measure.py` → `bursts.py`
→ **`sweep.py`** → `beds.py` → `charts.py` → `spec.py` → `shortsmith.py`.

⚠⚠ **`sweep.py` MUST follow `dropout.py`, and it was missed once.** `sweep.py`
draws its 360 frames from `mix-broken.wav`; when `dropout.py` re-wrote that file
with the −6 dB static gain, the sweep frames were left at the old amplitude. The
film then showed **two pictures of the same twelve seconds at different
heights** — `wave-full` (regenerated) at ±0.5 and the sweep (stale) filling the
plot. Nothing failed: no gate compares two charts. Caught by putting the frames
side by side and looking.

⚠ `measure.py` **plays the transport on staging for six seconds** every time it
runs, and the live figures move a little between runs. `charts.py` must be
re-run after it or the chart and the spec disagree.

## Staging hygiene

- Everything ran against **17695**. Port 17600 (the user's live app) was not
  listening at any point during this build (`lsof -nP -iTCP:17600 -sTCP:LISTEN`
  returned nothing, with a positive control proving `lsof` was working) and was
  never addressed. `material.mjs` asserts the port itself; `measure.py` refuses
  any port but 17695.
- The session already open on staging was **saved first** to the session
  scratchpad as `hwb2-staging-preexisting-2026-09-05.dawproj`, and
  `restore.mjs` reopens it.
- The window was **not** resized: 1600×900 throughout, `debug.windowFrame` only
  ever read.
- **Master volume was set to 0 while filming** and put back afterwards — the
  film's audio was rendered offline, and nobody asked for the mix out of their
  speakers at midnight.
- `--app DAWApp` only. Frame 1 of the recording was looked at by hand and is
  the right window, with the transport already running (`0:00.260`).
- The `omlx` speech server was started on port 8000 for the narration gate and
  killed pid-exact, found by port, afterwards.

## Things found by looking

Every one of these was invisible to the build's own return code — the first
assembly reported `[ ok ]` on all seven verify checks.

1. **The broken twelve seconds played under a bullet list.** The one moment in
   this whole series where there is a visible cause and an audible effect was
   spent on a static card, because the play segment reuses the stage's shot
   list and the still timer picked the first two entries. `sweep.py` now
   renders a **360-frame burst of the waveform with a playhead crossing it in
   real time**, so the mark the viewer sees and the click they hear land
   together. Frames pulled at film 296.0 / 297.0 / 300.0 / 303.0 s: the
   playhead is just left of the first mark, on it, on the second, and on the
   third. **I looked at all four.**

2. **Nine shot lists were mistimed, and every one was fixed by measurement.**
   The still timer is `n = round(total/cut); each = total/n`, with `holdLast`
   CLAMPING the list — not "spread evenly". Rather than guess, each key phrase
   was located by transcribing **8-second windows of the stage's own wav** until
   the phrase appeared, then the film frame at that time was pulled and looked
   at. What was wrong before the fix:

   | stage | the words | what was on screen |
   |---|---|---|
   | `00-open` | "written by an artificial intelligence" (18–26 s) | the title card, not the disclosure card |
   | `04-broken` | "three separate blocks of 512" (24–32 s) | the waveform, not the method card |
   | `05-zoom` | "look at the edges" (18–26 s) | the wide view, not the close-up |
   | `06-rule` | "you may not ask the system for memory" (24–26 s) | the summary card, not the list |
   | `08-counter` | "45 % of the counts" (48–50 s) | the forbidden list, not the 45 % card |
   | `10-audit` | "six things it calls watch items" (24–32 s) | straddled onto the wrong card |
   | `11-load` | fine already (41 tracks at 6–14 s) | — |
   | `12-close` | "part three" (~16 s) | the title card, not the closing card |

   After the fix, eleven frames were pulled from the finished film at the exact
   moment each figure is spoken and inspected as a contact sheet. All eleven
   show the card carrying that figure.

3. **A transcribe-back dropped a word the audio actually says.** The full-file
   Whisper pass of `10-audit` returned "Each one got a verdict. 0." — the word
   *violations* absent, which looked like the speech model having skipped it.
   Transcribing **only the thirteen seconds around that phrase** returned
   "got a verdict. Violations 0." The audio is correct; the long-file pass
   collapsed it. ⚠ Worth carrying: **a word missing from a whole-file
   transcript is not evidence of a word missing from the audio.** Re-transcribe
   the excerpt before believing it.

4. **An orphaned build process wrote thirteen narration files whose gate report
   was lost.** A `nohup`-backgrounded shortsmith survived its shell, a second
   copy was started against the same output directory, and the two collided on
   `_try1.wav` (`FileNotFoundError` renaming it to `01-block.wav`). All thirteen
   wavs existed afterwards and would have assembled fine — but the per-stage
   `sim` scores that gate them had gone to a log the second run truncated. The
   whole `vo/` directory was deleted and regenerated by a single process, so
   every stage's score is on the record. **A file that exists is not a file
   that passed a gate.**

5. **The manim `Deadline` scene's two trace labels rendered off the left edge**
   ("sound", "ole in it") because `next_to(..., LEFT)` does not know where the
   frame is. They are anchored to the left margin now. Nothing measured this
   either; I pulled a frame and looked at it.

Also: `.become()` mutates and returns a mobject — it is **not** an animation,
and `self.play(x.become(...))` is a `TypeError`. It is still the right tool for
a numeric readout (`Transform` renders mush mid-step), so it is called outside
`play()` and the beat held with `wait()`.

## The click was verified in the FINISHED FILE, with a control

An mp4's AAC could have smeared a 10.67 ms gap into nothing. It did not. The
three gaps survive encoding as **exact digital silence**, measured on the
finished film's own decoded audio (2 ms RMS windows, ±12 ms around each
instant):

```
dropout 1 @ film 300.488s : min RMS 0.000000
dropout 2 @ film 303.485s : min RMS 0.000000
dropout 3 @ film 306.483s : min RMS 0.000000
```

⭐ **With negative controls** — the same probe, same film, at instants inside
the same broken passage where nothing was edited:

```
control @ film 299.133s : min RMS 0.073850
control @ film 301.933s : min RMS 0.060045
control @ film 304.933s : min RMS 0.122939
control @ film 308.433s : min RMS 0.079344
```

Without the controls, three low readings would have proved nothing.

The A/B holds one level up as well: `out/segments/04-broken-play.wav` has
zero-RMS windows at 2.550, 5.548 and 8.544 s and `out/segments/03-clean-play.wav`
has **none** at those same instants (0.128 / 0.103 / 0.126).

### ⚠ This probe first reported the dropouts were GONE, and it was the probe

The first run of it said the finished film had no silence at all — min RMS
0.088–0.148 at all three instants, indistinguishable from the controls. That
reading was **wrong, and it was wrong in the most dangerous direction**: it
looked like a clean, confident negative.

The cause was that I had *assumed* the play segment began at 297.88 s, computed
from segment durations. Cross-correlating the segment against the film put the
true start at **297.9333 s** — a 39 ms error, larger than the 10.67 ms hole
being looked for, so every window landed beside the gap rather than on it.

Two things caught it, and only because I ran them:

1. **A positive control on the source.** The identical probe on
   `audio/mix-broken.wav` returned exactly `0.00000000` at all three instants
   and 0.06–0.12 at the controls. A probe that cannot find the thing in the file
   that certainly contains it is not evidence about any other file.
2. **Walking the chain.** `04-broken-play.wav` had the zeros, and
   `04-broken-play-mux.mp4` still had them (0.00014 vs a 0.077 control) — so
   "the concat destroyed it" was already untenable before the offset was found.

⭐ The lesson is the house one, in a new costume: **a probe that never looked and
a probe that looked and found nothing produce identical output.** Measure the
offset; do not derive it and trust it.

## The corner avatar

Every card and chart was checked for ink in the bottom-right eighth, where
shortsmith burns the level-meter avatar. **All eleven cards: 0.00 %.** The two
waveform charts and the budget chart carry 0.5–1.4 % there — waveform tail and
an axis tick, no label — and every caption is anchored at x = 0.055, far left.
The manim captions run through `_place_cap()`, which keeps their right edge at
x ≤ 4.4 manim units. Confirmed by looking at eleven finished frames.

## Final assembly

- `out/HWB2.mp4` — **776.57 s (12:56)**, 1920×1080, h264 yuv420p 30 fps,
  aac 48 kHz stereo, **43,930,647 bytes (41.9 MB)**.
- `verify.py`, run standalone with the speech server up: **ALL 8 CHECKS
  PASSED.** Loudness −16.3 LUFS / −1.5 dBTP. a/v drift 8.0 ms. Distinct frames
  5 of 5, control (frame vs itself) 0.00. Content gate: best-matching stage 0.33
  vs worst-matching **control** 0.04 — 9.3× separation over 6 blind windows.
  Joins: worst seam 0.2858 at t = 226.2 s against a peak-to-inverted-peak
  control of 0.9871 and an ordinary cut of 0.6111.
  ⚠ **`content` read `ok`, not `BROKEN`.** With the speech server down the
  content check reports BROKEN and shortsmith does **not** block on it, so a
  build can "succeed" at 7 ok + 1 BROKEN. The server was up and confirmed
  listening on 8000 for this run.
- The `⚠ 776.6s is OVER the 60 s Shorts limit` line is shortsmith's Shorts
  advisory and does not apply to a long-form film.
- Narration gate, per stage: **sim 0.95–1.00, every stage first-take**; brand OK
  on `00-open`; facts OK on all nine stages that carry a `factCheck` whitelist.
  ⚠ **The gate score is not sufficient** — see "Second pass" below: a stage that
  scored **1.00** was missing a word, and a stage that scored 0.95 had two real
  defects.
- ⚠ **`out/timeline.json` is written by an earlier step and went STALE** — after
  three rebuilds it still described a superseded cut, with stage starts that no
  longer matched the film. The chapter times below were computed from the actual
  `out/segments/*-mux.mp4` durations instead. Do not read chapters out of it.

### Chapters (start of each stage's narration)

Measured from the concatenated segment durations, not from `timeline.json`.

| at | stage |
|---|---|
| 0:04 | what a DAW is, who is talking, and what this part is about |
| 0:55 | samples, sample rate, blocks — and the deadline, read off the live engine |
| 1:54 | what a thread is, and the audio thread's contract |
| 2:39 | *(play)* the deadline animation |
| 3:00 | the project, and twelve seconds of it working |
| 3:46 | *(play)* twelve seconds playing **correctly** |
| 3:58 | **exactly how the broken file was made** |
| 4:57 | *(play)* the same twelve seconds, **broken** — the three clicks |
| 5:09 | why ten milliseconds of silence is loud |
| 6:05 | the rule that forbids most of programming |
| 6:50 | memory, locks, logging, waiting — why each is banned |
| 7:50 | atomic, and the counter that lost forty-five percent |
| 8:46 | *(play)* the read-add-write race animation |
| 9:09 | the fix that changed nothing, and what that meant |
| 10:06 | the audit: forty-seven sites, zero violations, six watch items |
| 11:17 | what the discipline buys — and this project's own numbers |
| 12:13 | close: what Parts 3 and 4 are |

### Every spoken figure, transcribed back and read by hand

`sim()` strips numbers by design, so a stage's figures are gated ONLY by its
`factCheck` whitelist. All thirteen stage wavs were therefore transcribed and
every number read. ⚠ **`out/vo/<stage>.txt` is written at synthesis time and the
copies on disk for `10-audit` and `11-load` predate their final re-takes** — the
verbatim lines below were re-transcribed from the FINAL wavs and from the
finished film, not read off those files. Verbatim:

| stage | what the transcribe-back heard |
|---|---|
| 01-block | `48,000 … 512 numbers … a little under 11 thousandths … 10 and a half` |
| 03-clean | `5 tracks … 228 notes at 100 beats a minute … 6 separate pieces … came out at 6` |
| 04-broken | `three separate blocks of 512 numbers … 1536 numbers changed, for each ear, out of more than half a million` |
| 05-zoom | `10.5 thousandths of a second in 12 seconds` |
| 08-counter | `eight workers … 45% of the counts` |
| 09-reattrib | `16 busy tracks … about 597 a second … nearly 1400 were due … Still about 597` |
| 10-audit | `47 of them, sorted into 8 groups … The number of violations was 0 … lists 6 things it calls watch items` |
| 11-load | `41 tracks … 14% of one processor core … under 1% of the time it had … about 23 times faster … The longest single call in 6.5 seconds … under 2%` |

## Things I could not source, and therefore cut

- **A captured, real dropout.** I have no honest way to make the engine miss a
  deadline on demand, so the film says that in as many words rather than
  implying the recording is a capture. This was the single most tempting claim
  in the part and it is the one that would have cost the most.
- **The 51 ms peak and "five late calls in twenty-three million".** A
  reset-windowed read early in the build reported `callbackCount 23,234,369`,
  `overrunCount 5`, `peakCallbackNs 51,513,083` — genuinely late calls on the
  staging app, and a lovely fact. **It is not in the film**, because that read
  RESET the counter, so nothing downstream could re-derive it, and I will not
  put a figure on screen that only exists in my own scrollback. The film uses
  the reproducible windowed measurement instead.
- **"Six watch items" was nearly cut too** (Part 1 cut it). It is in, because
  two independent counts were made in this build with a stated rule for which
  is the answer, and `measure.py` refuses to build if the header and the list
  disagree.
- **Nothing about how the tests are structured, the gate corpus, or any silent
  failure.** Those are Parts 3 and 4 and are named as such rather than spent.
- **Debug-vs-release slowdown figures (~28×).** Real and in `perf-c`, but the
  part already spends a paragraph explaining what an unoptimised build is, and
  a second number there earns nothing.

## Deliberate honesty edges

- `04-broken` states the method **before** the audio, not after, and names the
  three things I did *not* do first.
- `10-audit` closes with "one review, on one day, of the code as it stood in
  July. The program has grown since. It is evidence, not a guarantee."
- `08-counter` says the 45 % was measured **by putting the old code back**, not
  that "the test measures 45 %" — the test asserts exactness; the loss was seen
  by reverting the fix.
- `09-reattrib` is the film's one "eureka", in the sanctioned subverted form.
- `00-open` says the code was written by an AI agent working with one person,
  inside the first minute.
- The clean and broken halves are both `normalize: false`; the narration says
  "same passage, same level, nothing has been made louder", and that is true by
  construction.

## Staging restored — re-read, field for field

`restore.mjs` was run against **17695 only**. Its own stdout did not reach the
log, so — per the standing rule that a script's return is not proof — the
restore was verified by an **independent re-read**:

- `project.overview` — 4 tracks **Pad (48), Bass (80), Drums (174), Lead (16)**,
  tempo **100**, playhead **0**, `isPlaying false`, master volume **1**, loop
  **disabled**, 0–16. Identical to the reading taken before anything was built.
- `debug.panelLayout` — every field matches: `pianoRollPPB 32`,
  `pianoRollRowHeight 14`, `rowHeight 50`, `editorFraction 0.45`,
  `editorMaximized false`, `followPlayhead false`, `pianoRollMinimap true`,
  `sidebarWidth 260`, `mixerInsertsCollapsed false`, `waveformNormalize true`,
  `waveformVerticalZoom 1`, `auditionEnabled true`.
- `debug.windowFrame` — **1600×900**, never resized.
- `debug.captureUI` — Arrange view, no editor panel, no mixer, no modal,
  transport at 0. **I looked at the screenshot.**
- No lingering `node` control-socket clients (`ps` checked; none).

⚠ **One honest drift, the same one Part 1 recorded.** The session is now backed
by the copy saved before this build started
(`<scratchpad>/hwb2-staging-preexisting-2026-09-05.dawproj`). Musical content,
tempo, track set, note counts and layout are identical; only the document's
backing path changed. ⚠ **Correction to an earlier wording here:** the title
before this build was **not** "Untitled Session" — it was Part 1's own saved
file (`staging-preexisting-2026-09-05`), which is what Part 1's restore left
behind. The drift is Part-1-file → Part-2-file, not untitled → file.

⚠ **Fifteen wedged `node` clients were found afterwards, and the earlier "none"
was wrong.** The check that produced it was `ps | grep`-shaped — a match by
NAME. Re-checked **by port**, `lsof -nP -iTCP:17695` showed **15** ESTABLISHED
client sockets left open by my own `shoot.mjs`, `drive.mjs`, `probe.mjs`,
`reburst.mjs` and **`restore.mjs`** — the restore client had never exited,
exactly as the brief warned, which is why its stdout never reached the log.
Each was killed pid-exact; the re-read then showed **0** node clients with the
staging listener still up as a positive control, and `project.overview` still
reporting Pad 48 / Bass 80 / Drums 174 / Lead 16, tempo 100, playhead 0.
**The restore itself was always sound — it was verified by independent re-read,
never by the script returning.**

## Speech server

`omlx` was started from the plugin venv on port 8000 for the narration gate and
killed **pid-exact, found by port**, when the first pass finished:
`lsof -nP -iTCP:8000 -sTCP:LISTEN -t` → **69388** → `kill 69388` → port re-read
**FREE**, `ps -p 69388` gone. SIGTERM was enough; no `kill -9` was needed.
The second pass ran two of its own (**81233**, then **85634** after the final
rebuild) and each was killed to the same standard: read the pid back off the
port, match it against the pid I started, `kill`, then port re-read exit 1
(**free**) and `ps -p` exit 1 (**gone**). A pid I could not prove was mine would
have been left alone — which is exactly what I did when a sibling's server held
the port earlier.

⚠ **The final rebuild proved the trap is live.** Having killed 81233, the next
`shortsmith` run reported `[BROKEN] content: speech server unreachable` and
still **exited 0**. The build "succeeded" at 7 ok + 1 BROKEN. The server was
restarted, confirmed LISTENING by `lsof`, and `verify.py` re-run standalone
before anything was reported.

⚠⚠ **Port 8000 is shared and un-ownable, and it bit this build twice.** During
the second pass a sibling agent's server was already listening; I used it rather
than killing something I could not prove was mine. It then disappeared mid-run
and my transcriptions failed with `ConnectionRefusedError` — loud, so no result
was silently lost. I restarted one of my own (`omlx serve`, **not** `omlx
server`, which is not a subcommand and exits immediately) and confirmed it was
**listening** with `lsof`, not merely answering a `curl`.

⚠ **The dangerous failure here is the quiet one:** with the server down the
content check reports **BROKEN** and shortsmith does **not** block on BROKEN, so
a build "succeeds" at 7 ok + 1 BROKEN. Every build recorded in this file was
checked for `content: ... ok`; the final standalone `verify.py` was re-run with
the server confirmed listening.

⚠ **The character cap that Part 1 wrote down is retracted and was not applied
here.** Part 1's build hung for 20 minutes on a 1,500-character stage and
recorded a ~1,100-character cap as a law; that was re-tested afterwards on a
quiet machine and the length was innocent (38 s to speak, 1.0 s to transcribe)
— the stall was resource contention. **Nine of this part's thirteen stages are
over 1,100 characters** (the longest, `10-audit`, is 1,633) and every one
synthesised and transcribed first-take. One observation with no control is not
a law.

## Second pass — five corrections found after the film was first declared done

The film had already passed all eight checks once. Everything below was found
**after** that, by reading the script against its primary sources and by
transcribing the finished audio. None of it was caught by a gate.

### 1. A unit error in the centrepiece (`04-broken`)

Spoken: *"one thousand five hundred and thirty-six numbers changed, out of more
than a million."* **1,536 is the per-ear frame count**; the "more than a
million" is the both-ears total (1,152,000). Numerator and denominator were in
different units — the same trap Part 1 recorded.

Measured: `mix-broken.wav` is 576,000 frames per ear × 2 channels = 1,152,000
samples; the edit changes 1,536 frames per ear = 3,072 samples.
Now spoken as **"…for each ear, out of more than half a million."**
`dropout.json` now carries `differingFramesPerEar`, `channels` and
`excerptFramesPerEar` so the two counts can never be confused again.

### 2. A claim contradicted five minutes later (`04-broken`)

Spoken: *"I have no honest way to make it do that on demand."* But `09-reattrib`
describes exactly such a way — perf-c's own reproduction, an unoptimised build
with sixteen dense tracks. Reworded to say I **did not try** for this film, and
to name the documented way and where it comes up.

### 3. The audit's scope was overstated (`10-audit`)

Spoken: *"no memory requested, no lock taken, no file touched, nothing written
to a log, **on any of them**"* — of all 47 audited sites.
`docs/research/audit-rt-safety.md:111` says the zero is *"on any **Tier-1**
path"*, and the Tier-2 rows legally **do** allocate and lock — the very next
sentence of the narration names one of them. Now: *"On every one that runs on
the audio thread itself…"*

### 4. A watch item's trigger was wrong (`10-audit`)

Spoken: the plug-in reset happens *"when you press stop and never while music is
playing."* `audit-rt-safety.md:31` says it fires at *"reset edges (stop /
**un-bypass**), never per quantum"* — and un-bypassing an effect happens **while
music plays**. Now: *"when something changes — you press stop, or you switch an
effect back on — and never on every block."*

### 5. ⚠⚠ The TTS dropped and changed words, and `sim` scored it 1.00

This is the finding worth keeping. All thirteen stage wavs were transcribed in
full and every content word of ≥ 6 letters checked against the script:

- **`10-audit` never said the word "violations".** The script read
  `"Violations: zero."`; the audio says *"Each one got a verdict. Zero."* The
  word is simply absent — confirmed on the source wav, in full, with a negative
  control (`'banana' in transcript` → False). **The gate scored this stage
  `sim 1.00`**, because one missing word in ~250 rounds up. Reworded to
  *"The number of violations was zero."* and re-checked: the word is now there.
- **`11-load` said "lowest" where the script said "slowest"** — a *meaning
  inversion* on the peak-callback figure. Reworded to **"longest"**, which
  cannot be misheard the same way, and re-checked.
- **`11-load` spoke its final sentence twice**, ending *"It is the margin that
  stops the click. The margin is the margin that stops the click."* The script
  has it once. Re-synthesised; the new take's tail is clean.

That stage scored **0.95** — the lowest in the film — and the two defects are
exactly what the 0.95 was reporting. ⭐ **A passing similarity score is not a
statement that the words are right.** The transcribe-back-and-read-every-word
pass is what caught all three, and it should be standard, not optional.

Residual, checked and benign: the remaining "missing" words are Whisper writing
number-words as digits (`twelve`→`12`), spelling variants (`unoptimised`→
`unoptimized`, `favourite`→`favorite`) and `percent`→`%`.

### 6. A card that cut away from the words it displays (`11-load`)

The budget chart cut in at **702.1 s**, while the narrator was still reading
*"22.9 times faster than real time"* — a figure the **load card** is what shows.
The chart is cued by *"the picture on screen is this project"*, located at
≈ 715 s by transcribing an 8-second window. The shot list went from 4 load slots
to **6** (9 entries for the 9 slots assemble computes at `cut=6.4` for a 55.68 s
stage). Verified by pulling frames at 710 s (load card, correct) and 718 s
(chart, correct) **and looking at both**.

## ⚠ A tool finding: assemble.py's true-peak backstop cannot converge

Surfacing this rather than working around it silently.

`assemble.py`'s true-peak backstop trims the finished film by exactly
`-1.0 - tp` and **re-encodes AAC on every retry**. The trim has zero margin, so
each pass re-introduces the encoder's own intersample overshoot. On this film it
oscillated instead of converging and the build **failed**:

```
true peak   +0.60 -> trim -1.60 dB -> -0.80 dBTP  (still over — retrying)
true peak   -0.80 -> trim -0.20 dB -> -0.70 dBTP  (still over — retrying)
true peak   -0.70 -> trim -0.30 dB -> -0.90 dBTP  (still over — retrying)
true peak   -0.90 -> trim -0.10 dB -> -0.40 dBTP  (still over — retrying)
true-peak trim would not converge: -0.40 dBTP
```

Note the peak going **up** after a downward trim — that non-monotonicity is the
generation loss, and it means no number of retries would have fixed it. A film
that *did* converge would also have been through 2–4 AAC generations.

**I did not modify the shared script** — a sibling agent was mid-build against
it. The cause on this film's side was real and fixable in my own directory: the
project's own render comes out at **+0.4 dBTP / −8.1 LUFS**, and `mix-clean`,
`mix-broken` and `bed-play-arrange` all ride with `"normalize": false` (they are
the A/B; loudnorm must not touch their relative levels), so they **set** the
master's peak.

The fix is the one `assemble.play_audio`'s own docstring prescribes: **pre-gain
the pair by ONE shared static gain**. `dropout.py` now applies
`PLAY_GAIN_DB = -6.0` to the excerpt before the blocks are zeroed:

- both halves get the identical gain, so nothing in the demonstration moves
  relative to anything else, and `g × 0` is still `0` — the re-read still
  proves **exactly 1,536 differing frames** in exactly three 512-frame runs at
  the same three timestamps;
- all three files land at **−5.6 dBTP**;
- the master then lands at **−1.5 dBTP with zero trim passes**, so the shipped
  audio is a **single** AAC generation;
- nothing is compressed and nothing is made louder. `dropout.json`'s `method`
  string states the gain, so the record describes the file the viewer hears.

**A recommendation for the shared script, not applied here:** compute the trim
against a small margin (e.g. target −1.15 dBTP) so one pass lands under the
ceiling, or apply the trim to the pre-encode audio rather than re-encoding the
mp4.

## Two more numbers pinned

- **"the worst single block took under one percent"** is spoken in `11-load` and
  was not previously in `MEASUREMENTS.json`. It is verbatim in
  `docs/research/perf-c-load-profile.md`. `measure.py` now derives it as
  `loadPeakPercent`:
  `grep -o 'per-callback peaks under \*\*[0-9]* %' docs/research/perf-c-load-profile.md`
  → `per-callback peaks under **1 %`, negative control (`**99 %`) → 0 matches.
  ⚠ The obvious pattern ending in `%\*\*` matches **nothing** — the bold in the
  source spans the whole phrase, `**1 % of the real-time budget**`. It exits 1
  and looks like an absence.
  ⚠ `MEASUREMENTS.json` for **this** build predates the key: re-running
  `measure.py` plays the transport and moves the live figures the budget chart
  is drawn from, so it was deliberately not re-run for a documentation fix.
- **"one for the final mix"** — the sixth render block. The 6.00 is *measured*
  (`callbacksPerSecond / blocksPerSecond`); the attribution to a master chain is
  confirmed by `Sources/DAWEngine/PlaybackGraph.swift:344`,
  `private(set) var masterChainHost: AVAudioUnitEffect?`, in the documented
  chain `strip mixers ─► mainMixerNode ─► masterChainHost ─► outputNode`.

## A rounding stated on purpose

10.667 ms is spoken as **"ten and a half, near enough"** six times. That rounds
**down**, against the house habit of never rounding your own figures in your own
favour — here it is favourable in the sense of making the deadline sound
slightly tighter than it is. It is preceded on first use by *"a little under
eleven thousandths of a second"*, and the card and the chart both show
**10.67**. Recorded as a deliberate choice rather than left silent.

## Footage checked against a stray transport seek

A sibling agent sent `transport.seek {beats: 0}` to 17695 during this build. A
seek landing mid-recording would put the wrong bar on screen under the audio,
and **no gate can see it**. The only real app footage in this film is the
`play-arrange` burst, so its transport readout was read off the frames:

| film t | POSITION | TIME |
|---|---|---|
| 226.5 s | 1.1 | 0:00.537 |
| 234.5 s | 4.3 | 0:08.558 |
| 237.5 s | 5.4 | 0:11.577 |

8.021 s of transport across 8.0 s of film, and 11.040 s across 11.0 s —
monotonic, linear, no jump to zero. The first frame also confirms `MCP 17695`
(staging, not the user's app), tempo 100 and the five-track demo project.
**The footage is uncorrupted.**
