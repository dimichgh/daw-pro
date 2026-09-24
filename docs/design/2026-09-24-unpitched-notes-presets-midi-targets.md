# Unpitched sounds, the gentle-preset step, tuning to a MIDI melody, and the wobble dot (DESIGN)

Status: DESIGN ONLY, no code. Author: daw-architect ("architect B"), 2026-09-24.

Tags: [READ] = read at the cited `file:line` on 2026-09-24; [MEASURED] = measured, by whom stated;
[INFERRED] = reasoned, not measured; [VERIFIED] / [REPORTED] = a convention claim with / without a
primary source read (§7). Lines move: `PitchCorrection.swift` and `ProjectStore+PitchNoteEdits.swift`
are being edited by S2 right now, so every cite also names its symbol. Re-find by symbol.

**Inputs.**
- The user's words and page answers (brief `user-feedback-2026-09-24.md`).
- `DUR` = `~/Music/DAW Pro Dogfood/2026-09-24 p2-seg physics/` (quote the path: it has spaces).
- "[MEASURED archB]" = my read-only scripts `m1`–`m9` over `DUR/busyline-frames.csv`,
  `DUR/product/s1-detectpitch.json` and the take, held in memory and never written anywhere.
- The scripts live in the session scratchpad `archB/`, which does not survive a reboot; this task
  allowed one file.

**Does not redesign:** p2-seg (`2026-09-24-pitch-note-splitting.md`, being built as S2), C5a
(`2026-09-24-pitch-editor-vibrato-handle.md`), C2/C5b (`2026-09-24-pitch-editor-timing-and-freehand.md`).
It builds on them and names each amendment (§1.4 settles p2-seg §10 item 9; §4 amends C5a §9.3 and re-specifies C5a-F4).

**Invariants.** Render thread: nothing here reaches it. Every audio change is in the offline render job
(`StretchRenderCache.performRender`, a detached task) or on the main actor. DAWCore stays pure: the
three new functions are frames or notes in, segments out. One command surface: every capability below
has a store function, a wire command, an MCP tool and a test. **Nothing here needs full Xcode**,
entitlements, AUv3 or signing.

## §0 Decisions at a glance

| # | Decision | § |
|---|---|---|
| U1 | A no-note frame is **audible** when its `levelDbfs` ≥ **F + 9 dB**, F = the 10th percentile of the clip's own unvoiced frames. Relative to the clip's noise floor: never absolute (0 frames found on the same take 21.5 dB quieter), never "N dB below the singing" (that segments this take's silence). | 1.3 |
| U2 | `NoteSegment` gains one additive field, `origin: .detected / .transition / .unpitched`. Required: a borrowed pitch draws exactly like a detected one, and `detectedHz: 0` draws at A4. It also settles p2-seg §10 item 9 (mark transitions). | 1.4 |
| U3 | An unpitched sound borrows the pitch of the NEARER neighbouring note; a tie (it touches both) goes to the following note, the user's rule. It is a **drawing anchor**, not a pitch estimate, and no neighbour rule fixes a missed sung note (U-F3). | 1.5 |
| U4 | Both note-table builders add unpitched segments after S2's splitter, always as IDENTITY under every preset and shape. The curve skips an untouched one, so every existing render stays byte-identical. Stored tables change only by an explicit pass or merge. | 1.6 |
| U5 | Moving one applies its constant offset: it DOES pitch-shift a breath or an "s" (Melodyne never does). v1 says so on screen; "never transpose unpitched sounds" is follow-up U-F2. | 1.7 |
| U6 | "Remove" silences the selected segments with no ripple (`clip.setNoteGain`). The offline render starts reading `amplitudeDb` (hashed, unread today); −72 dB, the range floor, means silent, and a gain-only set skips the stretcher. | 1.8 |
| P1 | The gentle presets sound alike because they only move note CENTRES by 15–31 c RMS, under ~55 c of movement they leave alone, and the pull axis is already at its ceiling. The listening set varies ONE axis of Natural: how much of the singer's own wobble it keeps (100 / 60 / 30 / 0 %). | 2.1–2.2 |
| P2 | Seven pre-registered checks, including a bit-exact anchor, a plant, physics that must fall with the axis, an audibility bound and true peak ≤ −1 dBTP. | 2.3 |
| P3 | A middle pick ships as one additive option, `keepWobble`, on `PitchAutoCorrectOptions` and `clip.autoCorrectPitch`. | 2.4 |
| M1 | Tuning to a MIDI melody is a TARGET, orthogonal to the preset. f0 decides where notes are; the melody decides which note each one gets, and adds a cut only where one sung part spans two melody notes. The octave is matched per note to the nearest octave of the melody's pitch class. | 3.2 |
| M2 | Where the melody rests, the voice stays as sung (or goes to a scale, if one is given). A chord takes its top note. Every disagreement is reported in the response. | 3.3 |
| M3 | Additive keys on `clip.autoCorrectPitch` (`melodyClipId` / `melodyTrackId`, `octaveMatch`), and **Tune Vocal ▸ Tune to Melody…** opens a small card. | 3.4 |
| D1 | The dot is the Wobble tool's knob, moved to the note's top-centre. A click makes the wobble one step bigger (⌥-click smaller). A drag is the tool's ordinary gesture. The tip shows **"Wobble kept: 30% of how you sang it"**, which amends C5a §9.3. Undo coalesces clicks. | 4 |

**Questions for the user: none new.** Item 2 is a listening pick. Every other default is stated with
its reason, and is one constant or one enum case to change (§5).

## §1 Sounds with no detected note (item 1)

### §1.1 What the code does today

All [READ].
- **Only voiced frames make notes.**
  - `PitchAutoCorrect.voicedRuns` ends a run at every unvoiced frame and drops runs shorter than
    `minimumNoteSeconds` = 0.06 s (`PitchCorrection.swift:1702-1743`, `:1691`, `:1717`).
  - S2's splitter cuts only inside those runs.
  - Both builders emit one segment per part: `PitchAutoCorrect.editSet` (`:1791-1818`) and
    `PitchNoteTable.detected` (`ProjectStore+PitchNoteEdits.swift:273-290`).
  - **A breath, a consonant or a missed sung note therefore gets no segment, and there is nothing to
    grab.**
- **Every frame already carries a level and a reason.**
  - `ClipPitchFrame.levelDbfs` is the RMS of the frame's 16 ms hop at 16 kHz, or `nil` for digital
    silence (`PitchDetection.swift:57-60`). `absence` says why a frame has no pitch (`:19-29`).
  - The only level gate is the absolute `silenceFloorDbfs` = −75 dBFS, marked "UNTUNED against real
    vocal material" (`:219-221`; applied in `absenceReason`, `PitchTracker.swift:579`).
- **The curve and a segment with no pitch.**
  - Scales other than 1 need ≥ 2 voiced frames. Otherwise the segment is listed in
    `unresolvedShapingSegmentIDs` (`PitchCorrection.swift:1204-1234`), which reaches the editor
    (`PitchPlayedLine.swift:262`).
  - The constant offset always applies through the gate (`:1344`).
  - Gates are normalised only when their weights sum to more than 1 (`:1354-1358`).
- **A pitch of 0 draws at A4.**
  - `NoteSegment.init` heals a non-positive `detectedHz` to 0 (`:602-603`).
  - `PitchCorrectionMath.midi(fromHz:)` returns 69 for it (`:1955-1956`).
  - The blob row is `midi(fromHz: detectedHz)` (`PitchEditorModel.swift:275`).
- **Per-note gain exists only in the model.**
  - `amplitudeDb` is "Phase 4 — carried, unread" (`PitchCorrection.swift:435-437`).
  - It is clamped to `Clip.gainDbRange` = −72…+24 dB (`Model.swift:728`), counted in `isIdentity`
    (`:529`) and hashed (`StretchCurvePlan.swift:204`).
  - A grep of `Sources/` finds no other reader. The same grep, as a positive control, found the
    digest and wire uses.
- **Formants.** The clip-level `formantPreserve` (default false) goes to the stretcher
  (`OfflineStretcher.swift:99`).

### §1.2 Measured on the take

[MEASURED archB] on the product's own 2081 frames of the take (62.5 fps). The level replica I used
for the audio legs matches the product's `levelDbfs` with median |diff| 0.003 dB (max 0.287 dB; the
resampler differs). That is the positive control.

