# p2-seg — automatic note splitting inside an unbroken voiced run (DESIGN)

Status: DESIGN ONLY — no code. Author: daw-architect, 2026-09-24.
Tags: [READ] = read in source/doc at the cited line; [MEASURED] = measured (by whom is stated);
[INFERRED] = reasoned, not measured. Every code claim cites `file:line`.

## §0 Decision summary

**The decision, in six lines.**

1. **`voicedRuns` is NOT changed. A new pure splitter is layered ON TOP of it.** [READ] The played
   line and the editor's measured contour are drawn PER RUN, never per note, and both say why:
   a cut inside a run would "draw a 16 ms hole where the singer never stopped"
   (`Sources/DAWCore/PitchPlayedLine.swift:104-110`, `Sources/DAWAppKit/PitchEditorModel.swift:1565-1571`).
   Changing `voicedRuns` would break that line at every new boundary. So `voicedRuns`
   (`Sources/DAWCore/PitchCorrection.swift:1658-1699`) keeps its callers `PitchPlayedLine.swift:277`
   and `PitchEditorModel.swift:1564`. Only the two NOTE-TABLE builders move to the splitter:
   `PitchAutoCorrect.editSet` (`PitchCorrection.swift:1713`) and `PitchNoteTable.detected`
   (`Sources/DAWCore/ProjectStore+PitchNoteEdits.swift:272`).
2. **f0 decides whether to cut. Onsets only decide exactly where.** A legato slide has no
   consonant, so `detectTransients` cannot be relied on to fire at 22.6 s [INFERRED]. The f0 rule
   alone must turn the RED gate green. An onset near an f0-found cut moves the cut onto it; an
   onset alone never cuts (§1.5).
3. **The rule** (§1): split a run only between two HELD plateaus whose centres differ by
   **≥ 50 c** when both are measured over at least one full vibrato cycle, or **≥ 100 c** when
   either is shorter than that. A plateau lasts at least `minimumNoteSeconds`. Movement
   between plateaus, or before the first one, that lasts **> 120 ms** becomes its own
   TRANSITION part. Anything shorter stays with its plateau.
4. **A run with nothing to split comes out BYTE-IDENTICAL to today's `VoicedRun`**, median
   centre included, by construction (§2.4, §5.2). When a run DOES split, each held note's
   centre is the median of its own plateau frames, not of the whole run.
5. **What Hard Tune does to a transition is the USER'S pick** (§3, §9), from a 4-render
   listening set on their own take. The splitter emits parts, and every part becomes
   exactly one segment whatever the preset or shape, so the note table never depends on the
   pick. The pick only sets the `.transition` segment's correction values (offset, drift and
   vibrato scales): one policy constant, not a splitter change.
   Three of the four shapes render with today's engine. The staircase needs engine work (§3.3).
6. **Stored edits are never re-segmented.** The splitter runs only inside the two
   note-table builders, never on load, open, render or `syncStoredNoteTable` (§4).

**Invariants checked** [READ/INFERRED as tagged]:
- **Render thread: untouched.** The splitter is a pure DAWCore function called on the main
  actor inside `autoCorrectClipPitch`. Onsets come from `detectTransients`, a content-keyed
  cache that runs the analyzer "in a detached task — zero render-thread involvement"
  [READ `Sources/DAWEngine/AudioEngine.swift:2238-2245`]. No allocation, lock or block reaches the
  render path.
- **DAWCore stays pure.** `detectTransients` is an `async throws` engine-protocol method
  [READ `Sources/DAWCore/EngineProtocol.swift:652`] and the pure policy cannot call it. The STORE
  fetches the onsets and passes plain seconds in. The headless default returns `[]` [READ
  `EngineProtocol.swift:1696`], so the splitter must be complete without onsets. Point 2 already
  requires that.
- **One command surface.** No new wire verb is needed. `clip.autoCorrectPitch` picks up the
  new segmentation on new passes. Any new option is an additive optional field (§4.3).
- **No second home.** No second onset detector (editor doc §10 item 11,
  `docs/design/2026-09-22-pitch-editor-ui.md:1272-1274`) and no second hole rule. The splitter
  reads `voicedRuns` output and never re-derives run edges.
- **Nothing here needs full Xcode**, entitlements, AUv3 or signing.

## §1 The splitter — signals, rule, thresholds

### §1.1 Where it lives

- New file `Sources/DAWCore/PitchNoteSplitter.swift`. Pure: no clock, I/O, store or engine.
  It is the same kind of code as `PitchAutoCorrect` (`PitchCorrection.swift:1640`).
