# Melodyne-class pitch editors — gap analysis against DAW Pro's data model

**Date:** 2026-09-23
**Author:** research-analyst
**Ask:** *"look at similar features in melodyne and similar, we need to support them."* — verify whether our shipped `NoteSegment`/`PitchEditSet` model already covers the field, before more UI is built on top of `docs/design/2026-09-22-pitch-editor-ui.md`.
**Method:** primary source = our own code, cited file:line. Competitor claims = cited to a fetched page, dated. Nothing is asserted about a competitor from memory alone; where I could not verify a claim from a primary source I mark it **[UNCONFIRMED]**.

---

## Actionable takeaways (summary — detail and reasoning in §7)

1. **Highest-leverage single fix: supply a detected contour to the render path.** This alone revives `driftScale`, `vibratoScale`, and stops `hardTune` silently degrading to a stronger `Tight`. Not costed here — flag for `daw-architect` sizing.
2. ⚠️ **RE-MEASURED — Increment B (four presets) is fully SHIPPED, not "spec'd, gated on one store op" as this doc first reported.** Re-grepping `Sources/DAWControl/Commands.swift:809-811,4886,5000,5021` (wire verbs), `Sources/DAWCore/ProjectStore+PitchCorrection.swift` (the store op — `pitchEdits =` assignment confirmed), `mcp-server/src/server.ts:8671,8788,8805` (MCP tools), and `Sources/DAWApp/Timeline/TimelineLanesView.swift:4093-4095` (a live "Tune Vocal" context menu) all show the door is open end to end. The design doc's own §4 table (dated 2026-09-22) warns *"do not quote this table... re-run the four probes"* — I quoted it in an earlier pass anyway; this line is the correction. **What remains gated on item 1 is not the door, it is `hardTune` sounding correct once it's walked through.**
3. Land Auto-Key (default correction scale to detected key) — our own source calls the missing mitigation cheap; it targets our single worst measured failure mode (wrong-note-in-tune, §2).
4. Stop discarding `TakeAligner`'s per-onset offsets (`TakeAlignment.swift:96`) — small change, unlocks a real alignment-warp feature; do not conflate with Phase-3 timing (that reuse is speculative, §5).
5. **Flag for the user, do not silently resolve**: Melodyne's own tier data ranks timing as **core** (Essential-tier) while our own phasing defers per-note timing to Phase 3, behind amplitude/formant. That is a real disagreement between "what the benchmark treats as basic" and "what is cheap to render" — see §7 item 4.
6. **Would NOT build yet**: synthesized-vibrato-rate change, polyphonic separation, real-time correction, ARA hosting — see §7 item 10 for why each.

Full reasoning, citations, and the complete capability census: §§0–7 below.

---

## 0. The headline verdict on the six-fields question

> *"My own first reading is that those six per-note fields map almost one-to-one onto Melodyne's main per-note tools. VERIFY OR REFUTE THAT."*

**The SCHEMA maps almost one-to-one onto Melodyne's (and Flex Pitch's) per-note tools. The RENDER PATH does not — and that is the more important half of the answer.**