| Quantity | Value |
|---|---|
| Unvoiced frames | 1110 of 2081. **All 1110 are `belowConfidence`, 0 are `belowLevel`:** the −75 dBFS floor never fires on this take. |
| Level, voiced frames (V) | median −19.7 dBFS |
| Level, unvoiced frames | p10 (F) −37.4, median −32.1 dBFS. **The gaps are not silent.** |
| What fills the gaps | The quietest 300 ms (19.90 s, −37.1 dBFS) has 70.2 % of its energy below 150 Hz: peaks at 57–63 Hz and harmonics, the mains hum busy-line already named. |
| Floor to singing, V − F | 17.7 dB |
| No-note frames, dB relative to V (2 dB bins) | A floor peak at −16…−14 (186 frames). Its upper shoulder falls to 97 frames at −12…−10 and 61 at −10…−8. From there the counts are flat, 57–74 frames per bin up to +2 dB: the audible sounds. |

The threshold under test, applied to the 1129 no-note frames (18.06 s): a stretch is ≥ 4 frames
after bridging dips of ≤ 2 frames.

| Rule | dBFS | Segments | Seconds |
|---|---|---|---|
| V − 20 ("20 dB below the singing") | −39.7 | 41 | **17.84 (it segments the silence)** |
| V − 10 | −29.7 | 41 | 6.91 |
| F + 6 | −31.4 | 42 | 7.71 |
| **F + 9** | **−28.4** | **38** | **6.19** |
| F + 12 | −25.4 | 32 | 4.37 |

**The same take at another level.** The user's original m4a is `dry-norm.wav` 21.5 dB quieter
(p5–p95: 19.5–22.1 dB; the normaliser varied over time).
- F + 9 picks 414 frames on one and 407 on the other: **Jaccard 0.969**. F + 6 gives 0.952 and
  F + 12 gives 0.948.
- **The same −28.4 dBFS, used as an absolute line, picks 0 frames on the m4a.**
- V − F is 17.7 dB and 17.8 dB.
- Voicing came from `dry-norm` for both [INFERRED safe: SwiftF0 is level-blind, and no frame of
  either file is under −75 dBFS].

**The 38 segments at F + 9, against the user's "take the following note":**
- **Neighbours.** 19 touch the following note (gap ≤ 32 ms), 14 of them only that one. 12 touch the
  previous note, 7 of them only that one (a release or a coda consonant). 5 touch both, and 12
  touch neither.
- **Distance.** 7 are more than 300 ms from the next note. None lacks a following note, but the
  clip's last gap (32.768–33.296 s) has none, so the case exists.
- **Pitch evidence.** Only 3 have enough hum-free periodic YIN frames to name a pitch:
  - 28.928 s: the following note is right (+5 c).
  - 31.376 s: the following note is **wrong by +350 c**, and the previous one is right (+18 c).
  - 31.024 s: both neighbours are 60 c off.

  **The take cannot confirm or refute any borrowing rule.**
- **Confidence.** Median 0.59 in these loud gap frames (233 of 414 at ≥ 0.5), against 0.32 in the
  quiet ones. Many are nearly voiced; the 0.9 gate drops them.

### §1.3 The audible threshold (U1)

**The rule.** It lives in one new pure file, `Sources/DAWCore/PitchUnpitchedFinder.swift`, which
reads only fields that frames already carry. The frame rate is always the result's own
`frameRateHz`.
- **F**, the floor, is the 10th percentile of `levelDbfs` over the clip's unvoiced frames
  (`frequencyHz == nil`). A `nil` level (digital silence) ranks below everything.
- A **no-note frame** lies outside every part that `PitchNoteSplitter.parts` returned. It is
  **audible** when `levelDbfs ≥ F + 9 dB`.
- **A sound** is a stretch of audible no-note frames:
  - dips of ≤ 2 frame periods are bridged, never across a part;
  - it is kept when it lasts ≥ `PitchAutoCorrect.minimumNoteSeconds` (4 frames);
  - its span is `[first.timeSeconds, last.timeSeconds + 1/frameRateHz)`.

**Guards.** Each returns no sounds and a named reason on the wire:

| Guard | When | Why |
|---|---|---|
| `notEnoughQuiet` | fewer than `1 s × frameRateHz` unvoiced frames have a level | F cannot be measured |
| `tooNoisy` | V − F < 12 dB, where V is the median voiced level | floor and singing overlap |
| `noNotes` | there are no parts | nothing to borrow a pitch from (§1.5) |

**Why relative to the floor** (§1.2). An absolute line finds 0 frames on the same take 21.5 dB
quieter. A line relative to the singing (V − 20) falls under F and segments the silence. The
floor-relative line keeps Jaccard 0.969 across that change.