- Proposed API (names are the implementer's call; the SHAPE is the decision):
  - `PitchNoteSplitter.parts(in frames: [ClipPitchFrame], frameRateHz: Double, onsetSeconds: [Double] = []) -> [NotePart]`.
  - `NotePart` has: `kind` (`.held` / `.transition`), `startSeconds`, `endSeconds`,
    `centreHz`, `medianConfidence`, `frameCount`, `runIndex` (which `voicedRuns` element
    the part came from), and `runCentreHz` (that run's own median). Shape (c)'s mapping
    (§3.2) needs the WHOLE run's median, which no single part carries otherwise.
- It CALLS `PitchAutoCorrect.voicedRuns` first and splits inside each run. It never
  re-derives run edges, so holes stay note ends and are never bridged
  (editor doc §17 constraint; `PitchCorrection.swift:1653-1657`).
- Frame convention: a boundary lands on a frame START (`timeSeconds`). A part is
  `[first.timeSeconds, last.timeSeconds + 1/frameRateHz)`, the same convention `voicedRuns`
  uses (`PitchCorrection.swift:1671-1672`). Abutting parts therefore share their boundary
  exactly and crossfade to unity under the curve's complementary smoothstep [READ
  `PitchCorrection.swift:1375-1383`].

### §1.2 Signals

- **f0 stability decides whether a run splits. It is the only signal that can turn the RED
  gate green.** A slide into a held note has no consonant, so a spectral-flux detector has
  nothing new to fire on except moving harmonics [INFERRED; measured by item S0, §6].
- **`detectTransients` is the one onset detector.** [READ] It is declared on
  `AudioEngineControlling` (`Sources/DAWCore/EngineProtocol.swift:652`) and implemented in
  `Sources/DAWEngine/AudioEngine.swift:2244` over `TransientCache` → `TransientAnalyzer`
  (`Sources/DAWEngine/Analysis/TransientAnalyzer.swift:12-20`). Its method is spectral flux,
  a 1024-sample window at 256 hop, and a 30 ms minimum separation (`:33-38`). Markers are in
  SOURCE-FILE seconds (`EngineProtocol.swift:421-425`). The existing callers pass
  `sensitivity: 0.5` (`ProjectStore+TakeAlignment.swift:92-93`). Reusing 0.5 shares their
  cache entry, since the cache is keyed on sensitivity [READ `AudioEngine.swift:2244-2246`].
- **An onset only moves a cut that f0 already found (§1.5). It never creates one.** A voiced
  consonant inside a held note ("wa-t-er" on one pitch) would otherwise split a note that
  Hard Tune should treat as one. Splitting on an onset at the SAME pitch (re-articulation)
  is a named follow-up, not v1 (§6, S5).

### §1.3 The rule

All arithmetic is in cents, per run, relative to the run's own `centreHz`.
`r = frameRateHz` (62.5 today). Frame counts below are at 62.5 fps and must be DERIVED from
`r` in code, never hardcoded.

1. **De-glitch.** Take a centred 5-frame running median `x` of the run's cents. The window
   shrinks symmetrically at run edges and never reads across a run edge.
2. **Centre track.** Take a centred running median `y` of `x` over `P` frames, where `P` =
   one cycle of the slowest wobble the product models (§1.4). The window again shrinks
   symmetrically at run edges. A running median keeps steps sharp and follows ramps with no
   lag, which a running mean would not. So `y` is the contour with its wobble removed but its
   note changes intact.
3. **Plateaus.** Scan `y` left to right. Grow a stretch while `max(y) − min(y)` over it stays
   `≤ B`. Accept it as a candidate plateau if it is at least `T` frames long. Otherwise
   advance one frame. This is a greedy scan with no look-back.
4. **Merge.** Merge any two neighbouring plateaus, together with the frames between them,
   when their centres differ by less than `τ`. For this MERGE decision only, a plateau's centre
   is the MEAN of `x` over its frames. A mean cancels wobble without the whole-bin jumps a
   median of quantised frames makes. [MEASURED synthetic, steady ±37 c reading: over two
   adjacent 16-frame windows, the worst mean difference was 16.1 c against a worst median
   difference of 51.6 c.] The EMITTED centre (step 6) stays the median, so each part matches
   `VoicedRun`'s estimator. `τ = τ_long` when both plateaus are at least `P` frames long, else
   `τ_short`.
   Repeat until no pair merges.
5. **Classify the leftover frames.** Frames in no plateau are TRANSITION frames, in three
   places: before the first plateau (lead-in), between two plateaus (link), and after the
   last (tail-off).
   - A lead-in or tail-off of `≤ S` frames belongs to its plateau: it is a scoop or a
     release (§2.2).
   - A link of `≤ S` frames is cut at ONE frame and its two sides go to their plateaus. The
     cut is at an onset if §1.5 finds one. Otherwise it is at the first frame whose `x`
     crosses the mean of the two plateau centres.
   - A lead-in, link or tail-off of `> S` frames becomes its own `.transition` part.
6. **Emit.**
   - **Zero plateaus**, or one plateau with no `.transition` part: emit ONE part equal to
     today's `VoicedRun`, byte for byte, median of ALL the run's frames included (§2.4).
     This covers a pure glide, a shaky note and every steady note.
   - **Otherwise**: one part per plateau (`.held`) plus one per long transition
     (`.transition`). Each part's `centreHz` is the MEDIAN of its own raw frames, the same
     estimator `VoicedRun.centreHz` uses (`PitchCorrection.swift:1619-1622`). A part shorter
     than `minimumNoteSeconds` cannot happen for `.held` (since `T > 4` frames). A
     `.transition` is only emitted above `S > 4` frames.

### §1.4 Thresholds, each bounded by a fact

| Symbol | Value at 62.5 fps | Lower bound (fact) | Upper bound (fact) |
|---|---|---|---|
| de-glitch width | 5 frames (80 ms) | Must remove the isolated 1-frame and short octave-high glitches measured on the take [MEASURED by audio-dsp-engineer, vibrato doc §18.5, `docs/design/2026-09-24-pitch-editor-vibrato-handle.md:2046`]. A 5-median removes any feature of ≤ 2 frames. | Must keep any real note. A 5-median keeps features of ≥ 3 frames, and `minimumNoteSeconds` is 0.06 s = 4 frames (`PitchCorrection.swift:1648`). |
| `P` | the smallest ODD count ≥ `r / 3.0` = 21 frames (336 ms). Odd, so the median is centred. | One full cycle of the SLOWEST sung wobble the product models: `PitchWobbleEstimate.scanRangeHz.lowerBound` = 3.0 Hz [READ `Sources/DAWCore/PitchWobbleEstimate.swift:127`]. A median over at least one cycle lands near the centre for every rate in 3–9 Hz. ⚠️ NOT `vibratoRateHzRange`: that is 0...8 (`PitchCorrection.swift:481`), the GENERATED-vibrato range, where 0 means off. | Longer windows only add lag at run edges. `P` is the shortest window that meets the lower bound. |
| `B` (plateau band) | 52 c | [READ] The detector outputs 25.79 c SwiftF0 bins, so a single value is off by up to 12.90 c (`PitchCorrection.swift:1769-1772`, "THE DETECTOR'S RESOLUTION FLOOR"). A median of quantised values therefore moves in whole bins. [MEASURED, synthetic, by me: for ±37 c and ±50 c readings at 3.0–9.0 Hz with full bin quantisation, `y` strayed at most 25.8 c (one bin) from the centre inside a note.] A steady note's `y` therefore spans ≤ 2 bins = 51.6 c. | A semitone step (100 c) must break the band [MEASURED synthetic: a 199 c step and a 70 c step both broke it]. |
| `T` (min plateau) | 8 frames (128 ms) | A slide at speed `v` spends about `(B + one bin)/v` inside one band, because of the staircase. `T = 8` stops a slide of ≥ 800 c/s from faking a plateau. [MEASURED synthetic, 16 phases: at `T = 8` an 800 c/s slide over 1 s stayed whole, but a 600 c/s slide split into 4. At `T = 6` even the 800 c/s slide split into 5.] | Must be below the shortest held note that must be caught. The RED held tails are ~150–200 ms (brief: 23.05–23.2 s and 16.8–17.0 s), ≥ 9 frames. ⚠️ **The margin is 1–4 frames. This is the tightest bound in the design.** Item S1 must measure the real tails from product frames before code (§6). |
| `τ_long` | 50 c | Two plateaus of at least `P` frames each: the MEAN over at least a cycle cancels the wobble to ≤ 0.217 × depth (the sinc first sidelobe) and averages the bin staircase down. | Half a semitone is where `nearestAllowedMidi` flips on a chromatic scale. A smaller step cannot move a snapped note by more than it moves the sung one. |
| `τ_short` | 100 c | A plateau is never shorter than `T` = 8 frames, so the relevant fact is the worst merge-centre (mean of `x`) difference between two ADJACENT 8-frame windows of ONE steady wobbling note. [MEASURED synthetic, full-bin quantisation, 3–9 Hz, 16 phases:] 45.1 c for a ±37 c reading (the design point: a true ±40 c reads 34–37 c, brief), and 80.6 c for a ±50 c reading. So `τ_short` > 80.6 c keeps a wobble of up to a ±50 c reading as one note. | One semitone (100 c), the smallest scale step. Refusing to split below it costs at most today's behaviour. The band is (80.6, 100]. It takes the upper end because lowering it to 80 c did NOT reduce F-semi [MEASURED synthetic: eighth notes 100 c apart still gave 2–4 parts]. So a lower value would buy nothing and give up margin. |
| `S` (scoop/release limit) | 8 frames (128 ms) | The brief's scoop case: ≤ 120 ms = 7.5 frames must stay one note. | Must be well below the RED lead-in slides. [MEASURED synthetic: a 0.4 s slide into a held note left a 20–25-frame lead-in.] Item S1 measures the real lead-ins. |

Two more notes on the thresholds:
- The frame counts `P`, `T`, `S` and the de-glitch width all derive from `r`. A backend with a
  different frame rate gets the same seconds, rounded up to whole frames.
- **Synthetic check, run by me for this design** (python in the session scratchpad; NOT a
  product test, and the implementer re-derives it in Swift). With `B = 52`, `T = 8`, `P = 21`:
  - STAYED ONE NOTE: steady ±35 c at 3, 5.5 and 9 Hz; ±50 c and ±100 c at 5.5 Hz; a 120 ms
    300 c scoop; a 2-frame octave glitch; slides of 800 c/s and 833 c/s.
  - SPLIT: a 199 c legato step, cut at 0.496 s against a true 0.496 s; a 70 c step between
    two 0.8 s notes. The same step between two 0.5 s notes split in one phase of two.
  - EIGHTH NOTES: four 250 ms notes with ±37 c wobble split into all four at 200 c steps
    (16/16 phases). At 100 c steps they gave 2–4 parts: these notes are shorter than `P`, so
    `τ_short` = 100 c applies and a semitone sits right on it. That under-split is the safe
    direction (today's behaviour for those notes) and is recorded as F-semi in §8.
  - `P` = 11 (one cycle at 5.5 Hz) instead of 21 changed none of these outcomes. So `P` stays
    tied to the one 3 Hz fact, and there is no second window constant.
  - The two RED-like fixtures (a 741 c slide over 0.44 s then a 0.17 s tail; a 500 c slide
    over 0.4 s then a 0.2 s tail) each gave ONE held plateau covering the tail, centre within
    6–11 c of the sung tail, plus a 20–25-frame lead-in, so a `.transition` part. That centre
    figure uses the MERGE estimator. The EMITTED median of the raw frames was 0 c off on the
    741 c fixture [MEASURED synthetic]. S2 verifies both in Swift.

### §1.5 Onsets

- **Input**: `onsetSeconds: [Double]`, source-file seconds. The caller gives the markers from
  `detectTransients(…, sensitivity: 0.5)` whose times fall inside the detection window. An
  empty array is a complete, valid input (the headless engine returns `[]`,
  `EngineProtocol.swift:1696`).
- **Use**: exactly one. When step 5 cuts a short link, and an onset lies inside that link or
  within 1 frame of either end, the cut goes to the frame start nearest the onset. Otherwise
  it goes to the midpoint crossing.
- The tolerance is 1 frame (16 ms) because frame values sit ~8–12 ms after their
  `timeSeconds` [READ `PitchCorrection.swift:1160-1164`], and markers are refined to 64-sample
  blocks (`TransientAnalyzer.swift:45`).
- **Time bases**: markers are source-file seconds [READ]. Pitch frames are taken to be
  source-file seconds too [INFERRED from `PitchPlayedLine.swift:212-219` and from
  `detectClipPitch` passing `fromSeconds` in source-file seconds,
  `ProjectStore+PitchDetection.swift:68-89`]. S3 must prove this with a planted onset at a
  known second before trusting it.
- **Plumbing is sequenced, not skipped.** v1 (S2) ships the `onsetSeconds` parameter with
  every production caller passing `[]`. S3 wires real onsets into BOTH note-table builders
  through ONE store method. That keeps "the editor and the corrector cannot disagree about
  what a note is" (`ProjectStore+PitchNoteEdits.swift:259-263`). S3 only goes ahead if S0
  shows onsets actually land near the f0 cuts on the user's take. Otherwise it is dropped,
  with the measurement recorded.

## §2 The over-split guard

F1 (`docs/research/m23-q-pitch-correction-design.md:739`) names two over-split failures: "a
legato slide split into three notes" and "a vibrato peak read as a neighbour note". The guard
is not a separate pass. It is four properties of the §1.3 rule, one per case below. Each case
names the rule that holds it and the fixture that proves it (§5.3).

### §2.1 Steady note with a ±40 c, 5.5 Hz wobble: stays ONE note

- **The rule that holds it: the `P`-frame median track (§1.3 step 2) plus the band `B`.**
  - `P` spans one cycle at 3 Hz (336 ms), which is 1.85 cycles at 5.5 Hz. The median over it
    stays within one detector bin of the note's centre.
  - [MEASURED synthetic] With full 25.8 c quantisation, this held at ±37 c and ±50 c
    readings, at every rate from 3.0 to 9.0 Hz and 16 starting phases.
  - So the whole note is one plateau with `max(y) − min(y) ≤ 51.6 c ≤ B`.
- **A "vibrato peak read as a neighbour note" cannot happen.**
  - A single peak lasts half a cycle: 91 ms at 5.5 Hz, under `T` = 128 ms. It cannot form its
    own plateau.
  - It never survives into `y` anyway. At 3 Hz a half-cycle is 167 ms, longer than `T`, but
    `P` is a full 3 Hz cycle, so `y` cancels it.
- **Low pitch makes this case easier, not harder.** The detector under-reads small wobble,
  and more so below ~110 Hz (brief; vibrato doc §18.1.6). Under-reading shrinks the apparent
  wobble, so the band holds with more margin. The low-pitch risk is octave errors (§8, F-oct).
- **Beyond the design point:** a deeper or slower wobble that breaks the band yields plateau
  FRAGMENTS of one note. Their centres (means over ≥ `P` frames) sit within 50 c of each
  other, so step 4 merges them back. [MEASURED synthetic: ±100 c at 5.5 Hz stayed one note.]

### §2.2 Short onset scoop (≤ 120 ms): stays ONE note, byte-identical to today

- **The rule that holds it: the `S` = 8-frame lead-in limit (§1.3 step 5), plus the emit rule
  (step 6).**
  - A scoop is non-plateau frames before the first plateau.
  - If there are at most `S` of them, they belong to the note.
  - The run then has one plateau and no `.transition` part, so the emit rule returns today's
    `VoicedRun` exactly. Its `centreHz` is the median of all frames, which is what
    `VoicedRun`'s doc says outvotes a scoop (`PitchCorrection.swift:1619-1621`).
  - [MEASURED synthetic: a 120 ms, 300 c scoop into a held note left a 5–6-frame lead-in and
    one part.]
- **The same limit covers a release** (a fall-off at the note end) and a short LINK between
  two notes. A short link is cut at one frame, never turned into a third note.
- **Honest boundary.** A lead-in LONGER than `S` is by definition not a scoop. It is the
  22.6 s case, and what Hard Tune does with it is §3's question. So `VoicedRun`'s claim that a
  scoop is "a minority of frames, so it is outvoted" stays true for ≤ `S`. It is exactly what
  the RED cases break above `S`.

### §2.3 ±8 c detector staircase artefact: stays ONE note

- **The rule that holds it: the 5-frame de-glitch plus the `B` band.**
  - The detector is a 256-bin argmax at ~25.8 c per bin (brief). A ±8 c artefact is a
    fraction of one bin.
  - The worst it can do, alone or on top of wobble, is move `x` and `y` by one bin.
  - `B` = 52 c is set to hold two bins, so a steady note's plateau cannot break on it.
- **Merge check:** even where a bin flip splits a plateau at the band edge, the two fragments
  differ by one bin (25.8 c), under both `τ_long` and `τ_short`, so they merge.
- [MEASURED synthetic: every fixture in §1.4 ran with full-bin quantisation (up to ±12.90 c per
  value, the product's own stated floor, `PitchCorrection.swift:1769-1772`), which is harsher
  than the ±8 c artefact. None over-split.]

### §2.4 The invariance property that makes the guard testable

**Any run that §1.3 does not split comes out as today's `VoicedRun`, field for field.** It
has the same `startSeconds`, `endSeconds`, `centreHz`, `medianConfidence` and `frameCount`.

- This is by construction: step 6's first branch returns the `voicedRuns` element itself, not
  a recomputed one.
- So over-split protection and backward compatibility are ONE property. The §5.2 invariance
  gate checks it on every existing fixture.
- The guard is only as strong as that gate plus the §5.3 fixtures. Perfectly steady
  `Contour.note` fixtures cannot fail it, which is why §5.3 adds real-wobble fixtures.

### §2.5 A slow slide: stays ONE note, the "three notes" case

- **The rule that holds it: `T`.** A slide of about 800 c/s or faster never stays inside the
  `B` band for `T` frames, so it makes no plateau.
- A run that is ONLY a slide has zero plateaus and comes out as today's single note.
- [MEASURED synthetic: 800 c/s over 1 s and 500 c over 0.6 s were both one note at `T = 8`.
  The 1 s slide became 5 notes at `T = 6`. A 600 c/s slide became 4 notes even at `T = 8`.]
- **Known limit:** a glide slower than ~800 c/s (a semitone every ~125 ms or slower) can form
  plateaus and split. At that speed a glide and a slow chromatic run are genuinely
  ambiguous. Recorded as F-slow in §8, not hidden.

## §3 What Hard Tune does to the slide itself

### §3.1 What the question is

The splitter (§1) finds the HELD part of a slide-into-a-note. It holds that part apart from the
slide once the slide lasts more than `S` = 128 ms. Every option below locks the held part to its
own nearest note, which is what the RED gate asks (§5.1). The options differ ONLY in what the
listener hears DURING the slide. That is one axis, and it is the user's to pick (listening rule;
editor doc §17). The splitter emits `.transition` parts. A small mapping inside
`PitchAutoCorrect.editSet` (`PitchCorrection.swift:1723-1735`) turns parts into segments. The
user's pick sets that mapping; the splitter does not change.

### §3.2 The shapes

Each shape is described three ways: what the listener hears on the 22.6 s note, the segments it
writes, and whether today's engine can render it.

**(c) CONTROL: today's median pin.**
- *Hears:* the whole slide and the held note sit on ONE pitch from the middle of the slide.
  [MEASURED RED] G#2+9 c where A#2+41 c was sung.
- *Segments:* one segment per run, `detectedHz` = the run median, `driftScale = vibratoScale = 0`
  (`:1721`). This is simply the pre-p2-seg build.
- If the user PICKS it, the new build reproduces it on the split table. The `.transition` and
  `.held` segments both lock to the nearest note of the WHOLE run's median, with scales 0. So
  the table stays the same for every preset (§3.4).
- *Render today:* yes. It is the handoff page's `pitch-04-hard-tune.mp3`.

**(d) "Straight to the note": ONE note, centred on the held part.**
- *Hears:* no slide at all. The voice starts ON the held note's locked pitch and stays there.
  The first part of the slide is shifted up by as much as the slide was wide: up to ~7 st on
  the 22.6 s note. That is a big shift and may sound processed [INFERRED].
- *Segments:* the same two segments as every other shape.
  - The `.transition` segment keeps its own `detectedHz` (what was sung), so the editor stays
    honest.
  - Its `pitchOffsetCents` aims at the HELD part's target, with `driftScale = vibratoScale = 0`.
  - Both segments then lock to one pitch, so the join is seamless.
- *Render today:* yes. Only the transition segment's offset differs from (a-N).

**(a-T) "Slide kept, note locked": the slide plays as sung, and only the held part is locked.
This is the Melodyne-style two-part shape.**
- *Hears:* the singer's own slide, then the held note snaps onto pitch. A 30 ms crossfade joins
  them: Hard Tune's retune is the 30 ms floor [READ `PitchCorrectionPresets.swift:89-91`].
- *Segments:* the `.transition` part becomes an IDENTITY segment (`pitchOffsetCents = 0`,
  `driftScale = vibratoScale = 1`). The held part becomes today's Hard Tune segment for its
  own median.
- *Render today:* yes. An identity segment contributes zero correction, and abutting gates are
  complementary, so the curve crossfades from "as sung" into the locked note [READ
  `PitchCorrection.swift:1340-1360`, `:1375-1383`].
- *Why a segment and not a gap:* the curve also returns plain identity where no segment covers
  a time (`totalGate ≈ 0` → `clipPitchShiftSemitones`, `:1353`), so a gap would sound the same.
  But it would be a voiced stretch with no note drawn over it, a state the editor has never
  drawn and the user could not grab. The identity segment is a real, editable note.

**(a-N) "Slide as its own note": the slide becomes a short note locked to ITS median, then the
held part is locked separately.**
- *Hears:* two stepped pitches. The slide region holds one in-between note for ~0.4 s, then
  jumps to the held note.
- *Segments:* the `.transition` part gets today's Hard Tune treatment for its own median.
- *Render today:* yes.
- It is kept as the fallback 4th option, not a first choice: it is (c)'s pin made shorter.

**(b) "Robot staircase": every frame snaps to its nearest scale note, so the slide climbs in
semitone steps. This is the classic hard auto-tune sound.**
- *Segments to SHIP it:* a per-note "quantise the contour" mode. That means a new branch in
  `PitchCorrectionCurve.make`'s shaping (`PitchCorrection.swift:1330-1345`), a new additive
  `NoteSegment` field with a decode default, a `shapingVersion` bump (`:1542`) because renders
  change, a new `PitchEditSetDigest` input, and an editor drawing for it. **This is engine and
  model work** (audio-dsp-engineer), not part of p2-seg's first delivery.
- *Listening PROTOTYPE today:* one segment per stretch of frames that share a nearest note,
  built directly in the render harness (§3.3). No shipped code changes. Two cautions [READ]:
  - The curve is read once per 30 ms hop (`PitchCorrection.swift:734-737`, `:760-762`).
  - The fastest RED slide climbs a semitone in ~57 ms, which is under 2 hops.
  - So the prototype's steps may blur into a glide. The harness MUST check the render actually
    steps. Test: the YIN of the render shows at least 3 distinct flat regions inside the slide.
    If it does not, the (b) prototype is not what (b) would sound like, and (a-N) replaces it
    in the set. Say so on the page (audibility rule).
  - Whether the curve accepts segments shorter than the 30 ms ramp is [INFERRED], not read.
    The harness finds out.

### §3.3 The listening set: 4 renders of THEIR take, one axis

- **Source.** The user's own take that the busy-line check measured (vibrato doc §18.5,
  `docs/design/2026-09-24-pitch-editor-vibrato-handle.md:2032-2068`).
  > ⚠ **Orchestrator correction, 2026-09-24 [READ]:** the take and the scripts are located, not
  > gone. The user's ORIGINAL is `~/Downloads/dry-vocals.m4a` (2026-09-22 21:12). The measured copy
  > is the session scratchpad's `vocal/dry-norm.wav` (48 kHz, 33.3 s, made from it at 21:16). The
  > physics scripts are the scratchpad's `busyline/physics-ht-check.py`, `-all.py`, `-livelook.py`
  > and `busyline-common.py`, run with `busyline/.venv`. The real risk is that the scratchpad
  > lives in `/private/tmp` and does not survive a reboot. So **S1's first step** copies the
  > take and the scripts to `~/Music/DAW Pro Dogfood/2026-09-24 p2-seg physics/`, outside the
  > repo because it is the user's voice, and records its requirements.
- **Renders.** All four use the Hard Tune preset and the same key/scale as the handoff page's
  `pitch-04-hard-tune.mp3`. They differ ONLY in the slide mapping:
  1. (c) today, as the control;
  2. (d) straight to the note;
  3. (a-T) slide kept, note locked;
  4. (b) robot staircase prototype, or (a-N) if (b)'s render fails its step check.
- **Harness.** An env-gated DAWEngineTests suite, in the house pattern of
  `ContourShapingSweepTests` (`Tests/DAWEngineTests/ContourShapingSweepTests.swift:35`).
  It runs the product detector, builds each edit set directly, and renders through the
  PRODUCT's offline renderer (`StretchRenderCache`/`OfflineStretcher`, the path
  `ProjectStore+PitchCorrection.swift:60-62` names). Never a python imitation.
