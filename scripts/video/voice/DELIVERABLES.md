# Voice film: what is final (2026-10-11)

Tags: **MEASURED** = measured by me on the named file; **READ** = read from the app's own echo or
source; **INFERRED** = my reasoning, not measured.

## Final files (all under `scripts/video/voice/`)
| What | Path |
|---|---|
| The film: 331.9 s (5:32), 1920x1080, 30 fps, h264 + AAC 48 kHz (MEASURED, ffprobe) | `out/voice-film.mp4` |
| A/B timeline (8 halves) | `out/voice-film.mp4.timeline.json` |
| Intro 3.5 s / outro 5.0 s cards | `out/brand/intro.mp4`, `out/brand/outro.mp4` |
| Narration takes (16), one cloned voice | `vo/*.wav` |
| Manifest (script, cuts, A/B pairs) | `manifest.json` |
| Build scripts | `*.mjs`, `*.py`, `*.sh`, `tools/`, with `takes.json` the one table for cuts and takes |
| How to rebuild | `README.md` |
| Draft YouTube metadata (NOT uploaded) | `publish/voice-film.json`, `publish/chapters.txt` |
| Gate evidence | `logs/verify.log`, `work/content-gate.json`, `work/ab-equality.json`, `work/film-motion.json`, `work/measure/summary.json`, `loops/cuts.json` |

**Superseded, kept rather than deleted:**
- `out-superseded-2026-10-11-twinkle/` holds the first build on "Twinkle Twinkle" (its base builder, material, sheet echoes, project and stills). The user said no nursery tunes. Its replacement is the original song "Light On", composed on camera (`material.mjs`, `build-song.mjs`).
- `work/vo-superseded/voice-said-1dB.wav` is the first Voice-tool narration take. It said "about one decibel quieter", and that is wrong for the voice: −4.4 LU (MEASURED: −19.1 → −23.5 LUFS on the line-4 vocal). It was re-spoken as "the voice alone by about four decibels, the whole song by just over one" (song excerpt −1.3 LU, MEASURED).
- `work/bursts-superseded-move-tool/` holds the first Voice A/B screen takes. With the Move tool active, no Voice marks are drawn, so both halves showed the same picture. The re-recorded takes use the Voice tool: BEFORE shows 0 marks and AFTER shows 9 "Deeper 6.0" marks (READ from the echo, and seen in `bursts/voice-*/prep.png`).

## Chapters (start times MEASURED from the concat list's part durations)
| Start | Chapter | What it shows |
|---|---|---|
| 0:00 | Intro + "where we're headed" | Brand card, then the finished arrangement playing: drums, bass, pad, the muted Lead, Vocals, Harmony |
| 0:22 | Drums | An empty project, the drum track with the 909 kit (READ: `instrument.loadDrumPreset "909"`), and the step grid with the Accent row; the beat plays under a moving take |
| 0:40 | Bass and a pad | Four chords, B minor, G, D, A; the band plays (a take, with the step grid moving) |
| 0:53 | Lead melody | The Lead track's 32 notes in the piano roll; an electric piano plays it (a take) |
| 1:06 | The Sing sheet | Empty sheet → four typed lines → a harmony a third above, key worked out as D major |
| 1:21 | Singing | The progress card mid-job, then the Vocals and Harmony tracks arriving; the sung song plays (a take, with the Lead muted) |
| 1:47 | Note editor | 33 notes and 21 unpitched sounds; a pressed note sounds on its own (1.15 s); the Split tool's cut line reads "Cut · 496 ms \| 496 ms" |
| 2:07 | Spoiled on purpose | 4 line-ending notes selected, Option-dragged to "+70 cents", and played |
| 2:33 | Tune to Melody | The card (Lead picked), the "replace your hand edits?" question, "Tuned 29 notes to Lead."; then A/B on lines 1–2 |
| 3:15 | Natural vs Hard Tune | Both editors; then A/B on the vocal alone |
| 3:57 | Keep voice size | Every note an octave down; the slider at 100% and at Off with its "Big jump" hint; then A/B, Off first |
| 4:37 | The Voice tool | Dragging line 4 to "Deeper 6.0"; then A/B on line 4 with the marks visible on AFTER |
| 5:10 | The finished song | Arrangement playing, then the outro card |