**Why F + 9.** Here F + 9 = V − 8.7, which is where the floor's shoulder meets the flat run of real
sounds in the histogram. F + 6 and F + 12 do worse on the level test (0.952 and 0.948).
- ⚠ **It is tuned on ONE take.** U-A's gate re-measures it on a second take when one exists.
- Until then it is a wire knob, `marginDb` (§1.10), the way `silenceFloorDbfs` was exposed.

**Hum.** 70 % of this floor lies below 150 Hz. A level taken after a 150 Hz high-pass would widen
V − F from 17.7 to 23.5 dB [MEASURED archB]. But that is a detector change (an `analysisVersion`
bump and a contour re-key), so it is follow-up **U-F1**. **v1 changes nothing in the detector.**

### §1.4 The model: `NoteSegment.origin` (U2)

```swift
public enum NoteOrigin: String, Codable, Sendable, CaseIterable { case detected, transition, unpitched }
public let origin: NoteOrigin      // a detection fact, like `detectedHz`: no edit changes it
```
- **Coding.** `init` defaults to `.detected`, and the value is encoded only when it is not
  `.detected` (omit-when-default), so existing tables keep their bytes. Decoding reads `String?` and
  maps a missing or unknown value to `.detected`, so a newer file still opens in an older build (the
  `init` healing precedent).
- **For `.unpitched`, amend two docs.** `detectedHz` becomes the **borrowed drawing anchor**
  (§1.5), not a measurement. `detectedConfidence` becomes the median `confidence` of the sound's own
  frames.
- **Unchanged.** `isIdentity` and `isEdited` stay as they are: origin is not an edit. Splits carry
  origin through `reidentified`'s Codable round trip; add it to
  `splitCarriesEveryEditFieldTheParentHad`.
- **Digest slot (6), the origin block.** Gated on `segments.contains { $0.origin != .detected }`: a
  new marker, the count, then each segment's case index.
  - Slot (5) is reserved for U-C's gain block (§1.8). The order goes by slot, not by landing order
    (the `StretchCurvePlan.swift` banner).
  - `digestCoversEveryStoredField` gains `"origin"` and one rebuild case, since it is a `let`, like
    `detectedHz`.
- **Why not `detectedHz: 0` plus a lookup when drawing.** Every existing reader draws a 0 at A4,
  because `midi(fromHz:)` returns 69. An older build would put every breath two octaves above this
  singer. A borrowed Hz plus the marker degrades to a plain, silent note in the right place. A
  separate `anchorHz` field loses too: two pitch fields, and every reader must pick one.
- **It settles p2-seg §10 item 9.** The builders stamp `.transition` on transition parts; the user
  has now heard (a-T) and picked it, which was that item's precondition. How a slide is drawn is
  decided at U-E's looked-at gate. ⚠ S2 tests that build transition segments by hand gain
  `origin: .transition` (F-S2).

### §1.5 Which note an unpitched sound borrows (U3)

**The rule.** A sound borrows the `centreHz` of the **nearer** neighbouring part.
- A tie goes to the **following** part, the user's rule. A tie means both gaps are ≤ 2 frame
  periods (the sound touches both), or the gaps are equal.
- At a clip edge the sound uses its only neighbour. No 0 is ever stored, and with no neighbours
  there is no segment (`noNotes`).
- On this take: 27 of 38 sounds take the following note and 11 the previous one (7 touch only the
  previous note, 4 are nearer to it) [MEASURED archB].

**Where "take the note that follows" fails:**
1. **After the last note** there is no following note.
2. **A release or coda consonant** (the "s" of "notes") belongs to the note it ends: 7 of 38
   sounds.
3. **An isolated sound:** 4 of 38 sounds are nearer the previous note, up to 688 ms from the next.
4. **A missed piece of a sung note.** At 31.376 s the following note is +350 c off and the previous
   one is right. ⚠ That sound touches both, so U3 also takes the following note. **No neighbour
   rule fixes this.** The fix is U-F3: the detector's own sub-0.9 estimate (median confidence 0.59
   there). That needs a detector, wire and `analysisVersion` change, so it is not in v1.
5. **A breath has no pitch, whatever the anchor.** Dragging it "into tune" transposes noise (§1.7).

**So the anchor is only where the sound is drawn.** The take cannot test any rule further (3 of 38
sounds have evidence).
- A separate lane for unpitched sounds loses: a sound drawn away from its word cannot be read as
  part of it [INFERRED].

### §1.6 The two builders, p2-seg, and render neutrality (U4)

**Wiring.** Both builders, `PitchAutoCorrect.editSet(contour:)` and `PitchNoteTable.detected(from:)`,
call the finder right after `PitchNoteSplitter.parts`. They add one `.unpitched` segment per sound,
in time order. Sounds lie outside every part, so `canonical` heals nothing.
- **Sounds are IDENTITY under every preset and every slide shape.** Hard Tune's `shapeScale` 0 must
  not reach them: a sound has no voiced frames to shape, so it would join
  `unresolvedShapingSegmentIDs` and the editor would label a breath "couldn't analyse".
- A strength of 0 still returns `.empty`. Apart from `.transition` stamps (§1.4), the finder's
  output is the builders' only change.

**The curve skips an untouched sound.** One predicate, homed on `NoteSegment`:
`var entersPitchCurve: Bool { origin != .unpitched || pitchOffsetCents != 0 || wantsContourShaping || hasGeneratedVibrato }`.
`PitchCorrectionCurve.make` builds spans only where it is true.
- **Why the skip is needed.** An identity segment still joins the gate sum, and that sum is
  normalised whenever it exceeds 1. Beside an unequal ramp, the identity segment then trims its
  neighbour's correction. Example: Natural's 55 ms half-ramp next to a 64 ms sound's 32 ms
  half-ramp. 20 ms past the note's edge, the note's share of its correction falls from 0.239 to
  0.208 [INFERRED: the arithmetic of `gate` and `semitones`].
- **What the skip guarantees.** A table with untouched sounds renders **byte-identically** to
  the same table without them, so S2's bit-exact L pins and every byte gate stand. Adding sounds
  to an edited table still moves its digest: one byte-identical re-render, never stale audio.

**Stored tables are never rewritten behind the user's back** (p2-seg §4). A stored table gains
sounds only in two ways:
- a new preset pass;
- the merge verb `clip.findUnpitchedSounds` (§1.10), which fills only uncovered time and never moves
  or re-identifies a segment.

A fresh editor seed shows the sounds. An editor opened on an older table offers "Find sounds with no
pitch" (U-E).

