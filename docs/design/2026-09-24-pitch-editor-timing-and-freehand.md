# Pitch editor: per-note timing (C2) and freehand reshaping (C5b)

Design and implementation plan, 2026-09-24, daw-architect.

**Status: DESIGN. Nothing in this document is shipped.** It extends
`docs/design/2026-09-22-pitch-editor-ui.md` (whose section 7.3 orders the increments
C1 to C5b). It is written against two pieces of work that were landing while it was
written, and it designs neither of them:

- the detected-contour seam (audio-dsp-engineer): one function that returns "the
  contour the render uses", which the editor's display must also call;
- the pitch-editor wire verbs (mcp-integration-engineer): `view.openPitchEditor`,
  `debug.pitchEditor`, `clip.setNotePitch`, `clip.splitNote`.

The user's request (2026-09-23), verbatim:

> "Now, in editor, I should be able to drag the segments like note to higher or lower
> or make the narrower or expand, split the segment into smaller nonte segments and
> manipulate them similarly, zoom in/out, in each segment it should have more detailed
> curve that I should be able to smoth or add more cycles or pull tops or bottoms up or
> down, change the curve with mouse, not just some dots, but with say CMD + mouse I can
> change the shape the way I want."

and later: "look at similar features in melodine and similar, we need to support them".
The user is not a musician. Every user-facing sentence in this plan is written for a
novice.

---

## 0. How to read this document

- **READ**: I opened the code or document at the cited place on 2026-09-24.
- **INFERRED**: derived by arithmetic or reasoning from READ facts, not observed
  running. Every INFERRED claim that matters has a test in section 6 that can prove
  it wrong.
- **REPORTED**: a measurement quoted from someone else's doc comment or document. I
  did not re-measure it.
- **Line numbers were taken on 2026-09-24 between 00:50 and 01:40 while two other
  agents were editing `Sources/`.** Several moved by between one and thirty lines
  during this session. The symbol named next to each line is the durable anchor, so
  re-find by symbol before you edit.
- **Second pass, 2026-09-24 (after 02:00), by symbol.** F1 to F24 were re-found by
  symbol while three agents were editing `Sources/`. All of them hold. Cited lines
  drifted by up to 45 lines (the largest move: `StretchRenderCache.renderContour`,
  from 372 to 417). F19 was corrected in place, because the seam changed shape: it is
  now an enum, the key has a second field, and there is a fallback key. Section 2.7
  adds the facts that sections 3 and 4 rest on.
- Census counts are deliberately not quoted. Where a list of sites matters, the
  **method** (the grep) is given, and the implementing agent re-runs it. Agents add
  call sites every day in this tree.

---

## 1. Decisions at a glance

| # | Decision | Argued in |
|---|---|---|
| A1 | Per-note timing uses the two delta fields `NoteSegment` already has, read as **edited seconds**. One pure DAWCore value, `PitchTimeWarp`, turns an edit set and the source file's duration into a monotone piecewise-linear map **W** from source seconds to edited seconds, pinned at W(0) = 0 and W(D) = D. Render, display and store all build it through the same function. | 3.2 |
| A2 | A clip's `startOffsetSeconds` is read in edited seconds. So playback, clip split, trim, comp flattening, crossfades and fit-to-content need **no** change for C2. W is needed only where a position in the source file meets the clip: the render, the vibrato generator, the editor, the arrange waveform, and the analysis verbs. | 3.3 |
| A3 | The render warps time through the input schedule of the existing curve loop, with a **measured** lookahead. A set with no time edits takes today's loop byte for byte. | 3.4 |
| A4 | The time deltas are already hashed inline. A new time-warp suffix block, emitted only when some delta is non-zero, re-keys exactly the sets whose meaning changes. An unedited clip keeps a byte-identical key. | 3.5 |
| A5 | Melodyne's neighbour rule: an edge shared with an abutting note moves both notes. Otherwise the gap beside the edge gives or takes the time. Clip length, fades and crossfades do not change. | 3.6 |
| A6 | Drag a note's **edge** to change its timing, drag its **body** to change its pitch (C1), and **⌘-drag** it to reshape its curve (C5b). Time snaps magnetically to 1/16 by default; holding ⌥ drags freely. Every gesture commits once, on release. | 3.8, 5.5 |
| B1 | C5b stores a **delta** in cents per note, densely on a global 10 ms source-time grid, quantised to 0.1 cent. The render does not need the contour for it. | 5.2 |
| B2 | The shape is one more term in the curve's sum. It sits inside the note's gate and runs in **source** time. The synthesised-vibrato generator moves to **edited** time. | 5.3 |
| C | The editor draws the curve the render will play: the seam's contour plus `PitchRenderContour.curve(...)`. The blobs include the clip's transpose. The ghost stays as the "where it was sung" outline. This is item **C-0**, and it lands first. | 4 |

Nothing here touches the render thread. Nothing here needs full Xcode, entitlements,
signing or AUv3 (section 3.11).

---

## 2. Findings

### 2.1 The stretch engine and the render path

**F1 [READ]: the engine can do a variable time map offline, but only through
per-call frame counts.** The shim says the "effective stretch ratio is
outputFrames/inputFrames, averaged across calls ... there is no ratio setter"
(`Sources/CSignalsmithStretch/include/csignalsmith_stretch.h:76-81`). There is no
key-frame or time-map API. Our curve loop already drives the engine in chunks of
`interval` output frames, and it computes each chunk's input target **linearly**:
`inTarget = round((outDone + outBlock) · processIn / processOut)`
(`Sources/DAWEngine/Stretch/OfflineStretcher.swift:508-510`, in
`stretchTransposeCurve`). That line is where a warp goes. Since `presetDefault`
(`shim.cpp:28`; vendor `signalsmith-stretch.h:63-65`) the interval is 0.03 s, which is
1440 frames at 48 kHz, and it is measured, not derived (`hopIsMeasuredNotDerived`,
`Tests/DAWEngineTests/OfflineStretcherCurveTests.swift:57`).

**F2 [READ]: inside one call, the engine is linear, and "clean" has hard edges.**
Per block the vendored engine computes `inputOffset = round(outputIndex ·
inputSamples / outputSamples)` (vendor `:288`) and `timeFactor = interval /
inputInterval` (vendor `:312`). With `maxCleanStretch{2}` (vendor `:509`), `timeFactor`
is clamped to at least 0.5, and above 2 the phases are randomised (vendor `:638-640`).
So the engine's clean range for the **combined** local factor (clip ratio times note
factor) is [0.5, 2]. m23-q section 2.5 already recommends a product clamp of
[0.7, 1.4] with a warning. The library's own guidance is that time-stretch "sounds
best" in 0.75x to 1.5x
(`docs/research/2026-07-05-time-stretch-library-evaluation.md:18`).

**F3 [INFERRED, derived; must be MEASURED]: a warped schedule needs a lookahead that
the linear one gets for free.** The analysis centre fed at processing position `p` is
heard at delivered position `p + L`, where `L` is the output latency. The linear loop
absorbs this in `outputSeek`: `seekLength = inputLatency + playbackRate ·
outputLatency` (`OfflineStretcher.swift:460`; vendor `outputSeek` `:173-204`). Under a
variable map the input lead covering `L` output frames depends on the local factor,
so the schedule has to become `inTarget(p) = S(p + L) − S(L)`, where `S(d)` is the
source frame that should be heard at delivered frame `d`. The derived value is
L ≈ 2880 frames (60 ms) at 48 kHz, from the vendored latency accessors (vendor
`:42-47`). Leave the lookahead out and a retimed edge lands about `L` late. The
curve's own latency constant was **measured** (`measuredCurveLatencyFrames = 2379`,
`OfflineStretcher.swift:223`), and this constant needs the same treatment.

**F4 [READ]: output-to-source time has exactly one expression, and it assumes a
constant ratio.** The render always covers the **whole** source file
(`StretchCurvePlan.swift:21-25`). `sourceSecond(forOutputFrame:) = frame / (ratio ·
sampleRate)` (`:52-55`), and step 3 of its derivation says the ratio is constant
"(per-note timing is phase 3 and is explicitly unread today)" (`:29-31`). The curve is
read at `curveLookupFrame = outputFrame + latency + interval/2`
(`OfflineStretcher.swift:287-296`). So per-note timing touches exactly two
expressions in the engine: the input schedule (F1) and this source-second lookup.

**F5 [READ]: a committed edit silences the clip until its render lands.** The
schedule identity includes `pitchEditSetHash` (`PlaybackGraph.swift:66`, built at
`:869` from `PitchEditSetDigest.hex`). A clip whose render is `.pending` is scheduled
as **silence**, with the notice "clip-stretch-pending" (`PlaybackGraph.swift:947-963`).
This is why C1 commits once per gesture, never per pointer tick
(`Sources/DAWApp/PitchCorrectionStaging.swift:97-104`;
`aDragTickNeverCommits`, `Tests/DAWAppKitTests/PitchEditorModelTests.swift:996`). Every
new gesture in this plan inherits that rule.

**F6 [READ]: playback maps a clip into its rendered file linearly, at two sites.**
`fileOffsetFrames = (startOffsetSeconds × stretchRatio × fileRate).rounded()` appears
at `PlaybackGraph.swift:2693-2694` (`scheduleAll`, which `OfflineRenderer.beginSession`
also drives, `:2656`) and at `:2900-2901` (`buildCyclePlan`). Decision A2 keeps both
sites unchanged.

### 2.2 The model and cache identity

**F7 [READ]: the time deltas already exist, are already keyed, and nothing writes
them.**
- `NoteSegment.timeStartDeltaSeconds` / `timeEndDeltaSeconds`
  (`Sources/DAWCore/PitchCorrection.swift:418-424`) are documented "carried, unread".
  They are sanitised against NaN only (`:591-592`), omitted from Codable at 0
  (`:661-666`), and part of `isIdentity` (`:515-520`).
- They are hashed **inline** in the digest (`StretchCurvePlan.swift:168-169`).
- Nothing outside the model writes them. A grep for writers exits 1, and the same
  grep positive-controlled at a count of 9 inside `PitchCorrection.swift`.

So an unretimed clip keeps a byte-identical key for free, and a retimed clip re-keys.
[INFERRED] The one hazard: a hand-written or agent-written project that carries
non-zero deltas **today** renders them ignored, under a key that includes them. On the
day C2 makes them read, that same key would serve stale, unwarped audio. Decision A4's
suffix re-keys exactly those sets.

**F8 [READ]: the digest's field census is reflection over top-level labels.**
`digestCoversEveryStoredField` (`Tests/DAWEngineTests/PitchCurveRenderTests.swift:411`)
enumerates `NoteSegment`'s stored properties with `Mirror` against a covered list. It
also has a mutation leg. [INFERRED from how `Mirror` works] An **array** field is
caught at the label level only. The census cannot tell whether the digest hashes the
array's count or its contents, so C5b needs its own mutation test for interior
samples. The template for adding fields without re-keying legacy sets is the
generator suffix: `layoutVersion` stays 1, and a `suffixMarker` block is emitted only
when a segment uses the feature (`StretchCurvePlan.swift:126-131`, `:172-187`).

**F9 [READ]: C3's split copies every field verbatim, which is wrong for timing and
for shape.** `splitClipNoteSegment` (`Sources/DAWCore/ProjectStore+PitchNoteEdits.swift:128-165`)
keeps the parent as the left half with a new end. It builds the right half by a
Codable round trip (`reidentified`, `:210-224`), which copies all fields. Under C2 the
two halves must instead **re-derive** their time deltas at the cut, and under C5b they
must **slice** the shape samples. The pinning test
`splitCarriesEveryEditFieldTheParentHad`
(`Tests/DAWCoreTests/PitchCorrectionWriterTests.swift:490-561`) treats only
`{id, startSeconds, endSeconds}` as changeable (`:551`). Its parent sets no time delta
and no generator field (`:498-503`), so today it passes by default equality. Its
`changeable` set must widen in the **same change** that adds re-derivation, and a
physics test (W unchanged by a split) takes over the claim.

**F10 [READ]: the evaluator runs in source seconds, and the generator's phase is
anchored at source second 0.** `PitchCorrectionCurve.semitones(atSourceSecond:)`
(`PitchCorrection.swift:1160-1217`) sums the constant offset, the contour shaping
(interpolated linearly and **held at both ends**, `:1246-1256`) and the generator
`depth · fade · sin(ω·t)` (`:1269-1283`). The gates are centred smoothsteps
(`:1224-1232`). The model's own extension-seam note says a freehand override is
"another term in the same sum inside the same gate" (`:944-950`). [INFERRED] Under a
time warp, the generator must be evaluated in **edited** time. Otherwise a note
stretched 1.4x plays its synthesised 5.5 Hz vibrato at about 3.9 Hz. The gates and
the shaping terms must stay in source time, because they describe the sung audio,
which the stretcher moves along with the note.

**F11 [READ]: the curve builder is O(segments × frames).** `PitchCorrectionCurve.make`
re-filters the whole contour for each shaping segment (`:1097-1099`). The display
will now build a curve on every committed edit. [INFERRED] 450 notes × 2000 frames is
about 1M comparisons, which is fine, but C-0 measures it rather than assuming.

**F12 [INFERRED from READ gate code, pre-existing]: a split under a long retune can
dip at the join.** A half-ramp is `min(retune/2, duration/2)` (`:1132`), and
`retuneMsRange` reaches 500 ms (`:713`). Two split halves of unequal length can
therefore get unequal half-ramps. Their gates then do not sum to 1 at the cut, and the
correction dips there. This does not block C2 or C5b, but it means "the whole curve
is unchanged by a split" is **not** a true invariant to test. The split tests in
section 6 test W and the shape term, which are.

