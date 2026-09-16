# How We Built a DAW — Part 1

**"What a DAW even is, and the one decision everything hangs on"**
1920×1080 · built 2026-09-05 · `out/HWB1.mp4`
Brief: `docs/research/design-b7-what-it-took.md` (§0 + §1 of the four-part series).

⛔ **`--finalize` was NOT run.** Nothing was copied to `~/Movies`, no publish
sidecar was written, nothing was uploaded. The `filename` in the spec is
deliberately *not* a shipped film's name.

---

## What this part covers, and what it deliberately does not

| covered | left to another part |
|---|---|
| what a DAW is: record, arrange, mix, render | the render thread, the deadline, what a missed one sounds like (**Part 2**) |
| the six modules, drawn | silent failure, the four documented cases (**Part 3**) |
| **one command surface** — the spine | falsification testing, the gate corpus (**Part 4**) |
| one command travelling the whole path | anything for a professional audience (**B7b**) |

Real-time audio is named as the hard part in one paragraph (`04-hard`) and
handed to Part 2 twice. The words "thread" and "buffer" are never used.

## Chapters

| # | stage | beat |
|---|---|---|
| 1 | `00-open` | what a DAW is · who is talking · more test than program |
| 2 | `01-tracks` | track, clip, playhead, tempo — on the real app, then playing |
| 3 | `02-clip` | a note is four numbers; the piano roll; the drum grid |
| 4 | `03-mix` | fader, decibel, effect, render |
| 5 | `04-hard` | the deadline, in one paragraph → Part 2 |
| 6 | `05-shape` | six modules, animated · socket defined |
| 7 | `06-decision` | **one command surface**, and the two counts |
| 8 | `07-converge` | **CENTREPIECE A** — a button and a message land in one function |
| 9 | `08-sound` | **CENTREPIECE B** — from that function to air |
| 10 | `09-ai` | consequence one: an AI drives it — *with the real messages on the footage* |
| 11 | `10-fader` | a fader moved by twenty-seven messages |
| 12 | `11-tests` | consequence two: testing · the measured chart · the "coffee" beat |
| 13 | `12-film` | consequence three: **this film was made through that socket** |
| 14 | `13-scale` | the whole thing, measured, and the two-month timeline explained |
| 15 | `14-close` | what Parts 2 and 3 are |

## The centrepiece

`anim_journey.py` → two bursts.

**`JourneyA`** puts the app's PLAY button and an incoming socket message side by
side and drops both arrows into one box. Every label is a real file and line,
grepped by `measure.py` and injected from `MEASUREMENTS.json`:

- `TransportBar.swift:236` — `store.transport.isPlaying ? store.stop() : store.play()`
- `Commands.swift:841` — `case "transport.play":`
- both call `ProjectStore.swift:811` — `public func play() {`
- which reaches `ProjectStore.swift:816` — `engine.startPlayback(transport)`

**`JourneyB`** carries it from there to the speaker and hands the deadline to
Part 2. I looked at `shots/journey-a-final.png` and `shots/journey-b-mid.png`.

⚠️ **A caption in the first render said "in eleven lines of Swift" — a number I
had not measured.** It was replaced with "in exactly the same function" rather
than measured, because the line count of a function with comments in it is not a
number worth defending on screen.

## The proof shot, and how its honesty is enforced

`drive.mjs` builds a project over the socket while `screenrec --app DAWApp
--scale 2.0` films the app, and **logs the exact text of every message with the
instant it was sent**. `bursts.py` composites those messages back onto the
frames.

⚠️ **The offset between the recorder and the driver is MEASURED, not assumed.**
`calibrate()` finds the frames where the track-header column changes, matches
them to the driver's own five `track.add` timestamps, and refuses to build if
they disagree by more than 60 ms.

```
calibration offsets: 3.047, 3.054, 3.049, 3.056, 3.066   spread 19 ms
```

The film says "the two agree to within twenty milliseconds", which is that
spread.

⚠️ **A bug the calibration itself caught.** The first version advanced its
dedup cursor on *every* change event, so the `clip.addMIDI` flash 0.9 s after
each `track.add` pushed the 1.5 s window past the next one and five events
collapsed to three. It failed loudly only because the count is asserted against
the driver's log — a silent version would have drawn every message about two
seconds early.

## Every number stated on screen, and the command that re-derived it

All of these are in `MEASUREMENTS.json` **with their command stored beside them**
under `_commands`; `spec.py`'s `check()` refuses to emit a spec whose spoken
figure disagrees with the measured one.