### §1.7 What moving one does to its sound (U5)

- **Moving a sound transposes noise.** Its `pitchOffsetCents` reaches the curve, and the stretcher
  shifts the breath or consonant by that interval. With `formantPreserve` off (the default), up
  sounds brighter and thinner, and down sounds darker and duller [INFERRED; not measured].
  - Melodyne never does this: "Sibilants remain unaltered even when the word or syllable to which
    they belong is shifted upwards or downwards in pitch" [VERIFIED].
  - v1 allows it and says so. A sound's readout reads **"No pitch found. Moving it shifts this
    sound: a breath or an 's' just gets brighter or darker."**
- **Snapping is relative.** Drags snap the drawn pitch to the scale (`updatePitchDrag`,
  `snapScale.nearestAllowedMidi`), which means nothing without a pitch. An `.unpitched` sound moves
  in **whole semitones from where it sits**, and ⌥ is free movement.
- **The Wobble tool refuses:** "No pitch here, so there is no wobble to change." The C5a-2 wire
  verbs refuse with the same sentence.
- **Why v1 transposes.** Melodyne's way (U-F2: a vertical move renders as nothing) is one
  predicate, `entersPitchCurve`. But it would also stop a missed sung note (§1.5 case 4) from being
  moved into tune, and the finder cannot tell a missed note from a breath. The user asked to move
  sounds, so U-F2 waits until they ask for it after hearing v1.

### §1.8 Removing a sound (U6)

**What "remove/clear" does.** It silences the selected segments in place. Nothing moves (no ripple),
and undo brings them back.
- It works on any segment: a sound, or a "note" that is really hum.
- "Remove sound" sets −72 dB, the `Clip.gainDbRange` floor, which means **exact silence**.
  "Restore sound" sets 0.
- Architect A owns the menu and multi-select; this section gives the verbs.

**Store and wire.** `setClipNoteGain(clipId:segmentIds:gainDb:seedIfAbsent:)`, in
`ProjectStore+PitchNoteEdits.swift`, is one `performEdit` under `structuralKey`: it never coalesces.
It clamps to `Clip.gainDbRange` explicitly, because direct assignment bypasses the healing `init`
(that file's own ⛔). Wire `clip.setNoteGain {clipId, segmentIds, gainDb}` and MCP
`clip_set_note_gain` add one command and one tool.

**Render (U-C), in the offline job `StretchRenderCache.performRender`, never on the render thread.**
1. **Envelope.** 1 outside a gained segment; g = 10^(dB/20) inside, and exactly 0 at −72 dB.
   - The 10 ms raised-cosine fades sit **inside** the span, so a neighbour is never touched.
   - It is evaluated per output frame through the curve plan's own output-frame → source-second
     mapping, so ratio and C2 retiming line up by construction.
2. **The gain-only path.**
   - `NoteSegment.isPitchIdentity` is `isIdentity` without the gain term, and
     `StretchCurvePlan.make` guards on it. A gain-only set therefore takes no curve.
   - If ratio and semitones are identity too, the job **skips the stretcher**: the output is
     source × envelope. A breath removed from an untuned clip leaves every other sample bit-exact.
3. **Digest slot (5), the gain block.** It is gated on `segments.contains { $0.amplitudeDb != 0 }`
   and re-keys exactly the gain-edited sets, including those written before U-C, whose renders
   ignored the gain (the time-warp block's F7 precedent).

**Why the alternatives lose.**
- *Split the clip and delete the piece:* the note table fragments, stretched clips hit the F13/C2-0
  bug, and 40 breaths become 80 clips.
- *Delete the segment:* its audio still plays.

### §1.9 How other editors treat unpitched material

- **Melodyne 5** [VERIFIED, §7]. Its "sibilants" include "the sound of the vocalist inhaling or
  exhaling between words". They are "displayed hatched" and "remain unaffected by melodic changes".
  "Double-clicking with the Amplitude Tool on one or more selected notes mutes them."
- **Cubase VariAudio** [VERIFIED, §7]. "The gaps in between segments represent the non-tonal
  portions of the analyzed audio", and they "must be included in the segments manually".
- **Ours is a third way.** Each sound is its own segment you can grab, drawn at the nearer note.
  That makes it more visible than in either editor. It transposes when moved, which Melodyne never
  does (§1.7). Muting follows Melodyne's convention.

### §1.10 Obligations, failure modes, items

**Finder.** `PitchUnpitchedFinder.sounds(in: [ClipPitchFrame], frameRateHz:, notes: [Note], marginDb: Double = 9) -> Result`.
`Note` is `{start, end, hz}`: from the parts in the builders, and from the STORED segments in the
merge verb, so the user's splits count. `Result` is
`{sounds, floorDbfs, thresholdDbfs, skipped: Reason?}`.

**Store.** `findUnpitchedSounds(clipId:marginDb:)` has the shape of `autoCorrectClipPitch`:
pre-check, `await detectClipPitch`, relocate and re-check, then one
`performEdit("Find Sounds", structuralKey)`. It refuses a clip with no stored table (a fresh table
already has sounds) and a table from an older `analysisVersion`. `setClipNoteGain` is in §1.8.

**Wire and MCP: +2 commands, +2 tools** (`clip_find_unpitched_sounds`, `clip_set_note_gain`).
`clip.findUnpitchedSounds` returns
`{added, skippedReason?, floorDbfs, thresholdDbfs, sounds:[{segmentId, startSeconds, endSeconds, anchorHz, borrowedFrom}]}`.
Additive echoes: `origin` per segment on `clip.getPitchEdits`; `unpitchedCount` and
`unpitchedSkippedReason` on `clip.autoCorrectPitch`.

**Tests.**
- **`PitchUnpitchedFinderTests`** (synthetic): events at known dB; **a ±20 dB level shift gives
  identical sounds**; the three guards; bridging never crosses a note; the anchor rule with its
  tie and both edges; §1.5 cases 1–4.
- **Curve:** untouched sounds render byte-identical to no sounds. PLANT: a sound at +100 c must
  change the render. Hard Tune leaves sounds identity, with no unresolved ids.
- **Model:** both digest blocks and the reflection census. Codable omits the default and reads an
  unknown value as `.detected`. The merge never moves or re-identifies a segment, and undoes in
  one step.
- **U-C:** gain-only renders are bit-exact outside the span; −72 dB gives exact zeros inside it
  (fades excepted); on a tuned clip only the span changes.
- **Wire and MCP legs**, plus the real take: 38 ± 2 sounds on `DUR`'s take. That is a port check,
  not a pin.

**Failure modes.**
- **F-floor:** under 1 s of quiet gives `notEnoughQuiet`, shown on the wire and in the editor.
- **F-hum:** `tooNoisy`, then U-F1.
- **F-many:** a take just above the guard floods the view, so sounds draw faint.
- **F-borrow:** a sound drawn at the wrong note (§1.5 case 4).
- **F-stale:** an old table has no sounds until the merge verb runs.
- **F-S2:** transition fixtures built by hand. U-A re-runs S2's suites and explains every changed
  expectation, never re-pins it.

**Items U-A to U-E:** routes, sizes and order are in §6. U-E has a **looked-at gate** and covers:
- sounds drawn hatched and faint at their anchor;
- §1.7's readout, relative snap and Wobble refusal;
- remove and restore in architect A's menu;
- the "Find sounds" line.

## §2 The gentle presets need a bigger step (item 2)

### §2.1 Why Uncorrected, Gentle, Natural and Tight sound the same

**From the code.** Gentle, Natural and Tight all set `preserveVibrato: true`
(`PitchCorrectionPresets.options()`, `:77-92`), so `shapeScale` is 1. That means they only move each
held part's centre, by `strength × (nearest − detected)` (`segment(forPart:)`,
`PitchCorrection.swift:1832`). By construction that is at most 50 c × strength, and transitions stay
identity.

**From the numbers** [MEASURED archB, the 42 runs the user heard]:

| | Gentle | Natural | Tight |
|---|---|---|---|
| Centre moves, RMS | 15.4 c | 26.1 c | 30.8 c |
| Largest | 24.5 c | 41.7 c | 49.1 c |

- The page's "15 to 31" holds.
- The movement left in place is 54.2 c of whole-note SD (median) and 56.0 c of half-range, so
  "about 60" holds in size. After S2, held parts still carry 42.5 c (25.6 c inside their edges).
- Natural and Tight differ by 4.1 c on average.

**So each preset moves a centre by about half the wobble it leaves**, which is hard to hear in a
solo take with no reference pitch [INFERRED].
- The pull axis is used up: strength is clamped to 1 (`:1598`) and Tight is already there.
- Retune only shapes the 30–200 ms ramps at note edges.
- The one axis left is the movement. Only Hard Tune touches it, and it is the only preset the user
  heard as different (hear-hardtune = yes).

**The user's guesses.** "My vocals are not good": no, the step is too small. "Related to vibrato
control": in effect, yes. The gentle presets keep 100 % of the wobble, and §2.2 varies exactly that.

### §2.2 The listening set (P1)

**Setup.**
- **The preset:** Natural (strength 0.85, retune 110 ms), the middle of the three. Everything
  except the axis is fixed.
- **The one axis:** `keep`, the share of the singer's own movement kept on **held** parts. It sets
  `driftScale = vibratoScale = keep` on held parts only. Transitions and sounds stay identity.

| File | keep | What it should sound like |
|---|---|---|
| `N0-natural-keep100` | 1.0 | today's Natural, the anchor |
| `N1-natural-keep60` | 0.6 | a little steadier |
| `N2-natural-keep30` | 0.3 | clearly steadier notes, slides untouched |
| `N3-natural-keep0` | 0.0 | notes held flat, slides untouched |

**How it is rendered.**
- The take and window are L's: the whole 33.3 s, with the page excerpt at 13.783–19.689 s.
- The path is the product's own, `StretchRenderCache.renderIfNeeded`.
- It is done by **audio-dsp-engineer after S2 lands**, in a NEW env-gated file,
  `Tests/DAWEngineTests/NaturalWobbleListeningTests.swift`, beside L's `NoteSplitListeningTests.swift`.
  It reuses L's helpers and never edits the lines S2 repoints.
- Nothing is copied out of `DUR/`; the MP3s go only to the page.

**Why not another axis.** More pull is capped (§2.1). A faster retune only moves note edges, and
Tight is already at 40 ms. A key or scale answers a different question.

**The page asks:** "Which one sounds most like what you want *Natural* to do?" "They all sound the
same" is a valid answer, and a finding: nothing ships. Each file gets a zoom of its pitch (the
house rule for demos that may be hard to hear).