### 2.3 Clip geometry

**F13 [READ arithmetic; INFERRED consequence; must be proven red first]: split and
both trims add timeline seconds to a source-seconds offset.**
- `startOffsetSeconds` is in source seconds. See the doc at `Model.swift:547-553`,
  `sourceWindowSeconds = timeline / ratio` (`:760-775`), and `ARCHITECTURE.md:1468`:
  "file offset maps as `startOffsetSeconds × ratio`".
- Three sites add **timeline** seconds to it without dividing by the ratio:
  - `splitClip`: `splitSeconds = tempoMap.seconds(from: startBeat, to: atBeat)`
    (`ProjectStore.swift:5382`), then right half
    `startOffsetSeconds: clip.startOffsetSeconds + splitSeconds` (`:5467`);
  - `applyTrimWindow` (`:5529-5530`);
  - `clipTrimmedToWindow` (`:6607-6608`), the overlap-resolution and import trim.
- The sites that **do** divide:
  - `CompFlattener` (`Takes.swift:195-196`), whose comment calls itself "the splitClip
    math, generalized for stretch";
  - the comp crossfade (`Takes.swift:314-315`);
  - the arrange crossfade (`ProjectStore.swift:7210`, `:7231`).
- The only split and trim stretch tests (`ClipStretchTests.swift:227`
  `splitCopiesStretch`, `:242` `trimPreservesStretch`) check that ratio, pitch and
  formant carry over. Neither checks the offset.

Predicted consequence: split a 2x-stretched clip 4 s in, and the right half starts
4 s of stretched audio (2 s of source) past where the left half ends. This is
pre-existing and independent of C2, but it sits directly in C2's blast radius, so it
is item **C2-0**, red first. If the red test passes on today's tree, this finding is
wrong, and the item stops.

**F14 [READ]: the arrange waveform ignores the stretch ratio.** `ClipWaveform` maps a
column to `seconds = startOffsetSeconds + x/pixelsPerBeat × secondsPerBeat`
(`Sources/DAWApp/Timeline/ClipWaveform.swift:181`). Both construction sites pass the
project's `secondsPerBeat` unscaled (`TimelineLanesView.swift:3446-3453`,
`TakeLanesView.swift:193-195`). So a stretched clip's waveform already disagrees with
its sound. Per-note timing would add a second disagreement. Item C2-6 fixes both.

**F15 [READ]: analysis results reach the timeline through linear `× stretchRatio`
conversions.**
- `ProjectStore+TakeAlignment.swift:227`: `clipStartSeconds + (t − windowStart) ×
  stretchRatio`.
- `SliceToSampler.swift:277,283`.
- `ProjectStore+Quantize.swift:83`; its doc at `:12` states the formula.
- `ProjectStore+Analysis.swift:79` (bpm divided by the ratio).
- `clip.transcribe` refuses a stretched clip outright
  (`ProjectStore+Transcription.swift:50-51`).

Method for the full census: `grep -rn "stretchRatio" Sources/DAWCore Sources/DAWAppKit`
and `grep -rn "sourceWindowSeconds(" Sources/`. The second grep already includes a new
caller, `Sources/DAWApp/PitchEditorDebugStaging.swift`, added by a concurrent agent
during this session.

### 2.4 The editor and the display

**F16 [READ]: defect C.** The edited note does not draw the curve it will play.
- `drawContour` (`Sources/DAWApp/PitchEditor/PitchEditorView.swift:460-481`) strokes
  the **detected** contour runs.
- Only the blob rectangle moves to the edited pitch: `drawBlobs` (`:358-408`) builds
  the rect from `editedCentreMidi` (`PitchEditorModel.swift:291`, `:665-673`).
- The ghost is a dashed outline at the sung centre (`:394-399`).

So on a note moved up a semitone, the rectangle sits on the new row while the pitch
line stays on the old one.

**F17 [READ]: the editor ignores the clip's transpose.** `pitchShiftSemitones` does
not occur in `PitchEditorModel.swift`. The grep exits 1, and the same grep shape
matched `editedCentreMidi` in the same run. The render's curve **subsumes** the clip
transpose (`StretchCurvePlan.swift:45-49`). So on a transposed clip every blob and
the whole line are drawn at the wrong height.

**F18 [READ, with a REPORTED measurement]: the editor's contour and the render's
contour are different analyses.** The editor's detection provider is wired to
`store.detectClipPitch` (`Sources/DAWApp/ContentView.swift:983`), which analyses the
clip's **current window**. The render's contour is whole-file, from source second 0
(`Sources/DAWEngine/Stretch/PitchContourCache.swift:27-38`). That doc comment
**reports** what the two analyses do on a clip trimmed to start 1.234 s into the file:
the frame grid is 2.0 ms off, 16 of 2004 frames flip voicing, and pitch differs by a
median of 1.7 cents (max 17.7). I did not re-measure this.

**F19 [READ; corrected in place on the second pass]: the seam, as landed.**
- `AudioEngineControlling.renderPitchContour(inFileAt:analysisVersion:) async ->
  PitchRenderContour` (`Sources/DAWCore/EngineProtocol.swift:727`) leads to
  `StretchRenderCache.renderContour(source:analysisVersion:)`
  (`StretchRenderCache.swift:417`, "the display's door to THE seam"). That leads to
  the static `PitchContourCache.renderContour(source:analysisVersion:renderCacheDirectory:detector:)`
  (`PitchContourCache.swift:220`). The protocol's default implementation answers
  `.unavailable("this engine cannot analyse pitch")` (`EngineProtocol.swift:1757`).
- `PitchRenderContour` is an **enum in DAWCore** (`PitchCorrection.swift:1330`) with
  three cases: `.detected(PitchDetectionResult)`,
  `.analysisVersionMismatch(editSet:detector:)` and `.unavailable(reason:)`. `frames`
  is `[]` for every case except `.detected`. `frameValueOffsetSeconds` is half a
  detector frame (the frame centre), or 0 when nothing was detected.
- `PitchRenderContour.curve(editSet:clipPitchShiftSemitones:)` (`:1393`) is
  documented as "THE curve a render of editSet plays ... a display must too". The
  render reaches it only through
  `StretchCurvePlan.make(editSet:clipPitchShiftSemitones:sampleRate:ratio:contour:)`
  (`StretchCurvePlan.swift:81-92`). When the contour is `nil`, that falls back to
  `PitchCorrectionCurve.make(editSet:clipPitchShiftSemitones:)`.
- The render request is `StretchRenderCache.Params(clip:)` (`StretchRenderCache.swift:92-97`).
  It carries the ratio, `pitchShiftSemitones`, the formant flag and `pitchEdits`, and
  the last is normalised to `nil` when the digest is empty.
- `renderKeys` (`:354-390`) returns two keys, `resolved` and `legacy`. The resolved
  key appends `contour:<key>` **and** `shaping:<PitchRenderContour.shapingVersion>`, and
  only when `Params.shapesAgainstContour` (`:121-124`) is true. That requires some
  segment to have `wantsContourShaping` (a drift or vibrato scale other than 1,
  `PitchCorrection.swift:538`), and the set's `analysisVersion` to match the
  detector's. When the contour is not `.detected`, `performRender` renders the
  constant-offset curve under the legacy key and returns `.fellBack` with a reason
  (`:557-583`).
- **Nothing above the engine calls the seam yet.**
  `grep -rn renderPitchContour Sources/ Tests/` finds only the protocol, its default,
  the engine's implementation and doc comments. The same grep found all five of
  those, so it would have seen a caller if one existed.

So a C5b representation that does not need the contour keeps a shape-only set out of
the contour key entirely (decision B1).

**F20 [READ]: the editor has one affine conversion, already flagged for this phase.**
`PitchEditorGeometry.projectBeat(forSourceSecond:)` and its inverse
(`PitchEditorModel.swift:559-571`) use `(seconds − sourceWindowStart) × stretchRatio`.
UI design section 5.4 says "Phase 3 is where these stop being affine". The commit
kinds are `{notePitch, splitNote}` (`:946-952`), and there is one tool enum,
`{pointer, scissors}` (`:853`). ⌥ is read from `NSEvent.modifierFlags` on each drag
tick (`PitchEditorView.swift:940-944`).

**F21 [READ]: the snap vocabulary has a label trap.**
- `SnapResolution` (`Sources/DAWAppKit/PianoRollModel.swift:16-40`) uses musical
  labels: `.sixteenth` is 0.25 beats and reads "1/16".
- `ClipSnap` (`Sources/DAWAppKit/ClipEditModel.swift:17`) labels **beat fractions**,
  so its "1/4" means a quarter of a beat.
- The TUNE X reference frame shows a `1/16` chip (UI design `:915`, marked [SEEN]).
- The pitch editor has no time snap today.

### 2.5 Collisions and pre-existing gaps

**F22 [READ]: presets silently discard hand edits.** `autoCorrectClipPitch(clipId:options:)`
(`Sources/DAWCore/ProjectStore+PitchCorrection.swift:76`) replaces the whole set and
has no `replaceExisting`. The grep for that name exits 1, and the same grep matched
the function name. UI design section 6.3.6 requires a warning before hand edits are
discarded, and that warning was never built. Retiming and reshaping make the silence
more expensive, because minutes of hand work vanish on one menu click.

**F23 [READ]: per-note edits cannot reach a take-lane clip.**
`locateClipIndexForNoteEdits` searches `tracks[].clips` only
(`ProjectStore+PitchNoteEdits.swift:236-243`). Meanwhile the editor model is
id-addressed "so take lanes work from day one" (`PitchEditorModel.swift:986-989`).
This is pre-existing: it affects C1 and C3 today, and C2 and C5b inherit it.

**F24 [READ]: undo coalescing.** Same-key edits within 800 ms fold into one step
(`Sources/DAWCore/UndoJournal.swift:91`). The keys exist for segment, drift and
vibrato, and structural edits use `nil`, which never coalesces
(`PitchCorrectionUndoKey`, `PitchCorrection.swift:831-862`). The minimum note length
is `minimumNoteSeconds = 0.06` (`:1459`), and the split refusal uses it.

### 2.6 What Melodyne does (primary sources, fetched 2026-09-24)

**F25 [READ, Celemony help]: Timing Tool**
(https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolTiming_2):
- Dragging the left-hand end of a blob stretches or squeezes the beginning of the
  note; the right end works the same way for the end.
- A connected neighbour's facing edge moves "to avoid a gap or an overlap".
- A connection is drawn as a thin vertical line, and the Separation Type tool's
  bracket makes notes independent.
- Changes follow the Time Grid, and [Alt] overrides it.

**F26 [READ, Celemony help]: Main Tool**
(https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolMain):
- The tool is context-sensitive by zone. The front part of a note stretches its start
  with the end anchored, the rightmost part moves the end, and the middle drags pitch
  **and** time. The upper part acts as note separation.
- [Alt] ignores the pitch and time grids.
- The page does **not** state how large the edge zones are.

**F27 [READ, our research docs]: what the other docs establish.**
- The Time Handles and Attack Speed page
  (https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolTimeHandlesAttackSpeed_2)
  would not fetch. It failed twice with "socket hang up", both in the research pass
  and again today. Its contents are known only from search summaries
  (`docs/research/2026-09-23-melodyne-class-pitch-editors.md:49`, `:64-65`).
- Celemony's tier copy: "Essential provides all the basic tools to adjust pitch,
  timing and note length" (`:177`). Timing is core, not advanced.
- Rate-changing vibrato is **not** confirmed in Melodyne (`:17`, `:183`).
- ⌥ for free movement matches the convention the C1 plan uses
  (`docs/research/2026-09-23-vocal-editing-workflows.md:97-101`).
- Merge is the split tool's inverse (`:113-120`, `:208-212`).

### 2.7 Facts added on the second pass (2026-09-24)

**F28 [READ]: what sections 3 and 4 stand on that sections 2.1 to 2.6 did not record.**
- `PitchCorrectionCurve` is `Equatable`. Equality is synthesised over its
  `fileprivate` spans, the clip shift and `unresolvedShapingSegmentIDs`
  (`PitchCorrection.swift:966-1027`). A test can therefore compare the curve
  **object** the render uses with the one the display uses, rather than sampled
  points.
- `StretchCurvePlan` is internal to DAWEngine, and `DAWEngineTests` depends on
  `DAWAppKit` (`Package.swift:251`). A `@testable import DAWEngine` test can hold the
  editor model and the render plan side by side.
- `AudioFileImporter` computes a file's duration as
  `Double(file.length) / processingFormat.sampleRate`
  (`Sources/DAWEngine/AudioFileImporter.swift:24-26`). `fitClipToContent`
  (`ProjectStore.swift:5615`) already reads it through `media.audioFileInfo(at:)`.
  `performRender` opens the same file through the same `AVAudioFile` API, so the
  render can compute the **same bits** from `reader.length` and `format.sampleRate`.
- The vendored `outputSeek` infers **one** playback rate for the whole pre-roll:
  `(inputLength − inputLatency) / outputLatency` (vendor `:173-181`).
- `autoCorrectClipPitch` builds its note table from the **windowed** detection
  (`detectClipPitch(clipId:)`, `ProjectStore+PitchCorrection.swift:87-88`). So preset
  note boundaries and the render's whole-file contour come from two different
  analyses. This is F18's mismatch one level up. This plan names it as follow-up
  **C-F1** and does not fix it.