| number | command |
|---|---|
| 462 Swift files | `find Sources -name '*.swift' \| wc -l` |
| 209,766 lines of Swift | `find Sources -name '*.swift' -exec cat {} + \| wc -l` |
| 224,005 Swift test lines | same over `Tests/` |
| 15,746 / 19,973 TypeScript program / test lines | same over `mcp-server/src` and `mcp-server/test` |
| **225,512 program vs 243,978 test** | the two sums above |
| 148 check scripts | `ls scripts/gates/*.mjs \| wc -l` |
| 104 design documents | `ls docs/research/*.md \| wc -l` |
| 105 commits, 2026-07-06 → 2026-09-04, 60 days | `git log --oneline \| wc -l`, `git log --reverse --format=%ad --date=short` |
| 215 commands | `grep -o 'allCommands.count == [0-9]*' Tests/DAWControlTests/RenderCommandTests.swift` |
| 220 tools | `grep -o 'tools.length, [0-9]*' mcp-server/test/integration.test.ts` |
| **223 by naive search — wrong by 3** | `grep -c 'registerTool(' mcp-server/src/server.ts` |
| 16,991 DAWControl lines, 8.1 % of the program | `find Sources/DAWControl …`, ÷ 209,766 |
| per-module line counts on the diagram and card | `find Sources/<module> …` |
| TransportBar 236 / Commands 841 / ProjectStore 811 / 816 | `grep -n` on each file (see `measure.py:where`) |
| 5 tracks, 228 notes, 100 BPM, lead 28, drums 96 | `ids.json`, written by `material.mjs` as it created them; confirmed by `clip.getNotes` |
| −1.4 dB drums, −11.1 dB pad | read off `shots/app-mixer.png`, which is on screen while they are spoken |
| 27 `track.setVolume` messages, ~1 per tenth of a second | `drive.mjs` (`N = 26`, step 0.115 s) |
| 20 ms agreement | `bursts.py` calibration, printed above |

## The "eureka" beat — one, and it is Part 1's own

Per the brief's §"The 'eureka' beat": the coffee is subverted, not performed,
and **only one** is used, because Part 3 owns the anecdotes.

The one used is Part 1's own material rather than borrowed from Part 3's list:
counting the command surface. `grep -c 'registerTool('` says **223**; the test
that pins the surface says **220**. I measured both while writing this film.
That is why every count in the film comes from a pin and not a search.

## Things I could not source, and therefore cut

- **"0 violations, 6 watch items"** from the RT-safety audit. `Violations: 0` is
  in `docs/research/audit-rt-safety.md:111`; I did not verify the "6" and the
  whole subject is Part 2's, so the paragraph is one sentence with no numbers.
- **`chart-history.png`** was built and is retained, but **is not in the film**.
  It is honest — 105 commits, one week of 56 and eight weeks of 2–12 — but the
  56 invites a question ("why?") I cannot answer on screen from the record, and
  a chart that raises an unanswered question in a film about measurement is a
  liability. Kept in the build chain; not referenced by `spec.py`.
- **The word "commit"** is defined in `13-scale` rather than assumed, per the
  brief's rule about terms of art.
- **No claim about how many people worked on it beyond "one person"**, and no
  claim about hours spent — neither is in the record.

## Deliberate honesty edges

- The hook is stated the **hard** way. Swift tests (224,005) beat Swift program
  (209,766), but so does the whole-project comparison once the TypeScript is
  counted on **both** sides — 243,978 against 225,512. The film quotes the
  whole-project figures, and `chart-code.png` shows both languages on both bars.
- `12-film` says explicitly that the **voice is a local speech model** and the
  **editing is ordinary video tools**, so "this film was made by the thing it
  describes" cannot be read wider than it is true.
- `00-open` says the code was written by an AI agent working with one person, in
  the first thirty seconds, and `13-scale` says why it is said up front.

## Build chain

```
material.mjs   → builds the demo project over the socket (5 tracks, 228 hand-written notes), writes ids.json
shoot.mjs      → app stills via debug.captureUI
drive.mjs      → the proof shot's driver; writes drive-log.json          (film with screenrec in parallel)
measure.py     → MEASUREMENTS.json, every figure with its command
anim_modules.py / anim_journey.py  → the manim scenes
bursts.py      → calibrate + composite + explode everything into bursts/  → bursts.json
beds.py        → one audio bed per burst, EXACTLY its length
charts.py      → chart-code.png (used) and chart-history.png (not used)
spec.py        → HWB1.json, refusing to build on a numeric disagreement
shortsmith.py HWB1.json --out-dir out --size 1920x1080
restore.mjs    → puts staging back and re-reads to prove it
```

Re-run order after any source change: `measure.py` → `bursts.py` → `beds.py` →
`charts.py` → `spec.py` → `shortsmith.py`.

## Staging hygiene

