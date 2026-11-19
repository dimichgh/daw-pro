# Vocal → notes: how well our path finds known notes, with Basic Pitch as the yardstick

Lane W9-MIDIB (audio-dsp, opus), 2026-10-12, for the user's question "integrate https://github.com/muscriptor/muscriptor … need to verify?". Companion to `docs/research/2026-10-12-music-to-midi-muscriptor.md` (W9-MUSC, licence + paper review). The lane's report follows verbatim, except one corrected bullet (marked).

**Orchestrator verification (2026-10-12 ~15:2x).** I re-scored the headline numbers with MY OWN matcher (`$S/w9/orch-verify/midib-rescore.py`: maximum-cardinality bipartite matching via `scipy.optimize.linear_sum_assignment`, same-semitone + onset tolerance; Basic Pitch read from its `.mid` files, not the lane's JSON; no `mir_eval`, nothing imported from the lane's `score.py`). It reproduces every pooled figure exactly: ours held 50 ms P 0.576 / R 0.531 / F1 0.553 and 100 ms F1 0.813 (295 notes out); Basic Pitch 50 ms 0.316 / 0.503 / 0.388 and 100 ms 0.583 (510 out); 320 truth notes. Controls on my matcher: truth vs itself 1.0, +1 semitone 0.0, +60 ms 0.0, +40 ms 1.0. NOT re-measured by me: the per-voice tables, the failure-mode counts, the instrument fixtures, the timings. **MuScriptor itself was not run** (its weights are gated on the user's own Hugging Face licence acceptance). The harness (env-gated `Tests/DAWEngineTests/VocalNoteScoreTests.swift`, `MIDIB=1`) is in the tree; the scorer, Basic Pitch runner and data are in the session scratchpad (`$S/w9/MIDIB/`), which a nightly job sweeps when idle — they go into the pause backup.

---


# W9-MIDIB: how well does our "sung audio → notes" path find known notes? (Basic Pitch as the yardstick)

## The answer in plain words
1. **On singing, our own note finder is already the better of the two tools we can ship.** I scored 10 sung versions of the same 32-note tune.
   - **Ours:** the right note at the right moment about **8 times in 10** with a tenth of a second of timing slack. Under the strict rule research papers use (start within 1/20 s), about **5 to 6 in 10**.
   - **Basic Pitch** (Spotify's free tool): about **6 in 10** with slack, **4 in 10** strict.
   - Ours scored higher on all 10 voices. Basic Pitch finds nearly as many of the real notes (recall 0.50 vs 0.53). It loses on the many wrong extra notes it adds. (MEASURED)
2. **When ours finds a note, its pitch is right.** The middle error is 7 cents, about a fourteenth of a semitone, which nobody hears as a wrong note. It made zero octave errors; Basic Pitch made 7. (MEASURED)
3. **Ours loses notes for four known reasons, all fixable.** (MEASURED)
   - The same note sung twice in a row with no break comes out as one long note. It listens to pitch, not to the new word.
   - A slide up into a note after a "k" or "s" sometimes becomes a short extra note at the in-between pitch.
   - Very short notes inside a slide get labelled "slide" instead of "note".
   - Notes end a little early, because the consonant at the end of a word has no pitch.
4. **Basic Pitch's main problem on singing is chopping.** It cuts one long sung note into 2 or more pieces (120 of 320 notes) and adds ghost notes an octave or a twelfth higher. It reported 510 notes where 320 were sung. (MEASURED)
5. **On a full band, ours cannot help and Basic Pitch can.** Ours follows one line at a time by design and gets almost nothing on a band mix (F1 0.03 to 0.07). Basic Pitch found every melody note, most chord notes and fewer bass notes, about two-thirds overall. (MEASURED, on a test band played by the Mac's built-in General MIDI sounds, which is an easy case.)
6. **Both are fast.** Ours takes under 1 s per minute of audio; Basic Pitch takes 0.25 s. (MEASURED)

**Does MuScriptor make better music→MIDI than our existing logic?** Not measured, because it was not run.
- **Singing:** nothing found so far says it would help. Our path already beats the alternative we could ship. MuScriptor's own paper shows it doing worse than an older tool (YourMT3+) on the only sung test it reports (READ, W9-MUSC).
- **Instruments and full songs:** the app has nothing today. The honest comparison there is MuScriptor against Basic Pitch, which needs the user's word on MuScriptor's licence. The harness here can score its output on the same files.

**Recommendation:** build the "vocal clip → MIDI notes" command on our path (`PitchNoteTable.detected`), then fix the repeated-note and scoop losses. For instruments and full mixes, Basic Pitch (Apache-2.0) is the baseline we could ship.

## 1. What ran
**Our path (MEASURED; the product's own calls, nothing re-implemented).** A new env-gated test, `/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/VocalNoteScoreTests.swift` (skipped unless `MIDIB=1`; nonisolated, no new `@MainActor` suite), does two calls per file:
1. `ClipPitchAnalyzer.detect(fileAt:, fromSeconds: 0, durationSeconds: <file length>, confidenceThreshold: 0.9, silenceFloorDbfs: -75)` (`Sources/DAWEngine/Analysis/ClipPitchAnalyzer.swift:50`).
   - These are the product defaults (`Sources/DAWCore/PitchDetection.swift:218/:221`). It is the same call `AudioEngine.detectPitch` makes (`AudioEngine.swift:3440`).
   - SwiftF0 runs on ONNX Runtime at 62.5 frames/s over 46.9–2093.75 Hz.
2. `PitchNoteTable.build(from:)` (`ProjectStore+PitchNoteEdits.swift:1330`).
   - `detected(from:)` (`:1309`) forwards to it, and the editor seeds from it (`PitchEditorModel.swift:2672`).
   - It calls `PitchNoteSplitter.parts(… onsetSeconds: [])` (`:1333`), so onsets are never used (READ).

The test writes every frame and segment to JSON. Scoring rules:
- **Notes:** segments with origin `detected` (held) are the headline; `detected` + `transition` (slides) is a second column; `unpitched` never counts.
- **Pitch:** `detectedHz` rounded to the nearest MIDI note. The unrounded value is used only for the cents view.
- **Determinism:** run 1 and run 2 gave byte-identical segments and frames on all 20 vocal files (MEASURED).

**Basic Pitch (MEASURED).**
- **Install:** basic-pitch 0.4.0 in `$S/w9/MIDIB/venv` (Python 3.12).
  - On macOS with py3.12, 0.4.0 requires `tensorflow-macos<2.15.1`, which has no 3.12 wheel. pip got stuck searching for a working combination, so I stopped it pid-exact (30440, 30378).
  - I then installed basic-pitch with `--no-deps`, plus its non-TensorFlow dependencies, coremltools, onnxruntime and `setuptools<81` (resampy needs `pkg_resources`).
- **Backend:** the bundled CoreML model (`nmp.mlpackage`).
- **Settings:** library defaults (onset 0.5, frame 0.3, minimum note 127.7 ms, no frequency limits, melodia trick on). Notes are taken from its returned note events.
- **Isolation:** nothing installed system-wide; the pip cache is in the lane folder.
- **Determinism:** the two Basic Pitch runs (bp1, bp2) gave identical notes on all 23 files.

**The known notes.**
- **Vocals:** "Light On", 32 notes, 100 BPM, from `MFSong.notes()`. The test writes the truth file.
  - Check: the scorer compares it against a copy typed from MFSong's constants: `truthMatchesMaterial: true`. This only proves the JSON writer and beat arithmetic are right, not the material itself.
  - W9-MF's three run folders hold **10 different takes, not 14**: female-ref and builtin-down are byte-identical across the folders (same seed).
  - Voices: built-in singer at written pitch (MIDI 62–71) and an octave down; 6 narrator-prompted voices (b11-2, b8-0, ctl-none-0, ctl-none-2, b4-2, synthetic-D3); 2 VocalSet prompts (m4, m3). All except female-ref are an octave down. That makes 320 truth notes.
- **Take clock:** clip `startBeat` is 8.1 with no source offset (read from each take's tracks JSON), so onset = (beat − 8.1) × 0.6 s and the first note is at 0.24 s.
  - The app's saved pitch edits for female-ref show a rise from 0.16 s, then F#4 (MIDI 66) from 0.304 s.
  - Our detector agrees: 0.16–0.304 s at 64.9, then 0.304–0.736 s at 66.0.
  - Our per-file median lag is 0 to +16 ms on every voice. A wrong mapping would shift them all.
- **"Tuned" rows:** these are the app's pitch-corrected renders, and the splitter under test segmented that correction. They are reported but kept out of the verdict.
- **Instruments:** the test renders 3 fixtures offline through `OfflineRenderer` and the Mac's General MIDI bank (all sounds loaded), 48 kHz, 21 s. Truth is the exact MIDI rendered.

  | Fixture | Contents | Peak |
  |---|---|---|
  | melody-piano | 32 melody notes on piano | −17.6 dBFS |
  | band-nodrums | melody + bass (GM 33, 32 notes) + chords (GM 4, 48 notes) | −8.8 dBFS |
  | band-drums | the same plus a GM drum kit (96 hits) | −3.8 dBFS |

## 2. The scorer, checked first (MEASURED)
I used `mir_eval` 0.8.2 `match_notes`.
- Pitch must be within 50 c. Onset within 50 ms is the headline; 100 ms and 150 ms are extra views.
- Each view is scored with offsets (20% of note length, minimum 50 ms) and without.

| Control on the female-ref truth | Expected | Got |
|---|---|---|
| truth vs itself (with offsets / onsets only) | 1.0 | **1.0 / 1.0** |
| +1 semitone | ≈0 | **0.0** |
| +12 semitones | ≈0 | **0.0** |
| +40 ms / +60 ms at 50 ms tolerance | 1 / 0 | **1.0 / 0.0** |
| +40 c / +60 c (unrounded) | match / miss | **1.0 / 0.0** |
| the 3 repeated-note pairs merged | recall 29/32 | **R 0.906, P 1.0** |

The failure-mode classifier was checked on planted errors (`fm-controls.json`), all correct: truth vs itself gave 32 right; merged pairs gave 6 notes merged; +12 gave 32 octave; +2 gave 32 wrong pitch; each note halved gave 32 split; dropping every 4th gave 8 missed; 8 added notes gave 8 extra.

## 3. Results on the 10 sung takes (MEASURED, 320 truth notes)

| System | notes out | 50 ms: P / R / **F1** | 50 ms + offsets F1 | 100 ms: P / R / **F1** | 100 ms + offsets F1 | 150 ms F1 | shared-shift 50 ms F1 | median lag |
|---|---|---|---|---|---|---|---|---|
| **Ours, held** | 295 | 0.576 / 0.531 / **0.553** | 0.338 | 0.847 / 0.781 / **0.813** | 0.498 | 0.849 | 0.602 | +4 ms |
| Ours, held + slides | 323 | 0.542 / 0.547 / 0.544 | 0.333 | 0.811 / 0.819 / 0.815 | 0.491 | 0.855 | 0.591 | +4 ms |
| **Basic Pitch** | 510 | 0.316 / 0.503 / **0.388** | 0.186 | 0.475 / 0.756 / **0.583** | 0.284 | 0.653 | 0.480 | +38 ms |
| *(tuned) ours, held* | 296 | 0.581 / 0.537 / 0.558 | 0.331 | 0.838 / 0.775 / 0.805 | 0.464 | 0.844 | 0.575 | +8 ms |
| *(tuned) Basic Pitch* | 572 | 0.281 / 0.503 / 0.361 | 0.114 | 0.425 / 0.759 / 0.545 | 0.204 | 0.594 | 0.462 | +37 ms |

**Pitch view (within 50 c):** ours has a median |error| of **7.2 c** and a median signed error of +1.9 c (9.6 c on the tuned renders). Basic Pitch outputs whole MIDI notes, so its cents error is undefined.

**Per voice, F1** (50 ms / 50 ms + offsets / 100 ms; notes out in brackets):

| Voice | Ours (held) | Basic Pitch | Shared shift | Ours @shift | BP @shift |
|---|---|---|---|---|---|
| female-ref | 0.56 / 0.30 / 0.82 (29) | 0.29 / 0.12 / 0.53 (51) | +23.7 ms | 0.62 | 0.34 |
| builtin-down | 0.57 / 0.23 / 0.83 (28) | 0.35 / 0.16 / 0.56 (53) | +32.0 | 0.73 | 0.45 |
| narr-b11-2 | 0.56 / 0.30 / 0.82 (29) | 0.48 / 0.30 / 0.62 (48) | +24.0 | 0.56 | 0.57 |
| narr-b8-0 | 0.60 / 0.40 / 0.87 (28) | 0.33 / 0.09 / 0.58 (58) | +22.6 | 0.70 | 0.44 |
| narr-ctl-none-0 | 0.46 / 0.28 / 0.77 (33) | 0.26 / 0.13 / 0.49 (45) | +23.3 | 0.55 | 0.36 |
| narr-ctl-none-2 | 0.55 / 0.32 / 0.77 (30) | 0.40 / 0.20 / 0.65 (48) | +25.0 | 0.58 | 0.60 |
| narr-b4-2 | 0.52 / 0.33 / 0.79 (29) | 0.46 / 0.25 / 0.61 (47) | +20.0 | 0.56 | 0.58 |
| synth-D3 | 0.65 / 0.39 / 0.84 (30) | 0.42 / 0.18 / 0.53 (59) | +11.9 | 0.61 | 0.42 |
| vocalset-m4 | 0.60 / 0.50 / 0.83 (28) | 0.51 / 0.28 / 0.63 (47) | 0.0 | 0.60 | 0.51 |
| vocalset-m3 | 0.48 / 0.35 / 0.79 (31) | 0.40 / 0.16 / 0.63 (54) | +18.5 | 0.51 | 0.53 |

**Per voice, precision / recall:**

| Voice | Ours held: 50 ms P / R | + offsets P / R | Basic Pitch: 50 ms P / R | + offsets P / R |
|---|---|---|---|---|
| female-ref | 0.59 / 0.53 | 0.31 / 0.28 | 0.24 / 0.38 | 0.10 / 0.16 |
| builtin-down | 0.61 / 0.53 | 0.25 / 0.22 | 0.28 / 0.47 | 0.13 / 0.22 |
| narr-b11-2 | 0.59 / 0.53 | 0.31 / 0.28 | 0.40 / 0.59 | 0.25 / 0.38 |
| narr-b8-0 | 0.64 / 0.56 | 0.43 / 0.38 | 0.26 / 0.47 | 0.07 / 0.12 |
| narr-ctl-none-0 | 0.45 / 0.47 | 0.27 / 0.28 | 0.22 / 0.31 | 0.11 / 0.16 |
| narr-ctl-none-2 | 0.57 / 0.53 | 0.33 / 0.31 | 0.33 / 0.50 | 0.17 / 0.25 |
| narr-b4-2 | 0.55 / 0.50 | 0.34 / 0.31 | 0.38 / 0.56 | 0.21 / 0.31 |
| synth-D3 | 0.67 / 0.62 | 0.40 / 0.38 | 0.32 / 0.59 | 0.14 / 0.25 |
| vocalset-m4 | 0.64 / 0.56 | 0.54 / 0.47 | 0.43 / 0.62 | 0.23 / 0.34 |
| vocalset-m3 | 0.48 / 0.47 | 0.35 / 0.34 | 0.31 / 0.53 | 0.13 / 0.22 |

What the per-voice numbers show:
- **F1:** ours is higher on 10 of 10 voices, at 50 ms and at 100 ms. Ranges at 50 / 100 ms: ours 0.46–0.65 / 0.77–0.87; Basic Pitch 0.26–0.51 / 0.49–0.65.
- **Precision:** ours is higher on 10 of 10 voices.
- **Recall:** Basic Pitch is higher on 4 voices (narr-b11-2 0.59 vs 0.53, narr-b4-2 0.56 vs 0.50, vocalset-m4 0.62 vs 0.56, vocalset-m3 0.53 vs 0.47) and lower on the other 6. Pooled recall: ours 0.531, Basic Pitch 0.503. The F1 gap is mostly precision, i.e. chopping. *(Corrected from the lane's garbled draft per its own erratum; counted from the table by the orchestrator.)*
- **With the shared shift:** ours is higher on 6 voices and Basic Pitch on 4, each of those 4 by 0.02 or less.

## 4. The singer's own timing, and the one correction used (MEASURED)
- **The truth is the score the singer was given, not an as-sung annotation.** The singing engine places consonants around the beat. Published papers score against as-sung labels, so these strict 50 ms numbers are not comparable with published ones (INFERRED).
- **Onset spread, lenient match (±200 ms):**
  - Ours (275 notes): p10 / median / p90 = −64 / +4 / +64 ms; 64% within ±50 ms and 95% within ±100 ms.
  - Basic Pitch (278 notes): −14 / +38 / +115 ms; 58% and 86%.
- **The deviations depend on the syllable, not on the take:**
  - Ours starts early on notes that open with a voiced consonant: "you", "der", "win", "burn" (−50 to −72 ms). The singer starts the consonant before the beat, and a voiced consonant carries pitch.
  - "two" (−60 ms) is a different case: /t/ is unvoiced. It is more likely the pitch moving early from "for" (67) to "two" (66) without a break.
  - Openings after a rest start late: "I" +80 ms, "The" +64 ms, "ci-" +60 ms.
  - The two systems' per-note lags agree only weakly (correlation 0.39 over 29 notes). Each tool reacts to a sung onset its own way: ours when the pitch arrives, Basic Pitch when its onset detector fires.
- **The rule, stated and applied identically to both systems.** Nothing was fitted per system or per note. Two views:
  1. Wider windows (100 and 150 ms). These have no parameter.
  2. One constant per file: the median of both systems' pooled lenient lags (0 to +32 ms), added to the truth for both. Result: ours **0.602**, Basic Pitch **0.480**.

## 5. Failure modes (MEASURED, takes, by time overlap)

| | Ours, held | Ours, held + slides | Basic Pitch |
|---|---|---|---|
| right pitch | 281 | 294 | 273 |
| wrong pitch (not an octave) | 22 | 26 | 10 |
| octave | **0** | **0** | 7 |
| missed (<25% of the note covered) | 17 | **0** | 30 |
| merged (truth notes → output notes) | 40 → 20, all same pitch | 40 → 20 | 8 → 4 |
| split into 2+ pieces | 11 | 19 | **120** |
| extra notes outside the tune | 3 | 3 | 2 |

- **Repeated notes merge (ours).** "Light On" has 3 same-pitch pairs, 30 ms apart in the score: I-left, case-you, ci-ty.
  - Ours merged 20 of the 30 pairs across the 10 voices. That costs 20 of 320 notes, about 6%.
  - The loss is built in. The splitter never sees onsets (`onsetSeconds: []`, `ProjectStore+PitchNoteEdits.swift:1333`), and its design says "an onset alone never cuts" (`PitchNoteSplitter.swift:109`) (READ).
  - Control: the merged truth scores R = 29/32.
- **Scoops become notes (ours).**
  - "case" (#9): after the "k" the singer slides up about 4 semitones over ~150 ms. Ours made a separate held note at the slide's middle pitch in 8 of 10 voices. Example: female-ref 5.280–5.472 s at MIDI 64.35, truth 66.
  - The same happens on the first note: 0.16–0.304 s at 64.9 before the 66.
  - Basic Pitch skips the scoop and comes in about 60 ms late.
- **Short notes inside slides become slides (ours).** "der" #12, "a" #20, "and" #24 and "dow's" #28 are the notes the held-only view misses most.
  - Counting slides as notes recovers all 17 misses, but adds 4 wrong pitches and 28 output notes.
  - Net F1 is unchanged: 0.553 vs 0.544 at 50 ms, 0.813 vs 0.815 at 100 ms.
- **Notes end early.**
  - Ours ends a median 48 ms early (p10 −142, p90 +60), and notes are 0.89 of the written length. The end of each syllable is unvoiced.
  - Basic Pitch ends a median 63 ms early, with p10 −588 ms from its chopping.
  - This is why every "+ offsets" score is low.
- **Basic Pitch's 510 output notes break down as:**
  - 259 were the first piece of a correct note;
  - **164 were extra same-pitch pieces** of a note it had already found;
  - 22 were octave ghosts;
  - 41 were other-pitch ghosts, for example +19 semitones (the 3rd harmonic);
  - 22 were 1–2 semitones off (bends).

## 6. Instruments (MEASURED)

| Fixture | Truth notes | Ours (one line, vs melody) 50 ms P / R / F1 · + offsets F1 | Basic Pitch (vs all pitched) 50 ms P / R / F1 · + offsets F1 · 100 ms F1 | Basic Pitch recall by part |
|---|---|---|---|---|
| melody-piano | 32 | 0.964 / 0.844 / **0.900** · 0.667 | 0.865 / 1.000 / **0.928** · 0.290 · 0.928 | melody 1.00 |
| band-nodrums | 112 | 0.069 / 0.062 / 0.066 · 0.033 | 0.542 / 0.866 / **0.667** · 0.392 · 0.729 | melody 1.00, bass 0.72, chords 0.88 |
| band-drums | 112 (+96 hits) | 0.032 / 0.031 / 0.032 · 0.032 | 0.495 / 0.866 / **0.630** · 0.325 · 0.688 | melody 1.00, bass 0.69, chords 0.90 |

- **Piano melody:** ours merges 3 repeated pairs again. Basic Pitch's offsets run long (median +145 ms) because it hears the piano ring after the key is released (an instrument effect, INFERRED).
- **Band mixes:** ours is not a real contestant here. It is monophonic by design (READ).
- **Caveat:** these are synthetic General MIDI sounds, so treat the band numbers as a ceiling (INFERRED). The failure-mode table is not given for chords, because chord notes overlap by design.

## 7. Speed on this Mac (MEASURED)
- **Method:** measured under `timing.lock` after every other lane's slot had drained (35 s). heavy-1 was held by ORCH-sled-adup when I took the lock, which shows the drain check can see a foreign slot. Each file got 1 first call plus 3 repeats; the median repeat is reported.

| | Per minute of audio | First call, all 190 s of takes | Notes |
|---|---|---|---|
| Ours | **0.73 s** (≈80× real time) | 2.55 s | Debug test build. Includes the 48 kHz WAV read and ONNX Runtime inference. The splitter alone takes 0.095 s for all 190 s. |
| Basic Pitch (CoreML) | **0.25 s** (≈240× real time) | 0.89 s | Plus 0.94 s Python import and 0.12 s model load, once per process. |

- **Was anything else running?** Yes, the user's desktop.
  - Load average (1-minute) was 8.9 before, 11.5 between and 11.0 after, on an 18-core Mac17,6.
  - Top processes: WindowServer ~68%, a Claude helper ~31%, the jamf security extension 20–59%, Chrome/VS Code helpers 6–15%.
  - No lane slot was held. The order of magnitude is solid; the roughly 3× gap between the tools is approximate.

## 8. Recommendation for a "vocal clip → MIDI notes" command
1. **Build it on `PitchNoteTable.detected`**, using held notes rounded to the nearest semitone.
   - It beats the shippable alternative on all 10 voices (MEASURED).
   - It is already in the app, adds no dependency and no licence, and keeps the editor and the export in agreement (READ).
   - Counting slides as notes did not help (MEASURED).
2. **Fix, in order of cost.** Each fix is INFERRED until this harness measures it.
   - **Repeated notes** (~6%, built in): onsets or the lyric's syllable count would need to be allowed to cut a held note at the same pitch. `PitchNoteSplitter.swift:109` forbids this today, so it is a design change for the splitter's owner.
   - **Scoops:** a short part whose pitch is still moving straight into the next held note could join that note. That would fix 22 wrong-pitch notes, including "case" in 8 of 10 voices.
   - **Note ends:** for MIDI only, extend a note to the next note's start across a short unvoiced gap.
3. **Instruments and full mixes:** Basic Pitch (Apache-2.0, bundled CoreML/ONNX model) is the baseline we could ship, as a "rough sketch" tool (MEASURED here: F1 0.63–0.67 on a synthetic band). MuScriptor needs the user's licence decision first.
4. **Decision rule if MuScriptor is ever evaluated:**
   - **Singing:** on these 10 takes, it should beat ours by at least 10 points of onset F1. Ours is 0.553 at 50 ms and 0.813 at 100 ms.
   - **Bands:** compare it with Basic Pitch's 0.667 / 0.630 on the band fixtures.

## 9. Limits
- **Narrow test set:** one tune of 32 notes, sung 10 ways by one singing engine with different voice prompts. These are synthetic voices, not people (INFERRED: real singers are harder).
- **Truth is the score, not the performance:** strict-onset numbers understate both tools.
- **Easy instrument fixtures:** General MIDI sounds and short, simple parts.
- **Debug build:** our timing came from a debug build.
- **Known pitch bias (`p2-sing-x9-f4`) did not show:** the median signed error was +1.9 c (MEASURED). It never changed which note was chosen.

## 10. Files and how to reproduce
- **Repo change:** one untracked, env-gated file, `/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/VocalNoteScoreTests.swift`. It is identical to `$S/w9/MIDIB/draft/VocalNoteScoreTests.swift` (`cmp`).
  - Run it while holding a slot: `MIDIB=1 [MIDIB_RENDER=1] MIDIB_OUT=<dir> MIDIB_MANIFEST=<json> [MIDIB_REPEAT=3] ./scripts/test.sh --filter VocalNoteScoreTests`.
  - Without `MIDIB=1` both tests skip (MEASURED).
- **Basic Pitch:** `$S/w9/MIDIB/venv/bin/python $S/w9/MIDIB/bp_run.py <manifest> <outdir> [repeats]`.
- **Scorer:** `$S/w9/MIDIB/venv/bin/python $S/w9/MIDIB/score.py <ours_dir> <contestant_dir> <truth> voices.json <out.json> [inst_dir]`. A new contestant (MuScriptor, ROSVOT) only needs `<label>.json` files containing `notes:[{start,end,pitch}]`.
- **Data:** `$S/w9/MIDIB/`
  - `out1/`: product output, instrument renders, truth
  - `out2/`: timed run
  - `bp1/`, `bp2/`: Basic Pitch untimed and timed
  - `score2.json`: final numbers
  - `fm-controls.json`
  - `manifest-*.json`, `voices.json`, `logs/`
  - helpers: `lagnotes.py`, `estside.py`, `offsets.py`, `fm_controls.py`

## 11. Rules kept (MEASURED)
- **`Sources/` untouched; one new test file.** It was installed only under heavy-2.
  - Run 1, 15:05:49–15:07:45: green ("Test run with 2 tests in 1 suite passed").
  - Run 2, 15:10:56–15:12:15, heavy-2 plus timing.lock: green.
  - All locks released by content check.
- **0 warnings:** the pattern `\.swift:N:N: warning:` finds 0 in run 1's log, where my file was compiled. Positive control: the same pattern finds 280 in `$S/w9/AIR/logs/unit1-152257.log`.
- **Python and licences:** Python only in the lane venv, with Basic Pitch runs under `take-aux`. No MuScriptor, no licence accepted, no account or token, no `.env`.
- **Off-limits:** no port 17600, no app launch, no commits, no git checkout/stash/restore/clean/reset. `scripts/ace-step/`, `scripts/rvc/` and audio devices untouched.
- **Kills:** one kill, pid-exact (the stuck pip: 30440, 30378).