- `debug.pitchEditor` (`Sources/DAWApp/PitchEditorDebugStaging.swift:74-143`)
  reports `editedMidi = sungMidi + pitchOffsetCents/100` for each note. That leaves
  out the clip transpose (F17 again), and its `edited` flag reads only
  `pitchOffsetCents`.
- m23-q's own words on the clamp
  (`docs/research/m23-q-pitch-correction-design.md:111`) are "clamp per-note time
  ratio to ~[0.7, 1.4] and surface a warning rather than silently smearing". It
  quotes upstream's "between 0.75x and 1.5x". The same document (`:78`) notes that
  the 30 ms hop grid is in **output** time, so a retimed note gets non-uniform curve
  sampling in source time.

---


## 3. Design A: per-note timing (C2)

### 3.1 The decision, and the two alternatives that lose

**Decision.** A note's timing is stored in the two fields `NoteSegment` already
carries: `timeStartDeltaSeconds` and `timeEndDeltaSeconds`. They are read as
**edited seconds**. The note's edited start is `startSeconds + timeStartDeltaSeconds`,
and its edited end is `endSeconds + timeEndDeltaSeconds`. "Edited seconds" is the
clip-source time axis after retiming and before the clip's own `stretchRatio`. Under
no time edits it is the source axis, bit for bit. One pure DAWCore value,
`PitchTimeWarp` (W), maps source seconds to edited seconds. The offline render warps
the stretcher's input schedule through W, so the rendered file is the whole source
file with the notes moved inside it. The file's length does not change.

**Alternative 1: cut the clip at note boundaries and stretch each piece as its own
clip.** It loses for four reasons. It multiplies clips, crossfades and render-cache
entries by the note count. It breaks the whole-file render that makes a split clip
share one phase-coherent render (`StretchCurvePlan.swift:21-25`, F4). It puts a
crossfade seam at every note boundary, where the singer did not stop. And it turns a
per-note undo into a structural arrange edit.

**Alternative 2: a new stored field, a per-note time ratio or a list of time
markers, instead of the two deltas.** It loses on two counts. The deltas already
exist, are already sanitised, already sit in `isIdentity`, are already omitted from
Codable at zero, and are already hashed inline (F7). A new field would need a second
digest migration and a second Codable default for no gain in expressiveness. Two
edge positions per note, plus the neighbour rule (3.6), is exactly Melodyne's Timing
Tool (F25), so nothing the user asked for needs more.

### 3.2 The time map W (`PitchTimeWarp`)

**Home:** a new file, `Sources/DAWCore/PitchTimeWarp.swift`. It is pure: no clock,
no I/O, no store, no engine.

```swift
public struct PitchTimeWarp: Sendable, Equatable {
    /// Strictly ascending. First element 0, last element D.
    public let sourceKnots: [Double]
    /// Strictly ascending, index-for-index with `sourceKnots`. First 0, last D.
    public let editedKnots: [Double]
    /// True when construction dropped or moved any knot (steps 2 to 4 below). A set
    /// the setter wrote is never healed. A caller that finds this true must say so
    /// (a render notice, an editor caption), and never adjust silently.
    public let healed: Bool

    /// nil when the set has no time edits (`PitchEditSet.hasTimeEdits` is false),
    /// or when `sourceDurationSeconds` is not finite and positive. A caller that
    /// holds time edits and gets nil must SAY so. It must never render or draw
    /// the edits as if they were absent (section 3.10, mode 5).
    public static func make(editSet: PitchEditSet,
                            sourceDurationSeconds: Double) -> PitchTimeWarp?

    public func editedSecond(forSourceSecond s: Double) -> Double
    public func sourceSecond(forEditedSecond e: Double) -> Double
    /// Edited length over source length for the piece containing `s`.
    public func localFactor(atSourceSecond s: Double) -> Double

    /// Structural bound on every piece's slope. NOT the audio-quality clamp:
    /// that one depends on the clip's ratio and lives in the setter (3.7).
    public static let structuralFactorRange: ClosedRange<Double> = 0.25...4
    /// Re-keys every retimed render when bumped (3.5).
    public static let scheduleVersion = 1
}
```

**The one predicate.** `NoteSegment.hasTimeEdits` is `timeStartDeltaSeconds != 0 ||
timeEndDeltaSeconds != 0`, and `PitchEditSet.hasTimeEdits` is
`segments.contains(where: \.hasTimeEdits)`. This follows the `hasGeneratedVibrato`
rule: the digest suffix, `make`, the render branch and the editor all ask this one
property, and none of them re-states it.

**Construction.** Everything below is deterministic, so every site gets the same
knots from the same inputs.
1. Knots: `(0, 0)`, then for each canonical segment in order,
   `(startSeconds, startSeconds + timeStartDeltaSeconds)` and
   `(endSeconds, endSeconds + timeEndDeltaSeconds)`, then `(D, D)`.
2. Drop every segment knot whose source position is `≤ 0` or `≥ D`. The file's
   edges are fixed, so a note that starts at source second 0 cannot move its start
   (the setter refuses; see 3.7). A set that arrives with such a knot anyway, from
   hand-written JSON, is healed rather than rejected, and `healed` is set.
