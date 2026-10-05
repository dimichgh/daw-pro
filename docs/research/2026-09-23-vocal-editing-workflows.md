# How Melodyne-class tools are actually used — workflows, ergonomics, complaints, and what we should do differently

**Date:** 2026-09-23
**Author:** research-analyst
**Ask:** *"just look at melodyne and similar product on how they allow to edit vocals and make it better."* Follow-up to `docs/research/2026-09-23-melodyne-class-pitch-editors.md`, which answered *what capabilities exist*. This one answers *how a person actually works in these tools*, and feeds the still-open interaction questions in `docs/design/2026-09-22-pitch-editor-ui.md` §7.
**Method, carried over and reinforced:** primary source = our own code, cited file:line, **re-measured this session, not quoted from the design doc's own table** (that table warns of its own staleness and, confirmed below, had already gone stale again). Competitor claims = cited to a fetched page or an explicitly-labelled search summary, dated 2026-09-23. **Action counts are constructed by me from the documented steps unless a source states a count directly** — every action-count line below says which. Nothing is asserted about a competitor from memory; unconfirmed claims are marked as such.

---

## Actionable takeaways (summary — full evidence in §§1–5)

1. **Re-measured this session: Increment B (the four presets) is FULLY LIVE, not "gated on one store op" as both the design doc's dated table and my own first draft of this doc said.** Wire verbs (`Sources/DAWControl/Commands.swift:809-811,4886,5000,5021`), the store op (`Sources/DAWCore/ProjectStore+PitchCorrection.swift`, writes `pitchEdits`), MCP tools (`mcp-server/src/server.ts:8671,8788,8805`), **and the UI door — a "Tune Vocal" context-menu item wired to `onTuneVocal`/`autoCorrectClipPitch`** (`Sources/DAWApp/Timeline/TimelineLanesView.swift:4093-4095`) — are all present. Increment A's read-only pitch-editor view (blobs, contour, pitch ruler) is also live (`Sources/DAWApp/PitchEditor/PitchEditorView.swift`). **What is still NOT live**: `StretchCurvePlan.make` still defaults `contour: [ClipPitchFrame] = []` and `StretchRenderCache.performRender` still calls it with no contour argument (`Sources/DAWEngine/Stretch/StretchCurvePlan.swift:78,83-84`; `Sources/DAWEngine/Stretch/StretchRenderCache.swift:344-348`) — so the prior doc's contour-starvation finding stands: `hardTune` still degrades, drift/vibrato are still starved, **even though the UI to reach them is now built.**
2. §1's per-workflow "our current path" entries are corrected below against this measurement — several read as unbuilt in an earlier pass and are, in fact, shipped.
3. The agent-driven angle (§4.1) has a sharper form than "would be valuable": **the wire/MCP door is the ONLY door for anything past Increment B** — no product surveyed here has an end-user scriptable surface at all (checked, including ARA, which is a host↔plugin protocol, not a user-facing instruction layer), so an agent instruction is not competing with a faster mouse workflow on Increment C-class edits; it is the only workflow that exists until Increment C ships.
4. §5's five §7 recommendations stand as researched, with two corrections from review: §5.2 (multi-select empty-selection default) now rests on the novice-safety rule alone, not an invented complaint; §2.1's Melodyne modifier-key claim is now stated as a disagreement between sources, not resolved.

---

## 0. What I read before starting

`docs/design/2026-09-22-pitch-editor-ui.md` §7 (lines 883–1180) in full, including **§7.2b**, the correction where the user identified that the "glowing circle" in the reference frames was the screen recorder's own click-highlight chrome, not a product feature — and the design doc's own retraction of two readings built on it. That correction is the single most load-bearing fact for §5 of this doc: it means Melodyne's **own** documented tools (verified below, not the misread frames) are now the primary evidence for the open §7 questions, more than they were when the design doc was written.

⚠️ **A second, unplanned correction happened while writing this doc.** The design doc's own §4 prerequisite table (dated 2026-09-22, R3 marked ⛔) carries its own warning: *"Do not quote this table. Re-run the four probes... if a rung disagrees with what you find, the tree is right and this table is stale."* I quoted it anyway in an earlier pass of this doc. Re-running those probes plus a direct grep on the UI layer (§1's "Actionable takeaways" item 1) shows **R3 has since landed in full, UI included** — two agents active in `Sources/DAWApp/PitchEditor/` per this task's own standing constraint shipped exactly the work the table still describes as pending. Every "our current path" line in §1 below reflects the **re-measured** state, cited file:line, not the design doc's table.

---

## 1. THE WORKFLOWS, concretely

Each workflow below is built from Celemony/Antares/Synchro Arts's own documentation and third-party walkthroughs, cited per step. **Action counts are my own construction from the documented steps — marked [CONSTRUCTED] — except where a source states a number directly, marked [SOURCE-STATED].** I did not find a single source that states a raw click-count for any of these six workflows; every editing tool's own documentation describes *sequences*, not counts, which is itself a finding (§3).

### 1.1 Tune a lead vocal that is mostly fine (the 80% case)