- Everything ran against **17695**. Port 17600 (the user's live app) was not
  listening at any point during this build and was never addressed;
  `build.mjs` refuses it and `material.mjs` asserts the port itself.
- The session that was already open on staging (4 tracks, Pad/Bass/Drums/Lead,
  100 BPM) was **saved first** to the session scratchpad as
  `staging-preexisting-2026-09-05.dawproj`, and `restore.mjs` reopens it.
- The window was **not** resized: it was already 1600×900 and `debug.windowFrame`
  was only ever read.
- Panel layout was read bare before anything was set; the read values are in
  `restore.mjs`'s header and are what it writes back.
- The `omlx` speech server was started on port 8000 for the narration gate and
  killed pid-exact, found by port, afterwards.

---

## Second pass — five things found by looking, after the first assembly

Recorded in the order they were found. Every one of them was invisible to the
build's own return code: the first assembly reported `[ ok ]` on all seven
verify checks.

1. **A narration line was false by my own measurement.** `05-shape` said
   "about sixteen thousand lines … under eight percent of the program".
   DAWControl is 16,991 lines of 209,766 = **8.10 %**, which rounds to
   *seventeen* thousand and is *over* eight percent. Worse, the spec's own
   assertion passed, because it checked `8.1 == 8.1` — a number the narration
   never said. The check now tests the **spoken form**:
   `8.0 < share < 9.0` and `16_500 <= lines < 17_500`. Line is now
   "about seventeen thousand … just over eight percent".

2. **A unit was wrong.** `09-ai` said the drum clip message carried "ninety-six
   **numbers**", four minutes after `02-clip` defined a note as *four* numbers.
   96 notes is 384 numbers. Now "ninety-six notes", which is also what the
   burned-in wire text on that very shot says.

3. **The footage did not reach the line that describes it.** The narration ends
   "Then the playhead starts moving," but the `drive-build` burst was cut at
   driver t=15.4 and `transport.play` fires at 14.2 — 1.2 s of playhead. The
   burst now runs to t=20.8 (19.57 s, 549 frames, 28.05 fps measured), so the
   playhead moves for ~6 s. Calibration re-ran and still agrees to **19 ms**.

4. **A card left the screen before the numbers it holds were spoken.**
   `13-scale` held card 10 for ~13 s of a 44 s stage while the figures run to
   ~45 % of it; `11-tests` dropped the chart before the line that reads it.
   Both shot lists were re-weighted. Shot lists are not part of the narration
   cache key, so this cost nothing to fix.

5. **The centrepiece caption ran under the burned-in meter avatar.** manim knows
   nothing about the corner meter shortsmith burns in afterwards, so
   "That is the whole decision. Everything else follows from i|▮▮▮" was
   the actual rendered result. `anim_journey.py` now routes every caption
   through `_place_cap()`, which keeps its right edge at x ≤ 4.4 manim units
   and re-checks the left edge. **Nothing measured this — I looked at it.**

Also tightened for the same reason as (1): "Fifteen thousand more lines of
TypeScript" for 15,746, spoken while the card on screen prints `15,746`, is now
"just under sixteen thousand". A film whose thesis is that a plausible number
is the dangerous kind should not round its own figures down.

### An operational stall, and the wrong law I nearly left behind

The first build **hung for 20 minutes at 0 % CPU** on `11-tests`. VoxCPM
synthesised a 67-second, 6.47 MB wav in 77.8 s, and the Whisper transcribe-back
that gates it never returned. Both processes idle, no error, no timeout — the
classic shape. `SIGTERM` did not end the server; `kill -9` on that exact pid did.

I blamed the stage: it was the longest narration in the film (~1,500 characters),
it was the only one that hung, and I wrote "cap a stage at about 1,100
characters" into these notes as a law for the next film.

⛔ **That law was wrong, and it is retracted.** The project owner supplied the
missing fact: **another session was loading a model into the GPU at that moment**,
and the memory surge is what stalled the server. So I ran the experiment I should
have run before writing a rule — re-synthesised a **1,432-character** text, the
same shape and length as the stage that hung, on a quiet machine:

```
chars: 1432
TTS   ok    38.0s  5.58 MB
STT   ok     1.0s  1306 chars
sim(prose): 0.998      has 223 / 220 / 148 / "coffee": all True
```

**38 s to speak and 1.0 s to transcribe** — against 77.8 s and never. The length
was innocent **of the stall**; there was contention for the GPU.

⚠️ **AMENDED after the fact, and the amendment matters.** Length is innocent of
the *stall*. It is **guilty of something else**, which I had not measured when I
wrote this section and which the viewer heard before any instrument here did —
see *The wash in the pauses* below. Two true statements that sound like
contradictions: a long stage does not hang the speech server, and a long stage
does come back with a rising noise floor. Do not read the stall retraction as a
clean bill of health for long takes.

⭐ The general shape, which is this project's characteristic failure mode from a
new angle: **a stall gives you a correlation and no mechanism, and the longest
item is always the most tempting thing to blame.** One process's symptom was
another process's memory. I had a plausible cause, one confirming instance, and
no control — and I was one commit from installing it as a rule that would have
shortened every future stage for no reason.

**The split of `11-tests` into `11-tests` + `11b-count` stays, but on editorial
grounds only, and the notes now say so:** the anecdote gets its own card instead
of sharing one, and the card-on-screen timing is better for it. It is not a
workaround for a limit that does not exist.

6. **A shot list is timed by `cut`, not spread evenly across the stage.** I
   assumed even distribution when I wrote the lists; shortsmith advances the
   still every `cut` seconds and then holds or cycles. With `cut=6.4` and two
   lead + two drum stills, "This is the lead melody. Twenty-eight notes" landed
   at 17.2 s — on the **drums** grid. Three lead stills carry it to 19.2 s.
   Verified by pulling the frame again: 28 notes is now over the Lead piano
   roll, 96 notes over the Drums step grid.

## Final assembly

⚠️ **SUPERSEDED by the fourth cut** (see *The wash in the pauses*). The duration,
size, loudness and chapter times below are the **third** cut's and are kept as
the record of what was measured then. The shipped film is 787.37 s.

- `out/HWB1.mp4` — **764.47 s (12:44)**, 1920×1080, h264 yuv420p 30 fps,
  aac 48 kHz stereo, 42.7 MB (44,782,704 bytes).
- verify.py: seven checks, all `[ ok ]`. Loudness −16.4 LUFS / −1.5 dBTP.
  Content gate: best-matching stage 0.37 vs worst-matching **control** 0.04
  — a 9.7× separation over 6 blind windows.
- The `⚠ 764.5s is OVER the 60 s Shorts limit` line in the log is shortsmith's
  Shorts advisory and does not apply to a long-form film.
- Narration gate, per stage, all first-take: sim 0.94–1.00, brand OK, facts OK.

### Chapters (start of each stage's narration)

⚠️ Third-cut times. **The shipped chapter times are in the table below**, under
*Chapters, as shipped*.

| at | stage |
|---|---|
| 0:04 | what a DAW is, who is talking, and the number that started it |
| 0:54 | tracks, clips, the playhead |
| 1:50 | inside a clip: notes, the piano roll, the drum grid |
| 2:39 | mixing, faders, decibels, effects, rendering |
| 3:25 | where the difficulty actually is (and that it is Part 2) |
| 3:59 | the six parts, and what a socket is |
| 5:23 | the decision: one command surface |
| 6:05 | following one command — two callers, one function |
| 7:01 | …and then it makes a sound |
| 7:53 | consequence one: an AI can operate it (the proof shot) |
| 8:59 | a fader moving with no hand on it |
| 9:25 | consequence two: it can be tested with nobody clicking |
| 9:57 | the counting anecdote (223 vs 220) |
| 10:29 | consequence three: this film is made through that socket |
| 11:14 | the numbers, and the two-month timeline |
| 12:04 | close, and what Parts 2 and 3 are |

## Staging restored — re-read, field for field

`restore.mjs` was run against **17695 only**. It hung after doing its work (see
below), so the restore was verified by an independent re-read rather than by the
script's own report:

- `project.overview` — 4 tracks **Pad, Bass, Drums, Lead**, tempo **100**,
  playhead **0**, master volume **1**, `isPlaying false`, loop disabled.
- `debug.panelLayout` — every recorded field matches: `pianoRollPPB 32`,
  `pianoRollRowHeight 14`, `rowHeight 50`, `editorFraction 0.45`,
  `editorMaximized false`, `followPlayhead false`, `pianoRollMinimap true`,
  `sidebarWidth 260`, `waveformNormalize true`, `waveformVerticalZoom 1`,
  `mixerInsertsCollapsed false`, `auditionEnabled true`.
- `debug.captureUI` — window rect **1600×900** (never resized), Arrange view,
  no editor or mixer panel open, no modal. I looked at the screenshot.

⚠️ **One honest drift.** The session is now backed by the copy I saved before
starting (`<scratchpad>/staging-preexisting-2026-09-05.dawproj`), so the window
title reads `staging-preexisting-2026-09-05` rather than whatever the untitled
in-flight document was called. The musical content, tempo, track set and layout
are identical; only the document's backing path changed.

### Two orphaned clients were blocking the socket

While restoring I found **two `node restore.mjs` processes from the
`lessons/bach-house` rebuild still connected to staging after 1 h 52 m**, wedged.
They were the reason my own restore never returned. I killed those two node
clients (pid-exact: 33677, 34030, and their shells) — **not the app**. Staging
answered normally afterwards, in under a second.

⚠️ Worth carrying forward: a hung control-socket client from a *finished* agent
looks exactly like a hung app.

## Speech server

omlx was started for the narration gate and killed **pid-exact by port** when the
build finished: `lsof -nP -iTCP:8000 -sTCP:LISTEN` → pid 58373 → `kill 58373` →
port re-read **FREE**, pid gone. (An earlier instance, pid 29038, had to be
`kill -9`'d: it had wedged inside Whisper and ignored SIGTERM.)

## Third pass — the still timer, and every spoken figure transcribed back

### The narration gate does NOT check the numbers you did not whitelist

`sim()` in shortsmith deliberately **strips numbers and number-words** before
comparing ("Similarity over prose only"), because the channel spells figures out
and Whisper writes digits. That is correct — but it means a stage's numbers are
checked **only** by its `factCheck` whitelist. `13-scale` scored 0.95 while
naming nine figures of which three were whitelisted.

So I transcribed **all sixteen** stage wavs back through Whisper and read every
number myself. All correct, verbatim from the transcripts:

| stage | what the transcribe-back heard |
|---|---|
| 00-open | `225,000 lines of program … 244,000 lines of code` |
| 01-tracks | five tracks, `100 beats per minute` |
| 02-clip | four numbers, `28 notes`, `96 notes` |
| 03-mix | `minus 1.4`, `minus 11` |
| 05-shape | `about 17,000 lines out of 210,000, just over 8% of the program` |
| 06-decision | `215 commands on the socket, and 220 tools` |
| 07-converge | `line 236`, `line 811` |
| 09-ai | `within 20 milliseconds`, `96 notes` |
| 10-fader | `27 of them, about one every tenth of a second` |
| 11-tests | `225,000 … 244,000 … 148 separate check scripts` |
| 11b-count | `search says 223 … real number is 220 … counting three things` |
| 12-film | `five tracks, 228 notes` |
| 13-scale | `462 Swift files. 209,766 lines … just under 16,000 … 215 … 220 … 148 … 104 … 105 … 105 … 60 days, from the 6th of July to the 4th of September` |

Transcripts are kept beside the audio as `out/vo/<stage>.txt`.

### The still timer is not what I assumed — twice

Read out of `assemble.py::Film.stills` rather than inferred:

```
n = max(1, round(total / cut));  each = total / n
holdLast -> seq = [shots[min(i, len(shots)-1)] for i in range(n)]
```

`cut` is a **nominal** period rounded to fit the stage, and with `holdLast` the
shot list is **clamped**, so entries past slot `n-1` are never shown at all. I
guessed "evenly across the stage" first and "one still every `cut` seconds"
second, and both guesses put the wrong picture under "This is the lead melody.
Twenty-eight notes."

Fixed by measurement, not by another guess: `silencedetect -42 dB d=0.10` on
`out/vo/02-clip.wav` puts the pause after "…lead melody." at 17.93–18.05 s, so
the phrase runs 18.05 → ~19.35. With `total 38.08 / cut 3.5` → `n = 11`,
`each = 3.462`, and six lead stills, the lead roll holds to **20.77 s**. Frames
pulled at 18.06 and 20.06 both show the Lead piano roll; 21.66 and 30.06 show
the Drums grid. **I looked at all four.**

⚠️ The vo wav and the talk segment are the same length (38.080 vs 38.080), so
stage-relative time and vo time are interchangeable here. Check that before
reusing this method — a stage with lead-in padding would not be.

### Final artifact

`out/HWB1.mp4` — 764.47 s, 44,782,704 bytes (42.7 MB); re-measured
after the 02-clip fix. verify.py re-run **with the speech server up**:
**ALL 7 CHECKS PASSED**, content separation 9.7×.

⚠️ Note for the next build: with omlx down, shortsmith's content gate reports
`[BROKEN]` and **does not block**. Two of my intermediate builds shipped with a
BROKEN content line. The final one was verified separately with the server
running.

### Staging markers

`marker.list` on staging returns `{"markers":[]}` — none, which is also what the
saved before-state contains (it is the same file reopened), so nothing to
restore there.

### One more honesty edge

`12-film` says "Every moving shot was made by sending it messages and filming
what happened." In context that is about the app, and it is exactly true of
every shot **of the app**. The six-parts and journey diagrams are moving shots
that were rendered in manim, not filmed off the app — the same paragraph says
so ("the cutting together is done with ordinary video tools"), but the sentence
is scoped by context rather than by its own words.

Also worth a line: a/v drift moved from 1.7 ms to 28.3 ms between the first and
later assemblies. Both pass (under one frame at 30 fps = 33.3 ms), but it is
most of a frame and it moved, so it is written down rather than glossed.

## Killing the speech server (the command, for the record)

Pid-exact **by port**, never `pkill`/`pgrep` — those match by name and this
machine runs other Python servers:

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN                       # who is there
kill $(lsof -nP -iTCP:8000 -sTCP:LISTEN -t)            # kill exactly that pid
lsof -nP -iTCP:8000 -sTCP:LISTEN || echo "8000 FREE"   # PROVE it — a no-op kill is silent
```

`kill -9` only if `SIGTERM` is ignored, and only on that same pid. Instances
started and killed this way during this build: 29038 (needed `-9`, wedged in
Whisper), 58373, 63336, 64117, 64864, 67199. Port re-read free after each.

⛔ 17600 is the live app and is never touched. Staging is 17695.

## The wash in the pauses (the fourth cut)

The user, listening to the finished film, said: *"there is some kind of
background self-feeding echo if narration goes too long."* No gate in this
pipeline had anything to say about that. `sim()` scored the affected takes
0.94–1.00, the brand and fact gates passed, verify.py's loudness check read
−16.4 LUFS / −1.5 dBTP, and the content gate separated 9.7×. **Every instrument
in the build said the audio was healthy.** It was not.

### What it actually is, measured

The difference between an affected take and a clean one is not in the voice. It
is in the **silence**. Chop a take into fifths, take the 10th percentile of
20 ms RMS frames inside each fifth — the *gap floor*, how quiet the quiet parts
are — and a clean take holds its floor while an affected one climbs.

The controlled pair was already on disk from the stall investigation: the **same
1,432 characters**, once as one take and once as the two stages `11-tests` +
`11b-count`.

| | length | gap floor per fifth (dBFS) | rise |
|---|---|---|---|
| 1,432 ch, **one** take | 58.1 s | −50.3 −42.2 −33.1 −28.8 −28.3 | **+22.0 dB** |
| 715 ch, take A | 31.7 s | −45.4 −50.3 −49.3 −43.2 −41.8 | +3.6 dB |
| 716 ch, take B | 31.5 s | −42.1 −68.6 −46.9 −47.1 −40.3 | +1.8 dB |

Identical words. The pauses in the long take end up ~21 dB under the voice; in
the split takes they stay 34–41 dB under.

⚠️ **This is a correlation and a proxy, not a mechanism.** Nothing here shows
*why* the floor climbs. "Self-feeding echo" is the listener's name for the
sound, and it is a good one, but I have not demonstrated feedback. What is
established: it tracks take length, and splitting removes it.

⚠️ **And it is not deterministic**, which is why a chunk size alone would not
have been a fix: `12-film` is 1,093 characters and clean (ends −42.8), while
`07-converge` is 848 and affected (ends −27.8).

### The budget is measured, not chosen

The worst stage — `05-shape`, 1,134 characters, ending at **−26.9 dB** — was
re-synthesised at three chunk budgets on the same server, same reference voice:

| budget | chunks | gap floor per fifth | sim | synth |
|---|---|---|---|---|
| one take | 1 | −73.6 −48.5 −42.8 −32.4 **−26.9** | 0.94 | 38 s |
| 600 | 2 | −49.4 −45.4 −48.9 −51.6 **−37.4** | 0.951 | 32 s |
| 400 | 4 | −47.6 −49.6 −54.1 −53.2 **−49.3** | 0.934 | 34 s |
| **300** | 5 | −68.6 −63.1 −51.1 −59.4 **−60.9** | 0.951 | 33 s |

Transcribe-back similarity is unchanged and **splitting is not slower** — five
short requests cost less wall clock than one long one. 300 is what the pipeline
now uses.

### What changed in `scripts/video/shortsmith.py`

- `synth()` splits on sentence boundaries, packs **evenly** (`len/n`, not
  greedy — greedy at 400 produced chunks of 372/344/353/**62**, and a 62-char
  chunk synthesised alone is a different prosody problem), **merges any chunk
  under 110 characters into its smaller neighbour**, trims each chunk's own
  lead-in/tail at −45 dBFS with 60 ms of pad, and joins with a 0.30 s gap.
  An assertion checks the chunks rejoin to the original **word for word**.
- `echo_floor()` is the measurement, and `narrate()` uses it as a **take
  preference, not a veto**: accept immediately on a take that passes everything,
  otherwise keep the quietest-pauses take among those that passed the word
  gates and *say what it measured*. A veto would have reported an echo miss as
  a `factCheck` failure, which is a lie about what went wrong.
- `vo_key()` now includes the synthesis method. Without that, turning chunking
  on kept every echo-era take in the cache and **the fix would have shipped to
  nothing**.
- ⚠️ **A `for`/`else` stopped meaning what it said.** The take loop ended in a
  `for … else:` that fired the "none of the takes satisfied the gates" exit.
  Inserting a second `for` above it silently rebound the `else` to the *cleanup*
  loop — which always completes — so it would have exited on **every stage with
  a `factCheck`**. Caught by reading the patched region, not by a test. It is
  written out as an explicit `if` now, with the reason.

⚠️ **Chunking is OFF by default** (`CHUNK_DEFAULT = 0`). Enabling it changes
`vo_key` and therefore re-records every cached take of every film. This film
opts in with `VO_CHUNK_CHARS=300`; a sibling agent was mid-build on another film
when this landed, and invalidating its cache underneath it was not mine to do.
Flipping `CHUNK_DEFAULT` to 300 makes it universal when no build is in flight —
**the five rebuilt lesson films are 600–1,000 characters a stage, which is
exactly where this table turns**, so they very likely carry it too.

### Before and after, all sixteen stages

`echo_check.py` (retained, in this directory) prints the table and exits
non-zero on any stage over the threshold. Threshold: last fifth at or below
−38.0 dBFS — known-clean takes measure −40 to −60, known-affected −24 to −35.

Controls, both run: `longstage.wav` (1,432 ch, one take) reads **−28.4 → FAIL**;
`11-tests.wav` reads **−41.7 → PASS**. The metric discriminates the pair it was
built on.

⚠️ **THE FIRST VERSION OF THIS TABLE WAS FLATTERED BY THE FIX ITSELF, and the
correction is the interesting part.** `synth()` joins chunks with 0.30 s of
*exact zeros*, which score −180 dB, so the chunked takes were being credited for
silence **this pipeline had just inserted** — the measurement rewarding the
thing it was meant to judge. Fifths reading −88.5, −81.2, −80.1, −78.5 gave it
away: no neural vocoder output reaches −100 dBFS in 16-bit, only a run of exact
zeros does. `echo_floor()` now drops frames at or below −100 dB before taking
the percentile. Numbers below are the **filtered** ones.

The before-column is the control: it has no inserted joins, so the filter should
barely move it. It moves by **at most 1.3 dB** (11b-count −40.6 → −39.5) — from
lead-in/tail zeros in the original wavs — and no verdict changes. The
after-column moves by up to **10 dB** (09-ai −67.2 → −57.5, 05-shape −53.9 →
−48.6), which is exactly the flattery being removed.

| stage | before (last fifth) | after | | stage | before | after |
|---|---|---|---|---|---|---|
| 00-open | −34.7 WASH | **−49.6** | | 08-sound | −57.9 ok | −88.3 |
| 01-tracks | −33.5 WASH | **−50.8** | | 09-ai | −24.0 WASH | **−57.5** |
| 02-clip | −31.2 WASH | **−47.2** | | 10-fader | −42.1 ok | −41.6 |
| 03-mix | −29.7 WASH | **−54.9** | | 11-tests | −41.7 ok | −48.4 |
| 04-hard | −40.0 ok | −54.6 | | 11b-count | −39.5 ok | −51.0 |
| 05-shape | −26.9 WASH | **−48.6** | | 12-film | −41.5 ok | −47.0 |
| 06-decision | −36.2 WASH | **−46.8** | | 13-scale | −35.1 WASH | **−50.3** |
| 07-converge | −27.7 WASH | **−53.4** | | 14-close | −60.5 ok | −58.5 |

**7/16 → 16/16, and it survives the correction.** Every stage that was affected
improved by 12–33 dB; the worst last-fifth went from −26.9 to −41.6 (10-fader,
which was never affected). No stage climbs across its fifths any more.

⚠️ One stage got very slightly *worse* on this metric — 10-fader, −42.1 → −41.6,
0.5 dB, on a take that passed before and passes after. That is inside the
run-to-run spread of the measurement and is not a regression; it is recorded
because reporting only the improvements would be picking.

The take-1 film is kept as `out/HWB1-take1-echo.mp4` so the difference can be
heard rather than read.

### Re-verified after re-narrating, because every stage's length changed

Re-narrating invalidates timing work that was verified once. All of it was
redone against the **new** audio, not carried over:

- **Every stage transcribed back from the wav that is in the film** (not the
  take-time transcript): sim 0.943–1.000, brandCheck true, `missingFacts []`
  for all sixteen.
- **Every spoken figure hand-checked** against the transcripts, because `sim()`
  strips numbers and `factCheck` is a whitelist. 225,000 / 244,000 · 100 bpm ·
  28 · 96 · −1.4 / −11 · 17,000 of 210,000 / 8% · 215 / 220 · line 236 /
  line 811 · 20 ms · 96 · 27 · 148 · 223 vs 220 · 228 · 462 / 209,766 /
  16,000 / 215 / 220 / 148 / 104 / 105 / 60 days / 6 July–4 September. All
  correct.
- **The `02-clip` still timer re-measured.** Talk beat 39.03 s, `cut=3.5` →
  n = round(11.15) = 11 slots of 3.548 s; `[lead]×6 + [drums]×5` puts the Lead
  roll on 0–21.29 s. Transcribing the vo in windows puts "This is the lead
  melody. 28 notes." at 16.1–18.6 s and the drums sentence starting 18.77 s, so
  both lead figures land on the Lead roll and "96 notes" (≈29 s) on the Drums
  grid. Confirmed by pulling the frames.
- **`09-ai` was wrong and is fixed.** Talk 49.48 s, `cut=6.4` → 8 slots of
  6.185 s. Transcribing the *film's* audio in 6 s windows put "Watch the tracks
  arrive" at 39 s (slot 6, the app — right) and "ninety-six notes for the drums,
  **and the app draws them**" at 45 s (slot 7, a **card** — wrong). The
  four-entry cycling list was written out to eight so the app holds slots 6–7
  and hands straight to the play beat. Frames at 524.0 / 529.5 / 531.5 / 533.0 s
  re-pulled: **the app is on screen for all four. I looked at them.**
- **The 26 number moments re-pulled as a 4×4 contact sheet and read.** The
  `243,978` card, the Lead roll under "28 notes", the Drums grid under
  "96 notes", the mixer under the fader figures, the six-parts list with
  DAWControl highlighted, the 215/220/223 card, the two-callers diagram with
  `TransportBar.swift:236` and `ProjectStore.swift:811`, the program-vs-tests
  bar chart, and the "measured today" card with 462 / 209,766 / 15,746 / 148 /
  104 / 105.
- **The chart's own date stamp re-checked.** `charts.py` stamps
  `dt.date.today()`, so the caption now reads *measured 2026-09-05* while the
  figures were taken on the 4th. Rather than assume, `measure.py` was re-run:
  every figure is byte-identical today (462 / 209,766 / 224,005 / 105 /
  lastCommit 2026-09-04 / `ls docs/research/*.md` = 104), so the stamp is true.
  ⚠️ A bare `find docs -name '*.md'` gives **121** — the film's 104 is
  `docs/research/*.md` specifically, which is what `MEASUREMENTS.json` records
  as the derivation.

### Final artifact (fourth cut)

`out/HWB1.mp4` — **787.37 s (13:07)**, 1920×1080 h264 yuv420p 30 fps, aac
48 kHz stereo, **46,073,818 bytes (43.9 MB)**. 23 s longer than the third cut,
because chunk joins add a measured 0.30 s of silence at each of ~60 seams.

verify.py, **with the speech server up**: all seven `[ ok ]`. Loudness
−16.3 LUFS / −1.5 dBTP. a/v drift 28.3 ms (under one frame). Content gate:
best-matching stage 0.34 vs worst-matching **control** 0.03 — **10.2×**
separation over 6 blind windows.

⚠️ The speech server was killed pid-exact by port, but note what happened
mid-build: **a sibling agent's omlx died under me** and `build6.log` ends in
`Connection refused` after six stages. Those six stages were already cached and
were not re-recorded. The port is shared and un-owned; if two film builds run at
once, one can take the other's speech server away.

### Chapters, as shipped

Derived from `timeline.json`, which is regenerated from `out/segments/_all.txt`
by `ffprobe`-ing each segment in order — not from the estimates in the spec.

| at | stage | chapter |
|---|---|---|
| 0:04 | `00-open` | what a DAW is, who is talking, and the number that started it |
| 0:54 | `01-tracks` | tracks, clips, the playhead |
| 1:52 | `02-clip` | inside a clip: notes, the piano roll, the drum grid |
| 2:42 | `03-mix` | mixing, faders, decibels, effects, rendering |
| 3:31 | `04-hard` | where the difficulty actually is (and that it is Part 2) |
| 4:06 | `05-shape` | the six parts, and what a socket is |
| 5:30 | `06-decision` | the decision: one command surface |
| 6:13 | `07-converge` | **centrepiece** — two callers, one function |
| 7:11 | `08-sound` | …and then it makes a sound |
| 8:04 | `09-ai` | consequence one: an AI can operate it (the proof shot) |
| 9:13 | `10-fader` | a fader moving with no hand on it |
| 9:40 | `11-tests` | consequence two: it can be tested with nobody clicking |
| 10:13 | `11b-count` | the counting anecdote (223 vs 220) |
| 10:44 | `12-film` | consequence three: this film is made through that socket |
| 11:34 | `13-scale` | the numbers, and the two-month timeline |
| 12:24 | `14-close` | close, and what Parts 2 and 3 are |

Total 787.34 s of segments; the muxed file measures 787.37 s.

### Two narration paths, and this fix reaches one of them

`grep -ln "v1/audio/speech" plugins/narrated-film/scripts/*.py scripts/video/*.py`
returns **three** files, not one:

| file | who uses it | chunked? |
|---|---|---|
| `scripts/video/shortsmith.py` | this film **and all five lesson films** (`$V ../../shortsmith.py L8v2.json …`) | **yes**, on opt-in |
| `plugins/narrated-film/scripts/narrate.py` | the plugin's own standalone pipeline (`install.sh`, `README.md`) | **no** — separate `synth()` at line 86 |
| `plugins/narrated-film/scripts/design-voice.py` | voice-design tool, not a film path | no |

So: the lesson films **are** on the fixed path and will regenerate clean the
moment they are rebuilt with `VO_CHUNK_CHARS=300` (they are 600–1,000 characters
a stage, right where the table turns). The plugin's `narrate.py` is a **second,
independent copy of the same synthesis step and is not covered** — porting
`split_for_synth`/`echo_floor` into it is outstanding work, not something this
build did.

### What has NOT been listened to

Each stage now has 2–4 **seams**. At a seam the floor drops to *digital silence*
for 0.30 s and the next chunk restarts with utterance-initial prosody. Neither
is visible to transcribe-back, to `sim()`, or to the loudness gate — and
`echo_floor()` now deliberately ignores those frames, so it cannot see them
either. Every TALK beat sits over a ducked bed, which masks a 0.30 s zero-gap by
construction, but **masked is not checked**. If anything sounds off in the new
cut, the seams are where to point an ear first. That is the one claim in this
document with no instrument behind it.

## Independent verification by the orchestrator — 2026-09-05

Not the building agent's own report; re-measured from `out/HWB1.mp4` directly.

| check | measured | how |
|---|---|---|
| duration | **787.37 s (13:07)** | `ffprobe format=duration` |
| container | 1920×1080, 30 fps, h264 + aac 48 kHz stereo | `ffprobe show_entries stream` |
| integrated loudness | **−16.3 LUFS**, LRA 2.2 LU | `ffmpeg -af ebur128 -hide_banner` (NOT `-v error`, which hides the summary) |
| true peak | **−1.5 dBFS** | same |
| narration content gate | 16/16 stages STT score **1.0**, `verifyFails: []` | `out/build-report.json` |
| the picture MOVES | mean inter-frame luma delta **0.1489** over a 20 s window | `tblend=all_mode=difference,signalstats` |
| ⭐ negative control for the above | a genuinely still video of one of its own frames scores **0.0008** — 186× lower | same filter over a `-loop 1` still built from frame @120 s |

Frames inspected by eye at 5 / 120 / 300 / 480 / 700 s: real app capture (piano
roll pointed at its notes, not an empty grid), manim panels, and the restyled
narrow-bar meter present bottom-right on the body but not on the intro.

One cosmetic nit, not worth a re-render: in the "…and then it makes a sound"
panel the travelling green dot passes over the DAWEngine card's caption and
briefly occludes a word.