3. Two knots at the same source position (abutting notes, 3.6) merge. **The first
   wins** (the left note's end), which is `PitchEditSet.canonical`'s own rule.
4. **Heal to a total, monotone, slope-bounded map in one forward pass.** Let
   `[fMin, fMax] = structuralFactorRange`. The envelope of edited positions reachable
   from both anchors is
   `lo(s) = max(fMin·s, D − fMax·(D − s))` and
   `hi(s) = min(fMax·s, D − fMin·(D − s))`. For k = 1, …, n − 1 in ascending order:
   `e_k = clamp(e_k, max(lo(s_k), e_{k−1} + fMin·Δs), min(hi(s_k), e_{k−1} + fMax·Δs))`.
   [INFERRED, and pinned by test] Because `e_{k−1}` lies inside its own envelope,
   the interval is never empty. The last piece to `(D, D)` then lands inside the
   bounds automatically. A set the setter wrote passes through unchanged. Only
   hand-written or agent-written JSON is ever moved, and the heal never produces a
   crossing, a zero-length piece or a NaN.
5. Evaluation is linear interpolation between knots, with binary search. Outside
   `[0, D]`, W is the identity (slope 1). That is continuous, because both anchors
   are fixed points. A non-finite input returns itself.

**Why D is a parameter, and where it comes from.** W must return to the identity at
the file's end. Otherwise either the rendered length changes, which breaks the
stretcher's `round(inputFrames × ratio)` contract and every file-offset computation
that rests on it (F6), or the tail is clipped. `Clip` carries no source duration, and
DAWCore never opens files, so D is an input. It comes from **one expression**,
`Double(frameLength) / processingFormat.sampleRate`:
- the render computes it from the `AVAudioFile` it already opened in `performRender`;
- the store and the editor read `media.audioFileInfo(at:).durationSeconds`, which
  `AudioFileImporter` computes with the same expression (F28).

A test pins that the two are bit-identical on a fixture file (C2-1). If they ever
differ, the display's W and the render's W differ in their last piece, and the C-0
equality gate goes red.

**Why an "open" edge does not simply shift everything after it (tail slope 1,
rejected).** The alternative lets W beyond the last note be `s + δ_last`. That needs
no D. But it lengthens or shortens the rendered file. The render would have to pad
or drop audio at both ends and change its output-length contract, and the clip's
window would silently gain or lose material at its far end. Anchoring at D keeps one
rule everywhere: the gap beside a moved edge gives or takes the time, and the file's
start and end are simply the far sides of the first and last gaps.

**Where W lives at run time.** `PitchCorrectionCurve` gains a stored
`timeWarp: PitchTimeWarp?`. `PitchCorrectionCurve.make` and
`PitchRenderContour.curve(editSet:clipPitchShiftSemitones:)` each gain a
`timeWarp: PitchTimeWarp? = nil` parameter, built by the caller with
`PitchTimeWarp.make`. Existing callers pass nothing and are byte-identical. Because
the curve is `Equatable` (F28), the C-0 gate compares W too. A display that forgets to
pass W fails the gate on any retimed set.

### 3.3 Where W is needed, and where it is not (decision A2)

`Clip.startOffsetSeconds` is read in **edited** seconds. The rendered file's frame
`d` is edited second `d / (ratio · rate)`, and W(D) = D keeps the file's length. So
every computation that lives in the rendered file's domain is unchanged.

**Not needed (edited domain throughout):**
- playback file offsets, `startOffsetSeconds × stretchRatio × fileRate`, at both
  sites (F6);
- clip split and both trims. This holds once C2-0 fixes their missing `/ ratio`
  (F13). Timeline seconds divided by the ratio are edited seconds;
- comp flattening and both crossfades, which already divide (F13);
- `fitClipToContent`, which reads `fileDuration − startOffsetSeconds`. W(D) = D makes
  that an edited-domain quantity;
- anything that reads the rendered file: bounce, meters, spectrum, loudness.

**Needed (a source-file position meets the clip):**

| Site | What W does there | Item |
|---|---|---|
| The render's input schedule and curve lookup | edited → source | C2-3 |
| The vibrato generator | runs in edited time (F10) | C2-3 |
| The store's timing setter, and split re-derivation (F9) | validation; W(cut) | C2-4 |
| `clip.getPitchEdits` | echoes `editedStartSeconds` / `editedEndSeconds` | C2-4w |
| The editor: blob x, hit zones, scissors, the played line | source ↔ edited ↔ beat | C2-5 |
| `ClipWaveform` (which also ignores the ratio today, F14) | column → edited → source | C2-6 |
| Analysis results placed on the timeline (F15) | source → edited → timeline | C2-7 |

**Rule for C2-7: map or refuse, never misplace.** Every F15 site gets one DAWCore
function, `Clip.timelineSeconds(forSourceSecond:warp:tempoMap:)`. It replaces the
inline `(t − windowStart) × stretchRatio` expressions. A site that is not converted in
C2-7 must refuse a clip whose `pitchEdits?.hasTimeEdits` is true, with a teaching
error. `clip.transcribe`'s `transcriptionRequiresUnstretchedClip` is the precedent. A
retimed clip must never get results that are silently placed wrong. Census method:
`grep -rn "stretchRatio" Sources/DAWCore Sources/DAWAppKit` and
`grep -rn "sourceWindowSeconds(" Sources/`. Re-run both at build time.

### 3.4 The render: warping time through the curve loop (decision A3)

All of this runs inside `StretchRenderCache.performRender`, a detached offline task.
None of it runs on the audio render thread.

**Symbols.** `F` is the source length in frames, `r` the rate, `ρ` the clip ratio,
`O = round(F·ρ)` the output length (unchanged), and
`S(d) = r · W⁻¹(d / (ρ·r))` the fractional source frame heard at delivered output
frame `d`. With no warp, `S(d) = d/ρ`.

**1. Plan.** `StretchCurvePlan.make` gains `sourceDurationSeconds`. It builds
`PitchTimeWarp.make(editSet:sourceDurationSeconds:)` and passes it into the curve.
`performRender` passes `Double(reader.length) / format.sampleRate` (3.2). Because
`editSet.isIdentity` already includes the deltas (F7), a timing-only set is not
identity. It takes the curve path, and its curve is the constant clip shift.

**2. Curve lookup.** `sourceSecond(forOutputFrame:)` keeps today's expression
**verbatim** as its nil branch:

```swift
func sourceSecond(forOutputFrame frame: Int) -> Double {
    guard ratio > 0, sampleRate > 0 else { return 0 }
    let edited = Double(frame) / (ratio * sampleRate)   // today's expression
    guard let warp = curve.timeWarp else { return edited }
    return warp.sourceSecond(forEditedSecond: edited)
}
```

`semitones(atOutputFrame:)` passes both seconds to the curve (step 4).
`curveLookupFrame` is untouched. It is in delivered frames, and the warp enters after
it (F4).

**3. Input schedule.** `OfflineStretcher.stretchTransposeCurve(…)` gains
`inputSchedule: WarpedInputSchedule? = nil`. **nil runs today's lines unchanged**:
the linear `inTarget`, `seekLength`, `processIn`, `processOut` and the flush. This is
structural byte-identity, not arithmetic identity. An identity schedule computed
through `S` would **not** reproduce today's bytes, because today's loop uses
`processIn/processOut`, not `1/ρ`. So "no time edits" must never reach the warped
branch. `PitchTimeWarp.make` returning nil is what guarantees that.

The warped branch. It is [INFERRED] from the vendored `outputSeek` contract (F28: the
pre-roll rate is inferred from `inputLength`), and it reduces to `p/ρ` when W is the
identity. Where retimed edges actually land is MEASURED in C2-2 (step 5):
- `seekLength_w = Int(Double(inputLatency) + S(outputLatency))`. This is the same
  expression as today with `S` in place of `playbackRate ×`. It is equal to today's
  wherever W is the identity over the first `outputLatency` frames.
- In the chunk loop:
  `inTarget = clamp(Int((S(outEnd + L_w) − S(L_w)).rounded()), inDone, processIn_w)`,
  where `outEnd = outDone + outBlock` and `processIn_w = totalIn − seekLength_w`. The
  clamp never binds when W is monotone. It exists so that `inBlock` can never be
  negative into `css_process`, whatever reaches it.
- `processOut_w` is the largest `outEnd ≤ O` whose `inTarget` fits in `processIn_w`.
  The flush writes `O − processOut_w` frames, at the **local** playback rate of the
  last piece, `1/(ρ · localFactor(D))`.
- `totalIn = max(F, seekLength_w)`, zero-padded, as today.

**4. The generator in edited time (the timing half of B2).**
`semitones(atSourceSecond:)` gains an internal two-argument form,
`semitones(atSourceSecond s: Double, editedSecond e: Double?)`. The render passes
`(W⁻¹(edited), edited)`. The one-argument form passes `timeWarp?.editedSecond(…)`.
Inside, the generator term reads

```swift
let t = e ?? s          // branch on PRESENCE; never evaluate an identity W
contribution += Self.generatedVibrato(span, at: t)
```

The envelope is anchored at `W(startSeconds)` when warped, and at `startSeconds`
otherwise, the same way. [INFERRED from F10] Gates, drift/vibrato shaping and the C5b
shape term (5.3) stay in **source** time, because they describe the sung audio, and
the stretcher moves the sung audio with the note. **Why branch rather than evaluate:**
a piecewise-linear identity `a + (t − a)·1.0` is not bit-exact in IEEE arithmetic.
This is the same class of hazard the `-0.0` note inside `semitones(atSourceSecond:)`
records. The untimed goldens stand on the branch, not on arithmetic luck.

**5. The lookahead `L_w` is MEASURED, not derived (F3).** The derived candidate is
`css_output_latency` (2880 frames at 48 kHz). The measured curve latency is 2379, 501
frames short of its own derivation (`OfflineStretcher.swift:205-209`). That is the
evidence that this pipeline's effective delay is not its accessor's. Item C2-2
measures `L_w` before C2-3 uses it:
- Fixture: a 4 s file of 2 ms sine bursts every 200 ms, and a hand-built edit set.
  One note spans [1.0, 1.6] s, with its end delta +0.3 (factor 1.5). The next note
  spans [2.4, 3.0], unedited, so the gap is compressed by 0.625.
- Predicted landing of each burst: `W(s_burst) · ρ · r`. Measure the actual onsets by
  energy threshold.
- First render the **raw** path (`L_w = 0`) and record the lag. That is the
  `.none`-compensation precedent (`OfflineStretcher.swift:229-240`). Then sweep
  `L_w ∈ {0, 1440, 2379, 2880, 4320}` and fit.
- Record the result as `measuredWarpLookaheadFrames`, with the measurement quoted in
  its doc comment the way `measuredCurveLatencyFrames` is. Scale it by the rate
  exactly as `curveLatencyCompensation(sampleRate:)` does, and re-measure at
  44.1 kHz and at ρ = 1.25.
- Landing budget: every burst within ±(half a hop + the measured residual). The
  budget is set from the measurement and quoted, never invented.
- **The fit must tell a wrong constant from a wrong formula.** Regress landing
  error against burst position, before, inside and after the stretched note. A
  constant offset means `L_w` is wrong, and the sweep fixes it. An error that grows
  with position inside the warped region means the schedule formula itself is wrong.
  No choice of `L_w` can fix that, so the item stops and reports rather than fitting
  around it.

**6. Resolution, stated rather than claimed away.** Inside one `css_process` call the
engine is linear (F2), and chunks are one hop (30 ms). So a knot takes effect at hop
granularity: ±15 ms, the same limit that floors `retuneMs`. The hop grid is in
**output** time (F28, m23-q `:78`), so a stretched note gets its curve sampled more
densely in source time, and a compressed one less densely. That is harmless, but no
code may assume uniform source-time sampling.

### 3.5 The cache key (decision A4)

The deltas are already hashed inline (F7). So the only job of a new block is the
stale-key hazard: a set that carries non-zero deltas **today** was rendered with them
ignored, under a key that includes them. Append after the generator suffix, in
`PitchEditSetDigest.hex`:

```swift
if set.hasTimeEdits {                        // the one predicate (3.2)
    putBits(timeWarpSuffixMarker)            // a new distinctive constant
    putInt(PitchTimeWarp.scheduleVersion)
}
```

- **An untimed set produces byte-identical digest material**, so every cache entry on
  every disk stays valid. `layoutVersion` stays 1, following the generator suffix
  precedent (F8).
- **A timed set re-keys**, including one written before C2 existed.
- **`scheduleVersion` follows the `shapingVersion` precedent.** When `L_w` is
  re-measured, or the heal or the flush rule changes, bump it. Exactly the retimed
  renders re-key. `stretchEngineVersion` would re-render every stretched clip on
  every disk.
- D is **not** hashed. It is a property of the source file, and
  `sourceIdentityFields(source:)` already puts the file's identity in the render key.
- The playback graph's schedule identity is the digest hex (F5), so it follows
  automatically.

Tests (C2-1): pinned hex goldens for three legacy sets (plain offsets, a flattened
set, a generator set) are unchanged. A set with a +0.1 s end delta has a hex that
differs from its **pre-C2 hex**. Capture that literal on today's tree before the
change, and embed it. Planted defect: remove the suffix emission. The re-key test
must go red.

### 3.6 The neighbour rule (decision A5)

- **Connected** means `left.endSeconds == right.startSeconds` exactly, in source
  seconds. Detected notes never abut: a voiced run ends at a hole or at a frame gap
  (`PitchAutoCorrect.voicedRuns`), so there is always a gap. C3's split always makes
  abutting halves (the left half's new end is the right half's start, F9). So
  "connected" means "one sung note the user cut in two". That is Melodyne's
  connected pair (F25): a legato line that the segmenter reported as one run.
- **Dragging a connected edge moves both notes.** The setter writes the same delta
  to the left note's end and the right note's start. The two knots then coincide,
  and step 3 of the construction (first wins) is a no-op on a set the setter wrote.
- **Dragging an unconnected edge moves one note.** The gap beside it gives or takes
  the time: W interpolates between the moved knot and the neighbour's unmoved knot.
  For the first and last notes, the neighbour's knot is the file's edge, `(0, 0)` or
  `(D, D)`.
- **What does not change:** the clip's start, length, window, fades and crossfades,
  every other note, and the rendered file's length.
- **The editor draws the connection** as a thin vertical hairline at the shared
  edge, in `signal` ink at 40 %, the same mark Melodyne uses (F25). A novice can then
  see *before* dragging that the two notes move together.
- **Not in this plan:** a separation tool that makes a connected pair independent
  (Melodyne's Separation tool bracket, F25). In this model, separating means moving
  a **source** boundary, which is a different edit. Named as follow-up C-F4.

### 3.7 Limits the setter enforces (never the model)

The model only sanitises against NaN (F7), and the field's own doc forbids inventing
a range there (`PitchCorrection.swift:418-423`). Every limit below lives in
`setClipNoteTiming`. A direct field assignment bypasses `NoteSegment.init`, which is
the `setNotePitchClamps` lesson (`ProjectStore+PitchNoteEdits.swift:73-80`). The UI
drag clamps continuously against the **same** function, which is pure and in DAWCore:
`NoteTimingLimits.clamp(request:editSet:ratio:window:sourceDurationSeconds:)`. So the
drag and the wire can never disagree about how far is too far.

1. **The clean-stretch clamp, hard.** For every piece of W that the edit changes (the
   note, and each gap that gives or takes time), `ρ · localFactor ∈ [0.5, 2.0]`.
   Above 2 the vendored engine switches on phase randomisation, so it *chooses*
   smearing. Below 0.5 its time factor is clamped (F2). Both are cliffs [READ]. The
   **gap** matters as much as the note: a 50 ms gap asked to absorb 200 ms would be
   a factor of 5. Novice refusal when the gap binds: "No room: the next note is in
   the way. Move the next note first, or make this one shorter."
2. **The comfort band, soft.** Outside `ρ · localFactor ∈ [0.7, 1.4]` (m23-q's number,
   F28) the readout turns amber: "may sound processed". **This deliberately departs
   from m23-q's "clamp at [0.7, 1.4]".** Lengthening a held last note is the most
   common timing edit there is. A hard stop at +40 % would read to a novice as a
   broken control, and the region between 1.4 and 2.0 sounds processed, not broken.
   The band's edges are **provisional until the listening item C2-L** puts real
   vocal renders at ×1.2, ×1.4, ×1.7 and ×2.0 in front of the user.
3. **Minimum note length.** The edited length must be at least
   `PitchAutoCorrect.minimumNoteSeconds` (0.06 s, F24), the floor the split refusal
   already uses.
4. **The clip window.** Both edited edges must stay inside the clip's visible window
   in edited seconds, `[startOffsetSeconds, startOffsetSeconds +
   sourceWindowSeconds(tempoMap:)]`. The same rule applies on the wire: one command
   surface, one semantics. Refusal: "The clip ends here. Make the clip longer to give
   this note more room."
5. **The file's first 0.1 s** [INFERRED: 60 ms of pre-roll latency plus one 30 ms
   hop]. The pre-roll infers one rate for its whole length (F28), so an edge inside
   it cannot be honoured exactly. The setter refuses to move an edge whose source or
   edited position is under 0.1 s: "This note is too close to the start of the
   recording to retime." A note that starts at source second 0 can never move its
   start (3.2, step 2).
6. **Needs D.** Without `media`, the setter throws `mediaServiceUnavailable`, which is
   the `fitClipToContent` precedent. It never guesses a duration.

When one of limits 1 to 4 binds, the setter **applies the nearest allowed value**. Limits 5 and 6 are refusals. It reports
`clamped: true` and names the binding limit in plain words. It does not refuse,
because a drag must never snap back to where it started. That matches
`setClipNotePitchOffset`'s clamp-and-echo.

### 3.8 Interaction (decision A6)

**Zones on a blob `w` px wide** (F26: Melodyne does not publish its zone sizes, so
these are picks):
- **Edges:** `clamp(0.25·w, 4, 8)` px at each end. **Body:** the rest.
- A blob narrower than 12 px has no edge zones. Hovering one draws "Zoom in to change
  this note's timing" in the help slot. Zoom already exists (C4).
- **Body drag = pitch (C1), unchanged.** Moving a whole note in time is deliberately
  not in this plan. Two edge drags express it, and a body drag that also moved time
  would make every pitch drag wobble sideways for a novice. Named as follow-up C-F5.

**Cursor.** Over an edge zone, `NSCursor.resizeLeftRight`. When that edge is at a
limit in one direction, use the one-way variant. Use the non-deprecated successor if
the installed SDK deprecates these: `Sources/` must stay at zero warnings. Over the
body, today's pointer cursor.

**Snapping.**
- The grid is the **1/16 note**: `SnapResolution.sixteenth`, 0.25 beat. It is never
  `ClipSnap`, whose "1/4" means a quarter **beat** (F21).
- It is **magnetic**. Within 6 px of a grid line, the edge sits on the line and the
  line glows. Elsewhere, the edge follows the pointer.
- **⌥ turns the magnet off.** It is read from `NSEvent.modifierFlags` on every drag
  tick, as C1 does (F20).
- The editor's `1/16` chip (UI design `:915`) is a **real control**. It cycles
  1/8 → 1/16 → 1/32 → Off, and it is held in the editor model, not the project. A
  chip that looked like a control and did nothing would be the fake affordance
  `docs/DESIGN-LANGUAGE.md` Rule 3 forbids. `debug.pitchEditor` reports its value.

**Novice readout** (the palette's existing readout slot, SF Mono, live during the
drag):
- normally: `Starts 40 ms earlier · 1.2× longer`;
- amber band: `… · may sound processed` (in amber);
- a hard limit: the limit's own sentence from 3.7;
- snapped: `… · on the 1/16 grid`.

Times are shown in whole milliseconds.

**Live preview, one commit.**
- The drag lives in the model as a draft, the `PitchEditorDragDraft` pattern.
- Blob, played line (C-0) and W are all computed from the table with the draft
  applied. **Nothing is written to the store during the drag.**
- On release, exactly **one** `setClipNoteTiming` call. A committed edit silences
  the clip until its render lands (F5), and a per-tick commit would silence the
  vocal for the whole drag.
- The readout then says "Rendering… you'll hear it in a moment" until the render's
  pending state clears. The existing pending notice is the signal.

### 3.9 Store, wire and MCP (one command surface)

**Store** (`Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`):

```swift
@discardableResult
public func setClipNoteTiming(clipId: UUID, segmentId: UUID,
                              editedStartSeconds: Double?, editedEndSeconds: Double?,
                              seedIfAbsent: PitchEditSet? = nil) throws -> NoteTimingResult
// NoteTimingResult { clip: Clip; applied: (start: Double, end: Double);
//                    clamped: Bool; limit: NoteTimingLimit? }
```

- It shares `locateEditableNoteClip` (the MIDI and comp-member refusals) and
  `noteTable(…seedIfAbsent:)` (the stored table wins).
- It applies the neighbour rule (3.6) and the limits (3.7). It writes one or two
  segments, then makes one `performEdit("Retime Note", key:
  PitchCorrectionUndoKey.timing(clipID:segmentID:))` and one
  `engine?.tracksDidChange(tracks)`.
- The new `timing` key coalesces within 800 ms like `segment` (F24).

**The split re-derives timing (F9).** In `splitClipNoteSegment`, when the set
`hasTimeEdits`:
- the left half's `timeEndDeltaSeconds` becomes `W(cut) − cut`;
- the right half's `timeStartDeltaSeconds` becomes `W(cut) − cut`;
- the new knot lies on the old piece, so W is unchanged.

This needs D, so the split takes the `media` path only when the set has time edits.
`splitCarriesEveryEditFieldTheParentHad`'s `changeable` set gains the two delta
fields **in the same change**. A physics test takes over the claim: W is unchanged by
the split, to within 1e-12 s, at 1000 probe points.

**Wire** (`Sources/DAWControl/Commands.swift`, additive only):
- **`clip.setNoteTiming`.** Parameters: `clipId`, `segmentId`, and one or both of
  `startSeconds` / `endSeconds`, in edited clip-source seconds. Enforced with
  `rejectUnknownKeys`. The response is `clip.getPitchEdits`'s shape plus
  `timing: {requestedStart, requestedEnd, appliedStart, appliedEnd, clamped, limit}`,
  with a teaching `note` whenever `clamped`.
- **`clip.getPitchEdits`** gains, for each segment, `editedStartSeconds`,
  `editedEndSeconds` and `connectedToNext`. When D is unavailable they are omitted,
  with a `timingNote` saying why.

**MCP** (`mcp-server/src/server.ts`): `clip_set_note_timing`. Its description is
written for an agent that has never seen edited seconds. It says: read
`editedStartSeconds` from `clip_get_pitch_edits`; the numbers are clip-source seconds
before the clip's own stretch; a connected neighbour moves too; clamps are reported,
never silent.

### 3.10 Failure modes

1. **Stale audio for a set that already carries deltas.** Fixed by the suffix (3.5).
2. **A retimed edge lands late or early.** `L_w` is measured with a landing budget
   (C2-2), never derived.
3. **Untimed clips drift by a bit.** Structural nil paths (3.4, steps 3 and 4), with
   the existing byte goldens plus the three pinned legacy digests (C2-1).
4. **Non-monotone W from hand-written JSON leads to a negative `inBlock`, which is
   undefined behaviour in `css_process`.** The heal (3.2, step 4) prevents it, and
   the loop's clamp makes it impossible. An adversarial-JSON test (C2-1) and an
   `inBlock ≥ 0` assertion inside the loop pin both. A healed set is reported
   through `PitchTimeWarp.healed`: the render posts a notice and the editor shows a
   caption. The adjustment is never silent (mode 5).
5. **The display and the render disagree on D, or one site has no D.** One
   expression, pinned by test (C2-1). A site with time edits but no D says so (a
   render notice or a `PanelRefusalLine`), and never renders or draws the set as if
   it were untimed.
6. **The clip's ratio changes after a retime,** so the product leaves [0.5, 2.0]. No
   silent re-clamp: that would rewrite the user's edit behind their back. The editor
   draws the out-of-range note's readout in red: "sounds smeared at this clip speed".
7. **Compression shortens the pitch ramp below the renderer's one-hop floor.** The
   audible ramp is `ρ · localFactor · retuneMs`, down to 15 ms at the clamp. [INFERRED]
   This is pre-existing for any clip stretched below 1. C2-3 measures the level dip
   of a 2-semitone step across a boundary compressed to 0.5 against an uncompressed
   one. If it is more than 2 dB worse, the curve widens that gate's half-ramp in
   source time by `1/(ρ·f)` (a new `PitchRenderContour.shapingVersion`-style bump,
   named at that time).
8. **Every release re-renders the whole file** (F5), so a long take goes silent for
   seconds after each edge drag. Out of scope. The readout says so honestly (3.8).
9. **Take-lane clips cannot be retimed** (F23). The setter's not-found error is
   inherited. Follow-up C-F2.
10. **A preset silently discards hand retiming** (F22). This becomes item C-F3, and
    C2-5 depends on it: the UI must not ship retiming while one menu click erases
    it.
11. **Time-stretch quality on a real voice is the open E2 risk of m23-q**
    (`m23-q-pitch-correction-design.md:23`). Only a listening pass (C2-L) closes
    it, and no gate can.

### 3.11 Render thread, platform and Xcode

- **Render thread:** untouched. W is evaluated in the offline render task
  (`performRender`, detached), in the store (main actor, pure arithmetic) and in the
  editor (main actor). The audio render thread still plays a rendered file through
  the unchanged playback graph. The offline loop's buffers are allocated before the
  loop, as today. None of this is a real-time constraint, because none of it is the
  render thread.
- **Platform:** plain Swift, SwiftUI and AppKit cursors on macOS 14. No entitlements,
  no AUv3, no signing. **Nothing here needs full Xcode.**

---

## 4. Item C-0: the editor draws the curve the render plays (lands FIRST)

### 4.1 The defect, the decision, and the alternatives that lose

**Seen by eye.** A note moved up a semitone draws as an empty green bar on the new
row. Its wobble stays behind in the dashed ghost on the old row. The audio, though,
plays the wobble at the new pitch. The picture disagrees with the sound. There are
three causes:
- the line is the **detected** contour (F16);
- the clip's transpose is ignored (F17);
- the line comes from a **different analysis** than the render's (F18).

**Decision.** The editor draws the **played line**: the render's own contour (the
seam), passed through the render's own curve function. The ghost becomes an outline
only, marking "where it was sung".