### §2.3 Pre-registered checks (P2)

Written down before any render. Each check has a plant that must fail it.

1. **Anchor.** N0 is bit-exact with L's `wav/07-natural-after.wav`, with 0 samples differing.
   Otherwise STOP: the harness is not the product path.
2. **Plant.** N0's settings rendered twice give identical bytes. A render with keep 0.6 on ONE held
   part must be caught by check 3(i).
3. **Invariance, L's three controls** (`DUR/L/README.txt`), over windows of held parts ± 55 ms:
   - (i) every curve hop outside the windows is identical to N0's;
   - (ii) the audio is bit-exact up to the first changed hop;
   - (iii) the independent YIN over transitions: the planted part's move must exceed the worst
     untouched transition's median |diff| against N0 by at least 10×. No absolute number is
     pre-registered here: L's 1.00–2.69 c came from unsplit held runs, and P-L changes those.
4. **Physics.** Held-part wander W (`PitchWanderMeter`: SD about the note mean, 0.10 s edge margin,
   octave-folded YIN) falls strictly: W(N0) > W(N1) > W(N2) > W(N3), and W(N3) ≤ 0.5 · W(N0).
5. **Audibility.** Adjacent files must differ in W by ≥ 20 % of W(N0). If a pair fails, drop one
   of the two, never N0. If N0 against N3 fails, STOP and report: no page is published.
6. **Level.** Every file is matched to one integrated loudness by pure gain, with true peak
   ≤ −1 dBTP. Both are re-measured on the decoded MP3s with `ffmpeg -hide_banner` (never
   `-v error`, which hides the summaries).
7. **Report.** For each file: W, loudness, true peak and gain applied. For each check: its result,
   with its plant's result beside it.

### §2.4 What ships after the pick (P3)

**If the user picks N1 or N2:**
- **The option.** Add `keepWobble: Double?` (0…1, clamped) to `PitchAutoCorrectOptions`. It applies
  to held parts when `preserveVibrato` is on. Under Hard Tune it is ignored and echoed as `nil`.
- **Wire, MCP, tests.**
  - The wire key goes on `clip.autoCorrectPitch`, in its `rejectUnknownKeys` list (`Commands.swift`
    ~`:5103`), and in the `appliedOptions` echo.
  - The MCP field goes on `clip_auto_correct_pitch`.
  - Tests cover the clamp, the echo, and a byte-identical render when the key is absent.