## Gates (all MEASURED on `out/voice-film.mp4` unless named)
- **Content, per line:** all 16 takes pass the transcribe-back gate (`work/content-gate.json`, threshold 0.60). Similarity by line: open 0.93, drums 0.96, band 1.00, lead 0.88, sheet 1.00, singing 0.96, sung 1.00, editor 0.90, split 0.86, sour 0.93, ttm 0.95, ttm-ab 0.80, hard 0.90, size 0.89, voice 0.93, close 1.00. On the film itself, verify.py's blind-window content check gives best 0.52 against a worst-match control of 0.04, a 12.1x separation.
- **verify.py:** ALL 9 CHECKS PASSED (`logs/verify.log`):
  - streams and frame size 1920x1080
  - a/v drift 21.3 ms, under one frame
  - distinct frames 5 of 5 (self control 0.00)
  - audio present at 4 of 4 points
  - loudness and A/B separation (both below)
  - joins: worst seam 0.2437 against a peak-to-inverted-peak control of 1.0131
- **Loudness / true peak:** −16.8 LUFS / −1.6 dBTP (verify.py), −16.83 LUFS / −1.62 dBTP (loudnorm). The first assembly measured exactly −1.00 dBTP. AAC adds about 0.5 dB of overshoot on the drums beat, so the loop ceiling went from −1.5 to −2.0 (`cut-loops.py`).
- **A/B separation (verify.py):** in each pair the film keeps the source's level difference exactly:

  | Pair | Source → film | Content difference |
  |---|---|---|
  | ttm | +0.10 → +0.10 LU | −1.2 dB |
  | hard | +0.50 → +0.50 LU | +3.9 dB |
  | size | −1.60 → −1.60 LU | +0.8 dB |
  | voice | +1.30 → +1.30 LU | −6.4 dB |

- **A/B halves ARE their loops (`tools/ab-equality.py`):** correlation 0.9927–0.9975 against the half's own loop, versus 0.31–0.88 against the other half's loop (the control). Gain is within 0.22 dB of the loop. A constant −21.3 ms lag is 1024 samples, the AAC priming delay. So the numbers measured on the renders are what the viewer hears.
- **Motion / freeze:**
  - In the film (`tools/film-motion.py`), all 15 of 15 play beats move (2,752–5,703 pixels changed between frames 1 s in and 1 s before the end). All 8 of 8 single-still talk beats read 0 (the static control), and a frame against itself reads 0.
  - On the raw takes (`tools/take-motion.py`), all 15 of 15 move (5,536–16,192 pixels changed). The self control reads 0 and the frozen-video control reads 0.
  - The on-screen transport clock differs at 0, 4 and 8 s in every take (`work/clocks-*.png`, read by eye). The synced clips start within ±42 ms of their excerpt.
- **Intro/outro present:** the film's first part is `out/brand/intro.mp4` and its last is `outro.mp4` (READ: `out/segments/_all.txt`). The frames were looked at: "DAW PRO / WHAT'S NEW / with Claude Opus-5", and the outro "© 2026 DAW Pro / All rights reserved. / Narration and singing are synthetic voices. Every figure on screen is measured."
- **Brand check:** neither card reads "YOUR BRAND" (looked at, `work/cards.png`). The stock disclaimer "No music-generation model was used" was **deliberately omitted** (`--no-disclaimer`), because the singing comes from a singing model. The outro line says what is true.
- **Spoken numbers vs screen:** I looked at film frames where each number is spoken (`work/sheet/numbers.png`). Each on-screen number matches the narration: "Found 33 notes and 21 sounds", "+70 cents", "Tuned 29 notes to Lead.", "100%" and "Off", and "Voice: deeper 6.0".