**Alternative 1: keep the editor's window detection and add the curve to it.** It
loses. The line would then have the right shape but come from a different analysis.
F18 reports 16 of 2004 frames flipping voicing, so holes would appear or vanish in
places the render does not have them.

**Alternative 2: re-detect the rendered audio and draw that.** It loses. It is only
available after the render lands, so there is nothing to draw while the clip is
silent and pending (F5). It costs a detection per edit. And it cannot show a live
drag.

### 4.2 One pure function: `PitchPlayedLine` (DAWCore)

**Home:** a new file, `Sources/DAWCore/PitchPlayedLine.swift`. The editor model and
the wire verb (4.5) both call it, so the editor and an agent see one line.

```swift
public struct PitchPlayedLine: Sendable, Equatable {
    public enum Basis: Sendable, Equatable {
        case render                   // the seam answered .detected
        case estimate(reason: String) // the seam had no frames; see below
    }
    public struct Point: Sendable, Equatable {
        public var sourceSeconds: Double  // frame CENTRE (see "x position")
        public var editedSeconds: Double  // W(sourceSeconds); equal to it until C2
        public var sungMidi: Double
        public var playedMidi: Double     // sungMidi + curve.semitones(atSourceSecond:)
    }
    public let runs: [[Point]]            // one per voiced run: the hole rule
    public let curve: PitchCorrectionCurve
    public let basis: Basis
    public var unresolvedSegmentIDs: [UUID] { curve.unresolvedShapingSegmentIDs }

    public static func make(contour: PitchRenderContour,
                            fallback: PitchDetectionResult?,
                            editSet: PitchEditSet?,
                            clipPitchShiftSemitones: Double,
                            sourceWindow: Range<Double>) -> PitchPlayedLine
}
```

**The curve.** `curve = contour.curve(editSet: editSet ?? .empty,
clipPitchShiftSemitones: clipPitchShiftSemitones)`. Call it for **every** contour
case, not only `.detected`. [READ, then INFERRED; pinned by test 1 in 4.6] This one
call equals the curve the render builds in all three cases:
- **Detected contour, some note shapes against it.** The render calls the same
  function with the same contour (`performRender`, F19).
- **Detected contour, no note shapes against it.** The render passes `contour: nil`
  and gets `PitchCorrectionCurve.make(editSet:clipPitchShiftSemitones:)`. Inside
  `make`, the contour and its offset are read only for segments with
  `wantsContourShaping`, so the result is the same value.
- **Not `.detected`.** `frames` is `[]` and `frameValueOffsetSeconds` is 0 (F19). The
  call reduces to exactly the render's nil-contour fallback.

C2-1 later adds `timeWarp:`, and C2-5 passes it (3.2).

**The sung line.**
- `.detected`: the contour's frames, cropped to `sourceWindow`, extended by one
  frame on each side.
- Otherwise: `fallback`, which is the editor's existing windowed detection
  (`detectClipPitch`), with basis `.estimate`.
- If there is no fallback either, `runs` is `[]` and the basis is `.estimate`.

The runs come from `PitchAutoCorrect.voicedRuns(in:frameRateHz:)`, the one home of
the hole rule. There is one polyline per **run**, never one per note: a split puts
two notes in one run, and the line must not break at the cut (the rule
`PitchEditorModel.apply` already follows).