- **Presets.** Natural's preset gets the picked value. Gentle and Tight wait for a second set.
- **Docs.** Edit the presets banner's "nothing in between" (`PitchCorrectionPresets.swift:14-22`)
  and Natural's summary.
- **What changes at render time.** Natural then needs the detected contour: its first render is
  slower, and if detection is unavailable it falls back to the constant offset with the "couldn't
  analyse" caption (shipped contour-to-render behaviour).

**If the user picks N0, or says they all sound the same, nothing ships, and the page says so.**

## §3 Tune a vocal to a MIDI melody (item 3)

### §3.1 What the code has today

All [READ]:
- **Nothing tunes to MIDI today.** `clip.autoCorrectPitch` targets a scale (`tonicPitchClass`,
  `mode`) and nothing else (`Commands.swift` case `:5017`, keys `:5103-5106`).
- **A MIDI note** is `pitch` (Int), `velocity`, and `startBeat` / `lengthBeats` counted in beats
  **from the clip's start** (`Model.swift:137-146`). A clip carries `notes`, with no content offset
  and no loop fields (`:544`; a grep for either found nothing, positive-controlled on
  `startOffsetSeconds`).
- **Audio time to timeline beats:**
  `beat = tempoMap.beat(from: clip.startBeat, elapsedSeconds: (t − startOffsetSeconds) · stretchRatio)`
  (`ProjectStore+Quantize.swift:81-83`). Its inverse uses `TempoMap.seconds(from:to:)` (`:190`).
- **The "lead track"** the user remembers is a "Lead" instrument track that
  `SongSkeleton.swift:182, :238` writes when a skeleton is generated. Any MIDI track can be a
  melody. No wire verb creates a lead track by name; the grep was positive-controlled.
- **The Tune Vocal menu** (`TimelineLanesView.swift:4093`) holds the presets, "Open Note
  Editor…" and "Remove Tuning".

### §3.2 The design (M1)

**The principle: f0 decides where notes are, and the melody decides which note each one gets.**
The melody is a TARGET, separate from the preset. The preset still sets retune, wobble and slide
shape.

**The pure function.** New file `Sources/DAWCore/PitchMelodyTarget.swift`, with
`PitchMelodyTarget.plan(parts:frames:frameRateHz:melody:octaveMatch:) -> Plan`.
- `MelodyNote` is `{startSeconds, endSeconds, midi}`, already in **vocal source seconds**. The
  function never sees beats.
- `PitchAutoCorrect.editSet` gains `melody: [MelodyNote]? = nil`. With `nil`, the output is
  byte-identical to today's.

**The rules.**
1. **Match.** Each held part takes the melody note it overlaps most; a tie goes to the earlier note.
   A part that overlaps no melody note stays as sung, or goes to the scale if one was sent.