- **Checks before a render goes on the page:**
  - RED gate physics on the held tails (§5.1) for renders 2–4;
  - true peak ≤ −1 dBTP AND loudness (a loudness meter does not look up);
  - (b)'s step check.
  - Trim each render to a ~6–8 s excerpt spanning 16.4 s and 22.6 s. Put a 1-line plain
    description under each (novice rule).
- **The ONE question, in the user's words:** *"When the singer slides up into a note, which of
  these sounds most like what you want 'Hard Tune' to do?"* The labels are the plain names
  above, never the letters.
- **Where:** the existing handoff page (rewritten in place, same URL, per the handoff-artifact
  preference). The answer is read from the page's decision slot.

### §3.4 What the other three presets do: not a vote, but stated

Gentle, Natural and Tight keep vibrato (`preserveVibrato: true`,
`PitchCorrectionPresets.swift:79-87`) and move each note by ONE constant.

- With the splitter, each held part gets its own constant, and a `.transition` gets the
  identity mapping in EVERY shape.
- Reason: a slide has no centre to move, and moving it by a constant shifts the whole sweep by
  an arbitrary ±50 c [INFERRED].
- This is an architect call because it follows from "one note table for every preset": the
  editor must draw the same notes whichever preset is picked.
- It IS audible on this take. §5.1 gates it with physics, and §9 Q2 offers it to the user as a
  veto, with a Natural before/after pair on the same page as information, not a second vote.

## §4 Stored edits and compatibility

### §4.1 A stored table is never re-segmented, by construction

[READ] Segmentation runs in exactly two builders, and after S2 those two are the only callers of
the splitter:

1. **`PitchAutoCorrect.editSet`**, called by `autoCorrectClipPitch`
   (`ProjectStore+PitchCorrection.swift:113-114`). That is an explicit new pass.
2. **`PitchNoteTable.detected`**, called by `PitchEditorModel.apply`
   (`PitchEditorModel.swift:1575-1580`). Its result is a SEED held in the view model. It is
   "NOT written to the store: opening a viewer must not dirty a project". It reaches the store
   only as `seedIfAbsent` on the first edit, and only when the clip has no table. From then on
   "THE STORE IS THE TRUTH" (`PitchEditorModel.swift:1593`).

Nothing runs segmentation on load, on project open, on render, or in `syncStoredNoteTable`. So:

- **No migration.** Nothing runs over existing projects when the app opens them.
- An old table plays exactly as it did, with its old boundaries, for as long as it exists.

"Never re-segment" means never AUTOMATICALLY. A user or agent who runs a preset again with
`replaceExisting: true` (the default, `ProjectStore+PitchCorrection.swift:76-79`) asks for a new
pass. That pass uses the new splitter. That is today's contract, unchanged.

### §4.2 C-F3 `replaceExisting` and the hand-edit stamp: unchanged, and still correct

[READ `ProjectStore+PitchCorrection.swift:108-111`, `:131-134`, `:136-142`]

- The stamp records the content a pass wrote. `hasHandEditsSinceAutoCorrect` compares the table
  as it is NOW with that record.
- An untouched table written by the OLD splitter still reads as "exactly a preset's output". So
  `replaceExisting: false` goes ahead and the new pass replaces it. That is correct: nothing done
  by hand is lost.
- A hand-edited table still refuses under `false`. The splitter changes none of this, and the
  stamp does not care how the segments it covers were produced.
- **One ordering rule for S3** (the onset wiring):
  - Fetching onsets adds a second `await` to `autoCorrectClipPitch`.
  - That await MUST sit BEFORE the post-await relocate and C-F3 re-check (`:116-134`), so the
    re-check still reads the table as it is after EVERY await.
  - A test in the shape of the existing "hand edits made WHILE detection was still running"
    test (`Tests/DAWControlTests/PitchCorrectionCommandTests.swift:1265`) must land a hand-edit
    during the onset await and see the refusal.

### §4.3 Undo

- Unchanged. A pass is still ONE `performEdit("Auto-Correct Pitch", key: structuralKey)`
  (`ProjectStore+PitchCorrection.swift:143-148`).
- One undo restores the previous table whole, however many parts the splitter made. There is no
  new coalescing key.

### §4.4 The wire: additive only, and v1 adds nothing

- **`clip.autoCorrectPitch`**
  - Its accepted keys (`Sources/DAWControl/Commands.swift:5105`) and response are untouched in
    S2. New passes simply come back with more segments where a run had a note change.
  - The slide shape is a policy constant (the user's §3 pick), not a per-call option. So
    `PitchAutoCorrectOptions` gains no field.
  - This matters because it is Codable and echoed on the wire as `appliedOptions`
    (`Commands.swift:13786`).
- **If the user wants more than one shape available** (§9 Q1 option), each becomes a named
  optional key. It has a `decodeIfPresent` default equal to the picked shape, and ships with an
  MCP tool field and a test. That is additive, never a rename.
- **S3's one additive field.** The response gains `onsetsUsed: Bool`, so an agent can tell an
  onset-refined pass from an f0-only one.
  - An onset fetch that throws or has no engine falls back to f0-only placement. §1.5 says why
    that fallback is safe.
  - That fallback must be VISIBLE, never silent.
- **MCP.** `mcp-server/src/server.ts` holds the `clip.autoCorrectPitch` tool (positive control:
  the file contains `autoCorrectPitch`).
  - [MEASURED by me] A grep of `mcp-server/src` and `Sources/DAWControl` for "voiced run",
    "unbroken", "legato", "slur" and "one note per" found no claim that auto-correct makes one
    note per run. Every hit was about the sampler's `voiceMode`.
  - S2 still re-reads the tool's description once and updates any line that implies "one note
    per phrase".

### §4.5 The editor's own note seeding: YES, it goes through `voicedRuns` today

[READ] `PitchEditorModel.apply` seeds its note table with `PitchNoteTable.detected(from:)`
(`PitchEditorModel.swift:1580`), which calls `voicedRuns`
(`ProjectStore+PitchNoteEdits.swift:272`). That builder's banner promises that the editor and the
corrector "cannot disagree about what a note is" (`:259-263`).

- **S2 therefore moves BOTH builders to the splitter in ONE change.** Moving only `editSet`
  would make a fresh editor seed show one note where Hard Tune just wrote two.
- **What stays on `voicedRuns`, deliberately:**
  - the editor's measured contour (`contourRuns`, `PitchEditorModel.swift:1564-1571`);
  - the played line (`PitchPlayedLine.swift:277`).
  Both are per RUN, so a cut never draws a hole where the singer did not stop.
- **Frame ownership still holds.** `noteSummaries` gives each frame to a segment by its frame
  CENTRE inside `[start, end)` (`PitchPlayedLine.swift:343-347`). Parts cut at frame STARTS
  split a run's frames exactly, so an untouched part still owns exactly its own frames.
- **Two meanings of "split" now coexist, on purpose.**
  - The manual scissors (`splitClipNoteSegment`, `ProjectStore+PitchNoteEdits.swift:128-165`)
    copy the parent to both halves, `detectedHz` included (`:149-151`). They split an EDIT and
    keep it.
  - The automatic splitter gives each part its own median. It segments a DETECTION.
  - For a clip ALREADY corrected with the old splitter, the manual route (cut, then drag each
    half) is still the fix, or clear and run the preset again. §9 Q3 asks whether the user wants
    a one-click "re-split this clip".

### §4.6 Persistence, versions, timing

- **No new persisted field for shapes (c), (d), (a-T) or (a-N).** Each writes ordinary
  `NoteSegment`s, and an identity segment is just a note with offset 0 and scales 1. Shape (b)
  adds one field and is its own item (S6).
- **`analysisVersion`: do NOT bump it for the splitter.** The detector did not change, and a
  stored table's boundaries stay valid for that table.
  - Before S2 merges, the implementer greps every consumer of
    `PitchEditSet.currentAnalysisVersion` [INFERRED: not read here].
  - If any consumer turns a version mismatch into a user-visible "stale" prompt, bumping would
    fire that prompt on every corrected project. That is a regression.
  - Add no `segmentationVersion` either. Nothing reads it, since segments are explicit data.
- **C2 timing and the vibrato handle** consume segments, not runs. `PitchTimeWarp`'s rule for
  notes at source edges (`PitchTimeWarp.swift:60`) applies to parts exactly as it does to runs,
  because a part at a run edge IS at that edge.

## §5 Gates

### §5.1 The physics gate on the user's take (RED today)

Measured on the RENDER, by an INDEPENDENT tracker (an exact YIN, as in the busy-line check). Never
on the product's own contour.

- **Pass condition, as a RULE against the render's own scale** (it generalises editor doc §17,
  `docs/design/2026-09-22-pitch-editor-ui.md:1564-1569`). For each held tail:
  - the render must read, ±30 c, EITHER `scale.nearestAllowedMidi(plateau median)` for the
    scale the render was made with, OR the second-nearest ALLOWED note when that one is within
    60 c of the sung plateau median;
  - anything else fails.
  - ⚠️ Never hardcode note names. On a scale without C#, a CORRECT fix of the 16.8 s tail reads
    C3 or D3, and a chromatic-only rule would call it RED.
  - **S1 records the scale** that `pitch-04-hard-tune.mp3` used. Every §3.3 render uses it.
