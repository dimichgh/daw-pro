# Pitch editor: the per-note wobble handle (C5a)

> **Amended 2026-09-25 by `docs/design/2026-09-25-natural-tuning.md` (natural tuning, the user's MUST).** Where this document and that one disagree, that one wins. Amended sections here: §5.2 (coupling/decoupling, Drift tool, batch setter, double-click "Steady"), §5.3 (separator v2, "Remove wobble and drift" label).

Design and implementation plan, 2026-09-24, daw-architect.

**Status: DESIGN. Nothing in this document is shipped.** It extends
`docs/design/2026-09-22-pitch-editor-ui.md` (section 7.3 orders the increments; C5a is
"one handle, rate + depth, flatten to add") and sits beside
`docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` (C2 timing, C5b freehand,
C-0 the played line). It does not redesign C5b or C-0.

**Contents**
0. How to read this document
1. Decisions at a glance
2. Findings
3. The user's verbs, and which feature answers each
4. The door and the handle
5. The gesture: what width and speed do, branch by branch
6. Continuity: the first tick on a sung note
7. The phase anchor (a model change)
8. Measuring the sung wobble
9. The readout
10. The store setter
11. Split, canonical, and C2 timing
12. Wire and MCP
13. Coexisting with C5b on one note
14. Failure modes
15. Tests and planted defects
16. Implementation plan
17. What needs the user's word

---

## 0. How to read this document

- **[READ]**: I opened the code or document at the cited place on 2026-09-24. A number
  marked [READ] that is a measurement was measured by whoever wrote the cited test or
  doc comment. I re-ran nothing: three other agents were building in this tree, so any
  build or test run of mine would have been noise, and the brief forbade it.
- **[INFERRED]**: derived by arithmetic or reasoning from [READ] facts, not observed
  running. Every [INFERRED] claim that a later decision rests on has a test or a
  measurement in section 15 that can prove it wrong.
- **[MEASURED]**: not used. Nothing in this document was measured by me. Where a
  measurement is needed, section 15 specifies it for the implementing agent.
- **Cite by symbol, not by line.** Lines moved while this was written:
  `PitchEditorModel.swift` shifted by about 77 lines between two of my reads, and
  `PitchCorrection.swift` by about 15. The symbol named beside each line number is the
  durable anchor. Re-find by symbol before editing.
- **Census counts are not quoted.** Where a list of sites matters, the method (the grep)
  is given, positive-controlled, and the implementing agent re-runs it.
- **"Wobble" is the user-facing word for vibrato.** The tree already uses it in the C-0
  captions ("their wobble setting can't change them"). Code and wire keep the model's
  names (`vibratoRateHz`, `vibratoDepthCents`, ...). Only drawn text says "wobble".
- **Heard rate vs stored rate.** `vibratoRateHz` is stored per SOURCE second. What a
  person hears is `vibratoRateHz / stretchRatio` (finding V5). The UI and the readout
  speak heard rate. The model and the wire speak stored rate, and every response also
  echoes the heard rate.

---

## 1. Decisions at a glance

| # | Decision | Section |
|---|---|---|
| D1 | The user's four verbs map to: **smooth** = C5a pull-down (whole note straightens), with regional smoothing a named gap (C-F7); **add more cycles** = C5a sideways; **pull tops or bottoms** = C5a up/down for every peak together, the C5b brush for one peak, and a lopsided wobble (tops only) a named gap; **change the shape the way I want** = C5b only. | 3 |
| D2 | The door is a fourth palette slot, **Wobble** (SF Symbol `waveform.path`, the reference frames' own glyph). In that tool the whole note is the grab area and a knob is drawn at the note's centre. The Move tool's body (pitch, C1) and edges (timing, C2) are untouched. ⌘ held at mouse-down means the C5b brush in every tool. | 4 |
| D3 | **One swappable mapping.** `PitchWobbleGesture.Layout` is the only code that reads pointer translation for this gesture. It turns translation into `(speedTravel, widthTravel)`, and its three cases are the three answers on the user's handoff page. The drawn help is derived from it, so swapping the layout cannot leave the help lying. | 4 |
| D4 | **Two branches, chosen at mouse-down and never crossed during a gesture.** On **your wobble** (the singer's own), up/down is the keep lever. On **a new wobble** (the app's generator), up/down is its width. On both, up means wider, down means narrower, and flat is the bottom. This departs from "flatten and add are one continuous range": see the CONFLICT block in 5.6. | 5 |
| D5 | **Flat is `vibratoScale = 0` AND `driftScale = 0`.** `vibratoScale = 0` alone leaves an inverted ~21 % of a 5.5 Hz wobble (finding V3). The keep lever writes `driftScale = min(driftAtStart, keep)`, so drift follows only while flattening below where it started, and widening never exaggerates the slides into and out of a note. | 5.3 |
| D6 | **Continuity.** On your wobble, speed does nothing until the pointer has moved 16 pt, mostly sideways. A shorter or mostly-vertical drag is byte-identical in speed. Past that point comes a one-time **handoff**: your wobble is replaced by a new one seeded from the estimator's reading of the line on screen (heard rate, width and phase). An unmeasurable wobble refuses the handoff and says what to do instead. | 6 |
| D7 | **Model change: `NoteSegment.vibratoPhaseAnchorSeconds`.** Default 0, which is today's source-second-0 phase, bit for bit. Without it, a speed drag on a note 30 s into a recording moves the drawn phase about 1.5 cycles per point (V6), so the line boils and cannot be read. The anchor is stored, not derived from `startSeconds`, so canonical truncation and split keep the banner's two guarantees. It has its own digest block. | 7 |
| D8 | **Measurement.** `PitchWobbleEstimate` is a new pure DAWCore function: a least-squares sine fit with quadratic detrend over the note's middle 80 %, scanning 3 to 9 Hz, on the render's whole-file contour. The result is `.wobble(rate, depth, anchor, fit)`, `.noWobble` (below the 12.90 c floor) or `.unmeasurable(reason)`. It is validated on quantised synthetic contours and on the real detector before anything prints it. | 8 |
| D9 | **Readout.** For your wobble, the readout is the estimator run over the **draft played line**, so it is never computed from the keep factor. For a new wobble, it shows the asked values. Heard rate is shown to 0.1 per second and width rounded to the nearest 5 cents. The 8 Hz ceiling is shown as "the fastest that plays cleanly". No number is shown for an unmeasurable wobble. | 9 |
| D10 | **Store setter.** `setClipNoteVibrato(clipId:segmentId:edit:seedIfAbsent:)`. `nil` means unchanged, and there are no hidden defaults: the UI passes onset and anchor explicitly. It clamps to the model ranges, and clamps heard rate to 8 Hz against `stretchRatio`. The undo key is `PitchCorrectionUndoKey.vibrato`, with one commit per gesture. A reset uses `structuralKey`. | 10 |
| D11 | **Split** re-derives the right half's onset (V8). The anchor is copied, so the phase continues through the cut. Under C2, the anchor maps through W, as the envelope's start already does. | 11 |
| D12 | **Wire.** `clip.setNoteVibrato` takes model-named keys, so it round-trips with `clip.getPitchEdits`. `clip.getPitchEdits` gains `vibratoPhaseAnchorSeconds` and `heardVibratoRateHz`. `clip.getPlayedPitch` (C-0c) gains per-note wobble readings, because `clip.getPitchEdits` promises no engine call. The MCP tool is `clip_set_note_vibrato`. | 12 |
| D13 | **C5b on the same note:** the drawn delta stays a separate layer. The handoff seed excludes it. Neither readout mentions the other feature. | 13 |
| D14 | **Onset** is not on the handle. The UI passes a provisional pick, `min(0.25 s, 0.3 × note length)`. Listening item C5a-L sets the real default from the user's choice among four options. | 9.5, 16 |
| D15 | **Gating.** Your-wobble edits and the handoff need the played line's basis to be `.render`, like the C5b brush. A note whose wobble is already a new one, with both scales at 1, needs no contour and stays editable during `.estimate`. | 5.5 |

**Render thread:** untouched. Everything here runs on the main actor (the editor, the
store) or in the existing detached offline render. **Xcode:** nothing here needs full
Xcode, entitlements, signing or AUv3.

---

## 2. Findings

Line numbers are approximate (section 0). Cite by the symbol.

**V1 [READ]: nothing writes the vibrato fields on one note.**
- The only per-note setters are `setClipNotePitchOffset` and `splitClipNoteSegment`
  (`Sources/DAWCore/ProjectStore+PitchNoteEdits.swift` ~65, ~128).
- Method: `grep -rn --include='*.swift' -E '\.(vibratoScale|vibratoRateHz|vibratoDepthCents|vibratoOnsetSeconds|driftScale)[[:space:]]*=[^=]' Sources/`.
  The only `NoteSegment` hits are the model's own `init`. The other hits are
  `BreathContour.Options` and the effort options, which are different structs: the
  wire's `vibratoRateHz` keys at `Commands.swift` ~7825 and ~8189 belong to them.
- The constructor-argument form, `(vibratoScale|vibratoRateHz|vibratoDepthCents|vibratoOnsetSeconds|driftScale):`,
  finds nothing outside the model. The same pattern with the filter removed matched the
  model's own lines, including `PitchAutoCorrect`'s `driftScale: shapeScale, vibratoScale:
  shapeScale` (`PitchCorrection.swift` ~1590). So the search could see a writer, and the
  two scales are only ever written **equal**, which matters for V3.

**V2 [READ]: the generator, as shipped.**
- The term is `depth × fade(t) × sin(2π · rate · t)`, with the phase at source second 0
  and the fade anchored at the segment's own start (`PitchCorrectionCurve.generatedVibrato`,
  `PitchCorrection.swift` ~1270-1284).
- It **adds**. Replacing is `vibratoScale: 0` in the same edit (curve banner ~913-918).
- `hasGeneratedVibrato` (depth ≠ 0) is the one predicate.
- Rate and onset are outside `isIdentity`, because at depth 0 they are inert by
  arithmetic (~493-514). They are inside `isEdited` (~534).
- The digest hashes the two scales inline. It hashes rate, depth and onset in a suffix
  block, emitted only when some segment has a generated wobble (`StretchCurvePlan.swift`
  ~154-187, marker ~131).

**V3 [READ, with INFERRED arithmetic that agrees]: `vibratoScale: 0` on its own is not flat.**
- `PitchRenderContour.shapingVersion`'s doc (`PitchCorrection.swift` ~1394-1402): *"on a
  5.5 Hz vibrato the 250 ms window passes 121 % of the wobble into 'vibrato', so
  `vibratoScale: 0` on its own over-corrects"*. Hard Tune sets drift and vibrato both to
  0, which cancels the split. It cuts within-note wander by 48–58 % at A3 and B3, and
  *"most of what is left in every case is the renderer"*.
- The arithmetic, from `PitchCorrectionMath.movingAverage` (~1693-1709). It is a centred,
  edge-clamped boxcar. At the detector's 16 ms frame its half width is
  `round(0.25 / 0.016 / 2) = 8`, so it has 17 taps. Its gain at 5.5 Hz is
  `sin(π·5.5·17·0.016) / (17·sin(π·5.5·0.016)) ≈ −0.215`.
  - So the "vibrato" part is 1.215 × the true wobble, and the "drift" part carries
    −0.215 × of it.
  - With `vibratoScale 0` and `driftScale 1`, the played line keeps an **inverted** 21.5 %
    of the wobble at 5.5 Hz. The same formula gives −18 % at 6 Hz, −17 % at 4.5 Hz,
    −8 % at 4 Hz, −5 % at 7 Hz and +8 % at 8 Hz. The 272 ms window's nulls fall near
    3.7 Hz and 7.4 Hz, not at 4 Hz and 8 Hz, and the edge clamp changes the response
    near a note's ends.
  - That matches the doc's 121 %.
- ⚠️ **Since W7-C3 (2026-09-27, natural tuning §3b): this v1 arithmetic now applies ONLY
  to equal-scale notes (Hard Tune and any preset with `driftScale == vibratoScale`).**
  `vibratoScale: 0` alone (unequal scale, the case this section is ABOUT) now takes a
  DIFFERENT kernel: a triangular window, L = `separatedDriftWindowSeconds` = 0.16 s,
  `separatedDriftEdge = .truncate` (`PitchCorrection.swift`, `separatedShapingVersion`).
  Its response at 5.5 Hz is close to 0 (H ≈ +0.001) rather than v1's −0.215, so the
  predicted "vibrato" part is ≈ 1.0 × (not 1.215 ×) and `vibratoScale: 0` alone no longer
  over-corrects by the mechanism above. MEASURED through the product render (W7-STX,
  2026-09-27, `Tests/DAWEngineTests/ContourToRenderTests.swift` `oneNoteVibratoScaleZero`
  + `ContourShapingSweepTests` under `CONTOUR_SWEEP=1`, same run, no formant base on either
  render): within-note wander cut 44 % at B3 and 48–51 % at A3, against 48–58 % under v1 on
  2026-09-24 (which no longer reproduces even under v1 on today's tree: the RENDER changed
  independently of the separator, per W7-C3's `shapingVersion` doc). See
  `docs/ROADMAP.md` "W7-C3: drift/wobble separator v2 DONE".
- Two design texts still say flatten is `vibratoScale: 0` alone: the `NoteSegment`
  generator banner ("the flat half drives `vibratoScale` 1 → 0", ~347-352) and the 09-24
  doc (~1256). D5 supersedes both. Correcting the banner comment is part of item C5a-2.

**V4 [READ]: C-0 as it exists in the working tree, not as sketched in the 09-24 doc.**
- `PitchPlayedLine.make(contour: PitchRenderContour?, fallback:editSet:clipPitchShiftSemitones:sourceWindow:)`
  (`Sources/DAWCore/PitchPlayedLine.swift` ~222).
  - `contour` is **optional**. `nil` means "not answered yet" and reads as
    `.estimate(pendingReason)`.
  - Points sit at voiced frame **centres**:
    `playedMidi = sungMidi + curve.semitones(atSourceSecond: centre)` (~306-313).
  - There is one polyline per voiced run.
- The editor model holds `playedLine`, `draftPlayedLine`, `draftSpan` (the dragged note
  widened by half the retune ramp on each side) and `rebuildDraftLine()`.
  `rebuildDraftLine()` copies `noteTable` and sets **only `pitchOffsetCents`** on the
  dragged segment (`Sources/DAWAppKit/PitchEditorModel.swift` ~1462-1482).
- So the draft path is C1-shaped today. C5a, and later C2-5, must generalise it. Neither
  may add a second one.
- The store door is `ProjectStore.renderPitchContour(clipId:) async -> PitchRenderInputs`
  (`ProjectStore+PitchRenderContour.swift` ~56).

**V5 [READ, then INFERRED]: the heard rate is the stored rate divided by the clip's stretch ratio.**
- `StretchCurvePlan.sourceSecond(forOutputFrame:) = frame / (ratio × sampleRate)`
  (~52-55). The curve, generator included, is evaluated in source seconds, and an output
  second is `ratio` source seconds. So `sin(2π · f · t_source)` is heard at `f / ratio`.
- Every generator measurement in the tree runs at ratio 1:
  `NoteVibratoGeneratorTests.measureDepth` (~634-637) and `rateIsDelivered` (~918-921).
- [INFERRED] The 8 Hz ceiling is an **output-time** limit. The curve is read once per
  30 ms hop of **output** frames (09-24 doc F1 and F28; `vibratoRateHzRange`'s doc).
  - On a clip at ratio 0.5, a stored 5 Hz is heard at 10 Hz. That is inside the measured
    staircase regime: at 10 Hz the chain adds non-sinusoidal content equal to 61.7 % of a
    ±93 c request.
  - On a clip at ratio 1.25, the stored ceiling of 8 Hz is heard at 6.4 Hz.
  - Neither case has been measured. Item C5a-1 measures both.

**V6 [INFERRED from READ]: with the phase at source second 0, a speed drag makes the drawn line boil.**
- The phase at time `t` is `θ = 2π · f · t`, so `dθ/df = 2π · t`.
- At a speed gain of 0.05 Hz per point (5.4), one point of pointer travel moves the phase
  of a note centred at 5 s by π/2, a quarter cycle. For a note at 30 s it is 3π, one and a
  half cycles.
- The peaks do not stretch around the knob; they jump. The draft line would show that
  faithfully, which makes it useless as feedback.
- This is not an audio defect, since the commit happens at release. It makes the gesture
  unusable after the first few seconds of any recording. D7 fixes it.

**V7 [READ]: nothing in `Sources/` measures a note's sung wobble.**
- Method: `grep -rn --include='*.swift' -i 'vibratoRate\|vibratoDepth\|estimateVibrato\|measureVibrato\|VibratoEstimate\|VibratoAnalysis\|vibratoAnalysis\|func.*vibrato' Sources/`,
  excluding `PitchCorrection.swift`. It finds only the digest, the breath and effort
  generators and the `getPitchEdits` echo.
- Positive control: the same pattern on `PitchCorrection.swift` alone matched 36 lines.
- The tests have two tools, and neither does this job:
  - `M23QToneTracker.fitSinusoid` (`Tests/DAWEngineTests/M23QCurveHarness.swift` ~230-264)
    fits at a **known** rate, by a one-bin DFT.
  - `rateIsDelivered` scans candidate rates, but its own comment says the scan's
    amplitudes *"are NOT depths and must never be quoted as one"*, because a partial
    cycle biases them (~948-953).
- A readout needs an **unknown** rate and a depth from one short note. The estimator is
  new (D8, section 8).

**V8 [READ, then INFERRED]: split copies the onset, and the right half's fade restarts at the cut.**
- `splitClipNoteSegment` builds the right half by a Codable round trip (`reidentified`,
  ~210-224).
- The fade is `smoothstep((t − noteStartSeconds) / onset)`, where `noteStartSeconds` is
  the segment's own start (curve `make` ~1147, `generatedVibrato` ~1281).
- So splitting a new wobble with a 0.25 s onset makes the right half fade in again from
  zero at the cut. That is a quarter-second hole in the wobble, mid-note.
- `generatorIsContinuousAcrossASplit` cannot see this: its notes use the default onset 0
  (`NoteVibratoGeneratorTests.swift` ~329-333).
- `splitCarriesEveryEditFieldTheParentHad` (`Tests/DAWCoreTests/PitchCorrectionWriterTests.swift`
  ~490; `changeable` ~551) pins verbatim copying of every field except
  `{id, startSeconds, endSeconds}`. C2-4 and C5b-3 already widen that set for their own
  fields (09-24 doc F9). C5a widens it for `vibratoOnsetSeconds`.

**V9 [READ]: `clip.getPitchEdits` already echoes every vibrato field, and promises no engine call.**
- The echo: `pitchEditsResponse`, `Commands.swift` ~13599-13613.
- The promise: *"STRICTLY READ-ONLY ... no engine call"* (~5045-5050).
- A measured sung wobble needs the render contour, which is an engine call, so it cannot
  live there. `clip.getPlayedPitch` (C-0c) already makes that call.

**V10 [READ]: the 12.90-cent readout floor lives in DAWAppKit.**
- `PitchEditorReadout.centsResolutionFloor` (`PitchEditorModel.swift` ~93).
- DAWCore cannot import DAWAppKit, so the estimator's floor needs a DAWCore home, and the
  readout type then reads that. One home, not two.

**V11 [READ]: one undo key for both mechanisms, justified by a drag that crosses zero.**
- `PitchCorrectionUndoKey.vibrato(clipID:segmentID:)` (~843-855): *"one drag ... writes
  `vibratoScale` on the way down and `vibratoRateHz`/`vibratoDepthCents` on the way up"*.
- `structuralKey` is nil and never coalesces (~857-860).
- The journal coalesces same-key edits inside a sliding 800 ms window (09-22 doc §8.1).

**V12 [READ]: what the generator is measured to deliver, all at ratio 1.**
Sources: the `NoteSegment` docs ~358-486, and `NoteVibratoGeneratorTests` §C.
- **Excess.** About +3 c at 1 Hz, +7 c at 5.5 Hz and +10 c at 8 Hz. It does not scale
  with depth.
- **Honest bound.** *"±7 cents at typical rates ... round to the nearest 5. No
  pre-compensation."*
- **Rate ceiling.** 8 Hz, set by the shape. The chain adds non-sinusoidal content equal
  to 23.8 % of a ±93 c request at 7.8 Hz, and 61.7 % at 10 Hz, measured over the
  tracker's own floor.
- **Other ranges.** Depth 0–200 c and onset 0–5 s are bounded picks, not measurements.
  So is `shapeScaleRange` (0…4, ~434-436), and the UI's [0, 2] below is a second pick.
- **Rate is smooth.** Delivered depth is smooth in rate. The hypothesised spike at the
  hop-commensurate 5.0 Hz was measured and falsified (`depthGainIsNotSmoothInRate`,
  ~803-820), so the UI's 0.1 Hz lattice needs no special cases.
- **Honesty rule 5** (09-22 doc ~631-635): *"`vibratoScale` IS A KEEP/FLATTEN LEVER AND
  MUST NEVER BE A DEPTH SLIDER."*

**V13 [READ]: the palette and the modifiers.**
- The palette *"grows a slot when a tool lands, and never before"*, and its help is
  **drawn**, never only a tooltip (`PitchEditorTool`, `PitchEditorModel.swift` ~842-887).
- ⌥ is read from `NSEvent.modifierFlags` on every tick (`PitchEditorView.dragChanged`
  ~940-944). C5b reads ⌘ at mouse-down (09-24 doc §5.5).
- `dragEnded` is *"the ONE place a gesture can produce a store write"* (~947-962).
- Staging reads every write back (`commitPitchNoteEdit`, `PitchCorrectionStaging.swift`
  ~106-149).

**V14 [READ]: a preset silently erases every hand-made wobble.**
A preset replaces the whole set and does not warn (09-24 doc F22, `autoCorrectClipPitch`).
C-F3 is the fix. C5a's UI item inherits C2-5's dependency on it.

**V15 [READ]: per-note edits cannot reach take-lane clips.**
09-24 doc F23; `locateClipIndexForNoteEdits` (~236-243). C5a inherits this. It is
follow-up C-F2.

---

## 3. The user's verbs, and which feature answers each

The request, verbatim: *"in each segment it should have more detailed curve that I should
be able to smoth or add more cycles or pull tops or bottoms up or down, change the curve
with mouse, not just some dots, but with say CMD + mouse I can change the shape the way I
want."* The frames show one edit of one note whose readout moves from `Vibrato 5.5 Hz
±93 c` to `Vibrato 7.8 Hz ±32 c` in one drag (09-22 doc §7.2b, [READ]).

| The user's words | Answered by | What happens | What it must NOT be taken to mean |
|---|---|---|---|
| "smooth" | **C5a** | Drag a note down in the Wobble tool. The whole note's line straightens toward the note's centre, wobble and slow drift together, until it is flat (D5). | Smoothing **part** of a note is not C5a. That is the smoothing brush, follow-up **C-F7** in the 09-24 doc, which is not scheduled. |
| "add more cycles" | **C5a** | Drag sideways: more wobbles per second. On the singer's own wobble this goes through the handoff (section 6). | Not "add one cycle at one spot". The C5b brush can draw a bump anywhere, but that is drawing, not cycles. |
| "pull tops or bottoms up or down" | **C5a** for every top and bottom together; **C5b** for one top or one bottom | C5a: drag up or down to widen or narrow the whole wobble; the top of the wobble follows the pointer (5.4). C5b: hold ⌘, press on one peak and drag it (09-24 doc §5.5, which quotes these same words). | A **lopsided** wobble, tops pulled up with bottoms left alone, has no parametric control: the generator is a symmetric sine. Named gap **C5a-F1**; C5b can draw it regionally. |
| "change the curve with mouse, not just some dots, but with say CMD + mouse I can change the shape the way I want" | **C5b only** | ⌘-drag draws the line (09-24 doc §5). | C5a is not freehand. Its readout never says "shape", "draw" or "line". |

**What keeps the two features from impersonating each other:**
- C5a's readout speaks only of wobble, speed ("per second") and width ("cents each way").
  C5b's readout (`Drawing · moves the line by up to 35 cents`, 09-24 doc §5.5) never says
  "per second".
- C5a's drawn help mentions ⌘ **only when the Shape tool exists**: the sentence is
  appended when `PitchEditorTool.allCases` contains the Shape slot. If C5a ships before
  C5b, it cannot advertise a feature that is not there.
- They are separate undo steps with separate keys (`.vibrato` for a wobble gesture,
  `structuralKey` for a stroke) and separate context-menu resets ("Back to how you sang
  it" for C5a, "Reset drawn shape" for C5b).

---

## 4. The door and the handle

### 4.1 Decision: a Wobble tool in the palette

The palette gains a slot, **Wobble**, with the SF Symbol `waveform.path`. In the reference
frames, the vibrato edit happened with a waveform tool engaged (09-22 doc §7.2b, frames
3–6, [READ]). The palette's rule is that it grows a slot when a tool lands (V13), and this
is that tool. The slot sits after Split. If C5b's Shape slot already exists, Wobble goes
before Shape, because a wobble is the more common edit.

**In the Wobble tool:**
- a press anywhere on a note grabs that note's wobble. Hit testing uses the existing
  `PitchEditorModel.blob(at:)`, with its 4 pt slop and nearest-by-vertical rule;
- the note's **knob** is drawn at the note's temporal centre, vertically at the blob's
  drawn centre (edited pitch plus the clip transpose, which is what C-0's blob uses). The
  knob is 10 pt across, in `signal` ink with the house glow, and is drawn on hover and
  during a drag. `signal` is the accent the editor already uses for an edited note (V13);
  never cyan (playback) or violet (AI content);
- the readout floats above the note, where C1's pitch readout sits, and is mirrored in
  the palette's readout slot in SF Mono;
- **⌥ held means fine control**: every gain is divided by 4. It is read per tick, as in
  the Move tool, where ⌥ also means "precise" (free of the snap).

**Alternative 1: a knob on every note in the Move tool** (for example at the top-centre
dot the reference frames show). This loses for three reasons.
- The Move tool's note already has three meanings: the body is pitch (C1), the edges are
  timing (C2), and ⌘ is the brush (C5b). A fourth zone on the same rectangle makes every
  one of them harder to hit.
- A knob-sized target vanishes at low zoom, where a whole-note target does not.
- What the top-centre dot does is a question already on the user's page (09-24 doc §7).
  If the answer is "it is the wobble control", a Move-tool knob becomes a second door to
  the same gesture (follow-up **C5a-F4**), because the gesture code below does not care
  which door opened it.

**Alternative 2: a modifier in the Move tool.** This loses because no modifier is free:
- ⌘ is C5b's brush;
- ⌥ means free movement or fine control;
- ⌃-click is macOS's secondary click, which opens the context menu;
- ⇧ conventionally constrains a drag.

### 4.2 How it avoids the other gestures

- **The Move tool's body (pitch) and edges (C2 timing)** are not active in the Wobble
  tool, so no zone arithmetic is needed and none can be wrong.
- **⌘ held at mouse-down is the C5b brush in every tool**, Wobble included, once C5b-4
  lands. Before that, ⌘ has no meaning in the Wobble tool and the gesture is a wobble
  edit.
- **One router decides what a press means.**
  `PitchEditorGestureRouter.route(tool:modifiersAtMouseDown:hit:) -> PitchEditorGestureKind`
  returns one of `pitchDrag`, `timingDrag`, `brush`, `wobble` or `split`. It lives in
  DAWAppKit. It is the one place a future zone or modifier is added: C2-5's edges and
  C5b-4's ⌘ also route through it, so whichever of C2-5, C5b-4 and C5a-4 lands first
  builds it. The view's `dragChanged` asks the router once, at the first tick of a
  gesture, and never re-decides mid-gesture.

### 4.3 The one swappable mapping (D3)

The axis question is already on the user's page. Its three answers are the three cases of
one enum. **No other code reads the pointer's translation for this gesture.**

```swift
// Sources/DAWAppKit/PitchWobbleGesture.swift (new)
public enum PitchWobbleHandleLayout: String, Sendable, Equatable, CaseIterable {
    case sidewaysIsSpeed   // RECOMMENDED DEFAULT: one knob; ← → speed, ↑ ↓ width
    case sidewaysIsWidth   // "the other way round": one knob; ← → width, ↑ ↓ speed
    case twoHandles        // a speed knob (← →) and a width knob (↑ ↓)
}
public enum PitchWobbleKnob: Sendable, Equatable { case both, speed, width }

/// Pointer travel, in points, already mapped: + is faster, + is wider.
public struct PitchWobbleTravel: Sendable, Equatable {
    public var speed: Double
    public var width: Double
}

public enum PitchWobbleGesture {
    /// ⭐ THE ONE PLACE the user's answer to the axis question lives.
    public static let layout: PitchWobbleHandleLayout = .sidewaysIsSpeed

    public static func travel(translation: CGSize, knob: PitchWobbleKnob,
                              layout: PitchWobbleHandleLayout = layout) -> PitchWobbleTravel
    /// Where each knob is drawn and grabbed, for a blob's rect.
    public static func knobs(in blobRect: CGRect,
                             layout: PitchWobbleHandleLayout = layout) -> [(PitchWobbleKnob, CGPoint)]
    /// The drawn help. Derived from the layout so a swap cannot leave it lying.
    public static func help(layout: PitchWobbleHandleLayout = layout,
                            drawToolAvailable: Bool) -> String
}
```

| Layout | Knob grabbed | `speed` | `width` |
|---|---|---|---|
| `sidewaysIsSpeed` | `both` | `+dx` | `−dy` |
| `sidewaysIsWidth` | `both` | `−dy` | `+dx` |
| `twoHandles` | `speed` | `+dx` | `0` |
| `twoHandles` | `width` | `0` | `−dy` |

(`dy` grows downward, as SwiftUI reports it, so `−dy` is "up is more".)

**Knob placement.**
- One-knob layouts: one knob at the blob's centre, and the whole blob is the grab area.
- `twoHandles`: knobs at 1/3 and 2/3 of the blob's width, each with a 12 pt hit radius. A
  press elsewhere on the blob grabs the nearer knob. A blob narrower than 40 pt shows the
  help "Zoom in to change this note's wobble" and ignores the press.

**Help text** (drawn in the palette's help slot):
- `sidewaysIsSpeed`: "Drag a note up to widen its wobble, down to smooth it flat. Drag
  sideways for a faster or slower wobble."
- `sidewaysIsWidth`: "Drag a note right to widen its wobble, left to smooth it flat. Drag
  up or down for a faster or slower wobble."
- `twoHandles`: "Drag the ↕ knob up to widen a note's wobble, down to smooth it flat. Drag
  the ↔ knob sideways for a faster or slower wobble."
- Every layout then gets "100 cents is one piano key." If `drawToolAvailable` is true, it
  also gets "Hold ⌘ to draw instead." It always ends with "Let go to hear it."

Everything downstream, including the branches, gains, dead zone, handoff, clamps and
readout, consumes `PitchWobbleTravel` and is layout-agnostic. Any of the three answers is
a one-line change to `layout`. Test T11 (section 15) pins that.

---

## 5. The gesture: what width and speed do, branch by branch

### 5.1 Two branches, chosen at mouse-down

A note has at most two wobbles:
- **your wobble**: the singer's own, kept, narrowed, straightened or widened by
  `vibratoScale` (and `driftScale`, 5.3);
- **a new wobble**: the app's sine, `vibratoRateHz` / `vibratoDepthCents` /
  `vibratoOnsetSeconds` / `vibratoPhaseAnchorSeconds`, **added** on top (V2).

The branch a gesture edits is decided **once, at mouse-down**, by a pure function in
DAWAppKit:

```swift
// Sources/DAWAppKit/PitchWobbleGesture.swift
public enum PitchWobbleStart: Sendable, Equatable {
    case own(sung: PitchWobbleReading)        // edit your wobble
    case made(fromNothing: Bool)              // edit (or start) a new wobble
    case refused(String)                      // why this note cannot be edited now
}
public static func classify(segment: NoteSegment, sung: PitchWobbleReading?,
                            basis: PitchPlayedLine.Basis) -> PitchWobbleStart
```

In order:
1. **The basis gate first** (5.5). It may refuse.
2. If `segment.hasGeneratedVibrato`, the result is `.made(fromNothing: false)`: the note
   already plays a new wobble.
3. If the sung reading (section 8, over the render's contour of **what was sung**, never
   over the played line) is `.noWobble`, the result is `.made(fromNothing: true)`. There
   is nothing of the singer's to widen, so up means "add one". The note's scales are left
   as they are, so the singer's natural line stays under the new wobble.
4. Otherwise (`.wobble` or `.unmeasurable`) the result is `.own(sung:)`. **This includes a
   > ⚠ Amended by §18.3 (Defect 2): on an `.unmeasurable` note, widening is capped at k = 1 unless there is evidence of real movement.
   note the user already flattened** (`vibratoScale == 0`): the sung contour still has a
   wobble, so up brings it back. Flat is the bottom of your wobble, not the start of a new
   one.

A gesture never changes branch by passing through flat. The only change of branch inside a
gesture is the one-way **handoff** from your wobble to a new one (section 6).

### 5.2 Your wobble: the keep lever

> **Amended (natural tuning, §3):** A new **Drift tool** (C5a-5, beside Wobble) decouples the keep lever: if G3 passes, Wobble writes `vibratoScale` only, Drift writes `driftScale` only, so the coupling `min(driftAtMouseDown, k)` below no longer applies; if G3 fails, `driftScale = d0·k/k0` stays (line :463 rule). Multi-selection via batch `setClipNotesVibrato` (:775): single setter becomes one-item call. Double-click toggles between as-sung (1) and the same "Steady" target as the "Steady drift" menu row (0 until L3, then the user's pick per R24). Short notes (:1743 R18). Risk (:1836 R30). Note: natural-tuning §3 calls this tool C5a-5, so the build schedule (2026-09-25) renames this design's own looked-at gate to **C5a-G** to avoid the clash.

- **Width travel moves the keep factor** `k = vibratoScale`, from its value at mouse-down.
  > ⚠ Amended by §18.3 (Defect 2): k > 1 needs a `.wobble` reading, or a fitted depth ≥ `reportFloorCents`.
  It is clamped to **[0, 2]** and quantised to steps of 0.05.
  - [0, 2] is a pick. The model allows 0…4 (`shapeScaleRange`, itself a pick, V12).
  - Twice as wide is already an exaggeration a novice will not mistake for subtle.
- **Gain: the top of the wobble follows the pointer.**
  `Δk = widthTravel / (rowHeight × max(D, 20) / 100)`, where `D` is the sung reading's
  depth in cents and `rowHeight` is `geometry.rowHeight` at mouse-down (100 cents is one
  row).
  - The floor of 20 c stops a small wobble from giving an uncontrollable gain.
  - For `.unmeasurable` there is no `D`, so `Δk = widthTravel / (3 × rowHeight)`.
  - Both gains are picks.
- **Drift is coupled on the way down only:** `driftScale = min(driftAtMouseDown, k)`.
  - Pulling down straightens the slow drift together with the wobble, and flat is truly
    flat (5.3).
  - Pulling up above where drift started leaves drift alone, so widening never exaggerates
    the slides into and out of a note.
  - The rule is continuous: at `k = driftAtMouseDown` both branches of `min` agree.
- **Speed travel does nothing below the dead zone, then triggers the handoff** (section 6).
- The readout is the estimator over the **draft played line** (section 9), never
  `k × D` (V12, rule 5).

### 5.3 Why flat writes both scales (D5)

> **Amended (natural tuning, §3):** C5a-F2 (a separator v2 with no inversion) is promoted into §3 as the prerequisite for the Drift tool. Natural-tuning §3 decides (per R24): if G3 passes, flat is an explicit action "Flatten note" / "Remove wobble and drift" (R26 :1802) writing both to 0; if G3 fails, the fallback rule (:764-766) applies. The "inverted 17–22 %" reason here (D5) is exactly what v2 removes, and G3 must show it removed.

`vibratoScale = 0` alone keeps an inverted 17–22 % of a 4.5–6 Hz wobble. That figure is
the model's own statement and the boxcar arithmetic agrees (V3). With both scales at 0,
the shaping term is `−(drift + vibrato) = −(the whole deviation from the note's detected
centre)`. The split between drift and vibrato cancels algebraically, and the drawn line
inside the note is exactly the note's centre plus its offset. That is Hard Tune's
composition, which the render has already been measured delivering.

**The honest consequence, stated rather than hidden:** pulling a note flat also
straightens the slide into and out of it. Keeping the slides while removing the wobble
needs a separator that does not leak, which means a `PitchRenderContour.shapingVersion`
bump and its own measurement. That is follow-up **C5a-F2**, now part of the §3 prerequisite.

**Flat is flat in the picture, not in the audio.** The render leaves some wander: Hard
Tune cut it by 48–58 % at A3 and B3, and *"most of what is left in every case is the
renderer"* (V3). So the readout says **"smoothed flat"**, never "0 cents" and never "no
wobble". The help adds: "Flat removes most of the wobble; a little of the recording's own
movement can remain."

### 5.4 A new wobble: width and speed

- **Width travel moves the depth** `vibratoDepthCents` over [0, 200] (the model's range),
  quantised to 5 c: `Δdepth = widthTravel × 100 / rowHeight`, so the top of the wobble
  follows the pointer.
- **Speed travel moves the heard rate** `h` at **0.05 per second per point** (20 points
  per step of 1 per second), quantised to 0.1. The gain is a pick.
  - `h` is clamped to [2, 8]. The 2 is a pick. The 8 is the measured ceiling (V12).
  - The stored rate is `h × stretchRatio`, clamped to `min(8, 8 × stretchRatio)`. On a
    clip at ratio 1.25 the fastest reachable heard rate is therefore 6.4, and the readout
    says so (section 9).
- **A diagonal drag changes both.** That is what the reference frames show (5.5 → 7.8
  while 93 → 32).
- **Starting from nothing** (`fromNothing`):
  - the speed starts at the stored rate if it is non-zero (a parked rate is inert at
    depth 0, V2), otherwise at **5.5 heard**, the reference's first readout and the
    middle of sung vibrato;
  - the draft sets `vibratoPhaseAnchorSeconds` to the note's temporal centre, so speed
    changes stretch the cycles around the knob (section 7);
  - the onset is set to the provisional pick (9.5).
- **An existing new wobble keeps its anchor and onset.** A second gesture does not
  re-phase or re-fade what the first one made.
- Pulling down to depth 0 makes the note flat under this branch: no generator. On a note
  that **had** a new wobble, the release commits depth 0 and keeps the rate stored, where
  it is inert, so the next pull-up resumes at the same speed.
- ⛔ **A gesture whose result plays exactly like the stored note commits nothing.** A
  `fromNothing` gesture carries a parked rate, a centre anchor and an onset in its draft.
  If it ends at depth 0, those fields differ from the stored ones while the sound does
  not. A commit would make `isEdited` true, and the blob would then draw in `signal` ink
  with a ghost for a note that plays identically: C-0b's "looks edited, isn't" defect in
  reverse.
  - So `endWobbleDrag()` emits a commit only if the draft or the stored segment has a
    generated wobble, or if either scale changed.
  - Otherwise it emits nothing, whatever the draft parked. The parked speed is shown while
    dragging ("none yet") and is not kept.
  - T10 asserts this.

### 5.5 Gating on the played line's basis (D15)

Your wobble is resolved against the render's contour. While the played line's basis is
`.estimate`, a `vibratoScale` or `driftScale` other than 1 lands in
`unresolvedShapingSegmentIDs` and renders as nothing. The curve banner says what follows:
*"a replace gesture sounds like "add" for that render"* ([READ] ~919-929). So:
- **Basis `.render`:** every branch.
- **Basis `.estimate`:** only a note that already has a new wobble **and** has both scales
  at 1 is editable. Nothing it can write, and nothing it keeps, needs the contour. Every
  other press is refused, with the reason drawn in `PanelRefusalLine`:
  - while the contour is pending: "Changing a wobble needs the app's analysis of this
    recording. One moment."
  - when it is unavailable or from another detector generation: "The app couldn't analyse
    this recording, so this note's wobble can't be changed. Its pitch can still be moved."
- The wire is not gated (section 12). An agent can write any field, and the render's
  existing unresolved notice reports what it could not apply.

### 5.6 ⛔ CONFLICT with two shipped texts. Called out, not absorbed.

**What they say.**
- The 09-22 doc §7.2b [READ ~968-970]: *"FLATTEN AND ADD ARE ONE TOOL, ONE CONTINUOUS
  RANGE."*
- The `NoteSegment` generator banner [READ ~347-352]: *"A UI that wants ONE axis running
  `sung → flat → synthesised` ... maps that axis onto BOTH fields ... The natural zero the
  axis passes through is exactly the point where both are at zero."*
- `PitchCorrectionUndoKey.vibrato` [READ ~843-852] justifies its one-key rule by a single
  drag that *"writes `vibratoScale` on the way down and `vibratoRateHz`/`vibratoDepthCents`
  on the way up"*.

**What this design does instead.** It keeps **one tool** and does not keep **one
continuous range**. On a single axis running sung → flat → new, pulling down makes the
wobble narrower until flat, and then **wider again** as the new wobble grows. The
direction of the pointer stops meaning "narrower" halfway through the same motion. A
novice cannot learn that.

**The reference frames do not contradict this.** Flat (frames 2–4) was reached **before**
the tool was engaged and before the click; the new wobble was then pulled from flat (09-22
§7.2b's own timeline). That is two actions, which is what 5.1 does.

**What survives.**
- The one-key rule is still right, for a different reason: the handoff (section 6) writes
  both mechanisms, both scales at 0 plus the generator, in one gesture, so they must be
  one undo entry.
- Item C5a-2 restates the key's doc comment with that reason. It is a comment change, not
  a behaviour change.
- The banner's *"the flat half drives `vibratoScale` 1 → 0"* is superseded by D5 (V3), and
  C5a-2 corrects that comment too.

---

## 6. Continuity: the first tick on a sung note

### 6.1 The problem

Changing a wobble's speed needs synthesis, because the singer's wobble can only be scaled
(`0 × anything = 0`; 09-22 §7.5 conflict 2). A synthesised wobble is a clean sine; a sung
one is not. It wanders in rate, builds and fades in depth, and its phase is its own. So
there is no synthesised wobble that sounds exactly like the sung one, and any swap is a
change. The requirement is that the **first tick** of a speed drag on a sung note does not
change the sound.

### 6.2 Decision: a dead zone, then a one-time handoff

**The dead zone.** On the own branch, speed travel is inert until **|speed| ≥ 16 pt and
|speed| ≥ |width|**: the pointer has gone at least 16 points, mostly sideways. Both numbers
are picks.
- Until then, the draft's generator fields equal the stored ones.
- A drag that ends inside the dead zone with no width travel leaves the draft table equal
  to the stored table, so `draftPlayedLine == playedLine` (Equatable) and the gesture
  commits nothing. That is **byte-identity by construction**, and it is test T2's claim.
- A mostly-vertical drag with some sideways wander never crosses: the dominance condition
  holds it.

**The handoff.** It happens once per gesture, at the tick that crosses.
1. Build the note's played points from the **current draft**, with any C5b drawn shape
   removed from the copy (section 13).
2. Read them with the estimator (section 8), in edited seconds (section 11.3). Call the
   reading `R`.
3. If `R` is `.wobble(rate f, depth A, anchor τ)`, the new draft is:
   - `vibratoScale = 0`, `driftScale = 0`;
   - heard rate `h = quantise(f / stretchRatio, 0.1)`, stored rate `h × stretchRatio`;
   - `vibratoDepthCents = quantise(A, 5)`;
     > ⚠ Amended by §18.2: the seed is the CALIBRATED depth, A ÷ `response(pitch)`, and the handoff is refused where `response` is nil. C5a-L2 arbitrates.
   - `vibratoPhaseAnchorSeconds = τ`, the fitted sine's rising zero crossing nearest the
     note's centre, so the new sine starts in step with the old one there. It does not
     depend on the rounding of the rate; the rounded rate only lets the two drift apart
     slowly away from `τ`;
   - `vibratoOnsetSeconds` = the pick (9.5).
4. If `R` is `.noWobble` (for example, the keep was already near 0), the new draft is:
   - both scales 0;
   - depth 0;
   - heard rate from the **sung** reading if it is `.wobble`, else 5.5;
   - anchor at the note's centre;
   - onset = the pick.

   Both sides of this handoff are flat, so it is continuous.
5. If `R` is `.unmeasurable`, the handoff is **refused for this gesture**. Speed stays
   > ⚠ Amended by §18.3 (Defect 1): a draft with both scales at 0 is taken as `.noWobble`, whatever its sample count. The refusal words are §18.3's.
   inert, and the readout says: "This wobble is too uneven to change its speed. Drag down
   to smooth it flat, then sideways to make a new one."
6. From then on, the gesture is on the made branch.
   - Speed moves the heard rate from `h` by `(|speed| − 16) × gain`, in the sign of
     `speed`.
   - Width moves the depth from its seed by `(width − widthAtHandoff) × gain`.
   - The keep change made before the handoff is superseded, because the scales are now 0.
7. The handoff is **one-way within the gesture.** Moving back inside the dead zone does
   not bring your wobble back. Undo does, in one step, because the whole gesture is one
   commit. The readout flips to `New wobble: …` and carries `(replaces your own)` for the
   rest of the gesture.

**What the handoff changes in the sound.** The singer's irregular wobble is replaced by a
clean sine at the same heard speed, the same width and the same phase at the anchor. What
remains different is:
- the singer's irregularity: rate wander, the depth envelope, a non-sine shape;
- the slides, now straightened.

That is the smallest change possible without re-rating the singer's own wobble
(Alternative 2). Test T14 measures it.

### 6.3 The alternatives that lose

**Alternative 1: swap at mouse-down.** Seed the new wobble from the reading the moment the
note is pressed. This loses outright on the requirement. Every press, including a click or
a pure-vertical widen, would replace the singer's wobble. Without the anchor (section 7),
the sine's phase would also be wherever source second 0 puts it. Two equal-width sines in
opposite phase differ by twice the width, so the first tick could move the line by the
wobble's whole span.

**Alternative 2: re-rate the singer's own wobble.** Scale the instantaneous phase of the
contour's periodic part, `A(t) · cos(φ₀ + k · (φ(t) − φ₀))`. At `k = 1` this is continuous
by construction, and it keeps the singer's character. It loses on four counts:
- It is a new relative field whose render depends on the contour: the unresolved
  fallback, the contour key, and a `shapingVersion` bump.
- It is a second rate mechanism beside the measured generator, so there would be two
  speed readouts with two different honesty bounds.
- Analytic-signal phase over 2 to 10 cycles has edge behaviour nobody has measured.
- The "periodic part" it would re-rate is contaminated by the separator's leak (V3).

It is named as follow-up **C5a-F3**, to reconsider if listening shows new wobbles sound
mechanical.

**Alternative 3: refuse speed on the singer's wobble until the note is flattened.**
Sideways does nothing, and a drawn hint explains. This is fully continuous and the
simplest option. It loses on the user's own words, "add more cycles": it turns one drag
into a lesson and two gestures. **It is the fallback** if the user answers the question in
section 17 "no". The change would be confined to `PitchWobbleGesture` (the handoff becomes
the refusal of step 5).

**Considered and rejected: a crossfade handoff** over the first N points. It is continuous
in the picture, but the halfway states sum two wobbles at different phases, and those
partly cancel. A release at that point would commit a half-cancelled wobble nobody asked
for.

---

## 7. The phase anchor (a model change)

### 7.1 Decision

`NoteSegment` gains one stored field:

```swift
/// Where the SYNTHESISED wobble's phase is anchored, source seconds: the generator is
/// `depth × fade(t) × sin(2π · rate · (t − vibratoPhaseAnchorSeconds))`.
/// `0` (the default) is exactly the phase every set had before this field existed:
/// anchored at source second zero. Stored, NOT derived from `startSeconds`, so
/// `canonical` truncation cannot re-phase it and a split copies it to both halves.
/// Inert at `vibratoDepthCents == 0`, like rate and onset, so it stays out of `isIdentity`.
public var vibratoPhaseAnchorSeconds: Double
/// Structural bound for sanity, not a taste pick: the wobble editor anchors inside or
/// within half a period of a note, so no real value falls outside it.
public static let vibratoPhaseAnchorSecondsRange: ClosedRange<Double> = -1...86_400
```

**Evaluation.** `Span` gains `vibratoPhaseAnchorSeconds`, and `generatedVibrato` computes
`sin(span.vibratoRadiansPerSecond * (t - span.vibratoPhaseAnchorSeconds))`.

**No branch is needed at the default.** `t − 0.0 == t` for every finite `t` in IEEE
arithmetic: `x − (+0) = x`, and `−0 − (+0) = −0`. So at anchor 0 the argument is
bit-identical to today's `ω · t`. Write that in a comment beside the line. The proof is
that `NoteVibratoGeneratorTests` §A's render and digest goldens stay green (test T12).

### 7.2 Why it keeps the banner's two guarantees

The banner anchored the phase at source second 0 for two reasons ([READ] ~931-943).
- **`PitchEditSet.canonical` truncation.** First-wins moves a later note's
  `startSeconds`. A start-anchored phase would re-phase a note nobody touched. The anchor
  is **stored**, and truncation does not touch it.
- **Split.** A start-anchored phase would restart the sine at the cut. The anchor is
  **copied** to both halves by `reidentified`'s Codable round trip, so both halves share
  one phase, and `generatorIsContinuousAcrossASplit` still holds.

### 7.3 What it buys

- **V6 is fixed.** The phase is pinned at the anchor, which the editor puts at the note's
  centre, so a speed drag stretches the cycles around the knob. The phase change at time
  `t` is `2π · (t − τ) · Δf`. For a 1 s note, at the note's ends, that is
  `2π × 0.5 × 0.05 ≈ 0.16` radians per point: a gentle stretch, not a jump, at any
  distance into the file.
- **The handoff can match phase** (section 6): the new sine crosses zero where the
  singer's fitted wobble did.

### 7.4 Every pin it touches (all updated in C5a-1)

- `isIdentity`: stays **out**. It is inert at depth 0 by arithmetic, the rule rate and
  onset already follow (V2). `identityFollowsDepthAlone` gains the field.
- `isEdited`: **joins**, as `|| vibratoPhaseAnchorSeconds != 0`, the way rate and onset
  already do (~534).
- `init`: sanitised with `PitchCorrectionMath.finite(…, default: 0)` and then clamped to
  the range. `generatorSanitises` gains non-finite and out-of-range cases.
- Codable:
  - a `CodingKeys` case;
  - `decodeIfPresent(...) ?? 0`;
  - encode **omitted at 0**.
  So `legacyPayloadRoundTripsWithoutNewKeys` stays green, and every saved project
  re-encodes byte for byte.
- `digestCoversEveryStoredField` (`Tests/DAWEngineTests/PitchCurveRenderTests.swift`
  ~411): the `covered` list gains the label.
- `generatorIsContinuousAcrossASplit`: unchanged, and must stay green.
- A new mutation test, `digestSeesTheAnchor`: changing one segment's anchor on a set with
  a generated wobble changes the hex; changing it on a set with none does not.

### 7.5 The digest block

The anchor gets **its own** block, not a `putDouble` inside the generator block. Adding it
to the generator block would change the digest material of every existing generator set,
re-render them all for no audible change, and turn `NoteVibratoGeneratorTests` §A's digest
goldens red. The template is the generator suffix itself (09-24 doc F8).

```swift
// PitchEditSetDigest.hex (StretchCurvePlan.swift), directly after the generator block.
if set.segments.contains(where: { $0.hasGeneratedVibrato && $0.vibratoPhaseAnchorSeconds != 0 }) {
    putBits(vibratoAnchorSuffixMarker)            // a new distinctive constant
    for segment in set.segments {                 // EVERY segment: the generator block's rule
        putDouble(segment.vibratoPhaseAnchorSeconds)
    }
}
```

- **Why the condition includes `hasGeneratedVibrato`.** An anchor on a note with no
  generated wobble changes nothing audible, so it must not re-render anything. This is the
  rate and onset precedent.
- **The every-segment rule's one cost.** Once any segment carries a generated wobble with
  an anchor, the block hashes every segment's anchor, inert ones included. So an inert
  anchor re-keys a set that has an active one. The UI can never store an inert anchor:
  5.4's no-commit rule drops a gesture that ends without a wobble. Only the wire can, and
  a needless re-render is the safe direction.
- **A set with no anchors produces byte-identical material.** Every cache entry on every
  disk survives, and `layoutVersion` stays 1.
- **Block order is fixed: generator, anchor, warp (C2-1), shape (C5b-1).** Each block is
  marker-gated and emitted only when used. Whichever of the three items lands first, no
  existing set re-keys. The 09-24 doc §5.4 fixed "generator, then warp, then shape"; this
  inserts the anchor block second, and the digest's comment records the full order.

### 7.6 Under C2 (per-note timing)

C2-1 moves the generator into edited time and anchors the envelope at `W(startSeconds)`
(09-24 doc §3.4 step 4). The phase anchor maps the same way:
`sin(ω · (e − W(vibratoPhaseAnchorSeconds)))`.
- Whichever of C5a-1 and C2-1 lands second adds this one line to the edited-time branch.
- Test: a retimed note keeps its zero crossing at `W(anchor)`.
- The editor computes an anchor from the played line in **edited** seconds (11.3), and
  stores `W⁻¹` of it, because the model's axis is source seconds. Before C2 the two axes
  are identical.

### 7.7 The alternatives that lose

- **No field.** V6 makes the speed drag unreadable after the first few seconds of any
  recording. The draft line would show a boiling wobble, faithfully.
- **Snap the rate to values that keep the phase fixed at the note's centre** (a lattice
  spaced `1 / t_centre` Hz). This works late in a file (0.03 Hz steps at 30 s) and fails
  early (1 Hz steps at 1 s). The speed readout would jump unevenly, and the stored rate
  would not be the one the user picked.
- **Anchor each note at its own start.** This breaks both of the banner's guarantees
  (7.2), which is exactly why the banner rejected it.

---

## 8. Measuring the sung wobble

### 8.1 What is measured, and from which data

**Data: the render's whole-file contour**, from `ProjectStore.renderPitchContour(clipId:)`
(V4). It is never taken from the editor's window detection. The two are different analyses
(09-24 doc F18: 16 of 2004 frames flip voicing, and pitch differs by a median of 1.7 c and
at most 17.7 c on a trimmed clip). The handoff seed has to describe the line on screen and
the curve the render shapes against, and both of those come from the render's contour. When
there is no `.detected` contour, there is no reading, and the own branch is gated anyway
(5.5).

**Two inputs, one function.**
- **The sung reading.** Input: the note's voiced frames with `timeSeconds` in
  `[startSeconds, endSeconds)`, timed at the frame centre
  (`+ contour.frameValueOffsetSeconds`), in cents against `detectedHz`. Used for: the
  branch at mouse-down (5.1), the keep gain's `D` (5.2), and a speed fallback (6.2 step 4).
- **The played reading.** Input: the **draft** played line's points attributed to the note
  by frame centre (the `PitchPlayedLine.noteSummaries` rule, [READ]), at
  `Point.editedSeconds`, in cents against the note's played median. Used for: the own
  branch's readout and the handoff seed.
  - For **both** uses, the line is built from a table copy with the note's C5b shape
    cleared (section 13).
  - Otherwise "Your wobble: about 60 cents" on a note whose singer wobbled 40 and whose
    drawing adds 20 would misreport the singer. The drawing is a separate layer, and the
    readout says so ("your drawn changes stay on top").
  - Until C5b-1 lands there is nothing to clear.

### 8.2 The estimator

It lives in `Sources/DAWCore/PitchWobbleEstimate.swift` (new). It is pure and total:
seconds and cents in, a reading out.

```swift
public enum PitchWobbleShortfall: String, Sendable, Equatable {
    case tooFewSamples, tooShort, tooUneven
}
public enum PitchWobbleReading: Sendable, Equatable {
    /// rate per second OF THE TIME AXIS GIVEN; depth is a PEAK ("each way");
    /// anchor = a rising zero crossing of the fitted sine, nearest the middle;
    /// fit = share of the detrended variance the sine explains, 0…1.
    case wobble(rateHz: Double, depthCents: Double, anchorSeconds: Double, fit: Double)
    case noWobble
    case unmeasurable(PitchWobbleShortfall)
}
public enum PitchWobbleEstimate {
    public static func read(times: [Double], cents: [Double]) -> PitchWobbleReading
    /// The per-tick readout: amplitude and anchor at a KNOWN rate. No rescan.
    public static func refit(times: [Double], cents: [Double],
                             rateHz: Double) -> (depthCents: Double, anchorSeconds: Double)?
    public static func sung(_ segment: NoteSegment,
                            contour: PitchRenderContour) -> PitchWobbleReading?   // nil unless .detected
    public static func played(_ segment: NoteSegment,
                              line: PitchPlayedLine) -> PitchWobbleReading
}
```

**Method.**
1. **Trim** 10 % of the note's samples at each end, at least 2 samples each. Onset scoops
   and releases are not the wobble.
2. **Centre the time axis:** `u = t − t_mid`.
3. **Scan.** For each candidate rate from 3.0 to 9.0 Hz in 0.02 Hz steps, fit
   `c = p0 + p1·u + p2·u² + a·sin(ωu) + b·cos(ωu)` by least squares (a 5 × 5 normal
   solve), and record the residual `RSS(ω)`. This is a proper least-squares fit, **not**
   the tests' one-bin projection, whose amplitudes are biased by a partial cycle (V7).
4. **Pick the best rate** `ω*` as the smallest residual, refined by a parabola through
   its two neighbours. A minimum at either end of the scan means there is no interior
   peak, and the result is `.unmeasurable(.tooUneven)`.
5. **Measure it.** Refit at `ω*` to get the depth `A = √(a² + b²)` and the fit
   `F = 1 − RSS(ω*) / RSS_trend`, where `RSS_trend` is the residual of the quadratic alone.
6. **Decide**, in this order:
   - fewer than 24 samples: `.unmeasurable(.tooFewSamples)`;
   - `A` below the floor (8.3): `.noWobble`;
   - trimmed duration × `f*` below 2.0 cycles: `.unmeasurable(.tooShort)`;
   - `F < 0.4`: `.unmeasurable(.tooUneven)`;
   - otherwise `.wobble(rateHz: f*, depthCents: A, anchorSeconds: τ, fit: F)`, where
     `τ = t_mid − atan2(b, a) / ω*`, moved by whole periods to the value nearest `t_mid`.
7. **Cost [INFERRED].** 301 candidates × at most about 500 samples × about 20 operations
   is about 3 million floating-point operations per note, well under a millisecond in a
   release build.
   - The sung reading is needed on **hover** (9.2, first row), not only at mouse-down. It
     is cached per (segment id, contour generation) and invalidated when the model's
     `contourGeneration` or the note table changes. It is never recomputed per hover tick.
   - A mouse-down runs at most one full read, of the played line.
   - A drag does not rescan: a keep change does not move the rate, so each draft change
     runs one `refit` at the known rate, one 5-parameter solve.

### 8.3 The floor has one home
> ⚠ §18.1.7 (2026-09-24): this floor is half the LATTICE's bin, and the product is not a lattice. What it should mean is re-derived later (C5a-F6). A second, separate floor for calling something a wobble is `reportFloorCents` (§18.1.4).

The floor is `PitchCorrectionMath.detectorResolutionFloorCents = 12.90`, added to DAWCore
with a citation of the file header's constraint 1 (half a 25.79 c detector bin).
`PitchEditorReadout.centsResolutionFloor` becomes an alias of it (V10). A readout and the
estimator can then never disagree about what the detector can resolve.

### 8.4 Every threshold is a pick until validated

These are all picks: 24 samples, 2 cycles, `F ≥ 0.4`, the 10 % trims and the 3–9 Hz scan.
Validation (8.5) may move them, and must do so **before** anything prints a number. The
validation must never loosen a threshold just to make it pass.

### 8.5 Validation (item C5a-0)
> ⚠ **Superseded by §18.1** (2026-09-24, re-picked against the product detector): (a)'s lattice fixtures, its 7 c depth bound, its 0.05 Hz jitter-free rate bound, the ±8 c control and the 0.35 s control, and (b)'s [0.75, 1.05] band.

**(a) Synthetic contours**, built as `ClipPitchFrame`s at 62.5 frames per second.
- The pitch is quantised onto the detector's own lattice: 256 log-spaced bins over
  46.875–2093.75 Hz, 25.79 c each (the header's constraint 1, [READ]).
- Three base pitches (A3, B3, E4), so the lattice's offset from the note varies.
- The grid:
  - rate {4.5, 5.5, 6.5, 7.5} Hz;
  - depth {20, 40, 80} c;
  - rate jitter: none, or a slow random ±5 % wander;
  - drift: none, a 30 c linear ramp, or a −80 c onset scoop over 80 ms;
  - duration {0.6, 1.0, 2.0} s.
- **Assert:**
  - `.wobble` whenever depth ≥ 20 c and duration × rate ≥ 2.5;
  - rate error ≤ 0.15 Hz at the 95th percentile (≤ 0.05 Hz without jitter);
  - depth error ≤ 7 c, the chain's own honest bound (V12), so the estimator is never the
    looser link.
- **Negative controls** (each proves the floor or a refusal can fire):
  - a flat quantised line reads `.noWobble`;
  - a ±8 c sine reads `.noWobble`;
  - a 0.35 s note at 5.5 Hz reads `.unmeasurable(.tooShort)`;
  - of 20 fixed-seed random walks of ±30 c, at most one reads `.wobble`.
- **Anchor:** on a jitter-free fixture, `sin(2π f (t − τ))` crosses zero, rising, within
  5 ms of the fixture's own crossing.

**(b) The real detector.** Env-gated; route audio-dsp-engineer; the
`ContourShapingSweepTests` gating pattern.
- Input: a harmonic tone carrying a known 5.5 Hz ±40 c wobble, at A3 and at B3, passed
  through THE seam's detector and then the estimator.
- Assert the rate is within 0.2 Hz.
- Record the depth as a fraction of the truth, and assert it lies within [0.75, 1.05]. The
  detector reads 80–97 % of a real wobble's depth ([READ] ~1394-1402), so the number a
  person sees for their own wobble can be up to about a fifth low. Section 9 says "about"
  because of this.

**(c) The real dry vocal.** Env-gated; the file E2 used.
- Log every note's reading.
- **Looked-at gate:** for five notes, a person compares the printed speed with a count of
  the peaks in the drawn line, on a `view.capture` from staging (port 17695).

If (a) misses its bounds, **the item stops and reports**. The thresholds are then re-picked
from the data. A tolerance is never widened to make a test pass.

### 8.6 What the reading means, in words
> ⚠ §18.1.4: `.noWobble` now also covers readings below the 20 c report floor. The words for every row are §18.3's.

| Reading | What it tells the readout (section 9) |
|---|---|
| `.wobble` | a speed and a width, both prefixed "about" |
| `.noWobble` | "no wobble the app can measure", which is not the same as "none" |
| `.unmeasurable(.tooShort)`, `.tooFewSamples` | "too short to measure" |
| `.unmeasurable(.tooUneven)` | "too uneven to measure" |

---

## 9. The readout

### 9.1 Where, and in what units

- **Where.** Beside the knob, above the note, on hover and during a drag. The same text is
  mirrored in the palette's readout slot in SF Mono. It is always **drawn**, never a
  tooltip, because `view.capture` cannot see tooltips (V13).
- **Speed.** The **heard** rate (V5), "per second", one decimal.
- **Width.** "cents each way", rounded to the nearest 5. That is the model's PEAK (V2):
  ±30 c swings 30 above and 30 below. The help says once that 100 cents is one piano key.

### 9.2 The exact strings
> ⚠ §18.3 replaces this table's `.unmeasurable` rows, the handoff-refusal row and the `.noWobble` parenthetical, and adds a speed-only row for pitches no T6 block covers.

| State | Readout |
|---|---|
| Hover or press, your wobble, reading `.wobble` | `Your wobble: about 5.5 per second, about 40 cents each way` |
| Dragging your wobble | `Your wobble: about 5.5 per second, about 20 cents each way`: the played reading of the **draft**, refit per draft change (8.2) |
| Your wobble when the played reading is `.noWobble` (keep at or near 0) | `Your wobble: smoothed flat` |
| Your wobble, sung reading `.unmeasurable` | `Your wobble: too uneven to measure` when idle; `Your wobble: narrower` / `wider` / `smoothed flat` while dragging, by the sign of the keep change |
| No wobble of its own (`.noWobble`), depth 0 | `No wobble the app can measure. Drag up to add one.` (Never "no wobble": a singer's wobble under the 12.90 c floor is real and unmeasured, 8.6.) |
| A new wobble | `New wobble: 5.5 per second, 30 cents each way` |
| A new wobble with a speed set but no depth | `New wobble: 6.2 per second, none yet. Drag up to add it.` |
| After the handoff, for the rest of the gesture | `New wobble: 5.5 per second, 40 cents each way (replaces your own)` |
| Handoff refused (6.2 step 5) | `This wobble is too uneven to change its speed. Drag down to smooth it flat, then sideways to make a new one.` |
| At the speed ceiling | `… 8.0 per second (the fastest that plays cleanly)` |
| At the lower ceiling of a slowed-down clip (ratio above 1: the model stores at most 8 per source second, V5) | `… 6.4 per second (the fastest possible on this slowed-down clip)` |
| At the speed floor | `… 2.0 per second (the slowest this control goes)` |
| At the width ceiling | `… 200 cents each way (the most this control allows)` |
| Heard rate over 8 **after** a clip-speed change (drawn red) | `New wobble: 9.6 per second: too fast to play cleanly at this clip's speed` |
| On a note that also has a C5b drawn shape | the line above, plus ` (your drawn changes stay on top)` |
| Gated (5.5) | nothing beside the knob; the caption in `PanelRefusalLine` |
| After release, until the render lands | `Rendering… you'll hear it in a moment.` The existing pending notice is the signal, as in C2 and C5b. |

### 9.3 The rules behind the strings

- **Your wobble's numbers come from the estimator over the draft played line.** They are
  never `keep × measured`.
  - Rule 5 forbids presenting the keep lever as a depth (V12).
  - Keep × measured would also be wrong: widening lets the separator's leak through, so a
    keep of 2 on a 5.5 Hz wobble plays about 2.2 × (V3). The played line, which is the
    render's own curve, already contains that; `k × D` does not.
  - The numbers carry "about", because the detector reads 80–97 % of a real wobble (8.5b).
    > ⚠ §18.1.2 / §18.1.6: the product reads 0.75–0.99 at mid pitch and 0.16–0.89 at 83–110 Hz. A width prints only where a T6 block covers the note's pitch.
- **A new wobble's numbers are the asked values**: heard rate is stored ÷ ratio, and depth
  is rounded to 5.
  - The estimator is not used here: an onset fade lowers a whole-note fit, and would show
    "25" for a wobble asked and delivered at 30.
  - The generator is measured to deliver the asked depth within ±7 c at typical rates
    (V12), at ratio 1. C5a-1 measures ratios other than 1.
- **Never print these:**
  - a speed above what plays cleanly as if it were fine (that is the red state);
  - a cents number for `.noWobble` or `.unmeasurable`;
  - a keep percentage (rule 5);
  - "0 cents" or "no wobble" for flat (5.3).
- **Speed on your wobble** is shown to 0.1 with "about". If C5a-0's validation cannot hold
  0.15 Hz at the 95th percentile, the item stops and this rule is revisited. The display is
  never quietly widened to hide it.
- **C-0's `draftSpan` applies unchanged to a wobble draft.** Every field C5a writes lives
  inside the note's gate (V2; the shaping and generator terms are gated), so the note
  widened by half the retune ramp on each side is exactly where the draft line can differ.
  Do not invent a second span.
- **The readout and the draft line are rebuilt only when the quantised draft changes.**
  The quantisation (0.05 keep, 5 c, 0.1 per second) turns most pointer ticks into no-ops,
  so a typical drag rebuilds `PitchPlayedLine` tens of times, not at pointer rate. The cost
  of each rebuild is C-0's measured build time (09-24 doc §4.2).

### 9.4 Rounding, summarised

| Quantity | Stored step (from the UI) | Shown as |
|---|---|---|
| Keep `vibratoScale` | 0.05 | never shown as a number |
| Heard rate | 0.1 per second (stored = heard × ratio) | one decimal |
| Depth | 5 c | nearest 5 |
| Your wobble's width (a reading) | not stored | "about", nearest 5 |
| Your wobble's speed (a reading) | not stored | "about", one decimal |

The UI quantises, so the number a person sees is the number stored. The wire does not
quantise, because agents may want exact values (section 12). Its values are shown rounded.

### 9.5 Onset (D14)

Onset is not on the handle, because a third quantity on a two-axis gesture would be
unlearnable. When the UI **creates** a new wobble, either from nothing or by the handoff,
it passes `vibratoOnsetSeconds = min(0.25, 0.3 × note length)`, rounded to 0.01 s. An
existing onset is kept.
- The value is a **pick**, and the listening item **C5a-L** replaces it: four options on
  one axis, and the user's choice is the feedback.
- The setter never supplies it silently (section 10).
- Onset on the handle (a context-menu choice, or a third knob) is follow-up **C5a-F5**,
  after C5a-L.

---

## 10. The store setter

In `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`, beside C1 and C3. It shares
`locateEditableNoteClip` (the MIDI and comp-member refusals), `noteTable(…seedIfAbsent:)`
(the stored table wins) and `segmentIndex` (the teaching not-found error).

```swift
/// Six optional fields. `nil` means "leave it". Units are the MODEL's:
/// `vibratoRateHz` is per SOURCE second.
public struct NoteVibratoEdit: Sendable, Equatable {
    public var vibratoRateHz: Double?
    public var vibratoDepthCents: Double?
    public var vibratoOnsetSeconds: Double?
    public var vibratoPhaseAnchorSeconds: Double?
    public var vibratoScale: Double?
    public var driftScale: Double?
    public init(/* all default nil */)
    public var isEmpty: Bool { /* every field nil */ }
}
public enum NoteVibratoLimit: String, Sendable, Equatable {
    case rateRange, heardRateCeiling, depthRange, onsetRange, anchorRange, scaleRange, driftRange
}
public struct NoteVibratoResult: Sendable, Equatable {
    public let clip: Clip
    public let segment: NoteSegment              // as STORED, after clamping
    public let clamped: [NoteVibratoLimit]       // empty when nothing bound
    public var heardRateHz: Double { segment.vibratoRateHz / clip.stretchRatio }
    /// A depth with no rate never moves: said out loud (item 10), never refused.
    public var silentWobble: Bool { segment.vibratoDepthCents > 0 && segment.vibratoRateHz == 0 }
}

@discardableResult
public func setClipNoteVibrato(clipId: UUID, segmentId: UUID, edit: NoteVibratoEdit,
                               seedIfAbsent: PitchEditSet? = nil) throws -> NoteVibratoResult
@discardableResult
public func resetClipNoteVibrato(clipId: UUID, segmentId: UUID,
                                 seedIfAbsent: PitchEditSet? = nil) throws -> NoteVibratoResult
```

**Behaviour.**
1. **An empty edit is refused**: "Nothing to change: give at least one wobble setting."
2. **A non-finite value is refused**, with an error naming the field. The model's `init`
   would silently turn a NaN into "inert", and a setter must not accept input it then
   ignores. JSON cannot carry a NaN, but the Swift API can.
3. **Each supplied value is clamped** to the model's range: `vibratoRateHzRange`,
   `vibratoDepthCentsRange`, `vibratoOnsetSecondsRange`, the new anchor range, and
   `shapeScaleRange` for both scales. A direct field assignment bypasses
   `NoteSegment.init` (the `setNotePitchClamps` lesson, the comment at ~73-83), so the
   clamp must be explicit.
   - It is **one pure DAWCore function**, in `Sources/DAWCore/NoteVibratoLimits.swift`
     (new):
     `NoteVibratoLimits.clamp(_ edit: NoteVibratoEdit, stretchRatio: Double) -> (edit: NoteVibratoEdit, bound: [NoteVibratoLimit])`.
   - The setter calls it. The UI drag calls the **same** function on every draft change.
   - So the drag and the wire can never disagree about how far is too far. This is C2's
     `NoteTimingLimits.clamp` pattern (09-24 doc §3.7).
4. **The heard-rate ceiling.** Additionally,
   `vibratoRateHz ≤ 8 × clip.stretchRatio` whenever that is below the model's 8 (V5).
   Every binding limit goes in `clamped`. A clamp is never a refusal, because a drag must
   never snap back.
5. **No hidden defaults.** The setter never invents an onset or an anchor. An agent that
   asks for depth 50 gets depth 50 and nothing else; the anchor stays where it was, and 0
   means today's source-second-0 phase. The UI passes onset and anchor explicitly when it
   creates a wobble (5.4, 6.2).
6. **One edit, one render.** Exactly one
   `performEdit("Change Wobble", key: PitchCorrectionUndoKey.vibrato(clipID:segmentID:))`
   and one `engine?.tracksDidChange(tracks)`.
   - The gesture writes `driftScale` under the `.vibrato` key too: one gesture, one key
     (5.6).
   - The `.drift` key is left for a drift-only control, which does not exist.
7. **A no-op is silent.** If every supplied value, after clamping, equals the stored one,
   `performEdit` journals nothing. This is C1's rule, and `captureEditState()` enforces it.
8. **Reset** writes all six fields to their defaults (keep 1, drift 1, rate 0, depth 0,
   onset 0, anchor 0) with
   `performEdit("Reset Wobble", key: PitchCorrectionUndoKey.structuralKey)`. A deliberate,
   discrete reset never merges into the drag before it (the preset rule, 09-22 §8.3).
9. **Two doc comments change in the same item, with no behaviour change:**
   `PitchCorrectionUndoKey.vibrato`'s stated motivation (5.6), and the generator banner's
   "the flat half drives `vibratoScale`" (V3).
10. **An inaudible result is said out loud, not refused.**
    - `NoteVibratoResult` gains `silentWobble: Bool`, which is true when the stored
      segment has `vibratoDepthCents > 0` and `vibratoRateHz == 0`. Such a wobble never
      moves (`sin(0) = 0`), yet depth breaks `isIdentity`. So the clip is re-rendered
      through the stretcher for nothing: the model's own `isIdentity` doc notes that
      *"a ratio-1 stretch is not its own input"*.
    - This is the "silent inaudible success" class this tree has already paid for once:
      a drum kit sent without its `kind`.
    - It is not a refusal, because an agent may send depth and rate in two calls.
    - The UI cannot produce this state: its speed floor is 2.

**The UI's commit.** `PitchEditorCommit.Kind` gains
`.noteVibrato(segmentID: UUID, edit: NoteVibratoEdit)`. The edit carries **all six**
fields from the draft, so what the UI drew is exactly what it submits.
`PitchCorrectionStaging.commitPitchNoteEdit` gains a case that calls
`setClipNoteVibrato(…seedIfAbsent:)` and **reads the stored segment back** from
`clip.pitchEdits`. It compares all six fields with an **independent** expectation:
`NoteVibratoLimits.clamp(edit, stretchRatio: clip.stretchRatio).edit`. Any mismatch raises
`PitchNoteEditDidNotTake` (V13; the C1 read-back rule).
- ⛔ The expectation must never be the setter's own returned segment. A check of the store
  against the store is circular, and it passes against a setter that dropped a field.

---

## 11. Split, canonical, and C2 timing

### 11.1 Split (C3): the right half's onset is re-derived

**The problem.** `splitClipNoteSegment` copies every field to the right half (V8). The
right half's fade then starts again at the cut.

**The fix.** When the parent has a generated wobble (`hasGeneratedVibrato`) and
`vibratoOnsetSeconds > 0`, the right half's onset becomes
`max(0, onset − (cut − parent.startSeconds))`. The left half is unchanged. Rate, depth,
anchor and both scales are copied, as the round trip already does.

**Where the fix is exact.** When the cut comes after the fade has finished
(`cut ≥ start + onset`), the right half's onset is 0. It is at full depth from the cut,
which is exactly what the parent played there, and the phase continues because the anchor
is shared (7.2).

**Where it is only bounded.** When the cut falls inside the fade, the right half fades up
from 0 over the time that remains. The parent would instead have continued from
`smoothstep((cut − start) / onset)`, so the dip is bounded by that level.
- This is stated, and tested as a bound (T8). It is not claimed away.
- ⚠️ **Corrected 2026-09-25 (C5a-2, MEASURED through `PitchCorrectionCurve`): that bound is too tight.** The right half's
  fade starts FLAT (smoothstep's zero slope) while the parent's is already rising, so the gap WIDENS for a moment after
  the cut. For a cut at 1.1 s in T8's fixture, the stated bound is 0.352 × depth and the measured dip is 0.422 × depth.
  T8 therefore asserts what holds: the right half never ADDS wobble, the dip stays under 0.45 × depth, and the curves
  match exactly once the parent's fade is done.
- Representing the fade exactly would need a second stored anchor for the envelope. That
  cost is not worth paying for a cut made within the first quarter-second of a note.

**The pinning test.** `splitCarriesEveryEditFieldTheParentHad` gains `vibratoOnsetSeconds`
in its `changeable` set **in the same change**, and a physics test takes over the claim
(T8). C2-4 and C5b-3 widen the same set for their own fields (09-24 doc F9). Whichever of
the three lands second rebases.

**The scales across a split.**
- **When the two scales are equal** (every keep at or below drift-at-start, and every
  preset), the shaping is `(k − 1) × (the whole deviation)`. That is independent of the
  separator, so a split is exact away from the gate ramps.
- **When keep is above drift** (a widened wobble), each half's moving average is
  edge-clamped at the cut. Shaping near the cut then differs from the unsplit note, by at
  most the separator's leak, within ±0.136 s of the cut (half the 272 ms window).
- That is pre-existing shaping behaviour, not something C5a introduces. T8 excludes that
  window for widened notes and says why.
- F12 (a gate dip at a split under a long retune) is separate and untouched.

### 11.2 Canonical truncation

First-wins moves a later note's `startSeconds` forward. The anchor is stored, so the phase
does not move (7.2). The envelope re-anchors at the new start, which is the banner's
deliberate choice (~410-413). Nothing here is new.

### 11.3 C2 per-note timing

**A new wobble keeps its heard rate.** After C2-1 the generator runs in edited time, with
`sin(ω · (e − W(anchor)))` and the envelope anchored at `W(startSeconds)` (7.6). So its
heard rate stays `stored / stretchRatio` whatever the note's retiming. That is why C2
moved it (09-24 doc F10).

**Your wobble does not.** It is part of the audio, and retiming a note by a local factor
`L` plays it at `f / (stretchRatio × L)`.
- The own-branch readout already accounts for this, because it reads the **played line in
  edited seconds** (`Point.editedSeconds`, 8.1). An estimate in edited seconds, divided by
  `stretchRatio`, is what is heard, with no separate `L` term.
- C-0 fills `editedSeconds` with the source second until C2-5 passes W (09-24 doc §4.2).

**The anchor across the two axes.** The editor computes an anchor in edited seconds (the
handoff, 6.2) and stores `W⁻¹` of it, because the model's axis is source seconds. Before
C2 the two are identical.

**Timing edits never touch the vibrato fields**, and vibrato edits never touch the timing
deltas. The only file both change is `splitClipNoteSegment` (11.1).

---

## 12. Wire and MCP

Every wire change here is **additive**: no live command is renamed, and no existing key
changes meaning.

### 12.1 `clip.setNoteVibrato` (new; `Sources/DAWControl/Commands.swift`)

**Parameters.**
- `clipId` and `segmentId`, both required UUIDs.
- Then **either**:
  - at least one of `vibratoRateHz`, `vibratoDepthCents`, `vibratoOnsetSeconds`,
    `vibratoPhaseAnchorSeconds`, `vibratoScale`, `driftScale`. Each is a finite number in
    the **model's** units. These are exactly the keys `clip.getPitchEdits` returns, so an
    agent can read a segment and write it back without a translation table;
  - **or** `reset: true`, alone. `reset` together with any other key is refused: "reset
    puts every wobble setting back to how it was sung; send it on its own."
- Unknown keys are refused with `rejectUnknownKeys`.
- There is **no detection on the wire path**: no `seedIfAbsent`. This is the
  `clip.setNotePitch` rule. A clip with no stored table is refused with the store's
  teaching text.

**Response.** `clip.getPitchEdits`'s shape, plus `segmentId`, plus:

```
vibrato: { requested: {only the keys sent},
           applied:   {all six stored values},
           heardRateHz,
           clamped:   ["heardRateCeiling", ...],
           note?      }
```

`note` is present whenever something was clamped, **or when the stored result is
silent** (depth set, rate 0: "vibratoDepthCents is set but vibratoRateHz is 0, so this
wobble does not move, and the clip is still re-rendered through the stretcher for
nothing. Send a rate, per source second, or set the depth back to 0."). It also appears when a rate is
parked with no depth ("vibratoRateHz is set but vibratoDepthCents is 0, so there is no new
wobble yet."). It always teaches. Clamp examples:
- "vibratoRateHz 9 was clamped to 8: above 8 per second the render cannot carry a wobble's
  shape."
- "vibratoRateHz 7 was clamped to 6.4: this clip plays at 0.8× length, so 6.4 per source
  second is heard at 8 per second, the fastest that plays cleanly."

**Errors** are inherited from the store: clip not found, MIDI clip, comp member, no
table, unknown segment (with the note count).

**Coalescing.** The `.vibrato` key: two calls on the same note within 800 ms fold into one
undo step. `reset` uses the nil key.

### 12.2 `clip.getPitchEdits` (additive)

Each segment gains:
- `vibratoPhaseAnchorSeconds`;
- `heardVibratoRateHz`, equal to `vibratoRateHz / clip.stretchRatio`.

That follows the response's own "EVERY field, always" rule ([READ] ~13608-13610).
`pitchEditsResponse(clipId:edits:appliedOptions:extra:)` does not know the clip's ratio
today, so it gains a `stretchRatio:` parameter, and every call site passes it. Census:
`grep -n 'pitchEditsResponse(' Sources/DAWControl/Commands.swift`, re-run at build time.

The verb still makes no engine call (V9).

### 12.3 `clip.getPlayedPitch` (C-0c; additive)

Each note gains:

```
wobble: { sung: Reading, played: Reading }
Reading = { kind: "wobble" | "noWobble" | "unmeasurable",
            heardRateHz?, depthCents?, anchorSeconds?, fit?, reason? }
```

Both readings come from `PitchWobbleEstimate`, run over the contour and the line the verb
has **already** built. A second read verb would fetch the contour again and could disagree
with this one, which is why the readings go here.

When the basis is not `render`, `wobble` is `null` and a `wobbleNote` says why, in C-0's
caption words.

### 12.4 MCP (`mcp-server/src/server.ts`)

**`clip_set_note_vibrato`.** Its description is written for an agent that has never seen
this model:

> Change one note's wobble (vibrato). Two separate mechanisms, combinable in one call.
> (1) vibratoScale and driftScale keep or flatten the SINGER's own wobble and slow drift:
> 1 = as sung, 0 = removed, above 1 exaggerates (up to 4). These are relative levers, NOT
> depths in cents. To flatten a note properly send BOTH at 0; vibratoScale 0 alone leaves
> part of the wobble behind. (2) vibratoRateHz, vibratoDepthCents, vibratoOnsetSeconds and
> vibratoPhaseAnchorSeconds make a NEW sine wobble that is ADDED on top (depth 0 = none).
> To replace the singer's wobble with a new one, send vibratoScale 0, driftScale 0 and the
> new wobble in one call. vibratoRateHz is per SOURCE second: what is heard is
> vibratoRateHz divided by the clip's stretchRatio (returned as heardRateHz), and the
> render cannot carry more than 8 heard per second. vibratoDepthCents is a peak, "each
> way"; expect the render to land within about 7 cents of it. Set
> vibratoPhaseAnchorSeconds to the note's middle ((startSeconds + endSeconds) / 2 from
> clip_get_pitch_edits) to centre the wobble on the note; left at 0, its phase is anchored
> at the start of the recording. Send reset: true alone to put the note back to how it was
> sung. Check the result with clip_get_played_pitch, which also measures each note's
> wobble.

**Also:** `clip_get_pitch_edits` and `clip_get_played_pitch` get updated descriptions for
the new fields.

**Tests:**
- `Tests/DAWControlTests/PitchNoteVibratoCommandTests.swift` (new);
- `mcp-server/test/pitch-correction.test.ts`.

### 12.5 `debug.pitchEditor` (dogfood, not a gate)

`Sources/DAWApp/PitchEditorDebugStaging.swift` gains:

```
wobble: { layout, branch, handedOff, speedTravel, widthTravel,
          draft: {the six fields}, readout,
          perNote: [{id, sung: Reading, played: Reading}] }
```

`tool` already reports the palette slot.

**No wire verb selects the tool**, and none is added. The capability is the operation,
`clip.setNoteVibrato`, which is the same rule C5b follows with `clip.setNoteShape`.

---

## 13. Coexisting with C5b on one note

**The sum is four terms** (09-24 doc §5.3):
`constant + shaping(s) + generator(e) + shape(s)`.
- C5a writes the shaping term (keep and drift) and the generator term.
- C5b writes the shape term.
- Neither writes the other's fields.

**C5b after C5a.** The brush writes a delta relative to the line the user currently hears,
and that line includes the wobble. So the drawn line lands where the pointer was (09-24
doc §5.5).

**C5a after C5b.** The drawn delta stays where it was drawn. A new speed moves the wobble's
peaks under it, so a peak the user pulled up may no longer sit on a peak.
- That is the honest consequence of composing by addition, not a bug.
- On such a note the readout appends `(your drawn changes stay on top)`.
- The two resets are separate menu items: "Back to how you sang it" (C5a) and "Reset drawn
  shape" (C5b).

**The handoff seed excludes the drawing.** The handoff measures the draft played line with
the note's shape arrays **cleared in the copy** (6.2 step 1). Otherwise the drawing would
be mistaken for part of the wobble, copied into the new sine, and then play twice. Until
C5b-1 lands there are no shape arrays, and this step is a no-op that C5b-1's author wires
up.

**⌘ at mouse-down is the brush in every tool**, through the one router (4.2). C5b-4 owns
that line.

**Separate words.** The readouts never mention each other's feature (section 3). C5a's
help mentions ⌘ only once the Shape tool exists.

**Separate undo steps.** A wobble gesture uses the `.vibrato` key and a stroke uses
`structuralKey`, so they are two undo steps.

**Identity.** C5b adds `!hasShape` to `isIdentity`. C5a adds nothing there, because the
anchor is inert at depth 0 (7.4).

---

## 14. Failure modes

| # | How it breaks | Mitigation | Test |
|---|---|---|---|
| 1 | The first sideways tick replaces a sung wobble. | The dead zone, plus the dominance condition (6.2). | T2 |
| 2 | The draft and the commit disagree, for example the draft uses heard rate as stored. The picture then changes on release. | One clamp function (section 10, item 3), one conversion, and the draft goes through C-0's `make`. | T3 |
| 3 | The drawn wobble boils during a speed drag. | The phase anchor (section 7). | T4 |
| 4 | "Flat" leaves an inverted wobble. | Both scales go to 0 (5.3). | T7 |
| 5 | A new wobble stacks on a flatten that could not be resolved (no contour). It "sounds like add". | The basis gate (5.5). The wire can still produce this; the render's existing unresolved notice names the note. | T15 |
| 6 | Heard rate is misreported on a stretched clip, or goes past 8 per second. | The conversion (V5), the setter's heard ceiling (section 10, item 4), and the render measurement at ratios 2 and 0.5. | T1, T9, T16 |
| 7 | The clip's ratio changes **after** a wobble is made, which changes its heard rate. That is correct: the singer's own wobble changes too. | No silent re-clamp. The readout shows the new heard rate, in red above 8 (the C2 failure-mode-6 precedent, 09-24 doc §3.10). | T16 |
| 8 | On a slowed clip (ratio above 1), 8 per second cannot be reached. `NoteSegment` does not know its clip, so its decode sanitiser cannot scale the range. | Said in the readout (9.2). Not fixed; a range that could not see the ratio would be the wrong layer to fix it in. | T9 |
| 9 | A split leaves a hole in a faded-in wobble. | The onset is re-derived (11.1). | T8 |
| 10 | A preset silently erases every wobble. | C-F3 gates C5a-4, as it gates C2-5 (V14). | C-F3's own |
| 11 | An estimate is printed when it should not be. | The floor, `tooShort` and `tooUneven` states, plus validation with negative controls (8.5). | T5, T6 |
| 12 | The readout claims more than the render delivers. | Width rounded to 5 c; "about" on your wobble; asked values on a new wobble, which are measured within ±7 c, **at ratio 1 only** until C5a-1 measures other ratios. | T1, T16 |
| 13 | Every release silences the clip until its render lands (09-24 doc F5). | Out of scope. Said out loud: "Rendering…". | none |
| 14 | Take-lane clips cannot be reached (V15). | Inherited: the setter's not-found error. Follow-up C-F2. | none |
| 15 | The help text names a tool that does not exist. | The ⌘ sentence is conditional (section 3). | T11 |
| 16 | Widening writes the two scales **apart** for the first time: keep above drift. The model says the 250 ms separator *"only starts to matter when a Phase-2 editor moves the two apart, and that is the point at which it should be measured rather than picked"* (`driftWindowSeconds`, [READ] ~1029-1040). | Display equals render, so what is drawn is what plays, leak included, and the readout reads the drawn line. C5a-1 also records the rendered depth of a 5.5 Hz ±40 c fixture widened to keep 2. The prediction is about 2.2 × [INFERRED, V3]. It is recorded, not gated, and it feeds follow-up C5a-F2. | T1 (recorded leg) |
| 17 | The handoff is refused on an irregular wobble, and the user does not know why. | The refusal sentence names the two-step route instead (6.2 step 5). | T15, T16 |

---

## 15. Tests and planted defects

**Standing rules** (the 09-24 doc §6's, restated because every item inherits them):
- Run `./scripts/test.sh`, never bare `swift test`.
- **Every planted defect is applied, shown red, and reverted**, and the red run is quoted
  in the close record. A test that has never been seen to fail has not been shown to
  test anything.
- Tests assert **physics**: what is rendered, drawn or stored, not a re-statement of the
  arithmetic under test.
- A looked-at gate uses `view.capture` on **staging (port 17695), never 17600**, the
  user's live app, plus a person-readable description of the frame.

| Id | Name and file | Claim | Planted defect that must turn it red |
|---|---|---|---|
| **T1** | `askedRateIsHeard`, `Tests/DAWEngineTests/NoteVibratoHandleRenderTests.swift` (new) | **The rendered f0 carries the asked rate, measured in the output.** A generator note is rendered through the shipping path (`StretchCurvePlan.make`, `OfflineStretcher.stretchTransposeCurve`, `curveLatencyCompensation`) at: ratio 1, stored 6.0 (heard 6.0); ratio 2, stored 6.0 (heard 3.0); ratio 0.5, stored 3.0 (heard 6.0). The output is tracked with `M23QToneTracker`, and a projection scan over **2–10 Hz** (not `rateIsDelivered`'s 4–12, which cannot see the ratio-2 leg's 3.0) must peak within 0.2 Hz of the **heard** rate. Control: the scan at 1.35 × the heard rate reads under half the peak (`rateIsDelivered`'s own control shape). **Recorded leg:** the non-sinusoidal residual at heard 7.8 via ratio 0.5 (stored 3.9) must match ratio 1's 7.8 Hz figure within 3 percentage points. That shows the ceiling is output-time (V5). If it does not, the item stops and the heard clamp is revisited. Also recorded: failure mode 16's widened-depth figure. | The generator is evaluated per **output** second (the ratio dropped from its time argument). At ratio 2 the scan then peaks at 6.0, not 3.0. |
| **T2** | `firstSidewaysTickIsIdentical`, `Tests/DAWAppKitTests/PitchWobbleGestureTests.swift` (new) | **The first ticks of a speed drag on a sung note change nothing.** Fixture: a 5.5 Hz ±40 c note, basis `.render`, sung reading `.wobble`. Speed travel of 1 to 15 pt (pure sideways): `draftPlayedLine == playedLine` (Equatable) at every tick, and ending the drag returns no commit. Also: 15 pt sideways with 30 pt vertical produces no handoff, so the generator fields still equal the stored ones. | Dead zone set to 0: the first sideways tick hands off, and the lines differ. |
| **T3** | `displayIsTheRenderForAWobbleNote`, in C-0's `Tests/DAWEngineTests/PitchEditorDisplayMatchesRenderTests.swift` | **Display equals render for a wobble-edited note.** Notes: D, a new wobble at heard 6.2 on ratio 1.25 (stored 7.75), ±40 c, anchor at the centre, both scales 0; E, your wobble widened to keep 1.6; F, flat. Check `model.playedLine.curve == StretchCurvePlan.make(…).curve`, the render's arguments mirrored exactly as C-0's test 1 does. Also: at the last tick of a wobble drag on D that ends at heard 7.0, `draftPlayedLine.curve` equals the curve built from the table the release actually stored. | (i) The draft writes the heard rate as stored (forgets × ratio) while the commit converts: red on ratio 1.25. (ii) The draft omits the anchor while the commit sets it. |
| **T4** | `speedDragStretchesAroundTheKnob`, `PitchWobbleGestureTests.swift` | **Speed changes stretch the wobble around the knob.** A new wobble on a note centred at 12.3 s. One speed step (0.1 per second) moves the rising zero crossing nearest the knob by less than 0.5 ms. | Anchor forced to 0. The phase at 12.3 s then moves by `2π × 12.3 × 0.1`, about 1.23 cycles, so the crossing moves by about 38 ms at 6 Hz. (The fixture time is chosen so the plant cannot land on a whole number of cycles.) |
| **T5** | `sungWobbleMeasurement`, `Tests/DAWCoreTests/PitchWobbleEstimateTests.swift` (new) | Every bound and negative control in 8.5(a). | (i) The quadratic detrend removed: the drift and scoop fixtures miss the 7 c depth bound. (ii) The floor removed: the flat line reads `.wobble`. (iii) The least-squares fit replaced by the one-bin projection: the 0.6 s notes miss the depth bound (partial-cycle bias, V7). |
| **T6** | `realDetectorReadsTheWobble`, `Tests/DAWEngineTests/PitchWobbleDetectorTests.swift` (new, env-gated) | 8.5(b): rate within 0.2 Hz; depth within [0.75, 1.05] of the truth; the anchor's rising crossing within 5 ms of the truth. | Timestamps at the frame **start** instead of the centre: the anchor lands about 8.6 ms off (the detector's measured lead, [READ] curve `make`'s doc). |
| **T7** | `flatIsFlat`, `PitchWobbleGestureTests.swift`, plus an env-gated physics leg | **Pulling a note fully down makes it flat.** Stored `vibratoScale == 0` **and** `driftScale == 0`. The played line inside the note, away from the gate ramps, has a peak-to-peak of at most 1 c. Physics leg (recorded, not gated): within-note wander through the render is cut by at least Hard Tune's 48 % (V3). | Write `vibratoScale 0` alone (the banner's old mapping). About 21 % of the ±40 c wobble stays in the drawn line, a peak-to-peak of about 17 c. |
| **T8** | `splitKeepsTheWobbleGoing`, `Tests/DAWCoreTests/PitchNoteVibratoTests.swift` (new) | Parent note: [1.0, 3.0], a new wobble at heard 5.5, ±40 c, onset 0.25 s, anchor at the centre. **Cut at 2.0:** the curve at 1000 probe points outside the cut's ramp equals the unsplit curve to 1e-12, and the stored right-half onset is 0. **Cut at 1.1:** the difference is bounded by `depth × smoothstep(0.1 / 0.25)`, and the stored onset is 0.15. | The onset is copied verbatim (today's behaviour): the right half dips to 0 at the cut, about 40 c off. |
| **T9** | `setterClampsAndSaysSo`, `PitchNoteVibratoTests.swift` | Each input, with the stored result and the limit it reports: rate 12 at ratio 1 → 8, `.rateRange`; rate 7 at ratio 0.8 → 6.4, `.heardRateCeiling`; depth 500 → 200; keep −1 → 0; anchor 10⁹ → 86 400. NaN is refused with a teaching error. An empty edit is refused. A no-op leaves the undo journal's count unchanged. | A direct field write without the clamp: 12 is stored (the `setNotePitchClamps` lesson). |
| **T10** | `oneCommitPerWobbleGesture`, `PitchWobbleGestureTests.swift` | 50 ticks produce zero commits, then exactly one at the end, or none for a no-op. This is the `aDragTickNeverCommits` pattern. Also: a `fromNothing` gesture that goes up and returns to depth 0 commits **nothing**, although its draft parked a rate, an anchor and an onset (5.4). | (i) Emit a commit from the update function. (ii) Decide the no-op by field equality alone: the up-and-back gesture then commits an inaudible, "edited-looking" note. |
| **T11** | `layoutIsOneConstant`, `PitchWobbleGestureTests.swift` | For each of the three layouts, pure `+dx` travel changes exactly the expected quantity (4.3's table). Each layout's help names its own directions. The ⌘ sentence appears only when the Shape tool exists. | The model reads `translation.width` directly, bypassing `PitchWobbleGesture.travel`: the `sidewaysIsWidth` leg goes red. (A site test that `translation` is read only in `PitchWobbleGesture.swift` is secondary; the behaviour test is the gate.) |
| **T12** | `anchorZeroIsTodayBitForBit`, extending `NoteVibratoGeneratorTests` §A, plus `digestSeesTheAnchor` in `PitchCurveRenderTests` | The §A render and digest goldens are unchanged with the field present at 0. `legacyPayloadRoundTripsWithoutNewKeys` is unchanged. The census covers the label. The mutation test from 7.4 passes. | (i) The anchor is hashed inside the generator block, unconditionally: the §A digest goldens go red. (ii) The default anchor is the note's start instead of 0: the render goldens go red. |
| **T13** | `undoIsOneStepAndResetIsItsOwn`, `PitchNoteVibratoTests.swift` | Two gesture commits on the same note within 800 ms make one undo entry. Commits on different notes make two. A commit then a reset within 800 ms make two. | The reset uses the `.vibrato` key: it merges into the drag before it. |
| **T14** | `handoffMatchesWhatWasOnScreen`, `PitchWobbleGestureTests.swift` | Fixture: a jitter-free 5.5 Hz ±40 c sung wobble, whose note centre is chosen so that an anchor-0 sine would be in **opposite** phase there. Crossing the dead zone must give pre- and post-handoff readings that agree: rate within 0.2 Hz, width within 10 c, anchor within 5 ms. The RMS difference between the two drawn lines inside the note is at most 10 c. | Anchor forced to 0: the anchors differ by about half a period (91 ms), and the RMS difference is about 56 c. |
| **T15** | `gatedWhileEstimating`, `PitchWobbleGestureTests.swift` | With basis `.estimate`: a press on your wobble is refused with the caption; a new-wobble note with both scales at 1 is allowed; one with scales at 0 is refused. An `.unmeasurable` wobble refuses the handoff with the 6.2 step-5 sentence. | The gate removed: the own-branch press starts a drag. |
| **T16** | `readoutNeverOverclaims`, `PitchWobbleGestureTests.swift` | Your wobble at keep 2 on the 5.5 Hz ±40 c fixture prints exactly the estimator's reading of the draft line, rounded to 5. **v1, until 2026-09-27:** that reading had to differ from `k × D` = 80 — expect about 90, since 2.215 × 40 = 88.6 (the assertion was the equality and the inequality, not the literal 90, which sat close to a rounding boundary). **v2 since 2026-09-27 (W7-C3, natural tuning §3b):** an unequal-scale note takes the triangular kernel (L 0.16 s), whose response at 5.5 Hz is H ≈ +0.001, so keep 2 now reads ≈ 2.00 × D ≈ 80 = `k × D` — AT 5.5 Hz THE TWO NO LONGER TELL APART. The test was re-derived (not just re-numbered; READ, `PitchWobbleGestureTests.swift`'s own doc, lines 942-972, W7-C3, 2026-09-27) to assert against the separator's own prediction and to catch the `k × D` plant at 4 Hz instead, where the v2 kernel still acts (H ≈ 0.13): keep 2 reads ≈ 74.6 c → "75", the plant prints "80". See `docs/ROADMAP.md` "W7-C3: drift/wobble separator v2 DONE". A new wobble on a ratio-1.25 clip prints the heard 6.2, not the stored 7.75. `.noWobble` prints no cents number. No readout prints a percentage or "0 cents". Heard above 8 after a ratio change prints the red sentence. | (i) Width computed as `k × D`: it prints 80. (ii) The stored rate printed: 7.8. |
| **T17** | `Tests/DAWControlTests/PitchNoteVibratoCommandTests.swift` (new), plus `mcp-server/test/pitch-correction.test.ts` | An unknown key is refused. `reset` alone works; `reset` with a field is refused. A clamp is echoed with `clamped` and a `note`. `heardRateHz` equals stored ÷ ratio. `clip.getPitchEdits` has the anchor and `heardVibratoRateHz` on every segment. `clip.getPlayedPitch`'s wobble readings equal `PitchWobbleEstimate` run on the same inputs in process. | (i) An unknown key is accepted. (ii) `clamped` is omitted on a clamp. (iii) `clip.getPitchEdits` echoes the stored rate as heard on a ratio-2 clip. (iv) Depth sent alone on a note whose rate is 0 returns no `note`: the silent success goes unreported. |
| **T18** | Looked-at gate (C5a-4), staging only | Three captures, each described in words: a sung note hovered in the Wobble tool (knob and "Your wobble: about …"); a new wobble mid-drag (knob, the draft line, the readout); a note pulled flat ("smoothed flat", a straight line inside the blob). | none; a person looks. |
| **T19** | `wideningLeavesTheSlidesAlone`, `PitchWobbleGestureTests.swift` | Keep 1 → 1.5: drift stays 1. Keep 1 → 0.5: drift 0.5. Starting from a preset's 0.3/0.3 and widening to 0.8: drift stays 0.3. | Drift coupled in both directions: the widening leg goes red. |

---

## 16. Implementation plan

The standing rules are in section 15. In addition:
- Every capability ships with its store function, wire verb, MCP tool and tests. Wire and
  MCP changes are additive only.
- After C5a-3, re-run the wire and MCP count pins: `node scripts/gates/doc-count-drift.mjs`.
  Each count moves by exactly one: `clip.setNoteVibrato` and `clip_set_note_vibrato`.
- Tick `docs/ROADMAP.md` when an item lands.

**Order.**

```
C5a-0 (estimator) ─────────────┬──────────────────────────────┐
C5a-1 (anchor, render legs) ─── C5a-2 (store) ─┬─ C5a-3 (wire, MCP; also needs C-0c)
                                               └─ C5a-4 (UI; also needs C-0b and C-F3)
C5a-L (listening; independent, can run now)
```

**Shared shapes: build each once.** C5a-4, C2-5 and C5b-4 all need two things. Whichever
of the three lands first builds them, and the others extend them.
- The gesture router (4.2).
- The **generalised draft**: `PitchEditorDraftEdit`, with cases `.pitch(offsetCents:)`
  and `.wobble(NoteVibratoEdit)`, and later `.timing(…)` for C2-5. It has one
  `apply(to: inout NoteSegment)` function, which `rebuildDraftLine` calls instead of
  setting `pitchOffsetCents` directly (V4).
  - C-0b is being built right now. Rebase onto whatever `rebuildDraftLine` it lands.
  - Never add a second draft path.

### C5a-0. The wobble estimator
- **Depends on:** nothing.
- **Route:** audio-dsp-engineer.
- **What:**
  - `PitchWobbleEstimate` (8.2);
  - the floor's single home (8.3);
  - validation (8.5a), plus 8.5b and 8.5c env-gated.
- **Files:**
  - `Sources/DAWCore/PitchWobbleEstimate.swift` (new);
  - `Sources/DAWCore/PitchCorrection.swift`, for `PitchCorrectionMath.detectorResolutionFloorCents` only;
  - `Sources/DAWAppKit/PitchEditorModel.swift`, one line: the readout floor aliases the
    new constant;
  - `Tests/DAWCoreTests/PitchWobbleEstimateTests.swift` (new, T5);
  - `Tests/DAWEngineTests/PitchWobbleDetectorTests.swift` (new, env-gated, T6 and 8.5c).
- **Planted, red:** T5 (i) to (iii); T6's frame-start plant.
- **Stop condition:** if 8.5(a) misses its bounds, report. Do not loosen a threshold.
- ⛔ **STOPPED 2026-09-24** under this condition. It continues as **C5a-0b** (§18.4).

### C5a-1. The phase anchor, and the render's heard-rate legs
- **Depends on:** nothing hard. Merge order against C2-1 and C5b-1 is soft, because the
  digest blocks are marker-gated and their order is fixed as generator, anchor, warp,
  shape (7.5).
- **Route:** audio-dsp-engineer.
- **What:**
  - the field, its range, `init`, Codable, `isEdited`, `Span` and `generatedVibrato`
    (7.1–7.4);
  - the anchor paragraph added to the curve banner;
  - the digest block (7.5);
  - T1's three ratios, and its two recorded legs (the output-time ceiling; the widened
    depth of failure mode 16);
  - if C2-1 has landed, the anchor in the edited-time branch (7.6).
- **Files:**
  - `Sources/DAWCore/PitchCorrection.swift`;
  - `Sources/DAWEngine/Stretch/StretchCurvePlan.swift`;
  - `Tests/DAWEngineTests/NoteVibratoGeneratorTests.swift` (§A extensions: T12, and the
    identity, sanitise and legacy pins);
  - `Tests/DAWEngineTests/PitchCurveRenderTests.swift` (the census, `digestSeesTheAnchor`);
  - `Tests/DAWEngineTests/NoteVibratoHandleRenderTests.swift` (new, T1);
  - **`docs/ARCHITECTURE.md`, "Key future decisions".** Record the settled decision: a
    per-note wobble is a keep lever plus an additive generator with a stored phase
    anchor; heard rate is stored ÷ ratio; flat is both scales at 0. This design pass was
    confined to its own file, so the implementing item carries it (the 09-24 doc did the
    same).
- **Planted, red:** T1's per-output-second generator; T12 (i) and (ii).

### C5a-2. The store setter, reset, and the split
- **Depends on:** C5a-1.
- **Route:** swift-app-engineer.
- **What:**
  - `NoteVibratoEdit`, `NoteVibratoLimits.clamp`, `setClipNoteVibrato` and
    `resetClipNoteVibrato` (section 10);
  - the split's onset re-derivation (11.1);
  - the two doc-comment corrections (section 10, item 9).
- **Files:**
  - `Sources/DAWCore/NoteVibratoLimits.swift` (new; holds `NoteVibratoEdit`,
    `NoteVibratoLimit` and the clamp);
  - `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`;
  - `Sources/DAWCore/PitchCorrection.swift` (comments only);
  - `Tests/DAWCoreTests/PitchNoteVibratoTests.swift` (new: T8, T9, T13);
  - `Tests/DAWCoreTests/PitchCorrectionWriterTests.swift` (widen `changeable` **in the
    same change**).
- **Planted, red:** T8's verbatim onset; T9's unclamped write; T13's reset under the
  `.vibrato` key.

### C5a-3. The wire and MCP
- **Depends on:** C5a-2, C5a-0, and C-0c (`clip.getPlayedPitch` must exist to be
  extended).
- **Route:** mcp-integration-engineer.
- **What:**
  - `clip.setNoteVibrato` (12.1);
  - `clip.getPitchEdits`' two new keys and the `stretchRatio:` parameter (12.2);
  - `clip.getPlayedPitch`'s wobble readings (12.3);
  - `clip_set_note_vibrato`, and the two updated descriptions (12.4).
- **Files:**
  - `Sources/DAWControl/Commands.swift`;
  - `mcp-server/src/server.ts`;
  - `Tests/DAWControlTests/PitchNoteVibratoCommandTests.swift` (new, T17);
  - `mcp-server/test/pitch-correction.test.ts`.
- **Planted, red:** T17 (i) to (iii).

### C5a-4. The Wobble tool
> ⚠ Amended by §18.4: it also depends on C5a-0b, and it adds Defects 1–3, the calibrated seed, and T20–T23.
- **Depends on:** C-0b (the played and draft lines), C5a-0, C5a-2, and C-F3. C-F3 is the
  warning before a preset replaces hand edits; one menu click must not erase a user's
  wobbles (V14). This is the same gate as C2-5.
- **Route:** ui-design-engineer.
- **What:**
  - the Wobble slot;
  - the router and the generalised draft, if not already built;
  - `PitchWobbleGesture`: the layout, `travel`, knobs, help, `classify`, gains,
    quantisation, dead zone and handoff (sections 4 to 6);
  - the knob and the readout, drawn (section 9);
  - the commit kind `.noteVibrato`, and staging's independent read-back (section 10);
  - "Back to how you sang it" in the note's context menu;
  - the basis-gate captions (5.5);
  - the `debug.pitchEditor` wobble block (12.5).
- **Files:**
  - `Sources/DAWAppKit/PitchWobbleGesture.swift` (new);
  - `Sources/DAWAppKit/PitchEditorModel.swift`;
  - `Sources/DAWApp/PitchEditor/PitchEditorView.swift`;
  - `Sources/DAWApp/PitchCorrectionStaging.swift`;
  - `Sources/DAWApp/PitchEditorDebugStaging.swift`;
  - `Tests/DAWAppKitTests/PitchWobbleGestureTests.swift` (new: T2, T4, T7's display leg,
    T10, T11, T14, T15, T16, T19);
  - T3, in C-0's `Tests/DAWEngineTests/PitchEditorDisplayMatchesRenderTests.swift`.
- **Planted, red:** T2, T3 (i) and (ii), T4, T7, T10, T11, T14, T15, T16 (i) and (ii),
  T19.
- **Looked-at gate:** T18, on staging.

### C5a-L. Listening: how quickly should a new wobble build up?
- **Depends on:** nothing new. The generator and its onset already render. Use the real
  dry vocal from E2.
- **Route:** audio-dsp-engineer renders; the orchestrator publishes the page.
- **What:**
  - Four renders of one held note, its own wobble replaced by a new one at 5.5 per second
    and ±40 c, with onsets of 0, 0.15, 0.3 and 0.6 s. That is **one axis**, and the
    user's pick is the feedback.
  - A novice-readable page.
  - **True peak at or below −1 dBTP, checked alongside loudness.** A loudness meter does
    not look up.
- **Automated guard:** in each render's f0, the wobble reaches 90 % of its final depth at
  the asked onset, within one hop.
- **Planted, red:** render all four at onset 0. Identical results prove the axis did
  nothing.
- **Result:** replaces the provisional onset in 9.5.

### Follow-ups named by this plan and not scheduled

| Id | What | Why it waits |
|---|---|---|
| **C5a-F1** | A lopsided wobble: tops pulled up, bottoms left alone | The generator is a symmetric sine. C5b draws it regionally today. |
| **C5a-F2** | Smooth the wobble but keep the slides into and out of the note | Needs a drift/vibrato separator that does not leak (V3): a `shapingVersion` bump, its own measurement, and a listening pick. |
| **C5a-F3** | Re-rate the singer's own wobble instead of replacing it | Section 6.3, Alternative 2. Only if listening shows new wobbles sound mechanical. |
| **C5a-F4** | A wobble knob on the note in the Move tool (the top-centre dot) | Only if the user's answer to the already-asked dot question says that is what it is. The gesture code is door-agnostic. |
| **C5a-F5** | Onset on the handle, or as a context-menu choice | After C5a-L sets a default. |

---

## 17. What needs the user's word

**Already asked on the handoff page. Do not ask again.**
- **The drag axis.** The recommended answer is sideways for speed, up and down for width;
  the alternatives are the other way round, or two separate handles. The plan builds
  `sidewaysIsSpeed`. Any of the three answers is a one-line change to
  `PitchWobbleGesture.layout`, the help text follows automatically, and T11 pins that.
- **What the top-centre dot in the reference frames does** (09-24 doc §7). If it is the
  wobble control, C5a-F4 adds it as a second door. Nothing else changes.

**One new question, with the default the plan builds unless told otherwise:**

1. **"When you drag sideways on a note that has your own natural wobble, the app swaps
   your wobble for one it makes, starting at the same speed and width, so you can make it
   faster or slower. Undo, or 'Back to how you sang it', brings yours back. Is that swap
   OK?"**
   - *Recommended default:* yes. It answers "add more cycles" in one drag.
   - *If no:* sideways does nothing on your own wobble until you have smoothed the note
     flat, and a drawn hint says so (section 6.3, Alternative 3). The change is confined
     to `PitchWobbleGesture`.
   - *Why ask:* this is the one place C5a replaces the singer's own sound rather than
     scaling it, and the user can judge that better than code can.

**Said, not asked:** pulling a note flat also straightens the slide into and out of it
(5.3). If that is not wanted, the route is C5a-F2. It is not offered as a choice now,
because the alternative cannot be built cleanly today.

**Asked as a listening pick, not a question:** how quickly a new wobble builds up (C5a-L:
four versions of one held note).

---

## 18. Addendum 2026-09-24: re-picked against the product detector

Written by the orchestrator, one decision at a time. Four architect runs on this addendum
died to an upstream API timeout on their first post-read reasoning turn. Where a section
below supersedes an earlier one, the old spot carries a one-line pointer here. Labels:
**[READ]** file:line, **[MEASURED]** log + line, **[INFERRED]**.

### 18.0 What changed

C5a-0 built the estimator (`Sources/DAWCore/PitchWobbleEstimate.swift`) and then STOPPED
under §8.5's own rule: four §8.5(a) bounds missed, and none was loosened. The logs are in
`scratchpad/wobble/final-t5-try1.log` (T5, the model) and `final-t6-try1.log` (T6, the
product detector). The misses trace to one wrong premise: **§8.5(a) modelled the detector
as a 256-bin argmax lattice, and the product is not one.**
- [MEASURED] T6:19-20: a ±8 c wobble at A3 comes out at 0.3–0.8 c (117 of 125 frames at
  0.5 c), which sits −5.0 to −5.5 c from every modelled bin centre. It is neither the
  wobble nor a lattice level. The detector ERASES small modulation. It does not quantise it.
- [MEASURED] T6:27-41, the ±8 c sweep over 14 base offsets:
  - at 11 of 14 the wobble fits UNDER the 12.9 c floor (0.01–11.7 c);
  - at the other 3 (A3+14/+16/+18 c) it reads as a 13.8–15.7 c wobble (18.1.4).
- [MEASURED] T6 depth transfer (5.5 Hz, 1.0 s): true ±20 c → 5.2–6.4 c read; ±25 → 12.1–17.9;
  ±30 → 18.1–26.3; ±40 → 33.7–36.9. **The product is blind below about ±20 c and
  under-reads up to about ±35 c.** Every ±20 c cell of the steady grid reads `.noWobble`
  (36 of 36, T6:44-80). The transfer is T6:89-91.
- [MEASURED] T6:94 onward, the user's real take: 42 notes → 6 `.wobble`, 1 `.noWobble`, 24
  `.tooFewSamples`, 8 `.tooShort`, 3 `.tooUneven`. Most notes last 0.1–0.4 s. **On this
  singer the common case is a note the tool cannot measure** (§18.3).

### 18.1 Validation, re-picked (supersedes §8.5(a)–(b))

#### 18.1.1 Two suites, two jobs

- **T5 tests the estimator's ARITHMETIC, not the detector.** Its fixtures DROP the lattice,
  because the lattice is not the product (18.0). They use exact sines on a quadratic trend,
  plus seeded Gaussian noise at σ = 3 c per frame. σ = 3 c is a pick [INFERRED]: voice-like
  jitter, and well above the detector's steady spread (T6:19). The bounds come from the
  fit's own information limit, computed IN THE TEST from each cell's N, span T, depth A and
  σ. The Cramér–Rao floors are σ_A = σ·√(2/N) and σ_f = √12·σ / (2π·A·T·√N).
  > ⚠ **CORRECTED by C5a-0b (2026-09-24), checked by the orchestrator:** for a REAL sinusoid the
  > SNR is A²/(2σ²), so the rate floor is **σ_f = √24·σ / (2π·A·T·√N)**. That is the only form
  > consistent with σ_A = σ·√(2/N) above. The printed √12 is √2 too tight: the estimator measured
  > 0.93–1.11 × the √24 floor, and 35 of 36 cells failed the √12 form. The 2.5 × factor is kept.
  - rate: p95 ≤ 2.5 × σ_f per cell. The factor absorbs the three trend nuisance parameters
    and the grid + parabola refinement [INFERRED].
  - depth: |error| ≤ 3·σ_A + 1 c.
  - anchor: ≤ 5 ms on cells ≥ 1.0 s, ≤ 8 ms at 0.6 s.
  - Each bound must still turn red under a named plant: a +0.1 Hz bias on the refined rate;
    the amplitude scaled by 0.9 (it trips on the ±80 c cells); the anchor moved by a quarter
    period.
- **T6 tests the PRODUCT CHAIN** (the real detector, then the estimator). Its bounds are
  ratios and bands MEASURED from the product. **Anything a person is ever shown must
  respect T6, never T5** (18.1.2).

**This resolves the depth-bound contradiction.** §8.5(a)'s absolute 7 c and §8.5(b)'s
[0.75, 1.05] share were two bounds on two different layers, and both were written against
the lattice. T5's absolute bound now measures the estimator alone. T6's ratio measures what
the product can see. Neither is the other's looser twin.

#### 18.1.2 T6 bounds on the product chain (mid pitch)

The measured product values [MEASURED] T6:81-86 are for true depth ±40 / ±80 c, 12 cells
each, at A3, B3 and E4. The bounds are picks with headroom, each with the plant that must
still turn it red.

| Quantity | Measured | Bound | Plant that must still turn it red |
|---|---|---|---|
| rate p95, 0.6 s | 0.0483 / 0.0455 Hz | ≤ 0.07 Hz | +0.1 Hz bias on the refined rate |
| rate p95, ≥ 1.0 s | 0.0039–0.0201 Hz | ≤ 0.03 Hz | the same |
| depth read ÷ true | 0.75–0.99 (±40), 0.77–0.98 (±80) | [0.70, 1.02] | amplitude × 0.85, and × 1.10 |
| anchor p95 | 3.10–4.79 ms | ≤ 6 ms | anchor moved by a quarter period |

- **The ±20 c blind band is PINNED as a tripwire, not a quality bar.** Every ±20 c cell must
  read `.noWobble` (36 of 36 today, T6:44-80). If that ever turns red, the detector has
  changed, and §18.3's words and the report floor (18.1.4) must be re-derived before
  anything ships. Plant: feed the true contour past the detector, and ±20 c reads `.wobble`.
- **The detector is deterministic on fixed fixtures.** These values do not wander run to
  run, so a bound this close to a measurement flags a real change, not noise.
- ⛔ **All of T6 is MID PITCH (220–330 Hz). This singer lives at 72–145 Hz, median 106 Hz**
  (MIDI 37.8–49.8 over all 42 notes, [MEASURED] T6:95-136). This table does NOT cover their
  voice. See 18.1.6 before quoting any of it to them.

#### 18.1.3 Short notes: the two refusals keep their order

- **Kept as built** [READ] `PitchWobbleEstimate.swift:107-117`, `:273-279`, `:383-392`:
  - `.tooFewSamples` = fewer than 24 voiced frames HANDED IN, counted BEFORE the trims.
    That is a note shorter than 0.384 s.
  - Then: floor, scan edge, `.tooShort` (fewer than 2.0 cycles across the kept span), fit.
  - Counting after the trims would make `.tooShort` unreachable at 5.5 Hz. 24 kept frames
    already span 2.02 cycles; the source comment at :111-116 says so.
- **§8.5(a)'s "a 0.35 s note reads `.tooShort`" cannot hold, and is replaced.** 0.35 s is
  21–22 frames, so it reads `.tooFewSamples`. The two controls become:
  - 0.35 s at 5.5 Hz → `.tooFewSamples`;
  - 0.40 s at 5.5 Hz (25 frames; 2 trimmed at each end leaves 21, spanning 1.76 cycles) →
    `.tooShort`.
  - T5 already carries a passing test that both refusals can fire ([MEASURED] T5:32). It
    must use exactly these two durations, so that the doc and the test name one fixture.
- **Two cycles stays the minimum for a READING.** On the real take, 8 notes of 0.40–0.61 s
  are `.tooShort` although they plainly move (T6: notes 15, 17, 26 and 29 fit 35.7–67.0 c at
  4.8–5.9 Hz). A rate from 1.5 cycles is too uncertain to print (σ_f grows as 1/T) and too
  uncertain to seed a handoff (§6.2). Those notes are still fully editable through the
  branches that need no reading (§18.3). **The refusal limits the READOUT, never the tool.**

#### 18.1.4 A separate, higher floor for calling something a wobble (supersedes §8.5(a)'s ±8 c control)

**The finding.** At 3 of 14 base offsets, a true ±8 c wobble comes out of the product as a
two-level square wave, and reads `.wobble` at 13.8–15.7 c ([MEASURED] T6:34-36, 41). That
is ABOVE the 12.9 c resolution floor, so the reading cannot tell a real, compressed
±25 c wobble (read 12.1–17.9 c, T6:89-91) from an artefact of a ±8 c one.

**Why it matters more than a wrong number.** §5.1 step 4 sends every `.wobble` into the
"your wobble" branch, and the keep lever renders (k − 1) × the DETECTED wobble [READ] §5.2.
If what was detected is an artefact, any k ≠ 1 writes the artefact into the audio. Pulling
such a note flat would ADD a ±15 c stepped warble to a voice that only moved ±8 c
[INFERRED from the render rule; not yet heard]. 18.5 covers the same mechanism under the
presets.

**Decision.** A new constant, `PitchWobbleEstimate.reportFloorCents = 20.0`. A READ depth
below it is `.noWobble`, and §5.1 step 3 then sends the note to "a new wobble", which adds a
clean sine and leaves the singer's own line unscaled.
- `detectorResolutionFloorCents = 12.90` keeps its one job (§8.3): what the detector can
  resolve, used by the readouts. The two constants answer different questions, so they are
  not a second home for one fact.
- **Evidence the floor costs nothing on this singer:** all 6 of the real take's `.wobble`
  notes read ≥ 22.0 c (T6 notes 7, 8, 13, 18, 41 and 42: 22.0–85.4 c).
- **The price, stated:**
  - a true ±25 c wobble at mid pitch reads as "no wobble the app can measure";
  - at LOW pitch a much deeper wobble may too (18.1.6).
  - That is honest: the product cannot tell those from the artefact.
- **T6 pins the band.**
  - The ±8 c sweep: at most 3 of 14 offsets fit ≥ 12.9 c, and none fits ≥ 20 c. Under the
    new floor all 14 read `.noWobble`.
  - Positive control: a true ±30 c wobble at A3 and B3 (read 26.3 / 25.5 c) still reads
    `.wobble`.
  - Plant: `reportFloorCents` lowered back to 12.9, and the sweep turns red at A3+14/+16/+18.

#### 18.1.5 The 3.0 Hz scan edge stays

[MEASURED] on the real take:
- notes 6 and 19 have their best rate AT the edge: 84.8 c and 28.0 c at 3.00 Hz, which
  reads `.tooUneven` (step `scanEdge`);
- notes 21, 28 and 33 sit just inside it: 133.5 / 176.3 / 84.3 c at 3.07–3.18 Hz, which
  reads `.tooShort`.

These are large, slow movements: slides and bends into and out of a note, not a wobble.
Sung vibrato sits at about 4.5–7.5 Hz, and the take's six real wobbles read 4.3–7.6 Hz.
§5.3's drift half (`driftScale`) is the lever for a bend. The wobble lever is not.

- **Decision:** keep 3.0–9.0 Hz. Lowering the edge would turn slides into "wobbles" with
  1–2 cycles of evidence.
- **Control:** a 2.5 Hz ±80 c sine over 1.0 s reads `.tooUneven` via the edge rule.
- **Plant:** widen the scan to 2.0 Hz, and the control reads `.wobble`.
- The readout words for these notes are in 18.3.

#### 18.1.6 Low pitch: the product's response collapses below about 110 Hz

[MEASURED] `scratchpad/wobble-onset/instrument/instrument.json`, rows 1–12. The C5a-L agent
ran synthetic tones carrying the same wobble through BOTH the product detector (SwiftF0) and
an independent tracker. The tracker read about 35 c on every row (34.5–35.3; residuals
0.08–0.48 c). SwiftF0's reading as a share of the tracker's:

| Pitch | 8 partials 1/k | voice-like, weak fundamental | pure sine |
|---|---|---|---|
| 83.2 Hz | 0.48 | 0.61 | 0.16 |
| 110.6 Hz | 0.76 | 0.89 | no SwiftF0 fit |
| 146.8 Hz | 0.92 | 0.97 | no SwiftF0 fit |
| 220.0 Hz | 1.03 | 0.97 | no SwiftF0 fit |

**This singer's median note is 106 Hz** (18.1.2), squarely where the product reads a half to
nine-tenths of a real wobble, and less on a thin or breathy tone. The consequences follow from
the render rule [INFERRED from §5.2, not yet heard]:
- **Readings:** the depth is low by up to half. A real ±35 c wobble at 83 Hz reads
  5.5–20.9 c, which is `.noWobble` under the 20 c report floor (18.1.4).
- **Flatten:** it removes only what the detector sees, so more of the sung movement stays.
  The C5a-L agent measured 22.8 c RMS left after flattening its 83 Hz note
  (`measurements.json:330`).

**Decision.**
- **T6 grows a LOW-PITCH block before anything prints a width for a low note:**
  - pitches 82.4, 110.0 and 146.8 Hz;
  - both voice-like spectra;
  - ±40 / ±80 c, at 1.0 and 2.0 s;
  - plus the ±8 c sweep at 110 Hz, to find out whether the square-wave artefact of 18.1.4
    exists down there.
  - It is bounded exactly as in 18.1.2 (measured, headroom, plant).
- **Until that block is measured and bounded, the readout prints NO width number for a note
  whose median pitch is below 150 Hz.** Words only (18.3). The handoff seeds depth only
  where a block exists (18.2).
- The report floor stays 20 c everywhere. It exists for the artefact, not for the depth
  response. If the low block shows no artefact band, lowering it there becomes a
  measured option, never a default.

#### 18.1.7 Retiring the known issues, and the one-home floor

**All three `withKnownIssue` blocks test the LATTICE fixtures**
([READ] `Tests/DAWCoreTests/PitchWobbleEstimateTests.swift`):
- ~:391-399, the jitter-free rate p95 ≤ 0.05 Hz;
- ~:421-427, depth ≤ 7 c;
- ~:507-515, ±8 c at B3.

The "REGRESSION PIN — the measurement … NOT a validation bound" lines after each block pin
lattice measurements too.

**C5a-0b deletes them together with the lattice, in this order, never out of it:**
1. Write the new bounds as plain `#expect`s: T5's noise-model bounds (18.1.1), T6's
   mid-pitch table and its two pins (18.1.2, 18.1.4), the scan-edge control (18.1.5), and the
   two short-note controls (18.1.3).
2. Show each one red under its named plant, in an ISOLATED COPY of the tree (gate-laws
   §2026-09-24a #6).
3. Only then delete the three blocks, the lattice fixtures and their regression pins.

**Gate after C5a-0b:** `withKnownIssue` occurs 0 times in that file. `grep -c` prints 0 and
exits 1, so the gate reads the printed count, not the exit code. It also runs the same grep on
a file known to contain one, as its positive control.

**The alias (§8.3's one home):** `Sources/DAWAppKit/PitchEditorModel.swift:93`,
`centsResolutionFloor: Double = 12.90`, becomes
`= PitchCorrectionMath.detectorResolutionFloorCents` (`PitchCorrection.swift:1781`).

**Named, not scheduled: C5a-F6.** §8.3's 12.90 c is half of the LATTICE's bin, and 18.0
shows the product is not a lattice. The detector's static bias measures 0.5–5.4 c (T6:19-26,
the "detected levels" lines), so for a static readout the floor is safe but conservative.
What the readout floor should MEAN for the product gets re-derived from product data, not
from the lattice.

### 18.2 Depth at the handoff (amends §6.2 step 4's seed)

**The problem.** §6.2 seeds the new wobble at the MEASURED rate, depth and phase so that the
first tick past the dead zone sounds unchanged. Rate and phase hold: rate error ≤ 0.05 Hz and
anchor ≤ 5 ms at ±40 c (T6:81-86). Depth does not. The product reads 0.75–0.99 of a real
wobble at mid pitch, median 0.85 (T6:81-86), and 0.48–0.89 at 83–110 Hz (18.1.6). A seed at the
read depth therefore NARROWS the wobble on the first tick, by about 15 % at mid pitch and by up
to half on this singer's lowest notes. That is the jump §6 exists to prevent [INFERRED: not yet
heard, hence C5a-L2].

**Decision: seed at the CALIBRATED depth**, `readDepth ÷ response(pitch)`, where `response` is
the MEDIAN read/true share that T6 measured for the note's pitch block (18.1.2 mid, 18.1.6 low).
- **Why this is not the forbidden move.** The model banner forbids pre-compensating the
  GENERATOR, i.e. asking the renderer for more than the user asked, to hide a render loss. This
  is the opposite layer: it corrects the MEASUREMENT of what was sung, from a measured
  response. The generator still renders exactly the depth the model stores.
- **Where no response block covers the note's pitch, the handoff is REFUSED** with §6.3
  Alternative 3's hint ("smooth it flat first, then add a new wobble"). C5a-0b's low-pitch
  block (18.1.6) covers this singer, so for them this is a fallback, not the common path.
  > ⛔ **FALSE, measured by C5a-0b (§18.7):** the 82.4 Hz and 110 Hz blocks hit the stop condition,
  > and ALL SIX of this singer's real wobbles sit at 108.5–126.1 Hz. For them the refusal IS the
  > common path.
- **The readout never shows the calibrated number as a measurement** (18.3 prints words).

**C5a-L2, a listening pick, is the arbiter** (the user's pick IS the feedback):
- One axis: the seed depth. Four files on the user's own voice, all −22 LUFS, true peak
  ≤ −1 dBTP:
  - as sung (the reference, not an option);
  - the handoff at the read depth × 1.00;
  - × 1.15;
  - × 1.30.
- On two notes: note 41 (120 Hz, reads 85.4 c at 4.34 Hz, the deepest real wobble) and note 13
  (126 Hz, reads 41.5 c at 5.47 Hz).
- The question, in their words: **"Which one sounds most like the first file?"** A "they all
  sound the same" option is a real answer.
- If the pick is × 1.00, the calibration is dropped. If the pick lands near
  `1 ÷ response(pitch)`, it is confirmed.

### 18.3 A note the tool cannot measure: the COMMON case (amends §5.1, §5.2, §6.2 step 5, §9.2)

On this singer's take, 35 of 42 notes are `.unmeasurable`: 24 too few samples, 8 too short,
3 too uneven (18.0). The design treated that as an edge case. Three defects follow for it, and
each gets a fix.

**Defect 1: the handoff hint is FALSE on short notes.** §6.2 step 5 says "Drag down to smooth it
flat, then sideways to make a new one", and step 4 lets a FLAT draft hand off because it reads
`.noWobble`. But the estimator counts samples BEFORE it tests the floor (18.1.3), so a flat
0.2 s note still reads `.tooFewSamples`, and the handoff is refused forever: 24 of 42 notes.
- **Fix:** at the crossing tick, a draft with `vibratoScale == 0 && driftScale == 0` is FLAT BY
  CONSTRUCTION. Its played line is the target line, so `R` is taken as `.noWobble` whatever
  the sample count, and step 4 applies (both sides flat, so continuous).
- The rule reads the draft's scales, not the estimator. A flat note needs no measurement to
  be continuous with a new wobble that starts at depth 0.

**Defect 2: widening what isn't a wobble.** §5.1 step 4 sends every `.unmeasurable` note to "your
wobble", and §5.2 lets `k` reach 2. On a 0.1–0.4 s note, what the 250 ms separator calls
"vibrato" is mostly jitter, the fast edge of a scoop, and detector noise, including the artefact
of 18.1.4. Widening scales that into the audio [INFERRED from §5.2's render rule].
- **Fix:** widening (k > 1) is allowed only with evidence of real movement above the artefact
  band:
  - a `.wobble` reading; or
  - an `.unmeasurable` note whose estimator ran and fitted a depth ≥ `reportFloorCents`.
    That is the diagnostic the refusals already compute ([MEASURED] T6: note 15 fitted
    67.0 c).
- Otherwise `k ∈ [0, 1]`. Up stops at "as you sang it", and smoothing works everywhere.
- A `.tooFewSamples` note has no analysis, so it can only be smoothed.

**Defect 3: the words name the wrong reason.** §9.2 prints "too uneven to measure" for every
`.unmeasurable` note, but 32 of the 35 are too SHORT. The strings below replace §9.2's rows. They
are novice words, name no unit the product cannot back, and never blame the singer.

| State | Readout |
|---|---|
| Your wobble, `.tooFewSamples` or `.tooShort`, idle | `This note is too short to measure its wobble. Drag down to smooth it.` |
| Your wobble, `.tooUneven`, idle (includes the scan edge, 18.1.5) | `This note's pitch slides around rather than wobbling evenly. Drag down to smooth it.` |
| Dragging up, and widening is not allowed (Defect 2) | `As you sang it. This note is too short to make its wobble wider.` |
| Handoff refused, short note, not yet flat | `To change its speed, first drag down to smooth it flat, then drag sideways to add a new wobble.` |
| Handoff refused, uneven note, not yet flat | the same sentence as the row above |
| `.noWobble` (now below the 20 c REPORT floor, 18.1.4) | `No wobble the app can measure. Drag up to add one.` (the parenthetical becomes "a singer's wobble under the 20 c report floor is real and unmeasured") |
| Your wobble, `.wobble`, on a note whose pitch no T6 block covers (18.1.6) | the speed only: `Your wobble: about 5.5 per second` |

The refusal rows now state ONE action that works, and Defect 1's fix is what makes it work.

### 18.4 Items (amends §16)

**Order, amended:**

```
C5a-0 (built, STOPPED) ── C5a-0b (re-pick) ─┬───────────────────────────────┐
C5a-1 ── C5a-2 ─┬─ C5a-3 (also needs C-0c ✅ 2026-09-24)                      │
                └─ C5a-4 (also needs C-0b ✅, C-F3 ✅, and C5a-0b) ◄─────────┘
C5a-L ✅ (on the handoff page) · C5a-L2 (independent; can run now)
```

#### C5a-0b. The re-pick, against the product
- **Depends on:** C5a-0 (built and stopped; its code stays).
- **Route:** audio-dsp-engineer. It is implementation now, not design; every value is in
  18.1.
- **What:**
  - T5 rebuilt on unquantised fixtures with σ = 3 c noise, and Cramér–Rao-derived bounds
    (18.1.1);
  - T6's mid-pitch table and the ±20 c blind-band pin (18.1.2);
  - `PitchWobbleEstimate.reportFloorCents = 20.0` in the decision step, plus the ±8 c sweep
    pin (18.1.4);
  - the two short-note controls at 0.35 s and 0.40 s (18.1.3);
  - the scan-edge control (18.1.5);
  - **the LOW-PITCH block** at 82.4, 110.0 and 146.8 Hz, with the ±8 c sweep at 110 Hz
    (18.1.6);
  - `PitchWobbleEstimate.response(pitchHz:)`: the median read ÷ true share, per measured
    block, for the handoff (18.2). It returns `nil` outside every block;
  - retiring the three `withKnownIssue` blocks, in 18.1.7's order;
  - the `centsResolutionFloor` alias (18.1.7).
- **Files:**
  - `Sources/DAWCore/PitchWobbleEstimate.swift`;
  - `Sources/DAWAppKit/PitchEditorModel.swift` (one line);
  - `Tests/DAWCoreTests/PitchWobbleEstimateTests.swift` (T5);
  - `Tests/DAWEngineTests/PitchWobbleDetectorTests.swift` (T6, env-gated as now).
- **Planted, red:** every bound's named plant in 18.1.1–18.1.5, and `response` returning 1.0
  everywhere (the calibration test must go red). Run them in an ISOLATED COPY.
- **Gate:** 0 `withKnownIssue` left, positive-controlled (18.1.7).
- **Stop condition:** if a low-pitch block's read ÷ true share cannot be held inside a band
  no wider than [0.5, 1.1], stop and report. That pitch then gets no `response` (`nil`), and
  18.3's speed-only row applies there. No band is widened to make it pass.

#### C5a-4, amended (the Wobble tool)
- **Depends on, added:** C5a-0b (`reportFloorCents`, `response`, the low block).
- **What, added (18.2, 18.3):**
  - the flat-by-construction handoff rule (Defect 1);
  - the widening cap (Defect 2);
  - 18.3's strings, which replace §9.2's matching rows;
  - the calibrated seed, with the handoff refused where `response` is `nil`. Its
    multiplier waits on C5a-L2's pick.
- **Tests, added,** in `Tests/DAWAppKitTests/PitchWobbleGestureTests.swift`:
  - **T20:** a 0.2 s note at k = 0 and d = 0, dragged sideways past the dead zone, commits
    a new wobble at depth 0;
  - **T21:** on a `.tooFewSamples` note, dragging up keeps k at 1, and the readout is 18.3's
    "As you sang it" row;
  - **T22:** all of 18.3's strings, verbatim, by reading;
  - **T23:** the seed equals read ÷ `response(pitch)`, and the handoff is refused where
    `response` is `nil`.
- **Planted, red:**
  - T20 with the flat rule removed (the handoff is refused);
  - T21 with the cap removed (k reaches 2);
  - T23 with `response` fixed at 1.0.

#### C5a-L2. Listening: how deep should the handed-off wobble be?
- **Depends on:** nothing. The generator and flatten renders exist, as they did for C5a-L.
- **Route:** audio-dsp-engineer.
- **What:** the four files and two notes of 18.2, matched to −22 LUFS with true peak
  ≤ −1 dBTP, and each checked audible before publishing (the audibility rule), to
  `~/Downloads/daw-pro-wobble-handoff/`, then on the handoff page.

### 18.5 The same mechanism already ships, in the presets

**Only Hard Tune** drops the wobble: `preserveVibrato: false` ([READ]
`PitchCorrectionPresets.swift:88-91`), which is the preset that renders with the scales below 1
([READ] `Model.swift:651`). Gentle, Natural and Tight keep it (`preserveVibrato: true`,
`:79-87`), which matches the measured "Tight removes 1 % of the real vocal's wobble, Hard Tune
70 %" (⚠ **RETRACTED 2026-09-25:** measured note by note after note splitting, Hard Tune removes a
median 49 % by one pitch meter and 68 % by an independent one, every note kept on its own note; the
70 % came from before splitting and counted notes pulled onto the wrong pitch. The figures' one home is
`PitchCorrectionPresets.swift`'s doc). Under Hard Tune the render shifts every note's audio by minus its DETECTED deviation.
Two consequences follow from 18.1 [INFERRED from the render rule, not yet heard]:
- **Where the detector UNDER-reads** (low pitch, 18.1.6), flattening leaves part of the sung
  movement. That is benign: less correction than asked. [MEASURED] 22.8 c RMS was left after
  flattening the C5a-L 83 Hz note (`measurements.json:330`).
- **Where the detector INVENTS movement** (18.1.4's square wave, or any glitch), flattening
  writes the INVERSE of the invention into the audio: a stepped warble where the singer was
  steady. The editor would draw a flat line over it, because the line is the render's curve
  (C-0) and not the audio.

**Measured on the user's take, 2026-09-24** (the busy-line check, audio-dsp-engineer; files in
the session scratchpad `busyline/`). The product contour was compared with an exact YIN,
positive-controlled to 0.01 c, plus pYIN and a 48 kHz spectral check, with a planted +800 c glitch
and a planted octave error both caught.
- **No GLITCH region exists in this take** [MEASURED]. All 33 disagreement regions are YIN
  octave errors, caused by a 58.75 Hz background hum. After folding octaves, 94 % of frames agree
  within 50 c, and every large move (E0–E9) is real singing: its harmonics move with the line
  [LOOKED AT: overview + the 22.8 s zoom]. So the invented-movement case above does NOT occur here.
  What is left: 12 isolated frames 1.1–2.2 st off (note-end hooks), 3 octave-high frames, and 8
  pitched frames drawn as gaps. **C5a-F7 stays filed but has no evidence to design from yet.**
- ⛔ **The real Hard Tune risk on this take is SEGMENTATION, not detection.**
  `PitchAutoCorrect.voicedRuns` makes one note of each unbroken voiced run, by design
  (`PitchCorrection.swift:1605-1615`: "does NOT split a legato phrase"). Hard Tune then flattens
  the whole run to its snapped median (`:1721`, `shapeScale = 0`). A slide into a held note
  therefore becomes ONE note pinned near the middle of the slide. At 22.61–23.22 s a D#2→B2 slide
  is pinned to G#2: the start moves +4.97 st and the held tail −2.23 st on average (−3.09 st at
  its peak). 4 of 42 notes move more than 3 st, 11 more than 2 st, up to 5.06 st [computed from
  the render rule on the product's own frames]. **[MEASURED in two renders with an exact YIN:
  the handoff page's own `pitch-04-hard-tune.mp3` and the rebuilt bundle's `livelook-hardtune.wav`.]**
  The 23.05–23.2 s held tail, sung A#2+41 c, plays as G#2+9 c; the 16.8–17.0 s held note, sung ≈ D3 (all 12 frames: D3−5 c; product frames D3−1 c; it wobbles ±85 c. An earlier "C#3+13 c" was a tracker-mask artefact, p2-seg §11.4), plays as
  A#2−11 c. Counted as notes where most of the note plays ≥ 1 st away from what was sung: 0:07.6
  (61 %), 0:09.2 (85 %), 0:16.4 (81 %), 0:22.6 (100 %) and 0:31.4 (77 %). The formula over-predicts
  0:26.2 (5 % in the render: too few voiced frames in its scoop). Controls: the uncorrected render
  reproduces the sung pitches (alignment), and 2 of 3 least-shifted notes read the same in both
  (the third is 60 ms, unreadable). Gentle, Natural and Tight shift each run by ONE constant from
  its median, so they stay within ~50 c.
- **Nothing owns the fix.** m23-q §11.2 puts "segmentation into notes" in Phase 2, and F1 says the
  failure lives there, but the editor's build order (`2026-09-22-pitch-editor-ui.md` §7.3, §15) is
  all manual editing. Filed as **p2-seg** in that doc's §17. Until it lands, the manual route is
  to cut the note with C3's scissors (`clip.splitNote`, shipped) and drag each half.

### 18.6 What needs the user's word

**Nothing new as a question.** C5a-L2 (18.2) is a listening pick, and the user's pick is the
feedback. 18.3 and 18.4 are design corrections that follow from measurement. None changes
behaviour the user has already chosen.

### 18.7 C5a-0b's outcome (2026-09-24): the stop condition fired, twice

Built and green (audio-dsp-engineer). **Verified by the orchestrator:** 0 `withKnownIssue` in T5,
with the pre-edit copy printing 4 as the control; the response table as quoted below, read in
`Sources/DAWCore/PitchWobbleEstimate.swift:277-338`; key tests passing by display name.

- **The stop condition (18.4) fired at 82.4 Hz and at 110 Hz.** 82.4 Hz reads 0.303–0.827 of a
  true wobble. 110 Hz reads 0.472–0.976, and its share FALLS as the wobble gets faster (0.775 at
  4.5 Hz, 0.472 at 7.5 Hz). Both get `response = nil`. No band was widened.
- **146.8 Hz holds** (0.740–0.895 → 0.83), and so does mid pitch (0.747–0.987 → 0.88). The ranges
  each block covers (edges at the geometric midpoints) are an inference, pinned at the edges by
  a test.
- **What it means for THIS singer.** All six real wobbles on their take sit at 108.5–126.1 Hz,
  inside the refused block. So the calibrated handoff (§6.2, 18.2) is refused for every one.
  The wobble tool still does what 18.3 promises: smoothing always works, and after smoothing
  flat, a NEW wobble can be added. What it cannot do on their voice is change the speed of
  THEIR OWN wobble in one move. 18.3's two-step hint is the path for all of their notes.
- **C5a-L2 loses its point for now.** Both of its notes (120 Hz, 126 Hz) have no response, so
  the pick cannot confirm `1 ÷ response`. It stays filed, NOT scheduled, until a response
  exists in this singer's range.
- **The only way to give this singer a response is a re-pick, not a wider band.** The 110 Hz
  share depends on wobble RATE, so a response per (pitch, rate) cell might hold inside
  [0.5, 1.1]. That needs its own design: the lookup would use the ESTIMATED rate, which carries
  its own error. Filed as **C5a-F8**, not scheduled.
- **Found on the way:**
  - 18.1.4: the 20 c floor costs ±30 c at E4, not ±25 c (a true ±30 c fits only 18.1 c there).
  - 18.1.6: lowering the floor at low pitch is ruled out, because the ±8 c artefact is present
    at 110 Hz too.
  - 18.1.5's prediction was wrong but the control is still red: widening the scan makes the
    control read "too short", not "a wobble".
  - **SwiftF0's timing lag depends on pitch.** The anchor lands 8–14 ms late at low pitch against
    about −2 ms mid-pitch. At 5.5 Hz, 12 ms is ~24° of phase, the jump the handoff exists to
    avoid. This is for **C5a-1 / C5a-4** to account for. Fixing it in the estimator would change
    the analysis version, which is a separate item.

### 18.8 C5a-4a's outcome (2026-09-25): the handoff seeds the wobble AS READ; the low-note refusal is gone

C5a-4a built the headless gesture (`Sources/DAWAppKit/PitchWobbleGesture.swift`, tests in
`PitchWobbleGestureTests.swift`). The lane ran 23/23 tests with 28 plants, each RED.
§18.7 is superseded for the handoff seed.

- **Why "as read" is the only continuous seed.** The render replaces the singer's wobble as
  `− detected(t) + generated(t)`.
  - At keep 1 the voice is heard as `true(t)`.
  - At the crossing tick (scales 0 plus the new sine G) it is heard as
    `true(t) − detected(t) + G(t)`.
  - The jump is therefore `G − detected`. It is zero only when G is the sine fitted to the PLAYED line,
    at its READ depth and READ anchor.
  - The played line is `detected + curve`, so the drawn jump equals the audio jump.
  - §18.2's depth ÷ response and the lag correction both steer G toward the TRUE voice. That is the wrong
    target: each adds a jump.

  Measured by the lane at 146.8 Hz (response 0.83, lag +6.7 ms), on a 5.5 Hz ±40 c wobble:

  | Seed | Jump |
  |---|---|
  | as read (shipped default, `.asRead`) | 0.00 c RMS |
  | lag subtracted | 6.55 c RMS |
  | depth ÷ 0.83 | 7.05 c RMS |
  | both (§18.2 as written, `.calibrated`) | 10.20 c RMS |

- **§15 T14's tolerances could not see this.** The calibration alone passes every design leg. T14 now has a
  tight leg: width within 3 c, anchor within 2 ms, RMS within 2 c.
- **Consequence: the refusal where `response` is nil is gone.** It existed only for the calibration. So
  §18.7's "the handoff is refused for all six of this singer's real wobbles" NO LONGER HOLDS: T23 hands off
  at 110 Hz.
  - What remains at low pitch after a speed change is `(1 − r)` of the singer's own wobble at its old rate.
  - The two-step route (smooth flat, then add) leaves the same residual, so the refusal bought nothing
    audible.
  - **C5a-L2 regains a point:** listen for that low-pitch residual.
- **The switches** are `PitchWobbleGesture.handoffSeed` (`.asRead` / `.calibrated`) and
  `PitchWobbleGesture.coupling` (`.proportional`, the default until G3's non-inverting separator exists; or
  `.decoupled`).
  - Under `.proportional`: drift = `d0 · k / k0` on the way down, it stays at d0 on the way up, and it is
    untouched when k0 = 0.
  - §5.2's `min(d0, k)` is retired: with drift 1 under keep 0.5, it jumps with zero travel.
- **Design errors found by the lane (NOT fixed in code):**
  - **§6.2 step 4 with the 20 c floor.**
    - The problem: a `.noWobble` handoff from a draft that isn't flat zeroes both scales. A ±40 c wobble reads
      `.noWobble` near keep 0.45, so that tick drops up to about 20 c of drawn and heard wobble.
    - Filed as **C5a-F9**; it needs a design fix before C5a-4b ships the drag.
  - **§9.2's "smoothed flat when the played reading is `.noWobble`"** is false for the same reason. The
    readout says "narrower" or "wider" unless keep is 0.
  - **T20 contradicts T10:** a handoff at depth 0 plays like the stored note. T10 wins: a release at width 0
    commits nothing.
  - **Slop:** the dot's "release within 3 pt" is replaced by the router's 4 pt slop (one home).
  - **§6.2 step 6's `(|speed| − 16)·gain`** is replaced by travel measured from the crossing tick, so the value
    neither jumps there nor when ⌥ toggles.
  - **D14's onset** is superseded by the user's `wobble-onset: same`: onset 0.
- **Worth a look in C5a-4b's looked-at gate:** after a handoff on a low note, "New wobble: … 40 cents each
  way (replaces your own)" prints the READ depth, which invites reading it as the singer's own.