2. **Cut.** The melody adds a cut only where one held part spans two melody notes of different
   pitch. Each note must overlap the part by ≥ `minimumNoteSeconds`, and their boundary must be more
   than S = 8 frames (128 ms, the splitter's own constant) from any f0 cut.
   - The cut goes where the smoothed f0 crosses the midpoint of the two pitches, searched within
     ±S frames. If there is no crossing, it goes at the MIDI boundary.
3. **Octave.** `nearestOctave` is the default: the melody's pitch class in the octave nearest the
   part's own median, so a low voice can follow a high lead. `exact` is the alternative.
4. **Offset.** `strength × (target − detected) × 100`, the same arithmetic as `segment(forPart:)`.
   Transitions and sounds stay identity, as under the presets.
5. **Strength.** In melody mode it is 1 unless `strength` is sent, and `appliedOptions` echoes it.
   The user asked for notes that land ON the melody; Natural's 0.85 would stop 15 % short.

**Beats to vocal seconds** (in the store):
- A melody note's beat is `midiClip.startBeat + note.startBeat`. Notes are clipped to
  `[0, lengthBeats)`.
- `t = vocal.startOffsetSeconds + tempoMap.seconds(from: vocal.startBeat, to: beat) / vocal.stretchRatio`.
  Only notes inside the vocal's window are kept.
- ⚠ Stretched clips inherit the F13/C2-0 split/trim bug. Tests pin ratio 1 and ratio 1.25.

### §3.3 Where voice and melody disagree (M2)

Every case gets a defined result and a field in the response's `melody{}` block. Nothing is silent.

| Case | Result | Reported in |
|---|---|---|
| The melody rests under a sung part | as sung, or to the scale if one was sent (Waves Tune's "normal functioning resumes", §3.5) | `unmatchedParts` |
| A melody note that nobody sang | nothing to tune; v1 never invents singing | `unsungNotes` |
| The singer is early or late | majority overlap decides, so a lag under half a note is harmless | (by construction) |
| One sung part spans two melody notes | a cut, by §3.2 rule 2 | `cutsAdded` |
| A chord, or overlapping notes | the highest sounding note; an overlap under 60 ms counts as legato (the earlier note ends) | `chordsReduced` |
| The melody is an octave away | folded by `nearestOctave`, kept by `exact` | `octaveFolded` |
| A move of more than 300 c from what was sung | applied and reported. With `formantPreserve` off, the voice's character moves with it [INFERRED] | `farMoves:[{segmentId, cents}]` |
| No MIDI note overlaps the vocal | refused, with a teaching error naming both clips' spans | error |
| The melody is edited during detection | resolved after the detection await, in its final state | (by construction) |

Timing is not changed (C2 is "later", the user's pick): a late note is tuned where it was sung.

### §3.4 Wire, MCP and the Tune Vocal menu (M3)

**Wire.** `clip.autoCorrectPitch` gains three additive keys, each added to `rejectUnknownKeys`:
- `melodyClipId` or `melodyTrackId`: exactly one, and sending both is an error;
- `octaveMatch`: `"nearestOctave"` (the default) or `"exact"`.

These are not `PitchAutoCorrectOptions` fields: the options are the preset, and the melody is the
target. The response gains a `melody{}` block with `source`, `notesUsed`, `matchedParts` and the
§3.3 fields.

**Why not a new verb.** A `clip.tuneToMelody` verb would need a second copy of the replace guard,
the C-F3 pre-check, the detection await and the relocate/re-check.

**Store.** `autoCorrectClipPitch` gains `melody: MelodySource? = nil` (`.clip(UUID)` or
`.track(UUID)`) and `octaveMatch`. The melody is resolved after the await.

**MCP.** The same three fields go on `clip_auto_correct_pitch`. **The tool and wire counts do not
change.**

**UI.** Tune Vocal ▸ **Tune to Melody…** opens a card with:
- a melody picker: MIDI tracks and clips that overlap the vocal, with "Lead" first;
- preset chips (default Natural) and a "Match octave" switch (on);
- **Apply**, through `PitchPresetReplaceGate`, which reports one line, for example "Tuned 31 notes
  to Lead. 4 had no melody note and stayed as sung."

If no MIDI overlaps the vocal, the item is disabled with "Add a MIDI melody under this vocal
first."

### §3.5 How other tuners use MIDI target notes

| Tuner | What MIDI does | Mark |
|---|---|---|
| Auto-Tune Pro / Artist | A "Target Notes via MIDI" control: notes arriving on MIDI become the correction targets, live. | The control VERIFIED; its behaviour REPORTED (§7) |
| Waves Tune | "Receive MIDI – Tune to MIDI Notes": "This mode overrides the Notes grid (and all other modes) while MIDI notes are being played. Normal functioning resumes when no MIDI note input is sensed. MIDI note targeting overrides the speed and note transition" (manual p. 13) | VERIFIED |
| Cubase VariAudio | "You can use a MIDI track as a reference for your pitch and timing corrections", shown "as lines". With MIDI input, "The segment pitch is raised or lowered according to the note you play", on the selected segments, by hand. | VERIFIED |
| Melodyne 5 | Exports notes as MIDI. The pages read show no MIDI-as-target function; that is not a claim that none exists. | VERIFIED (export) |

**What this design takes.** From Waves: the melody wins where it plays, and normal correction
resumes where it rests (§3.3). Unlike Waves, the preset's speed is kept, because the preset is the
character. From VariAudio: melody lines drawn in the editor (M-F1). From none of them: live MIDI
input. Ours is an offline match, which an agent can drive with one wire call.

### §3.6 Failure modes, tests, items

**Tests.**
- **`PitchMelodyTargetTests`** (pure): the majority match and its tie going to the earlier note;
  the cut rule, with its S-frame guard and its midpoint search; octave folding both ways, where a
  6-semitone tie goes lower; chords, legato, unsung notes, and unmatched parts with and without a
  scale.
  - **Invariance:** a melody equal to each held part's nearest chromatic note reproduces the
    chromatic pass's table, ids excluded.
  - **`melody: nil` is byte-identical to today's `editSet`.**
- **Store:** beat to seconds at ratio 1, at 1.25 and across a tempo change; the melody edited during
  the await; the refusal when nothing overlaps.
- **`PitchMelodyCommandTests` and an MCP test:** the keys, their exclusivity, `rejectUnknownKeys`
  and the `melody{}` echo.
- **Physics** (synthetic): a sine "voice" 40 c flat of a three-note melody. The independent tracker
  must read each rendered note within 10 c of its MIDI pitch.

**Failure modes.**
- **F-lag:** a singer more than half a note late matches the previous melody note. It is reported;
  retiming is C2.
- **F-fold:** a note folds into the wrong octave. `exact` is the escape.
- **F-far:** a large shift (§3.3).
- **F-stretch:** the F13 geometry bug.
- **F-fast:** melody notes under 60 ms are never cut.

**Items M1–M3:** see §6. M3 has a looked-at gate. The follow-ups M-F1 and M-F2 are also in §6.

## §4 The top-centre dot (item 4, input to C5a-F4)

**What the user described.** In the wave tool, a drag smooths and shapes the wobble. A click on the
dot then "makes it a little more scale up overall to 31% as it showed in a tip". So the dot belongs
to the **Wobble tool** (C5a-4), not the Move tool. C5a §4.1 Alternative 1 (no fourth zone on a
Move-tool note) stands.

**Drawing.** The dot sits at the blob's **top-centre**: x at the note's temporal centre, y on the
top edge. It replaces C5a's centre knob, so a note still has one handle. It is 10 pt, in `signal`
ink, with a **12 pt hit radius** (C5a's two-handle radius). It shows on hover, in the Wobble tool,
on notes the tool can grab. There is none on a sound (§1.7) and none while the tool is gated (C5a
§5.5).

| Input | Does |
|---|---|
| Click: release within 3 pt of the press | **one step bigger.** Your own wobble: keep `k` += 0.10, clamped to [0, cap], where cap is 2, or 1 under Defect 2 (§18.3). A made wobble: depth += 5 c, up to 200. |
| ⌥-click | one step smaller, with the same clamps |
| Press, then move ≥ 3 pt | the tool's ordinary drag: ↑ ↓ width, ← → speed (the user's x-speed pick) |

**The tip.** It is drawn, never a tooltip (V13), and shows on hover and after each click. It
states the SETTING (keep, as a share of the singer's own wobble), never a cents depth.

| State | Tip |
|---|---|
| 0 < k < 1 | `Wobble kept: 30% of how you sang it` |
| k = 1 / k = 0 | `As you sang it (100%)` / `Smoothed flat` |
| k > 1 | `Wobble widened to 130%` |
| At Defect 2's cap | §18.3: `As you sang it. This note is too short to make its wobble wider.` |
| A made wobble | C5a's string, e.g. `New wobble: 5.5 per second, 35 cents each way` |

**⚠ This amends C5a §9.3's "never print a keep percentage".** Rule 5's intent holds: keep is never
presented as a depth. The reasons for the amendment:
- On this singer **no cents width can ever print**. 35 of 42 notes are `.unmeasurable`, and all
  six real wobbles (108.5–126.1 Hz) have `response = nil` (§18.3, §18.7). Without the percentage the
  dot would show no number at all.
- The user saw a percentage.
- Waves Tune shows its natural vibrato the same way: "a ratio multiplier for the detected natural
  vibrato", 0–200 % (manual p. 12, VERIFIED).

**Undo.** Each click is one `setClipNoteVibrato` commit (C5a-2) under
`PitchCorrectionUndoKey.vibrato`. Clicks on one note within the journal's 800 ms window fold into
**one** undo step. A slower click, or another note, starts a new step, as a drag does. "Reset
wobble" (keep 1, depth 0) is a `structuralKey` commit from architect A's menu.

**Scope.** A click steps one note; selections wait for architect A's selection model. There is no
new wire: the click is `clip.setNoteVibrato`, and `debug.pitchEditor` gains `door: "dot" | "drag"`.
One step is about ±5 c on a 50 c wobble, so the tip and C5a's draft line are what show it.

**Tests** (`PitchWobbleGestureTests`).
- T-dot-1: a click moves 0.2 to 0.3 in one commit.
- T-dot-2: ⌥-click, with clamps at 0, 1 and 2.
- T-dot-3: a made wobble steps +5 c, up to 200.
- T-dot-4: three clicks within 800 ms are one undo step; a click at 900 ms is a second.
- T-dot-5: the exact tip strings.
- PLANT: 4 pt of travel is a drag, not a step. There is no dot in the Move tool or on a sound.

**Item C5a-F4 (re-specified).** It comes after C5a-2 and C5a-4. ui-design-engineer, S, with a
looked-at gate. **No question for the user.** "A little more … to 31%" reads as a step, and a fixed
31 % jump would be one constant.

## §5 What needs the user's word

- **Nothing new is asked.** Item 2 is a listening pick (N0–N3, §2.2), and the user's pick is the
  feedback.
- **Told on the page, not asked:**
  - moving a breath or an "s" changes its sound (§1.7);
  - a sound is drawn at the nearer note, which is where to grab it, not its pitch (§1.5);
  - a melody pass lands notes ON the melody unless a strength is set (§3.2).
- **Every default is one constant:** the F + 9 dB margin (`marginDb` on the wire), the 0.10 keep
  step, the 5 c depth step, the 300 c far-move report, and `nearestOctave`.

## §6 Items, order, routes

| # | Item | Waits for | Route | Size |
|---|---|---|---|---|
| 1 | **P-L**: the Natural wobble listening set (§2.2–2.3) | S2 | audio-dsp-engineer | M |
| 2 | **U-A**: the finder, `origin`, both builders, the curve skip, digest slot (6) | S2 | audio-dsp-engineer | M |
| 3 | **U-B**: `clip.findUnpitchedSounds`, its MCP tool, the echoes | U-A | mcp-integration-engineer | S |
| 4 | **U-C**: the gain render, the stretcher skip, digest slot (5) | S2 (the same files) | audio-dsp-engineer | M |
| 5 | **U-D**: `setClipNoteGain`, `clip.setNoteGain`, `clip_set_note_gain` | U-C | mcp-integration-engineer | S |
| 6 | **U-E**: sounds in the editor, and remove / restore | U-A, U-D, architect A's menu | ui-design-engineer + swift-app-engineer | M |
| 7 | **M1**: `PitchMelodyTarget` and the `editSet` parameter | S2, U-A | audio-dsp-engineer | M |
| 8 | **M2**: store, wire keys, MCP fields | M1 | swift-app-engineer + mcp-integration-engineer | M |
| 9 | **M3**: the Tune to Melody card | M2 | ui-design-engineer | M |
| 10 | **P-ship**: `keepWobble` | the user's pick | audio-dsp-engineer + mcp-integration-engineer | S |
| 11 | **C5a-F4**: the dot (§4) | C5a-2, C5a-4 | ui-design-engineer | S |

- **Order.** P-L goes first: it needs no code, and the user is waiting on item 2. U-A and U-C can
  run in parallel. U-A must precede M1, because both change `editSet`.
- **Counts.** +2 wire commands and +2 MCP tools (U-B, U-D); everything else adds keys. Re-measure
  with `node scripts/gates/doc-count-drift.mjs` at landing, and never quote a count from here.
- **Nothing needs full Xcode, and the render thread is untouched.** The gain envelope and the
  stretcher skip live in the offline job.
- **Follow-ups, none scheduled:**
  - U-F1: a hum-rejecting level.
  - U-F2: an unpitched move renders as nothing.
  - U-F3: the detector's own sub-0.9 estimate for sounds that are nearly voiced.
  - M-F1: melody lines drawn in the editor.
  - M-F2: retiming to the melody (with C2).

**Owed to `docs/ARCHITECTURE.md` "Key future decisions"** (docs-scribe; this task allowed one file).
The verbatim entry:
> **Unpitched sounds, per-note gain and melody targets (2026-09-24,
> `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md`).** Audible stretches with no
> note (level ≥ the clip's own floor + 9 dB, where the floor is the 10th percentile of its unvoiced
> frames) become `.unpitched` segments (`NoteSegment.origin`). They are drawn at the nearer note's
> pitch and are always identity, and the curve skips untouched ones, so every render stays
> byte-identical. Per-note gain (`amplitudeDb`) renders in the offline job, never on the render
> thread; a gain-only set skips the stretcher, and −72 dB is silence. A MIDI melody is a TARGET on
> `clip.autoCorrectPitch`: f0 decides where notes are, and the melody decides which note each one
> gets. Digest suffix slots: (5) gain, (6) origin.

## §7 Sources

V = VERIFIED: read, and quoted from the page or PDF. R = REPORTED: third-party or not read first-hand.

**Melodyne 5**
- V, sibilants: https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_AudioAlgorithms?env=standAlone
- V, mute: https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolAmplitude
- V, sibilant balance and delete-or-mute: https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolAmplitude_Fade_Sibilance
- V, MIDI export: https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ExportMIDI_standalone?env=standAlone

**Cubase VariAudio**
- V, gaps: https://archive.steinberg.help/cubase_artist/v12/en/cubase_nuendo/topics/sample_editor_variaudio/sample_editor_variaudio_segments_segments_and_gaps_r.html
- V, MIDI reference: https://archive.steinberg.help/cubase_pro_artist/v10/en/cubase_nuendo/topics/sample_editor_variaudio/sample_editor_variaudio_showing_midi_reference_tracks_t.html
- V, MIDI input: https://archive.steinberg.help/cubase_pro_artist/v10/en/cubase_nuendo/topics/sample_editor_variaudio/sample_editor_variaudio_pitch_changes_via_midi_input_t.html

**Waves Tune**
- V, pp. 6, 12, 13: https://assets.wavescdn.com/pdf/plugins/tune.pdf

**Auto-Tune**
- V, the Target Notes control only: https://help.antarestech.com/hc/en-us/articles/41109184245908-How-to-configure-MIDI-control-of-Auto-Tune-Pro-or-Auto-Tune-Artist-in-Logic-Pro
- R, its behaviour:
  - http://support.antarestech.com/support/solutions/articles/26000030590-how-to-configure-midi-control-of-auto-tune-pro-in-pro-tools
  - https://www.protoolstraining.com/blog-help/pro-tools-blog/tips-and-tricks/189-antares-auto-tune-how-to-use-autotune
  - https://duc.avid.com/showthread.php?t=343210
  - https://gearspace.com/threads/using-the-target-notes-via-midi-function-with-autotune-and-protools-10.861076/