## Where the spoken numbers come from
| Spoken | Source | Tag |
|---|---|---|
| 32 notes over 8 bars | `material.mjs` (4 lines × 8 syllables, 2 bars per line) | READ |
| 37 s for both parts | the sing job | MEASURED in the prior session |
| 33 notes, 21 sounds, 496 ms, +70 cents, 29 notes | app echo, `work/quotes-tune.json` | READ |
| Sour notes +65…+76 c; after Tune to Melody 75/65 → 7/0 | YIN pitch reader with a self-test (`tools/pitch.py`) | MEASURED |
| Wobble 78 → 38 on nine notes (Natural 77.5 vs Hard 38.0, p95–p5) | `tools/pitch.py` | MEASURED |
| Centroid ×0.53 Off / ×0.95 Keep / ×0.54 half-speed tape | `tools/voicesize.py`; its half-speed control must pass first | MEASURED |
| Voice tool: centroid ×0.86, pitch unchanged | `tools/voicesize.py` | MEASURED |
| Voice tool: −4.4 LU on the voice alone, −1.3 LU on the song | `loud.sh` | MEASURED |

## LOOK report (what each capture actually shows)
**Step grid (s03, drums takes):**
- Eight named rows from Cymbal down to Kick, then an **Accent** row underneath.
- The Accent row is unlit: no accents are set. The help text (READ) is: "Accent: click a step to make every hit in it play harder…"
- Earlier: on long drum clips the step grid overflowed (filed in the prior session).

**Sing sheet (s06 empty, s07 words, s08 harmony):** three parts, WORDS, VOICE ("Built-in singer") and HEIGHT, plus EXPRESSION "Style: as sung" and HARMONY. Wrong:
1. The WORDS box clips the 4th lyric line at the bottom edge.
2. The word-chip strip under it shows overlapping, truncated circles ("(((…)))"), so the syllable-to-note mapping can't be read.
3. HEIGHT says "Fits your voice." and, in the same breath, "This is only a suggestion. I'm still checking how well it fits."

On the harmony: "Key: D major (worked out from the song)" with "Pick the key", and a "third above · Built-in singer · Remove" row.

**Singing card (s09):**
- Shows "SINGING PART 1 OF 2 · LINE 2 OF…", truncated.
- Labelled "AGENT" for a job started over the wire (the narration explains this).
- Shows "about 0:12 left".
- After the job (s10), the card stays docked bottom-right showing the finished job. That is an observation, not filed as a defect.

**Note editor (t01–t16, and every editor take):**
- The header reads "Found 33 notes and 21 sounds with no pitch."
- The four preset cards carry their help texts. Hard Tune's is exactly "Holds each note in tune, with less vibrato. The robot effect."
- The palette offers Move, Split, Wobble and Voice.
- Keep voice size sits at 100%, Consonants ON and Slides Smooth.
- Unpitched sounds are drawn as striped boxes, and the white line is the sung pitch.

Wrong or misleading:
1. Pressing a note (t02-hear) shows no visual change during the press.
2. Spoiled notes are labelled with the nearest semitone (D4 + 70 c reads "D#4").
3. Hard Tune's notes are drawn almost flat (the editor's own played line spans 4–26 c, READ). Yet the rendered audio keeps about half its wobble (77.5 → 38.0, so it removes about half, MEASURED). The CHANGELOG disagrees with itself here: line 18 says a held note "keeps about two thirds of its vibrato", while lines 157 and 179 say Hard Tune "removes about half to two-thirds" (READ), so **the picture overstates the effect**. The film says so.
4. After the octave move the lowest notes sit partly under the editor's bottom edge.
5. The Voice-tool marks overlap on short notes ("De Deepe Deeper 6.0", "Deeper 6. Deeper 6.0"). This is visible in the film's Voice AFTER half.

**Tune to Melody card (t06):**
- Lead is picked by default.
- It also offers Drums ("120 notes under this vocal") and two "Beat" clips as melodies to tune a voice to.
- Its 8-row list shows only 4 rows.