| `NoteSegment` field | Melodyne / Flex Pitch tool it corresponds to | Schema | Render, TODAY (re-verified against the render path, not assumed) |
|---|---|---|---|
| `pitchOffsetCents` | **Pitch Tool** — drag a blob vertically to move its centre ([Sound on Sound](https://www.soundonsound.com/techniques/pitch-correcting-vocals-melodyne)) | **Direct match.** | ✅ **LIVE.** The only one of the six that reaches audio unconditionally. |
| `driftScale` | **Pitch Drift Tool** — the second sub-tool of the Pitch Tool, sitting beneath it in the toolbar, selectable by [F2] or the Note Editor's context menu (confirmed: [Celemony, Pitch modulation and drift](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolModulationDrift_2?env=standAlone)); Flex Pitch names the same territory as two hotspots, drift-in and drift-out ([Apple Support, Flex Pitch](https://support.apple.com/guide/logicpro/edit-pitch-and-timing-with-flex-pitch-lgcpc53e6bef/mac)) | **Direct match to a NAMED tool**, and our single scalar is a simplification of Flex Pitch's two separate hotspots (§7 item 4 note) into one. | ⛔ **STARVED, NOT LIVE.** See below — the render path never supplies a contour, so this field computes to zero regardless of its value. |
| `vibratoScale` | **Pitch Modulation Tool** — the FIRST sub-tool of the Pitch Tool, same toolbar location as Pitch Drift above (same Celemony source) — Melodyne's own term is "pitch modulation," covering vibrato/trills; Flex Pitch's single "Vibrato" hotspot is the same idea under a simpler name | **Direct match as a depth multiplier**, to a named tool. Explicitly NOT a calibrated depth control by our own doc comment (`Sources/DAWCore/PitchCorrection.swift:69-74,303-306`, measured 1.06–1.20× overshoot vs. requested). | ⛔ **STARVED, NOT LIVE.** Same cause as drift. |
| `formantOffsetSemitones` | **Formant Tool** (Melodyne) / Formant hotspot (Flex Pitch) / throat modeling (Auto-Tune) | Field exists, ±24 semitones, matches the whole-clip range. | ❌ **Never read** by anything. `Sources/DAWCore/PitchCorrection.swift:309-311`: *"No renderer reads it today."* |
| `timeStartDeltaSeconds`/`timeEndDeltaSeconds` | **Time Tool** (also called the Timing Tool) — drag start/end to move/stretch a note ([Pro Tools Training](https://www.protoolstraining.com/blog-help/pro-tools-blog/tips-and-tricks/468-editing-in-melodyne-manual-tools)) | Field exists. | ❌ **Never read.** `:312-316`: *"carried, unread."* |
| `amplitudeDb` | **Amplitude Tool** — raise/lower a single blob's level | Field exists, shares `Clip.gainDbRange`. | ❌ **Never read.** `:319-321`. |

**Corrected headline: exactly ONE of the six fields — `pitchOffsetCents` — reaches audio today.** An earlier draft of this table marked drift and vibrato "live," which is wrong and contradicted by our own code's own bold-faced comments:

- `Sources/DAWCore/PitchCorrection.swift:109-113`: *"STILL GENUINELY ABSENT: the render path passes `contour: []`, so `preserveVibrato: false` (the `.hardTune` preset) degrades to a constant per-note offset and populates `unresolvedShapingSegmentIDs`, which no caller reads. That is the one remaining hole, and it is user-visible as Hard Tune sounding like Tight."*
- `Sources/DAWCore/PitchCorrectionPresets.swift:104-113`: *"The render path calls `StretchCurvePlan.make` with `contour: []`, so a set with `driftScale`/`vibratoScale` ≠ 1 has nothing to resolve its shaping against: every segment lands in `unresolvedShapingSegmentIDs`... and only the constant per-note offset survives. Measured on a real vocal, `hardTune` asks for a median 62.1 cents against `tight`'s 18.8 — so it would not even be inaudible, it would be a *stronger Tight* wearing the label 'the robot effect.'"*

This is exactly why `PitchCorrectionPreset.offeredInUI` (`PitchCorrectionPresets.swift:128`) withholds `hardTune` from every on-screen door while still accepting it on the wire (`:120-123`) — the UI has no room to explain a control that lies about what it does, but an agent asking explicitly gets a `warnings` field telling it so.

⚠️ **Re-confirmed at report time, not just when this section was first written**: `Sources/DAWEngine/Stretch/StretchCurvePlan.swift:78,83-84` still default `contour: [ClipPitchFrame] = []`, and `Sources/DAWEngine/Stretch/StretchRenderCache.swift:344-348` still call `StretchCurvePlan.make` without passing one. This finding has NOT gone stale even though the UI/wire status in the Actionable takeaways above has.

**So the schema-correspondence half of the original claim holds — and is stronger than my first pass reported: four of the six (pitch, drift, modulation, timing) are direct matches to Melodyne's own NAMED tools, verified against Celemony's help pages, not just a "same territory" description.** But "the model has this" cannot be read as "this is audible." `PitchCorrectionCurve.make`'s own doc comment (`:719-729`) takes a `contour: [ClipPitchFrame] = []` parameter specifically because nobody currently supplies one; the mechanism to make drift/vibrato/formant/timing/amplitude audible is not "write a UI," it is "get a detected contour to the render path" (for drift/vibrato) plus separately wire the other three terms into the curve/stretch call at all. §7 orders the recommended build sequence around this correction.

**On the toolbox enumeration itself — a method note.** My first pass claimed to have "read Celemony's own tool documentation" for a full toolbox list; the direct `WebFetch` of that page failed (`socket hang up`, retried once, failed again) and every name in that list actually came from search-engine result summaries of Celemony/third-party pages, not a page I read directly — an overclaim, corrected here. What follows in §1 is now built from search summaries of: Celemony's own **Pitch modulation and drift** page (confirmed reachable via search snippet, quoted above), Celemony's **Time Handles and Attack Speed** page, a MusicTech piece on Melodyne 5's sibilant feature, and Pro Tools Training's third-party toolbar walkthrough. Names are given as returned by those sources; where a name could not be pinned to an official Celemony page directly, it is marked so in §1.

---

## 1. Capability table: capability → model / UI / render → what is missing

Method for "model": grep-verified field or type in `Sources/DAWCore/PitchCorrection.swift` (1187 lines, read in full) and `PitchCorrectionPresets.swift` (129 lines, read in full). Method for "UI": read against `docs/design/2026-09-22-pitch-editor-ui.md` §§3–12 (1457 lines, read in full), **cross-checked against the actual source tree where the design doc's own dated table could be stale (see the Actionable takeaways correction)**. Method for "render": grep-verified against `PitchCorrectionCurve.make`/`semitones(atSourceSecond:)` (`Sources/DAWCore/PitchCorrection.swift:619–892`) and the two ⛔-marked comments quoted in §0.

| Capability | Model | UI (re-verified against source, not just the design doc's table) | Render | What is missing |
|---|---|---|---|---|
| Move a note's pitch centre (Pitch Tool) | ✅ `pitchOffsetCents` | Spec'd, Increment C1 — **not yet built** (Increment A's view is read-only per its own spec; confirmed no drag handler in `PitchEditorView.swift` this session) | ✅ **live** | Just the drag gesture + UI. |
| Flatten/keep pitch drift (Pitch Drift Tool) | ✅ `driftScale` | Not yet in interaction spec | ⛔ **starved** — computed but has no contour to shape against | **The contour, not the UI.** Render path must be handed `[ClipPitchFrame]`; see §7 item 1. |
| Flatten/keep/exaggerate vibrato depth (Pitch Modulation Tool) | ✅ `vibratoScale`, capped 0–4×, honesty-capped as a depth multiplier not a calibrated control | Spec'd as part of the "shape brush," partially | ⛔ **starved**, same cause | Same fix as drift — one contour-supply change unlocks both fields at once. |
| Change vibrato RATE (cycles/sec), not just depth | ❌ no field | Frames show it (`5.5 Hz → 7.8 Hz`), flagged **[SEEN]** in design doc §7.2 | ❌ | **New field + new synthesis mechanism** — a generator, not a scaler. §3 below; design doc calls this "a representation gap, not a UI gap" (§7.5). |
| Formant shift, independent of pitch (Formant Tool) | ✅ field exists | Out of scope, Phase 4 (§10 item 2) | ❌ never read | Renderer wiring. Stretch engine already exposes `formantPreserve` per `m23-q` §3.1 — the substrate exists, the wire does not. |
| Move a note's start/middle (Time Tool, "Time Handle" sub-tool per search summary) | ✅ `timeStartDeltaSeconds`/`timeEndDeltaSeconds` exist | §10 item 1 defers to Phase 3; §7.5 conflict 1 flags the user's brief asking for exactly this in Increment C | ❌ never read | Renderer wiring — the hard part; interacts with neighbours and `maxCleanStretch = 2`. |
| Stretch a note's ATTACK independent of its anchor point (Attack Speed sub-tool of the Time Tool — [Celemony: Time Handles and Attack Speed](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolTimeHandlesAttackSpeed_2)) | ❌ no distinct field — our two time-delta fields describe *whole-note* start/end shift, not an internal-envelope attack-speed parameter | Not addressed anywhere | ❌ | A materially finer-grained concept than our existing time fields; would need its own field once Phase 3 timing lands at all. Named so nobody assumes the two existing time fields already cover it. |
| Per-note level (Amplitude Tool) | ✅ field exists | Out of scope, Phase 4 (§10 item 2) | ❌ never read | Renderer wiring; a plain gain multiply — likely the cheapest of the three fully-unwired fields. |
| Per-note fade in/out (Fade sub-tool, per search summary of the Amplitude Tool's sub-tools) | ❌ no field — `amplitudeDb` is one scalar per note, not a fade shape/duration | Not addressed | ❌ | New, small: a fade-time or fade-curve field alongside `amplitudeDb`, once that field is wired at all. |
| Sibilant detection + independent balance/duck | ❌ **nothing** — no sibilant/fricative classifier anywhere in `PitchCorrection.swift`/`PitchDetection.swift`; `ClipPitchFrame.frequencyHz == nil` flags ALL unvoiced content (breaths, esses, silence) as one undifferentiated class, not sibilants specifically | Not addressed anywhere | N/A | Genuinely new detector work. Per a MusicTech report on Melodyne 5's feature announcement, this tool *"detects unpitched, noise-like consonant sounds including 's,' 'z,' 'ch,' 'k,' and 't' sounds"* and lets them be *"ducked, accentuated and otherwise processed separately"* ([MusicTech](https://musictech.com/news/gear/celemony-announces-melodyne-5/)) — a real classifier, not a byproduct of pitch detection. |
| Note separation (split/merge blobs) | Partial — `PitchAutoCorrect.voicedRuns` treats a hole as a hard boundary (`:939–949,992–1033`), but **cannot split a legato run with no hole**, and **has no merge at all** | Spec'd, Increment C3 (split only); merge named as unaddressed in §7.2 ("nothing implies merge") | N/A (segmentation, not a render term) | A same-pitch-run splitter using transient/onset evidence (`detectTransients` already exists, `m23-q` §3.4) and a merge operation, neither written. |
| **Note Assignment Mode** — fix which pitch class a note is *believed to be*, without touching audio, by choosing among "ghost blob" candidates | ❌ **no field, no type, no candidate-retention concept anywhere** | Not mentioned in either doc | N/A | **Fully absent — the gap the user suspected. §2.** |
| Scale / tonal grid, custom scales | ✅ `PitchCorrectionScale` (tonic + chromatic/major/minor), reads through `KeyMode.scaleIntervals` (`:143–149`) | Spec'd for Increment B; read-only ruler drawn in Increment A (**Increment A confirmed live**, `Sources/DAWApp/PitchEditor/PitchEditorView.swift`) | ✅ `nearestAllowedMidi(to:)` drives `PitchAutoCorrect.editSet` | **No custom/microtonal scales** — our `PitchCorrectionScaleMode` is a closed 3-case enum (`:131-149`). **[UNCONFIRMED]** exact Melodyne tier at which custom scales unlock, but every comparison table found groups them with the rest of the Assistant-tier toolkit. |
| **Auto-Key** — default the correction scale to the clip/project's own detected key | ❌ **named as unimplemented in our own code**: `PitchCorrection.swift:195-200`, *"THE MITIGATION IS A KEY, AND IT IS NOT BUILT… which makes chromatic the default for exactly the material it handles worst."* Design doc §6.3 item 3 names the same gap. | Not built | N/A | Low effort per our own source: `PitchCorrectionScaleMode`'s raw values are already *"exactly `KeyEstimate.mode`'s two strings, so a future 'default the scale to the clip's detected key' is a direct construction rather than a translation table"* (`PitchCorrection.swift:128-130`). Antares ships the same idea as a standalone **Auto-Key** plug-in ([Antares Auto-Tune Pro docs](https://www.antarestech.com/blog/auto-tune-pro-x-tutorial-overview)). |
| Correction macros (the four presets) | ✅ `PitchCorrectionPreset` (gentle/natural/tight/hardTune) | ✅ **SHIPPED, re-verified this session** — wire verbs (`Commands.swift:809-811,4886,5000,5021`), store op (`ProjectStore+PitchCorrection.swift`), MCP tools (`server.ts:8671,8788,8805`), and a live "Tune Vocal" context-menu door (`TimelineLanesView.swift:4093-4095`). **The design doc's own §4/§15 table (dated 2026-09-22, R3 ⛔) is stale on this point** — its own text warns of exactly this. | ✅ live for the pitch term; **degraded** for `hardTune` per §0 | Nothing structural remains — `hardTune` needs the contour fix in §0 to stop degrading to Tight, which is a render-path fix, not a missing door. |
| **Flex-Tune** — a dead zone around the target pitch so small scoops/dips are left alone entirely, rather than pulled proportionally | ❌ no threshold/dead-zone concept — `PitchAutoCorrectOptions.strength` is a single proportional multiplier applied to every note uniformly, with no "ignore notes within N cents" gate | Not addressed | N/A | Antares's own description: *"creates an 'ignore area' between half steps so scoops and dips don't get tuned so tightly"* **[claim as described in a search summary; not independently re-verified against Antares's own manual text this session]**. Cheap to add as a threshold parameter on `PitchAutoCorrectOptions`. |
| **Humanize** — relax retune speed specifically on long/sustained notes so they don't sound static | ❌ `PitchEditSet.retuneMs` is one constant for the whole clip (`:452-478`), not a per-note, duration-adaptive value | Not addressed | N/A | A policy addition to `PitchAutoCorrect.editSet` (duration-aware retune scaling), not a new field — `retuneMs` already exists per set, this would need to become per-segment or take a duration-scaling function. |
| Real-time / low-latency correction while singing (Waves Tune Real-Time, Auto-Tune's live mode) | ❌ not attempted; architecturally excluded | Explicitly out of scope, no phase (design doc §10 item 5) | ❌ | **Deliberate, not a gap.** `m23-q` §7.6 (condition 5) is absolute: *"No pitch DSP on the render thread, ever."* Everything in this subsystem is offline-only by design — a genuine divergence from this product class, stated here so it reads as a decision rather than an oversight. |
| Leveling (macro loudness evening across notes) | Only the per-note `amplitudeDb` primitive exists; no macro computes and applies a leveling pass | Not addressed | ❌ | A policy function, not written; cheap once `amplitudeDb` is wired to render. Melodyne 5 ships this as a **Leveling Macro** per a low-confidence social-media feature reel ([Facebook/Celemony](https://www.facebook.com/Celemony/videos/melodyne-5-the-leveling-tools/276709953694151/)) — cited for the feature's existence/name only. |
| Time quantize (snap note onsets to a grid) | ❌ no grid-snap logic anywhere in `PitchCorrection.swift` | Not addressed; §10 groups all timing under Phase 3 | ❌ | New: needs a tempo-grid-aware quantize policy operating on `timeStartDeltaSeconds`, itself unwired. |
| Audio-to-MIDI | ❌ nothing in `PitchCorrection.swift` produces `MIDINote`s | Not addressed | N/A | Would consume `PitchAutoCorrect.voicedRuns` → `[MIDINote]`, cheap in principle (median Hz → nearest MIDI, run bounds → beat bounds via `TempoMap`), genuinely absent today. |
| Take-doubling alignment (VocAlign-class warp) | **Half-built** — `TakeAligner.align` computes a full list of per-pair onset deltas (`winningPairs`, `Sources/DAWCore/TakeAlignment.swift:93-96`) then **collapses them to one scalar median offset** (`:96-100`) and discards the list | Exposed as `take.autoAlign`, whole-lane only | Applies one constant offset to a lane | **The per-onset offset list is computed and then thrown away.** §5. |

---

## 2. Note assignment / detection correction — the item confirmed absent

**Verified: `PitchCorrection.swift` and `PitchDetection.swift` (read in full, plus a targeted grep for `noteAssign|reassignPitch|pitchClassOverride` across `Sources/` — 7 hits, all unrelated: effects-chain de-essers and frequency-reference tables) contain no concept of "the detector proposed the wrong note; let the user pick a different one without touching the audio."**

What Melodyne's Note Assignment Mode actually is, per Celemony's own documentation (fetched 2026-09-23):

> *"Sometimes Melodyne detects the wrong note... In Note Assignment Mode, you may see hollow blobs of which only the outlines... are visible. These represent 'potential notes'... To reassign a note from its currently-detected place, click the corresponding 'ghost blob.' The root note of that blob will be reassigned, but will not alter the pitch."* — [Celemony: Tools for note assignment](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_NA_Mode_Tools)

This is a **detection-correction layer that sits BELOW pitch correction**, not a pitch edit, and it is a distinct MODE (a toggle over the whole editor), not one more item in the drag-tool palette. It:
1. Keeps and surfaces multiple candidate pitch-class hypotheses per note (the "ghost blobs"), not just the winning one.
2. Lets the user pick a different candidate — reassigning *what the detector believes the note is* — while leaving the audio and the note's actual timing/pitch curve untouched.
3. Is explicitly the fix for **octave errors and overtone confusion**, which our own docs independently identify as our worst measured failure mode: `PitchCorrection.swift:174-201` documents, with numbers, that chromatic scale-snap on a note that drifted 42-48 cents off puts **24% of frames a semitone away from what was sung**, and that distance-to-nearest-semitone as a quality metric scores that wrong-note render as *better* than the untouched take (11.7¢ vs 18.8¢) — "a wrong note perfectly in tune is perfect by that measure." The same comment names the mitigation as **a key** (detected-key defaulting, i.e. Auto-Key, §1), not as note assignment — but Melodyne's actual answer to this exact failure class is note assignment, and we have neither.

**Why this is genuinely hard, not just unbuilt** (per the task's instruction to name hard things as hard):
- It requires the detector to retain **and surface multiple candidates per frame/run**, not just the argmax. SwiftF0, our shipped detector, is documented in `docs/research/m23-q-pitch-correction-design.md` §5.6.2 as returning exactly two tensors — `pitch_hz` and `confidence` — i.e. **one hypothesis, not several**. Building a ghost-blob equivalent means either (a) re-running the model with alternate constraints (e.g. an octave-shifted search) to manufacture a second candidate, which is a real DSP task, not a UI task, or (b) a much cruder proxy — just letting the user manually pick a different octave for a note, which is buildable but is a weaker feature than what Melodyne ships (it has no evidence *for* the alternative, just a manual override).
- It is a genuinely different kind of edit from anything `NoteSegment` currently represents: every existing field describes *how much to move a detected pitch*; note assignment describes *what the detector's belief about the note itself was, and letting a human override that belief without moving audio*. This likely wants a new type (e.g., `detectedMidiOverride: Int?` on `NoteSegment`, defaulting to nil, which `PitchCorrectionCurve` would then treat as the reference point for its cents math instead of `detectedHz`), not a field on the existing shape.

---

## 3. Synthesized vibrato (rate change) — confirmed absent, and the design doc got here first

`docs/design/2026-09-22-pitch-editor-ui.md` §7.5, "CONFLICT 2," independently reaches the same conclusion I would have: `vibratoScale` is a **multiplier on the detected contour**, so on a note with no sung vibrato, `vibratoScale × 0 = 0` no matter how large the scale — it cannot manufacture cycles that were not sung, and it cannot change their rate even where they exist (rate is a property of the *sampled contour itself*, invisible to a post-hoc scalar). The user's own reference video shows exactly this operation (`5.5 Hz ±93¢` → `7.8 Hz ±32¢`, both axes changing). Building it needs:
- New fields, absolute rather than relative: something like `syntheticVibratoRateHz: Double?`, `syntheticVibratoDepthCents: Double?`.
- A decision the design doc correctly flags as unresolved: does synthesized vibrato **replace** the sung contour inside a note, or **add to** it?
- A generator in the render path, which does not exist — today `PitchCorrectionCurve` only ever *reads* a measured contour (`Sources/DAWCore/PitchCorrection.swift:730-797`), it never writes one, and per §0 it currently reads no contour at all in production.

**[UNCONFIRMED]** whether Melodyne's own Pitch Modulation Tool goes beyond a depth multiplier to reshape or re-rate the modulation curve — I could not find primary Celemony documentation confirming or denying rate-changing behavior in that tool, and I am not asserting it does. Auto-Tune's comparable **Natural Vibrato** control is described consistently across sources as "exaggerate or suppress," i.e. a depth control, matching our own `vibratoScale`'s shape and limitation ([Antares Auto-Tune Pro docs](https://www.antarestech.com/blog/auto-tune-pro-x-tutorial-overview)). If TUNE X's rate-changing brush is not standard even in Melodyne, that would make it a genuinely novel ask relative to the whole product class, not just relative to us — worth surfacing to the user rather than assumed.

---

## 4. Scale / tonal grid — what we have and the two things Melodyne tiers add

**Have, verified**: `PitchCorrectionScale` (`Sources/DAWCore/PitchCorrection.swift:163-259`) — a tonic (0-11) plus `.chromatic`/`.major`/`.minor`, `nearestAllowedMidi(to:)` doing the actual snap with a documented tie-break rule. This is a real, working scale-constraint engine, on par with the basic tonal-grid concept in every one of these products.

**Missing, and tier-gated in Melodyne**:
1. **Custom/arbitrary scales.** Our `PitchCorrectionScaleMode` is a closed enum of three cases (`:131-149`) — there is no way to express a custom N-note scale or a non-Western tuning. Every Melodyne comparison table found groups custom scales with the rest of the Assistant-tier toolkit. **[UNCONFIRMED]** the exact feature name/tier boundary from a single search pass.
2. **Per-note scale override / macro-driven scale changes mid-clip.** Ours is one scale for the whole `PitchAutoCorrectOptions` call (`Sources/DAWCore/PitchCorrectionPresets.swift:77-93`) — a key change mid-song has no representation.
3. **Auto-Key** (§1 table) — defaulting the scale to a detected key is separately absent and separately cheap, per our own source's construction note.

Both #1 and #2 are additive to the existing enum/struct shape, not architectural changes — the harder work (`nearestAllowedMidi`) already exists.

---

## 5. `TakeAlignment.swift:96` — the finding the task asked me to check by name

**Confirmed: the per-pair offset list is computed and then discarded.**

`Sources/DAWCore/TakeAlignment.swift:92-109`:
```swift
// 4. Median refinement over the winner's matched pair deltas.
let winningPairs = matchPairs(reference: reference, candidate: candidate,
                              candidateOffset: winner.offset,
                              tolerance: matchToleranceSeconds)
let deltas = winningPairs.map { $0.candidate - $0.reference }.sorted()
let refined = median(ofSorted: deltas)
...
return AlignmentResult(
    offsetSeconds: refined,
    matchedOnsets: winningPairs.count,
    ...
```

`winningPairs` — the full per-onset (reference, candidate) correspondence, i.e. exactly the point-pair list a time-warp needs — is computed, walked twice (once for the median, once for `residual`), and then **goes out of scope**. `AlignmentResult` (`:12-37`) carries only the scalar `offsetSeconds`, plus counts and an aggregate `meanAbsDeviationSeconds`. Nothing in the type or its caller (`ProjectStore.autoAlignTake`, `Sources/DAWCore/ProjectStore+TakeAlignment.swift:77`) retains the per-pair deltas.

**Why this matters for VocAlign-class alignment specifically**: VocAlign/Revoice Pro's actual method, per Synchro Arts's own description (fetched 2026-09-23), is *"measuring time-varying features of the... Guide and... Dub signals, comparing these features to find the best time-alignment PATH"* — [Synchro Arts, product description](https://www.synchroarts.com/vocalign) — a **path**, i.e. a continuous, non-constant warp, not one global offset. That is structurally the same shape as our discarded `winningPairs`/`deltas` list: a set of (reference-time, candidate-time) correspondences that, if kept and interpolated between, would let a candidate performance be time-warped onto a guide's phrasing at each syllable rather than shifted uniformly.

**What we have today is the single-offset degenerate case of that** — `TakeAligner.align` already does the correspondence-finding and matching (the hard, DSP-adjacent part) and then throws away exactly the information a warp needs, keeping only its median. Turning this into a genuine alignment feature does **not** need a new detector or a new algorithm — it needs:
1. `AlignmentResult` to optionally carry the `deltas`/pair list (or a caller-provided `perOnsetOffsets: [(referenceSeconds: Double, offsetSeconds: Double)]`).
2. A consumer that turns that into a piecewise time-warp.

**Speculative, flagged as such**: my first draft proposed reusing `NoteSegment.timeStartDeltaSeconds`/`timeEndDeltaSeconds` directly as that consumer. That is NOT verified and should be treated as a hypothesis, not a plan — a take being aligned to a guide has not necessarily had `clip.detectPitch` run on it at all, so there may be no `NoteSegment` table to carry the offsets on; `PitchEditSet` is keyed to *detected notes*, and an alignment warp's natural unit is *onsets*, which is a different granularity (`detectTransients`, not `PitchAutoCorrect.voicedRuns`). The two might share a time-warp *representation* at the render/stretch level (both ultimately need a piecewise time schedule fed to `OfflineStretcher`), but claiming they'd share the *same persisted field* on `NoteSegment` is a guess I have not checked against `OfflineStretcher`'s actual curve-input shape. Treat this as "two features that might share render-side plumbing," not "one field serves both."

---

## 6. What is genuinely hard (named separately, per the task's instruction)

1. **Note assignment / multi-candidate detection** (§2). Hard because it needs the detector to expose more than an argmax, and SwiftF0 — verified in `m23-q` §5.6.2 — does not.
2. **Polyphonic separation (Melodyne DNA).** Not attempted anywhere in this tree, and rightly so — `m23-q` §2.4 scoped the whole milestone to **monophonic** correction on a monophonic detector, and the 2026-09-22 design doc names polyphonic separation as "different problem class, never asked for" (§10, item 6). Correctly out of scope; named here so it stays named as hard rather than silently absent.
3. **Note separation of a legato run with no silence gap.** `PitchAutoCorrect.voicedRuns` (`:939-949`) documents its own limitation directly: *"It does NOT split a legato phrase where the singer changes note without stopping... a test pins exactly that so the limitation is visible."* Needs a pitch-change-triggered splitter fused with `detectTransients` evidence — a real segmentation algorithm, not a parameter add.
4. **Sibilant detection** (§1). A genuine classifier problem — distinguishing "s/z/ch/k/t" noise bursts from voiced content is a different signal-processing task than f0 tracking, not a byproduct of it.
5. **Synthesized vibrato rate** (§3) — new field types plus a generator, smaller than #1–4 but genuinely new mechanism, not wiring.

Everything else in §1's table — the contour-supply fix that revives drift/vibrato/hardTune, formant/timing/amplitude wiring, Flex-Tune/Humanize/Auto-Key, custom scales, audio-to-MIDI, leveling, the alignment offset-retention — is **wiring or additive schema work against machinery that already exists and is already tested or measured**, a materially different (and cheaper) category than the five items above.

---

## 7. Recommended order, and what I would NOT build

Ordering principle: **restore what the model already computes before building anything new** — that is one item, not a category, because a single contour-supply change un-starves two fields and one preset at once. Then land cheap wiring, weighing Melodyne's own tier signal honestly rather than only by our render cost. Then treat "hard" items as their own milestones.

1. **Supply a detected contour to the render path (fixes drift, vibrato, and `hardTune` in one change).** This is the highest-leverage item in this whole doc. `PitchCorrectionCurve.make(editSet:contour:clipPitchShiftSemitones:)` already accepts `contour: [ClipPitchFrame]` (`:719-729`) — the render path just calls it with `[]`. `PitchCorrectionPresets.swift:125-127` states the unlock condition itself: *"Remove this property [`offeredInUI`'s withholding of `hardTune`] — not edit it — once the contour reaches the render path."* **The honest cost, not assumed**: the detected contour is deliberately NOT persisted (`m23-q` §7.3/§7.8 — "regenerable analysis," matching `clip.detectPitch`'s own read-only, uncached design per `docs/design/2026-09-22-pitch-editor-ui.md` §2.3), so the render path must either re-run detection at render time or be handed a freshly-detected contour by the same caller that built the `PitchEditSet` — an architecture decision, not a trivial plumbing change, and I have not sized it. Flagging its existence and its payoff (three features at once) is this doc's job; sizing it is a `daw-architect` question.
2. ⚠️ **RE-MEASURED: Increment B (the four presets) is already shipped end-to-end — wire, store op, MCP, AND the UI door — per the Actionable takeaways correction above.** There is no remaining "finish the door" work; item 1 is what remains, and it is a render-quality fix (`hardTune` sounding correct), not a missing capability.
3. **Auto-Key.** Per our own source, this is a *construction*, not a translation table (`PitchCorrection.swift:128-130`), and it directly targets the failure mode the same file's header calls "the default for exactly the material it handles worst" (§2). High leverage, low cost — arguably underpriced relative to its place in this list.
4. **Weigh the tier signal honestly before choosing between timing and amplitude/formant next.** Celemony's own tier copy: *"Essential provides all the basic tools to adjust pitch, timing and note length"* — formant, vibrato-depth, and amplitude land at Assistant ([Whipped Cream Sounds comparison](https://www.whippedcreamsounds.com/compare-melodyne-versions/); [The FX Chain comparison](https://thefxchain.com/pages/melodyne-5-comparison)). That ranks **timing as core, not premium** in the product this doc is benchmarking against — and the user's own brief for Increment C explicitly asks for timing ("make the narrower or expand"). Render-difficulty reasoning (timing interacts with neighbours and a stretch ceiling; amplitude is a plain gain multiply) argues for sequencing amplitude and formant first regardless. **Both signals are real and they disagree — that disagreement should go to the user, not get silently resolved by picking the cheaper axis.** My default, stated as a recommendation and not a ruling: land amplitude (near-free) and formant (substrate already exists per `m23-q` §3.1) first on cost grounds, but flag Phase 3 timing as higher priority than its current backlog position if user testing shows people reach for it — which the tier data suggests they will. One additional wrinkle worth noting: our `driftScale` already covers what Flex Pitch needs two separate hotspots for (drift-in and drift-out), which is arguably the "closest thing to a minimal viable set" the task named Flex Pitch as being — our simplification there may already be the right level of ambition, independent of this ordering question.
5. **Fix `TakeAlignment.swift:96` — stop discarding `winningPairs`.** Small, low-risk (add a field, keep data already computed), and unlocks a real VocAlign-class alignment feature (§5). Whether it also feeds Phase 3 timing is speculative (§5) and should not be assumed while sizing this.
6. **Then Phase 3 (per-note timing) as its own milestone**, per the existing `m23-q` phasing.
7. **Custom scales, Flex-Tune, Humanize** — small, additive, no dependency on the hard items; land opportunistically after item 3.
8. **Audio-to-MIDI, Leveling macro, per-note fades** — cheap, no urgency; build when a concrete use case asks, not speculatively.
9. **Note assignment (§2), legato-run splitting (§6), sibilant detection (§6) as their own scoped design spikes**, not folded into Increment C. None has any substrate today — the 2026-09-22 design doc's Increment C table (C1–C5) accounts for none of them, and folding them in would repeat the mistake `m23-q` §11.2 warned about for the editor as a whole: *"the editor UI... is the single largest chunk... because it has no substrate."* These have even less.
10. **What I would NOT build**: synthesized-vibrato-rate (§3) ahead of the above — it is a generator feature layered on a correction feature, its competitive precedent is unconfirmed even for Melodyne, and everything else in this list either has its substrate already or is smaller. I would also not build polyphonic separation, real-time correction (deliberately architecturally excluded, §1), or ARA hosting (already declined per design doc §10 item 10) without an explicit, separate user decision reopening that scope.

---

## Sources

**Primary (our code, all read in full or targeted, this session; UI/wire status re-grepped a second time after initial review flagged the design doc's own table as stale):**
- `Sources/DAWCore/PitchCorrection.swift` (1187 lines)
- `Sources/DAWCore/PitchCorrectionPresets.swift` (129 lines)
- `Sources/DAWCore/TakeAlignment.swift` (179 lines)
- `docs/design/2026-09-22-pitch-editor-ui.md` (1457 lines)
- `docs/research/m23-q-pitch-correction-design.md` (lines 1-381 read directly; further sections cross-cited via the design doc's own quotations, cited as such where used)
- `Sources/DAWControl/Commands.swift:809-811,4886,5000,5021` — wire verbs, re-grepped
- `Sources/DAWCore/ProjectStore+PitchCorrection.swift` — store op, re-grepped
- `mcp-server/src/server.ts:8671,8788,8805` — MCP tools, re-grepped
- `Sources/DAWApp/Timeline/TimelineLanesView.swift:4093-4095` — the live "Tune Vocal" context menu, re-grepped
- `Sources/DAWApp/PitchEditor/PitchEditorView.swift` — Increment A's live read-only view, re-grepped
- `Sources/DAWEngine/Stretch/StretchCurvePlan.swift:78,83-84`, `Sources/DAWEngine/Stretch/StretchRenderCache.swift:344-348` — re-confirmed contour still defaults empty and is still not supplied
- Grep census: `sibilant|deEsser|de-esser|noteAssign|reassignPitch|pitchClassOverride` across `Sources/` — 7 hits, none related to pitch note-assignment (effects-chain de-essers/frequency references, unrelated subsystem)

**External (fetched 2026-09-23, dated as such; direct-fetch and search-summary sources kept distinct):**
- [Celemony: Melodyne editions](https://www.celemony.com/en/melodyne/melodyne-5-editions)
- [Whipped Cream Sounds: Melodyne 5 version comparison](https://www.whippedcreamsounds.com/compare-melodyne-versions/)
- [The FX Chain: Melodyne 5 comparison](https://thefxchain.com/pages/melodyne-5-comparison)
- [Sound on Sound: Pitch-correcting vocals with Melodyne](https://www.soundonsound.com/techniques/pitch-correcting-vocals-melodyne)
- [Pro Tools Training: Editing in Melodyne — manual tools guide](https://www.protoolstraining.com/blog-help/pro-tools-blog/tips-and-tricks/468-editing-in-melodyne-manual-tools)
- [Celemony: Tools for note assignment](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_NA_Mode_Tools)
- [Celemony: Pitch modulation and drift](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolModulationDrift_2?env=standAlone) — names the Pitch Modulation Tool and Pitch Drift Tool as the two sub-tools of the Pitch Tool
- [Celemony: Time Handles and Attack Speed](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolTimeHandlesAttackSpeed_2)
- [MusicTech: Celemony announces Melodyne 5 (sibilant detection)](https://musictech.com/news/gear/celemony-announces-melodyne-5/)
- [Facebook/Celemony: Melodyne 5 leveling tools reel](https://www.facebook.com/Celemony/videos/melodyne-5-the-leveling-tools/276709953694151/) — low-confidence source, cited only for feature naming
- [Antares: Auto-Tune Pro X tutorial overview](https://www.antarestech.com/blog/auto-tune-pro-x-tutorial-overview)
- [Apple Support: Edit pitch and timing with Flex Pitch in Logic Pro](https://support.apple.com/guide/logicpro/edit-pitch-and-timing-with-flex-pitch-lgcpc53e6bef/mac)
- [Synchro Arts: VocAlign](https://www.synchroarts.com/vocalign)
- [Synchro Arts: Revoice Pro features](https://synchroarts.com/products/revoice-pro/features)

**Direct fetch attempted and failed**: `helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolMain` (the toolbox overview page) — `WebFetch` returned `socket hang up` on two attempts. Every Melodyne tool name in this doc is therefore sourced from search-result summaries of Celemony/third-party pages (cited individually above), not from a directly-read Celemony toolbox page, except where the "Pitch modulation and drift" page's content is quoted directly from the search snippet.

**Marked [UNCONFIRMED] in the body, and why:** the exact tier boundary at which Melodyne introduces custom/arbitrary scales (§1, §4); whether Melodyne's Pitch Modulation Tool can reshape/re-rate modulation, not just scale depth (§3); Flex-Tune's exact mechanism, taken from a search summary rather than independently re-verified against Antares's manual text (§1); the precise sub-tool names "Time Handle" and "Fade" as distinct from their parent tools, taken from search summaries of third-party guides rather than a directly-fetched Celemony page (§1).