**Melodyne**, per Celemony's own Correct Pitch macro documentation and a Sound on Sound walkthrough:
1. Select all notes (⌘A). [SOURCE-STATED gesture, per a search summary of Celemony's macro page]
2. Open the **Correct Pitch macro** (Edit ▸ Quantization Macros ▸ Correct Pitch, or its toolbar button) — [Celemony: Correct Pitch Macro](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_MacroPitch?env=dawsWithAra).
3. Set the **pitch-center slider** (a search summary of common practice cites ~70–80%, not a hard default) and, separately, the **drift-containment slider**.
4. Apply. This is ONE macro invocation covering every selected note — **not per-note**, which is the whole point of a macro.
5. Listen; manually drag any note the macro under/over-corrected.

**[CONSTRUCTED] action count for a clean 20-note phrase, assuming ~3 notes need a manual touch-up**: ⌘A (1) + open macro (1) + set 2 sliders (2) + Apply (1) + 3 manual drags (3) = **~8 actions**, independent of the phrase's note count for the bulk of the work — this is the central ergonomic fact of a macro-based workflow: **cost is O(exceptions), not O(notes).**

**Our current path, re-measured**: **1 action** — the shipped "Tune Vocal ▸ Natural" context-menu item (`TimelineLanesView.swift:4093-4095`, wired through `onTuneVocal` to `ProjectStore.autoCorrectClipPitch`, which is live per the takeaways). We have collapsed Melodyne's slider-tuning step into a fixed preset (`docs/design/2026-09-22-pitch-editor-ui.md` §6.5: *"No 'tuning strength' slider in v1... exist precisely so a novice does not have to understand strength × retune speed"*). **This is fewer actions than Melodyne's own default path for the 80% case AND it is shipped, not planned** — the gap is Melodyne's manual-touch-up step (step 5 above), which is Increment C, not yet built.

### 1.2 Fix ONE bad note in an otherwise good take

**Melodyne**: click-drag the blob vertically to the target pitch, or double-click to snap it to the nearest scale pitch — [Sweetwater Melodyne Quickstart](https://www.sweetwater.com/sweetcare/articles/melodyne-quickstart-guide/) (search-summary sourced): *"If you double-click with the Main Tool on the middle part of a note... you quantize the note(s) in question to the nearest pitch allowed by the current Pitch Grid."* **[CONSTRUCTED] action count: 1 (double-click) for a note that just needs scale-snapping, or 1 drag for a note that needs to land somewhere off-grid.** This is the single cheapest operation in any of these products, by design — it is the product's whole reason to exist.

**Our current path, re-measured**: no per-note editing exists yet in the app's mouse UI — Increment A's `PitchEditorView` (confirmed live, `Sources/DAWApp/PitchEditor/PitchEditorView.swift`) draws blobs but is documented read-only (design doc §5.1: *"Nothing is draggable"*), and the only mouse-driven correction lever is the whole-clip preset from §1.1, which re-corrects every note, not one. **This is a real, named gap** relative to Melodyne's 1-action fix, and it is exactly Increment C's job. **The wire, however, is not similarly limited**: `clip.autoCorrectPitch`/`clip.getPitchEdits` can already inspect and (whole-clip only) rewrite a `PitchEditSet` from an agent — closing this specific per-note gap for a MOUSE user needs Increment C; closing it for an AGENT needs only a new verb operating on one segment id, which is a much smaller addition given the store op and undo keys (`PitchCorrectionUndoKey.segment`) already exist (confirmed in the prior doc).

### 1.3 A note the detector got wrong

Three distinct sub-cases, each a different tool in Melodyne, confirmed via search summaries of Celemony/forum sources:

- **Octave error.** Per a Gearspace-sourced search summary: *"Users confirm the occasional 'displaced octave' anomaly... a gravelly, unpitched component can mislead Melodyne to interpret a note as a low octave."* Fix: **Note Assignment Mode** — switch mode ([F2]/toolbar), click the "ghost blob" at the correct octave (§2 of the prior doc). **[CONSTRUCTED]: mode switch (1) + click ghost blob (1) = 2 actions**, IF a ghost blob exists at the right position — the same search summary notes *"there's not a whole lot one can do"* when it doesn't, meaning this fix has a **floor of 2 actions and no ceiling** when the detector offers no correct candidate at all.
- **Two slurred notes read as one.** Fix: the **Note Separation Tool** ([F6] or toolbar) — click where the split should be. **[CONSTRUCTED]: tool switch (1) + click split point (1) = 2 actions.** Our own `PitchAutoCorrect.voicedRuns` has the identical documented limitation (`Sources/DAWCore/PitchCorrection.swift:939-949`) and Increment C3 (split) targets exactly this case.
- **A breath read as a note.** Two documented Melodyne paths, both confirmed via search summary of Celemony/production-expert sources: (a) **deactivate** the note via Note Assignment Mode — the search summary states Melodyne "creates a silent note" rather than leaving spectral energy with nowhere to go; **[UNCONFIRMED] whether this produces genuinely audible silence at that point in the file or is a bookkeeping/reassignment state** — the summary describes the mechanism, not a verified listening result, and I have not checked it against Celemony's manual text directly; (b) set the **Sibilant Balance Tool** to −100%, eliminating breath/sibilant noise while leaving pitched content untouched. **[CONSTRUCTED]: path (a) is mode switch + select blob + deactivate = 3 actions (the mode switch was omitted from an earlier count of this doc — corrected here); path (b) needs the note separated first if it isn't already its own blob (+1), then the tool set to −100% (1–2 more).** We have **no equivalent of either path** — no note-deactivation concept and no sibilant tool at all (confirmed absent in the prior doc §1/§6).

### 1.4 Make a robotic/hard-tuned effect deliberately

**Auto-Tune**: set **Retune Speed** to 0 ("the famous Auto-Tune Effect") — [Antares Auto-Tune Pro docs, search-summary sourced]. **[CONSTRUCTED]: 1 knob turn**, applied to the whole track in real time, no per-note action at all — this is Auto-Tune's headline UX advantage for this specific case: it needs no note-by-note interaction whatsoever.

**Melodyne**: no single "make it robotic" switch exists in the documentation found; the closest equivalent is running the Correct Pitch macro at 100% strength with drift and modulation flattening also applied — a macro-plus-manual-flattening combination, **not** a single dedicated control. **[UNCONFIRMED]** whether a later Melodyne version added a one-click hard-tune macro; none turned up in this search pass.

**Our current path, re-measured**: the **`hardTune` preset**, reachable through the SAME live "Tune Vocal" menu as §1.1 — **1 action**, same shape as Auto-Tune's single knob — **except it does not currently sound like hard tune**, confirmed again this session: `StretchCurvePlan.make` still defaults to `contour: []` (`StretchCurvePlan.swift:78`) and `StretchRenderCache.performRender` still does not pass one (`StretchRenderCache.swift:344-348`), so per the prior doc's §0 measurement it degrades to a stronger `Tight` (median 62.1¢ vs Tight's 18.8¢). **The UX shape is fully shipped; the audio behind it is not.**

### 1.5 Tighten a double or a stack against a lead

This is **not a pitch-correction task at all** in the professional workflow — it is a **time-alignment** task, and the tool used (VocAlign/Revoice Pro) is architecturally separate from Melodyne/Auto-Tune. Per Synchro Arts's own quick-start documentation (search-summary sourced, [VocAlign Ultra Quick-Start for Logic Pro X](https://www.synchroarts.com/manuals/VocAlignUltraV1.1/Manual/HTML/vocalign-ultra-quick-start-guide-for-logic-pro-x.html)):
1. Insert the plugin on the **Guide** (lead) track.
2. Turn on **Link** between the Guide and Dub instances.
3. On the **Dub** (double) track, set the sidechain input to the Guide.
4. Select the regions to work on; click **Dub Capture**.
5. Click **Align**.

**[CONSTRUCTED]: ~5 actions** to align one phrase, largely fixed-cost regardless of the phrase's length or note count — the workflow is built around **SmartAlign**, which per the same source *"intelligently aligns audio in a dub that doesn't start or end at the same points... no pre-editing needed"*, i.e. the product is explicitly designed to avoid manual onset-matching.

**Our current path**: `take.autoAlign` — **1 action**, per `docs/research/m23-q-pitch-correction-design.md` §3.4's description of `ProjectStore.autoAlignTake`. **Fewer actions than VocAlign's own quick-start**, but a materially weaker result: per the prior doc §5, our aligner computes a full per-onset correspondence (`TakeAligner.align`'s `winningPairs`) and then collapses it to a single scalar median offset — a **whole-lane shift**, not VocAlign's continuous **warp path**. So: cheaper to invoke, structurally less capable once invoked. This is not a contradiction — it means our 1-action version solves a narrower problem (gross sync) than VocAlign's 5-action version (syllable-level phrasing match), and the prior doc's §5/§7 already recommends closing that gap by keeping the per-onset data we already compute rather than discarding it.

### 1.6 Fix timing without touching pitch

**Logic Flex Pitch / Flex Time**: these are Apple's own **separate tools** — Flex Time handles timing, Flex Pitch handles pitch, and a user moves between them explicitly (confirmed structurally by Apple's own naming and by every walkthrough found treating them as two features, not one dial). **[CONSTRUCTED]: switch to Flex Time mode (1), drag the region/transient (1 per edit)** — the separation is real and is a genuine ergonomic answer to "fix timing without touching pitch": **the two axes are never on the same control**, so there is no way to accidentally move one while adjusting the other.

**Melodyne**: the **Time Tool**, with its **Time Handle** and **Attack Speed** sub-tools (confirmed, [Celemony: Time Handles and Attack Speed](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolTimeHandlesAttackSpeed_2)) — same separation-by-tool-selection principle as Flex Time; picking the Time Tool guarantees a pitch drag cannot happen by accident, because it is a different tool occupying the same toolbar slot.

**Our current path**: `timeStartDeltaSeconds`/`timeEndDeltaSeconds` exist on `NoteSegment` (confirmed, `Sources/DAWCore/PitchCorrection.swift:317-318`) but are **completely unwired** — no UI, no render read (confirmed in the prior doc's render-column audit and re-confirmed this session — nothing in `StretchRenderCache.swift`/`StretchCurvePlan.swift` reads either field). There is no answer to this workflow today; it is entirely Phase 3.

---

## 2. THE ERGONOMICS

### 2.1 Modifier keys and drag axes — the snap-vs-free answer, product by product

This is the sharpest, most directly reusable finding for our own §7 questions, and every product answers it differently:

| Product | Default drag behaviour | How you get the OTHER behaviour | Source |
|---|---|---|---|
| **Melodyne** | **Snaps to the current Pitch Grid** (Scale / Chromatic / None, chosen via a clef-icon menu) | **Sources disagree on the exact key, and this is stated as a disagreement rather than resolved**: one search summary states *"Hold Alt (PC) or Cmd (Mac) and drag"*; another, independently, states *"snap can temporarily be disabled by holding the [OPTION/ALT] key while dragging."* Both agree Option/Alt works; only the first names Cmd as a Mac equivalent, and neither source's exact wording was independently checked against Celemony's manual text. **Do not read this as a confirmed ⌘/⌥ equivalence — read it as Option/Alt confirmed, Cmd unconfirmed.** | [Sweetwater Melodyne Quickstart](https://www.sweetwater.com/sweetcare/articles/melodyne-quickstart-guide/) and a second, separately-worded search summary — both search-summary sourced, not cross-checked against each other by the search tool |
| **Melodyne, double-click** | **Quantizes instantly** to the nearest pitch allowed by the CURRENT grid setting (semitone if Chromatic, scale degree if a Scale is active) | N/A — double-click is a discrete action, not a drag; there is no "double-click but free" variant found | Same sources |
| **Design doc's C1 spec (ours, planned)** | *"vertical = pitch. Snap to scale, ⌥ for free"* (`docs/design/2026-09-22-pitch-editor-ui.md:1014`) | ⌥ | Design doc, not yet built (Increment C) |

**The finding: our planned C1 behaviour uses the SAME Option/Alt modifier and the SAME default-snap convention Melodyne's confirmed mechanism uses.** This is worth stating plainly because it means the open question is not "what should the modifier be" — Option/Alt is confirmed by at least one source and matches our own plan — it is **whether double-click should ALSO exist as a discrete quantize action**, which the design doc's §7.1 fork 3 leaves open and Melodyne answers with a clear yes. §5 recommends closing that fork using this evidence.

### 2.2 Multi-select — confirmed mechanism, and where it disagrees with our undo model

Per Celemony's own **Selecting notes** page (search-summary sourced, [helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_SelectingNotes](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_SelectingNotes?env=standAlone)):
- **Rubber-band/lasso**: click-drag in empty space around the desired blobs.
- **⌘-click** to add individual notes to a selection.
- **⌘-drag** to add a further rubber-band region to an existing selection.
- **Macros act on the selection if one exists, and on EVERYTHING if none does.** Worth naming as a real, deliberate design decision: Melodyne's macros have **no "nothing selected → do nothing" state** — an empty selection is read as "the whole file."

**Our gap, already named precisely in the design doc**: §8.4 states *"`PitchCorrectionUndoKey` provides no group key... N segments dragged together would push N entries, and undo would peel them off one at a time."* Melodyne's own undo model is not documented in enough detail from this search pass to confirm whether it has the same problem or solved it differently — **[UNCONFIRMED]**, flagged rather than guessed at.

### 2.3 Note separation / merge — the exact gesture, verified

Per Celemony's own **Note separation tools** page (search-summary sourced, [helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolSeparations_2](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolSeparations_2?env=standAlone)):
- **Split**: select the Note Separation Tool ([F6] or toolbar/context menu), click at the point to split.
- **Merge ("un-separate")**: **double-click an EXISTING separation marker and it disappears** — the two blobs recombine. This is the SAME tool as split, not a different one; split and merge are one tool, distinguished by *where* you click (empty space within a note = split; an existing separation marker = remove it).
- **Multi-note propagation**: *"If you select several notes and move a note separation, the note separations of the other selected notes will also be moved. If you double-click one of the note separations to remove it, those of the other selected notes will also be removed."* — a genuinely clever piece of ergonomics: a merge operation, once learned, batches for free across a multi-select with no separate "merge all" command needed.

**This directly answers one of the five open §7 questions** (§5 below): merge is not a new tool or a new gesture — it is the **existing split tool's own inverse action**, triggered by clicking an existing boundary instead of empty note interior. This is a different double-click than §2.1's: Melodyne's double-click means something different **per active tool** (Main Tool → quantize; Note Separation Tool → merge-if-on-a-boundary) — consistent with a tool-palette model (confirmed as the correct reading of TUNE X's own bottom palette per the design doc's §7.2), not a conflict.

### 2.4 Auto-Tune's specific ergonomic answer to snap-vs-free

Per a search summary of Antares's own documentation:
- **Retune Speed** (0–400ms) is the primary dial — 0 snaps instantly and hard (the "Auto-Tune Effect"), higher values let the singer's natural pitch movement show through before the correction catches up.
- **Flex-Tune**: *"creates an 'ignore area' between half steps so scoops and dips don't get tuned so tightly"* — **[UNCONFIRMED against a primary source]**, description taken from a search summary, not independently re-verified against Antares's manual text. If accurate, this is a THIRD distinct answer to snap-vs-free, different from both Melodyne's (a modifier key, binary) and ours (a modifier key, binary): Auto-Tune's is a **continuous dead-zone threshold**, always active, no modifier needed — snap and free coexist per-note automatically based on how far off the note already is.
- **Humanize**: relaxes retune speed specifically on sustained notes, a second continuous, always-on mechanism layered on the same idea — the note gets more "free" time the longer it's held.

**The pattern across all three products**: nobody solves snap-vs-free with only ONE mechanism. Melodyne and our own C1 spec use a **binary modifier** (snap OR free, chosen at drag time). Auto-Tune layers **two continuous, automatic** mechanisms (Flex-Tune, Humanize) on TOP of its speed dial, so the tool decides "how free" per note without the user touching a modifier at all. This is worth naming as a real design axis we have not yet considered: **modifier-driven (explicit, per-gesture) vs. parameter-driven (automatic, per-note, no gesture)** are not mutually exclusive — Auto-Tune ships both simultaneously (Retune Speed + Flex-Tune).

---

## 3. WHAT USERS ACTUALLY COMPLAIN ABOUT

Every complaint below is drawn from a search summary of forum/community content (Gearspace, Apple Discussions, Cakewalk forums), not independently re-verified against the original forum post — flagged once here rather than per-line, consistent with the discipline this doc is asked to hold.

**Melodyne:**
- **Octave/displacement errors on gravelly or unpitched-adjacent material**, with no reliable fix beyond Note Assignment Mode, and even that fails when no candidate at the right octave exists — one search summary states plainly *"there's not a whole lot one can do"* in that case.
- **Gang-editing (macro over many notes at once) produces worse results than smaller batches** — one Gearspace-sourced summary specifically recommends editing "one note at a time" over macro-ing a whole track, which is a direct complaint about the QUALITY of the exact workflow Celemony's own quick-start documentation recommends as the default (§1.1). **This is a complaint about correction quality on a large batch, not about the empty-selection scoping behaviour described in §2.2** — the two are related (both are about macro-over-many-notes) but are not the same claim, and §5.2 below does not rest on this complaint.
- **Learning curve is repeatedly named as real** ("Melodyne has a definite learning curve") across multiple comparison sources, specifically contrasted against Waves Tune's simplicity.

**Auto-Tune:**
- **Warble on ambiguous/microtonal pitch** — when the detector genuinely cannot commit to a target semitone, the correction audibly oscillates between two candidates.
- **Artefacts that don't exist in the source material** are reported as appearing after correction, described as inconsistent across "programs" (implying Auto-Tune is not uniquely bad, but not immune either) — **[weakly sourced]**, this was the vaguest of the complaint clusters found and deserves a lower confidence weighting than the other two.
- **Robotic sound at fast retune speeds** is treated by users as EITHER a complaint OR a deliberate effect depending on context — i.e., the same behaviour is the product's most-loved feature and most-hated side-effect, purely depending on user intent. Worth naming because it means "artefact" and "feature" are not fixed categories for this class of tool — they are entirely about whether the user asked for it.

**Logic Flex Pitch — the sharpest and most concrete complaint set found:**
- **Gaps where the detector fails entirely**, contrasted directly against Melodyne: *"Melodyne detects everything without leaving such gaps."* Doesn't detect sibilance/consonants at all.
- **A specific regression, dated and Apple-acknowledged**: *"In Logic Pro 10.7.5 or 10.7.6 on macOS Ventura, Logic Pro can incorrectly assign audio files analyzed with Flex Pitch to note C0"* — [support.apple.com, search-summary sourced] — a genuine, versioned, vendor-acknowledged bug, not user error.
- **Crackling/popping artefacts after correction**, reported as inconsistent and unpredictable ("no consistency or pattern"), specifically triggered by the tool trying to pitch-correct **consonant attacks** — "s" and hard-consonant onsets are treated as pitched content and warped, producing audible pops. This maps directly onto our own §1.3's "breath read as a note" case and §1's sibilant-handling gap: **Flex Pitch's worst-reported failure mode is exactly the failure mode Melodyne 5 built a dedicated Sibilant Balance Tool to solve, and exactly the failure mode we have no answer to at all** (confirmed absent in the prior doc).
- Multiple users report abandoning Flex Pitch for Melodyne specifically because of these artefacts, on "critical work."

**Cross-cutting pattern worth stating plainly**: two of the three most concrete, most-repeated complaint clusters (Flex Pitch's consonant-attack artefacts, Melodyne's own historical sibilant handling before v5 added a dedicated tool) are the SAME underlying problem — **unvoiced/consonant content being treated as pitched content by a detector that was not built to tell the difference.** Our own detector (SwiftF0) makes the identical binary voiced/unvoiced call with no sibilant-specific classification (confirmed in the prior doc). This is independent corroboration, from user complaints rather than a feature-list comparison, that sibilant handling is a real and recurring pain point across this entire product class — not a Melodyne-5 marketing feature nobody actually needs.

---

## 4. WHERE WE COULD BE BETTER — argued, not asserted

### 4.1 The agent-driven angle

**The claim to test**: *"Every one of these products is mouse-only... 'Fix the flat notes in the second chorus' as an instruction rather than forty drags is a thing none of them can do."*

**Checked, not assumed — I specifically searched for a programmatic surface rather than reasoning from its absence in unrelated searches.** The one credible candidate is **ARA (Audio Random Access)** — Celemony's own interoperability layer, now open-source ([Celemony/ARA_SDK on GitHub](https://github.com/Celemony/ARA_SDK)), which does real bidirectional exchange of note/tempo/key/scale data between a host DAW and a plugin like Melodyne. On inspection this does **not** contradict the claim, it narrows it correctly: ARA is a **host-to-plugin data protocol for DAW vendors to implement**, not an end-user or agent-facing instruction surface — there is no documented "ARA host sends a natural-language or rule-based batch-correction instruction" capability, only structured data exchange (audio samples, detected content, tempo/key metadata) that a DAW's own UI still has to turn into edits through the same mouse-driven tools surveyed in §1–§2. **So the corrected claim**: no product surveyed here — including the one with a real, open, documented programmatic layer — exposes an end-user-facing instruction surface of the kind "fix the flat notes in the second chorus" describes. This is a materially stronger claim than my first pass's untested absence, because it was checked against the most likely counterexample and the counterexample does not qualify.

**The case FOR the value being real:**
- §1.1 already shows the actual cost shape of these workflows is **O(exceptions), not O(notes)** — a macro handles the bulk, manual work handles the outliers. "Fix the flat notes in the second chorus" is precisely an *exception-selection* instruction: it identifies the outliers a macro-pass leaves behind, which is exactly the step every one of these workflows still requires a human to eyeball and click through one at a time. An agent that can (a) read `clip.getPitchEdits`/pitch detection data, (b) identify segments that are flat relative to their nearest scale degree by more than some threshold, and (c) issue per-segment corrections through a wire verb is automating exactly the step Melodyne's own documentation admits is manual (§1.1 step 5) and that its users report needing to do carefully, in small batches, not gang-applied (§3's gang-editing complaint).
- The "second chorus" framing specifically requires **musical/structural context** (verse/chorus boundaries) that none of these tools' pitch-editing surfaces model at all — they operate on one clip's note table with no awareness of song structure, and ARA's data exchange (checked above) does not change this — it exchanges audio/tempo/key facts, not song-section semantics. An agent with access to the whole project (arrangement markers, region names, or even just "the clip the user is currently pointing at") can resolve "second chorus" into a set of segment IDs in a way no mouse-driven blob editor, ARA-integrated or not, is positioned to do, because the editor's own data model stops at the clip boundary.
- **This is not hypothetical for us the way it is for the competition**: per this doc's own re-measurement (§0, Actionable takeaways), the wire/MCP door for Increment B is already the ONLY door that exists for anything Increment B does not cover — Increment C (per-note edits) has no mouse UI yet at all, but `clip.getPitchEdits`/`clip.autoCorrectPitch` already exist. An agent instruction is not racing a faster mouse workflow on the per-note cases; today, for us, it is the only workflow.

**The case AGAINST — and it should be taken seriously, per the task's own instruction to argue against if evidence doesn't support it:**
- **Every corrective action in §1 that matters most (fixing one bad note, octave-reassignment, note separation) is a JUDGMENT call about a specific sound**, not a rule that generalizes cleanly to "all notes matching criterion X." The Melodyne octave-error complaint in §3 is instructive here: the fix requires listening and picking the RIGHT ghost blob, not applying a threshold. A rule like "fix flat notes" is well-defined; a rule like "fix the notes that sound wrong because the singer scooped up from below on purpose vs. the notes that are wrong because they're actually off-pitch" is not something a scalar threshold on detected-cents-from-scale can distinguish — and that distinction is precisely what a human ear does effortlessly and a `pitchOffsetCents` comparison cannot. **An instruction like "fix the flat notes" risks correcting intentional expression along with genuine pitch errors, silently, which is a worse failure than doing nothing — it is the same "confident wrong answer" failure class this project's own standing rules are built around avoiding.**
- Every one of these tools' own vendors, despite decades of R&D and enormous commercial incentive to sell an "auto-fix everything" button, ship a **macro that still requires a manual pass** (§1.1) rather than a fully automated pipeline — and independently, `PitchCorrectionScale.chromatic`'s own doc comment (quoted in the prior doc §0) demonstrates that even a SIMPLE automated pass (snap-to-nearest-semitone) can score as an improvement by a naive metric while moving a note to the wrong pitch class entirely. **If a scale-snap macro can silently produce a worse result while looking better on paper, an agent instruction with a fuzzier target ("flat notes in the second chorus") has strictly more surface area to get this wrong, not less.**
- **The value of an agent instruction is bounded by how cheaply a human can verify the result**, and pitch correction is exactly the domain where verification requires LISTENING, not reading a diff. An agent that "fixes the flat notes" and reports success has the identical shape as this tree's own repeatedly-documented failure mode — "audible=true is not correctness," "a setter's return is not proof it took" — applied to music instead of code. The MCP tools already required for this (`clip.getPitchEdits`, a hypothetical batch-correct verb) can prove the DATA changed; nothing can prove it SOUNDS RIGHT except a human ear, which puts a hard ceiling on how much of this workflow can be handed to an agent without a listening step in the loop — a ceiling this project's own standing rule (§ "ship 3-4 options... their pick IS the feedback," cited via the design doc's own listening-round methodology, §12.5) already assumes exists for every preset decision.

**My verdict, stated as a recommendation, not a certainty**: the angle is real and valuable **specifically for the exception-finding and batch-execution parts of a workflow that these tools' own documentation already treats as manual and error-prone** (§1.1's step 5, §3's gang-editing complaint) — an agent proposing a list of candidate corrections for a human to confirm, rather than applying them silently, captures the value while respecting the verification ceiling above. I would NOT build "fix the flat notes" as a fire-and-forget instruction that writes edits without a review step; I WOULD build it as an instruction that returns a proposed edit set (via `clip.getPitchEdits`-shaped data, not yet applied) for the user to preview and confirm — which is also the shape the design doc's own §8.4 multi-select discussion is already heading toward (one undo entry over N segments, implying a batch operation is already an anticipated shape).

### 4.2 The novice angle

**Confirmed, cross-source**: every comparison found ranks these tools by learning curve, and the ranking is consistent — **Waves Tune Real-Time is explicitly marketed and reviewed as the beginner option**, specifically because it trades away Melodyne/Auto-Tune-Pro's deep editing for a small, clearly-labelled control set; Melodyne is repeatedly described as having "a definite learning curve"; Auto-Tune Pro is "steeper... but not bad." None of the four products found (Melodyne, Auto-Tune Pro, Flex Pitch, Waves Tune) is described anywhere in this research as designed FOR a novice from the ground up — Waves Tune wins the novice comparison by being the least professional-feature-complete option, not by solving novice-friendliness as a design problem in its own right.

**What this means for us, concretely**: our standing rule that the target user is a novice is not a compromise on top of a professional tool — it is a genuinely different design target than any single product surveyed here occupies. The nearest analogue in this research is our own four-preset shape (§6 of the prior doc, §1.1 here, and now re-confirmed as SHIPPED, not planned): a **fixed, named, small option set with a plain-language description per option**, which is structurally closer to Waves Tune's stripped-down control set than to Melodyne's slider-plus-macro model or Auto-Tune's parameter-dense Graph Mode. That comparison is evidence the preset-first approach is the right novice answer, not merely a reasonable one — it is the same shape the one product actually reviewed as beginner-friendly uses, arrived at independently, and it is already in the tree.

**Where these tools get it wrong for a novice, named concretely from the complaint evidence in §3**:
1. **Octave-error recovery (Note Assignment Mode) has no novice path at all** — it requires understanding that the tool can be WRONG about what note was sung, a meta-concept above "move this note," and Melodyne's own users report it sometimes has no fix regardless of skill. A novice has no way to know this failure mode exists until they hit it.
2. **The gang-edit-vs-small-batch tension (§3)** is exactly the kind of thing an expert learns by trial and error and a novice has no way to discover — Celemony's own documented happy path (select all, macro, done) is the thing experienced users warn against.
3. **Consonant/breath artefacts (Flex Pitch's crackling, pre-v5 Melodyne's lack of sibilant handling)** are the least forgiving failure mode for a novice specifically because they are NOT obviously "wrong pitch" — they sound like a technical glitch, and a novice is likely to blame their recording or their plugin rather than recognize it as a known, named failure class with a known, named fix (the Sibilant Balance Tool). This is the strongest argument in this whole doc for prioritizing sibilant handling above where §7 of the prior doc currently ranks it — not because it's easy (it isn't, confirmed as genuinely hard in that doc), but because its ABSENCE is disproportionately confusing to exactly our target user, more than to a professional who has a mental model for "that's a detector artefact."

---

## 5. Five recommendations for the open §7 questions, with the evidence behind each

Read against `docs/design/2026-09-22-pitch-editor-ui.md` §7.1 forks 2–7 and §7.2b's corrected state.

### 5.1 What a double-click on a note should do

**Recommendation: quantize the note to the nearest allowed scale pitch**, matching `PitchCorrectionScale.nearestAllowedMidi(to:)` — which already exists and already implements exactly this operation (`Sources/DAWCore/PitchCorrection.swift:237-258`, confirmed in the prior doc).

**Evidence**: Melodyne's own documented behaviour, directly: *"If you double-click with the Main Tool on the middle part of a note... you quantize the note(s) in question to the nearest pitch allowed by the current Pitch Grid."* This is not inference from a misread frame — it is Celemony's own stated mechanic, and it maps onto a function we have already shipped and tested (per the prior doc's §4 confirmation that `nearestAllowedMidi` is live and drives `PitchAutoCorrect.editSet`). **This is close to a zero-cost recommendation**: the mechanism exists, only the gesture binding is new work (Increment C).

### 5.2 Whether multi-select exists, and by what gesture

**Recommendation: yes, and use rubber-band-drag-in-empty-space plus ⌘-click-to-add**, matching Melodyne's convention exactly.

**Evidence**: confirmed via Celemony's own Selecting Notes documentation (§2.2). This is the same gesture vocabulary macOS users already have from Finder/every other selection surface in this app (marquee + ⌘-click-add is the platform convention, not a Melodyne-specific choice) — so recommending it is not "copy Melodyne," it is "Melodyne made the same platform-convention choice we would independently make."

**The one open sub-question, and the correction from an earlier draft of this doc**: whether macros/presets applied with an empty selection should act on nothing (safer) or everything (Melodyne's documented choice, §2.2). An earlier version of this section linked that choice to a specific user complaint (§3's gang-editing item); **on review, that complaint is about correction QUALITY on a large batch, not about accidental SCOPE from an empty selection — the two are not the same claim, and I do not have a sourced complaint specifically about the empty-selection behaviour.** The recommendation below therefore rests on our own standing novice-safety rule alone, not on invented evidence: **empty selection = act on the whole clip only when the entry point is explicitly whole-clip** (the existing "Tune Vocal" context-menu presets, §1.1, which are already scoped to "the clip," not "a selection") — and **require an explicit selection for any future per-note batch operation**, diverging from Melodyne's documented default because a control whose behaviour surprises a novice is a defect under our own standing rule, independent of whether Melodyne's users have complained about it specifically.

### 5.3 The merge gesture

**Recommendation: merge is the split tool's own inverse, triggered by clicking an EXISTING split boundary rather than empty note interior** — not a separate tool, not a separate palette slot.

**Evidence**: confirmed directly, Celemony's own Note Separation Tools documentation (§2.3): *"double-click an existing separation and it disappears."* This resolves design doc §7.2's open question ("the scissors implies split; nothing implies merge") with a concrete, source-backed answer, and it is cheap to build: C3 (split, already planned per §7.3 of the design doc) and merge become the same interaction surface with two click targets, not two features. Note the double-click here means something different from §5.1's double-click — the Main/pointer tool's double-click quantizes, the split tool's double-click-on-a-boundary merges — which is consistent with, not a contradiction of, the tool-palette model already read correctly from the TUNE X frames (design doc §7.2).

### 5.4 Which pointer axis should drive vibrato RATE vs. DEPTH

**Recommendation: I do not have primary evidence to pick one over the other, and I recommend NOT trying to infer it from the corrected TUNE X sequence** — the design doc's own §7.2b already states this plainly (*"cursor travel between those frames is small and mostly vertical... still a choice to make, not a fact to read off"*), and this research pass found no external precedent to break the tie: neither Melodyne's Pitch Modulation Tool nor Auto-Tune's Natural Vibrato control exposes a two-axis rate+depth drag anywhere documented in this research (both are single-scalar depth controls, confirmed in the prior doc §3). **This is very likely a genuinely novel control** relative to the whole product class surveyed, not a convention we can borrow.

**What I recommend instead of guessing**: pick the axis that matches the OTHER two-axis convention already in this app rather than inventing a new one — vertical-for-primary/horizontal-for-secondary is the existing convention for the blob's own pitch-drag-plus-scale-snap behaviour (§2.1), and reusing it (vertical = depth, since depth is the "how far from centre" analogue of pitch; horizontal = rate, since rate is inherently a time-axis quantity and the x-axis is already time everywhere else in this editor) is at least internally consistent with the rest of the surface, even though it is not externally validated. **State this as a design choice, not a finding** — flag it for `daw-architect`/`ui-design-engineer` review rather than treating it as settled by this research.

### 5.5 What a dot at a blob's top-centre conventionally is in these products

**No answer found.** I searched specifically for a Melodyne "amplitude handle" or comparable top-centre control and found no source describing a persistent top-centre dot on a note blob in any of Melodyne, Auto-Tune Graph Mode, or Flex Pitch's documented interfaces. The closest analogues found are: Melodyne's amplitude-envelope anchor points (plural, placed by the user, not a fixed single dot) and Flex Pitch's four corner hotspots (drift-in/out, at the corners, not the top-centre). **Given §7.2b's own retraction of a "glowing circle" that turned out to be screen-recorder chrome, and given that no product surveyed here has a documented single fixed top-centre dot, I recommend treating this element with real suspicion** — it may be a TUNE X-specific UI convention with no market precedent (plausible, since TUNE X's other conventions — the persistent bottom tool palette, the floating active-tool indicator — are also not confirmed as matching any product researched here), or it may be another capture artefact not yet identified as one. **I recommend NOT building anything against this element until it can be confirmed from a source other than the frames** — ask the user directly what it is, rather than inferring, given this exact class of mistake already cost two retracted readings in §7.2b.

---

## Sources

**Primary (our code / our design doc, read or re-grepped this session):**
- `docs/design/2026-09-22-pitch-editor-ui.md` §7 (lines 883–1180), read in full, including §7.2b's correction
- `Sources/DAWCore/PitchCorrection.swift` — `nearestAllowedMidi` (:237-258), `timeStartDeltaSeconds`/`timeEndDeltaSeconds` (:317-318), `PitchCorrectionUndoKey` (§8.4 of the design doc)
- `Sources/DAWControl/Commands.swift:809-811,4886,5000,5021` — the three live wire verbs, re-grepped this session
- `Sources/DAWCore/ProjectStore+PitchCorrection.swift` — the store op, `pitchEdits =` assignment confirmed
- `mcp-server/src/server.ts:8671,8788,8805` — the three MCP tools, re-grepped this session
- `Sources/DAWApp/Timeline/TimelineLanesView.swift:4093-4095` — the live "Tune Vocal" context menu, re-grepped this session
- `Sources/DAWApp/PitchEditor/PitchEditorView.swift` — the live Increment A read-only blob/contour view, re-grepped this session
- `Sources/DAWEngine/Stretch/StretchCurvePlan.swift:78,83-84` and `Sources/DAWEngine/Stretch/StretchRenderCache.swift:344-348` — re-confirmed this session: contour still defaults to `[]`, still not passed by the render caller
- `docs/research/2026-09-23-melodyne-class-pitch-editors.md` — the prior doc in this pair, cited throughout for capability/render-status facts already verified there

**External (fetched or search-summarized 2026-09-23; every claim below is search-summary-sourced except where noted — no additional direct WebFetch succeeded this session beyond what the prior doc already recorded):**
- [Celemony: Correct Pitch Macro](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_MacroPitch?env=dawsWithAra)
- [Celemony: Selecting notes](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_SelectingNotes?env=standAlone)
- [Celemony: Note separation tools](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolSeparations_2?env=standAlone)
- [Celemony: Time Handles and Attack Speed](https://helpcenter.celemony.com/M5/doc/melodyneStudio5/en/M5tour_ToolTimeHandlesAttackSpeed_2)
- [Sweetwater: Melodyne Quickstart Guide](https://www.sweetwater.com/sweetcare/articles/melodyne-quickstart-guide/)
- [Sound on Sound: Pitch-correcting vocals with Melodyne](https://www.soundonsound.com/techniques/pitch-correcting-vocals-melodyne)
- [Antares: Understanding Graph Mode in Auto-Tune Pro X](https://www.antarestech.com/blog/understanding-graph-mode-in-auto-tune-pro-x)
- [Antares: Auto-Tune Pro X tutorial overview](https://www.antarestech.com/blog/auto-tune-pro-x-tutorial-overview)
- [Synchro Arts: VocAlign Ultra Quick-Start Guide for Logic Pro X](https://www.synchroarts.com/manuals/VocAlignUltraV1.1/Manual/HTML/vocalign-ultra-quick-start-guide-for-logic-pro-x.html)
- [Synchro Arts: Using SmartAlign](https://www.synchroarts.com/manuals/VocAlign6Pro/Manual/HTML/using-smartalign.html)
- [Whipped Cream Sounds: Waves Tune vs Melodyne](https://www.whippedcreamsounds.com/waves-tune-vs-melodyne/)
- [Celemony/ARA_SDK on GitHub](https://github.com/Celemony/ARA_SDK) and [Celemony: DNA Direct Note Access](https://www.celemony.com/en/service1/about-celemony/technologies) — the programmatic-surface check for §4.1
- Gearspace forum threads on Melodyne octave errors, gang-editing, and Flex Pitch reliability (search-summary sourced, individual thread URLs returned by search but not independently opened — titles: "Melodyne won't recognise vocal notes," "Flex pitch issues/be careful," "Logic Pro X Flex Pitch Issues")
- Apple Support / Apple Community threads on Flex Pitch's C0 misassignment bug and reliability discussion (search-summary sourced)
- [MusicTech: Celemony announces Melodyne 5](https://musictech.com/news/gear/celemony-announces-melodyne-5/) — carried over from the prior doc, re-cited for sibilant/breath handling

**Marked [UNCONFIRMED] or lower-confidence in the body, and why:** Flex-Tune's exact mechanism (§2.4) — a search summary only, not independently checked against Antares's manual text; whether a later Melodyne version shipped a dedicated one-click hard-tune macro (§1.4); the general "artefacts... inconsistent across programs" Auto-Tune complaint (§3) — the vaguest-sourced claim in this doc; whether Melodyne's Cmd-key equivalent to Option/Alt for free-dragging is real or a search-summary conflation (§2.1) — stated as a disagreement, not resolved; whether note-deactivation in Melodyne's Note Assignment Mode produces audible silence or is a bookkeeping state (§1.3); the top-centre dot (§5.5) — actively unresolved and flagged for the user rather than guessed at.