## Product defects (filed, not fixed; development is paused)
1. **Sing sheet: WORDS box clips line 4.** Seen in s07 and s08.
2. **Sing sheet: word chips overlap into unreadable circles.** Seen in s07 and s08.
3. **HEIGHT contradicts itself.** "Fits your voice." sits beside "This is only a suggestion. I'm still checking how well it fits." Seen in s06–s08.
4. **Progress card text truncated, and "AGENT" shown for a wire job.** Seen in s09.
5. **Staging window is 1440x900 points, not the requested 1600x900.** The captures are 2880x1800 (16:10), MEASURED.
6. **Tune to Melody offers drum clips as melodies,** and its list is cut to 4 visible rows. Seen in t06-ttm-card.
7. **Hard Tune: the editor draws notes flatter than the audio is.** Display 4–26 c (READ) against rendered wobble 77.5 → 38.0 c (MEASURED, independent YIN).
8. **Keep voice size hint is direction-blind.** "Big jump: turn up Keep voice size so it doesn't sound squeaky" shows for a move DOWN an octave, which sounds big, not squeaky (t14). The help text has the same flaw.
9. **After a large downward move the lowest notes are partly hidden** at the editor's bottom (t13 and t14).
10. **The Voice tool's "Deeper" also lowers level:** −4.4 LU on the line (MEASURED). Whether that is intended is INFERRED as unknown.
11. **Voice marks overlap on short notes.** Seen in t16 and the film's Voice AFTER half.
12. **The note menu "Voice: Deeper 2.0" SETS −2 rather than adding.** It overwrote a −6 during exploration (READ from `clip.getPitchEdits`).
13. **Spoiled notes are labelled with the nearest semitone** (t05).
14. **No visual feedback while a note is pressed** (t02-hear).

Not filed: one exploration run showed a selection surviving `project.open`, but scripted runs reproduced it 0 times in 2.

Docs finding: CHANGELOG.md line 18 ("keeps about two thirds of its vibrato") contradicts lines 157 and 179 ("removes about half to two-thirds"). This film measures about half removed.

Pipeline (not product) findings:
- The assemble.py copies have diverged (a local fork is used here).
- The brand's stock disclaimer is false for any film with a singing model.
- The `blend=difference` two-seek motion probe in record-all.sh (copied from features/) does not compare the frames it names.

## Processes (all stopped; MEASURED 2026-10-11 ~04:40)
- **Staging app** pid 11339, launcher pid 11020 (`kill 11020`, pid-exact):
  - Both have 0 rows in `work/ps-final.txt`.
  - 0 rows match `/.build/debug/DAWProStaging` or `node start-staging.mjs` once my own shell's row is excluded.
  - Port 17695 has no listener (lsof exit 1; stderr is only the known hfs warnings).
- **Singing sidecar:**
  - Staging's last `sing.sidecarStatus` said `installedNotRunning`, with pid null.
  - The private runtime's `run/` folder is empty, with no pidfile.
  - Port 18004 has no listener.
  - The installed engine is unchanged: `find …/SingingEngine -newer work/ref-start` finds 0 files. Two controls: that find lists the engine's 11 top-level entries, and the same comparison finds 105 newer entries in `work/`.
- **Speech server:** started 4 times (narration, content gate, two verify runs), stopped each time by `speech-server.sh stop`. The last pids were 30990, 31732, 32538 and 33880. 0 `omlx serve` rows remain, and ports 8387, 8229, 8135 and 8577 have no listener.
- **Positive control:** the same lsof shape on 17600 shows `DAWApp 31025 … 127.0.0.1:17600 (LISTEN)`. That is the user's live app, never connected to and still running.
- **Not mine:** `caffeinate -i -t 300` (pid 34660) is a child of the harness process 78510, which also parents my shells. Its arguments differ from record-all.sh's `caffeinate -d -i -u -w $$`, and it expires on its own (INFERRED).