- **Worked example, chromatic** (the editor doc's own wording):
  - the 23.05–23.2 s tail, sung A#2+41 c, must read A#2 (41 c) or B2 (59 c), ±30 c. G#2
    fails.
  - the 16.8–17.0 s tail, plateau median D3−1 c (product frames; it wobbles ±85 c), must read D3.
    ⚠ Corrected by the orchestrator 2026-09-24 from "sung C#3+13 c, must read C#3": that figure was a
    tracker-mask artefact (§11.4). The "sung plateau median" in this rule is §1.3's own emitted median
    from the PRODUCT's frames; the independent tracker measures the RENDER only.
- **RED baseline** [MEASURED 2026-09-24 by audio-dsp-engineer, two renders]:
  - 23.05–23.2 s reads G#2+9 c;
  - 16.8–17.0 s reads A#2−11 c;
  - 5 of 42 notes play ≥ 1 st away from what was sung for most of their length: 0:07.6,
    0:09.2, 0:16.4, 0:22.6 and 0:31.4 (vibrato doc §18.5).
- **GREEN requires, for each of the §3 shapes (d), (a-T) and (a-N)/(b):**
  - both tails pass;
  - for each of the five named notes, its HELD part plays the rule's allowed target(s) above,
    ±30 c, for most of the held part's length.
  - Not "within 1 st of what was sung": on a scale, a CORRECT snap can legitimately sit up to
    ~100 c from the sung pitch.
  - ⚠ **Run 28 (23.712 s) is a SIXTH RED-shaped note** (R1 §13.4, added by the orchestrator 2026-09-24,
    §14): MEASURE and REPORT it on every render. At T = 8 its 7-frame tail is absorbed and is
    [INFERRED] ~165 c flat: an accepted, recorded cost, NOT a pass condition at T = 8.
  - Shape (c) is the control and must still FAIL. If (c) passes, the tracker or the alignment
    is broken, not the product fixed.
- **Tracker controls** (the §18.5 method):
  - the uncorrected render reproduces the sung pitches;
  - a planted +800 c glitch is caught;
  - a planted octave error is caught.
  - A tracker that cannot fail is not a gate.
- **Count bound on the take:**
  - Report the total part count against today's 42, and list every split run with its parts.
  - No run may split into more `.held` parts than it has plateaus ≥ `T` that are ≥ `τ` apart.
    §1.3 guarantees this; ASSERT it anyway.
  - Someone LOOKS at the five named notes in the pitch editor before the item closes. A UI
    phase isn't done until someone looked.
- **Other presets:**
  - Under Natural, no held part may play further from its nearest note than it did before
    p2-seg (render vs render, same tracker).
  - Every `.transition` region under Natural must render within ±5 c of the UNCORRECTED render,
    since identity is what §3.4 promises.
- **The take and scripts.** Located (§3.3's correction); S1 makes them durable first.

### §5.2 The invariance control: no note change → today's segment, byte for byte

- **Unit.** For every contour in the existing fixtures, `PitchNoteSplitter.parts` must map 1:1
  onto `PitchAutoCorrect.voicedRuns` with equal `startSeconds`, `endSeconds`, `centreHz`,
  `medianConfidence` and `frameCount` (`VoicedRun` is `Equatable`,
  `PitchCorrection.swift:1616`). The fixtures are those the current `voicedRuns` callers build:
  - `Tests/DAWCoreTests/PitchCorrectionTests.swift:303`;
  - `Tests/DAWCoreTests/PitchCorrectionWriterTests.swift:320`;
  - `Tests/DAWAppKitTests/PitchEditorModelTests.swift:311` and `:393`;
  - `Tests/DAWEngineTests/M23QDetuneRepairTests.swift:49` and `:130`;
  - `Tests/DAWEngineTests/ContourShapingSweepTests.swift:35`;
  - `Tests/DAWEngineTests/ContourToRenderTests.swift:704`;
  - `Tests/DAWEngineTests/PitchWobbleDetectorTests.swift:95`.
  Exception: a fixture that really contains a note change must be NAMED and explained. It is
  not quietly excluded.
- **Edit set.** `PitchAutoCorrect.editSet` output on those fixtures equals the pre-p2-seg
  output field by field.
  - A segment `id` minted per call is excluded, if ids are minted per call [INFERRED — the
    implementer checks `NoteSegment.init`].
  - Better: compare `PitchEditSetDigest.hex` if it excludes ids. Its stamp exclusion is READ at
    `ProjectStore+PitchCorrection.swift:140-141`; its id handling is not.
- **Render bytes.** Every existing render byte gate (e.g. `ContourToRenderTests`) passes
  UNCHANGED. Re-baselining any of them is a failure of this gate, not a fix.
- **The gate must be able to fail.** Plant a defect in the no-split branch, for example
  centre = MEAN instead of median, and show §5.2 goes red. Then revert. A byte gate over
  renders alone is blind to a decode default (gate law §2026-09-20i). That is why the unit and
  edit-set legs exist as well as the render leg.

### §5.3 The over-split fixtures, one per §2 case, each with a twin that MUST split

New suite `Tests/DAWCoreTests/PitchNoteSplitterTests.swift`. The fixtures are contours built
directly, quantised to the detector's ~25.8 c bins so the staircase is present.

| §2 case | Fixture: must be ONE part, equal to `voicedRuns` | Twin: MUST split, proving the fixture can fail |
|---|---|---|
| 2.1 wobble | ±37 c reading (a true ±40 c, per the brief's under-read) at 5.5 Hz, 1 s, 16 phases. Also at 3.0 and 9.0 Hz. | The same wobble on two 0.5 s notes 199 c apart: 2 `.held` parts, cut at 0.5 s ± 1 frame. |
| 2.2 scoop | A 120 ms, 300 c linear scoop into a 0.6 s held note. | The same shape with a 400 ms slide: `.transition` + `.held`, held centre within ±15 c of the tail. |
| 2.3 staircase | A steady note with a ±8 c staircase that flips every frame. | A 100 c step between two 0.6 s notes: splits. |
| 2.5 slow slide | An 800 c/s slide over 1 s: ONE part (F1's "three notes"). | The same slide ending in a 0.2 s hold: `.transition` + `.held`. |
| glitch (§1.4) | A 2-frame octave glitch mid-note. | A 12-frame octave excursion: splits. This is recorded behaviour (§8 F-oct), not an endorsement. |

**Threshold pins.** Each constant gets a pair of fixtures one frame or one cent either side of
it: `T` (a held tail of `T` frames splits, `T − 1` does not), `S`, `B` and both `τ`. A later
edit to a threshold then fails loudly instead of drifting.

**The real detector, not just contours.** One env-free DAWEngineTests case:
- Synthesise a ±40 c, 5.5 Hz vibrato tone at 106 Hz (this singer's median) and at 220 Hz.
- Run the PRODUCT detector over it, then the splitter.
- Pass: ONE part each.
This catches real detector artefacts (low-pitch under-read, the argmax staircase) that
hand-built contours cannot. Precedent: `PitchWobbleDetectorTests.swift:95` runs `voicedRuns` on
detector output.

### §5.4 The existing legato pin: REWRITTEN on purpose, and named

- **The test.** `Tests/DAWCoreTests/PitchCorrectionTests.swift:559-583`,
  `legatoSlurIsOneSegmentToday` ("KNOWN PHASE-2 LIMIT: a legato slur is ONE run, and the pin
  says so"). It expects `segments.count == 1` for 440 Hz then 494 Hz, 0.5 s each, with no gap.
- **The rewrite**, under a new name such as `legatoSlurSplitsAtTheNoteChange`:
  - `segments.count == 2`, cut at 0.5 s ± 1 frame;
  - each segment's `detectedHz` is its own median (440 / 494 Hz, ±1 c);
  - under C major the targets are A4 and B4.
- **KEEP both existing controls:**
  - the 200 ms hole twin, which is still 2 segments;
  - a new assertion that `voicedRuns` on the SAME frames still returns ONE run. That pins the
    per-run contract the played line depends on (§0 point 1).
- **Doc comments to rewrite in the same change**, so no source keeps the old claim:
  - `VoicedRun`'s doc (`PitchCorrection.swift:1605-1615`), which says "a test pins exactly
    that". `voicedRuns` stays the RUN rule, and notes now live in `PitchNoteSplitter`.
  - `PitchNoteTable`'s banner (`ProjectStore+PitchNoteEdits.swift:259-263`) and the editor's
    comment (`PitchEditorModel.swift:1558-1563`), which both say segmentation is `voicedRuns`'
    job.
- **Suite rule.** `./scripts/test.sh` (never bare `swift test`) must be green.
  - Any test OTHER than this pin whose expectation changes is a FINDING. Name it in the report
    with the reason, never re-baseline it silently. A net delta hides a shrink.
  - MCP tests should not move in S2, because no wire change happens there.

## §6 Items, routes, order

**Order:** S1 → (S2 ∥ L) → *(the user's pick, §9 Q1)* → S2-close → S3 (only if S1 says go) → S4.
L runs IN PARALLEL with S2, because the user's pick is the long pole.
S5, S6 and S7 are conditional follow-ups, not scheduled. Every agent brief carries the standing
constraints:
- commits only on the user's word;
- port 17600 is the user's live app (staging is 17695, killed pidfile-exact);
- no `git checkout/stash/restore/clean`;
- never touch user audio devices, `.env`, `scripts/ace-step/` or `scripts/rvc/`;
- `./scripts/test.sh`, never bare `swift test`;
- kill the ACE sidecar pid-exact if anything starts it.

### S1: measure the take (no product code). Route: `audio-dsp-engineer`

1. **Find the user's take** that the busy-line check measured (vibrato doc §18.5). Rebuild the
   independent physics:
   - an exact YIN over RENDERS;
   - the uncorrected-render alignment control;
   - a planted +800 c glitch and a planted octave error, both caught.
   Reproduce the RED baseline: G#2+9 c at 23.05–23.2 s and A#2−11 c at 16.8–17.0 s, ±5 c.
   **If it does not reproduce, STOP and report.** A gate that cannot see the defect cannot
   see its fix.
2. **From the product's own frames** (`clip.detectPitch` on staging, or the detector in an
   env-gated test), for each of the five named notes (0:07.6, 0:09.2, 0:16.4, 0:22.6, 0:31.4):
   - classify the shape (slide into a hold, run of short notes, other);
   - measure the lead-in and held-tail lengths in frames;
   - measure the plateau median.
   **Check:** `T` = 8 frames is below every held tail, and `S` = 8 is below every RED lead-in,
   each by ≥ 2 frames. If either fails, the §1.4 bound is wrong for this singer. Report
   before S2 starts; do not quietly retune.
3. **Onset recall.** `detectTransients(sensitivity: 0.5)` on the take's source file. For each
   §1 cut in step 2, is there a marker within ±2 frames? This decides S3 (go if most cuts
   have one).

**Output:** a short record appended to this doc as §11, with numbers, never "looks fine".

### S2: the splitter (DAWCore, pure). Route: `audio-dsp-engineer`

- **New file `Sources/DAWCore/PitchNoteSplitter.swift`:** `NotePart` and
  `PitchNoteSplitter.parts(in:frameRateHz:onsetSeconds:)`, per §1.3. All frame counts are
  derived from `frameRateHz` and from:
  - `PitchWobbleEstimate.scanRangeHz.lowerBound` (`PitchWobbleEstimate.swift:127`);
  - `PitchAutoCorrect.minimumNoteSeconds` (`PitchCorrection.swift:1648`).
  Each constant carries its §1.4 bound in a doc comment.
- **`Sources/DAWCore/PitchCorrection.swift`:**
  - `editSet` (`:1713-1735`) consumes parts. It maps a `.transition` through ONE named constant,
    the slide shape, and applies identity for the preserve-vibrato presets (§3.4).
  - Rewrite the `VoicedRun` doc (`:1605-1615`) so it describes `voicedRuns` as the RUN rule.
- **`Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`:** `PitchNoteTable.detected`
  (`:266-283`) consumes parts in the SAME change. Rewrite the banner (`:259-263`).
- **`Sources/DAWAppKit/PitchEditorModel.swift`:** a comment-only rewrite at `:1558-1563`. The
  contour stays on `voicedRuns`.
- **Tests:**
  - new `Tests/DAWCoreTests/PitchNoteSplitterTests.swift` (§5.3 fixtures and threshold pins);
  - the §5.2 invariance legs, with a planted defect proven to fail them;
  - the §5.4 legato-pin rewrite, NAMED in the report;
  - the §5.3 real-detector wobble case in DAWEngineTests.
- **Before merge:** grep every `currentAnalysisVersion` consumer (§4.6); re-read the
  `clip.autoCorrectPitch` MCP description (§4.4).
- **Can be written and gated before the pick.** The shape constant is set to the user's
  answer in **S2-close**, which then runs the §5.1 physics gate on the picked shape. S2 is not
  done until §5.1 is GREEN on the take and someone has LOOKED at the five notes in the editor.

### L: the listening set. Route: `audio-dsp-engineer` renders; the orchestrator publishes

- **Depends on S1 only.** The harness builds the four edit sets from S1's MEASURED part
  boundaries (a hand-specified cut list for the listening excerpts), so it does not wait for
  S2's code.
- When S2 lands, S2-close re-renders the picked shape with the REAL splitter and runs §5.1 on
  that render. The listening renders are evidence for the pick, not the gate.
- Render per §3.3: 4 renders, the env-gated harness, the product renderer, and the pre-page
  checks (physics, true peak AND loudness, (b)'s step check).
- Publish on the handoff page, rewritten in place, with ONE question. Kill any sidecar
  pid-exact afterwards.

### S3: onset placement. Only if S1 step 3 says go. Routes: `audio-dsp-engineer` (store + core), `mcp-integration-engineer` (wire field + MCP), `swift-app-engineer` (editor loader)

- ONE store method returns the clip's onsets as source-file seconds, cropped to the detection
  window (e.g. `clipNoteOnsetSeconds(clipId:) async -> [Double]?`, where `nil` means
  unavailable). Both builders use it:
  - `autoCorrectClipPitch`, with the await BEFORE the C-F3 re-check (§4.2);
  - the editor's loader, which passes the onsets into `PitchNoteTable.detected`.
- Additive `onsetsUsed: Bool` on the `clip.autoCorrectPitch` response, with an MCP tool doc
  line and a test.
- **Planted-onset time-base test:** a fixture file with a click at a known SOURCE second
  proves markers and frames share a time base (§1.5, currently [INFERRED]).
- A hand-edit-during-onset-await refusal test (§4.2).

### S4: docs. Route: `docs-scribe`

- CHANGELOG entry, and the ROADMAP p2-seg checkbox.
- A status line at the head of editor doc §17 pointing here.
- **The `docs/ARCHITECTURE.md` "Key future decisions" entry I OWE but could not write** (this
  task limited me to this file). Text to add verbatim:
  > **Note segmentation (p2-seg, 2026-09-24):** a note is a PART of a voiced run, found by
  > `PitchNoteSplitter` (f0 plateaus; onsets only place a cut). `voicedRuns` stays the RUN
  > rule, and the contour and played line stay per run. Stored tables are never
  > re-segmented. Design: `docs/design/2026-09-24-pitch-note-splitting.md`.

### Conditional follow-ups: filed, not scheduled

- **S5: same-pitch re-articulation.** An onset with no pitch change splits a note. It needs
  its own guard (a voiced consonant inside a held note must not split) and its own design.
- **S6: the staircase for real**, only if the user picks (b). An additive `NoteSegment` field,
  a curve shaping branch, a `shapingVersion` bump, a digest input, editor drawing, and a wire
  field + MCP. Routes: `audio-dsp-engineer` + `swift-app-engineer`, with a `daw-architect`
  review first.
  - [INFERRED] The curve feeds the OFFLINE stretch render (`StretchRenderCache`), not the
    real-time render thread. S6's review must confirm that before any per-frame quantiser is
    added.
- **S7: one-click "re-split this clip"**, only if §9 Q3 says yes. It re-segments a table
  while keeping hand edits, which is a merge problem. Its own design.

## §7 Alternatives considered and why they lose

### The two strongest alternatives

**A1. An HMM note decoder, Viterbi over semitone note states (the pYIN/Tony shape). The
textbook answer, and the strongest rival.**
- It models attack, stable and silent states per semitone, and finds note changes and slides
  in one optimisation.
- **Why it loses for p2-seg:**
  - It needs a dozen transition and emission probabilities. None of them is bounded by a fact
    this repo holds, which is exactly the "picked, not bounded" shape the brief forbids.
  - Its note pitch is still a median afterwards, so it buys nothing on the measured defect.
  - It cannot promise §2.4's byte-identical output on unsplit runs: a Viterbi path moves
    boundaries it has no reason to move.
  - The one reference implementation is GPL and was already rejected on licence (m23-q §9:
    "GPL knocked out the pYIN reference implementation"). So it would be a from-the-paper
    re-implementation.
- **When it wins:** it is the right ESCALATION if F-semi (§8) proves common on real takes,
  meaning semitone steps between short notes stay merged.

**A2. Change `voicedRuns` itself to split at note changes.** This is the smallest diff, and
what "THE SEAM PHASE 2 REPLACES" literally invites.
- **Why it loses:** `voicedRuns` is also the RUN rule for the contour and the played line,
  and both are per run on purpose.
  - Splitting inside it draws "a 16 ms hole where the singer never stopped"
    (`PitchPlayedLine.swift:104-110`, `PitchEditorModel.swift:1565-1571`).
  - It also silently reinterprets every test and consumer that uses it as a run primitive (the
    nine call sites in §5.2).
- The seam is replaced at the NOTE level, and the run rule stays.

### Weaker alternatives, and the fact that sinks each

- **A slope (derivative) threshold.** The peak slope of a ±40 c, 5.5 Hz wobble is
  40 · 2π · 5.5 ≈ 1380 c/s ≈ 22 c/frame. A 700 c slide over 0.5 s is 1400 c/s ≈ 22 c/frame.
  Slope cannot tell them apart. Displacement that PERSISTS can, and that is the plateau test.
- **Onsets as the primary splitter.**
  - A legato slide has no consonant.
  - Spectral flux fires on voiced consonants INSIDE held notes.
  - An onset-only cut breaks §2.4 invariance on same-pitch runs.
  - Onsets are kept for PLACEMENT only (§1.5).
- **A two-window median change-point test with no plateau stage.**
  - [MEASURED synthetic] Medians of bin-quantised frames jump in whole bins. Two opposing
    one-bin errors reach 51.6 c even over full-cycle windows, and 103 c over 4-frame windows
    at a ±50 c reading.
  - So its threshold must sit above the very semitone it has to detect.
  - It also needs a second rule for a slide that STARTS the run, which is the RED case.
- **Splitting only for Hard Tune, keeping one note per run for the other presets.** Then the
  note table would depend on the preset, and the editor would redraw a different number of
  notes when the user switches from Gentle to Hard Tune. That breaks "the editor and the
  corrector cannot disagree about what a note is" (`ProjectStore+PitchNoteEdits.swift:259-263`).

## §8 Failure modes

Ordered roughly by likelihood × damage. Each gives the symptom, then the cause, then the
mitigation.

- **F-inv: every existing correction shifts by a few cents.**
  - *Symptom:* every render byte changes after a "harmless" refactor.
  - *Cause:* the no-split branch recomputes its centre, for example from the de-glitched `x`
    instead of the raw frames.
  - *Mitigation:* §2.4 makes the no-split output the `voicedRuns` element itself. §5.2 checks
    it three ways (unit, edit set, render bytes), with a planted defect proving the gate can
    fail.
- **F-over: a real held note is split, and Hard Tune invents a step.**
  - *Symptom:* a wide or slow vibrato beyond the design point, or a drift of ≥ 50 c between
    two long plateaus, comes out as two notes a semitone apart.
  - *Cause:* the tiers are tuned to the ±40 c design wobble.
  - *Mitigation:*
    - the merge tiers (§1.3 step 4);
    - the §5.3 fixtures at 3–9 Hz and ±50 c [MEASURED synthetic: ±100 c at 5.5 Hz stayed one
      note];
    - S1's look at the take.
  - *Residual:* the manual fix is merging the two notes back. Whether the editor HAS a merge
    gesture was not checked here (§10). F1 wants split AND merge to be first-class.
- **F-slow: a slow glide becomes several notes.**
  - *Symptom:* a glide slower than ~800 c/s splits into semitone-sized `.held` parts, and Hard
    Tune then plays a staircase the user did not pick.
  - [MEASURED synthetic: 600 c/s over 1 s gave 4 parts.]
  - *Cause:* `T` protects only against slides fast enough to cross a band in under `T` frames.
  - *Mitigation:* S1 measures the take's real slide speeds. If any is under ~800 c/s, add the
    within-plateau trend test (first-third vs last-third median) before raising `T`, because
    raising `T` eats the ~150 ms held tails.
- **F-semi: a semitone step between short notes stays one note.**
  - *Symptom:* two notes < 336 ms long and ~100 c apart stay merged.
    [MEASURED synthetic: 2–4 parts of 4 across phases.]
  - *Cause:* `τ_short` = 100 c sits right on the step.
  - *Mitigation:* this is the safe direction (today's behaviour for those notes). The manual
    scissors remain. A1 (the HMM decoder) is the escalation if it proves common.
- **F-oct: an octave error becomes a note.**
  - *Symptom:* an octave excursion long enough to survive the de-glitch and `y` becomes its own
    `.held` part, drawn an octave off in the editor.
  - *Render effect:* that part's offset is only its own snap distance, so it plays near as
    sung. Today's flatten-to-the-run-median would shift those frames by the full octave, so
    this is the less damaging failure [INFERRED from `editSet`'s arithmetic,
    `PitchCorrection.swift:1724-1726`].
  - *Mitigation:* the editor shows the detected pitch, so a wrong octave is visible. §18.5
    found only 3 isolated octave-high frames on this take, which the 5-median removes. §5.3
    pins the behaviour.
- **F-time: onset cuts land off by the clip's offset.**
  - *Symptom:* every onset-placed cut is shifted by the clip's source offset.
  - *Cause:* markers are source-file seconds [READ], and the frames are only [INFERRED] to be.
  - *Mitigation:* S2 ships no onsets. S3's planted-onset test must pass first.
- **F-race: a hand edit is replaced despite `replaceExisting: false`.**
  - *Cause:* S3's onset await was placed AFTER the C-F3 re-check.
  - *Mitigation:* the ordering rule and test in §4.2.
- **F-preset: Gentle/Natural/Tight sound different on runs that change note.**
  - *Cause:* this is intended (§3.4), but it is audible.
  - *Mitigation:* the §5.1 Natural legs (never further from the nearest note than before;
    transitions within ±5 c of the uncorrected render), and the §9 Q2 veto.
- **F-novice: a `.transition` note looks broken.**
  - *Symptom:* under (a-T), the slide is a real note with no correction. A novice may read
    "this note isn't tuned".
  - *Cause:* nothing in the model marks it as a transition. v1 adds no `kind` field.
  - *Mitigation:* the page text for Q1 says what the listener hears. A persisted marker for
    the editor is left open (§10) until the user has seen it.
- **F-stale: old clips keep the old notes.**
  - *Symptom:* clips corrected before p2-seg keep one note per run.
  - *Cause:* intended (§4.1).
  - *Mitigation:* re-running the preset re-splits an unedited table. §9 Q3 covers the rest.
- **F-RT: none identified.**
  - The splitter is pure DAWCore on the main actor. It costs O(frames × `P` log `P`): about
    15,000 frames × 21 for a 4-minute take, which is milliseconds [INFERRED].
  - Onsets come from a detached-task cache (`AudioEngine.swift:2238-2245`).
  - Nothing reaches the render thread.

## §9 Needs the user's word

Offer these; never assume. They go on the existing handoff page (rewritten in place, same URL).
The answers are read from the page. Q1 is a LISTENING question (4 renders, one axis). Q2 and Q3
are yes/no with a default, so they block nothing.

**Q1. "When the singer slides up into a note, what should Hard Tune do?"** (§3; the renders
come from item L)

| Option (plain label on the page) | What you hear | Engine work |
|---|---|---|
| Today's sound (control) | The slide and the note sit on one in-between pitch | none |
| Straight to the note | No slide; the voice starts right on the locked note | none |
| **Slide kept, note locked** *(recommended)* | Your own slide, then the note snaps onto pitch | none |
| Robot staircase | The slide climbs in semitone steps | yes (S6); prototype render only |

> **Amended 2026-09-24 by §15.1:** the page's fourth option is **In-between note** (the slide
> becomes one short note at its own median, Hard-Tuned, then steps up to the held note; engine
> work: none). The staircase prototype produced no audible steps, so it is not offered.

- **Recommendation: "Slide kept, note locked"**, because:
  - it keeps the slide, which is performance, not error;
  - it fixes the held note the gate measures;
  - it needs no new DSP;
  - it is the Melodyne-style shape F1 points at.
- **If they pick "Robot staircase":** S6 gets scheduled. The page also asks which option Hard
  Tune should use until then, as a one-line runner-up tick. That is the same axis, so it is
  not a second question.
- **If they pick "Today's sound":** p2-seg still ships the splitter for the other presets and
  the editor, and Hard Tune keeps the median pin. The §5.1 gate is then withdrawn for Hard
  Tune, by their word.

**Q2 (a veto, default yes). "Use the same note splitting for Gentle, Natural and Tight."**
(§3.4)
- The page shows a Natural before/after pair on the same take, as information.
- **Recommended: yes.** One note table for every preset, so switching preset never changes
  how many notes the editor draws.
- The alternative, splitting only under Hard Tune, is offered but not recommended (§7).

**Q3 (default no). "Clips you corrected BEFORE this change keep their old notes. Do you want a
one-click 'split this clip's notes again' button?"** (§4.1, S7)
- **Recommended: no, for now.**
  - Running the preset again already re-splits any clip you have not hand-edited.
  - For a hand-edited clip, a re-split would have to merge your edits into new note
    boundaries. That is a design of its own and should be built only if you ask for it.

## §10 What this design could not settle

Stated, not papered over. Each item names the one that settles it.

1. **The real lead-in and held-tail lengths, and the slide speeds, on the take.**
   - `T` and `S` stand on the brief's numbers (~150–200 ms tails), a margin of 1–4 frames, and
     on synthetic slides.
   - Settled by S1 step 2. If they fail, S2 does not start on these constants.
2. **Whether `detectTransients` fires near legato cuts at all** (S1 step 3). This decides
   whether S3 exists.
3. **Whether pitch frames are in source-file seconds** [INFERRED]. Settled by S3's
   planted-onset test.
4. **The real detector's other artefacts.** My synthetic checks used full-bin quantisation
   (±12.90 c per value), which matches the product's stated floor (`PitchCorrection.swift:1769-1772`).
   So the staircase itself is modelled at its worst. Not modelled: the low-pitch under-read
   and any other behaviour of a real voice through SwiftF0. Settled by §5.3's real-detector
   fixture.
5. **How §5.2 compares edit sets.** ✅ **SETTLED by the orchestrator, 2026-09-24 [READ]:** ids ARE
   minted per call (`NoteSegment.init(id: UUID = UUID(), …)`, `PitchCorrection.swift:577-578`;
   `editSet` passes none), and `PitchEditSetDigest.hex` DOES hash each id
   (`StretchCurvePlan.swift:56-57`). So §5.2 compares field by field, EXCLUDING `id`, and never by
   digest. That same pair is why re-applying a preset always renders cold: ROADMAP `p2-cachekey`.
6. **Who consumes `PitchEditSet.currentAnalysisVersion`** (§4.6), and so whether "do not bump"
   is safe as well as unnecessary. Settled by an S2 grep before merge.
7. **Whether the curve accepts segments shorter than its 30 ms ramp**, which the (b) prototype
   needs. Settled by the L harness; (a-N) replaces (b) if not.
8. **Whether the pitch editor has a MERGE-notes gesture** (F-over's manual repair). Not
   checked here. If none exists, it is a gap F1 already names.
9. **Whether a `.transition` part should be MARKED in the model**, so the editor can draw it
   differently (F-novice). That needs a persisted additive field. Deferred until the user has
   seen the (a-T) result, not decided blind.
10. **The Hard Tune slide shape itself.** It is the user's (§9 Q1). The design is complete for
    every option. Only the constant waits.
11. **`docs/ARCHITECTURE.md` "Key future decisions"** is OWED. This task allowed edits to this
    file only. The verbatim entry is in §6 S4.

**Where this doc's numbers come from:**
- Every [MEASURED synthetic] figure comes from python arithmetic I ran for this design in the
  session scratchpad: 5-median, a 21-frame running median, full 25.8 c quantisation, and 8–16
  phases per case.
- They are design evidence, not product tests. S2 re-derives each one in Swift, against the
  product's own detector where §5.3 says so.

## §11 S1 measurements (2026-09-24)

Measured by audio-dsp-engineer. Every figure is [MEASURED] unless tagged otherwise. No product
code was changed. `DUR` = `~/Music/DAW Pro Dogfood/2026-09-24 p2-seg physics/`: outside the repo,
because it holds the user's voice. `DUR/README.txt` explains every file. The S1 scripts are
`DUR/s1/s1-red.py`, `s1-split.py`, `s1-onsets.py` and `s1-staging.mjs`. Their outputs are
`DUR/s1/out/*.log` (readable) and `*.json` (every number).

### §11.1 The take and the physics are durable

- **Take.** `DUR/take/dry-vocals.m4a` is the user's original (md5 `fe73bcdc…`).
  `DUR/take/dry-norm.wav` is the measured copy (md5 `25f59c88…`, the busy-line assertion). It is
  the m4a decoded at lag 0 samples, with a slowly varying normaliser gain of +19.3…+22.1 dB
  (per-second fit).
- **Also copied.** The four busy-line scripts and the two data files, with their paths made
  folder-relative. The four renders (`DUR/renders/`). The product contour cache file and the
  staging responses (`DUR/product/`). A pinned `DUR/requirements.txt` (35 packages).
- **Proof.** `physics-ht-livelook.py`, `-all.py` and `-check.py` were re-run from `DUR`, with a
  FRESH uv venv built from `requirements.txt` and working directory `/`. All three outputs are
  byte-identical to the original logs. The S1 outputs in `DUR/s1/out` come from the same kind of
  run and are byte-identical to the development runs.

### §11.2 Step 1: RED reproduces on both renders (`DUR/s1/out/s1-red.log`)

The instrument is the exact YIN of `physics-ht-livelook.py`:
- frame 1024 at 16 kHz, hop 256;
- a frame counts when a CMNDF trough dips below 0.1 AND its aperiodicity is < 0.4;
- a window reads the median of its counted frames.

| Hard Tune render | 23.05–23.20 s (baseline G#2+9 c) | 16.80–17.00 s (baseline A#2−11 c) |
|---|---|---|
| handoff `pitch-04-hard-tune.mp3` | G#2+9.2 c (8 of 9 frames), dev +0.2 c | A#2−10.9 c (8 of 13), dev +0.1 c |
| live-look `livelook-hardtune.wav` | G#2+9.2 c (8 of 9), dev +0.2 c | A#2−10.9 c (8 of 13), dev +0.1 c |

- Both reproduce within ±5 c. `[16.80, 16.99)` gives the same numbers: the extra frame at
  16.992 s is not counted.
- **Alignment controls pass on both render pairs.**
  - The uncorrected render against the take: waveform lag 0 samples.
  - Per frame, the median |diff| is 0.00 c over 718 frames, and 100 % are within 10 c.
    The best lag is 0 hops; ±1 hop gives 11.1 c.
  - At both windows, the uncorrected render reads the take's own reading within 0.1 c:
    A#2+40.9 c and C#3+13.5 c.
  - The Hard Tune render against its uncorrected twin: RMS-envelope lag 0 ms.
- **Planted defects are caught.** Plants went into both Hard Tune renders at both windows, by
  two methods: a level-matched synthesised harmonic tone, and the real render through librosa's
  phase vocoder. Both used 10 ms crossfades.
  - +800 c read as +795.5…+805.2 c.
  - −1200 c read as −1195.1…−1200.0 c.
  - +1200 c read as +1184.2…+1200.7 c.
  - All 24 plants were caught (±30 c). The 8 plants of 0 c moved the reading by 0.0–0.1 c.
- **The gate can pass.** The uncorrected render, shifted onto the rule's target over the window
  ±50 ms, reads A#2+7.1 c and C#3+4.9 c: rule PASS. Both Hard Tune renders FAIL the rule at
  both windows, whichever instrument supplies the "sung" pitch.

### §11.3 The scale `pitch-04-hard-tune.mp3` used: CHROMATIC

- **[READ]**
  - `PitchCorrectionPresets.swift:77`: `options(scale: PitchCorrectionScale = .chromatic)`.
    The line is identical in HEAD.
  - The harness `Tests/DAWEngineTests/ContourRenderListeningTests.swift:43` maps `.hardTune`
    to `04-hard-tune`, and `:168-169` calls `preset.options()` with no scale.
  - `clip.autoCorrectPitch` defaults to chromatic when neither `tonicPitchClass` nor `mode`
    is given (`Commands.swift:5031`, `:5110`).
- **⚠️ Reading the source is not proof here.** Both source files were modified at 02:24:05,
  AFTER the render at 02:09:53, and the harness file is untracked. So the scale was measured:
  - The handoff mp3 IS the harness's `04-hard-tune.wav`: lag 0, gain −0.50 dB, residual
    −53.7 dB. The negative controls (03-tight, 00-uncorrected) leave −0.1 and 0.0 dB.
  - 15 runs were MOVED onto their chromatic nearest note (uncorrected more than 30 c off, Hard
    Tune within 20 c), on 9 pitch classes.
  - There are 12 distinct 7-note product scales (major on T equals minor on T+9;
    `ChordVoicing.swift:62-63`). Each of them leaves at least 5 of those 15 runs outside the
    scale. No major or minor scale could have produced this render.
  - The live-look wav gives the same result. Its `clip.autoCorrectPitch` response echoes
    `{tonicPitchClass: 0, mode: chromatic}` (`DUR/product/livelook-c-hardtune-autocorrect.json`).
- So every §3.3 render uses the chromatic scale.

### §11.4 ⚠️ Finding: "sung C#3+13 c" at 16.8–17.0 s is an artefact of the tracker's mask

(`DUR/s1/out/s1-red.log`, section D1)

- **What happens.** The tail wobbles by about ±85 c. The gate tracker counts only 7 of its 13
  frames. Frames at 16.800–16.896 s pass the trough-below-0.1 test. Frames at 16.912–16.992 s
  fail it, and those are the UPPER half of the wobble.
- **The same window, read four ways (in cents relative to D3):**
  - YIN, counted frames only: −86.5 c, which is C#3+13.5 c (7 frames);
  - YIN, all frames with octave errors dropped: −4.9 c (12 frames);
  - product frames: median −0.8 c, mean −1.6 c (12 frames);
  - the §1.3 held part's emitted median: D3−1 c (§11.5).
- **Consequence.** A CORRECT p2-seg Hard Tune plays D3 here, because the held part is locked to
  its own median. §5.1's worked example ("must read C#3 (D3 is 87 c away)") would call that
  RED. The rule's "sung plateau median" does not say which instrument measures it.
- **Needs an architect ruling before S2-close.** For example: the §1.3 held part's median from
  product frames, or YIN over ALL of the part's frames. Nothing was retuned here.
- **23.05–23.20 s is consistent.** YIN counted frames and YIN all frames both read A#2+40.9 c.
  The product frames read A#2+42.5 c.

### §11.5 Step 2: the five notes under §1.3 (`DUR/s1/out/s1-split.log`)

**Inputs.**
- The product frames are `DUR/busyline-frames.csv`. They equal S1's own staging
  `clip.detectPitch` output on all 2081 frames: 0 voicing mismatches, max 0.0011 c.
- The python `voicedRuns` replica matches the product's own 42 Hard Tune segments: starts and
  ends within 3.6e-15 s, centres within 0.0008 c.
- Constants as §1.4: B 52 c, T 8, S 8, P 21, τ 50/100 c, de-glitch 5. Edges shrink symmetrically,
  as §1.3 states.

**Result: none of the five notes is a single "slide into a hold".** In the table:
- **plat** = the plateau's length (the quantity T gates);
- **part** = the length of the emitted part;
- **raw** = frames from the first frame within B/2 of the plateau median to the part's end.

| Note (run span) | Shape | Parts (frames) | Leftovers | Held parts: plat / part / raw frames, part median (plateau median) |
|---|---|---|---|---|
| 0:07.6 (7.552–8.560) | run of 3 short notes | H14 H24 H25 | 2 links of 7 fr (≤ S), each cut at one frame (7.776 s, 8.160 s) | 10/14/14 G#2+30 c (G#2+22); 18/24/21 C3+35 c (C3+38); 20/25/20 A#2+8 c (A#2+4) |
| 0:09.2 (9.152–9.824) | run of notes: A2, then an 80 ms stop near B2, then C#3 | H10 T18 H14 | lead-in 2 (absorbed); link 18 becomes a transition | **8**/10/7 A2+16 c (A2+28); 11/14/12 C#3+41 c (D3−48) |
| 0:16.4 (16.384–16.992) | note, slide, note: G2, then a 17-frame slide, then a wobbling D3 | H10 T17 H11 | link 17 becomes a transition | 10/10/10 G2+23 c (G2+23); **8**/11/10 D3−1 c (D3−23) |
| 0:22.6 (22.608–23.216) | note, slide, note: D#2, then an 8-frame slide, then A#2 | H19 H19 | link **8 = S**: cut at one frame (22.912 s), NO transition | 13/19/19 D#2+21 c (D#2+16); 15/19/16 A#2+43 c (A#2+44) |
| 0:31.4 (31.440–32.064) | run of notes: D3, a fall with a B2 bump, then A2 drifting ~100 c | H12 T27 | lead-in 4 (absorbed); tail-off 27 becomes a transition | **8**/12/7 D3−35 c (D3−42) |

**Checks.** The required margin is ≥ 2 frames: every plateau ≥ 10 frames, every RED slide ≥ 10 frames.
- **T = 8 FAILS.** Three held plateaus are exactly 8 frames, a margin of 0:
  - 0:09.2's A2;
  - 0:31.4's D3;
  - 0:16.4's D3 tail, which is a RED tail. There the ±85 c wobble breaks the 52 c band, even
    though the raw contour stays on the note for 10 frames.
  - All other plateaus are 10–20 frames. Two of them, 0:07.6's G#2 and 0:16.4's G2, are
    exactly 10.
- **S = 8 FAILS on 0:22.6.** Its slide is an 8-frame LINK, equal to S. So §1.3 cuts it at one
  frame and emits no `.transition` part.
  - 0:16.4's slide (a 17-frame link) passes, with a margin of 9.
  - 0:07.6's slides are 7 frames, below S, so they are cut at one frame.
- Per §10 item 1, S2 should not start on these constants without a ruling. Nothing was retuned.
- **Consequence for §3 [INFERRED from the table]:**
  - On the headline 0:22.6 note, the four listening shapes would differ only in a `.transition`
    that §1.3 does not emit. So (d), (a-T), (a-N) and (b) write the SAME table there: each held
    part locks to its own median, and the A#2+43 c tail goes to A#2, which passes the rule. Only
    (c) differs: it pins the whole run's median, G#2, which stays RED. The split alone turns
    23.05–23.2 s green, and item L cannot tell the fixes apart on this note. L's excerpt should
    centre on notes that DO emit a transition: 0:16.4 (17-frame link), 0:09.2 (18-frame link) or
    0:31.4 (27-frame tail-off).
  - Every RED transition on this take is a LINK between two held notes, never a lead-in. So
    shape (d) "straight to the note" needs a stated target when the transition is a link.
- **Medians.** For every held part, the emitted median is within 9.2 c of the raw-held median,
  except 0:09.2's A2: −21.3 c, under the 30 c flag.
- **Slide speeds (F-slow).**
  - The RED slides move at 2604 c/s (0:16.4: 708 c net across its link) and 4239 c/s (0:22.6:
    543 c across its 8-frame link).
  - Four transitions are slower than 800 c/s (runs at 3.536, 7.104, 14.464 and 27.696 s:
    511–768 c/s). Each moves only 85–111 c net.
  - No slow glide on this take spans more than one semitone.

### §11.6 All 42 runs under §1.3 (`DUR/s1/out/s1-split.log`)

- **Counts.** 42 runs give 59 parts. 12 runs split, into 22 `.held` and 7 `.transition` parts;
  30 runs are unchanged. 26 runs are at least 2T = 16 frames long.
- **No steady run split.** "Steady" means the de-glitched contour spans ≤ 100 c over the whole
  run; 12 runs qualify.
- The count bound holds on all 42: #held equals #plateaus, and adjacent plateaus are at least τ
  apart. No result depends on merge order.
- **Every split run**, with the steps between adjacent parts (cents):

  | Run start | Parts (frames) | Steps |
  |---|---|---|
  | 3.536 s | H17 H12 T9 | −117, −3 |
  | 4.240 s | H9 H18 | +227 |
  | 5.584 s | H17 H21 | +168 |
  | 7.104 s | T11 H11 | +204 |
  | 0:07.6 | H14 H24 H25 | +405, −227 |
  | 0:09.2 | H10 T18 H14 | +196, +230 |
  | 10.928 s | H10 H20 | +182 |
  | 14.464 s | H24 T11 H17 | +77, +121 |
  | 0:16.4 | H10 T17 H11 | +227, +449 |
  | 0:22.6 | H19 H19 | +722 |
  | 27.696 s | H8 T9 | +52 |
  | 0:31.4 | H12 T27 | −411 |

- **Early over-split warning.** Two splits come from a release just over S (9 frames):
  - at 27.696 s, a 17-frame run becomes an 8-frame held part plus a 9-frame tail-off whose
    median is only 52 c higher;
  - at 3.536 s, the tail-off sits 3 c from the held part before it.
  - Under (a-T) neither invents a note, because a transition is identity. Under (c) or (a-N),
    each tail-off would become its own locked note.
- **Implementation controls.** 14 of the design's 17 stated synthetic outcomes agree
  (`DUR/s1/out/s1-split.log`, top). Three differ:
  - ±100 c at 5.5 Hz splits in 1 of 16 phases. The symmetric edge shrink leaves `y ≈ x` in the
    last frames, which makes a 10-frame tail-off. An edge-clamped window gives one note in all 16.
  - A 70 c step with no wobble splits in 8 of 16 phases. Quantisation reads the step as 51.6 c,
    which is ≤ B. With ±37 c wobble it splits in all 16.
  - The 741 c slide's lead-in is 25–26 frames, not the design's 20–25.
- **Edge-rule sensitivity (NOT the spec).** With an edge-CLAMPED P-median, 10 of the 42 runs
  change their parts. S2 should pin the edge rule with a fixture.

### §11.7 Step 3: onset recall is no better than chance (`DUR/s1/out/s1-onsets.log`)

- **Markers.** `clip.detectTransients {sensitivity: 0.5}` on S1's staging instance gave 226
  markers over 0.020–33.271 s. A repeat call returned identical markers.
- **Time base.** Markers are SOURCE-FILE seconds [READ `Commands.swift:4720-4724`,
  `EngineProtocol.swift:443-445`, `:668-671`, `ProjectStore+Quantize.swift:9`, `:77-80`].
  - This clip is untrimmed (window start 0, stretch 1), so source-file seconds, clip-local
    seconds and frame time all coincide here.
  - F-time (§8) is therefore NOT exercised. S3's planted-onset test is still owed.
- **Density.** 39 % of all frame starts in the file have a marker within ±32 ms.
- **Recall at ±2 frames (±32 ms) of the f0 cuts.** Chance is each run's own marker coverage,
  and p is from a 20000-draw permutation:

  | Cuts | Recall | Chance | p |
  |---|---|---|---|
  | five named notes | 3/8 (38 %) | 33 % | 0.52 |
  | all 42 runs | 6/17 (35 %) | 39 % | 0.71 |
  | short-link cuts only | 3/7 | 41 % | — |

  - 0:22.6's cut has a marker at −26.7 ms. Both 0:16.4 cuts miss, at −60 and +69 ms.
- **§1.5's narrower condition** (an onset inside the short link, ±1 frame): 6 of 7. Chance
  predicts 3.6 of 7, exact p = 0.050.
- **S3 go/no-go needs a ruling, because §6's "go if most cuts have one" does not say which cuts.**
  - All cuts at ±2 frames (S1's brief): 6 of 17 (35 %), no better than chance. That reads NO-GO.
  - Only the short-link cuts §1.5 would move, at §1.5's own window: 6 of 7, against 3.6
    expected by chance, p = 0.050 on n = 7. That is borderline.

## §12 Orchestrator rulings after S1 (2026-09-24)

S1's record (§11) was checked by the orchestrator before these rulings. The §11.4 mask artefact
was re-measured independently: over 16.80–16.99 s, all 12 YIN frames read D3−5 c; only the 7
frames the aperiodicity mask kept read C#3+13 c; the product's frames read D3−1 c. These are
ENGINEERING rulings, not the user's. The user's question stays §9 Q1.

1. **§5.1's instrument.** The "sung plateau median" in the pass rule is §1.3's OWN emitted median,
   from the PRODUCT's frames. The independent tracker measures the RENDER only. The worked
   example is corrected in place (16.8–17.0 s must read D3).
2. **Shape (d) between two held notes.** Every RED slide on this take sits BETWEEN two plateaus
   (§11). For (d), "straight to the note", a `.transition` takes the target of the plateau it
   leads INTO: the destination. A lead-in takes its first plateau's target. A tail-off takes
   its last plateau's target.
3. **S3 (onset placement) is NOT scheduled.**
   - Across all 17 cuts, onsets land within ±2 frames at 6 of 17 (35 %), against 39 % by chance
     (p = 0.71).
   - Only the 7 short-link cuts reach 6 of 7 (p = 0.050), which is borderline on a single take.
   - f0 alone decides. S2 still ships the `onsetSeconds` parameter, with every caller passing
     `[]` (§1.5), so S3 can return later with more takes. Its time-base question (F-time) stays
     open.
4. **T and S are NOT ruled blind. They get a sensitivity re-pick (R1) before S2 starts.** S1 found
   0 margin on both (three 8-frame held plateaus, including a RED tail; an 8-frame RED link = S).
   - The two failure directions are unequal. A plateau missed at T degrades, under the
     recommended (a-T), to that stretch playing as sung: not locked, and never a wrong note.
   - A T set too low lets a slow glide fake plateaus and over-split: the F1 failure, and the
     worse one.
   - So R1 measures before anything moves:
     - T ∈ {6, 7, 8} and S ∈ {6, 7, 8}, on synthetic slides at 300–1200 c/s and on the real
       take's 42 runs;
     - ±1-frame jitter at every boundary;
     - over-split counts and missed-plateau counts, both.
   - R1 picks with the bound it rests on, and appends a §13. Route: audio-dsp-engineer,
     python only, reusing S1's §1.3 implementation (`~/Music/DAW Pro Dogfood/2026-09-24 p2-seg
     physics/s1/`).
5. **L (the listening set) centres its excerpt on 0:16.4.** That is a 17-frame transition between
   G2 and a wobbling D3, and it holds for any T/S in R1's range. It does NOT centre on 0:22.6,
   whose 8-frame link emits no transition, so every shape writes the same table there. 0:09.2 and
   0:31.4 may join if their transitions survive R1. L starts after the orchestrator's full-suite
   run, because it builds and renders.
6. **The edge rule is §1.3's as written** (the median window shrinks SYMMETRICALLY at run edges).
   S1 showed that an edge-clamped window changes 10 of 42 runs, so S2 pins the symmetric rule
   with a fixture.

## §13 R1: T and S re-picked (2026-09-24)

Measured by audio-dsp-engineer, python only. No product code was changed. `DUR/r1/r1-sweep.py`
imports S1's `s1-split.py` and runs its `split_run` unmodified. Per cell it sets only the module
globals `T` and `S`.
- **Outputs.** `DUR/r1/out/r1-sweep.log` (readable) and `r1-sweep.json` (every number).
- **Anchors.** The 8/8 cell reproduces S1's `s1-split.json` on all 42 runs and all 17 control
  strings. Planted cells T7/S8 and T8/S7 each make that comparison fail.
- **Run.** One process under `nice -n 19`, 35 s. Two runs of the final script give the same log
  and JSON, timestamps aside.
- **Tags.** Every figure below is [MEASURED synthetic] or [MEASURED real take] unless tagged
  otherwise.

### §13.1 The pick: T = 8, S = 8. Same values, now with measured bounds and recorded costs

- **T = 8.**
  - *Lower bound (no fake notes on a slide)* [MEASURED synthetic]. The fixture is a wobble-free
    slide, 10 lengths × 16 bin-grid offsets = 160 fixtures per speed.
    - At 700 c/s, y stays inside the B band for 7 frames in 160 of 160 fixtures; at 800 c/s it
      stays 6–7 frames.
    - T = 8 is the smallest T that rejects both: 0 of 160 split at every speed ≥ 700 c/s.
    - At T = 7, 147/160 split at 700 c/s and 51/160 at 800 c/s. That includes §5.3's own
      fixture, an 800 c/s slide over 1 s, which comes out as `T H7 T` at 6 of 16 offsets:
      F1's "a slide split into three notes", exactly.
    - Margin: 1 frame.
  - *Upper bound (catch the held notes)* [MEASURED real take]. The shortest held plateaus that must
    lock are 8 frames: 0:16.4's D3 tail (8 at every T), 0:31.4's D3 and 0:09.2's A2. Margin: 0.
  - *Why 8 and not 7.* §12.4 ranks over-split first.
    - T = 7 over-splits the design's own fixture. It also over-splits wobbling slides up to
      2000 c/s; T = 8 does so only up to 1500 c/s.
    - What T = 8 adds over T = 7 is missed plateaus. A missed plateau falls back to today's
      behaviour (§13.4), never to something new.
- **S = 8.**
  - *Lower bound (a scoop stays one note)* [MEASURED synthetic]. Fixtures: scoops of 48–120 ms and
    100–500 c, with and without the ±37 c wobble, 16 phases, 640 in all.
    - Every scoop of ≤ 120 ms leaves a lead-in of at most 7 frames, at every T.
    - At T = 7 and T = 8, S = 8 keeps all 640 scoops whole with 1 frame to spare. S = 7 keeps
      them with 0 to spare.
    - S = 6 splits 59–62 of 640, breaking §2.2.
  - *Upper bound* [MEASURED real take]. The take's links are 7 and 7 frames (0:07.6) and 8 frames
    (0:22.6). No S in {6, 7, 8} has 2 frames of margin to all three.
    - At S = 8, 0:22.6's link is absorbed: no transition. Both of its held notes still lock in
      every cell (plateaus 13 and 15).
    - §11.5 and §12.5 already priced this in.
- **The ≥ 2-frame margin rule cannot be met on this take** [MEASURED real take].
  - The RED D3 tail at 0:16.4 has an 8-frame plateau at every T, so its margin is 8 − T.
  - Two frames of margin needs T ≤ 6, and T = 6 breaks §2.5: S1's 800 and 833 c/s slides split
    into 5 and 5–6 parts.
  - This is a fact about the take, not a choice.
- **Flip condition.** Suppose the orchestrator moves the slow-slide floor from 800 to 900 c/s,
  with §5.3's fixture. Then T = 7 is better on every real-take and jitter measure here:
  - 0 single-frame ops unlock a named held note, against 26 at T = 8 (§13.6);
  - run 28's tail is caught (§13.4).
- **No slope guard.** No cell keeps a wobbling slide whole below 1500 c/s (§13.3), but no guard
  separates those fakes from the take's real notes (§13.7).

### §13.2 The (T, S) table

Column notes:
- **§2 guards broken.** Against S1's 17 controls with S1's phases. §5.3's 800 c/s × 1 s fixture
  is also tested at 16 offsets.
- **Slide floor.** The slowest probed speed from which every probe upward keeps all 160 fixtures
  ONE. Probes: 300–2000 c/s.
- **Must-split.** Widths 200–800 c.
- **Take.** Today's count is 42 parts, one per run.
- **Unlocks.** Single-frame ops that unlock a named held note.

| T/S | §2 guards broken | slide floor, c/s (no wobble / ±37 c) | scoops / releases not ONE (of 640 each) | must-split missed (of 25,536) / holds locked WRONG (of 51,072) | take: parts / held / transitions | named held notes locked | steady runs split | edge jitter: flips / unlocks | all-frames jitter: unlocks (of 1,904) |
|---|---|---|---|---|---|---|---|---|---|
| 6/6 | 120 ms scoop; 800 and 833 c/s slides; §5.3 fixture 16/16 | 1000 / 2000 | 60 / 36 | 6,029 / 2,992 | 68 / 31 / 10 | 10/10 | 0 | 32 / 0 | 0 |
| 6/7 | 800 and 833 c/s slides; §5.3 fixture 16/16 | 1000 / 2000 | 1 / 23 | 5,676 / 3,888 | 65 / 31 / 7 | 10/10 | 0 | 33 / 0 | 0 |
| 6/8 | 800 and 833 c/s slides; §5.3 fixture 16/16 | 1000 / 2000 | 1 / 20 | 5,549 / 4,704 | 62 / 30 / 4 | 10/10 | 0 | 22 / 0 | 0 |
| 7/6 | 120 ms scoop; §5.3 fixture 6/16 | 900 / 2000 | 59 / 40 | 8,341 / 4,931 | 67 / 29 / 12 | 10/10 | 0 | 20 / 0 | 0 |
| 7/7 | §5.3 fixture 6/16 | 900 / 2000 | 0 / 26 | 8,055 / 5,945 | 65 / 29 / 10 | 10/10 | 0 | 27 / 0 | 0 |
| 7/8 | §5.3 fixture 6/16 | 900 / 2000 | 0 / 23 | 7,914 / 6,865 | 62 / 28 / 7 | 10/10 | 0 | 23 / 0 | 0 |
| 8/6 | 120 ms scoop | 700 / 1500 | 62 / 41 | 10,376 / 7,236 | 68 / 26 / 16 | 10/10 | 0 | 33 / 6 | 26 |
| 8/7 | none | 700 / 1500 | 0 / 26 | 10,027 / 8,265 | 64 / 24 / 12 | 10/10 | 0 | 34 / 6 | 26 |
| **8/8** | none | 700 / 1500 | 0 / 23 | 10,022 / 9,221 | 59 / 22 / 7 | 10/10 | 0 | 23 / 6 | 26 |

Columns 2–5 are [MEASURED synthetic]; columns 6–10 are [MEASURED real take]. S1's ±100 c wobble
control still comes out as 1 or 2 parts in every cell except T6/S8. That is S1's edge-rule finding
(§11.6), not a threshold effect.

### §13.3 Synthetic over-split, scoops and releases [MEASURED synthetic]

**Runs split at S = 8, out of 160, by slide speed and wobble:**

| Wobble | T | 300 | 450 | 600 | 700 | 800 | 900 | 1000 | 1200 | 1500 | 2000 c/s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| none | 6 | 96 | 128 | 144 | 152 | 159 | 158 | 0 | 0 | 0 | 0 |
| none | 7 | 96 | 128 | 144 | 147 | 51 | 0 | 0 | 0 | 0 | 0 |
| none | 8 | 96 | 128 | 139 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| ±37 c | 6 | 91 | 128 | 143 | 154 | 154 | 154 | 153 | 154 | 154 | 0 |
| ±37 c | 7 | 87 | 125 | 141 | 152 | 152 | 151 | 150 | 153 | 115 | 0 |
| ±37 c | 8 | 86 | 122 | 137 | 148 | 148 | 149 | 150 | 108 | 0 | 0 |

- **S1's controls sampled only 4 offsets on a wobble-free fixture.**
  - S1's `phases` pair each vibrato phase with a bin offset of (k % 4) · 25.79/4 c.
  - A wobble-free fixture has no vibrato phase to vary, so S1 tested only 4 distinct inputs.
  - That is why S1's control shows the 800 c/s slide whole at T = 7, while 16 distinct offsets
    split it at offsets 5–7 and 13–15.
- **A wobbling slide over-splits in every cell below ~1279 c/s.**
  - *Mechanism.* 1279 c/s is the wobble's peak slope, 2π · 5.5 Hz · 37 c. Below it, the contour
    stalls once per cycle.
  - After the 5-frame de-glitch, x is monotone, so y = x. Each stall becomes a flat step of 5–6
    frames. With its in-band neighbours it fills 7–10 frames of the band at 800–1200 c/s.
  - The steps sit about v / 5.5 Hz apart (182 c at 1000 c/s). That is above `τ_short`, so step 4
    never merges them.
  - T = 8 is clean only from 1500 c/s up; T = 6 and T = 7 only from 2000 c/s.
  - So §2.5 holds for wobble-free slides only.
  - [MEASURED real take] The take has two transitions of about 1000 c/s that span more than a
    semitone: 0:09.2's link (1079 c/s, +311 c) and 0:31.4's fall (1003 c/s, −433 c; §11.5).
    - At T = 7 and T = 8, each stays one transition.
    - At T = 6, each gains a held part inside it: a B2 in 0:09.2 and an A#2 in 0:31.4.
- **Scoops.** The 120 ms scoops at 300–500 c leave 5–7-frame lead-ins, with and without wobble
  (max 7).
  - S = 6 splits 59–62 of 640.
  - S = 7 and S = 8 split none at T = 7 and T = 8. At T = 6 one 200 c scoop splits.
- **Releases (tail-offs) are wider than §2.2 says.**
  - Wobbling releases of 96–120 ms leave tail-offs of up to 11 frames.
  - At T = 7 and T = 8, 23 of 640 split at S = 8 and 26 at S = 7. All of them wobble.
    Wobble-free releases leave at most 6 frames.
  - This matches the take's two 9-frame tail-offs at 3.536 s and 27.696 s (§11.6). It is likely
    the symmetric edge shrink S1 flagged. The edge rule stays as ruled (§12.6).

### §13.4 Must-split, and what a missed plateau really does

**Two-sided fixtures** [MEASURED synthetic]: hold h1, then a step or a slide, then hold h2.
- Slides: 4239 and 2604 c/s (the take's RED speeds) and 1200 c/s. Widths 100–800 c.
- Holds: h ∈ 6–12 frames, 19 pairs.
- Wobble: none, ±37 c or ±85 c at 5.5 Hz. 16 phases.
- **A split is FOUND** when two different `.held` parts each cover a hold, with medians within 50 c
  of its true pitch.

**What the fixtures show:**
- *No wobble.* T = 8 misses 836/1344 fixtures whose shorter hold is 6 frames, and 336/1344 at 7
  frames. It misses none from 8 frames up. T = 7 misses only the 6-frame case (336); T = 6 misses
  none.
- *±37 c.* Misses by shorter hold, 6 → 12 frames:
  - T = 8: 980 / 708 / 240 / 132 / 27 / 1 / 0 (of 1344 each; the 12-frame column is of 448);
  - T = 7: 723 / 253 / 150 / 36, then 0;
  - T = 6: 209 / 60 / 18, then 0.
- *±85 c*, the depth of 0:16.4's tail. Miss rates run from the 6-frame shorter hold to the
  12-frame one:
  - T = 8: 90 → 69 %;
  - T = 7: 90 → 57 %;
  - T = 6: 86 → 32 %.
  - The 52 c band cannot hold that wobble near a run edge. That is B's bound, not T's.
  - The 0:16.4 tail locks only because its plateau reaches exactly 8.
- *100 c steps.* 85–91 % are missed in every cell. This is F-semi, as recorded.

**§12.4's premise holds only in part.** "A missed plateau plays as sung, never a wrong note" is
true only when two conditions both hold: the run keeps another plateau, AND the leftover frames
exceed S. When the missed plateau was the run's only one, step 6 returns today's whole-run pin.
- [MEASURED synthetic] At T8/S8, out of 51,072 holds:
  - 9,221 fell into a part that Hard Tune snaps to a DIFFERENT note: the unsplit run, or a held
    part more than 50 c off;
  - 4,796 fell into a transition, and so play as sung.
  - Wrong outnumbers as-sung even without wobble: 1,192 against 336.
- [MEASURED real take] **Run 28 (23.712 s) is a sixth RED-shaped note.** It ends in a 7-frame held
  tail, sung at A#2−35 c, after a 120 c jump.
  - T = 8 cannot accept 7 frames, so the run stays one part with centre G#2+46 c, target G#2.
  - The tail's only allowed target is A#2; A2 is 65 c away.
  - So Hard Tune plays the tail about 165 c flat, on G#2. [INFERRED from §3.2 (c) and the
    analogous measured 0:22.6 RED, §11.2; not rendered.]
  - T = 7 catches it as `H19 H7`.
- [MEASURED real take] At T = 8, dropping any one of 0:31.4's 8 plateau frames turns `H12 T27` into
  one run with median A#2+42 c. Hard Tune then pins it to A#2, about 365 c below the sung D3−35 c.
  Today's RED returns.
- **The version that does hold:** a missed plateau is never WORSE than today, because it falls
  back to today's pin or to as-sung. A fake plateau is new behaviour that today never had. That
  still ranks over-split first, which is why T stays 8.

### §13.5 The real take, under the pick (T8/S8) [MEASURED real take]

- **All 10 held notes of the five named notes lock, in all 9 cells.**
- **No steady run splits**, in any cell or under any jitter op. The §5.1 count bound holds in
  every cell.
- **Unchanged runs.** 31 of the 42 runs are identical in all 9 cells. The full 42 × 9 matrix is in
  the log.
- **Changed runs.** The 11 that change are runs 6, 7, 10 (0:07.6), 12 (0:09.2), 17, 18, 24, 25,
  27 (0:22.6), 28 and 40 (0:31.4).

**The five named notes at T8/S8:**

| Note | Parts | Held notes: median → Hard Tune target (plateau frames) | One dropped or duplicated frame |
|---|---|---|---|
| 0:07.6 | H14 H24 H25 | G#2+30 c → G#2 (10); C3+35 c → C3 (18); A#2+8 c → A#2 (20) | no flip at S = 8. At S = 7, one duplicated link frame adds a transition |
| 0:09.2 | H10 T18 H14 | A2+16 c → A2 (8); C#3+41 c → C#3 (11) | dropping any of frames 28–38 unlocks C#3. As sung it FAILS §5.1 (41 c off) |
| 0:16.4 | H10 T17 H11 | G2+23 c → G2 (10); D3−1 c → D3 (8) | 7 single drops unlock D3. As sung, D3−1 c passes §5.1 |
| 0:22.6 | H19 H19 | D#2+21 c → D#2 (13); A#2+43 c → A#2 (15) | duplicating any link frame (13–20) gives H T H, e.g. H13 T9 H17. Both notes still lock |
| 0:31.4 | H12 T27 | D3−35 c → D3 (8) | dropping any of frames 4–11 makes the whole run one part pinned to A#2 (RED). Duplicating any of 27–33 adds a held A2 at the end |

- **L's transitions survive** (§12.5). 0:16.4's 17-frame link is `H T H` in all 9 cells. At T = 8,
  0:09.2's 18-frame link and 0:31.4's 27-frame tail-off both stay transitions.
- **What T = 7 would change (the flip option).**
  - New held parts in:
    - run 17: G#2 for 8 frames, then A2;
    - run 24: G#2 for 9 frames, then a 12-frame transition only 68 c away. That is S1's over-split
      signature, harmless under (a-T);
    - run 28: the A#2 tail, correct;
    - 0:31.4: its final A2, 12 frames, median A2−26 c.
  - 0:09.2's A2 part grows to 17 frames, and its median moves +21 c. The target is unchanged.

### §13.6 Jitter on the real take [MEASURED real take]

- **Edge jitter** (the brief's). Four ops at every plateau edge of each cell's own result: drop
  the frame on either side, or duplicate the frame on either side. The run is re-timed and
  re-split at the same cell.
  - Flips: T8/S8 23 in 12 runs (236 ops); T7/S8 23 in 11 runs (238 ops); T6/S8 22 in 8 runs
    (254 ops).
  - Named held notes unlocked: 6 ops at T = 8 (every S), 0 at T ≤ 7.
- **All-frames jitter.** Every frame dropped, then every frame duplicated: 1,904 ops per cell.
  Unlike edge jitter, this can also CREATE a plateau.
  - Named held notes unlocked: 26 ops at T = 8, 0 at T ≤ 7.
  - Ops that add a held part: T8/S8 49, T7/S8 31, T6/S8 29.
  - At T7/S8 the named runs flip, but no held note ever unlocks:
    - a duplicated frame in 0:09.2's link adds a held B2, the 80 ms stop;
    - a duplicated frame in 0:31.4's fall adds a held B2;
    - a dropped frame in 0:31.4's A2 loses that part;
    - a dropped frame at 28, 29 or 38 moves 0:09.2's C#3 part to D3−46 c, target D3. §5.1
      allows both C#3 and D3 for C#3+41 c.
- **S flips on the named notes.**
  - At S = 8, a duplicated frame in 0:22.6's link emits a transition.
  - At S = 7, a dropped frame removes that transition, and a duplicated frame in either 7-frame
    link of 0:07.6 adds one.

### §13.7 Slope guard: measured, not added [MEASURED synthetic, MEASURED real take]

The guard tested rejects a RAW candidate plateau (§1.3 step 3) when its last-third median minus
its first-third median exceeds X.
- **It cannot work on a wobble-free slide, by construction.** There x = y, and a plateau is
  defined by max − min(y) ≤ B. So a fake's trend is at most 52 c, and 0 % are rejected at X = 52.
- **On wobbling slides it catches too few fakes.** At X = 39 c it rejects 9–13 % of the fakes.
  At the same X it rejects 17–50 % of the five named runs' real plateaus (y-trend and x-trend).
  - No X rejects most fakes while keeping the take's held notes.
- **"x is monotone across the plateau" does not separate them either.** It holds for:
  - 64–67 % of wobbling fakes;
  - 77–78 % of wobble-free real holds;
  - 0:31.4's D3 plateau [4,12) itself. So that guard would send 0:31.4 back to RED.

### §13.8 Carried forward to S2 and the design (recorded; nothing retuned)

1. **Sweep 16 distinct offsets.** §5.3's threshold pins and slide fixtures must use k · 25.79/16 c.
   S1's `phases` give a wobble-free fixture only 4 offsets, which hid T = 7's split.
2. **F-slow is wider than §2.5 and §8 state.** With the design's ±37 c wobble, slides below about
   1279 c/s split in every cell. T = 8 protects wobble-free slides from 700 c/s up, and wobbling
   ones from 1500 c/s up.
3. **§2.2's release claim fails at the top of its range.** Wobbling releases of 96–120 ms split
   at S = 8 in 23 of 640 fixtures.
4. **±85 c holds are mostly uncatchable at any T.** That is B's bound.
5. **Run 28 is a sixth RED-shaped note** that T = 8 leaves as today (§13.4). §5.1 lists five.
6. **§12.4's asymmetry holds as "never worse than today", not as "never a wrong note".** The
   decision stands on the first wording (§13.4).

## §14 Orchestrator rulings after R1 (2026-09-24)

R1 (§13) was checked by the orchestrator before these rulings: its anchor (T8/S8 reproduces S1 on
0 of 42 runs; the planted T7/S8 and T8/S7 cells differ on 12 and 5 runs), its 8/8 totals (59 parts,
12 split, 22 held, 7 transitions, = §11.6) and its all-frames jitter column (26 named unlocks at T = 8;
31/29 added held parts at T7/T6 with S = 8) were re-read from `DUR/r1/out/r1-sweep.log`.

1. **T = 8, S = 8 STAND.** The flip to T = 7 was tested on the one evidence that is not synthetic:
   the two real-take runs where T = 7 adds a held part.
   - **Run 24 (19.280 s):** the product contour is a wobbling RISE, −97 → +128 c over 21 frames
     (~225 c). T = 7's "held G#2" is one wobble cycle inside it. T = 7 INVENTS that plateau, and
     under Hard Tune it would lock half the note and leave the rest as sung.
   - **Run 17 (13.920 s):** a 7-frame (112 ms) near-flat onset (±19 c), then a jump. Ambiguous
     between a grace note and a scoop, and it sits inside §2.2's "a scoop ≤ 120 ms stays ONE note".
   - So the real take has at least one fake plateau at T = 7. §12.4's ranking (over-split first)
     now rests on a REAL instance, not only on §5.3's synthetic fixture.
   - R1's flip condition stays recorded; S2 pins `T` as a named constant whose doc comment carries
     it, so a flip is a one-line change plus a gate re-run.
2. **§12.4 is re-worded to what R1 measured:** a missed plateau is "never WORSE than today", not
   "never a wrong note". When the missed plateau was the run's only one, today's pin returns.
3. **Run 28 joins the measured list (§5.1)** as a known T = 8 cost, not a pass condition. Its
   mechanism is TAIL ABSORPTION: a leftover ≤ S that sits at a DIFFERENT pitch (a jump, not a slide)
   is absorbed into the held part before it. Filed as **p2-seg-F-tail**: absorb a leftover only
   when it is a slide into or out of the part. Needs its own design pass (daw-architect) and a
   fixture; not in S2.
4. **R1's errata are placed here, where S2 will read them:**
   - §5.3's threshold pins and slide fixtures sweep **16 DISTINCT bin offsets** (k · 25.79/16 c).
     S1's `phases` give a wobble-free fixture only 4, which hid T = 7's split (§13.3).
   - §2.5 ("an 800 c/s slide stays one note") holds for WOBBLE-FREE slides only. With ±37 c,
     slides below ~1279 c/s split in every cell; T = 8 is clean from 1500 c/s (§13.3).
   - §2.2's release claim fails at the top of its range: wobbling releases of 96–120 ms split at
     S = 8 in 23 of 640 (§13.3). Recorded, not retuned.
   - ±85 c holds are mostly uncatchable at any T: that is B's bound (§13.4).
5. **L launches on these constants.** 0:16.4's parts (H10 T17 H11) are identical in all nine cells,
   so the listening set does not depend on this ruling.

## §15 L: the listening set, measured (2026-09-24)

Item L rendered the user's take through the product renderer (`StretchRenderCache.renderIfNeeded`),
with edit sets built from S1's parts at T = 8, S = 8 (`DUR/L/parts.json`: 42 runs → 59 parts; 12 runs
split into 22 held parts and 7 transitions). The full record is `DUR/L/README.txt`. The orchestrator
re-checked the page-facing numbers below with its own instruments before publishing.

### §15.1 What goes on the page, and the Q1 erratum
- **Q1's fourth option is (a-N) "In-between note", not (b) "Robot staircase".** (b) as specified
  (per-frame nearest-note stairs, 30 ms retune) produced **0** flat regions by the step check fixed
  before measuring: ≥ 3 consecutive counted YIN frames within ±25 c of one note, inside
  [16.544, 16.816) s; pass = ≥ 3 distinct notes. A finer YIN (32 ms frames, 4 ms hop) shows an ideal
  staircase tone holding 5 notes for ≥ 24 ms; (b) holds none (longest stay 16 ms) and sits 11.8 c
  from (a-T) inside the slide. 12 of its 36 stairs are single-frame, which the curve cannot shape
  (`PitchCorrection.swift:1207`). The §9 branch "if they pick Robot staircase → S6" is void until a
  staircase with a minimum stair length (or its own ramp) is designed. S6 stays filed.
- **(c) is bit-exact with the handoff's `04-hard-tune.wav`**: 0 of 1,598,400 samples differ.
  Orchestrator: whole-file md5 `8519e82d…` for both, and both negative controls differ. So the page's
  "today" clip is file 04, cut to 6 s.
- Excerpt: 13.783–19.689 s of the take (5.906 s). Slide at clip 2.761–3.033 s; held D3 at
  3.033–3.209 s. A second split slide (run 18, clip 1.065–1.241 s) also changes between options.
- Audibility inside the slide (folded median |YIN diff|, PH4), pairwise: c–d 405, c–aT 232,
  c–aN 102, d–aT 472, d–aN 506, aT–aN 81 c. The RMS of the difference signal cannot rank anything
  here (§15.3).
- The orchestrator's own YIN (numpy, separate code, 85–400 Hz, frames wholly inside each window;
  synthetic control reads G2+23.0 / D3−0.9). Values are held G2 / slide / held D3:
  - today: A#2+3 / A#2+1 / A#2−15
  - straight: G2+10 / D3+4 / D3−13
  - slide kept: G2+4 / as sung / D3−13
  - in-between: G2+8 / A2−0 / D3−12
  The held D3 sits ~12 c low in all three split shapes alike, so the shape is not the cause.
  [INFERRED, not measured: the 30 ms hop against the note's ±50 c wobble.]
- Loudness: all 7 MP3s are −21.5 LUFS integrated, with true peak −1.2 to −2.8 dBTP. The orchestrator
  re-measured them with `ebur128=peak=true` and got identical figures.

### §15.2 §5.1 as pre-registered FAILED on every render; neither cause is the slide shape
- **0:09.2's first held part (A2).** The independent YIN reads A1 (−1200 c) on EVERY render,
  uncorrected included. The half-harmonic octave measure calls 5 of the part's 8 f/2 frames
  genuinely ambiguous. §5.1's instrument cannot rank shapes there.
- **0:22.6's first held part (D#2, ~78 Hz).** The PRODUCT detector reads it ~21–23 c sharp of YIN
  and pYIN: over 19 frames, YIN − product median = −22.6 c and pYIN − product median = −20.9 c.
  Hard Tune moves by the product's reading, so every shape lands ~20 c flat of D#2. This is a
  detector-accuracy question at low pitch, not a segmentation one. **Filed as p2-seg-F-detect.**
- Re-read POST-HOC (octave-folded, counted frames; declared after the first run and labelled so),
  (d), (a-T), (b) and (a-N) PASS and (c) FAILS. **The pre-registered verdict stands as FAIL.** The
  folded reading explains that verdict; it is not a pass.
- **S2-close must settle §5.1's octave rule BEFORE using it as a gate.** The candidate is PH1's folded
  counted-frames rule. Its blind spot: it cannot see an octave error, so T2's plants have to cover
  those.
- Run 28 (a recorded cost, §14 item 3): Hard Tune pulls the absorbed tail 152–161 c below the
  uncorrected render, and 140–148 c below the sung tail median. The [INFERRED] ~165 c is confirmed
  in size.

### §15.3 The invariance control as specified is impossible in this renderer
- The vendored signalsmith-stretch computes each output bin's phase from its own previous output
  (`Sources/CSignalsmithStretch/vendor/signalsmith-stretch/signalsmith-stretch.h:713-716`). It
  resets only after ≥ 2 blocks of input energy below 1e-15 (`:240-247`), and the take never gets
  there. Measured: a +50 c plant on one unsplit run changed 7 hops, and 1,465,920 later samples
  differ, to the end of the file.
- Any "outside the split" gate must compare three things, never whole-file audio:
  1. the per-hop pitch grid: 0 hops differ outside [start − h, end + h], where
     h = min(retuneMs/2000, dur/2);
  2. the audio before the first changed hop, which must be bit-exact (and the change must start
     there);
  3. octave-folded pitch on the unsplit runs.
  L's three controls each caught the plant.
- For §5.2's render byte gate: a fixture that splits changes every sample after its first changed
  hop. That is expected, not a bug. Such a fixture is NAMED as an exception (§5.2 already requires
  that), never re-baselined silently.

### §15.4 The Natural pair (Q2, shown as information)
- Natural today and Natural with the split differ by 24–38 c on run 18 and 33–50 c on 0:16.4
  (folded, per part). Elsewhere they are identical in pitch. A novice may not hear that, so the page
  says so and shows `natural-pair-zoom.png`.
- Today's Natural moves run 20 as ONE piece. Its first held note (sung G2+23 by the product) goes up
  onto G#2 (YIN reads G#2−2 to −10). With the split, it stays near where it was sung.
- Pre-registered N1 PASSED only vacuously: its tolerance came out at 1021 c, an octave misread.
  Folded, 0 of 22 held parts end further from their note, and 7 of 22 end closer by more than the
  25.19 c tolerance. N2 FAILED on one row only (run 5's tail-off interior has 0 counted frames). The
  other 6 transitions are left as sung (0.22–2.38 c).
- **Q3 is deferred to S2-close's page.** It concerns clips corrected before the change, and those
  only exist once S2 ships. Its default (no) stands meanwhile. The page already has 11 open asks.

### §15.5 Pins that S2 gets for free, and the harness it must repoint
- `Tests/DAWEngineTests/NoteSplitListeningTests.swift` (env-gated) calls `PitchAutoCorrect.editSet`
  at 4 sites to get "today". After S2 those calls return the split behaviour. Its pass-1 controls
  (today reproduces the handoff files) must be repointed to the pre-p2-seg reference path, not
  deleted.
- L's WAVs are bit-exact targets for S2's product edit sets on the take:
  - (c) → `01-today.wav`
  - (d) → `02-straight.wav`
  - (a-T) → `03-slide-kept.wav`
  - (a-N) → `05-in-between.wav`
  - Natural with the split → `07-natural-after.wav`

  Same parts and same arithmetic give the same bytes. Any difference names a run and a hop.