**The x position moves from the frame start to the frame centre.**
`sourceSeconds = frame.timeSeconds + contour.frameValueOffsetSeconds`. For the
estimate basis, use `0.5 / frameRateHz`, which is the same formula. The render places
each value at the frame centre, a **measured** 8.58 ms lead (F19, `make`'s doc).
Evaluating the curve anywhere else draws an interpolated shaping value the render
never plays. The visible shift is about 8 ms, under 2 px at the editor's default
zoom. `PitchEditorContourPoint.sourceSeconds` keeps its documented "frame start"
meaning wherever it is still used. The played line is a new type, not a silent
change to the old one.

**`playedMidi = sungMidi + curve.semitones(atSourceSecond: sourceSeconds)`.** The
curve already includes the clip transpose, because it **subsumes** it (F17). So this
one expression fixes F16 and F17 together.

**Cost (F11).**
- Build once per change of table, draft, transpose, contour or window, and cache the
  result in the model.
- Measure a 450-note, 5-minute fixture and quote the number.
- If a release build takes more than 8 ms, turn `PitchCorrectionCurve.make`'s
  per-segment `voiced.filter` into a binary-searched slice. That selects identical
  frames, and the existing byte goldens guard it (route: audio-dsp-engineer). Do not
  optimise before measuring.

### 4.3 The store door, the provider, the load order

**Store** (new file `Sources/DAWCore/ProjectStore+PitchRenderContour.swift`):

```swift
public struct PitchRenderInputs: Sendable, Equatable {
    public var contour: PitchRenderContour
    public var sourceDurationSeconds: Double?   // nil without `media`; see 3.10 mode 5
}
public func renderPitchContour(clipId: UUID) async -> PitchRenderInputs
```

- `analysisVersion` is `clip.pitchEdits?.analysisVersion ??
  PitchEditSet.currentAnalysisVersion`, which is the seam's documented contract
  (F19).
- The URL is `clip.audioFileURL`.
- No engine gives `.unavailable(reason: "no audio engine is running")`. No URL gives
  `.unavailable(reason: "this clip has no audio file")`. It never throws.

**View** (`Sources/DAWApp/PitchEditor/PitchEditorView.swift`): a second provider,
`renderContour: (UUID) async -> PitchRenderInputs`, sits beside `detect:`. Wire it
at the existing construction site (`Sources/DAWApp/ContentView.swift:983`) to
`store.renderPitchContour(clipId:)`.

**Load order:**
1. `detect:` runs as today. It seeds the note table and is the fast path.
2. `renderContour:` runs in parallel.
3. Until step 2 answers, the line is built with basis
   `.estimate("Matching the line to the sound…")`.
4. `.detected` rebuilds it with basis `.render`. Any other answer keeps the estimate
   and shows the reason (4.4).
5. A late answer for a previous clip is dropped by the model's existing
   `loadGeneration` token.
6. Fetch again only when the clip's file or its set's `analysisVersion` changes. The
   contour is a function of the file and the detector alone, **never** of the edits.

### 4.4 What to draw

| Element | Data | Drawing |
|---|---|---|
| Played line | `PitchPlayedLine.runs`: x from `editedSeconds`, y from `playedMidi` | today's contour stroke (`textPrimary` 1.5 px over a 5 px halo, `drawContour`) |
| Blob | edited edges; centre `editedCentreMidi + clipPitchShiftSemitones` | as today |
| Ghost (edited notes only) | the sung centre `+ clipPitchShiftSemitones`, at the **unedited** edges | dashed outline and link, as today. **No line inside.** The user saw the wobble "left behind" as the defect. |
| Estimate basis | the same line | `textPrimary` at 45 %, plus the reason in `PanelRefusalLine` |
| Unresolved notes (`unresolvedSegmentIDs`) | blobs whose id is in the list | an amber dashed outline on the blob, plus one caption |

**Why the ghost includes the clip transpose.** The ghost answers "how far did **I**
move this note". A whole-clip transpose is not a per-note edit, and it has its own
control. Drawing every ghost a transpose away from its blob would put a false edit
on every note.

**Captions**, drawn in the palette's `PanelRefusalLine` slot. Each states the
consequence, never only the cause:
- **`.detected`, but some notes unresolved** (fewer than two voiced frames): "3 notes
  have no steady pitch the app could hear, so their wobble setting can't change them.
  Their pitch moves still play."
- **`.analysisVersionMismatch`:** "These notes were found by an older version of the
  app, so wobble changes can't be applied to them. Pitch moves still play." The line
  is drawn as an estimate rather than left empty: the render plays the sung audio
  plus the constant offsets, and today's detector's reading of the sung audio is an
  honest picture of that. A re-detect action that keeps hand edits is follow-up
  C-F6.
- **`.unavailable(reason)`:** "The app couldn't analyse this recording (reason), so
  wobble changes can't be applied. Pitch moves still play."

**Also in C-0:**
- **Transpose, in both directions (F17).** `PitchEditorGeometry` gains
  `clipPitchShiftSemitones`. Rows, note names, snap targets and `autoFitMidiRange`
  use the drawn pitch. The C1 drag converts back through **one** DAWAppKit function:
  `storedOffsetCents = (drawnMidi − clipPitchShiftSemitones − centreMidi) × 100`.
- **The live draft.** During any drag, the model builds `PitchPlayedLine` from
  `noteTable` with the draft applied. That is a value copy with the dragged field
  set to the draft value, passed through the same `make`. There is no commit until
  release (F5).
- **`debug.pitchEditor` spy.** It gains:
  - `clipPitchShiftSemitones`;
  - `playedMidi` for each note (the drawn centre);
  - `playedLine: {basis, reason, unresolvedNoteIds, perNote: [{id, minMidi,
    medianMidi, maxMidi}]}`;
  - a fix to `edited`, so it reads "any per-note field differs from default"
    through a new `NoteSegment.isEdited`, not `pitchOffsetCents` alone.

  This is dogfood. It is not the gate.

### 4.5 The wire: agents see what the editor draws

`clip.getPlayedPitch` takes `{clipId, fromSeconds?, durationSeconds?, maxPoints?}`
and returns `{basis, reason?, unresolvedNoteIds, runs: [[{sourceSeconds,
editedSeconds, sungMidi, playedMidi}]]}`.
- It is headless: the store door plus `PitchPlayedLine.make`, with no UI.
- `maxPoints` defaults to 2000 and decimates evenly. A window gives full resolution.
- MCP: `clip_get_played_pitch`, "the pitch this clip will actually play, frame by
  frame, after every edit".

This lets an agent **assert the physics** of an edit, not just its audibility. That
is the tree's standing lesson: audibility is not correctness.

### 4.6 Tests (the in-process equality is the gate)

**File:** `Tests/DAWEngineTests/PitchEditorDisplayMatchesRenderTests.swift`, with
`@testable import DAWEngine`, `DAWAppKit` and `DAWCore` (F28). Every test lists the
defect planted to prove it can fail. The defect must be shown red, then reverted.

**The fixture.**
- A synthetic `PitchDetectionResult` with a 5.5 Hz, ±40 c vibrato over three voiced
  runs, and an unvoiced hole between runs 2 and 3.
- Note A: `pitchOffsetCents: 100`. Note B: `vibratoScale: 0`, so it needs the
  contour. Note C: generator, 6 Hz, 40 c.
- `pitchShiftSemitones: 2`, `stretchRatio: 1.25`, and
  `analysisVersion = currentAnalysisVersion`.

**The tests.**
1. **`displayCurveIsTheRenderCurve`.**
   - Setup: `let p = StretchRenderCache.Params(clip: clip)` and
     `let render = StretchCurvePlan.make(editSet: p.pitchEdits,
     clipPitchShiftSemitones: p.semitones, sampleRate: 48_000, ratio: p.ratio,
     contour: fallback ? nil : contour)!.curve`. The contour argument mirrors
     `performRender` exactly.
   - Check: `#expect(model.playedLine.curve == render)`.
   - Repeat for `.detected`, `.analysisVersionMismatch` and `.unavailable`. For the
     last two, also check `unresolvedSegmentIDs == [B.id]`.
   - **Identity leg.** This is the first thing a novice does: open the editor on a
     transposed clip (`pitchShiftSemitones: 2`) and touch nothing.
     `Params(clip:).pitchEdits` is nil, `StretchCurvePlan.make` returns nil, and the
     render takes the constant path at 2 semitones. There is no render curve object
     to compare, so assert values: every played point is exactly `sungMidi + 2`.
     Plant: the display skips the transpose when the set is identity.
   - Plants, each separately:
     (i) the display builds with `PitchCorrectionCurve.make(editSet:
     clipPitchShiftSemitones:)` and no contour, which goes red on `.detected`;
     (ii) the display passes `clipPitchShiftSemitones: 0`;
     (iii) after C2-5, on a retimed fixture, the display omits `timeWarp`.
2. **`drawnPointsAreThePlayedPitch`.**
   - Check, for every point, all three of these exactly:
     `sourceSeconds == frame.timeSeconds + contour.frameValueOffsetSeconds`;
     `playedMidi == sungMidi + render.semitones(atSourceSecond: sourceSeconds)`;
     the drawn y is `geometry.y(forMidi: playedMidi)`.
   - Plant: evaluate at the frame start. It goes red on B, whose shaping is
     interpolated there.
   - "Exactly" is against the curve's one-argument form, which is what the display
     calls. After C2-5 the render calls the two-argument form with `(W⁻¹(e), e)`,
     and `W(W⁻¹(e))` is not bit-identical to `e`. So any later test that compares
     display samples with render-path samples on a **generator** note uses a
     tolerance of 1e-9 semitones, and says why.
3. **`seamIsCalledWithTheRenderArguments`** (a spy).
   - Setup: a fake `AudioEngineControlling` records `renderPitchContour`, and the
     set's `analysisVersion` is 0, not the current version.
   - Check: the URL is `clip.audioFileURL` and the version is 0.
   - Plant: the door passes `PitchEditSet.currentAnalysisVersion`.

**In `Tests/DAWAppKitTests/`:**

4. **`draftMovesTheLine`.**
   - Setup: a +100 c draft on A.
   - Check: every point where A's gate is 1 moves by exactly 1.0 semitone; B's and
     C's points are unchanged; release makes one commit.
   - Plant: build the line from the stored table instead of the draft.
5. **`transposeIsDrawnAndUndrawn`.**
   - Setup: a shift of +2.
   - Check: the drawn row is `centre + offset + 2`, and a drag to drawn row R stores
     `(R − 2 − centre) × 100`.
   - Plant: drop the `− 2`.
6. **`holesStayHoles`.**
   - Check: the hole between runs 2 and 3 is a **geometric** gap in the drawn
     polylines, not only a count.
   - Plant: join the runs into one polyline.
7. **`estimateIsSaidOutLoud`.**
   - Setup: `.unavailable` plus a fallback.
   - Check: the basis is `.estimate` and the caption is on screen. This is a
     `view.capture` site test: a tooltip would be invisible to it (the palette's own
     rule).
   - Plant: hard-code `.render`.

**Timing measurement.** Build time for the 450-note, 5-minute fixture, recorded in
the test's output and asserted under a generous debug bound (50 ms). The release
figure is quoted in the close record.

**Routes:**
- **C-0a** (DAWCore `PitchPlayedLine`, the store door, tests 1–3): swift-app-engineer.
- **C-0b** (editor model and view, the transpose, the draft, the captions, the debug
  spy, tests 4–7): ui-design-engineer.
- **C-0c** (`clip.getPlayedPitch` and `clip_get_played_pitch`): mcp-integration-engineer.

---

## 5. Design B: freehand reshaping (C5b, ⌘-drag)

### 5.1 The decision, and the two alternatives that lose

**Decision.** A reshaped note stores a **delta**: cents to add to whatever the note
already plays. It is stored densely on a global 10 ms source-time grid, quantised to
0.1 cent. It is one more term in the curve's sum, inside the note's gate. The render
needs nothing to play it except the stored numbers.

**Alternative 1: store the absolute line the user drew, and replace the sung pitch
with it.** It loses. Replacing is `− sung(t) + drawn(t)`, and `− sung(t)` needs the
detected contour at render time. So a drawn note would:
- join the contour key;
- fall back when the contour is unavailable;
- then sound different from the picture, with nothing but a notice to say so.

The model already rules that replacement is a **composition** (the generator banner,
`PitchCorrection.swift:913-918`). To replace a sung wobble with a drawn line, flatten
it (C5a, `vibratoScale: 0`), then draw.

**Alternative 2: sparse control points (a spline).** It loses on the user's own words:
"not just some dots". A spline would turn every stroke into a fitting problem whose
answer depends on the fitter, and a hand-drawn wiggle would be smoothed away.
Control points survive as a **wire input form** (5.7), because an agent thinks in
points. They are resampled onto the grid, and the grid stays the stored truth.

### 5.2 The representation (decision B1)

The fields are flat, on `NoteSegment`:

```swift
/// Grid index of `shapeTenthsOfCents[0]`. Source second of sample k is
/// Double(shapeStartIndex + k) / NoteSegment.shapeGridHz. 0 when there is no shape.
public var shapeStartIndex: Int
/// The drawn delta in tenths of a cent, one sample per grid step. Empty means no shape.
public var shapeTenthsOfCents: [Int16]
public static let shapeGridHz: Double = 100
public static let shapeCentsRange: ClosedRange<Double> = -1200...1200
public var hasShape: Bool { !shapeTenthsOfCents.isEmpty }   // the ONE predicate
```

- **Why flat, not a nested `NoteShape` struct.** `digestCoversEveryStoredField` takes
  its census with a flat `Mirror` over top-level labels (F8). A nested struct would
  be one label, and a field added to it later would pass the census unseen. Flat
  fields keep the census honest without new test machinery.
- **Why a global grid anchored at source second 0.** Four operations become index
  operations with no resampling:
  - C3's split slices the array at an index;
  - `canonical`'s first-wins truncation of a later note's start leaves every sample
    at its own time;
  - C2's retiming never changes a note's source span, so it never touches the array;
  - two sessions that draw at the same positions get the same indices.

  This is the same defensive argument that anchors the generator's phase at source
  second 0 (`PitchCorrection.swift:931-943`).
- **Why 10 ms.** It is finer than the detector's frame (16 ms) and the renderer's
  hop (30 ms), so the representation is never the bottleneck. It is coarse enough to
  keep a fully reshaped vocal small (5.4). This is a pick, not a measurement.
- **Why 0.1 cent, and `Int16`.**
  - Stored values sit on a fixed lattice, so the same stroke gives the same bytes,
    the same digest and the same render key.
  - The quantum is 130 times finer than the 13-cent readout floor (UI design §7.4),
    so quantising is inaudible [INFERRED].
  - `Int16` tenths hold ±3276.7 c. The range is clamped to ±1200 c, because an
    octave move is what `pitchOffsetCents` is for.
- **Sanitising, in `NoteSegment.init`, including the decode path:**
  - clamp every sample to ±12 000 tenths;
  - with an empty array, force `shapeStartIndex = 0`.
- **Normalising, in the setter (5.7):**
  - trim the array to the note's grid span,
    `i ∈ [ceil(start·100), ceil(end·100) − 1]`;
  - store an all-zero array as empty.
- **Codable.** Both keys are omitted when the array is empty, as the time deltas are
  at 0 (F7), so every existing project encodes byte for byte as before.
- **`isIdentity` gains `&& !hasShape`.** ⛔ Leaving this out is the silent failure of
  this whole item. A shape-only set would hash to `""` and take the identity bypass
  (F19: `Params.isIdentity`), so the clip would play unshaped while every setter
  echoed success. Test C5b-2 plants exactly this.
- **`wantsContourShaping` is unchanged.** A shape needs no contour, so a shape-only
  set keys without `contour:` or `shaping:` (F19) and renders the same whether or not
  detection is available.

### 5.3 Composition and precedence (decision B2)

Inside a note's gate, the evaluator sums four terms:

```
contribution = constant                // pitchOffsetCents / 100            source time
             + shaping(s)              // (drift|vibrato scale − 1) × contour source time
             + generator(e ?? s)       // C5a synthesised vibrato             EDITED time (3.4)
             + shape(s)                // C5b drawn delta, this section       source time
```

- **`shape(s)`** is linear interpolation at grid position `s·100 − shapeStartIndex`,
  held at both ends (the convention `shaping` already uses,
  `PitchCorrection.swift:1246-1256`), in semitones (tenths ÷ 1000). It is precomputed
  per span in `make`, like the other terms.
- **Structural branch.** The term is added only when the span's shape is non-empty.
  That is the generator's rule, so every shape-free curve is bit-identical to today's
  (the `-0.0` lesson, 3.4).
- **Source time, because the user drew it against the sung audio.** Retiming (C2)
  moves and stretches it together with that audio. The synthesised generator is
  different: it is a rate the user chose, so it runs in edited time (F10, 3.4).
- **With `pitchOffsetCents`:** the terms add. A C1 drag carries the drawn shape along
  with the note. The shape's mean is **not** folded into the offset. Folding would
  rewrite a field the user did not touch, and the result would depend on an
  arbitrary estimator. So the blob shows the note's tuning and the line shows the
  drawing, and C-0 draws both truthfully.
- **With the drift and vibrato scales:** the terms are independent. When the contour
  is unavailable, the scale terms drop out (unresolved) and the drawn shape still
  plays. The C-0 line shows exactly that.
- **With the generator:** both add. This is the "override + generator" rule the
  model's extension seam asked for (`PitchCorrection.swift:944-950`).
- **The brush writes the delta relative to the line the user currently hears (5.5).**
  So the drawn line lands where the pointer was, whatever else the note carries.
- **The split (C3).** The left half keeps the samples with index below
  `ceil(cut·100)`, and the right half keeps the rest. It is an index split, with
  `splitCarriesEveryEditFieldTheParentHad`'s `changeable` set widened in the same
  change (F9). The physics test states the one honest exception:
  - the shape term at 1000 probe points is unchanged by the split, to 1e-12;
  - **except** inside the one grid step that straddles the cut. There each half's
    held end replaces the interpolation across the cut, so the difference is bounded
    by the step between the two samples beside the cut.
  - F12's gate dip at a split is separate, and is not tested here.
- **`canonical` truncation.** A truncated start leaves samples before the new start
  in storage. They are harmless: they were drawn at those times, and the next write
  trims them.

### 5.4 The digest, and persistence

**The suffix block** is appended after the time-warp suffix. The order is fixed:
generator, then warp, then shape. Each block is introduced by its own marker and
emitted only when some segment uses its feature. So if C5b lands before C2 and the
warp block is inserted between the other two later, no set's digest changes unless
the set has time edits. Those sets must re-key anyway (3.5). C5b-1's dependency on
C2-1 is therefore soft: merge order only.

```swift
if set.segments.contains(where: \.hasShape) {
    putBits(shapeSuffixMarker)                       // a new distinctive constant
    putInt(set.segments.count)
    for segment in set.segments {                    // EVERY segment, as the generator suffix does
        putInt(segment.shapeStartIndex)
        putInt(segment.shapeTenthsOfCents.count)     // count BEFORE contents: no ambiguity at boundaries
        for v in segment.shapeTenthsOfCents { putInt(Int(v)) }
    }
}
```

- **The census** (`digestCoversEveryStoredField`) adds both labels. On its own it can
  see only the labels (F8). So a second test, `digestCoversEveryShapeSample`, changes
  the digest in each of these ways:
  - +1 tenth on the first, a middle and the last sample of each of three segments;
  - one sample moved between two segments, with the total count unchanged;
  - `shapeStartIndex` changed by 1.
  **Plant:** hash only the count. The census stays green and this test goes red,
  which is why it exists.
- **A shape-free set** produces byte-identical material, so every cache entry on
  every disk survives. `layoutVersion` stays 1 (F8).
- **Size [INFERRED arithmetic].** JSON `Int16` samples average about 4 bytes each.
  - Fully reshaped, a 3-minute vocal about 60 % voiced is 10 800 samples, about
    45 KB in `.dawproj`.
  - A typical session reshapes a handful of notes, which is a few KB.
  - The format needs no binary blob and stays readable to agents.

### 5.5 Interaction: the brush (part of decision A6)

**Starting a stroke.**
- A stroke starts with ⌘-drag in the Move tool, or any drag in the Shape tool (5.6).
- ⌘ is read **at mouse-down**. Releasing ⌘ mid-stroke does not change the gesture.
- A stroke may cross notes. It writes into every note whose span it passes over and
  does nothing in the gaps, because gaps hold no segment and no pitch (the hole
  rule).

**The kernel.**
- The radius is 12 px on screen, converted to seconds at mouse-down with the
  current zoom. The brush therefore feels the same at every zoom level.
- The weight is a raised cosine, `w(Δ) = 0.5·(1 + cos(π·Δ/R))` for `|Δ| < R`. It is
  1 at the centre and falls to 0 with zero slope at the edge, so there is no corner
  where the brush ends.
- A faint band `2R` wide follows the pointer while ⌘ is held, showing where a stroke
  would act.

**Accumulating a stroke.**
- Between two pointer ticks, the path is interpolated at grid resolution, so a fast
  drag leaves no gaps.
- Each grid sample `i` keeps `w_i` (the **maximum** weight the stroke gave it) and
  `target_i` (the pointer's pitch at that moment; on a tie, the latest wins). Going
  back over a place re-aims it and never double-applies.
- Pressing on a peak and dragging straight up or down is one point with a moving
  target. That is "pull tops or bottoms up or down", in the user's own words.

**On release, and only on release** (F5; UI design §7.4: "a brush drag is the worst
possible case for per-tick commits"):
- `shape_i ← shape_i + w_i · (target_i − played_i)`, where `played_i` is the
  **pre-stroke** played line (C-0) at sample `i`'s source second. The sung contour is
  interpolated only inside a voiced run, never across a hole.
- Then quantise, clamp and normalise (5.2).
- One `setClipNoteShapes` call covers every note the stroke touched: one
  `performEdit("Draw Pitch")`.
- The undo key is `structuralKey`, so two strokes are two undo steps, like two cuts.

**While drawing:**
- The played line shows the drafted shape live, through C-0's draft mechanism.
- The readout says `Drawing · moves the line by up to 35 cents`, rounded to 5 c. It is
  an excursion, which UI design §7.4 allows.
- After release: "Rendering… you'll hear it in a moment."

**The brush is disabled while the basis is `.estimate`**, with the caption: "Drawing
needs the app's analysis of this recording. One moment." A delta computed against an
estimate would land off by the estimate's own error (5.8, mode 3).

**Clearing.** The note's context menu has "Reset drawn shape". On the wire, this is
`clear: true` (5.7).

### 5.6 Discoverability for a novice

- **The palette grows a third slot, "Shape"**, with the SF Symbol `scribble`. The
  palette's rule is that it "grows a slot when a tool lands, and never before"
  (`PitchEditorModel.swift:846-852`), and C5b is that tool. Its drawn help: "Drag
  along a note's line to redraw it. Press and drag up or down to pull a peak. Let go
  to hear it."
- **⌘ is the shortcut from Move.** The Move help becomes: "Drag a note up or down to
  change its pitch, or drag its ends to change its timing. Hold ⌘ to draw its line;
  hold ⌥ to move freely."
- **While ⌘ is held:** the help slot shows the Shape help, the cursor becomes a
  pencil, and the brush band appears.

All of this help is **drawn**, never only a tooltip. `view.capture` cannot see a
tooltip, and the palette already follows this rule
(`PitchEditorView.swift:655-657`).

"Let go to hear it" is the one sentence a novice most needs. The clip renders once
per stroke and is silent while it does (F5).

### 5.7 Store, wire and MCP

**Store** (`Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`): one function for
the brush and the wire alike.

```swift
public struct NoteShapeSamples: Sendable, Equatable {
    public var startIndex: Int
    public var tenthsOfCents: [Int16]   // empty = clear
}
@discardableResult
public func setClipNoteShapes(clipId: UUID, shapes: [UUID: NoteShapeSamples],
                              seedIfAbsent: PitchEditSet? = nil) throws -> Clip
```

- It uses the same gates as the other per-note setters.
- An unknown segment id is refused with the note count, through the existing
  `segmentIndex` teaching error.
- It trims, clamps and normalises (5.2), then makes **one** `performEdit` for all the
  segments and one `tracksDidChange`.

**Wire:** `clip.setNoteShape` takes `{clipId, segmentId, points?, clear?}`, with
exactly one of the two.
- `points: [{seconds, cents}]` are sparse points in **source** seconds. They are
  interpolated linearly onto the grid between the first and last point. The note's
  shape outside that span is left as it was.
- The response is `clip.getPitchEdits`'s shape.
- `clip.getPitchEdits` gains, for each segment, `shape: {startSeconds, stepSeconds:
  0.01, cents: [...]}`.
- The setter uses `rejectUnknownKeys`, and the change is additive only.

**MCP:** `clip_set_note_shape`: "Redraw part of a note's pitch line. Give points
(seconds, cents). The line between them moves by that many cents, on top of
everything else the note does. Check the result with clip_get_played_pitch."

### 5.8 Failure modes

1. **Shape missing from `isIdentity`.** The clip takes the identity bypass and plays
   unshaped with a success echo. Planted in C5b-2.
2. **Digest hashes the count only.** An interior edit serves stale audio. Caught by
   `digestCoversEveryShapeSample` (5.4).
3. **Brush against an estimate.** Prevented: the brush is disabled while the basis is
   `.estimate` (5.5).
4. **Detector upgrade** (`analysisVersion` bump). The shape is a delta and needs no
   contour, so it still plays identically. The sung line may redraw slightly
   differently, because it is a new detector's reading of the same audio.
5. **A split inside a drawn shape.** The held ends differ by at most one grid step
   across the cut (5.3). The pre-existing gate dip at a split is F12.
6. **Silence per stroke** (F5), the same cost as every committed edit. It is said out
   loud (5.6).
7. **Not in this plan:** a **smoothing** brush (⌘⌥-drag, where the target is the local
   average of the played line). C5a's flatten is the parametric answer to "smooth".
   A smoothing brush is follow-up C-F7. Brush-radius control is also deferred.

**Render thread and Xcode:** as 3.11. The term is evaluated in the offline render
task. Nothing here needs full Xcode.

---

## 6. Implementation plan

**Standing rules for every item:**
- Run `./scripts/test.sh`, never bare `swift test`.
- **Every planted defect is applied, shown red, and reverted**, and the red run is
  quoted in the close record. A test that has never failed has not been shown to
  test anything.
- A "looked-at" gate means `view.capture` on **staging (port 17695), never 17600**,
  which is the user's live app, plus a person-readable description of what the frame
  shows.
- Every capability ships with its store function, wire verb, MCP tool and tests.
  Wire and MCP changes are additive only.
- Tick `docs/ROADMAP.md` when an item lands.

**Order:**

```
C-0a ─┬─ C-0b ───────────────────────────────┬─ C2-5 ── (C2 done)
      └─ C-0c                                │
C2-0 (independent, red first)                │
C2-1 ─┬─ C2-2 ── C2-3 ── C2-L                │
      ├─ C2-4 ─┬─ C2-4w                       │
      │        └────────────────────────────────┤
      ├─ C2-6                                 │
      └─ C2-7 (also needs C2-4)               │
C-F3 ────────────────────────────────────────┘
C5b-1 (C2-1: soft) ─┬─ C5b-2
                    └─ C5b-3 ── C5b-4 (also needs C-0b)
```

### C-0: the display draws what the render plays (FIRST)

**C-0a. `PitchPlayedLine` and the store door.**
- **Depends on:** the seam, which has landed (F19).
- **Route:** swift-app-engineer.
- **Files:**
  - `Sources/DAWCore/PitchPlayedLine.swift` (new);
  - `Sources/DAWCore/ProjectStore+PitchRenderContour.swift` (new);
  - `Tests/DAWEngineTests/PitchEditorDisplayMatchesRenderTests.swift` (new, tests 1–3
    of 4.6, at the `PitchPlayedLine` level).
- **Planted, red:**
  - build the curve with `PitchCorrectionCurve.make(editSet:clipPitchShiftSemitones:)`
    and no contour (test 1, `.detected` leg);
  - the door passes `currentAnalysisVersion` (test 3).

**C-0b. Editor model and view.**
- **Depends on:** C-0a.
- **Route:** ui-design-engineer.
- **What:**
  - the played line;
  - the transpose, in both directions;
  - the ghost as an outline only;
  - the captions and the amber unresolved treatment;
  - the draft line;
  - the second provider;
  - `debug.pitchEditor` fields, with `NoteSegment.isEdited` for its `edited` flag.
- **Files:**
  - `Sources/DAWAppKit/PitchEditorModel.swift`;
  - `Sources/DAWApp/PitchEditor/PitchEditorView.swift`;
  - `Sources/DAWApp/ContentView.swift` (the provider, near `:983`);
  - `Sources/DAWApp/PitchEditorDebugStaging.swift`;
  - `Sources/DAWCore/PitchCorrection.swift` (`isEdited` only);
  - `Tests/DAWAppKitTests/PitchEditorPlayedLineTests.swift` (new, tests 4–7);
  - the model-level leg of test 1 in the C-0a file.
- **Planted, red:**
  - the line built from the stored table instead of the draft (test 4);
  - drop the `− clipPitchShiftSemitones` (test 5);
  - one polyline across a hole (test 6).
- **Looked-at gate:** the user's reported case, a note moved up a semitone. Its
  wobble must be drawn inside the moved blob, and the ghost must be an empty dashed
  outline.

**C-0c. `clip.getPlayedPitch` / `clip_get_played_pitch`.**
- **Depends on:** C-0a.
- **Route:** mcp-integration-engineer.
- **Files:**
  - `Sources/DAWControl/Commands.swift`;
  - `mcp-server/src/server.ts`;
  - `Tests/DAWControlTests/PlayedPitchCommandTests.swift` (new);
  - `mcp-server/test/pitch-correction.test.ts`.
- **Planted, red:** the verb builds its own curve without the clip transpose. The
  test compares its output with `PitchPlayedLine.make` on the same clip.

### C2: per-note timing

**C2-0. Split and trims divide timeline seconds by the ratio (F13). RED FIRST.**
- **Depends on:** nothing. It can run alongside C-0.
- **Route:** swift-app-engineer.
- **Files:**
  - `Sources/DAWCore/ProjectStore.swift` (`splitClip`, `applyTrimWindow`,
    `clipTrimmedToWindow`);
  - `Tests/DAWCoreTests/ClipStretchTests.swift`.
- **Red first:** split a 2× clip 4 s in. The right half's offset must be the left's
  plus 2 s of source. **If that test passes on today's tree, F13 is wrong and the
  item stops.** One test for each of the three sites.
- **Planted after the fix:** remove `/ ratio` at each site in turn. Only that site's
  test goes red.

**C2-1. `PitchTimeWarp`, `hasTimeEdits`, the curve's `timeWarp`, the digest suffix.**
- **Depends on:** nothing, but land it before C5b-1 so the digest's suffix order is
  settled.
- **Route:** audio-dsp-engineer.
- **Files:**
  - `Sources/DAWCore/PitchTimeWarp.swift` (new);
  - `Sources/DAWCore/PitchCorrection.swift` (the predicate, the stored `timeWarp`,
    `semitones(atSourceSecond:editedSecond:)`, the edited-time generator branch);
  - `Sources/DAWEngine/Stretch/StretchCurvePlan.swift` (the suffix);
  - `Tests/DAWCoreTests/PitchTimeWarpTests.swift` (new);
  - `Tests/DAWEngineTests/PitchCurveRenderTests.swift`.
- **Tests:**
  - W is monotone and total, and pins its anchors;
  - the adversarial-JSON heal (crossing intervals, deltas past the file's edges,
    abutting knots with unequal deltas);
  - importer D is bit-identical to the render's D on a fixture file;
  - three legacy digest goldens are unchanged;
  - a delta-carrying set re-keys against its **pre-C2 hex**, which must be captured
    on today's tree **before** the change.
- **Planted, red:**
  - remove the heal (the monotonicity test);
  - remove the suffix (the re-key test);
  - invert the predicate (the legacy goldens).
- **Also:** add the settled per-note timing decision to `docs/ARCHITECTURE.md`'s "Key
  future decisions". This design pass was confined to this file.

**C2-2. The warped input schedule, and MEASURING `L_w`.**
- **Depends on:** C2-1.
- **Route:** audio-dsp-engineer.
- **Files:**
  - `Sources/DAWEngine/Stretch/OfflineStretcher.swift` (the `WarpedInputSchedule`
    branch; `measuredWarpLookaheadFrames`, with its measurement in its doc comment);
  - `Tests/DAWEngineTests/PitchTimeWarpRenderTests.swift` (new).
- **Method:** the burst fixture of 3.4, step 5. The raw path first, then the sweep,
  the fit, and a landing budget at 48 kHz, at 44.1 kHz and at ρ = 1.25.
- **Planted, red:** `L_w = 0`. The landing test fails by the measured lag.

**C2-3. The render reads timing.**
- **Depends on:** C2-2.
- **Route:** audio-dsp-engineer.
- **What:** `StretchCurvePlan` (`sourceDurationSeconds`, the warped
  `sourceSecond`) and `performRender` (passes D and the schedule).
- **Files:**
  - `Sources/DAWEngine/Stretch/StretchCurvePlan.swift`;
  - `Sources/DAWEngine/Stretch/StretchRenderCache.swift`;
  - `Tests/DAWEngineTests/PitchTimeWarpRenderTests.swift`.
- **Tests:**
  - every existing byte golden is unchanged;
  - a retimed note's onset lands within budget;
  - a generator note stretched 1.4× still measures 5.5 ± 0.2 Hz in the output;
  - the compression level-dip measurement of 3.10, mode 7, recorded.
- **Planted, red:**
  - make `PitchTimeWarp.make` return an identity warp for untimed sets. The
    untimed byte goldens go red, because the warped branch is not the linear loop;
  - evaluate the generator in source time. It measures about 3.9 Hz.

**C2-4. The store setter.**
- **Depends on:** C2-1.
- **Route:** swift-app-engineer.
- **What:** `setClipNoteTiming`, `NoteTimingLimits.clamp`, the neighbour rule, the
  `timing` undo key, and re-derivation in `splitClipNoteSegment`.
- **Files:**
  - `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`;
  - `Sources/DAWCore/NoteTimingLimits.swift` (new);
  - `Sources/DAWCore/PitchCorrection.swift` (the undo key);
  - `Tests/DAWCoreTests/PitchNoteTimingTests.swift` (new);
  - `Tests/DAWCoreTests/PitchCorrectionWriterTests.swift` (widen `changeable` in the
    same change, F9).
- **Planted, red:**
  - clamp only the note's factor and not the gap's: a 50 ms gap absorbing 200 ms is
    accepted;
  - turn the neighbour rule off: the connected neighbour's delta stays 0. The heal
    silently hides this, so the test asserts both **stored** deltas, not W;
  - split without re-derivation: the W-unchanged-by-split physics test.

**C2-4w. `clip.setNoteTiming`, the `clip.getPitchEdits` edited seconds, and
`clip_set_note_timing`.**
- **Depends on:** C2-4.
- **Route:** mcp-integration-engineer.
- **Files:**
  - `Sources/DAWControl/Commands.swift`;
  - `mcp-server/src/server.ts`;
  - `Tests/DAWControlTests/PitchNoteTimingCommandTests.swift` (new);
  - `mcp-server/test/pitch-correction.test.ts`.
- **Planted, red:**
  - a clamp applied without `clamped` in the echo;
  - an unknown key accepted.

**C-F3. Warn before a preset replaces hand edits (F22). Gates C2-5.**
- **Depends on:** nothing.
- **Route:** swift-app-engineer for the confirm; mcp-integration-engineer for the
  wire flag.
- **What:**
  - the menu confirms before `autoCorrectClipPitch` replaces a non-identity set: "This
    replaces the tuning, timing and drawn shapes already on this clip.";
  - `clip.autoCorrectPitch` gains an optional `replaceExisting`, **defaulting to
    true**, which is today's behaviour (the additive rule).
- **Files:**
  - the preset menu's view in `Sources/DAWApp/`;
  - `Sources/DAWControl/Commands.swift`;
  - `mcp-server/src/server.ts`;
  - tests.
- **Planted, red:** the menu calls the preset without the confirm on a non-identity
  set (a site test).

**C2-5. The editor's timing UI.**
- **Depends on:** C-0b, C2-4, C-F3.
- **Route:** ui-design-engineer.
- **What:**
  - edge zones, the cursor, the magnetic 1/16 snap and its real chip, ⌥;
  - the readout;
  - the draft through W in the played line;
  - one commit on release;
  - the connection hairline;
  - scissors through `W⁻¹`;
  - the model's new commit kind `noteTiming`.
- **Files:**
  - `Sources/DAWAppKit/PitchEditorModel.swift`;
  - `Sources/DAWApp/PitchEditor/PitchEditorView.swift`;
  - `Sources/DAWApp/PitchCorrectionStaging.swift`;
  - `Tests/DAWAppKitTests/PitchEditorTimingTests.swift` (new), plus site tests.
- **Planted, red:**
  - a commit per drag tick (the `aDragTickNeverCommits` pattern);
  - snap through `ClipSnap` (the 1/16 = 0.25-beat test);
  - the played line without W (C-0 test 1, plant iii).
- **Looked-at gate:** a lengthened note, its neighbour's gap shortened, and the
  readout visible.

**C2-6. The arrange waveform through ρ and W⁻¹ (F14).**
- **Depends on:** C2-1.
- **Route:** ui-design-engineer.
- **Files:**
  - `Sources/DAWApp/Timeline/ClipWaveform.swift`;
  - `TimelineLanesView.swift` and `TakeLanesView.swift` (the construction sites);
  - a pure column-to-source mapping in `Sources/DAWAppKit/` with its tests.
- **Red first:** a 2× clip's column must map to half as many source seconds as
  today's code gives.
- **Planted, red:** drop W on a retimed fixture.

**C2-7. Analysis results: map or refuse (F15, 3.3).**
- **Depends on:** C2-1, C2-4.
- **Route:** swift-app-engineer.
- **Files:**
  - `ProjectStore+TakeAlignment.swift`;
  - `SliceToSampler.swift`;
  - `ProjectStore+Quantize.swift`;
  - `ProjectStore+Analysis.swift`;
  - `ProjectStore+Transcription.swift`;
  - `Clip.timelineSeconds(forSourceSecond:warp:tempoMap:)` in `Sources/DAWCore/`.
- **Census:** re-run the two greps of 3.3 before starting.
- **Planted, red:** revert one converted site to its inline expression. Its
  retimed-fixture test goes red.

**C2-L. Listening: how far can a note stretch?**
- **Depends on:** C2-3.
- **Route:** audio-dsp-engineer renders; the orchestrator publishes.
- **What:**
  - four renders of one held note on a real dry vocal, at ×1.2, ×1.4, ×1.7 and ×2.0.
    That is **one axis**, and the user's pick is the feedback;
  - true peak at or below −1 dBTP, checked alongside loudness;
  - a novice-readable page.
- **Result:** sets the amber band of 3.7.
- **Automated guard:** each option's measured note length equals the requested
  factor times the source length, within a hop.
- **Planted, red:** render all four at ×1.0. The guard must go red, because
  identical bytes prove the axis did nothing.

### C5b: freehand reshaping

**C5b-1. The shape fields, the term, the digest suffix, `isIdentity`.**
- **Depends on:** nothing hard. C2-1 is a soft, merge-order dependency (5.4).
- **Route:** audio-dsp-engineer.
- **Files:**
  - `Sources/DAWCore/PitchCorrection.swift`;
  - `Sources/DAWEngine/Stretch/StretchCurvePlan.swift`;
  - `Tests/DAWCoreTests/NoteShapeTests.swift` (new);
  - `Tests/DAWEngineTests/PitchCurveRenderTests.swift` (census plus
    `digestCoversEveryShapeSample`).
- **Planted, red:** hash the count only. The interior test goes red and the census
  stays green.

**C5b-2. A shape renders.**
- **Depends on:** C5b-1.
- **Route:** audio-dsp-engineer.
- **Files:** `Tests/DAWEngineTests/NoteShapeRenderTests.swift` (new).
- **Tests:**
  - a shape-only set measures +50 ± 5 c in its shaped region;
  - its key carries no `contour:` field;
  - every existing golden is unchanged.
- **Planted, red:** leave `!hasShape` out of `isIdentity`. The identity bypass
  measures 0 c.

**C5b-3. The store and the wire.**
- **Depends on:** C5b-1.
- **Route:** swift-app-engineer for the store; mcp-integration-engineer for the wire
  and MCP.
- **What:**
  - `setClipNoteShapes`;
  - the split slices the array;
  - `clip.setNoteShape` (points or clear);
  - the `clip.getPitchEdits` shape echo;
  - `clip_set_note_shape`.
- **Files:**
  - `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`;
  - `Sources/DAWControl/Commands.swift`;
  - `mcp-server/src/server.ts`;
  - tests in `DAWCoreTests`, `DAWControlTests` and `mcp-server/test/`.
- **Planted, red:** the split copies the whole array to both halves. The **storage**
  test goes red: each half must hold exactly its own grid span. A physics test would
  stay green here, because the global grid makes a whole copy sound right. That is
  why this test asserts storage.

**C5b-4. The brush UI.**
- **Depends on:** C-0b, C5b-3.
- **Route:** ui-design-engineer.
- **What:**
  - the Shape slot and the ⌘ shortcut;
  - the kernel and the band;
  - max-weight accumulation;
  - one commit on release;
  - disabled while the basis is `.estimate`;
  - "Reset drawn shape";
  - the drawn help and the readout.
- **Files:**
  - `Sources/DAWAppKit/PitchEditorModel.swift`;
  - `Sources/DAWApp/PitchEditor/PitchEditorView.swift`;
  - `Sources/DAWApp/PitchCorrectionStaging.swift`;
  - `Tests/DAWAppKitTests/PitchEditorShapeBrushTests.swift` (new).
- **Planted, red:**
  - a commit per tick;
  - summed weights (the idempotent-overdraw test);
  - the brush enabled during `.estimate`.
- **Looked-at gate:** a peak pulled up, with the line and the help visible.

### Follow-ups named by this plan and not scheduled

| Id | What | Why it waits |
|---|---|---|
| **C-F1** | Seed presets and the editor from the render's whole-file contour rather than the windowed detection (F18, F28) | Changes preset boundaries on existing projects. It needs its own gate. |
| **C-F2** | Per-note edits on take-lane clips (F23) | Pre-existing. It affects C1 and C3 today. |
| **C-F4** | A separation tool for connected notes (3.6) | Moves source boundaries, which is a different edit. |
| **C-F5** | Move a whole note in time (3.8) | Two edge drags express it today. |
| **C-F6** | Re-detect while keeping hand edits (4.4) | Needs a carry rule across detector generations. |
| **C-F7** | A smoothing brush, and brush-radius control (5.8) | C5a's flatten answers "smooth" today. |

---

## 7. What needs the user's word

**Already asked on the handoff page. Do not ask again.** Here is how this plan
depends on each answer:
- **Build note-length editing now?** Recommended: yes. If the answer is "not yet":
  - C2-1 to C2-7, C-F3 and C2-L wait;
  - C-0 and C5b go ahead unchanged (C5b-1 simply lands without the warp block ahead
    of it in the digest);
  - C2-0 still ships, because it is a pre-existing bug in clip split and trim.
- **The vibrato drag axis** (recommended: sideways is speed, up and down is width).
  That is C5a's handle. C5b's ⌘-drag brush is a separate gesture anywhere on the
  line, so neither answer changes this plan.
- **What the top-centre dot in the reference screenshots does.** No item here
  depends on it. The only possible conflict would be a zone on the blob, and this
  plan uses only the left and right edges (3.8). If the dot turns out to be a
  separation handle, it becomes follow-up C-F4.

**New questions, each with a default that the plan builds unless told otherwise:**

1. **Should note edges snap to the beat grid by default?**
   - *Recommended default:* yes, gently. An edge sticks to a 1/16 line only when
     dragged within a few pixels of it. Holding ⌥ turns snapping off for one drag,
     and the `1/16` chip can switch it off entirely.
   - *Why ask:* on a vocal recorded without a click track, the grid lines do not
     match the singing, and snapping would pull notes to meaningless places. The
     user knows how they record; the code cannot.
2. **Do you also want to slide a whole note earlier or later in one move?**
   - *Recommended default:* not now. Dragging both of its ends already does it, and
     keeping the note's middle for pitch alone means an up-or-down drag can never
     nudge a note sideways by accident.
   - If yes, it is follow-up C-F5.

**Asked as a listening pick, not as a question:** how far a note can be stretched
before it stops sounding natural. Item C2-L puts four versions of one held note
(×1.2, ×1.4, ×1.7 and ×2.0) on a page. The user picks the last one that still
sounds right, and that sets where the amber "may sound processed" warning starts.
