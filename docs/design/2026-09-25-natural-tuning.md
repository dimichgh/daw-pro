# Natural tuning — keep a tuned vocal sounding like the singer (design, 2026-09-25)

Status: DESIGN, not built. Owner: daw-architect. Roadmap id: m23-nt. Assembled from four section designs (§1 formants, §2 consonants, §3 drift/modulation, §4 transitions); the section bodies below are verbatim from their designers.

## Summary in plain words

You asked for tuning that does not sound tuned. Engineers who use Melodyne do four things to get that, and this design
gives DAW Pro all four:

1. **Voice depth (formants).** Moving a note up today can make the singer sound smaller, like a cartoon. After this,
   the app keeps the "size" of the voice where the singer's throat put it, and a new **Voice** tool lets you drag one
   note deeper or brighter on purpose. How much of that correction sounds right is your taste: you will hear the same
   note at four settings and pick one (§1).
2. **Consonants and breaths stay untouched.** In "Star" only "ar" is a note; "St" is noise. After this, the gaps
   between notes (S, T, breaths) play your original recording, so they never get a robotic pitch (§2). Three limits,
   said plainly: it first has to pass a timing measurement on your recording (if that fails, we fix the timing and
   re-check before building it, R2); an "s" sung ON the end of a vowel is inside the note and still moves with it;
   and the "Sibilance Balance" knob from your paste ships only if measurement shows the app is unsure where an "s"
   ends (R19). You can still drag a breath or an "s" on purpose, as today (R21).
3. **Steady without rigid.** A new **Drift** tool calms the slow wandering in a note but keeps its wobble (vibrato);
   the Wobble tool that is already planned does the opposite. Nothing becomes a flat, robot-straight line unless you
   ask for "Remove wobble and drift" (§3, R26). This one must first pass a measurement: the app has to be able to tell
   drift from wobble. On your recording most notes are too short to tell the two apart; on those notes Drift acts
   like a small pitch move and says so (R18). The Wobble half is the already-queued Wobble tool (C5a).
4. **Smooth joins.** When you move one note and not its neighbour, the pitch now glides between them over a width
   that grows with the jump, instead of snapping. This also applies to vocals tuned with a preset (R14) and across the
   tiny silences the app leaves between notes (R15). You can drag the rear edge of a note up or down to make the
   glide steeper or gentler, as in Melodyne (R12), and a sung slide between two notes tilts to meet the moved note
   instead of snapping back (§4).

**What does not change:** every project you already have plays and saves exactly as before, byte for byte. The new
behaviour is on for vocals you tune from now on. Older vocals get it when you tap one "upgrade" button (see the open
questions at the end). Nothing here touches the live audio thread or needs full Xcode, signing or entitlements.

**How it ships:** in lanes that never edit the same file at the same time (see "Delivery plan"). The tests that prove
each fix are written first, and several of them must FAIL on today's build to show they can catch the problem. You
will get up to four short listening pages, each changing one thing, and your pick sets the default.

**Reading guide for implementers:** §1-§4 are the section designs, verbatim. Where they disagree, **"Cross-section
consistency" at the end OVERRIDES them**, and **"Revision 2 amendments" (R1-R31, just before the open questions)
OVERRIDES everything, including X1-X12 and the Delivery plan**. Read R, then X, then the section. Line citations inside §1-§4 are as their
designers read them on 2026-09-25; `StretchRenderCache.swift` is being edited by another lane, so its line numbers drift.

## The user's ask (verbatim)

# The user's MUST, 2026-09-25 (verbatim framing: "we need this support for our vocal tuning. This is a MUST:")

The user pasted an explainer of how engineers keep a Melodyne-tuned vocal natural. The four capabilities it names:

1. FORMANTS (vocal-tract size). Pitching a note up shifts the formants too -> "chipmunk". Fix: a Formant Tool —
   when a note is shifted up, the formants can be lowered to restore the singer's depth and character.
2. UNPITCHED CONSONANTS / SIBILANCE. S, T, P, Ch (and breaths) are unpitched noise; in "Star" the "St" must not
   change pitch, only "ar". Fix: Melodyne separates them automatically; a Sibilance Balance tool makes sure
   consonants are unaffected by pitch changes. Shifting an "S" up sounds robotic.
3. PITCH DRIFT AND MODULATION. Singers slide and drift; a perfectly flat note sounds like auto-tune. Fix: the
   Pitch Modulation Tool (reduce or restore vibrato) and the Pitch Drift Tool (steady a note without making it rigid);
   keep some natural scoops between notes.
4. TRANSITIONS. Moving one note but not its neighbours can break the boundary into an abrupt robotic jump. Fix: the
   Pitch Tool drags the SEPARATION LINE between notes to blend the pitch curve smoothly from the altered note into
   the unaltered one.

Rule of thumb in the paste: 1-2 semitones usually sounds natural; 3+ semitones needs the formant tool and fixed
transitions or it sounds edited.

The user is not a musician: their words DESCRIBE, they do not diagnose. Measurable defaults are delegated to us;
taste (how much formant correction sounds right) is theirs, via 3-4 listening options differing on ONE axis.


---

# §1 Formants: a moved note must not chipmunk

Route: audio-dsp-engineer (shim, curve loop, gates) · swift-app-engineer / ui-design-engineer (UI) · mcp-integration-engineer (wire, MCP) · qa-test-engineer (key/digest gates). No Xcode, entitlement, AUv3 or signing dependency: everything here is shim, Swift and SwiftUI (READ, shim.cpp is plain C++ in the SwiftPM target).

## 1(a) Current state

- **A +4 st note drag chipmunks by default.** The drag writes `pitchOffsetCents` only. `Clip.formantPreserve` defaults to false (Model.swift:846) and decodes false when absent (:1107). The curve loop calls `css_set_formant_preserve(handle, formantPreserve)` ONCE, after the pre-roll transpose (OfflineStretcher.swift:522, MEASURED by reading today). The shim turns that into `setFormantFactor(1, preserve)` and `setFormantBase(0)` (shim.cpp:47-52, READ). With preserve false, `processFormants = formantMultiplier != 1 || (formantCompensation && mappedFrequencies)` is false (signalsmith-stretch.h:310, READ), so the envelope rides the partials up by 2^(4/12) = 1.26 (INFERRED; never measured on voice).
- **The only fix is agent-only, clip-wide, on/off:** `clip.setStretch formantPreserve:true` (Commands.swift:4576-4597; server.ts:8038-8048, READ via map). No app control writes it (MEASURED by the map lane: `setClipStretch` callers exist only in DAWCore and DAWControl). `clip_set_note_pitch` never mentions it (server.ts:9076, READ via map).
- **The per-note field is a placeholder with a live stale-key hazard.** `NoteSegment.formantOffsetSemitones` (PitchCorrection.swift:419, READ) has no writer and no renderer reader (MEASURED by the map lane with a positive control). It IS hashed inline in the digest (StretchCurvePlan.swift:361, READ) and it DOES break `isPitchIdentity` (PitchCorrection.swift:566-569, READ), so a hand-authored non-zero value today forces a stretcher pass that recolours the take without moving any formant. No formant suffix block exists: the fixed order is slots 1-6 (StretchCurvePlan.swift:370-452, READ).
- **The engine can do far more than the shim exposes.** `setFormantFactor(multiplier, compensatePitch)` writes BOTH members in one call (signalsmith-stretch.h:124-128, READ). `setFormantSemitones` (:129-131). `setFormantBase(baseFreq)` in cycles/sample, 0 = `estimateFrequency()` (:132-135, :982-983, READ), which the source calls "VERY rough" (:950) and smooths with an IIR across blocks (`freqEstimateWeighted += … * 0.25`, :962-963, READ). All three members are re-read each block (:310, :979-983, :1020-1021, READ). With `formantCompensation` true, the target envelope position is `invMapFormant(mapFreq(inputF))`, i.e. "shift measured from the SOURCE envelope"; with it false the envelope rides the pitch map and the multiplier stacks on top (:1019-1021, READ).
- **Measurement gap.** No test asserts the envelope stays put: the formant-ON tests use a sine (OfflineStretcherTests.swift:121-128; OfflineStretcherCurveTests.swift:207-254, READ via map). No LPC/cepstrum instrument exists in the tree (MEASURED by the map lane with a positive control). The only real-voice formant pair is ±32 c, too small to read.
- **Design debt.** m23-q §6.2E/§6.4 decided the SOURCE's measured f0 should feed `setFormantBase` (docs/research/m23-q-pitch-correction-design.md:512, :530); Phase-1 sub-item (3) (:796) never shipped (shim.cpp:51 still passes 0, READ). `clip.setNoteFormant` was planned for Phase 4 (:659). No design doc has decided the default, the per-note tool, or legacy handling.
- **In-flight collision.** RenderDiff (p2-ren lane, uncommitted) compares only the transpose per chunk plus the level mask (RenderDiff.swift:176-197, READ today); `isEmpty` is `pitchRanges.isEmpty && maskRanges.isEmpty` (:87, READ). A formant-only edit would plan an EMPTY extent and the provisional splice would serve stale audio.

## 1(b) Decision and mechanism

**DECISION F-1. Formant correction lives on the pitch-edit SET, not on the Clip. `Clip.formantPreserve` and its default are left exactly as they are.** A new set-level field `PitchEditSet.formantCorrection: Double?` (0...1, nil = legacy) says how much of a moved note's formant shift is removed. `NoteSegment.formantOffsetSemitones` (already stored) becomes the per-note Formant Tool value. Both are rendered by ONE per-hop formant curve fed to signalsmith through two new shim setters, in a branch that is never taken for a legacy set.

Why the set and not the clip (READ):
- `ClipRenderSignature.Tuning.everythingButTheNotes` is a whole `PitchEditSet` compared with `==` (ClipRenderSignature.swift:112-130); `PitchEditSet` is `Codable, Sendable, Equatable` with no custom `==` found (PitchCorrection.swift:766). A set-level field therefore reaches the render light for free.
- The set's digest already rides the render key and the schedule identity: `pitch:` in `renderKeys`, and `ClipKey.pitchEditSetHash = PitchEditSetDigest.hex(...)` (PlaybackGraph.swift:73, :1155, READ). A clip-level field would instead have to reach ClipKey, Params, renderKeys, RenderInputs, the ProjectDocument mirror and every `Clip(...)` rebuild site: the hand-maintained-site hazard (pitch-editor-ui P2).
- `hex` returns `""` for an identity set (StretchCurvePlan.swift:335-336, READ). So a correction amount on a set with no moved notes renders nothing new, which is correct by construction.

**Alternatives that lose.**
- *(A1) Flip `Clip.formantPreserve` to true for tuned clips.* On/off only, so there is no listening axis and no partial follow. It keeps the "VERY rough" auto f0 (signalsmith-stretch.h:950). It changes the tone of shipped projects under an unchanged key (the flag is already in every key). It also cannot express a per-note offset.
- *(A2) Formant curve rides a per-note field only (a per-note `formantCorrection`).* 450 decisions where there is one musical decision. It adds a `NoteSegment` Double, which triggers the `isCleared` padding trap (ClipRenderSignatureTests.swift:337) and the reflection census, and the UI has no sensible default per note. Per-note control stays available through the offset.

**The per-hop formant value (one home, DAWCore).** Add to `PitchCorrectionCurve` (PitchCorrection.swift:1136ff) a second evaluator, `formantSemitones(atSourceSecond:editedSecond:) -> Double`. It reuses the existing `gate(span, at:)` / `firstSpanIndex` / normalisation, and adds one precomputed Double per `Span`:

    spanFormant_i = (1 − c) · constantSemitones_i + formantOffsetSemitones_i
    F(t)          = clipPart + Σ gate_i(t)·spanFormant_i / norm(t)
    clipPart      = clip.formantPreserve ? 0 : clip.pitchShiftSemitones
    c             = set.formantCorrection ?? (clip.formantPreserve ? 1 : 0)

F is "formant semitones relative to the SOURCE envelope" (compensate = true). F = 0 keeps the singer's envelope. F = the note's move follows pitch (chipmunk). F = −2 is "deeper than sung".
- ⚠️ **nil is the ONLY legacy path; `c = 0.0` is NOT legacy.** At 0.0 the branch is taken: `processFormants` runs with multiplier 2^(T/12) and compensate on, which is multiplicative at every frequency and uses the measured base. Legacy-OFF rides the pitch map, which is additive above the tonality limit (signalsmith-stretch.h:850-856, :920-925). So G3's "c=0 ≈ G1" is a physics match, not a byte match, and listening option A is labelled accordingly.
- ⚠️ **Do NOT refactor `semitones(atSourceSecond:)`.** Its `-0.0` banner (PitchCorrection.swift:~1413ff, READ) exists because a shared blend helper is the plausible refactor that flips bit patterns. Duplicate the ~20-line gate loop in the formant evaluator. That is a second LOOP, not a second copy of the curve's MATH: the gates, spans and normaliser are shared.
- **The edit term is the note's CONSTANT move only.** The shaping (drift/vibrato removal) and generator terms are deliberately excluded, so formants never wobble with synthetic or kept vibrato. A real singer's formants stay near-fixed through vibrato (INFERRED, textbook source-filter physics). This is named, not accidental.
- Boundaries use the SAME C¹ gates as pitch. So a per-note offset ramps over the same `retuneMs` window as the move, and two abutting notes crossfade their offsets.

**The per-hop formant BASE (f0 hint), same home.** `formantBaseHz(atSourceSecond:)` is a step function over the set's notes. It returns the `detectedHz` of the note covering t. Between notes it holds the last note's value; before the first note it uses the first note's. Notes whose `detectedHz` is non-finite or ≤ 0 are skipped. The result is floored at 50 Hz. This is the SOURCE f0, as m23-q §6.4 ruled (docs/research/m23-q-pitch-correction-design.md:530). It is a pure function of stored data, so a window render reproduces it exactly.
- ⛔ **The base is NEVER 0 inside the new branch.** With 0, `estimateFrequency`'s IIR (`freqEstimateWeighted += … * 0.25`, signalsmith-stretch.h:962-963, READ) is cross-block state that `StretchWindow` cannot reproduce, and span renders stop matching whole-file renders (ClipSpanRenderTests.swift:203). With an explicit base, `freqEstimate = freqToBand(formantBaseFreq)` (:982) and the IIR is never entered (READ).
- ⚠️ The unvoiced-hop policy (hold) is shared with §2 consonants. If §2 adds an unvoiced mask, it must not zero the base; it may only change F.

**Shim (Sources/CSignalsmithStretch).** Add two functions to the header `include/csignalsmith_stretch.h` and to `shim.cpp`:

    void css_set_formant_semitones(css_stretch *s, float semitones, bool compensatePitch);
        // → stretch.setFormantSemitones(semitones, compensatePitch)  (writes BOTH members, :124-131)
    void css_set_formant_base_hz(css_stretch *s, float hz);
        // → stretch.setFormantBase(hz > 0 ? hz / s->sampleRate : 0)  (cycles/sample, stft.h:78-80; mirrors :43)

`css_set_formant_preserve` is NOT touched. It keeps the constant loop and the legacy curve path bit-exact. Both new calls are plain member writes: they do not allocate, lock or block (READ :124-135). The offline render is not the RT thread anyway.

**Curve loop (Sources/DAWEngine/Stretch/OfflineStretcher.swift `curveLoop`, :480-560).** Add optional closures `formantAtOutputFrame: ((Int) -> Double)?` and `formantBaseHzAtOutputFrame: ((Int) -> Double)?`. Both are nil for a legacy set.
- **nil** → today's code, unchanged: the `css_set_formant_preserve(handle, formantPreserve)` call at :522 and nothing per hop.
- **non-nil** → do NOT call `css_set_formant_preserve`. Before `css_output_seek`, set both values from the FIRST chunk's lookup frame, mirroring the pre-roll transpose rule (:497-521: continuity beats frame-0 correctness). Then re-set both inside the chunk loop beside the transpose (:538-543), at the SAME `curveLookupFrame(outputFrame:compensation:intervalSamples:)`. The whole-file and window entries share this loop (map: :433-446), so windows get it too.
- Whether a formant change lands at the same 2379-frame latency as a transpose is INFERRED (both are consumed inside the same block process, :296-312). It is gated in 1(g) G4 before anyone relies on it.

**Plan (Sources/DAWEngine/Stretch/StretchCurvePlan.swift).** `StretchCurvePlan.make` builds the two closures only when `set.engagesFormantCurve` is true. That is one predicate in DAWCore:

    extension PitchEditSet { var engagesFormantCurve: Bool {
        formantCorrection != nil || segments.contains { $0.formantOffsetSemitones != 0 } } }

The legacy-with-offset case (a hand-authored file) engages with c = the flag's value. The offset is thus finally read, and the file is re-keyed by slot 7 (1(d)).

**Store (Sources/DAWCore/ProjectStore+PitchNoteEdits.swift).**
- `setClipNoteFormant(clipId:segmentIds:semitones:seedIfAbsent:)` mirrors `setClipNoteGain` (:275-300). It clamps to the existing ±24 (PitchCorrection.swift:673-675) and uses undo title "Set Note Voice".
- `setClipFormantCorrection(clipId:amount:)` takes `Double?`: nil restores legacy, otherwise the value is clamped to 0...1. Undo title "Keep Voice Natural".
- ⚠️ **REBUILD SITES DROP SET-LEVEL FIELDS.** `PitchEditSet(analysisVersion:segments:retuneMs:)` is re-called at ProjectStore+PitchNoteEdits.swift:161 (split) and :534, PitchEditorModel.swift:1902 (draft line), and PitchCorrection.swift:1905/:1917 (`editSet`). These sites come from a census `grep -rn "PitchEditSet(" Sources/`: 6 hits, the pattern matched `static let empty` at :874 as its own control. Filter comment lines before trusting the count. A split today would silently revert the amount to nil, which is a tone change. **Add `formantCorrection` to `init` with NO default value**, so the compiler finds every site; test-site churn is the accepted cost. Decode it with `decodeIfPresent` (absent → nil). Encode it whenever it is non-nil, **INCLUDING 0.0**, because 0.0 is the new engine path, not legacy. The omit-at-default habit (:933-940) would silently flip a saved 0.0 back to legacy on reopen.

## 1(c) Defaults, and why existing projects stay byte-identical

| Case | `formantCorrection` | What renders | Bytes vs today |
|---|---|---|---|
| Set saved before this ships (key absent) | decodes **nil** | the flag's behaviour: today's code, the closures are nil | **identical**: render, digest (no slot 7) and re-saved JSON (nil is not encoded) |
| Legacy set + hand-authored non-zero offset | nil | engages with c = the flag; the offset is finally read | **changes, deliberately**: the audio was stale-by-construction, and slot 7 re-keys it (F7 closed). **No ruling owed**: no shipped writer of the field exists (MEASURED by the map lane with a positive control), so no shipped project carries it |
| NEW set (first tune of an untuned clip, the editor seeding a table, an auto-correct run) | **`PitchEditSet.newSetFormantCorrection`**, provisionally **1.0**, final value = the 1(h) pick | the formant curve, measured base | n/a (new material, new key) |
| `Clip.formantPreserve` (whole-clip transpose, constant loop) | untouched, default **false** | unchanged | **identical** |

- This follows the `.clipper` precedent: new = new default, absent = legacy (MEMORY: user pick 09-24). "A shipped kind may not change tone" holds. An open-and-play of any existing project produces the same bytes, because nothing re-derives a nil.
- **Why 1.0 provisionally.** Full correction is the physical answer to "don't chipmunk": the envelope stays where the singer's throat put it. It is also what the user's paste prescribes. Partial follow (0.5-0.75) is a known engineering taste choice, and only the listening round can settle it. `newSetFormantCorrection` is ONE constant in DAWCore, so the pick is a one-line change.
- **Where new sets get it.** `PitchAutoCorrect.editSet(contour:…)` (PitchCorrection.swift:1893-1920) passes the constant. It is the constructor for both auto-correct and the editor's detected table. Every rebuild site passes `table.formantCorrection` through (the compiler forces this, per 1(b)).
- **One consequence, stated rather than hidden (optional ruling D-F2).** Re-running auto-correct on a LEGACY clip builds a new set, so the clip gets the new default. That is a tone change, but only on an explicit user action that already rewrites every note. The recommended default is to accept it; the alternative is to carry over nil. If the existing set's value is non-nil, auto-correct carries it over, so a user's own pick is never reset by a preset.
- **Legacy upgrade is one tap, never automatic.** The editor shows a legacy set (nil) with a note that says so (1(f)). Tapping it sets `newSetFormantCorrection` through the normal store writer (undoable).
- **Out of scope, named.** The whole-clip transpose still chipmunks unless `formantPreserve` is on. The user's ask is about moved NOTES. Flipping the clip flag default would change shipped tone and needs its own ruling. The UI does expose the flag (1(f)).

## 1(d) Render-cache key impact

- **Digest: new suffix slot 7, "formant", after slot 6 (origin).** Gate: `set.engagesFormantCurve`. Content: `putBits(formantSuffixMarker)`, `putInt(PitchEditSet.formantRenderVersion)` (starts at 1), one byte `formantCorrection != nil`, then `putDouble(formantCorrection ?? 0)`. The offsets are ALREADY hashed inline (StretchCurvePlan.swift:361) and stay there; moving them would re-key every set. File the slot in the banner at StretchCurvePlan.swift:370-390. **Sibling sections §2-§4 take slots 8 and up**; the integrator fixes the final order in the design doc before any code (placing a block out of its slot re-keys every set that uses two features, :384-389).
- **`formantRenderVersion`** re-keys only the ENGAGED sets whenever the base policy, the F arithmetic or the shim semantics change. **`stretchEngineVersion` is NOT bumped** (StretchRenderCache.swift:196-198): that would re-render every stretched clip on the machine.
- **No new `Params` field, no `renderKeys` change, no `ClipKey` field, no `ClipRenderSignature` field.** The set-level value travels in the digest (PlaybackGraph.swift:73, :1155) and in `Tuning` (ClipRenderSignature.swift:112-130). The clip flag already sits in every key (StretchRenderCache.swift:398), and it enters F through `clipPart` and the nil fallback of `c`. It stays OUT of the render time base (StretchEngineTests.swift:961): formant changes no timing.
- **Legacy preserve=true renders do not change behaviour**, so there is no silent-stale problem and no re-key is needed. That is the point of keeping the measured base INSIDE the new branch. Hazard 2 of the map is dissolved rather than paid.
- **RenderDiff (p2-ren lane; a PATCH SPEC for that lane, not an edit from this one).**
  1. Add `formantEngaged` per side: the plan exists AND `engagesFormantCurve`.
  2. If engagement differs between old and new, refuse with a new `Refusal.formantCurveEngagement` ("one render shapes the voice note by note and the other does not"). A legacy-OFF → amount=1 flip has an IDENTICAL transpose per chunk, but every hop where T ≠ 0 now runs `processFormants`, so a transpose-only compare would call it empty (RenderDiff.swift:87).
  3. If both are engaged, the per-chunk `differs` compares the tuple `(Float(T), Float(F), Float(baseHz))`, not T alone, and feeds the same `pitchRanges`.
  4. Extend the `.formantAcrossLoops` guard (:161-163) to treat an engaged side like `formantPreserve`.
  The formant render lane is sequenced BEHIND p2-ren's commit. The alternative is that p2-ren takes this patch into its own lane.

## 1(e) Wire command + MCP tool (additive only)

- **`clip.setNoteFormant`** `{clipId, segmentIds:[uuid], formantSemitones:number}` → `ProjectStore.setClipNoteFormant`. Register it in the per-note door cluster after `clip.setNotePitches` (Commands.swift:460-505), keeping the cluster rule its neighbours document. The reply echoes the stored (clamped) value and the clip's `formantCorrection`. It refuses with the store's text when no note table exists and none can be seeded (the `setClipNoteGain` shape).
- **`clip.setFormantCorrection`** `{clipId, amount:number|null}`. null = "as before this feature" (legacy). The reply echoes the value in force and a `plainLanguage` field ("Voice kept natural: 100 %").
- **Read side (additive fields):** `clip.getPitchEdits` and `clip.autoCorrectPitch` add `formantCorrection` (number or null). `formantOffsetSemitones` (Commands.swift:14310) stops being "always 0". `clip.autoCorrectPitch` gains an optional `formantCorrection` argument.
  ✅ **DAWCore half landed 2026-09-27 (W7-D2):** `PitchAutoCorrectOptions.formantCorrection` (nil = today's rule; a
  number is clamped to 0...1 and beats BOTH the new-set seed and the clip's carried amount; NaN/infinity are refused in
  words before detection). The wire leg is W7-WIRE2's. **Ruled by the orchestrator: an explicit JSON `null` is REFUSED
  on `clip.autoCorrectPitch`.** `null` already means LEGACY for this field name (`clip.setFormantCorrection`, and
  `clip.getPitchEdits` reads it back that way), so an agent writing back what it read would otherwise get a silent
  re-seed at 1.0, a tone change reported as a success.
- **MCP (mcp-server/src/server.ts):** new tools `clip_set_note_formant` and `clip_set_formant_correction`. Rewrite the "unread by any renderer today, always 0" text (:8940-8941). Add one teaching sentence to `clip_set_note_pitch` (:9076): "Moving a note 3+ semitones? Formants are kept natural by `formantCorrection` (default 100 %); use `clip_set_note_formant` to make one note deeper or brighter." Add one to `clip_set_stretch` saying the flag governs the WHOLE-clip transpose only.
- Count pins: the wire +2, the MCP +2 (`node scripts/gates/doc-count-drift.mjs`). Update the plugin bundle's hand-maintained allowlist per the M39 release law (MEMORY §2026-09-20s).

## 1(f) UI (docs/DESIGN-LANGUAGE.md: dark glass, glow earned by state, beginner words)

The palette grows a slot only when a tool lands (PitchEditorModel.swift:1107-1112, READ). This section lands two controls and a hint.

1. **Set-level control: "Keep voice natural"**, in the pitch editor's header row beside the preset chips. It is a compact unipolar slider, 0-100 %, with an SF Mono readout ("Keep voice natural 100 %"). Detents sit at the four listening-round stops. Tooltip and drawn caption: *"When you move a note up, a voice can start to sound small and squeaky. This keeps the singer sounding like themselves."* Cyan arc only while dragging (glow earned by state). It writes through `store.setClipFormantCorrection`, one undo per gesture.
   - **Legacy set (nil):** the slider draws DIM (the "setting that cannot reach the sound stays live, goes dim, and says so" law, DESIGN-LANGUAGE.md:30), with an amber one-liner, ≤ 51 chars per that law's measurement: *"Tuned before voice-keeping. Tap to turn it on."* Tapping it writes `newSetFormantCorrection`. The slider stays live: dragging it also upgrades.
   - Simple mode shows only this slider. Pro mode adds a "Whole-clip transpose keeps voice" toggle chip, which writes `Clip.formantPreserve` through the existing `clip.setStretch` store path. That closes "the user CANNOT turn formant preservation on from the app".
2. **Per-note Formant Tool: palette slot "Voice"** (`PitchEditorTool.voice`, SF Symbol `mouth`; verify it exists on macOS 14 before use, otherwise use `person.wave.2`). Caption: *"Drag a note up or down to make that part of the voice brighter or deeper, without changing the note."*
   - Router: `(.voice, .note(id)) → .formantDrag(id)` (a new `PitchEditorPressKind`); empty space → `.band` as today.
   - A vertical drag sets `formantOffsetSemitones` (0.1 st resolution, ⌥ = fine, double-click = reset to 0, per the knob law). The UI range is ±6 st; the wire keeps ±24.
   - Drawing: while the Voice tool is active, each note with a non-zero offset shows a thin horizontal **amber** bar inside the blob, offset from centre by the value, plus an SF Mono chip "Deeper 2.0" / "Brighter 1.5". It is amber, not cyan and not violet: this is a user shaping, not playback and not AI. The blob's pitch position never moves in this tool.
   - Audition: reuse the existing note-audition path (PitchEditorAudition.swift), which renders through the product path.
3. **Note menu** (PitchEditorNoteMenu.swift): add a "Voice: Deeper / Brighter / As sung" row for keyboard-less and multi-note use. It is batched through `clip.setNoteFormant` with the selection's ids.
4. **Far-move hint (the paste's "3+ semitones" rule).** When a drag ends with |move| ≥ 300 c AND the set's effective correction is < 0.5, show a one-line prose hint: *"Big jump: turn up Keep voice natural so it doesn't sound squeaky."* This is presentation only. The `farMoves` report (unpitched design §3.3, :546) is still owed to the wire and belongs to §4/§2. This section does not claim it.

All labels resolve at ONE home (a `PitchEditorFormantCopy` in DAWAppKit) and are asserted BY VALUE, following the state-line law (DESIGN-LANGUAGE.md:40). Pixel-look gate: a capture of the header in the legacy and new states, plus the Voice tool with ±offsets, LOOKED AT by a person or an observer pass. "A UI phase isn't done until someone looked at it."

## 1(g) Physics gates (each with a positive and a negative control)

**Instruments first (shared with the measurement map, which owns them).** `Tests/DAWEngineTests/Support/SourceFilterVoice.swift` provides a pulse train through F1-F4 resonators with a settable formant scale. `Tests/DAWEngineTests/SpectralEnvelopeMeter.swift` gives an LPC F1-F3 reading and a cepstral `envelopeShiftCents`, both over 250-5000 Hz only. Above ~7.1 kHz the formant map is additive (signalsmith-stretch.h:920-925), so it is excluded from the metric and named. Instrument controls, before any gate is trusted:
- The meter reads a planted formant scale of c cents as c, at f0 = 80, 110 and 220 Hz. The take sits at 72-145 Hz, and a lifter can lock onto 72 Hz harmonics.
- The meter reads ≈ 0 when only f0 moves by ±7 st.
- `SpectralShiftMeter` on the same pair reads the PITCH move. The two instruments disagree in exactly the way they should.

Tolerances are pre-registered from a control pair, as max(floor, 2 × control): the `SpanRenderMetrics` convention (ClipSpanRenderTests.swift:1612-1797). New file: `Tests/DAWEngineTests/NaturalTuningFormantPhysicsTests.swift` (no suite-level `@MainActor`). Every render goes through the SHIPPING path: `StretchCurvePlan` + the curve loop with its compensation, the `renderThroughShippingPath` shape.

| Gate | Asserts | Positive control | Negative control |
|---|---|---|---|
| **G1 Chipmunk is real** (legacy nil, flag off, +4 st) | envelope shift ≈ +400 c | meter's planted-scale reading | pitch meter reads +400 on the same file, so G1 is not reading pitch |
| **G2 Kept natural** (c = 1; ±3/5/7 st; f0 80/110/220) | envelope shift within tolerance of 0 AND delivered pitch ≈ the move | G1's render reads ≈ +400 through the same meter | PLANT: the branch disabled (closures nil) must FAIL G2 |
| **G2b Small moves stay transparent** (Natural-preset shaping, every move ≤ 50 c; c = nil vs c = 1) | log-spectral distance (`SpanRenderMetrics` shape) within a pre-registered bound. With c = 1, `processFormants` runs at EVERY hop where T ≠ 0 (:310), i.e. through nearly every corrected note, and not only on 3+ st moves | the +4 st c = nil vs c = 1 pair EXCEEDS the bound | PLANT: an audible envelope tilt injected into the c = 1 side must fail |
| **G3 The amount is the axis** (c = 0/0.5/0.75/1, +4 st) | shift ≈ (1−c)·400 c, strictly ordered | c=0 matches G1 within tolerance | PLANT: `c` ignored (forced to 1) must fail the ordering. Distinct bytes alone prove nothing |
| **G4 Formant latency** (constant pitch, offset steps at a known boundary) | the envelope step lands at the transpose's MEASURED 2379 frames ± half a hop (OfflineStretcher.swift:184-218, :302-310) | the transpose step on the same fixture, via the existing landing instrument (OfflineStretcherCurveTests.swift:824-912) | PLANT: formant looked up one hop late must fail |
| **G5 Per-note offset** (−2 st on one note, no pitch move) | that note's envelope −200 c ±tol; pitch ≈ 0; neighbours' envelope ≈ the unedited render's | G2's neighbour reading | **RED ON HEAD** (the field is unread). PLANT: offset applied to the wrong note must fail |
| **G6 Byte identity at defaults** | nil-set curve renders (flag on AND off) byte-identical to a golden captured BEFORE the change; the constant loop likewise; §A vibrato goldens; whole-file golden (ClipSpanRenderTests.swift:1447-1605) | the golden differs when the flag flips (it can fail) | PLANT: an unconditional `css_set_formant_semitones(…, 0, true)` per hop must fail (the §A lesson) |
| **G7 Window == whole file, engaged** | a window starting in an unvoiced gap and one mid-note are byte-equal to the whole-file frames | an existing window-exactness case passes on the new build | PLANT: base = 0 inside the branch (the IIR) must fail. If it does not, report the gate as INCAPABLE rather than passing |
| **G8 Keys and schema** (DAWCore + DAWEngine) | slot 7 emitted iff `engagesFormantCurve` AND the set is non-identity (`hex` returns `""` first, StretchCurvePlan.swift:335-336); nil-set digest equal to the c21 goldens; hand-authored offset re-keys; a `formantRenderVersion` bump re-keys engaged sets only; `0.0` round-trips as 0.0 | the level-block test shape (PitchCurveRenderTests.swift:1067) | PLANT: omit-at-zero encode must fail the round-trip; a new set-level field absent from the digest must fail the census below |
| **G9 Writers keep the field** | split, setNotePitch(es), setNoteGain, setNoteCleared and auto-correct (carry-over) each preserve `formantCorrection` | a writer that sets it reads back | PLANT: a rebuild without it must fail |
| **G10 RenderDiff** (after the p2-ren patch) | legacy→engaged flip refuses `.formantCurveEngagement`; a formant-only edit on one note yields a non-empty extent covering the note ± ramp + latency | a pitch-only edit still yields its known extent | today's transpose-only compare computes EMPTY on the same pair (documented RED) |

- **New census:** a reflection test of `PitchEditSet`'s SET-level stored properties against the digest, with the explicit allowlist {`autoCorrectStamp`} (PitchCorrection.swift:816, "deliberately absent"). None exists today; only `NoteSegment` has one (PitchCurveRenderTests.swift:412-443).
- **Real take (G11, env-gated, `@MainActor` per test).** `NaturalTuningTakeHarnessTests` renders `dry-norm.wav` with one note moved +4 st at c = 0/0.5/0.75/1 into `~/Music/DAW Pro Dogfood/2026-09-25 natural-tuning/`. `PREREG.txt` is written first. `nt-checks.py` measures librosa LPC F1/F2 over the moved note's voiced frames: F2 shift ordered by c, and |shift| at c = 1 ≤ the pre-registered bound. Plant: shuffled labels must fail. The audio never enters the repo. It uses `busyline-frames.csv`, so no model load is needed.
- **Cost (owed, blocked by the timing lock):** time `M23QComparisonPair.render` on the 33 s take with c = nil vs c = 1. The ~10-20 % overhead is INFERRED. Record the number in the close record before claiming it.
- **These gates prove the mechanism, not "natural".** m23-ap-5 (the E2 human listen, ROADMAP.md:2394) stays open.

## 1(h) Taste question for the user: ONE axis, "how much of the voice is kept"

- **Material.** The user's take (`dry-norm.wav`), one sustained note moved **up 4 semitones**. It is the paste's "3+ needs the formant tool" case, and a large enough move to hear. Everything else is fixed: same preset, same `retuneMs`, same neighbours, per-note offset 0, product path, −21.5 LUFS, true peak ≤ −1 dBTP measured on the DECODED MP3s, ≥ 3 s of context either side. The P-L pipeline applies (PREREG, `nt-checks.py` with plants, `nt-page.py`, `manifest.json`).
- **Question, novice words:** *"The same note, raised. Which one still sounds like the same singer?"*

| Option | `formantCorrection` | Label on the page |
|---|---|---|
| A | 0.0 | "Follows the note: brighter, smaller voice" |
| B | 0.5 | "Halfway" |
| C | 0.75 | "Mostly kept" |
| **D (recommended default)** | **1.0** | "Voice fully kept" |

- The recommendation is D, because it is the physical fix and the paste's prescription. C exists because engineers often let formants follow a little on upward moves, so a fully-held envelope does not sound "pasted on". That is INFERRED practice; the user's ear decides.
- Pre-registered check: the envelope shift, measured on the rendered files, is ordered A > B > C > D ≈ 0. If it is not, the page does not ship.
- Audibility: if the LPC F2 difference A vs D is below the pre-registered audibility bound on this note, pick a different note or a +5 st move, and SAY so on the page (the audibility/novice rule).
- ⚠️ **What the user has already heard is mixed, and must not be cited as evidence for either default (MEASURED by grep just now).** The M23Q preset and detune harnesses rendered with `formantPreserve: true` (M23QPresetListeningTests.swift:92; M23QDetuneRepairTests.swift:162, :166, :184). The later P-L and note-split harnesses rendered with `false` (NaturalWobbleListeningTests.swift:314, :345; NoteSplitListeningTests.swift:206, :602, :628, :971). Those rounds varied other axes, so none of them answers this question.
- **Optional ruling D-F2** (1(c)): should re-running auto-correct on an old clip adopt the new default? The recommendation is yes. Put it on the handoff page as a yes/no, not as a listening item.

## 1(i) Files this section touches (for disjoint lanes)

**Lane F-core (DAWCore, audio-dsp-engineer)**
- `Sources/DAWCore/PitchCorrection.swift`: `formantCorrection` (field, init without default, Codable, clamp); `newSetFormantCorrection`, `formantRenderVersion`, `engagesFormantCurve`; `PitchCorrectionCurve.formantSemitones(…)`, `formantBaseHz(…)`, Span field; `editSet` passes the default.
- `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`: `setClipNoteFormant`, `setClipFormantCorrection`; thread the field at :161, :534.
- `Sources/DAWCore/ProjectStore.swift`: auto-correct carry-over only (locate `autoCorrectClipPitch` by grep, not by a line number).

**Lane F-engine (DAWEngine + shim, audio-dsp-engineer; sequenced AFTER p2-ren commits)**
- `Sources/CSignalsmithStretch/shim.cpp`, `Sources/CSignalsmithStretch/include/csignalsmith_stretch.h`: two setters.
- `Sources/DAWEngine/Stretch/OfflineStretcher.swift`: curve-loop closures, pre-roll + per-hop.
- `Sources/DAWEngine/Stretch/StretchCurvePlan.swift`: slot 7 block + banner; closures in `make`.
- `Sources/DAWEngine/Stretch/RenderDiff.swift`: the p2-ren lane applies the 1(d) patch spec, or it is co-owned.
- NOT touched: `StretchRenderCache.swift` Params/renderKeys, `PlaybackGraph.swift` ClipKey, `ClipRenderSignature.swift`. Their only change is to call sites that pass the plan through, if any.

**Lane F-wire (mcp-integration-engineer)**
- `Sources/DAWControl/Commands.swift`: 2 verbs and the read-side fields.
- `mcp-server/src/server.ts`: 2 tools and the teaching text; the plugin bundle allowlist.

**Lane F-ui (swift-app-engineer / ui-design-engineer)**
- `Sources/DAWAppKit/PitchEditorModel.swift` (`PitchEditorTool.voice`; :1902 threading).
- `Sources/DAWAppKit/PitchEditorGestureRouter.swift` (`.formantDrag`).
- `Sources/DAWAppKit/PitchEditorNoteMenu.swift`.
- New `Sources/DAWAppKit/PitchEditorFormantCopy.swift`.
- `Sources/DAWApp/PitchEditor/PitchEditorView.swift` (header slider, bars, chips, hint).

**Lane F-gates (qa-test-engineer + audio-dsp-engineer; lands FIRST)**
- New files: `Tests/DAWEngineTests/Support/SourceFilterVoice.swift`, `Tests/DAWEngineTests/SpectralEnvelopeMeter.swift`, `Tests/DAWEngineTests/NaturalTuningFormantPhysicsTests.swift`, `Tests/DAWEngineTests/NaturalTuningTakeHarnessTests.swift`, `Tests/DAWCoreTests/FormantCorrectionModelTests.swift` (Codable, writers, census), `Tests/DAWControlTests/FormantCommandTests.swift`.
- Additions to `Tests/DAWEngineTests/PitchCurveRenderTests.swift` (slot 7), done as a NEW file if another lane holds it.

**Docs**
- `docs/design/2026-09-25-natural-tuning.md` (this section).
- `docs/ROADMAP.md`: new ids for the formant base and `setNoteFormant`, which have none today (map, MEASURED).
- `docs/ARCHITECTURE.md` "Key future decisions" gets this entry (the integrator writes it; this lane's write scope is one file):
  > **Formant correction for tuned notes (settled 2026-09-25, m23-nt §1).** A set-level `PitchEditSet.formantCorrection` (0...1, nil = legacy) and the per-note `formantOffsetSemitones` drive ONE per-hop formant curve, relative to the source envelope, with the source's per-note f0 as the base (never 0). The curve renders through two additive shim setters, only in a branch a legacy set never takes, and is keyed by digest slot 7 with its own `formantRenderVersion`. `Clip.formantPreserve` is unchanged and governs the whole-clip transpose only. New sets default to the listening-round pick; absent decodes as legacy.

## 1(j) Risks

1. **p2-ren collision (highest).** Until RenderDiff compares (T, F, base) and refuses engagement flips, a formant edit can splice stale audio. Mitigation: F-engine lands after p2-ren commits; G10 is a merge gate.
2. **A dropped field at a rebuild site = a silent tone change.** Mitigation: the init param has no default (the compiler census), plus G9.
3. **Units trap.** Hz passed raw to `setFormantBase` silently weakens the correction and still passes `audible=true`. Mitigation: the shim divides; G2 at 80 Hz catches it (INFERRED that it would; plant it to confirm).
4. **Quality ceiling.** Upstream calls its formant correction less sharp than PSOLA; the one measured formant-mode number is a −5.18 dB dip at a 2-st step (m23-q-phase0-curve-experiment.md:161). If the round's D still sounds wrong, the m23-q §6.5 ladder applies (a shorter hop next). Rubber Band commercial or a PSOLA stage NEED THE USER'S WORD.
5a. **The formant path runs on EVERY corrected vocal, not only on far moves.** With c = 1, any hop with T ≠ 0 (shaping moves most notes by a few cents) runs `processFormants`. Any colouration and the cost therefore land on everything the user tunes. G2b gates the colouration; the cost is owed.
5. **Base from `detectedHz` is per-note, not per-frame.** It is also a step function: adjacent notes with different f0 change the envelope decay abruptly at the boundary (INFERRED). A refinement is to blend log-f0 through the same gates. Octave errors in detection would halve or double the envelope smoothing (INFERRED). A per-frame contour base is a later refinement; bump `formantRenderVersion` when it lands.
6. **Latency** (INFERRED 2379) and **cost** (INFERRED 10-20 %) are both unmeasured; G4 and the timing run are owed.
7. **Above ~7.1-8 kHz the map is additive.** Sibilance under formant correction is unmeasured and belongs to §2; the gates here exclude > 5 kHz on purpose.
8. **Whole-clip transpose still chipmunks by default.** This is named out of scope; flipping `Clip.formantPreserve` needs its own ruling.
9. **Slot contention.** §2-§4 may also want digest slots; the integrator must fix the order (7 = formant) in the design doc before any code.


---

# §2 Consonants and breaths keep their pitch ("St" stays, only "ar" moves)

Owner lane: audio-dsp-engineer (render mix, gates); mcp-integration-engineer (wire + MCP); swift-app-engineer (toggle).
Labels: MEASURED = I ran/read the output this session or it is a cited measurement by a named lane; READ = seen in source;
INFERRED = reasoning, not yet measured.

## 2a. Current state

1. **One curve, and the gaps already sit at the clip term.** `PitchCorrectionCurve` is the only evaluator (render and
   display) (READ, `Sources/DAWCore/PitchCorrection.swift:1270-1456`). Where no note's gate is open it returns
   `clipPitchShiftSemitones` (READ, :1449), which is 0 unless the whole clip is transposed.
2. **No note contains an unvoiced frame today.** `voicedRuns` ends a run at every unvoiced frame (READ,
   PitchCorrection.swift:1825) and drops runs < 60 ms (:1786). Note edges are run edges (READ,
   `PitchNoteSplitter.swift:22-31`), and the only boundary writer is split (READ,
   `ProjectStore+PitchNoteEdits.swift:155`). No wire verb writes arbitrary spans (MEASURED by the map lane, grep with
   positive control). So the complement of the note table is exactly the unvoiced (plus dropped < 60 ms voiced) time.
3. **Consonants still move, by LEAKAGE.**
   - Ramps are centred on each edge, gate 0.5 at the voiced onset (READ, PitchCorrection.swift:1335, :1463-1479), so a
     moved note leaks up to half its shift r/2 into the neighbouring consonant: 100/55/20/15 ms for
     Gentle/Natural/Tight/Hard Tune and 15 ms for the editor seed (INFERRED arithmetic from
     `PitchCorrectionPresets.swift:79-91` and `ProjectStore+PitchNoteEdits.swift:522`).
   - The stretcher adds ±15 ms landing error and a 10.7-14.8 ms transition (MEASURED by phase-0,
     `Sources/DAWEngine/Stretch/OfflineStretcher.swift:184-218`, :302-306), and its ~120 ms analysis block shares a
     block between a consonant and a moved vowel (INFERRED from `signalsmith-stretch.h:63-65`).
   - Above the 8 kHz tonality limit the shift is ADDITIVE, (m-1)·limit Hz (READ, `signalsmith-stretch.h:850-856`), so
     a shifted 's' moves its envelope brighter or darker.
4. **Every gap is resynthesised.** With any pitch edit, `renderAudio` takes the curve branch for the WHOLE file
   (READ, `Sources/DAWEngine/Stretch/StretchRenderCache.swift:803-821`). Gaps go through the stretcher at 0 st: an
   identity map (READ, `signalsmith-stretch.h:300`, :673-686) but not the source's bytes
   (READ, `Tests/DAWEngineTests/NoteLevelRenderTests.swift:321-328`, which proves only `bitMismatches > 0`). The
   magnitude is UNMEASURED.
5. **No path mixes dry and tuned.** The level mask MULTIPLIES delivered frames (READ,
   `StretchCurvePlan.swift:174-206`); the only dry output is the level-only branch, which excludes the curve branch
   (READ, StretchRenderCache.swift:822-844). But the mask is the exact template: a pure DAWCore function of source
   seconds (`PitchEditSet.gain(atSourceSecond:)`, READ `Sources/DAWCore/PitchNoteLevel.swift:86`), versioned
   (`levelMaskVersion`, :71) in digest slot 5 (READ, StretchCurvePlan.swift:431-440), applied once after the branch
   on both the whole-file and window entries (READ, StretchRenderCache.swift:877).
6. **`whole` survives the curve branch.** `renderAudio` passes `whole` by value into `stretchTransposeCurve`
   (READ, StretchRenderCache.swift:827, measured this session; the tree is being edited by another lane, so line numbers in this file drift by ~15 from the map's); only the level-only branch empties it (:854). A window reads source
   frames through `window.readSource` (READ, :850). So the dry source is in hand on both entries at no extra I/O.
7. **Voicing data exists but the render never reads it as a mask.** `ClipPitchFrame.frequencyHz == nil` is the only
   class; there is no fricative class (READ, `Sources/DAWCore/PitchDetection.swift:19-29`;
   `docs/research/2026-09-23-melodyne-class-pitch-editors.md:68`). Edges are uncertain by ±1 frame = 16 ms (READ,
   `Sources/DAWEngine/Analysis/PitchTracker.swift:591-594`). Loud gap frames on the user's take have median confidence
   0.59 (MEASURED by archB, `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md:135`).
8. **The unpitched design says the opposite of the MUST.** U5: moving an unpitched sound DOES transpose it; U-F2
   ("an unpitched move renders as nothing") is an unscheduled follow-up; U-A has not landed (READ, unpitched design
   :34-39, :262-279, :716; MEASURED by the map lane: no `NoteOrigin`/`.unpitched` in `Sources/`, positive-controlled).
9. **No control anywhere.** No wire key, MCP tool, UI control or physics test covers unvoiced handling (MEASURED by the
   map lane, Commands.swift pitch verbs :4967-5542, positive control returned the ten verbs).

## 2b. Decision and mechanism

**DECISION: mechanism (b), "the gaps play the untouched take".** Between notes, the render plays the SOURCE's own
samples; inside notes it plays the tuned render, unchanged. The join is a short crossfade placed on the GAP side of each
note edge, so every sample inside a note is byte-identical to today's render. The mask is SEGMENT-derived (the
complement of the pitched note spans), not contour-derived. It is active only where "dry" is well defined: ratio 1,
clip transpose 0, and no read time warp. Elsewhere the render is today's, and the wire says why.

**Why the two strongest alternatives lose.**
- (a) "Curve to the clip term on unvoiced frames". Today it reduces to one-sided ramps INSIDE each note, which
  moves the pitch transition and its −1.2 to −5.1 dB beat dip (MEASURED by phase-0, OfflineStretcher.swift:302-306)
  onto every vowel onset: a scoop into every moved note, which fights §4. Consonants stay resynthesised, and the
  120 ms block still smears the transposed vowel into them (INFERRED). It cannot resolve consonants under ~45-60 ms
  (INFERRED: 30 ms hop, ±15 ms landing). And a ramp-placement change has no version home except
  `stretchEngineVersion` (READ, StretchRenderCache.swift:198), which re-renders every stretched clip.
- (c) A harmonic/noise split (Melodyne-class). It is the only thing that handles sibilance OVERLAPPING voicing ('s' on a
  vowel tail, voiced 'z'/'v'), but it is new DSP with no instrument, no fixture and no measured need yet. Filed as
  N2-F3. Per-hop formant or tonality-limit tricks on unvoiced hops are weak, global and unmeasured (the auto-f0 on
  noise is arbitrary, INFERRED from `signalsmith-stretch.h:950`).
- Contour-derived mask (a variant of b) loses to segment-derived: it would put the contour in the key of EVERY
  pitch-edited render (today only when `shapesAgainstContour`, READ StretchRenderCache.swift:140-143), forcing a
  detection before every render and a fallback path. The segment mask is exact while notes = voiced runs (2a.2) and
  becomes "complement of PITCHED segments" once U-A lands (2b.6).

**Mechanism, down to functions.**
1. **Model field (DAWCore, set-level).** `PitchEditSet.keepsConsonantsUntuned: Bool`.
   - Memberwise-init default `false`, Codable ABSENT decodes `false`, encoded only when `true`.
   - New sets get `true` at the PRODUCT seams (2c), not in the initialiser, so every test that builds a
     `PitchEditSet(...)` keeps its golden.
   - Declared in `PitchCorrection.swift` beside `retuneMs` (READ :797), added to `CodingKeys` (:916), `init(from:)`
     (:919-931) and `encode(to:)` (:935-940).
2. **The pure mask (DAWCore, new file `Sources/DAWCore/PitchConsonantMask.swift`).** `extension PitchEditSet`:
   - `static let consonantMaskVersion: Int = 1` (the `levelMaskVersion` precedent, READ PitchNoteLevel.swift:71).
   - `static let consonantFadeSeconds: Double` and `static let consonantMinimumGapSeconds: Double`: MEASURED defaults
     from M-3 (§2g). Starting candidates: 0.010 and 0.064 (4 frames; U-A's "keep ≥ 4 frames" precedent, unpitched
     design :148-149). Picks until M-3 replaces them.
   - `func consonantRegions() -> [ClosedRange<Double>]`: the gaps between consecutive PITCHED segments, plus the
     head (0 to the first note) and the tail (after the last note), keeping only gaps ≥ `consonantMinimumGapSeconds`.
     A shorter gap (a detector blink, 2 frames = 32 ms) stays WET: it renders exactly as today. That is the
     hole-bridging rule. Empty when `keepsConsonantsUntuned == false`.
   - `func tunedWeight(atSourceSecond:) -> Double`: w in [0, 1]. 0 inside a region; 1 inside notes and in
     sub-minimum gaps; a raised-cosine ramp over the LAST `consonantFadeSeconds` of a region before a note, and the
     FIRST `consonantFadeSeconds` after a note. The ramp never enters a note, so w == 1 at every note sample.
     Clamped to half the region, so a short region never goes fully dry mid-fade. Pure, total, non-finite -> 1.
   - `var hasConsonantMix: Bool { keepsConsonantsUntuned && !isPitchIdentity }`: the ONE predicate (the
     `hasLevelEdits` precedent). A pitch-identity set bends nothing, so there is nothing to protect.
3. **The mix (DAWEngine).** `StretchCurvePlan.applyConsonantMix(_ set:, wet: inout [[Float]], dry: [[Float]],
   outputFrameOffset:, ratio:, sampleRate:, isCancelled:)`, beside `applyLevelMask`.
   - Per delivered frame f: s = `sourceSecond(forOutputFrame:)` (the one mapping, READ StretchCurvePlan.swift:46-84),
     w = `tunedWeight(atSourceSecond: s)`; if w != 1 then `wet = w·wet + (1-w)·dry`, with denormal flush like the level
     mask. It visits only frames inside regions, so its cost is O(gap frames).
   - Crossfade LAW: equal-gain (w, 1-w) is the starting candidate. In the fade, both sides carry the same consonant at
     ~0 shift, so they should be highly correlated (INFERRED). M-3 measures the correlation; if it is < 0.9 on the take,
     switch to equal-power (the p2-ren law, READ `docs/design/2026-09-25-incremental-note-render.md:439-444`), with a
     `consonantMaskVersion` bump. One law for every join, never chosen per join, so the mask stays pure DAWCore.
4. **Where it runs: inside `renderAudio`, once, after the branch and BEFORE `applyLevelMask`** (READ
   StretchRenderCache.swift:877). Only on `path == .curve` and only when `consonantMixActive(params)` holds. `dry` is
   `whole` on the whole-file entry, and `window.readSource(start..<end)` on the window entry (ratio 1 means output
   frame == source frame). The two masks touch disjoint frames (consonant mix: gap frames only; level mask: note
   frames only), so their order cannot change a byte (gate G-C2). Order is still fixed, so nothing depends on it.
   Because both entries go through this ONE body, drafts, the p2-ren provisional splice and finals cannot disagree.
5. **When it is inactive** (`consonantMixInactiveReason(params) -> String?`, pure, in StretchCurvePlan):
   - `"clip stretched"` when ratio != 1;
   - `"clip transposed"` when `params.semitones != 0`. Today consonants FOLLOW a whole-clip transpose
     (PitchCorrection.swift:1449); a raw-source mix would silently stop that;
   - `"time edits"` when `set.hasTimeEdits && StretchCurvePlan.readsTimeWarp` (READ :58, false today). A TRIPWIRE
     test fails the day `readsTimeWarp` flips, forcing this rule to be re-decided (G-C9).
   When inactive, the render is byte-identical to the flag-off render. The reason is reported on `clip.getPitchEdits`.
   "Dry under a transpose or stretch" means a SECOND stretcher pass at the constant clip term: 2x the cost, and its
   partial phases never converge with the curve render (−7 to +6 dB, READ StretchRenderCache.swift:887-894 in the
   map's numbering). That is follow-up N2-F1, gated on its own join measurement.
6. **U5 vs U-F2 (a ruling, surfaced).** Once U-A lands, `consonantRegions()` must read "complement of PITCHED
   segments": an `.unpitched` segment is inside a region, so moving it renders as nothing (U-F2). The MUST ("St must
   not change pitch") asks for exactly that. The cost is U-F3: a sung note the detector missed at < 0.9 confidence
   becomes an unpitched blob that can no longer be moved (unpitched design :219-222). **This design adopts U-F2 as the
   DEFAULT and needs the user's word on the escape hatch** (Q2 in §2h). Note that the missed-sung-note case is NOT made
   worse by this section today: such time is already a gap that renders at the clip term (2a.1).

## 2c. Defaults, and why

- **Existing projects render byte-identically.** An old set has no key, decodes `false`, emits no digest block, keeps
  its render key and takes the unchanged branch. This is the tree's "a shipped behaviour may not change tone" law
  (the `.clipper` precedent: NEW = on, ABSENT decodes the legacy value). Gates G-C7a/b pin the decode default and the
  bytes, not only the render.
- **New sets get it ON** (the user's MUST), set at the three product seams that CREATE a set:
  1. `PitchAutoCorrect` builders, READ PitchCorrection.swift:1905 and :1917;
  2. `PitchNoteTable.detected`, READ ProjectStore+PitchNoteEdits.swift:534;
  3. the editor's table seed, READ `Sources/DAWAppKit/PitchEditorModel.swift:1902`.
- ⛔ **Every seam that REBUILDS a set must COPY the flag**, or an edit silently turns protection off: split
  (READ ProjectStore+PitchNoteEdits.swift:161) is the known one. The implementing lane must CENSUS every
  `PitchEditSet(` call in `Sources/` (the six hits above were MEASURED by grep this session; report the method, not the
  number) and gate them with G-C8.
- **Existing tuned vocals stay as they are until the user turns it on** (the toggle, the wire verb, or a fresh
  Auto-Tune, which builds a new set). **Needs the user's word (Q1, §2h):** whether an update should instead turn it
  on for EXISTING tuned vocals too. That would re-key and re-render each such clip once (a digest-block change, not a
  `stretchEngineVersion` bump). I recommend OFF for existing projects: the law, plus the fact that the take they
  already approved would change sound without their action.
- **Measured defaults** (fade, minimum gap, law, edge offset) are delegated to us by the user's standing rule and set
  by M-2/M-3. They are declared constants, and each change bumps `consonantMaskVersion`.

## 2d. Render-cache key impact

- **Digest block, slot 8 (proposed).** Slots 1-6 are filed (READ StretchCurvePlan.swift:376-384); slot 7 is left to
  §1's formant block, which the formant map says must be filed before any code. **Integrator: confirm both slot
  numbers in the design doc before either lane writes code.** A block out of its slot re-keys every set that uses two
  features (READ :385-389).
  - New marker `consonantSuffixMarker`, distinct from the three existing markers (READ :315-326).
  - Gated on `set.hasConsonantMix`. Carries `putInt(PitchEditSet.consonantMaskVersion)` and, once the balance control
    ships (2f), `putDouble(consonantEdgeOffsetSeconds)`. The segment edges are already hashed inline, so the regions
    need nothing more.
  - Consequence: a flag-off set, or an identity set, digests exactly as before (G-C7c).
- **Inactive conditions do not remove the block.** A flag-on set on a transposed clip keys differently from flag-off
  while rendering identical bytes. That costs one redundant render when the flag is toggled on a transposed clip, and
  keeps the key a function of the set alone, never of the clip params. Deliberate.
- **`StretchRenderCache` Params / on-disk key:** no new field. The flag lives in the set, and the set already enters
  through the `pitch:` digest part (READ StretchRenderCache.swift:392-429). `stretchEngineVersion` is NOT bumped.
- **`ClipRenderSignature`:** covered through `Tuning`, which is built from the clip's set (READ
  `Sources/DAWAppKit/ClipRenderSignature.swift:110`). The implementing lane must confirm that `Tuning` compares the
  WHOLE set (so a set-level field reaches it) and add a signature test beside `ClipRenderSignatureTests.swift:337`.
  Not `RenderTimeBase`: the mix never changes length or time base (pinned by StretchEngineTests.swift:961).
- **p2-ren provisional splice (in flight, another lane).** `Sources/DAWEngine/Stretch/RenderDiff.swift` computes the
  dirty extent from "frames whose level masks differ" (READ :74, :199-222). It must ALSO union the frames whose
  consonant weights differ, computed by the same pass on a buffer of ones, or a toggle or a split that changes a
  region will serve a provisional without the change. Toggling the flag dirties every gap, so it exceeds the 40 %
  cap and the bridge plays until the final: correct, just not incremental. Coordinate with the Stage B owner; do not
  edit that file from this lane.

## 2e. Wire command and MCP tool (additive only)

- **New verb `clip.setConsonantProtection`** `{clipId, keepConsonantsUntuned: Bool}` (and later
  `consonantEdgeOffsetMs?`, 2f). It goes in the verb registry beside `clip.setNoteGain` (READ
  `Sources/DAWControl/Commands.swift:494`) and in the dispatch beside the pitch verbs (:4967-5542).
  - It uses `rejectUnknownKeys`, the house idiom (READ :4587, :5227).
  - It refuses with a clear error on a clip that has no pitch edits: there is nothing to protect, and silently
    creating an empty set would be a new side effect.
  - One undo entry. Its coalescing key goes in the design §7.4 undo-key home (READ PitchCorrection.swift:943-950).
  - Store: `ProjectStore.setConsonantProtection(clipID:_:)` in `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`,
    so the UI and the wire share one door (the one-command-surface invariant).
  - Response: `{clipId, keepConsonantsUntuned, consonantProtection: {active: Bool, inactiveReason: String|null}}`.
- **`clip.getPitchEdits` gains two fields** (READ :5216): `keepConsonantsUntuned` and the same
  `consonantProtection` object. `inactiveReason` is computed by the SAME pure
  `consonantMixInactiveReason` the render uses; it is never re-derived in the command (the `glideIsEffective` law in
  `docs/DESIGN-LANGUAGE.md:30`).
- **`clip.autoCorrectPitch` gains an optional `keepConsonantsUntuned`** (default true for the new set it builds;
  READ its key list at :5147). An absent key keeps the new default, so no existing caller changes.
- **MCP:** a new tool `clip_set_consonant_protection` in `mcp-server/src/server.ts`, next to `clip_set_note_gain`
  (READ :9314). The optional key goes on `clip_auto_correct_pitch`, and the `clip_get_pitch_edits` description names
  both new fields. Tool text, written for a novice agent: "Keeps breaths and consonants (s, t, p, ch) at the singer's
  original pitch when notes are moved. Works on clips that are not stretched or transposed; otherwise it reports why
  it is inactive." Counts: the wire +1 and the MCP tools +1, both re-measured with
  `node scripts/gates/doc-count-drift.mjs` (the command-count pin), never quoted from this doc.
- Plugin bundle: if the sound-designer/vocal agent allowlists are HAND-MAINTAINED (the M39 lesson), the new tool must be
  added there too, or a regenerated bundle will not reach agents. The implementing lane must check the artifact the
  user loads, not only the source tree.

## 2f. UI (docs/DESIGN-LANGUAGE.md)

- **Where:** the pitch editor header, in the same row as the preset chips, which already carry a drawn one-line
  summary (READ DESIGN-LANGUAGE.md:42). It shows in BOTH Simple and Pro: it is the MUST, and it is the 20 % control.
- **What:** a boolean in the store, so it is the house `toggleCell` ON/OFF capsule, never a chip or a knob (the
  toggle-vs-chip law, READ DESIGN-LANGUAGE.md:22).
  - Label: **"Natural consonants"**.
  - Drawn summary under it (never a tooltip, because `view.capture` cannot see tooltips): **"S, T and breaths keep
    their own pitch."** It must fit one line at a 560 pt pane width; its length is a layout decision, measured like
    the 51-character sampler line (READ :30).
  - ON glows `playback` cyan (an earned state). OFF is neutral chrome.
- **Inactive (transposed or stretched clip):** it stays LIVE, goes DIM and SAYS SO (READ DESIGN-LANGUAGE.md:30).
  - The capsule ink is `textFaint` with no glow, and an amber line reads, for example, "Off while the whole clip is
    transposed". It must say it in the card's words, not the wire's.
  - It is gated on the SAME `consonantMixInactiveReason`, never a local `semitones != 0`.
  - The line is conditional, so it counts in the header's worst-case height budget.
- **Blobs:** no new drawing in this section. Showing WHICH time is protected (a faint hatch over consonant regions)
  belongs with U-E's unpitched-sound drawing. Filed as N2-F4 so the two draw one idiom, not two.
- **Balance control (Melodyne "Sibilant balance"): NOT in v1; decided by measurement.** It would be a Pro-only knob,
  "Consonant edge", −30 to +30 ms, bipolar arc with a 0 detent, SF Mono readout. It moves where the protected region
  ends relative to the detected voiced edge. It ships ONLY if M-2 shows the detector's voiced edge sits more than
  one frame (16 ms) from the audible consonant/vowel boundary on the user's take. That is exactly the error a user
  would need a knob to fix. If M-2 shows ≤ 1 frame, a knob would be a do-nothing control, which the design language
  forbids (DESIGN-LANGUAGE.md:35).

## 2g. Measurements first, then physics gates

**Measurements that set defaults. They run BEFORE the mix is coded, and each writes a PREREG first.** They use the
user's take by absolute path (`~/Music/DAW Pro Dogfood/2026-09-24 p2-seg physics/take/dry-norm.wav`, never copied)
in a new folder `~/Music/DAW Pro Dogfood/2026-09-25 natural-tuning/consonants/`.
- **M-1 Alignment and residual.** Render the take at ratio 1 with one moved note (the curve branch) and compare the gap
  frames against the source.
  - Lag: argmax of the cross-correlation over ±256 frames, per gap ≥ 100 ms.
  - Residual: level in dB below the source.
  - Pass condition: lag == 0 in every gap.
  - Positive control: the same code, fed the source delayed by 3 frames, reads 3.
  - If the lag is ≠ 0, the design STOPS: an integer compensation is a design change that must be re-reviewed.
- **M-2 Edge placement.** For the 19 audible no-note sounds that touch the following note (unpitched design :90-126),
  compare the product's voiced onset (`busyline-frames.csv`) with an independent onset (librosa spectral flatness
  crossing plus a periodicity rise).
  - Output: the median and the 90th-percentile offset.
  - Positive control: a planted 20 ms shift in the frames reads as 20 ms.
  - Decides the balance knob (2f) and the edge-offset default.
- **M-3 Fade, minimum gap and law.**
  - Histogram of gap durations on the take, to find where blinks (≤ 2 frames) separate from real consonants.
  - Wet/dry normalised correlation inside candidate fades of 5, 10 and 20 ms: ρ ≥ 0.9 means equal-gain.
  - It sets `consonantFadeSeconds`, `consonantMinimumGapSeconds` and the law.

**Gates.** None needs `@MainActor`; the env-gated real-take gate puts `@MainActor` on each test, never on the suite.
Instruments come from the measurement map: `SourceFilterVoice` (the 'Star' syllable fixture: s 120 ms, t 20 ms, /a/
400 ms, with ground-truth voicing) and `ConsonantSpectrumMeter` (bands 2-4/4-8/8-16/16-20 kHz, centroid in cents,
log-spectral distance over 1-20 kHz). Both are shared with the measurement lane; this section does not build them
twice. File: `Tests/DAWEngineTests/NaturalTuningConsonantPhysicsTests.swift` (new).

| Gate | Asserts | Positive control (the gate CAN fail) | Negative control |
|---|---|---|---|
| G-C1 dry gaps are the source | Flag on, ratio 1, 0 st: every frame inside a region, beyond the fade, EQUALS the source bytes | Plant: the dry read offset by +1 frame fails. The flag-off render of the same set shows `bitMismatches > 0` (today's NoteLevelRenderTests shape, :321-328) | The same comparison on the note frames is NOT asserted equal |
| G-C2 note interiors untouched | Flag on vs flag off: every frame with w == 1 is byte-identical, including level-edited and cleared notes, in both mask orders | Plant: a fade that leaks 1 ms into the note fails | A frame inside a region differs (proves the mix ran) |
| G-C3 the 's' does not move | 'Star' fixture, /a/ moved +300 c: the 's' region's centroid and 4 bands vs the SOURCE stay within the floor. The floor is the flag-on render with the /a/ unmoved | Flag OFF on the same edit reads a shift. The expected value comes from mapFreq: multiplicative below 8 kHz, additive (m-1)·8000 Hz above (READ signalsmith-stretch.h:850-856). A constant clip transpose of +300 c reads that expected value, so the instrument sees shifts. Must be RED on today's code | The /a/ still moves +300 c (SpectralShiftMeter, READ PitchWanderMeter.swift:192-285) |
| G-C4 no click at joins | First difference at every join ≤ the bound from p2-ren G3 (READ incremental-note-render.md:858-871) | Plant: fade = 0 (a hard switch) fails | A join between two identical inputs reads 0 |
| G-C5 no dip or bump at joins | 10 ms RMS across each join within [−6, +1.5] dB of its neighbours (p2-ren G4) | Plant: wet delayed by 64 frames (comb) fails | Flag off: no joins exist, so nothing is checked. Prove it by counting joins = 0 |
| G-C6 span == whole | `renderSpan` windows that straddle a join equal the whole-file frames (the I1-F1 invariance, READ ClipSpanRenderTests.swift:203) | Plant: the mask evaluated at window-local frames fails | A window away from any join equals too |
| G-C7a decode default | Old JSON (no key) decodes false; a set built by `PitchEditSet(...)` is false; true round-trips and false is omitted from the bytes | Plant: absent decodes true fails | A new-set seam produces true |
| G-C7b bytes at default | All existing goldens unchanged: §A vibrato goldens, whole-file golden (I1F1_GOLDEN_OUT), c21 legacy digest, I7a level block, edit-free key/render, tuned-then-cleared (list: measurement map "byte-identity gates") | The existing negative controls of those suites | none new |
| G-C7c digest | Flag off, or an identity set: the digest is unchanged. Flag on and bending: it changes. A `consonantMaskVersion` bump changes it | Plant: an ungated block changes flag-off digests, fails | Identity set with flag on: digest `""` |
| G-C8 the flag survives edits | For every store/wire path that rebuilds a set (split, setNotePitch(es), setNoteCleared, setNoteGain, autoCorrect replaceExisting:false): true in, true out | Plant: drop the copy in split fails | false in, false out |
| G-C9 inactive = today | ratio ≠ 1 or semitones ≠ 0: flag-on bytes == flag-off bytes, and `inactiveReason` is non-nil. Tripwire: a test asserts `StretchCurvePlan.readsTimeWarp == false`, with a message saying to re-decide 2b.5 when it flips | Plant: removing the transpose guard fails | ratio 1, 0 st: the reason is nil |
| G-C10 blinks stay wet | Two notes split by a 32 ms gap: the gap bytes equal the flag-off render | Plant: minimum gap 0 makes a dry island, fails | A 120 ms gap does go dry |
| G-C11 real take (env-gated) | On the 38 audible no-note sounds, with notes moved ±300 c: consonant distance (1-20 kHz) vs source ≤ the M-1 floor for sounds beyond the fade | Flag off: the sounds within 60 ms + r/2 of a moved note exceed it (RED, per U5) | Sounds far from any moved note pass both ways |

Physics passing does NOT close m23-ap-5 (the human E2 listen). That stays open.

## 2h. Questions for the user

**Q1 (a decision, not taste): existing tuned vocals.** "Natural consonants is on for everything you tune from now on.
Should it also switch on for vocals you already tuned? Yes: they re-render once and their S and T sounds change
slightly. No: they stay exactly as you approved them until you flip the switch." **Recommended: No.**

**Q2 (a decision): a blob the app thinks is a breath but was really a sung note.** This only arises after U-A, and it
is the U5 vs U-F2 ruling. "Breaths and consonants never change pitch, even if you drag them. If the app mistook a
quiet sung note for a breath, should there be a 'this is a note' button that makes it movable?" **Recommended:
consonants never move (the MUST); add the button as U-F3.**

**Q3 (listening, ONE axis: where the protected part ends).** One word of the take ("St|ar"-like, chosen by M-2 from
the 19 sounds touching a note), with the vowel moved +3 st. Four files, identical except for where the untouched
consonant hands over to the tuned vowel:
- **A** "Consonant fully tuned": today's render, as the reference.
- **B** "Hand-over 16 ms early".
- **C** "Hand-over at the vowel". **Recommended default**, unless M-2 moves it.
- **D** "Hand-over 16 ms into the vowel".
Pipeline: the P-L pattern (PREREG, the product render path, checks with plants, −21.5 LUFS, ≤ −1 dBTP on the
decoded MP3s, a manifest). Audibility check first: if the four cannot be told apart by the consonant meter, say so on
the page (the audibility rule) and treat the knob as unwarranted. This round is optional if M-2 is unambiguous; the
user's pick is feedback, not a defect report.

## 2i. Files this section touches (lanes cut by file)

DAWCore (lane N2-core, audio-dsp-engineer):
- `Sources/DAWCore/PitchConsonantMask.swift` (NEW): the regions, the weight, the version, the constants, `hasConsonantMix`.
- `Sources/DAWCore/PitchCorrection.swift`: the field, CodingKeys, decode/encode, the builders at :1905/:1917.
  ⚠ SHARED with §1 and §3. The integrator must serialise edits to this file.
- `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`: the setter, the copy in split (:161), the detected seed (:534).
  ⚠ SHARED.

DAWEngine (lane N2-render, audio-dsp-engineer):
- `Sources/DAWEngine/Stretch/StretchCurvePlan.swift`: `applyConsonantMix`, `consonantMixInactiveReason`, the digest
  block in slot 8 and its marker. ⚠ SHARED with §1 (slot 7): one integrator order.
- `Sources/DAWEngine/Stretch/StretchRenderCache.swift`: the ONE call in `renderAudio` before `applyLevelMask`.
  ⚠ Currently modified in the tree by the p2-ren lane.
- `Sources/DAWEngine/Stretch/RenderDiff.swift` (untracked, p2-ren Stage B): the consonant-weight diff in the dirty
  extent. That lane's owner makes this edit.

Wire, MCP, UI:
- `Sources/DAWControl/Commands.swift`: the verb, the registry, `getPitchEdits` fields, the `autoCorrectPitch` key.
  Lane N2-wire, mcp-integration-engineer.
- `mcp-server/src/server.ts` plus its tests, and the plugin allowlist if hand-maintained. Lane N2-wire.
- `Sources/DAWAppKit/PitchEditorModel.swift` (:1902 seed, toggle state, inactive reason) and the pitch-editor header
  view in `Sources/DAWApp/`. Lane N2-ui, swift-app-engineer.
- `Sources/DAWAppKit/ClipRenderSignature.swift`: a test only, unless `Tuning` drops set-level fields.

Tests (all NEW files, so no edits to files other lanes hold):
- `Tests/DAWCoreTests/PitchConsonantMaskTests.swift` (G-C7a, G-C8, G-C10 at the mask level).
- `Tests/DAWEngineTests/NaturalTuningConsonantPhysicsTests.swift` (G-C1 to G-C6, G-C9).
- `Tests/DAWEngineTests/ConsonantDigestTests.swift` (G-C7b/c).
- `Tests/DAWEngineTests/NaturalTuningConsonantTakeTests.swift` (G-C11, M-1 to M-3 harness, env-gated).

Docs: `docs/ARCHITECTURE.md` "Key future decisions" (integrator); `docs/ROADMAP.md` m23-nt capability 2;
`docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` (U5 marked superseded by U-F2 as the default,
pending Q2). No entitlements, signing, AUv3 or full-Xcode dependency: this is pure Swift in DAWCore and DAWEngine.
RT safety: the mix runs in the detached offline render job, never on the render thread (READ, the same job as
`applyLevelMask`).

## 2j. Risks

1. **The alignment is a CONTRACT, not a measurement** (READ OfflineStretcher.swift:20-25; no test measures a lag).
   Any lag makes every join comb. M-1 is a hard precondition. Mitigation: G-C5's delayed-wet plant.
2. **The segment mask goes wrong silently when notes stop being voiced runs.** That happens with S3 onset placement,
   hand-authored tables, a merge, or U-A's `.unpitched` segments. After any of them, "gap" no longer means
   "unvoiced". Mitigation: `consonantRegions()` reads PITCHED segments by one predicate, and a test pins the
   predicate against U-A's `entersPitchCurve` the day U-A lands. Record in the U-A plan that it must edit this file.
   The latent uniform-step shaping defect (READ PitchCorrection.swift:1300-1305) is NOT triggered here: this design
   never makes a span cover a hole.
3. **Overlapping sibilance is not handled.** An 's' riding a vowel tail, or a voiced 'z'/'v', sits inside a note and
   is still shifted: only a harmonic/noise split fixes that (N2-F3). The UI summary must not promise more than "S, T
   and breaths": it says nothing about 'z'.
4. **The last `fade` ms of a consonant is a blend.** The wet half carries up to half the ramp's shift (centred ramps,
   2a.3). Fade and edge offset are measured (M-2/M-3). The ramp placement itself stays §4's decision. If §4 moves the
   ramp into the gap, this section's discarded gap absorbs it with no change here.
5. **Detector blinks.** A blink of ≤ 2 frames stays wet by rule. A longer false gap inside a sustained vowel becomes a
   dry island at the ORIGINAL pitch with two joins, which is a new, audible defect. M-3's gap histogram must show the
   minimum-gap default clears the take's blinks. G-C10 pins the rule.
6. **Silent flag loss.** Any code that rebuilds a `PitchEditSet` without copying the field turns protection off with
   no error. G-C8 plus a census of `PitchEditSet(` sites. Report the method, never a count.
7. **Two sections, one file, one digest order.** §1 (formant block) and §2 (consonant block) both append to
   `PitchEditSetDigest` and `PitchEditSet`. The slot numbers must be filed before either lane codes (2d).
8. **The p2-ren Stage B splice** must include consonant-weight differences in its dirty extent, or a provisional will
   play stale gaps until the final commits (transient, but audible). Owned by the Stage B lane.
9. **Transposed and stretched clips get no protection in v1.** That is honest (dim plus a reason) but incomplete. If the
   user's vocal workflow transposes whole clips, N2-F1 (a second pass at the clip term) moves up the order. That needs
   its own join measurement: its phases never converge with the curve render.
10. **Perception is unmeasured.** Every perceptual claim here (smear, phasiness, clicks) is INFERRED until M-1 to M-3
    and G-C11 run on the real take. A synthetic fixture proves the instruments, not the sound.

**Follow-ups filed by this section:**
- N2-F1: protection under a clip transpose or stretch.
- N2-F2: the balance knob, if M-2 warrants it.
- N2-F3: a harmonic/noise split for overlapping sibilance.
- N2-F4: drawing protected regions, with U-E.


---

# §3 Pitch Drift and Pitch Modulation: steady without rigid, reduce/restore the wobble

Scope: the user's ask 3 (`user-ask-2026-09-25.md`): "the Pitch Modulation Tool (reduce or restore
vibrato) and the Pitch Drift Tool (steady a note without making it rigid); keep some natural scoops
between notes." Labels: MEASURED = I ran it this session; READ = seen in source/doc; INFERRED = arithmetic
or reasoning, not run. Line numbers are at the tree of 2026-09-25 (HEAD `813c415` plus uncommitted work).

## 3a. Current state

**The levers exist and render. Nothing lets you set them per note.**

- Model: `NoteSegment.driftScale` / `vibratoScale`, relative keep levers (0 flat, 1 as sung, >1 more),
  `shapeScaleRange = 0...4` (a pick) — `Sources/DAWCore/PitchCorrection.swift:303-324`, `:470` (READ).
  Omitted from the saved file at default 1 (`:735-736`, map, READ).
- Render: `PitchCorrectionCurve.make` splits the note's contour (cents vs `detectedHz`) into
  `drift = movingAverage(cents, 0.25 s)` and `vibrato = total − drift`, then adds
  `((driftScale−1)·drift + (vibratoScale−1)·vibrato)/100` — `PitchCorrection.swift:1318-1323` (READ this
  session). `movingAverage` is a centred, edge-TRUNCATED boxcar: `halfWidth = round(0.25/step/2)`, so at
  16 ms frames 17 taps ≈ 272 ms, and near a note edge the window shrinks one-sided — `:2104-2123` (READ).
- The window is self-declared "AN UNCALIBRATED PICK … should be measured" once an editor moves the two
  scales apart — `PitchCorrection.swift:1221-1232` (READ). `shapingVersion = 1` sits in every
  contour-shaped render key — `:1610-1638`; `StretchRenderCache.swift:426-427` (READ).
- Only writer: the auto-correct policy, which sets BOTH scales to `1 − strength` when
  `preserveVibrato:false` (`PitchCorrection.swift:1911, :1941-1942`, map READ); reached by Hard Tune
  (`PitchCorrectionPresets.swift:88-91`) and `clip.autoCorrectPitch` (`Commands.swift:5187-5188`).
  Equal scales ⇒ the split cancels algebraically, so the separator has never shaped product audio.
  A DAWCore test pins exactly that cancellation and its negative control (unequal ⇒ differs) —
  `Tests/DAWCoreTests/PitchCorrectionTests.swift:804-839` (READ).
- The known leak: the 250 ms window passes 121 % of a 5.5 Hz wobble into "vibrato"
  (`PitchCorrection.swift:1627-1632`, READ). Consequences: `vibratoScale 0` alone leaves an inverted
  ~21 % (C5a V3, READ); `driftScale 0` alone WIDENS a 5.5 Hz wobble by ~21 % (INFERRED, same boxcar
  gain; never rendered — no drift-0/vibrato-1 cell in `ContourShapingSweepTests.swift:86-113`, map MEASURED).
- Missing writers (map, MEASURED): no store setter (only pitch/cleared/gain/pitch-group at
  `ProjectStore+PitchNoteEdits.swift:67/203/275/359`), no wire verb, no MCP tool, 0 UI hits for
  `driftScale|vibratoScale` in `Sources/DAWApp`+`Sources/DAWAppKit`; palette = Move + Split
  (`PitchEditorModel.swift:1113-1135`). Undo keys `.drift` and `.vibrato` exist with zero callers
  (`PitchCorrection.swift:980-997`, READ this session).
- Generator fields (rate/depth/onset, `:326-415`) render but have no writer (`server.ts:8939-8940`).
- Queued, not built: **C5a** (`docs/design/2026-09-24-pitch-editor-vibrato-handle.md`): C5a-2 store
  setter `setClipNoteVibrato(clipId:segmentId:edit:)` with `NoteVibratoEdit` carrying six optionals
  incl. `driftScale` (§10, :1061-1160, READ); C5a-3 `clip.setNoteVibrato` / `clip_set_note_vibrato`
  (§12.1/12.4, :1237-1337, READ); C5a-4 the **Wobble** tool: keep lever k∈[0,2], drift coupled on the
  way down `driftScale = min(driftAtMouseDown, k)` (§5.2, :449-471, READ), flat = both 0 (§5.3), and
  §10 item 6 "the `.drift` key is left for a drift-only control, which does not exist" (READ).
  **C5b** freehand delta brush (`…-timing-and-freehand.md` §5) writes a separate shape term; C5a §13
  fixes the sum as `constant + shaping + generator + shape` with neither writing the other's fields
  (:1356-1394, READ). C-F7 (smoothing brush) is filed only.
- Scoops: slides > `scoopLimitSeconds = 0.128` become their own transition parts, kept as sung in every
  preset (`PitchNoteSplitter.swift:160-178`; `PitchCorrection.swift:1860, :1966-1967`, map READ).
  Scoops ≤ 0.128 s belong to the held note.
- Short notes: 24 of this singer's 42 notes are < 0.384 s (vibrato-handle §18.0, map READ).

## 3b. Decision and mechanism

**Decision: one tool set = two palette tools over ONE setter family and ONE verb pair.**
- **Wobble** (C5a-4, unchanged door) is our Pitch Modulation tool: reduce / restore / exaggerate the
  singer's own wobble, or hand off to a new one.
- **Drift** (new, filed as **C5a-5**, inside C5a so there is one home) is our Pitch Drift tool: vertical
  drag on a note (or the selection) moves `driftScale` only. It is how "steady without rigid" is done:
  the slow wander goes, the wobble and the fast onset scoop stay.
- Both write through C5a-2's `setClipNoteVibrato` (its `NoteVibratoEdit` already carries `driftScale`,
  §10, READ) and its new batch twin. No second setter, no second verb family, no drift-only command.
- C5b's brush stays the drawing tool (shape term, C5a §13); it never writes the scales. C-F7 (smoothing
  brush) stays filed for SUB-note regions only; whole-note steadying is the Drift tool's job.

**Prerequisite, and it IS C5a-F2 (promoted here, not a sibling): a separator that does not invert.**
- Kernel v2: two cascaded centred boxcars of length L (triangular kernel). Frequency response
  `≈ sinc²(πfL) ≥ 0`, so no band is passed into "vibrato" at more than 100 % and nothing is inverted.
  Kernel arithmetic (MEASURED: discrete kernels at the 16 ms frame step, pure Python, this session;
  interior frames only, edge handling not modelled, no audio): v1 17-tap boxcar reads −0.215 at 5.5 Hz
  (matches the source's 121 %). v2 at L = 0.25 s (support 0.528 s): drift captures 94 % at 0.5 Hz,
  78 % at 1 Hz, 4.6 % at 3 Hz, and at most 4.8 % of any 4-8 Hz wobble. At L = 0.20 s (support 0.40 s):
  97 % / 87 % / 22 % and ≤ 4.9 % over 4-8 Hz. At L = 0.16 s: 13 % leak at 4 Hz. **L and the edge rule
  (truncate as today vs. reflect) are picked by gate G3's sweep, not by this arithmetic**
  (L ∈ {0.16, 0.20, 0.25} s; the short-note cell trades against the leak cell).
- **Byte identity by branch, not by algebra.** In `PitchCorrectionCurve.make` (`PitchCorrection.swift:1315-1323`):
  `if segment.driftScale == segment.vibratoScale { <today's lines, unchanged, v1 movingAverage> } else { <v2> }`.
  Today's expression depends numerically on `macro` even when the scales are equal, so any change there
  would move low bits of every Hard Tune render; the branch keeps them bit-for-bit.
- New pure function `PitchCorrectionMath.triangularAverage(_:windowSeconds:stepSeconds:edge:)` beside
  `movingAverage` (`:2104`); `movingAverage` itself is not edited.
- Version: `PitchRenderContour.shapingVersion` stays 1 and now names the EQUAL-scale arithmetic; add
  `separatedShapingVersion = 2` and `static func shapingVersion(for set: PitchEditSet) -> Int` = 2 iff some
  segment with `wantsContourShaping` has `driftScale != vibratoScale`, else 1 (predicate lives in
  `PitchCorrection.swift` next to `wantsContourShaping`, one home). See 3d.

**Coupling (amends C5a §5.2/§5.3 by name).** An independent Drift tool makes `drift > vibrato` reachable,
and then C5a's `driftScale = min(driftAtMouseDown, k)` jumps with zero travel (drift 1, keep 0.5 ⇒ drift
snaps to 0.5 on the first tick). Decision:
- **If G3 passes (v2 leak ≤ its pre-registered bound): DECOUPLE.** Wobble writes `vibratoScale` only
  (plus the generator fields on the handoff); Drift writes `driftScale` only. D5's reason for writing
  both ("vibratoScale 0 alone keeps an inverted 17-22 %") is exactly what v2 removes, and G3 must show
  it removed. "Flat" becomes an explicit action: **Flatten note** (context menu and ⇧-double-click in
  either tool) writes both to 0, one undo step, `structuralKey` — Hard Tune's composition, measured.
- **If G3 fails: keep coupling, never jumping:** on the way down `driftScale = d0 · k / k0` for
  `k < k0` (k0, d0 at mouse-down; `k0 = 0` ⇒ drift untouched). Continuous at `k = k0`, reaches 0 at
  `k = 0` iff `d0 > 0`. The Drift tool then ships agent-only (wire) and the UI slot waits for F2.
- ⛔ **OUTCOME 2026-09-27 (W7-C3; verified by the orchestrator 09:57, 478/29 green): G3 FAILED → KEEP COUPLING.**
  Production (1,0) keeps 0.211 / 0.572 / 0.443 of the wobble at 110 / 220 / 82 Hz (bound ≤ 0.2); (0.5,0.5)
  reads 0.654 / 0.713 at 220 / 82 Hz (band [0.4, 0.6]). The separator's own legs pass at every pitch; the 220 Hz
  failures are RENDERER-limited (render 0.572 vs the curve's 0.146), which this design did not quantify. So: the
  Drift tool is agent-only, the proportional coupling above is what the Wobble gesture runs, and v2 (L 0.16 s,
  truncate, `minimumSeparableSeconds` 0.5) ships in the render as the unequal-scale fix. G4 not run. Record:
  `docs/ROADMAP.md` "W7-C3: drift/wobble separator v2 DONE"; evidence `scratchpad/w7/C3/STATUS.md`.
- Either way this changes a C5a design detail, not what the user asked for ("C5a with the dot",
  ROADMAP.md:1864): the dot and the Wobble gesture are unchanged. Say it on the handoff page as a note.

**Selection (Melodyne parity; amends C5a-2/-4).** When the pressed note is in a multi-selection, the
keep lever (Wobble) and the Drift lever act on every selected note. Each note moves from ITS OWN
mouse-down value by the same additive Δ, clamped per note by `NoteVibratoLimits.clamp` (C5a §10 item 3,
one function for UI and wire). The Wobble speed axis/handoff is single-note only; with >1 selected it
does nothing and the readout says "Speed works on one note at a time".
- Store: `setClipNotesVibrato(clipId:edits:[NoteVibratoItem(segmentId, edit)], seedIfAbsent:, undoKey:)`
  in `ProjectStore+PitchNoteEdits.swift`, modelled on `setClipNotePitchOffsets` (`:359`, READ: refuses
  an empty list before `noteTable`). C5a-2's single setter becomes a one-item call of it.
- Undo keys: single note `.drift(clipID:segmentID:)` (finally used; `PitchCorrection.swift:980-983`) and
  `.vibrato`; selections use group twins built the way the I4 group-pitch key is (the key after
  `:997`, READ exists, signature not re-read).

**Double-click (Melodyne parity).** In the Drift tool double-click toggles the note (or selection)
between as-sung (1) and steady (0); in the Wobble tool between 1 and 0 on `vibratoScale`. The value it
toggles away from is not remembered (Melodyne semantics; undo restores it). One step, `structuralKey`.

**Short notes, said in words.** Below `minimumSeparableSeconds` (G3's short-note cell picks it; the
v2 kernel's support is 0.40-0.53 s for L 0.20-0.25, so INFERRED ~0.4-0.5 s) the separator cannot tell drift from wobble:
"drift" there is close to the note's average offset from its own centre, so Drift re-centres the note
rather than steadying its shape. The tool still acts (a drag never snaps back) and the readout says so
(3f). This covers most of this singer's notes (24/42 < 0.384 s, READ) — the text is the product, not
an edge case.

**Scoops.** No new field. Under v2 a ≤ 0.128 s onset scoop is fast movement, so Drift should keep most
of it and Wobble-to-0 / Flatten straightens it. G3's scoop cell REPORTS the kept fraction (edge rule
included); the help text quotes only what G3 measured. Slides > 0.128 s stay separate parts, as sung.

**Declined, with reasons.** Negative (inverted) values: `shapeScaleRange` stays `0...4`; an inverted
wobble is a special effect, not a natural-tuning tool. A clip-level "reduce drift N %" macro: select-all
+ Drift drag IS the macro, and agents send the batch verb with every id; a second writer of the same
field is a second truth. A `keepWobble` preset field (P-ship): stays declined per keep100.

## 3c. Defaults, and why every existing project renders byte-identically

- **No new stored field.** `driftScale`/`vibratoScale` already exist, default 1, omitted from the file
  at 1 (READ `PitchCorrection.swift:735-736`). Codable decode is unchanged, so there is no decode
  default to argue, and the "declare new Doubles before `isCleared`" trap (`:456-462`) does not apply.
  The group setter, verbs and tool add behaviour, not schema.
- **Equal-scale sets (every set the product has ever written):** the `driftScale == vibratoScale`
  branch runs today's lines with today's `movingAverage`, so the curve is bit-identical and so is the
  key (`shaping:1`, 3d). Hard Tune, Natural (keep100 stands), Gentle, Tight: untouched.
- **Unequal-scale sets that already exist:** only hand-authored files can hold one (no writer exists,
  map MEASURED). They re-key to `shaping:2` and re-render once with the non-inverting separator. That
  audio change is the bug fix itself, so it needs no user decision; nothing the user made changes.
- **New notes:** a note nobody touched with Drift/Wobble keeps 1/1 and never enters the shaping path
  (`wantsContourShaping`, `:621`, READ).
- Tool defaults (all picks, gated by G3/G5, never shown as numbers): drift gain Δd = vertical travel /
  (3 × rowHeight) (the same pick as C5a's `.unmeasurable` keep gain, §5.2), clamp [0, 2] like the keep
  lever, quantised to 0.05, ⌥ divides gain by 4. The Drift clamp upper bound is 2 rather than the
  model's 4 for the same reason C5a gives: twice is already an unmistakable exaggeration.

## 3d. Render-cache key impact

- **Digest (`StretchCurvePlan`)**: nothing. Both scales are already hashed inline per segment
  (`StretchCurvePlan.swift:359-360`, MEASURED grep). No new block, no slot to file.
- **`StretchRenderCache.renderKeys`**: `:427` becomes
  `fields.append("shaping:\(PitchRenderContour.shapingVersion(for: params.pitchEdits))")`.
  `Params` already carries the set (`pitchEdits`, `:83`, READ). The function returns 1 unless
  `PitchEditSet.needsSeparatedShaping` (new, beside `needsDetectedContour` at `PitchCorrection.swift:852`:
  some segment `wantsContourShaping && driftScale != vibratoScale`), then 2. A later separator change
  bumps only `separatedShapingVersion`, which re-keys only unequal-scale renders, never Hard Tune.
- **`ClipRenderSignature`**: nothing. It already treats the `shaping:` version as a per-build constant
  (`ClipRenderSignature.swift:30`, READ) and covers the edit set, and the per-set version is a pure
  function of that set. G6 pins that a scale change moves the signature.
- **RenderTimeBase, `stretchEngineVersion`, `analysisVersion`**: untouched.
- ⚠️ **Lane collision:** `StretchRenderCache.swift` is uncommitted-modified by another lane (git status
  at session start). The one-line key change must be sequenced after that lane lands, or applied by it.

## 3e. Wire command and MCP tool (additive only)

No new command family. Two amendments to C5a-3 (unbuilt, so nothing live is renamed):
- **`clip.setNoteVibrato`** (C5a §12.1) unchanged in shape; its doc gains: "`driftScale` alone steadies
  the slow drift and leaves the wobble alone (after C5a-F2); `vibratoScale` alone reduces the wobble and
  leaves the drift alone; send both at 0 to flatten."
- **`clip.setNoteVibratos`** (NEW, batch twin; precedent `clip.setNotePitch` → `clip.setNotePitches`,
  `Commands.swift:460, :505`, READ): `{clipId, notes: [{segmentId, <any of the six C5a keys>}]}`, each
  item ABSOLUTE (the setNotePitches rule: a dropped call and a call of 1 must read back differently),
  one undo step, one render, `rejectUnknownKeys` per item, empty list refused before table lookup (the
  `setClipNotePitchOffsets` order, `ProjectStore+PitchNoteEdits.swift:362-372`, READ). No `reset` in the
  batch (reset stays single-note, as C5a specifies). Response: `clip.getPitchEdits` shape plus per-item
  `{segmentId, requested, applied, clamped, note?}` and, per item, `tooShortToSeparate: Bool`
  (`durationSeconds < minimumSeparableSeconds` and `driftScale != vibratoScale`), with a teaching `note`:
  "This note is shorter than about <minimumSeparableSeconds, 0.1 s> s, so its slow drift and its wobble
  cannot be told apart: changing drift here mostly re-centres the note."
  Single-note `clip.setNoteVibrato` returns the same flag.
- **MCP**: `clip_set_note_vibratos` beside C5a's `clip_set_note_vibrato` (precedent pair
  `clip_set_note_pitch` / `clip_set_note_pitches`, `server.ts:9102, :9366`, MEASURED grep). Description,
  for an agent that has never seen the model: "Steady or loosen several notes at once. driftScale is the
  SLOW wander of the note's centre, vibratoScale the FAST wobble: 1 = as sung, 0 = removed, up to 2 from
  the app's tools (the model allows 4). They are keep factors, NOT cents. To steady a note without making
  it robotic, lower driftScale and leave vibratoScale at 1. To flatten, send both at 0. Notes too short
  to separate report tooShortToSeparate: true; there, changing drift mostly re-centres the note." (No
  length in the MCP text: `minimumSeparableSeconds` is G3's output; the wire `note` string interpolates
  the constant, never a literal.) Also update
  `clip_auto_correct_pitch`'s text to say `preserveVibrato:false` with strength < 1 keeps `1−strength` of
  the wobble AND pulls only `strength` of the way to the target, leaving `1−strength` of the original
  mistuning — use `clip_set_note_vibratos` for "in tune, keep the wobble" (the coupling trap, map risk).
  ⚠️ **Corrected 2026-09-25 (C5a-3, read at `PitchCorrection.swift:3133`,
  `offset = strength * (targetMidi − detectedMidi) * 100`):** this sentence first said the pull was
  `1−strength`, which is inverted. The shipped MCP text states the code's mechanism.
- Count impact: +1 wire verb and +1 MCP tool beyond C5a-3's +1/+1. Pin with
  `node scripts/gates/doc-count-drift.mjs` (the command-count pin), never `grep -c`.

## 3f. UI (glass cockpit, novice words)

- **Palette:** Move · Split · Wobble · **Drift** (· Shape once C5b lands; Drift sits after Wobble,
  before Shape, by C5a §4.1's "more common edit first" rule). Symbol is the ui-design-engineer's pick
  (candidate `water.waves`), never `waveform.path` (Wobble's). Ink: `signal` with the house glow on the
  active note, never cyan (playback) or violet (AI) (C5a §4.1, READ). Readouts in SF Mono per
  `docs/DESIGN-LANGUAGE.md:8`; no stock AppKit sliders or panels.
- **Gesture:** press anywhere on a note (`PitchEditorModel.blob(at:)`), drag down to steady, up to
  loosen. Vertical only; horizontal travel does nothing. ⌥ = fine (gain ÷ 4). ⌘ = C5b brush, as in
  every tool. The router (`PitchEditorGestureRouter`, C5a §4.2) gains one kind, `.drift`.
- **What you see while dragging:** the played line (C-0) redraws on each quantised change (C5a §9.3's
  rebuild rule, unchanged). While the Drift tool is active, hovering a note also draws its **slow
  line**, the note's centre plus its v2 drift, as a thin dashed `signal` line, so "drift" is a thing on
  screen and not a word. It comes from one DAWCore function shared with the render
  (`PitchCorrectionCurve.driftLine(for:contour:)`), so picture and sound use one separator.
- **Readout (words, no percentages until the user rules, see 3h):**
  - 1: "Drift: as sung" · 0.7-0.95: "A little steadier" · 0.3-0.65: "Steadier" · 0.05-0.25:
    "Much steadier" · 0: "Held steady, wobble kept" · above 1: "More wander than you sang".
  - Wobble tool text gains one clause when drift is untouched: "slow drift kept (use Drift to steady it)".
  - Short note (`tooShortToSeparate`): the second line, in `textSecondary`, reads "Too short to tell
    drift from wobble. This mostly moves the note to its average pitch." The length in the sentence is
    `minimumSeparableSeconds` rounded to 0.1 s, never a hard-coded "0.4". Not amber: amber already means
    "the render could not apply this" (`PitchEditorView.swift:668-678`, map READ).
  - Contour unavailable: the tool is disabled on that clip with C5a §5.5's `.render`-basis gate and says
    "Pitch detail isn't ready for this clip yet", so the picture never promises what the render drops.
- **Help (palette tooltip):** "Drift — steady a note's slow wander without making it sound robotic.
  Drag down to steady, up to loosen. The note's wobble stays. Double-click: steady ⇄ as sung. Select
  several notes to change them together."
- **Context menu on a note/selection:** "Steady drift" (Drift → the 3h default) · "Flatten" (both 0;
  also ⇧-double-click in Wobble or Drift) · "Back to how you sang it" (C5a reset; now also resets
  drift). Each is one undo step.
- **Latency, honestly:** each release re-renders; the old render plays until the new one lands. The
  played line is the instant feedback. Not claimed as real-time.

## 3g. Physics and identity gates (each: positive control, negative control)

Order is load-bearing: **G0 and G3 run before any UI or wire code**. Assert the physics, not
`audible=true`; distinct bytes prove nothing.

- **G0: measure today's leak on the product path** (map step 1). Add cells (drift 0, vibrato 1) at A3,
  B3 and 110 Hz to `ContourShapingSweepTests` (env `CONTOUR_SWEEP`), read by `PitchWanderMeter`.
  Expected (INFERRED): a 5.5 Hz wobble plays ~+21 % WIDER. This number is the negative control G3 must
  beat. Positive control: the existing "vibrato 0 alone" cell re-derives its recorded values.
- **G1: equal scales stay bit-identical** (DAWCore, `Tests/DAWCoreTests/PitchSeparatorV2Tests.swift`).
  A frozen copy of today's `make` shaping lines (the `PrePitchNoteSplitReference` pattern) must equal the
  new code bit-for-bit on equal-scale sets (0/0, 0.5/0.5, 1.7/1.7) over a synthetic contour. Plus the
  existing byte gates stay green unchanged: `PitchPresetRenderGateTests.swift:357`, the whole-file
  golden (`ClipSpanRenderTests.swift:1447-1605`), `NoteVibratoGeneratorTests.swift:98-206` §A.
  Negative control: an unequal set (0/1) must NOT equal the frozen copy. Plant: route equal sets through
  v2 ⇒ G1 must fail (proves the branch is load-bearing).
- **G2: key.** (`Tests/DAWEngineTests/ShapingKeyVersionTests.swift`, new file.) A Hard Tune set's
  resolved key string equals its pre-change golden (`shaping:1`); a 0/1 set keys `shaping:2`; a set
  with one unequal note among equal ones keys 2. Plant: a global `shapingVersion = 2` bump ⇒ the Hard
  Tune golden fails. Negative control: 0/1 vs 1/0 sets have different keys (the digest, not the version,
  separates them).
- **G3: separation physics** (`Tests/DAWEngineTests/NaturalTuningDriftVibratoTests.swift`, the file the
  measurement map names; no suite-level `@MainActor`). Fixture: synthetic tone at 82, 110 and 220 Hz
  with known drift (0.5 Hz, ±30 c) + known vibrato (5.5 Hz, ±40 c); rendered through the SHIPPING path
  (`StretchRenderCache.renderIfNeeded`), tracked with `M23QToneTracker` at 4096/480, decomposed by a
  sine fit with a low-order detrend (the `PitchWobbleEstimate` method), each quoted as delivered ÷
  **IdealReading** (same tracker on an ideal tone that follows the expected curve).
  - Cells (d,v): (0,1) (1,0) (0.5,0.5) (0,0) (1,1). Pre-registered (PREREG before any render):
    (0,1) wobble within [0.9, 1.1] of ideal and drift ≤ 0.3 of as-sung; (1,0) wobble ≤ 0.2 of as-sung
    with NO inversion (residual's fitted phase against the original not opposite at a fitted depth
    ≥ 5 c); (0.5,0.5) each component within [0.4, 0.6].
  - Negative control: the same cells with the v1 kernel (the separator is a parameter in test builds)
    must FAIL (0,1) with ≥ +15 % widening, and (1,0) with an inverted remainder. If v1 passes, the gate
    is blind and nothing downstream ships.
  - Plant: a kernel with a deliberate negative lobe ⇒ fail.
  - Sweep: L ∈ {0.16, 0.20, 0.25} s × edge {truncate, reflect}, recorded as a table. Pick rule,
    pre-registered: smallest L that passes every cell at 110 Hz, ties to "truncate" (today's edge).
  - Short-note cell: 0.2 / 0.3 / 0.4 / 0.5 / 0.8 s notes; `minimumSeparableSeconds` = the shortest
    length where (0,1) keeps wobble in [0.8, 1.2] AND removes ≥ 50 % of drift. Stored as a constant
    with this test named in its doc comment.
  - Scoop cell: an 80 ms, 100 c onset scoop into a 0.8 s vibrato note. (0,1): REPORT the kept fraction
    of the scoop's area (not asserted). Control that the meter can see it: (0,0) must read ≤ 0.2.
  - 82 Hz cells are REPORTED, not asserted, until the tracker's known-answer control at 80 Hz passes
    (instrument limits, map).
- **G4: the user's take** (env-gated, inside the section-shared harness
  `NaturalTuningTakeHarnessTests.swift` + `nt-checks.py`, folder `~/Music/DAW Pro Dogfood/2026-09-25
  natural-tuning/`, PREREG first, audio never in the repo). Drift 0 / wobble 1 on every held note at or
  above `minimumSeparableSeconds`: independent YIN (`busyline-common.py`) slow band (0.3-2 Hz) falls by
  ≥ 40 % against as-sung; 4-8 Hz band stays within [0.8, 1.25]. Floor: the (1,1) render vs the
  stretcher-at-0 render. Plant: the same set rendered with v1 must show the wobble band widening.
  Short notes are reported separately and never averaged in. Pre-registered minimum N = 8 qualifying
  notes; below that G4 is REPORT-ONLY and says so (the take has 42 notes, 24 < 0.384 s).
- **G5: store and UI.** Group setter: one undo step, one render, silent no-op, per-item clamp; read-back
  against an INDEPENDENT expectation `NoteVibratoLimits.clamp(edit, …).edit`, never the setter's return
  (C5a §10, V13). Plant: a setter that drops `driftScale` ⇒ read-back fails. Double-click toggle and
  Flatten: one step each. `tooShortToSeparate`: true at 0.3 s, false at 0.8 s (plant: flag hard-wired
  false ⇒ fail).
- **G6: picture = sound.** Extend `PitchEditorDisplayMatchesRenderTests` with a 0/1 note (new test file
  if the original is in another lane's edit): the played line and `driftLine` come from the same curve
  as the render. `ClipRenderSignature` moves when only `driftScale` changes (negative control: a
  whitespace re-save does not move it).
- **G7: wire/MCP.** `Tests/DAWControlTests/PitchNoteVibratoCommandTests.swift` (C5a-3's file) gains the
  batch verb: empty list refused, unknown key refused, reset refused in batch, absolute semantics,
  `tooShortToSeparate` echoed. `mcp-server/test/pitch-correction.test.ts`. Counts via
  `doc-count-drift.mjs`.

## 3h. Taste: one listening set, and two word decisions

**Listening set (built only after G3 passes; P-L pattern).** Axis: **how much slow drift "Steady drift"
removes**, wobble always kept at 100 %. On the user's take, every held note ≥ `minimumSeparableSeconds`:
- A. drift kept 100 % (as sung; today's audio) · B. 60 % · C. 30 % · D. 0 % (held steady, wobble kept).
- Question for a non-musician: "Which sounds most in tune while still sounding like a person singing?"
- Pre-registered physics must ORDER the four (slow-band wander A > B > C > D by independent YIN) or the
  page is not published; −21.5 LUFS pure gain, true peak ≤ −1 dBTP on the decoded MP3s.
- **Recommended default: C (30 %)**: steady but not rigid, which is the user's own phrase (INFERRED
  taste, not measured). The pick sets ONLY the "Steady drift" menu action's target. It does NOT change
  the Natural preset (keep100 stands); changing a preset's audio is a separate yes/no, never implied.
- Before the pick lands, "Steady drift" writes 0 (Melodyne's semantics), and the double-click toggle
  always goes to 0.

**Needs the user's word (words, not listening):**
1. **A percentage readout.** Melodyne prints "% of the original"; C5a §9.3 rule 5 forbids printing a
   keep percentage (READ `:1001-1034`). Options: (a) words only, as 3f (recommended; safe with the
   detector's under-reading on this voice); (b) "keeps about N % of your drift", framed as a share,
   never cents. One question, asked once, on the handoff page.
2. **FYI, not a question:** Wobble no longer lowers drift on the way down (3b, if G3 passes); "Flatten"
   is the explicit both-to-zero action. The dot and the Wobble gesture are as the user asked. C5a §17
   (READ :1621-1652) only TOLD the user "pulling a note flat also straightens the slide … the route is
   C5a-F2"; it asked nothing about coupling, so this stays a statement: "Smoothing the wobble now keeps
   the slow drift and the short scoops; use Flatten to remove both."

## 3i. Files this section's implementation touches (for disjoint lanes)

| Lane (route) | Files | Order |
|---|---|---|
| L1 separator + key (audio-dsp-engineer) | `Sources/DAWCore/PitchCorrection.swift` (equal/unequal branch in `make` ~:1315-1323; `triangularAverage` beside `movingAverage` :2104; `needsSeparatedShaping` beside :852; `shapingVersion(for:)` + `separatedShapingVersion` beside :1638; `minimumSeparableSeconds`; `driftLine(for:contour:)`); `Sources/DAWEngine/Stretch/StretchRenderCache.swift` :427 (⚠️ another lane has it modified) | 1st, with G0-G3 |
| L1 tests (qa-test-engineer may write G1/G2) | NEW `Tests/DAWCoreTests/PitchSeparatorV2Tests.swift`, NEW `Tests/DAWEngineTests/ShapingKeyVersionTests.swift`, NEW `Tests/DAWEngineTests/NaturalTuningDriftVibratoTests.swift`; EDIT `Tests/DAWEngineTests/ContourShapingSweepTests.swift` (G0 cells) | with L1 |
| L2 store (swift-app-engineer; lands WITH C5a-2) | `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift` (`setClipNotesVibrato`, `NoteVibratoItem`); `Sources/DAWCore/NoteVibratoLimits.swift` (C5a-2 new); group undo keys in `PitchCorrection.swift` ~:997 (coordinate with L1: same file, disjoint regions); NEW `Tests/DAWCoreTests/PitchNoteVibratoGroupTests.swift` | after C5a-2 |
| L3 wire + MCP (mcp-integration-engineer; with C5a-3) | `Sources/DAWControl/Commands.swift` (`clip.setNoteVibratos`, verb list ~:505); `mcp-server/src/server.ts` (`clip_set_note_vibratos`, `clip_auto_correct_pitch` text ~:9002-9010); `Tests/DAWControlTests/PitchNoteVibratoCommandTests.swift`; `mcp-server/test/pitch-correction.test.ts` | after L2 |
| L4 UI (ui-design-engineer + swift-app-engineer; with/after C5a-4) | `Sources/DAWAppKit/PitchEditorModel.swift` (palette :1113-1135, `.drift` tool); `Sources/DAWAppKit/PitchEditorGestureRouter.swift` (`.drift` kind); `PitchEditorCommit.Kind` (`.noteVibratos`); `Sources/DAWApp/PitchEditor/PitchEditorView.swift` (slow line, readout, menu); `Sources/DAWApp/PitchCorrectionStaging.swift` (commit + read-back); NEW `Tests/DAWAppKitTests/PitchEditorDriftToolTests.swift`, NEW display-match test file | after L1 G3 + L2 |
| G4 harness (audio-dsp-engineer) | shared `Tests/DAWEngineTests/NaturalTuningTakeHarnessTests.swift` (section-shared; add a named set) + Dogfood folder scripts | after L1 |
| Texts that become FALSE after L1 (fix in the same change, not later) | `PitchCorrection.swift:1221-1232` (window "uncalibrated … never exercised": now calibrated by G3) and `:1627-1632` ("`vibratoScale: 0` on its own over-corrects", 34 %/56 %: true of v1 only); C5a §5.3 D5 rationale and §9.2 "smoothed flat" at k = 0 (drift now kept ⇒ "wobble smoothed, drift kept"); C5a §12.4 MCP text "vibratoScale 0 alone leaves part of the wobble behind"; `PitchEditorDisplayMatchesRenderTests.swift:360-363` comment (its case B is `vibratoScale 0` alone, so it now takes the v2 branch; the `< 0.4 × sung` bound should still hold, INFERRED, re-run); `ContourShapingSweepTests.swift` "vibrato 0 alone" recorded numbers (re-derive). `ContourToRenderTests.swift:231` restates the key with `shapingVersion` on a Hard Tune set: stays 1, unaffected (MEASURED grep, READ). | with L1 |
| Docs (docs-scribe; orchestrator) | C5a design amendment (§5.2/5.3 coupling, §10 group setter, §12 batch verb, C5a-5, F2 closed here); `docs/ROADMAP.md` (C5a-5 entry, fix stale C5a-0b box at :1592); `docs/ARCHITECTURE.md` Key future decisions (the per-set shaping version rule) | at close |

## 3j. Risks

- **The separator could still fail G3 on real voice.** A non-inverting kernel is arithmetic, not a
  measurement. Fallback is named (3b: keep coupling, Drift agent-only). Do not ship the UI slot on a
  fail.
- **Short notes dominate this singer.** With ~0.4-0.5 s needed and 24/42 notes < 0.384 s, the Drift tool
  will say "too short" on most notes of this take (INFERRED). That is honest, and it may disappoint. The
  words are mandatory: a silent near-no-op is the "silent inaudible success" class this tree has paid for.
- **The detector bounds the lever.** Drift can only remove wander the detector saw; it under-reads at
  72-145 Hz and invents a ±8 c square artefact in places (vibrato-handle §18.1.4/18.5, map READ). Any
  d ≠ 1 writes that artefact, scaled, into the audio. G4 reports it; the help never promises "perfectly
  steady".
- **Per-set versioning is a new rule.** Anyone later editing the equal-scale branch must bump
  `shapingVersion` (all Hard Tune renders re-key), and anyone editing v2 must bump only
  `separatedShapingVersion`. Both doc comments must say which branch they version; G2's plant
  enforces the split.
- **Branch drift.** Two separators in one function invites a "tidy-up" that routes equal sets through v2
  (bit-changes every Hard Tune render). G1's plant is the guard; the branch carries a comment naming G1.
- **Selection edits with mixed lengths.** A selection mixing short and long notes applies one Δ to all;
  the readout must say "N of M notes too short to separate" rather than one note's status.
- **Agents can misuse `clip.autoCorrectPitch` as a wobble knob** (keep = 1 − strength). Mitigated by the
  new description text only; the behaviour is shipped and stays.
- **Lane collisions:** `StretchRenderCache.swift`, `PlaybackGraph.swift`, `AudioEngine.swift`,
  `StretchEngineTests.swift` are uncommitted-modified by another lane; this section edits only the first,
  one line, and adds new test files rather than editing shared ones.
- **Render latency** makes a drag-to-taste tool slower than Melodyne's; the played line is the feedback.
- **Nothing here touches the render thread** (offline stretcher path only) and **nothing needs full
  Xcode** (no entitlements, AU, or signing).


---

# §4 Transitions — blending a moved note into an unmoved neighbour

_Status: COMPLETE for critique (daw-architect, 2026-09-25). Labels: MEASURED = I read/ran it this session; READ = seen in source by the map lane, spot-checked by me where marked; INFERRED = arithmetic or reasoning, never rendered (another lane holds the timing lock)._

## 4.0 Decision in one paragraph

A join between two notes that ABUT (same `endSeconds`/`startSeconds` bits: a join inside one voiced run) becomes a **soft join** with ONE symmetric crossfade width, stored on the LEFT note (`NoteSegment.transitionOutMs`, Melodyne's "rear part of the note"). When the user has not set it, the width is **automatic and grows with the size of the jump** the correction must travel across the join, capped by a set-level **correction-slope limit** (`PitchEditSet.transitionSlopeCentsPerSecond`, cents/s). A sung slide long enough to be its own `.transition` part is seeded with `NoteSegment.glideFollow = 1` in NEW editor tables, so when a neighbour moves the slide TILTS (starts at the moved note's new pitch, lands on the unmoved one) instead of snapping back. Joins across a HOLE (unvoiced gap) keep today's per-edge ramp untouched. Every new field is omitted from the saved file at 0, lives in a marker-gated digest block, and changes no existing project's bytes.

## 4.a Current state

- **One evaluator, one set-level width.** Every join goes through `PitchCorrectionCurve` (`Sources/DAWCore/PitchCorrection.swift:1137-1549`). `make` turns the set's `retuneMs` into ONE `halfRamp = min(ramp/2, duration/2)` per span (:1281, :1335, MEASURED); the gate is smoothstep rise × fall, both using that same half (:1463-1471, MEASURED); abutting spans with equal halves crossfade to exactly 1, over-sums are normalised (:1449-1455, MEASURED). The curve is a DELTA on the sung audio, so scoops pass through in shape (READ, banner :1123-1136).
- **Fields.** `PitchEditSet.retuneMs` (:797) is the only transition parameter, clamped to 30...500 (:818-825), decoded to 30 when absent and omitted at 30 (:926-927, :939) — MEASURED. `NoteSegment` has no per-note or per-join field and no kind; `isCleared` is declared last on purpose (:456-461, MEASURED), pinned by `noteBytesAreExactlyItsFields` (`Tests/DAWAppKitTests/ClipRenderSignatureTests.swift:337-356`, MEASURED: it counts `fields - 2` Doubles plus one trailing Bool).
- **Floor.** 30 ms = one signalsmith hop; the transpose is set once per hop, sample-and-hold (`OfflineStretcher.swift:322-339, 541-546`, READ). Phase-0: instantaneous 2 st jump = −5.11 dB dip; spread over 3 hops = −1.20 dB at +2.3 dB broadband (`docs/research/m23-q-phase0-curve-experiment.md:24, 158-159, 213`, READ). The engine renders any width ≥ one hop; it is not the bottleneck (READ).
- **Four join regimes** (splitter `PitchNoteSplitter.swift:26-31, 161-178, 436-478`, READ): (1) hole between voiced runs — per-edge ramps into the gap, benign; (2) sung link ≤ 128 ms cut at ONE frame — a moved neighbour splices a ~30 ms step into the glide (INFERRED); (3) link/lead-in/tail-off > 128 ms becomes a `.transition` part written as IDENTITY by every preset (`PitchCorrection.swift:1949-1970`, MEASURED; user pick (a-T) 2026-09-24) — a moved neighbour crossfades back to 0, so the slide starts from the OLD pitch (INFERRED); (4) scissors split — halves abut and inherit everything (`ProjectStore+PitchNoteEdits.swift:154-163`, MEASURED); F12 asymmetric-ramp dip possible at retune > 2 × the shorter half (timing doc :196-202, READ).
- **The defect is the default.** Editor-seeded tables carry 30 ms (`ProjectStore+PitchNoteEdits.swift:520-537`, MEASURED: `detected(from:retuneMs: = engineMinimumRetuneMs)`), a drag keeps the table's value (`NotePitchDraft.swift:44`, READ), so a 3+ st hand drag gets the fastest join the engine allows, or silently inherits whichever preset ran last (200/110/40/30, `PitchCorrectionPresets.swift:77-92`, READ). Nothing widens with the size of the move.
- **`PitchNoteTable.detected` KNOWS the part kind** at seeding time (it maps `PitchNoteSplitter.parts`, :526-533, MEASURED) and then drops it. That is the only moment a slide can be marked without U-A's `origin` field.
- **Surfaces.** UI: Move and Split only (`PitchEditorModel.swift:1113-1147`; router `PitchEditorGestureRouter.swift:44-101`, READ). Wire/MCP: `retuneMs` only via `clip.autoCorrectPitch`/`clip_auto_correct_pitch`, which rewrites the whole table (`Commands.swift:5059-5185`; `server.ts:8897-9036`, READ). Per-note verbs today: `clip.setNotePitch`, `clip.splitNote`, `clip.setNoteCleared`, `clip.setNoteGain`, `clip.setNotePitches` (`Commands.swift:460-505`, MEASURED). The drag's draft line already draws through the same curve (`PitchEditorModel.swift:1884-1911`, READ), so a transition edit shows live for free.
- **Six `PitchEditSet(` construction sites in `Sources/`** (MEASURED, grep with count control): `PitchEditorModel.swift:1902` (draft line), `PitchCorrection.swift:874, 1905, 1917`, `ProjectStore+PitchNoteEdits.swift:161` (split), `:534` (seed). The split and draft sites rebuild the set from `analysisVersion/segments/retuneMs` only — a new set-level field is DROPPED there unless each site carries it (see 4.j).
- **Provenance is free.** `contentStamp` hashes the set's full Codable encoding (`PitchEditProvenance.swift:83-98`, MEASURED), so any new encoded field automatically counts as a hand edit and routes preset re-application through the confirm door.

## 4.b Mechanism

### 4.b.1 Model fields (all DAWCore, `Sources/DAWCore/PitchCorrection.swift`)

| Field | Type / range | Meaning | Codable |
|---|---|---|---|
| `NoteSegment.transitionOutMs` | Double; `0` or `30...1000` | Width of the join to the NEXT note. `0` = automatic. Stored on the LEFT note (Melodyne "rear part"). | key `transitionOut`, omitted at 0; absent decodes 0 |
| `NoteSegment.glideFollow` | Double; `0...1` | This note is a sung slide that FOLLOWS its neighbours: a ramp from the previous note's offset to the next note's is ADDED to its own constant (own offset still shifts the whole slide, so dragging a followed slide is never inert). `0` = today (own constant only). | key `glideFollow`, omitted at 0; absent decodes 0 |
| `PitchEditSet.transitionSlopeCentsPerSecond` | Double; `0` or `500...20000` | Soft-join mode switch AND the auto-width rule: the fastest the ADDED correction may travel across a soft join. `0` = legacy (today's centred per-span ramps). | key `transitionSlope`, omitted at 0; absent decodes 0 |

- Both note fields are Doubles declared AFTER `amplitudeDb` and BEFORE `isCleared` (the byte-layout law, :456-461). `noteBytesAreExactlyItsFields` counts `fields - 2` Doubles, so it keeps passing with no edit (MEASURED formula, `ClipRenderSignatureTests.swift:347-350`). `init` CLAMPS (non-finite → 0; `0 < x < 30` → 30; above ceiling → ceiling) so a read-back is what applies (the `retuneMs` precedent, :791-796).
- Predicates, ONE home each: `NoteSegment.hasTransitionEdits { transitionOutMs != 0 || glideFollow != 0 }`; `PitchEditSet.usesSoftJoins { transitionSlopeCentsPerSecond > 0 || segments.contains(where: \.hasTransitionEdits) }`.
- ⛔ **None of the three enters `isPitchIdentity` (:566-571) or `isIdentity` (:556, :845).** With every offset at 0 a width or a follow bends nothing, so a freshly seeded table (which WILL carry a slope and `glideFollow = 1` on slides) stays identity: digest `""` (`StretchCurvePlan.swift:336`), identity bypass, and `Clip.hasPitchEdits` still agrees with `isIdentity`. INFERRED from the predicates; gated in 4.g (G-ID).
- Clamps: `transitionOutMs` — non-finite → 0, `0 < x < 30` → 30, `> 1000` → 1000. `transitionSlopeCentsPerSecond` — non-finite or `≤ 0` → 0 (legacy), `0 < x < 500` → 500, `> 20000` → 20000. `glideFollow` — non-finite → 0, clamped to 0...1. Ceilings and the 500 c/s floor are picks, bounded not measured — stated as such in the doc comment.

### 4.b.2 `PitchCorrectionCurve.make` (precompute, O(n), no per-hop neighbour lookups)

`Span.halfRamp` is replaced by `halfRampIn` and `halfRampOut`; `Span` gains `bridgeFromSemitones`, `bridgeToSemitones`, `bridgeAmount`.

1. **Legacy branch — `!editSet.usesSoftJoins`:** `halfRampIn = halfRampOut = min(ramp/2, dur/2)`, bridge fields `0`. This is today's value computed by today's expression; the gate below reads the same Double in both places, so the curve is bit-identical by construction (INFERRED; gated by §A goldens, 4.g G-BYTE).
2. **Soft-join branch.** Start every span at the legacy halves, then for each adjacent pair `(i, i+1)` whose `seg[i].endSeconds == seg[i+1].startSeconds` BIT FOR BIT (a join inside one voiced run — the splitter's parts abut bit for bit, `PitchNoteSplitter.swift:474-478`, READ):
   - `endValue_i` / `startValue_{i+1}`, cents: a note's own `pitchOffsetCents`, or, when it has `glideFollow = g > 0`, its bridged value at that edge: `own + g·neighbourOffset` (the neighbour's OWN offset — no recursion; two adjacent following slides each read their held neighbours only).
   - `Δ = |endValue_i − startValue_{i+1}|`.
   - `W = seg[i].transitionOutMs` if > 0; else, if `slope > 0`, `W = max(retuneMs, 1000·Δ/slope)`; else this join keeps its legacy halves (a set can be soft only because some OTHER note has an explicit width).
   - `h = min(W/2, dur_i/2, dur_{i+1}/2)`; `halfRampOut_i = h`, `halfRampIn_{i+1} = h`.
   - Edges facing a HOLE keep the legacy half. ⭐ This is deliberate and is §2's protection: widening joins that face unvoiced gaps would spread correction onto the very consonants §2 must keep still.
3. **Bridge.** For a span with `glideFollow = g > 0`: `bridgeFrom` = previous abutting note's `pitchOffsetCents/100` (0 if the previous edge faces a hole), `bridgeTo` = next abutting note's (same rule), `bridgeAmount = g`.

### 4.b.3 Evaluator (`semitones(atSourceSecond:editedSecond:)`, :1390-1456)

- `gate`: `rise` uses `halfRampIn`, `fall` uses `halfRampOut` (:1464-1470). Scan break at :1408 uses `halfRampIn`; `firstSpanIndex` (:1535-1541) uses `endSeconds + halfRampOut`.
- Contribution: `var constant = span.constantSemitones; if span.bridgeAmount != 0 { let u = smoothstep((t − start)/(end − start)); constant += g·(from + (to − from)·u) }` — ADDITIVE, so a drag of a followed slide moves it by its own offset (a `(1−g)·own` blend would discard the drag at g = 1: a moved blob with an unmoved line, a silent inaudible success). BRANCH ON PRESENCE, never `+ 0` (the §A lesson, :1413-1434). Smoothstep, not linear, so the tilt has zero added slope at both joins and stays C¹ with the crossfades.
- Shaping and generated vibrato are untouched: the singer's scoop, drift and vibrato still pass through as a delta — the tilt moves WHERE the slide starts and lands, never its shape (the "keep natural scoops" ask).

**§4 ERRATUM vf-18 (2026-10-12, W9-SLRV).** A uniform move of every note moved a followed slide twice (its own
offset + its neighbours', 2M; one-sided slides up to ~1.7M; joins 30 → 200 ms). The additive bridge stays —
a lone drag of a followed slide keeps meaning +D. Fixed at the WRITER: a group move stores
`own + (1 − g)·Δ` on a followed slide whose anchors move with it (`groupMoveCarry`, one home in
`NotePitchDraft.swift`), and through a versioned bridge rule: under `PitchEditSet.slideFollowRule =
.holdAtOpenSide` a slide reads only HELD soft neighbours and a side with none copies the other side's anchor
(step 3's "0 if the previous edge faces a hole" holds for `.sungAtOpenSide`, the absent value). Hold is the only
affine open-side rule under which a uniform move can be exact and an unmoved table stays identity
(`f(a+M) − f(a) = M`, `f(0) = 0` ⇒ `f(a) = a`). Sets adopt it inside a hand edit only when it changes no
sample they already play (`afterHandEdit(from:)`), or through `upgradedToNaturalTuning`. Agents move groups
with `clip.setNotePitches {moveByCents}`; the `notes` form keeps its absolute meaning.
Status 2026-10-12 (W9-SLFX): the DAWCore half is in (`PitchEditSet.applyingGroupPitchMove`, the rule and its
digest marker, `ProjectStore.moveClipNotePitches`); `moveByCents` on the wire and the editor's group drag land
in their own legs, and until then both still store literal offsets.

### 4.b.4 Invariants (each gets a pin in 4.g)

- **I1 — at most two gates open ALONG A CHAIN OF SOFT JOINS (scope matters).** The soft clamp `h ≤ min(dur_i, dur_{i+1})/2` bounds how far a NEIGHBOUR's ramp reaches into each note by half of that note, so inside a run no point sees three gates. It does NOT hold across HOLE edges, which keep legacy halves `min(r/2, dur_own/2)`: with retune 200 and a 60 ms note between two tiny holes, both neighbours' 100 ms ramps cross the whole short note — three gates, normalised, on HEAD today (the U2 0.239→0.208 trim, unpitched doc :244-247). That is PRE-EXISTING and unchanged here. The soft clamp also bounds the explicit width (a join cannot be wider than the shorter of its two notes). INFERRED.
- **I2 — a soft join never dips.** Both sides of a soft join use the SAME `h` about the SAME edge, so `s(x) + s(1−x) = 1` (complementary smoothstep, :1473-1475) and normalisation is not taken. This fixes F12 (timing doc :196-202) on every soft join of a soft set. Legacy sets keep F12 until they are upgraded (4.c D4-1). INFERRED.
- **I3 — `firstSpanIndex` (:1534-1548, MEASURED) assumes `endSeconds + halfRamp` non-decreasing.** Soft joins keep it: `end_i + h ≤ end_i + dur_{i+1}/2 < end_{i+1} ≤ end_{i+1} + halfRampOut_{i+1}`. Across short holes on HEAD it can already be violated (`end_i + 100 ms` vs `end_i + 1 ms + 60 ms + 30 ms`), so the search could skip a still-open tail ramp — a PRE-EXISTING latent issue (INFERRED, never observed), not introduced here; filed as a risk (4.j), not fixed in this lane because fixing it moves legacy bytes. INFERRED.
- **I4 — source-time widths.** Gates run in SOURCE seconds (:1436-1438). After C2-3 a compressed note plays its join faster; §4 does not compensate, C2-3 owns that (timing §3.10 item 7). The wire and UI state "ms of the original take".

### 4.b.5 Who writes the fields

- **Seed** (`PitchNoteTable.detected`, `ProjectStore+PitchNoteEdits.swift:520-537`): gains `transitionSlopeCentsPerSecond: Double = PitchEditSet.defaultTransitionSlope` and sets `glideFollow = 1` on `.transition` parts (it holds `part.kind` at that moment). Every NEW editor table is therefore soft. Identity until an offset moves (4.b.1).
- **Presets** (`PitchAutoCorrect.editSet`, :1905/:1917): UNCHANGED — slope 0, `glideFollow` 0. `PitchPresetRenderGateTests` stays byte-identical and the shipped MCP text "every preset stores a slide AS SUNG" (:1853-1857) stays true. The user's (a-T) pick is untouched and NOT re-asked.
- **Hand drag / split / transition drag on a LEGACY set**: governed by D4-1 (4.c), RULED (b) 2026-09-25 PDT: the first such edit that changes a note updates the whole vocal to natural tuning, in that edit's own undo step (an explicitly picked slope is kept); an edit that changes no note updates nothing.
- **Split** (`ProjectStore+PitchNoteEdits.swift:154-163`): the LEFT half's `transitionOutMs` resets to 0 (the new interior join has Δ = 0 and gets the auto width); the RIGHT half inherits the original rear width; both inherit `glideFollow`. The `PitchEditSet(` rebuild at :161 must carry `transitionSlopeCentsPerSecond`.
- **Transition drag** (UI) / `clip.setNoteTransition` (wire): writes the LEFT note's `transitionOutMs` (nil/0 = back to auto) and, on a soft set, nothing else.

### 4.b.6 Worked cases (INFERRED arithmetic, never rendered)

- **Regime 2, A +300 c, B untouched, sung link rising 200 c across ~100 ms:** Δ = 300 c, slope 3000 c/s ⇒ W = 100 ms, crossfade centred on the cut. Delivered = sung (+200) + correction (−300) ≈ a smooth −100 c fall over the link, instead of rise / drop 300 in one hop / rise. At the old 30 ms: the correction moves at ≈10000 c/s, 2.4× the take's fastest sung slide (4239 c/s, note-splitting design :1130).
- **Regime 3, A +300, slide T (200 ms, `glideFollow = 1`), B untouched:** T's constant ramps +300 → 0 over 200 ms (1500 c/s); A|T and T|B joins have Δ ≈ 0 ⇒ floor width. The slide starts at A's NEW pitch and lands on B, keeping its sung wiggle.
- **Moved note next to a 60 ms note:** `h ≤ 30 ms` ⇒ the cap cannot be honoured (≥ 5000 c/s at 300 c). Stated bound, gated with `max(cap, Δ/min(dur))` (4.g).

## 4.c Defaults, and why

- **Existing projects: byte-identical, render AND file.** All three fields decode to 0 when absent (= legacy) and are omitted at 0, so a legacy set re-saves byte-identically, its `contentStamp` is unchanged (no spurious "hand edits" confirm), its digest is unchanged (4.d), and `make` takes the legacy branch. No ABSENT key changes meaning — the saturator/clipper law ("a shipped kind may not change its tone") holds. INFERRED from the design; gated 4.g G-BYTE/G-FILE.
- **New editor tables:** `transitionSlopeCentsPerSecond = defaultTransitionSlope`, **provisional 3000 c/s, pending the listening round (4.h)**. Why 3000: it maps the user's rule of thumb onto one number — a 100 c move gets ≈33 ms (≈ today's floor: "1-2 st usually sounds natural" stays as it is), 300 c gets 100 ms (≈3 hops, the phase-0 point where the level dip fell from −5.11 to −1.20 dB, READ :158-159), 500 c gets 167 ms. It is below the take's fastest sung slides (2604 / 4239 c/s) and above its typical ones (511-768 c/s) (note-splitting design :1130-1134, READ), i.e. the added correction never outruns what this singer actually does. INFERRED rationale; the listening round decides.
- **New editor tables:** `glideFollow = 1` on every `.transition` part — a measurable default (a slide should land where its neighbours are), not taste; the user delegated measurable defaults. Presets keep 0 (4.b.5).
- **Explicit width default:** none (0 = auto). The UI and wire expose "Auto" as a state, not a number.
- ✅ **D4-1 — RULED (b), 2026-09-25 PDT (Q-U1): what happens when you hand-edit a note in an EXISTING or PRESET-tuned vocal?** (a) The vocal stays on the old transition rule; only newly opened vocals get smooth joins. Nothing you did not touch changes, but the robotic jump the MUST describes remains on every vocal tuned with a preset first. (b) **Recommended:** the first hand edit switches that vocal to smooth joins. The note you dragged gets the smooth join, and so does every other join inside a phrase where two notes differ by a lot or one note is very short (those also lose the small dip F12 describes). Joins you would not notice stay the same. It is one Undo step, and undoing it restores the old rule. (Q-U1 later recommended (a); the user picked (b).) Shipped as the one constant `PitchEditSet.handEditUpgradesLegacyVocal`, now `true`, and the update is X4's whole upgrade (voice size, consonants and slides), not the joins alone. The question was asked once, on the handoff page, and is not asked again. Preset-tuned sets also cannot TILT slides under either option (the kinds are gone after a preset rebuilds the table) until U-A's `origin` field lands (slot 6, unpitched design U2) — a stated gap, not a re-ask of (a-T).

  ✅ **RULED (b)** (Q-U1, the user's word, the evening of 2026-09-25 PDT, which is 2026-09-26 UTC, the date the code cites): `PitchEditSet.handEditUpgradesLegacyVocal = true`, so the first per-note hand edit that CHANGES a note on a vocal that `predatesNaturalTuning` updates the whole vocal (`afterHandEdit(from:)` → `upgradedToNaturalTuning()`) in that edit's own undo step. **An edit that changes no note updates nothing** (ruled 2026-09-27 on the user's words, "the first note you DRAG": switching the whole vocal is audible, so a no-op must have no side effect): Reset Wobble on a note already as sung, a Restore of a note that is not cleared, a drag released where it started. The vocal stays exactly as it was and no undo step is added. `PitchEditSet.afterHandEdit(from:)` is the ONE home of both rules; every hand-edit transform and store writer calls it (`NaturalTuningHandEditCensusTests`). **A never-edited table is not legacy:** `predatesNaturalTuning` needs `!isPitchIdentity`, and slide widths, follow and levels sit outside identity, so a width, follow or level edit on such a table leaves its set-level fields alone, while its first edit that bends a note (a pitch, Voice, wobble or drift change, or a drawn line) updates it in that same step. Intended in effect: a table that bends nothing has no old sound to keep.

## 4.d Render-cache key impact

- **Digest (`StretchCurvePlan.swift` `PitchEditSetDigest.hex`, :335-452, MEASURED):** a NEW marker-gated suffix block, **requested slot 7** (after origin, 6). ⚠️ §1's formant stale-key block also needs a slot; the integrator files BOTH slot numbers in the design doc's block-order table BEFORE any code, and the order is by slot number, never by landing order (the rule at :374-390).
  - Gate: `set.usesSoftJoins` (the ONE predicate). `hex` already returns `""` for identity sets (:336), so a seeded-but-unedited table emits nothing.
  - Content: `transitionMarker`, `transitionRenderVersion` (Int, bump when the join arithmetic changes), `transitionSlopeCentsPerSecond` bits, `segments.count`, then per segment `transitionOutMs` and `glideFollow` bits.
  - ⛔ The set-level slope goes INSIDE the block, never inline next to `retuneMs` (:357) — inline would re-key every tuned render on the machine (the cache already held 757 MB with no eviction, ROADMAP.md:1596, READ).
- **`StretchRenderCache` keys (`StretchRenderCache.swift:55-128, 392-429`, READ):** no change. The digest hex is already the pitch material; no new clip-level Params field, no `stretchEngineVersion` bump, `RenderTimeBase` untouched (pinned `StretchEngineTests.swift:961`).
- **`ClipRenderSignature` (`Sources/DAWAppKit/ClipRenderSignature.swift:116-132`, MEASURED):** no code change. `Tuning` compares the notes' BYTES (`bitIdentical`, so the two new Doubles are covered by the layout law) and `everythingButTheNotes` — the whole set with `segments` emptied — by `==`, so the set-level slope is covered IF `PitchEditSet`'s `Equatable` stays synthesized (INFERRED; a hand-written `==` would drop it). Pinned by G-SIG.

## 4.e Wire command + MCP tool (additive only; no rename, no changed default)

- **`clip.setNoteTransition`** — `{clipId, noteId, widthMs: number|null}`. `noteId` is the LEFT note of the join. `widthMs` null or 0 = Auto; otherwise clamped to 30...1000 and to the shorter of the two notes (the response echoes the width that APPLIES, and `effectiveWidthMs` computed through the same `make` — a setter's return is not proof it took). Refuses: unknown clip/note; a LAST note (no join to its right); a note whose right edge faces a hole ("these two notes are separated by a silence; there is no slide between them to shape") — never a silent success. One undo step, `ProjectStore.setNoteTransition(clipID:noteID:widthMs:)` in `ProjectStore+PitchNoteEdits.swift`, key `PitchCorrectionUndoKey` family. On a legacy set it follows D4-1.
- **`clip.setPitchTransitionSmoothness`** — `{clipId, centsPerSecond: number|null}` writes the set-level slope (null → the default; 0 is NOT accepted — going back to legacy is Undo's job, not a wire state). Also a new optional `transitionSlopeCentsPerSecond` on `clip.autoCorrectPitch` is deliberately NOT added: presets stay legacy (4.b.5).
- **`clip.setNoteGlideFollow`** — `{clipId, noteId, amount: 0...1}` so an agent can make a slide follow (or stop following) its neighbours, including on preset-built tables where the seed never marked it.
- **`clip.getPitchEdits`** echoes `transitionSlopeCentsPerSecond`, and per note `transitionOutMs`, `glideFollow`, plus a read-only `joinToNext: "soft"|"hole"|"last"` and `effectiveTransitionMs` so an agent can see what the auto rule chose (`Commands.swift:14274`, the existing echo).
- **MCP** (`mcp-server/src/server.ts`, near `clip_auto_correct_pitch` :8897-9036): `clip_set_note_transition`, `clip_set_pitch_transition_smoothness`, `clip_set_note_glide_follow`. Tool text for a novice: "Makes the slide from one note into the next smoother (wider) or sharper. Use after moving a note by 3 or more semitones if the jump sounds robotic." State the source-time axis and the clamp to the shorter note.
- **Counts move:** wire +3, MCP tools +3; `node scripts/gates/doc-count-drift.mjs` is the pin. ⛔ The new tools must ALSO be added by hand to the plugin agents' allowlists (`claude-plugin/agents/mix-engineer.md`, `claude-plugin/agents/composer.md` — both list `clip_set_note_pitch` today, MEASURED grep) and the wire reference `claude-plugin/skills/daw-wire-reference/SKILL.md`, or the regenerated bundle will not reach agents (memory law, 2026-09-21 release).

## 4.f UI (Glass Cockpit, `docs/DESIGN-LANGUAGE.md`; beginner labels)

- **What you see.** At every soft join the editor draws a thin vertical **seam** (hairline, `textFaint` ink — static chrome never glows, DESIGN-LANGUAGE.md:15). The played pitch line through the join is already drawn (`PitchPlayedLine.swift:357`); on hover the join's section of that line brightens in the pitch accent with the glow recipe (:15), so the eye sees the slide it is about to shape. Joins facing a hole draw no seam (nothing to shape).
- **Handle.** Hovering the rear 12 pt of a note or the seam shows a small pill handle on the seam, labelled on hover **"Slide: Auto"** / **"Slide: 120 ms"** (SF Mono for the number, DESIGN-LANGUAGE.md:8). Drag LEFT/RIGHT to widen or narrow the slide — the user's own words were "drag the separation line". Widening draws two faint guide ticks at the join's edges. Double-click = back to **Auto**. Snaps: 30 ms shows **"Sharp"**, the clamp shows **"Widest"**.
- **Tool palette:** no new tool. The handle is live in the existing **Move** tool (like Melodyne's Pitch Tool on the rear of a note). Router: a new press kind `.transitionDrag(leftNoteID)` in `PitchEditorGestureRouter.swift` (today noteDrag / band / cut / none, :44-101), hit-tested BEFORE `noteDrag` only inside the seam hot zone, so grabbing a note body is unchanged.
- **Live preview:** the drag writes a draft width into the draft table the same way a pitch drag does (`PitchEditorModel.swift:1884-1911`); the draft `PitchEditSet(` at :1902 must carry the slope and the widths or the drawn line lies.
- **Smoothness control.** One labelled control in the pitch editor's header: **"Slide smoothness: Natural ▾"** with the 3-4 listened options as named steps (4.h). **"Sharp" = the slope CEILING (20000 c/s ⇒ every soft join at the 30 ms floor, symmetric), never legacy** — the wire refuses 0, so the UI must not be able to write it either. On a LEGACY set (no editor seed, or a preset just rebuilt the table) the control shows **"Set by preset"** with the hint "Pick a smoothness to take over the slides from the preset"; it never shows a step the render is not using. Tooltip: "How gently a moved note glides into the next one. Stronger smoothing sounds more natural after big moves." This supersedes, for this one axis, the v1 exclusion of a free retune slider (UI design :1268): it is a NAMED step list, not a free slider.
- **Beginner hint:** after a drag of 3+ st next to a Sharp join, a one-time inline hint on the seam: "Big move — drag this line to smooth the slide."

## 4.g Physics and byte gates (each: + = positive control that must FAIL/READ the effect, − = negative control)

Headless, no `@MainActor` on suites; env-gated take harness spells `@MainActor` per test. Slopes on voice quoted as DELIVERED ÷ IDEAL (the IdealReading method, `WobbleOnsetListeningTests.swift:1-70`), never raw c/ms.

**DAWCore (curve arithmetic) — `Tests/DAWCoreTests/PitchTransitionTests.swift` (new):**
- **G-ID** fresh seeded table (slope > 0, `glideFollow = 1` on slides) ⇒ `isIdentity`, digest `""`, `Clip.hasPitchEdits == false`. + plant: count `glideFollow` in `isPitchIdentity` ⇒ test goes red. − a table with one +100 c offset is NOT identity.
- **G-SUM (I2)** soft join, A +300 / B 0, sweep t across the join: `Σgate == 1 ± 1e-12` and the curve is monotone between the two values. + plant: give the right side `h/2` ⇒ dip detected (the F12 shape). − legacy set with retune 200 and a 60 ms note still shows the F12 dip (documents that legacy is untouched).
- **G-TWO (I1/I3)** fuzz 10k random CHAINS OF SOFT JOINS (abutting, random durations ≥ 60 ms, random widths/offsets): never three gates > 1e-12 at any t, and `firstSpanIndex` agrees with a linear scan. + plant: clamp at `dur` instead of `dur/2` ⇒ a three-gate point found. − legacy tables: gate sums and curve values are BIT-IDENTICAL to a copy of HEAD's evaluator (NOT "legacy passes the two-gate rule" — it does not across short holes, and that test would be red for a pre-existing reason).
- **G-AUTO** Δ = 100/300/500 c at 3000 c/s ⇒ effective W = 33.3/100/166.7 ms (clamp permitting); explicit width overrides; width clamps to the shorter note. − Δ = 0 ⇒ W = `retuneMs`.
- **G-TILT** A +300, T (200 ms, follow 1), B 0: curve at T start ≈ +3 st, at T end ≈ 0, smoothstep midpoint +1.5 st; T's shaping term unchanged. + plant: `glideFollow = 0` ⇒ curve at T start ≈ 0 (today's snap-back, the regime-3 defect reproduced). + plant 2: a `(1−g)·own` blend ⇒ dragging T by +100 c leaves the curve unchanged (the inert-drag defect). − B moved instead: mirror image; T alone moved +100 c with 0 neighbours ⇒ a +1 st constant over T.
- **G-SPLIT** split a note with explicit width ⇒ left half 0 (auto), right half keeps it; slope survives the rebuild at `ProjectStore+PitchNoteEdits.swift:161`. + plant: drop the slope in the rebuild ⇒ red.
- **G-STAMP** a transition edit on a preset-stamped set ⇒ `hasHandEditsSinceAutoCorrect == true`. − an unedited preset set ⇒ false.

**Byte identity (qa-test-engineer lane):**
- **G-BYTE** every existing golden stays green untouched: vibrato §A goldens + their negative control (`NoteVibratoGeneratorTests.swift:98-206`), c21 digest/render goldens, I7a level block (`PitchCurveRenderTests.swift:1067`), edit-free key/render, tuned-then-cleared, nothing-to-bend, constant-curve, whole-file golden (`ClipSpanRenderTests.swift:1447-1605`), preset render gate (`PitchPresetRenderGateTests.swift:357`). + plant: make `make` always take the soft branch ⇒ at least one golden goes red (proves the goldens can see it).
- **G-FILE** decode→encode a legacy project JSON ⇒ identical bytes and identical `contentStamp`. + plant: encode `glideFollow` unconditionally ⇒ red. **Abutment survives a round-trip:** every join that abuts bit-for-bit in a seeded fixture still abuts after encode→decode (soft vs hole is Double bit-equality, so a JSON number formatting change would silently turn soft joins into holes). + plant: nudge one `startSeconds` by 1 ulp ⇒ that join reads `hole` and the test names it.
- **G-DIGEST** (a) digest of every legacy fixture unchanged; (b) changing ONLY slope, ONLY one `transitionOutMs`, ONLY one `glideFollow` each changes the digest; (c) the new **PitchEditSet set-level reflection census** (Mirror over `PitchEditSet` stored properties minus `segments`/`autoCorrectStamp`, each must move the digest) — the map's missing census; − the existing NoteSegment census (`PitchCurveRenderTests.swift:412-443`) stays green with the two new fields listed.
- **G-SIG** `ClipRenderSignature` treats a slope-only change as a change. − identical sets in fresh storage compare equal (`tailPaddingIsNeverCompared` pattern).

**Render physics on a sine (engine lane, `Tests/DAWEngineTests/NaturalTuningTransitionTests.swift`, new, reusing `OfflineStretcherCurveTests.swift:474-912` instruments):**
- **G-DIP** 220 Hz sine, one note moved 300 and 500 c, neighbour 0: level dip and >2 kHz energy at the join vs a constant render, for legacy 30 ms vs soft 3000 c/s. Assert soft dip < legacy dip. + the legacy render must show a dip (else the instrument is blind). − a Δ = 0 join shows no dip in either.
- **G-LAND** tracked pitch 60 ms past the join is within ±10 c of B's target; tracked pitch 60 ms before is within ±10 c of A's. − swapping sides mirrors.

**Render physics on VOICE (take harness, env-gated, NEW Dogfood folder `2026-09-25 natural-tuning/`, PREREG first):**
- **G-SLOPE** at every `L/parts.json` link/lead-in join where exactly one side is moved +300/+500 c: delivered ÷ ideal slope in [0.7, 1.3], max step per 30 ms hop ≤ `max(cap, Δ/min(dur))·0.03 s`. + plant: render legacy 30 ms ⇒ max step exceeds the bound. − an unedited render ⇒ steps ≈ the singer's own.
- **G-SHAPE** within a followed slide: residual (delivered − (sung + ideal correction)) SD ≤ the unedited render's residual × 1.5, and no direction reversal when sung and correction slopes agree in sign. + plant: `glideFollow = 0` ⇒ a reversal at the slide start. 
- **G-CLICK** >2 kHz energy windowed to voiced→voiced joins only, floor = SAME window of an unedited render (the E1 detector fires on every fricative, map risk). − hole joins are excluded and asserted unchanged (protects §2).
- Physics passes prove mechanism, not naturalness; m23-ap-5 stays open.

## 4.h Taste question for the user (ONE axis: slide smoothness at a 3+ st move)

Material: the user's own take (`dry-norm.wav`), ONE held note moved +400 c next to an unmoved neighbour across a sung link, same excerpt in all files, −21.5 LUFS pure gain, ≤ −1 dBTP measured on the decoded MP3s, P-L pipeline, PREREG written first. Everything identical except `transitionSlopeCentsPerSecond`:

| Option | Label shown | Slope | 400 c join width |
|---|---|---|---|
| A | "Sharp (today)" | rendered as legacy (30 ms floor); at 400 c between two long notes this equals soft-at-ceiling (both 30 ms, symmetric), so the file also stands for the UI's "Sharp" step | 30 ms |
| B | "Quick" | 6000 c/s | ≈67 ms |
| C | **"Natural" — recommended default** | 3000 c/s | ≈133 ms |
| D | "Gentle" | 1500 c/s | ≈267 ms |

Question, novice wording: "One note was moved up. Which version slides into the next note most like a real singer would?" Pre-registered physics must order the files: join width A < B < C < D measured on the render and dip A worst. DISTINCT bytes prove nothing — the ordering is the check. The pick becomes `defaultTransitionSlope`; the four labels become the header control's steps. Plus **D4-1** (4.c), a yes/no-style pick asked on the same handoff page.

## 4.i Files this lane touches (for disjoint-lane cutting)

- `Sources/DAWCore/PitchCorrection.swift` — two `NoteSegment` fields (before `isCleared`), init clamps, Codable keys, `hasTransitionEdits`; `PitchEditSet.transitionSlopeCentsPerSecond`, `defaultTransitionSlope`, `usesSoftJoins`, Codable; `Span` in/out halves + bridge; `make`; `gate`; `firstSpanIndex`; evaluator bridge branch. ⚠️ Shared with §1 (formant) and §3 (drift/vibrato) — integrator serialises edits to this file.
- `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift` — seed (slope + follow on slides), split rule, `setNoteTransition`, `setPitchTransitionSmoothness`, `setNoteGlideFollow`, D4-1 hook.
- `Sources/DAWCore/NotePitchDraft.swift` — draft carries widths.
- `Sources/DAWEngine/Stretch/StretchCurvePlan.swift` — slot-7 block, marker constant, `transitionRenderVersion`.
- `Sources/DAWControl/Commands.swift` — 3 verbs + `getPitchEdits` echo.
- `mcp-server/src/server.ts` — 3 tools; `claude-plugin/agents/mix-engineer.md`, `claude-plugin/agents/composer.md`, `claude-plugin/skills/daw-wire-reference/SKILL.md` — hand-maintained lists.
- `Sources/DAWAppKit/PitchEditorModel.swift` (draft set at :1902, seam geometry, handle state), `Sources/DAWAppKit/PitchEditorGestureRouter.swift` (`.transitionDrag`), the pitch editor view in `Sources/DAWApp/` (seam, handle, header control).
- Tests (new files only): `Tests/DAWCoreTests/PitchTransitionTests.swift`, `Tests/DAWEngineTests/NaturalTuningTransitionTests.swift`, digest/census additions in a NEW `Tests/DAWEngineTests/TransitionDigestTests.swift` (not editing the uncommitted `StretchEngineTests.swift`), wire tests in `Tests/DAWControlTests/`, MCP tests in `mcp-server/`.
- Docs: `docs/design/2026-09-25-natural-tuning.md` §4 + the block-order table; `docs/ARCHITECTURE.md` "Key future decisions" (soft joins on the LEFT note, slope-based auto width); `docs/ROADMAP.md` m23-nt checkboxes.
- Nothing needs full Xcode; nothing touches the audio thread (the curve is offline, `PitchCorrection.swift:123-125`, READ). Routes: DAWCore + digest `audio-dsp-engineer`; wire/MCP `mcp-integration-engineer`; UI `swift-app-engineer`; gates `qa-test-engineer`.

## 4.j Alternatives rejected, and risks

**Alternatives.**
- *Widen the set-level `retuneMs` default for new tables (e.g. 110 ms).* Loses: one width for every join, so small moves get sluggish and big ones may still be too fast; no per-join shaping; the slide still snaps back in regime 3; F12 grows with a wider retune.
- *Per-join width stored on BOTH notes, or in a separate join table keyed by note-ID pairs.* Loses: two homes for one fact (a split or delete desynchronises them); a side table has no byte-layout pin and no reflection census; the left-note home matches Melodyne's "rear of the note" and survives split with one rule.
- *Turn `.transition` parts into bridges under the presets.* Loses: changes Natural/Tight/Hard Tune on every split run, breaks the preset byte gate and the shipped "slide AS SUNG" text, and re-litigates the user's (a-T) pick.

**Risks.**
- **Dropped set-level field** at the six `PitchEditSet(` construction sites (4.a): split and the draft line would silently revert to legacy. Mitigation: route both through a copy (`var s = table; s.segments = …`) instead of the memberwise init; G-SPLIT plants it.
- **Slot collision with §1's formant block** — both need a suffix slot. File both in the design doc's order table before either lands (4.d).
- **Consonant spill.** A wider soft join inside a run is still voiced-to-voiced, but a voiced consonant (m, n, l, z) inside a run gets the wider ramp. §2's gates must include the soft-join widths in their "distance to moved edge" statistic.
- **Stale premise in the timing lane.** Timing §3.6 says "detected notes never abut" (timing doc :733-737); p2-seg made them abut, and this design's "soft join" IS abutment. C2's connected-pair rule and C-F4 must adopt this section's definition (abut bit-for-bit = soft join; hole = hard) before either lands, or C2 will treat every splitter join as a user-made connection. The Melodyne Separation-Type toggle is NOT built here (C-F4 stays filed): "Sharp" (30 ms) is the hard-separation equivalent in a delta model.
- **Short-neighbour cap.** Next to a 60 ms note the join cannot be wider than 60 ms, so the slope cap is not honoured there (4.b.6). Stated bound, gated; widening further would open a third gate (I1).
- **Wider is not free.** Phase-0 recorded +2.3 dB broadband at 3 hops (READ :213); never listened to. The listening round (4.h) and G-DIP's energy leg measure it.
- **D4-1 RULED (b) ⇒ the MUST is fixed on a preset-first vocal at its first hand edit that changes a note** (the whole vocal updates, one undo step). Until that edit, or the one-tap "Update", such a vocal keeps the old rule; say so in the release note.
- **Explicit slope on a legacy set** via `clip.setPitchTransitionSmoothness` IS an explicit request and upgrades that set regardless of D4-1 (one undo step); the tool text says so.
- **Retiming (C2-3)** will shorten soft joins in edited time (I4). C2-3's measurement must include soft-join widths.
- **Pre-existing, found while proving I1/I3:** across short holes with a long legacy retune, three gates can open (normalised, trims the middle note) and `firstSpanIndex`'s monotonicity can break (INFERRED, never observed). Not introduced and not fixed here (a fix moves legacy bytes); file as its own roadmap item with a known-answer test.
  - ⚠️ **MEASURED and FIXED 2026-09-25 (p2-span).** The monotonicity break is real, and it is not limited to short holes: a long note abutting a very short one breaks it. The skipped contribution measured **41.04 c per 100 c of move, for 220 ms**, and the scan's early exit (`start − halfRamp`) had the same defect at the same size. Both evaluator loops now search a precomputed prefix-maximum of reach and exit on a suffix-minimum of opening. G-TWO (`PitchSpanSearchTests`) matches a linear scan bit for bit, and `transposeEngineVersion` is 3 (and 4 since p2-acc-3's vendored patches 0002/0003, the same day).


---

## Cross-section consistency

Status: written by the integrator (daw-architect) after reading all four sections and re-checking the source on
2026-09-25. **Where this section and a section body disagree, THIS SECTION WINS.** Labels: MEASURED (I ran it this
session), READ (seen in source), INFERRED.

### X1. Digest suffix slots: 7 formant, 8 consonant, 9 transition. §3 takes none.

§1 requests slot 7 (§1 1(d)) and so does §4 ("requested slot 7", §4 digest bullet). The banner in
`Sources/DAWEngine/Stretch/StretchCurvePlan.swift:374-390` (MEASURED, read this session) fixes slots 1-6:
1 generator (written), 2 anchor (reserved), 3 time warp (written), 4 shape (reserved), 5 level (written),
6 origin (reserved, U-A). The rule at :384-389 is "order by slot, never by landing order". Ruling:

| Slot | Block | Owner | Gate that emits it |
|---|---|---|---|
| 7 | formant (`formantSuffixMarker`, `formantRenderVersion`, correction) | §1 | `set.engagesFormantCurve` |
| 8 | consonant (`consonantSuffixMarker`, `consonantMaskVersion`) | §2 | `keepsConsonantsUntuned == true` |
| 9 | transition (`transitionMarker`, `transitionRenderVersion`, slope, per-segment width + follow) | §4 | slope != 0 or any `transitionOutMs`/`glideFollow` != 0 |
| — | drift/wobble separator v2 | §3 | NOT a digest block: `shaping:` renderKey version (below) |

§4's text saying "slot 7" is superseded: **§4 is slot 9.** The first lane that edits the banner writes all three
rows (7, 8, 9) into it at once, including the two not yet written, exactly as slots 2/4/6 are reserved today. Gate:
a digest census test (§4 proposed one) fails if a set-level field of `PitchEditSet` is neither hashed nor on an
explicit exemption list; it lives in `NaturalTuningDigestTests.swift` (lane NT-E1, which edits the banner) and must be red when a field
is added unhashed (plant).

§3's key: `StretchRenderCache.swift:427` today appends `shaping:\(PitchRenderContour.shapingVersion)` (MEASURED).
§3 changes it to a per-set version (1 unless some note has unequal scales, then 2). That is a renderKey change, not a
digest change, and it is compatible with slots 7-9. INFERRED: no interaction with the three blocks.

### X2. Where new sets are seeded, and where sets are rebuilt (census, MEASURED)

Method: `rtk proxy grep -rn 'PitchEditSet(' Sources/` (positive control: 29 lines mention `PitchEditSet` in
`PitchCorrection.swift` alone, so the command shape returns hits). Six constructor calls in `Sources/`:

| Site | Kind | What the new fields must do |
|---|---|---|
| `Sources/DAWCore/PitchCorrection.swift:874` `PitchEditSet.empty` | identity constant | stay legacy (nil / false / 0) |
| `Sources/DAWCore/PitchCorrection.swift:1905`, `:1917` (`PitchAutoCorrect.editSet`) | **SEED** (auto-correct and every preset) | per-field policy, X3 |
| `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift:534` (`PitchNoteTable.detected`) | **SEED** (the editor's table) | per-field policy, X3 |
| `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift:161` (split) | REBUILD | copy every set-level field |
| `Sources/DAWAppKit/PitchEditorModel.swift:1902` (draft played line, I4) | REBUILD | copy every set-level field |

**Two section claims are corrected by this census:**

- **§1 is wrong about the seed (MEASURED).** §1 says `PitchAutoCorrect.editSet` "is the constructor for both
  auto-correct and the editor's detected table". It is not: `PitchNoteTable.detected`
  (`ProjectStore+PitchNoteEdits.swift:519-537`) calls `PitchEditSet(` directly at :534. Under §1 as written, a table
  the editor seeds would decode `formantCorrection = nil`, take the legacy path, and the MUST would stay unfixed exactly
  where the user works. **Ruling: both seeds get `newSetFormantCorrection`.**
- **§2 misnames a rebuild as a seed (MEASURED).** `PitchEditorModel.swift:1902` builds the DRAFT line during a drag
  (the I4 comment above it). Seeding a flag there would draw a line with protection the stored table may lack.
  **Ruling: :1902 COPIES from `noteTable`; it never seeds.**

**The rebuild hazard is solved once, not four times.** §1 proposed a new `init` parameter with no default so the
compiler finds every site. That also breaks every test call: `rtk proxy grep -rn 'PitchEditSet(' Tests/` returns
181 lines in 40 files (MEASURED), including `StretchEngineTests.swift`, `ProvisionalRenderTests.swift` and
`EngineNoticeEngineTests.swift`, which the running p2-ren lane owns. **Ruling:**

1. The existing memberwise `init` keeps its signature. Every new field gets a default equal to its LEGACY value
   (nil / false / 0), so every existing test golden and fixture stays byte-identical (§2 wanted exactly this).
2. A new `PitchEditSet.withSegments(_ segments: [NoteSegment]) -> PitchEditSet` copies ALL set-level fields.
   Both rebuild sites (:161, `PitchEditorModel.swift:1902`) use it, and so does every future rebuild.
3. A new `PitchEditSet.seeded(analysisVersion:segments:retuneMs:origin:)` applies the X3 policy. Both seeds use it.
4. Gate (replaces §1's compiler census and merges §1 G9 with §2 G-C8): a DAWCore test that sets EVERY new
   set-level field to a non-legacy value, runs each writer (split, draft line, note move, level, vibrato,
   transition, formant, consonant setters), and asserts each field survives. Plant: a `withSegments` that drops one
   field must turn it red. A census test holds its OWN hard-coded list of stored-property names and asserts that
   `Mirror(reflecting: PitchEditSet.empty).children` names exactly that list; the carry test above covers every name
   on the list. A new field therefore turns the census red until BOTH the list and `withSegments` are updated (a test
   cannot read a function body, so "compare against the copy list" would pass by construction).

### X3. Per-field seed policy (the differences are deliberate: do NOT "unify" them)

| Field | Legacy (absent) | `PitchNoteTable.detected` (editor seed) | `PitchAutoCorrect.editSet` (auto-correct, presets) | Why |
|---|---|---|---|---|
| `formantCorrection` (§1) | nil | `newSetFormantCorrection` (1.0 provisional) | `newSetFormantCorrection` | chipmunking is a defect on every path |
| `keepsConsonantsUntuned` (§2) | false | true | true | the MUST: consonants never move |
| `transitionSlopeCentsPerSecond` (§4) | 0 | `defaultTransitionSlope` (3000 provisional) | **`defaultTransitionSlope` (R14 overrides the earlier 0)** | (a-T) governs slide identity, not join width (R14) |
| `glideFollow` on `.transition` parts (§4) | 0 | 1 | **0** | same (a-T) reason; presets no longer know part kinds |
| drift/wobble scales (§3) | unchanged | unchanged (equal, 1.0) | unchanged (equal) | §3 adds no field |

Consequence (revised by R14): a preset-tuned vocal built after the update gets voice, consonants AND soft joins;
only its slide parts stay as sung (`glideFollow` 0). Release note states that new preset renders differ from old ones
at large-move and short-note joins.

### X4. Upgrading an EXISTING vocal: ONE rule, ONE question

The sections recommend three different things: §1 "never automatic, one tap" (and optional D-F2, "re-running
auto-correct adopts the new default: yes"); §2 Q1 "turn it on for already-tuned vocals? no"; §4 D4-1 "the first hand
edit switches the vocal to smooth joins: yes". The discriminating fact is in §1's own G2b: at correction 1.0 the
formant path runs on almost every corrected note, so an automatic switch changes far more of the sound than §4's
joins alone. **Ruling (Q-U1 answered (b), 2026-09-25 PDT):**

- ONE store action `upgradeToNaturalTuning(clipID:)` sets all three set-level fields to their seed values
  (formant, consonants, slope) as ONE undo step. It is the only upgrade path. §1's one-tap note, §2's toggle-on and
  §4's D4-1 hook all call it. Wire: `clip.upgradeNaturalTuning` (X10); the three set-level verbs also remain for agents.
  - ✅ **Amended 2026-09-27 (NT-C2-F1, W7-D2): a set-level pick somebody MADE is kept.** The slope already was (C4's
    ruling: filled only when legacy). Now a consonant OFF somebody chose (`.offByChoice`, written only by
    `setClipConsonantProtection(enabled:false)`) is kept too, through the tap AND through D4-1's first changing hand
    edit (`upgradedToNaturalTuning()` in `PitchCorrection.swift`). Only an OFF nobody chose is switched on. No vocal
    that could be updated before 2026-09-27 updates differently, because no chosen OFF could be stored before then.
- The explicit tap stays: the pitch editor shows one dim line on a vocal where `predatesNaturalTuning` holds (R16):
  "Tuned before this update. Tap to update." (R26, 40 characters). Per Q-U1 = (b), the first hand edit that changes
  a note ALSO updates the vocal, in that edit's own undo step (`afterHandEdit(from:)`, through the same pure
  `upgradedToNaturalTuning()`); an edit that changes no note updates nothing. Nothing else changes an existing vocal
  on its own.
- Re-running auto-correct builds a new set, so it gets the new seeds. That answers D-F2 as "yes" by construction; it
  is still listed for the user because it changes a sound they have heard.
- §4's "an explicit `clip.setPitchTransitionSmoothness` on a legacy set upgrades that field" stands (explicit request).

### X5. `StretchRenderCache.swift` is owned by p2-ren too (MEASURED)

The task's list of p2-ren files omits it, but `rtk proxy git status --short Sources/DAWEngine/Stretch/` shows
`M StretchRenderCache.swift` and untracked `ProvisionalRenderStore.swift` alongside `ProvisionalRender.swift` and
`RenderDiff.swift`. §2 (consonant mix in `renderAudio`, :798) and §3 (`shaping:` at :427) both edit it. **Treat
`StretchRenderCache.swift` and `ProvisionalRenderStore.swift` as p2-ren files until p2-ren Stage B has landed with its
tests green (R17; a git commit is NOT required).**

### X6. `RenderDiff`: ONE patch, ONE owner

`RenderDiff.swift` (MEASURED, read this session) compares (1) the transpose as the `Float` handed to the stretcher,
chunk by chunk, and (2) the level mask frame by frame (it runs `applyLevelMask` on a buffer of ones, :259). It
refuses when `formantPreserve` differs (:154) or runs across loops with formant preservation (:161). So:

- §1 (a per-hop formant curve and f0 hint) and §2 (a per-frame crossfade to source) change audio that RenderDiff does
  not compare. Without a patch the provisional splice can play stale audio after a formant-only or
  consonant-only edit. **Both patches are written by the p2-ren owner as ONE change** (compare formant and base-hz per
  chunk, refuse when one side engages the formant curve and the other does not; compute consonant weights like the
  level mask and union their differing frames into the extent).
- §3 and §4 change only the transpose curve, which RenderDiff already compares chunk by chunk. INFERRED, and gated:
  the engine lane adds one RenderDiff test per section (a vibrato-scale-only edit and a transition-width-only edit
  each yield a non-empty extent; plant: an edit on a note far away yields an extent that does not cover it).

### X7. The formant blend follows §4's join widths

§1's formant curve reuses the pitch curve's gates; §4 widens those gates at soft joins. On a set that engages both,
the formant crossfade must track the transition width, or depth snaps while pitch glides. Ruling: §1's evaluator
calls the SAME span/gate function §4 modifies (no private copy). Gate (engine lane, after both land): a moved note
meeting an unmoved one at a soft join of width W; the measured envelope shift must cross 50 % within ±1 hop of the
pitch curve's 50 % point. Plant: a formant evaluator with a hard-coded `retuneMs` gate must fail it. Slot 9 keys it.

### X8. §2 and §4 act on disjoint places (INFERRED from both texts; gated)

> **Revised by R15:** disjointness now comes from ONE predicate, `joinKind`: gaps ≥ `consonantMinimumGapSeconds` are
> §2's, shorter holes are §4 soft joins. The gate below is replaced by R15's two-way planted gate.

§2 mixes the source back in only inside GAPS between notes (and leaves gaps shorter than its minimum tuned). §4 acts
only at SOFT joins, where two notes share an edge bit for bit, so there is no gap; a join facing a silence keeps
today's ramp. So the two never touch the same frame, except that §2's fade sits on the gap side of a hole edge where
§4 keeps today's ramp. That is consistent: the ramp shapes the tuned signal, and the fade then hands over to source.
Gate (engine lane, after both): one phrase with a soft join and a hole; the soft-join frames are byte-identical with
§2 on and off, and the gap frames are byte-identical with §4's slope at 0 and at 3000. Plant: a mask that also fades
at soft joins must fail the first half.

### X9. Pitch-editor UI: one header group, and "Natural" is not a control label

Three sections each add a header control (§1 slider "Keep voice natural", §2 toggle "Natural consonants", §4 step
list "Slide smoothness"), and "Natural" is already a preset name (Gentle / Natural / Tight, READ
`Sources/DAWCore/PitchCorrection.swift:1878`) and §4's listening option C. Four meanings of one word will confuse a
novice. **Ruling:** one header group titled **"Sound like the singer"**, three rows, no row uses the word "Natural":

| Row | Control | Source section | Novice line |
|---|---|---|---|
| Keep voice size (R26) | slider 0-100 %, dim + upgrade line on legacy | §1 | "Keeps the voice its own size when notes move." |
| Consonants | on/off | §2 | "S, T and breaths keep their own pitch." (§2's line, kept) |
| Slides | Snappy / Quick / Smooth / Slow (R26) | §4 | "How gently a moved note slides into the next." |

§4's listening option C is renamed "Smooth" to match. The final wording is the ui-design-engineer's under
`docs/DESIGN-LANGUAGE.md`; the constraint (one group, no "Natural") is fixed here.

Palette: `PitchEditorTool` has TWO cases today, `pointer` and `scissors` (READ `PitchEditorModel.swift:1113-1117`).
C5a adds Wobble, §3 adds Drift (after Wobble), §1 adds Voice. Each addition edits the same `CaseIterable` enum and
its `symbolName` switch, so they are sequenced (Delivery plan, UI lane). §4's join drag is NOT a tool: it is a
`.transitionDrag` press kind in the Move (pointer) tool, as §4 says.

### X10. Wire and MCP: the verb list, one owner

All verbs are additive; none renames a live command. Final list (8 verbs, 8 tools):

| Verb | MCP tool | Section |
|---|---|---|
| `clip.setNoteFormant` | `clip_set_note_formant` | §1 |
| `clip.setFormantCorrection` (null = legacy) | `clip_set_formant_correction` | §1 |
| `clip.setConsonantProtection` | `clip_set_consonant_protection` | §2 |
| `clip.setNoteVibratos` (batch) | `clip_set_note_vibratos` | §3 |
| `clip.setNoteTransition` | `clip_set_note_transition` | §4 |
| `clip.setPitchTransitionSmoothness` | `clip_set_pitch_transition_smoothness` | §4 |
| `clip.setNoteGlideFollow` | `clip_set_note_glide_follow` | §4 |
| `clip.upgradeNaturalTuning` | `clip_upgrade_natural_tuning` | X4 (the one-tap upgrade is user-facing, so it needs a verb) |

The upgrade verb ships regardless of Q-U1, because Q-U1 only decides whether the UI OFFERS the upgrade or DOES it on
the first hand edit. `clip.getPitchEdits` gains
every new field in one change: `formantCorrection`, per-note `formantOffsetSemitones`, `keepConsonantsUntuned`,
`consonantProtection {active, inactiveReason}`, per-note `transitionOutMs`/`glideFollow`, the applied join width and
join kind, `tooShortToSeparate`, and `predatesNaturalTuning: bool` (R16). `clip.autoCorrectPitch` gains §2's optional key.
Every new tool is added BY HAND to the plugin agents' allowlists and `claude-plugin/skills/daw-wire-reference/SKILL.md`
(§4 found this for its tools; it applies to all eight). Counts: the last measured wire count was 244 and MCP tools 249
(memory baseline, 2026-09-25 11:26, NOT re-measured here: INFERRED); +8 each is expected. The lane re-measures with
`node scripts/gates/doc-count-drift.mjs`, never `grep -c 'registerTool('`.

### X11. Shared test files and the hard stop gates

- `Tests/DAWEngineTests/NaturalTuningTakeHarnessTests.swift` is named by §1 and §3. **One owner: the gates-first lane
  creates it** with one `@Suite` per section; later lanes add cases only inside their own suite.
- `SourceFilterVoice.swift` and `SpectralEnvelopeMeter.swift` (§1) are shared fixtures for §1, §2 (the 's' gate) and
  §4 (dip and landing). The gates-first lane owns them.
- **Hard stop gates become lane dependencies, not footnotes:** §2 M-1, as rescoped by R2 (a lag in a clean-history
  gap pauses C2 pending a re-reviewed compensation; it never stops the design), gates the consonant engine work; §3 G3 (separator physics) gates the Drift tool's UI and the Wobble/drift decoupling
  (if G3 fails, §3's fallback applies: Drift ships to agents only). §1 G4 (formant latency equals transpose latency)
  gates the formant engine merge.

### X12. §3 and §4 on sung slides (INFERRED, gated)

§4 makes a `.transition` part follow its neighbours (`glideFollow`) and passes its own drift and vibrato through.
§3's Drift tool edits a note's `driftScale`. On a slide part, lowering drift would flatten the slide itself. Ruling:
the Drift and Wobble tools act on slide parts like any note (no special case), but the UI selection for a group
Drift edit skips parts with `glideFollow == 1` unless the user clicks one directly. Gate (UI lane): a group Drift edit
over a phrase leaves the slide's `driftScale` unchanged. Plant: selection that includes slides must fail it.

## Delivery plan

Lanes own DISJOINT file sets. A file appears in exactly one lane; where two lanes would need it, one lane owns it and
the other waits (a "file token"). All work lands in the shared tree, uncommitted, until the user says commit.

**Files held by the running p2-ren lane (never edited by any NT lane until p2-ren Stage B has landed, tests green,
uncommitted is fine — R17):**
`Sources/DAWEngine/AudioEngine.swift`, `Sources/DAWEngine/PlaybackGraph.swift`,
`Sources/DAWEngine/Stretch/StretchRenderCache.swift` (X5), `Sources/DAWEngine/Stretch/RenderDiff.swift`,
`Sources/DAWEngine/Stretch/ProvisionalRender.swift`, `Sources/DAWEngine/Stretch/ProvisionalRenderStore.swift`,
`Tests/DAWEngineTests/StretchEngineTests.swift`, `Tests/DAWEngineTests/ProvisionalRenderTests.swift`,
`Tests/DAWEngineTests/EngineNoticeEngineTests.swift` (MEASURED via `rtk proxy git status`, 2026-09-25).
No NT lane changes the `PitchEditSet` init signature (X2), so none of the 181 existing test call sites, including
p2-ren's, needs an edit.

### Lane table

| Lane | Route | Owns (only these files) | Depends on | Can start |
|---|---|---|---|---|
| **NT-G** gates first | qa-test-engineer | NEW: `Tests/DAWEngineTests/Support/SourceFilterVoice.swift`, `Tests/DAWEngineTests/SpectralEnvelopeMeter.swift`, `Tests/DAWEngineTests/ConsonantSpectrumMeter.swift` (§2's meter), `Tests/DAWEngineTests/NaturalTuningTakeHarnessTests.swift`, `Tests/DAWEngineTests/NaturalTuningBaselineTests.swift` | nothing | now (writing); running waits for the timing lock |
| **NT-C** DAWCore, serial | audio-dsp-engineer | `Sources/DAWCore/PitchCorrection.swift`, `Sources/DAWCore/ProjectStore+PitchNoteEdits.swift`, `Sources/DAWCore/ProjectStore.swift` (auto-correct carry only), `Sources/DAWCore/NotePitchDraft.swift`, NEW `Sources/DAWCore/PitchConsonantMask.swift`, `Tests/DAWEngineTests/PitchCurveRenderTests.swift` (the `covered` list only, in C0, R28); NEW tests `Tests/DAWCoreTests/{NaturalTuningFieldCarryTests,FormantCorrectionModelTests,PitchConsonantMaskTests,PitchSeparatorV2Tests,PitchTransitionTests}.swift` | the DAWCore file token (shared with U-A and C5a, below) | now, sub-step C0 |
| **NT-E1** engine, non-p2-ren files | audio-dsp-engineer | `Sources/CSignalsmithStretch/shim.cpp`, `Sources/CSignalsmithStretch/include/csignalsmith_stretch.h`, `Sources/DAWEngine/Stretch/OfflineStretcher.swift`, `Sources/DAWEngine/Stretch/StretchCurvePlan.swift`; NEW tests `Tests/DAWEngineTests/{NaturalTuningDigestTests,NaturalTuningFormantRenderTests,NaturalTuningTransitionRenderTests}.swift` | NT-C C0 (fields), C1 (formant), C4 (transitions); NT-G fixtures | after NT-C C0 |
| **NT-E2** engine, p2-ren files | audio-dsp-engineer (the p2-ren owner, or its successor once p2-ren Stage B lands) | `Sources/DAWEngine/Stretch/StretchRenderCache.swift` (consonant mix call, `shaping:` version), `Sources/DAWEngine/Stretch/RenderDiff.swift` (X6, ONE patch); NEW tests `Tests/DAWEngineTests/{NaturalTuningConsonantRenderTests,ShapingKeyVersionTests,NaturalTuningRenderDiffTests}.swift` | **p2-ren Stage B landed, tests green (R17)**; NT-C C2 + C3; §2 M-1 passed (R2) | when p2-ren hands over the token |
| **NT-W** wire + MCP | mcp-integration-engineer | `Sources/DAWControl/Commands.swift`, `mcp-server/src/server.ts`, `mcp-server/test/pitch-correction.test.ts` + a NEW `mcp-server/test/natural-tuning.test.ts`, `claude-plugin/agents/*.md` allowlists, `claude-plugin/skills/daw-wire-reference/SKILL.md`, the GENERATED `claude-plugin/server/index.mjs` (regen only, R31); NEW `Tests/DAWControlTests/NaturalTuningCommandTests.swift` | NT-C store setters for each verb | per verb, after its setter |
| **NT-U** pitch-editor UI | swift-app-engineer (logic) + ui-design-engineer (header group, seam, tool looks) | `Sources/DAWAppKit/PitchEditorModel.swift`, `Sources/DAWAppKit/PitchEditorGestureRouter.swift`, `Sources/DAWAppKit/PitchEditorNoteMenu.swift`, NEW `Sources/DAWAppKit/PitchEditorFormantCopy.swift`, `Sources/DAWApp/PitchEditor/PitchEditorView.swift`, `Sources/DAWApp/PitchCorrectionStaging.swift`; NEW `Tests/DAWAppKitTests/{PitchEditorNaturalTuningTests,PitchEditorDriftToolTests}.swift` | the pitch-editor file token (shared with I2, I5, I6b, U-A/U-B, C5a, C5b); NT-C; NT-E2 for formant/consonant controls (X6); NT-U2 also needs the R12 edge spec landed in the timing design (NT-D) | after the queued item holding the token |
| **NT-L** listening | qa-test-engineer, page by the orchestrator | NEW `Tests/DAWEngineTests/NaturalTuningListeningTests.swift` (env-gated); renders go to the session scratchpad | NT-E1/E2 for that feature | per feature |
| **NT-D** docs | docs-scribe | `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`, `CHANGELOG.md`, the three amended designs: `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` (C5a §5.2/§5.3, per §3), `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` (per §2), `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` ("detected notes never abut" → the soft/silence definition, per §4; AND the R12 shared note-edge spec, before NT-U2) | each feature's close; R12 before NT-U2 | at each close; R12 now |

Name notes: the per-section test files proposed in §1-§4 are consolidated into the names above so no two lanes
create the same file. §1's additions to `PitchCurveRenderTests.swift` go into `NaturalTuningDigestTests.swift`
instead (a NEW file, as §1 already allowed). §2's `ClipRenderSignature.swift` "test only" edit is a test in
`NaturalTuningDigestTests.swift`; no lane edits `ClipRenderSignature.swift`.

### Order inside the serial lanes

**NT-G (starts now).** Writes only tests that COMPILE AGAINST TODAY'S API (one test target compiles every file, so a
test naming a field that does not exist yet breaks the whole suite for every lane). Contents: the two fixtures; the
red-on-today baselines, each recorded as a number, not an assertion that must pass: §1 G5 (a per-note
`formantOffsetSemitones` does nothing today), §2's 's' gate G-C3 (the 's' moves with the vowel today), §3 G0 (today's
separator leak on the product path, which becomes G3's negative control), §4's F12 dip at a soft join; the §2
measurements M-1 (lag), M-2 (edge placement), M-3 (gap histogram). Tests that need the new API are written by the
lane that adds the API. Running any of it waits for the timing lock to be released.

**NT-C (DAWCore), one sub-step at a time, each with its own tests green before the next:**
- **C0 fields.** All set-level and per-note fields from §1, §2, §4 at once (legacy defaults in the memberwise init,
  Codable absent-decodes-legacy, encode-omit rules per section), `withSegments`, `seeded`, the X3 policy at the two
  seeds, the DAWCore rebuild site (`ProjectStore+PitchNoteEdits.swift:161`) switched to `withSegments`,
  `upgradeToNaturalTuning`, and the X2 carry + census gate over DAWCore writers. C0 does NOT edit
  `PitchEditorModel.swift:1902` (a UI-token file): switching that draft-line rebuild to `withSegments`, with its own
  AppKit carry test, is **NT-U's first edit, and must land before C4** (after C4 a dropped slope would make the line
  drawn during a drag differ from what plays).
- **C1 formant evaluator** (§1: `formantSemitones`, `formantBaseHz`, `engagesFormantCurve`, setters).
- **C2 consonant mask** (§2: `PitchConsonantMask.swift`, setter, R15's shared `joinKind`). **Gated by §2 M-1 as
  rescoped in R2**: only a non-zero lag in a clean-history, high-ρ gap pauses C2, and then R2's fallback is re-reviewed.
- **C3 separator v2** (§3: the two-branch separator; equal-scale path bit-identical). Its group setter
  `setClipNotesVibrato` needs `NoteVibratoLimits.swift`, which is C5a-2's NEW file: **the setter lands in C5a's lane
  or after C5a-2**, never by NT-C creating that file.
- **C4 transitions** (§4: soft joins, auto width, `glideFollow`, the three setters, D4-1 hook wired to X4).

**The DAWCore file token.** U-A (the `origin` field, digest slot 6) and C5a (vibrato setters) also edit
`PitchCorrection.swift` and `ProjectStore+PitchNoteEdits.swift`. One lane holds these two files at a time; it
releases the token at a sub-step boundary with its tests green. Digest slot order (X1) makes the landing order
irrelevant to the keys. Recommended: NT-C C0 takes the token first (small, additive, unblocks NT-E1 and NT-W), then
U-A's core step, then NT-C C1…C4 and C5a's core steps interleaved by the survey.

**NT-E1 then NT-E2.** NT-E1: digest blocks 7/8/9 plus the banner (X1), the formant closures and shim setters (§1),
the transition gates in the curve (§4), the X7 formant-follows-join gate. §1 G4 (latency) gates the formant
closures. NT-E2 waits for p2-ren: consonant mix in `renderAudio`, the `shaping:` per-set version (§3), the ONE
RenderDiff patch (X6), the X8 disjointness gate.

### Sequencing with the six queued pitch-editor items (the pitch-editor file token)

A read-only survey is already scheduling I2, I5, I6b, U-A/U-B, C5a and C5b into lanes (ROADMAP.md:1864, READ). NT-U
joins that schedule; this design does not invent its order. The hard constraints:

1. `PitchEditorModel.swift`, `PitchEditorGestureRouter.swift` and `PitchEditorView.swift` are held by ONE lane at a
   time (all six queued items and NT-U touch them).
2. **Drift tool (§3) after C5a** (it is C5a-5, beside Wobble) **and after §3 G3 passes**. If G3 fails, no Drift UI.
3. The palette enum (`PitchEditorTool`, `PitchEditorModel.swift:1113`) gains Wobble (C5a), Drift, Voice; each is one
   case in one lane, in that order.
4. **No formant or consonant control reaches the UI or the wire before NT-E2's RenderDiff patch** (X6): otherwise the
   provisional splice can play stale audio after that edit. The transition controls may go earlier (INFERRED, X6).
5. C5b (freehand) never writes the drift/wobble scales (§3); no dependency either way. I2/I5/I6b are viewport and
   playhead work with no NT dependency; they only share the token.
6. Recommended NT-U order: U1 the header group (X9) + the legacy upgrade line; U2 the rear-edge join drag (R12, after NT-D lands the shared edge spec in the timing design); U3 the
   Voice tool (§1); U4 the Drift tool (§3). Because the user marked this a MUST, the orchestrator should give NT-U1
   the token right after whichever queued item holds it when NT-E2 lands.

### Standing constraints every lane is briefed on

Commits only on the user's word; control port 17600 is the user's live app (staging only on its own port,
pidfile-exact kill); `./scripts/test.sh`, never bare `swift test`; no `git checkout/stash/restore/clean`; never touch
`.env`, user audio devices, `scripts/ace-step`, `scripts/rvc`, `scripts/video`; wire and MCP are additive only.
Every render change lives in the offline render job (`StretchRenderCache` / `OfflineStretcher`), never on the
render thread: no lane adds work to `AudioEngine.swift` or `PlaybackGraph.swift`. Nothing needs full Xcode,
entitlements, AUv3 or signing. Listening pages check TRUE PEAK as well as loudness, and each page ships only after
its pre-registered physics orders the files.

**Filed separately, not in any lane:** §4 found a pre-existing defect (three gates can open across short silences
with a long retune, and `firstSpanIndex`'s sort assumption can break). Fixing it changes saved sounds, so it gets its
own roadmap item and its own byte gate.

### For the integrator: the `docs/ARCHITECTURE.md` "Key future decisions" entry (NOT written by this lane)

This lane may write only this file. NT-D adds this entry at the first close:

> **Natural tuning (settled 2026-09-25, m23-nt).** Four set/per-note features make a tuned vocal keep the singer's
> sound: a formant curve (`PitchEditSet.formantCorrection`, per-note `formantOffsetSemitones`, source f0 as base,
> never 0), untuned consonants (`keepsConsonantsUntuned`: gaps between notes crossfade to the source), a drift/wobble
> separator v2 run only when a note's two scales differ, and soft joins (`transitionOutMs`, `glideFollow`,
> set-level slope). Digest suffix slots 7 formant, 8 consonant, 9 transition; §3 is keyed by the `shaping:` render
> key version. Absent fields decode to legacy, so saved projects render and save byte-identically. New sets are
> seeded by `PitchEditSet.seeded` (presets get the slope but keep slide parts as sung, `glideFollow` 0, per (a-T));
> soft joins also span holes shorter than the consonant minimum (one `joinKind` predicate); the consonant crossfade
> is power-matched from a per-join measured correlation; every rebuild goes through
> `withSegments`. `RenderDiff` compares formant and consonant weights. `Clip.formantPreserve` governs the whole-clip
> transpose only.

## Revision 2 amendments (OVERRIDE §1-§4, X1-X12 and the Delivery plan)

Each R-item answers one review finding (see "Review log"). Where an R-item and any earlier text disagree, the R-item
wins. Labels: MEASURED = read or run this session; READ = seen in source; INFERRED = derived.

### DSP: the consonant mix and its gates (§2)

**R1. The consonant crossfade law is measured per join, not one law per take (replaces 2b.3's LAW bullet, M-3's
law leg, G-C5's premise).** 2b.3 assumed dry and tuned are "highly correlated" in the fade. The source says the
correlation depends on HISTORY, not on the take: the stretcher carries each bin's output phase forward
(`prevOutput × input × conj(prevInput)`, READ signalsmith-stretch.h:697-717) and re-anchors to the input only when
the prediction's norm is ≤ `noiseFloor` 1e-15 (READ :596-603, :508). So after any moved note the tuned gap is the
source with per-bin phase rotations; before the first moved note it is close to the source (INFERRED). The p2-ren
lane measured the analogue: seam ρ −0.25…0.77, equal-power failed its envelope bound on 8 of 16 seams (+1.6 to
+2.2 dB at ρ ≈ 0.5), and it moved to a power-matched law (MEASURED by p2-ren, READ ProvisionalRender.swift:65-75,
:145-156). 2b.3 cited the superseded text (incremental-note-render.md:439-444).
- **Law.** `applyConsonantMix` uses the power-matched MATH, not the p2-ren function (that one is a linear ramp over a
  fixed count, in a p2-ren-owned file, READ ProvisionalRender.swift:632-667). Per fade: measure ρ between dry and wet
  over the fade's frames, clamp to [0, 1]; gains `w/n` (wet) and `(1−w)/n` (dry), `n = √(w² + (1−w)² + 2ρw(1−w))`.
  `w` stays the pure DAWCore raised cosine (`tunedWeight`), versioned by `consonantMaskVersion`; ρ and `n` are
  engine-side because they need audio. Outside a fade `w ∈ {0, 1}` gives `n = 1`, so G-C1 (dry bytes) and G-C2
  (note bytes) keep their byte claims (INFERRED algebra).
- **Window vs whole file.** ρ is data-derived and continuous, so a window render differs from the whole-file render
  only as much as its wet audio does. **G-C6 is restated on the I1-F1 split**: a window whose history is untransposed
  < −90 dB (gate (a), READ ClipSpanRenderTests.swift:203); otherwise the gate-(b) magnitude-and-pitch tolerance
  (:333). Not byte equality.
- **M-3** reports ρ PER JOIN, split into "a moved note precedes this join" and "clean history", and no longer picks a
  law. **G-C5** keeps its [−6, +1.5] dB bound; add a plant: equal-power forced at a clean-history join (ρ ≈ 1) must
  bump past +1.5 dB (proves the gate sees the over-sum).

**R2. M-1 separates delay from rotation, and its failure pauses C2 instead of stopping the design (replaces 2g M-1,
X11's M-1 sentence, Delivery plan C2 "stop and report").** Alignment is structural: output frame 0 = input frame 0
through `outputSeek` (READ OfflineStretcher.swift:20-25, csignalsmith_stretch.h:12-16). Coherence is historical
(R1). A raw cross-correlation argmax after a moved note can drift toward a fraction of the dominant period because
its lag-0 value scales with cos(rotation) (INFERRED). New M-1, per gap ≥ 100 ms:
- (a) lag from the ENVELOPE of the analytic cross-correlation (or GCC-PHAT); (b) peak normalised ρ; both split by
  "moved note precedes the gap".
- Pass: lag 0 in every clean-history gap with ρ ≥ 0.9. Gaps after moved notes are REPORTED (they feed R1 and R5),
  never a stop.
- Plants: the 3-frame delay reads 3 (kept); NEW, the tuned audio phase-rotated by π/2 per bin reads lag 0 with LOW ρ
  (proves the instrument tells rotation from delay).
- **If a clean-history gap shows a real non-zero lag:** C2 pauses (the MUST does not). Fallback: a constant integer
  compensation of the dry read, measured per render configuration, behind G-C1's existing +1-frame plant, and
  re-reviewed by daw-architect before C2 resumes. Nothing else in NT-C waits on M-1.

**R3. §1 G7 is rewritten on the I1-F1 split, with a spy instead of an inert plant (replaces 1(g) G7; rewords 1(b)'s
"base never 0" reason).** Byte equality after a moved note is unreachable (READ ClipSpanRenderTests.swift:203, :333;
incremental-note-render.md:127-131). The base=0 plant cannot fail: `estimateFrequency`'s IIR is entered only when
`processFormants` (READ signalsmith-stretch.h:689-695, :310) and base ≤ 0 (:983), and `reset()` (called by
`outputSeek`, :59, :175) zeroes it, so after untransposed history both sides hold 0 (INFERRED from READ lines).
- New G7: gap-start window, clean history: < −90 dB vs whole file; any other window: gate-(b) tolerance.
- Spy gate (the tree's "a spy gate beats a source-shape gate" law): record every value the curve loop obtains from
  `formantBaseHzAtOutputFrame` on engaged hops (a test-only recording closure wrapped around the Swift closure; the
  C shim is NOT instrumented). Assert every value > 0 and == `formantBaseHz(atSourceSecond:)` at that hop's lookup
  frame. Plant: a closure returning 0 must fail.
- 1(b) reword: the explicit base buys DETERMINISM and a trusted f0 (the detector's, not an estimator upstream calls
  "VERY rough", :950), not whole-file byte parity.

**R4. A gate for consonant smear INSIDE the note (new G-C12; M-2 gains a leg).** The mask removes the shifted
consonant only in gaps. The stretcher's 120 ms Kaiser blocks at a 30 ms hop (READ signalsmith-stretch.h:63-65, :75)
carry a consonant's energy, shifted, into the first and last tens of ms of a moved note, where w == 1 (READ 2b.2;
ProvisionalRender.swift:50-54 names the same 0.12 s smear). The size is INFERRED; G-C2 would lock it in.
- **Measure first (M-2b, NT-G):** > 4 kHz energy and spectral flatness over the first and last 60 ms of each note
  that touches a consonant region; compare the flag-on render with the source and with an unmoved render. Plant:
  the 'Star' /a/ moved +300 c must show inner-edge excess over the unmoved render.
- **G-C12:** the excess is within a pre-registered bound (from the unmoved control pair, max(floor, 2 × control)).
- **If M-2b shows audible excess:** the fade may extend a MEASURED distance into the note (the "edge offset",
  option D of the old L4, now ours, not the user's). Then G-C2 reads "byte-identical beyond fade + offset". M-2's
  knob decision uses this smear as well as the detector's edge error.

**R5. G-C3 names its retune and gains a waveform leg that sees phase scrambling.** With the editor seed the ramp
leaks 15 ms into the gap (READ 2a item 3, the r/2 leak row), which touches only the 20 ms 't', so a centroid
metric on the 120 ms 's' may pass on HEAD (INFERRED). And what dry gaps fix is phase resynthesis (R1), invisible to
magnitude metrics.
- Fixture retune: **Gentle (retune 200 ms, r/2 = 100 ms leak)**, pre-registered HEAD reading: the 's' region's
  band shift is > the floor (the leak covers most of the 's'). The Natural-retune case is recorded, not asserted.
- New waveform leg, and it is the red-on-HEAD leg: residual dB of (render − source) per gap, split by "moved note
  precedes". HEAD after a moved note: a number NT-G records from M-1 first and pre-registers as the red
  threshold (not guessed here); flag on: −inf
  (digital zero) beyond the fade. Plant: the dry read offset by one frame is not −inf.
- G-C11 (real take) gains the same residual leg.

### DSP: §1 and §4 minors

**R6. 1(b)'s reason for "nil is the only legacy path" is corrected.** `invMapFormant` switches to an additive map
above the same limit with the exact inverse (READ signalsmith-stretch.h:850-856 vs :920-925, both using
`freqTonalityLimit` = limit/√p, :110). With multiplier = p, `invMapFormant(mapFreq(f)) = f` in both regimes (INFERRED
algebra), so at c = 0 the energy ratio is 1 to float rounding and the base does nothing. The TRUE differences from
legacy: F takes only the note's constant move, not shaping and generator terms (1(b), the "edit term is the note's CONSTANT move only" bullet), and the formant stage
runs (cost). So G3's "c = 0 ≈ G1" stands, for this reason. Option A's material must be UNSHAPED (see R20).

**R7. G6 gets a flag-on plant.** The existing plant (`css_set_formant_semitones(…, 0, true)`) is what
`css_set_formant_preserve(true)` already writes (READ shim.cpp:47-52), so it cannot move flag-on bytes. Add: an
unconditional per-hop `css_set_formant_base_hz(110)` in the legacy branch; a flag-on golden must go red.

**R8. The explicit base sits 0.5 bin low; documented, not compensated.** `freqToBand` uses the modified-spectrum
`f·N − 0.5` (READ stft.h:78-80; `DynamicSTFT<Sample, false, true>` with 1 = MODIFIED, signalsmith-stretch.h:519,
stft.h:10), while `estimateFrequency` returns a spacing (:951-963). At N = 6144 (INFERRED from stft.h:35) that is
−3.6 % at 110 Hz, −5.4 % at 72 Hz, about 1 % on the envelope decay. The shim cannot see N without a new API, so the
shim comment documents it and G2's 80 Hz cell is its guard. It is part of `formantRenderVersion` 1 and is never
"fixed" later without a version bump.

**R9. The additive-map threshold depends on the formant shift.** It is `L·2^(F/12)` (READ :921), not a fixed ~7.1 kHz:
at no pitch move, −2 st → 7.1 kHz, the UI's −6 → 5.66 kHz, the wire's −24 → 2.0 kHz; with a +4 st move, −6 → 5.04 kHz
(INFERRED arithmetic). 1(g)'s meter band (250-5000 Hz) stays; G5 stays at −2 st; the UI range stays ±6 st and the
Voice caption is unchanged; the wire text for `clip.setNoteFormant` says "large negative offsets also move the upper
band by a fixed amount rather than a ratio".

**R10. G-LAND measures where the join has finished.** At Δ 500 c, 3000 c/s, h = 83.3 ms, the smoothstep 60 ms past
the join is 0.947, about 27 c short (INFERRED, from 4.b.2). New rule: measure at ±(h + half a hop + the tracker's
half-window) per join, h taken from the SAME `make` output; or compare against the ideal curve (IdealReading method).

**R11. Per-note formant granularity is stated and gated.** One value per 1440-frame hop (READ OfflineStretcher.swift:
536-545), applied to a 120 ms block. G5 measures neighbours only beyond ramp half-width + 60 ms. NT-E1 records the
shortest note the Voice tool can isolate (MEASURED constant, `PitchEditSet.minimumVoiceNoteSeconds`); the UI says
"Too short to change the voice of this note alone" on shorter notes, like §3's "too short to separate".

**Latency note (from the DSP verdict; no behaviour change).** 1(b)'s "a formant change lands at the same latency as a
transpose" is upgraded from INFERRED to READ: `presetDefault` passes `splitComputation=false` (READ
signalsmith-stretch.h:63-65), so `processToStep = newBlock ? blockProcess.steps : 0` (:321) runs every step of the
block at once, and setters written before the same process call are consumed together. G4 stays as the measurement.

### Product: the join control, presets, short holes, the upgrade (§4, X3, X4)

**R12. ONE note-edge interaction spec for C2 and §4 (replaces 4.f "Handle" and "Tool palette"; blocks NT-U2).** As
written, §4's LEFT/RIGHT seam drag and hairline sit on the same abutting joins as C2's planned connected-edge timing
drag and its own hairline (READ timing design :739-750, §3.8 :801-812; C2-2…C2-5 open, MEASURED ROADMAP.md:1592).
Melodyne edits a transition with a VERTICAL drag on the rear part of the note (Celemony Melodyne 5
Pitch Tool page, quoted by the product critic: "If you position the Pitch Tool over the rear part
of a note, click and drag vertically, you can make the pitch transition steeper or less steep"; NOT re-fetched here,
the fetch failed this session). The spec:
- **One edge zone** per blob: C2's `clamp(0.25·w, 4, 8)` px at each end; no edge zone on a blob narrower than 12 px.
- **Axis lock** after 4 px of travel: horizontal → C2 timing (as C2 designed); vertical, on the REAR zone of the left
  note of a soft join (R15's predicate) → that join's width. Drag DOWN = gentler (wider), UP = steeper (narrower),
  double-click = back to Auto. A vertical drag on a rear zone that is not at a soft join is a normal pitch drag.
- **One hairline idiom** at soft joins, owned by C2 (`signal` ink at 40 %, READ timing design :748-750). §4 adds no
  second hairline; it adds a drawn (NOT hover-only) caption "Slide: Auto" / "Slide: 120 ms" under every soft join
  whose Δ ≥ 100 c. Captions are drawn because tooltips are invisible to `view.capture` (READ
  PitchEditorModel.swift:1137-1140).
- **Note menu row:** "Smoother slide into the next note" / "Sharper slide" / "Slide: Auto", so every join is reachable
  without the zone (narrow notes, keyboard-less use).
- Ownership: this spec is carried into the timing design by NT-D (the only lane that edits it) BEFORE NT-U2 starts;
  the router's press kind is `.edgeDrag(noteID, edge)` resolved to `.timingDrag` or `.transitionDrag` by the lock.

**R13. The Move tool keeps its pitch drag on short notes (new UI gate G-U-HIT).** A fixed 12 pt rear zone hit-tested
before noteDrag would make a ≤ 0.19 s note (≈ 12 px at the default 32 px/beat, 120 BPM; READ PianoRollZoomModel.swift:25;
INFERRED arithmetic) all seam; 24 of 42 notes are < 0.384 s (READ §3a). R12's zone rule fixes it. Gate: at default
zoom, presses at the centre and at 75 % of a 0.2 s note route to `noteDrag`. Plant: a fixed 12 pt zone fails it.

**R14. Presets get the transition slope too; `glideFollow` stays 0 on presets (replaces X3's slope row and 4.b.5
"Presets").** The (a-T) ruling makes the slide PART an identity segment (READ note-splitting design :318-323); it
says nothing about join width. Seeding slope = `defaultTransitionSlope` on `PitchAutoCorrect.editSet` changes preset
renders only where W > retune (Δ large) or where the neighbour is the shorter note, and removes the F12 dip at soft
joins (INFERRED from 4.b.2). `glideFollow` = 0 stays, which is all (a-T) protects, so "every preset stores a slide AS
SUNG" stays true. Correction of a claim: `PitchPresetRenderGateTests` builds through `editSet` (READ
PitchPresetRenderGateTests.swift:22, :248) but asserts pitch DIRECTION and identity-digest, not bytes (READ :190,
:357), so it is blind to join changes. New gate G-PRESET-JOIN (NT-E1): preset render with slope seeded vs slope 0
differs ONLY inside ±h of joins where the soft h ≠ the legacy half. X4's upgrade then has ONE slope for every set,
preset-built or not.

**R15. ONE DAWCore predicate for "soft join", shared by §2 and §4 (amends 4.b.2 step 2, 2b.2, X8).**
`PitchEditSet.joinKind(between: i, and: i+1) -> .soft | .gap`: soft if the notes abut bit for bit OR the gap is
shorter than `consonantMinimumGapSeconds`; else gap. `voicedRuns` ends a note at any unvoiced frame (READ
PitchCorrection.swift:1791-1796, :1826), so a one-frame blink leaves a 16-32 ms hole that §2 leaves tuned and §4
treated as a hole with 30 ms ramps (≈ 10000 c/s at 300 c, 4.b.6).
- For a short-hole soft join, `make` centres both gates on the gap MIDPOINT m with one shared h (so I2's
  complementarity holds); `firstSpanIndex`'s scan uses the effective edge m. G-SUM gains 16 ms and 32 ms holes;
  G-TWO's fuzz gains short holes and asserts `effectiveEnd + halfRampOut` is non-decreasing.
- X8's gate becomes: gap ≥ minimum → §2 only (§4 byte-inert there); gap < minimum → §4 only (§2 byte-inert); planted
  both ways. M-3's gap histogram sets the one threshold for both.
- Legacy sets: `usesSoftJoins == false` never reaches this; bytes unchanged.

**R16. `predatesNaturalTuning` is defined once; Q-U1 is reworded (replaces X10's `legacyNaturalTuning`, 1(f)'s
legacy line trigger).** `legacyNaturalTuning` appears once, undefined (MEASURED grep, natural-tuning.md X10). Define
`PitchEditSet.predatesNaturalTuning: Bool { formantCorrection == nil && !isPitchIdentity }` in DAWCore; the UI line,
the wire field (`predatesNaturalTuning`) and Q-U1 all read it. A preset-tuned vocal built after the update is NOT
"predates": it gets voice, consonants and (R14) slides at once. Q-U1's text is rewritten below.

### Product: coverage of the four asks, and the user's earlier rulings

**R17. NT-E2 waits for p2-ren to LAND, not to be committed (replaces "committed"/"commits" in X5, the Delivery plan
preamble, the NT-E2 row and its "Can start", and §1 1(i)/1(j)'s "AFTER p2-ren commits").** Commits are the user's word (Delivery plan preamble). Read literally, voice and
consonant controls would wait on an unrelated commit nobody asked the user about. New wording: "p2-ren Stage B landed
and its tests green in the tree (uncommitted); the p2-ren owner hands over the file token at that point".

**R18. Ask #3 is stated as half-owned, with its short-note behaviour said out loud (amends Summary item 3, 3h, 3j).**
The Wobble half is C5a (C5a-0b → C5a-4 open, MEASURED ROADMAP.md:1592). On this singer, 24 of 42 notes are shorter
than ~0.4-0.5 s, where Drift "mostly moves the note to its average pitch" (READ §3b). So:
- The handoff page says: "On your recording most notes are too short to tell slow wander from wobble; there, Drift
  acts like a small pitch move."
- L3 adds ONE short note (< `minimumSeparableSeconds`) as a second excerpt on the same axis, so the pick is heard where
  it mostly applies.
- What ships if a gate fails: C5a-0b fails → no Wobble tool (C5a's own fallback); §3 G3 fails → Drift ships to agents
  only (X11). Named in 3j via R30.

**R19. Ask #2's limits are said up front (amends Summary item 2, 2h).** M-1 is a precondition with a fallback (R2);
an "s" riding a vowel inside a note still moves (N2-F3, READ 2b "(c)"); the Sibilance Balance knob the user named
ships only if M-2/M-2b show the edge is uncertain. Stretched clips: `stretchRatio` is written only by
`setClipStretch` and `stretchClip` (MEASURED ProjectStore.swift:7571, :7638), so "inactive on stretched clips" is an
edge case, not the common case.

**R20. L1 plays two excerpts and labels option A honestly (amends 1(h), L1).** One +4 st note is the case that
favours 100 %, yet the pick sets every future vocal and the formant stage runs on nearly every corrected note (G2b,
READ 1(g)). Add a second excerpt on the same page and axis: a phrase with ordinary preset-size corrections at the same
four settings; publish only if G2b's bound holds on it. Option A renders at c = 0.0 on UNSHAPED material (R6) and is
labelled "Follows the note: brighter, smaller voice (like today)" only if its envelope shift matches the nil render
within G3's tolerance on that material; otherwise "(like today)" is dropped.

**R21. U5 stays: a breath or "s" the user drags on purpose still moves (replaces 2b.6's U-F2 default; Q-U4 becomes a
note).** The MUST is that moving the NOTE never moves the "St"; it does not say a blob the user drags must stay put.
The unpitched design shipped U5 because "the user asked to move sounds" (READ unpitched design :38, :276-279).
Rule, once U-A lands: `consonantRegions()` = complement of segments that are PITCHED **or** have their own
`pitchOffsetCents != 0`. An untouched `.unpitched` segment is dry; a deliberately moved one renders moved. The MUST
holds (moving "ar" never moves "St"); U5's on-screen text stays true. Gate G-C13 (after U-A): an `.unpitched` segment
with offset 0 is dry, with +300 c it is not. Plant: ignoring the offset makes the moved blob dry, fails.

### Product: UI wording and small semantics

**R22. The Voice offset is drawn in `signal` ink, never amber (replaces 1(f) item 2's colour).** Amber is
record/warning (READ DESIGN-LANGUAGE.md:11) and on a pitch-editor note already means "the render could not apply this"
(READ PitchEditorView.swift:666-673). The offset bar and "Deeper 2.0" chip use `signal` at the §3 Drift readout's
weight; amber stays for refusals.

**R23. No Simple/Pro split in the pitch editor (replaces 1(f) item 1's "Simple mode… Pro mode", 2f's "BOTH").** The
pitch editor has no density mode today (MEASURED: `grep -rniE 'simple mode|pro mode|isPro\b|simpleMode|uiMode|
densityMode'` over `Sources/DAWApp/PitchEditor` and `Sources/DAWAppKit/PitchEditor*.swift` is empty; the same
pattern over `Sources/DAWApp` returns QuantizePanel.swift, ChopToPadsPanel.swift and others, the positive control). All three header rows, and §1's "Whole-clip transpose keeps voice"
chip, always show; no mode wiring is added (no new file outside NT-U's list).

**R24. "Steady" means one thing (amends 3f/3h).** Double-click in the Drift tool toggles between as-sung and the SAME
target as the "Steady drift" menu row (0 until L3 is answered, then the pick). 0 is reached only by "Remove wobble
and drift" or a drag. Readout bands move so the recommended 0.3 lands inside one band: 0.7-0.95 "A little steadier",
0.2-0.65 "Steadier", 0.05-0.19 "Much steadier".

**R25. The question list is cut to taste questions and maps the paste's names (replaces "Open questions").** L4 is
measurable (ours, R4); Q-U2 answers itself; Q-U4 concerns an unbuilt feature and R21 removes its premise. Both become
FYI lines. The page gains one line mapping names: Formant tool → Voice; Sibilance Balance → Consonants (automatic);
Pitch Modulation / Pitch Drift → Wobble / Drift; the separation line → Slides (and the rear-edge drag, R12).

**R26. Labels that collide are renamed; every string lives in `PitchEditorFormantCopy` (amends X9, 1(f), 3f, 4.f).**
"Gentle" is a preset chip (READ PitchCorrectionPresets.swift:47) and a Slides step; "Sharp" and "Flatten" are pitch
words (the app uses "sharp" as too high, READ Sources/DAWControl/CopilotCatalog.swift:690, "pushes a wind instrument sharp"); "Voice depth 100 %" reads as "deepest".
- Slides steps: **Snappy (today's width) / Quick / Smooth / Slow**. L2 uses the same names.
- Voice row: **"Keep voice size"** 0-100 % (0 % = follows the note, 100 % = kept).
- §3's "Flatten" → **"Remove wobble and drift"**.
- Upgrade line, one string, ≤ 51 characters: **"Tuned before this update. Tap to update."** (40 characters, MEASURED `wc -m`; re-measure at landing). Sweep the stale strings: 1(f) item 4's hint → "Big jump: turn up Keep voice size
  so it doesn't sound squeaky."; plainLanguage "Voice kept natural" → "Voice size kept"; MCP text "kept natural by
  formantCorrection" → "voice size kept by formantCorrection".

### Gates and delivery

**R27. G-BYTE's plant forces a value, and names the golden that goes red (replaces 4.g G-BYTE's plant).** Forcing
the soft branch on a legacy golden is inert: with slope 0 and no explicit width, every join "keeps its legacy
halves" (READ 4.b.2 step 2), so no byte moves. New plant: `make` substitutes slope = `defaultTransitionSlope` on every
set. The gate lists at least one existing golden that contains an abutting join with W > `retuneMs` or a shorter
neighbour, and asserts THAT golden goes red. If no existing golden has such a join, NT-E1 adds one before claiming
the gate can fail.

**R28. The existing NoteSegment census is NT-C's, in C0 (amends the lane table).**
`digestCoversEveryStoredField` holds a literal `covered` list (READ Tests/DAWEngineTests/PitchCurveRenderTests.swift:
412-443); §4's `transitionOutMs` and `glideFollow` turn it red the moment they exist. One test target compiles every
file, so the sub-step that adds the fields updates `covered` in the same landing: C0 adds all fields (Delivery plan),
so **C0** owns this edit (with the matching digest slot-9 block landing in NT-E1). NT-C's file list gains
`Tests/DAWEngineTests/PitchCurveRenderTests.swift` (the `covered` list only).
⚠️ The census compares NAMES only (`Set(fields) == Set(covered)`), so from C0 until NT-E1 lands digest slot 9 it is
green while nothing hashes the two fields. The two `covered` entries carry a comment "hashed in slot 9 (NT-E1)", and
G-DIGEST (b)'s mutation rows are what close that window; until they pass, the census is a name pin, not a coverage
pin, and no lane may cite it as proof the fields are keyed.

**R29. `seeded(…, origin:)` becomes `partKinds:` (amends X2 rule 3, X3).** No `origin`/`NoteOrigin` exists
(MEASURED: grep `NoteOrigin\|origin:` over `Sources/DAWCore/PitchCorrection.swift` is empty; `retuneMs` on the same
file counts 20, the control), and digest slot 6 is reserved for U-A's stored `origin` (READ
StretchCurvePlan.swift:381). New signature: `PitchEditSet.seeded(analysisVersion:segments:retuneMs:partKinds:
seedPolicy:)`, where `partKinds: [UUID: NotePart.Kind]` (READ PitchNoteSplitter.swift:32-33) is a TRANSIENT hint from `PitchNoteTable.detected` used
only to set `glideFollow` on `.transition` parts, and `seedPolicy` is `.editor | .preset` (R14's table). X3 gains a
row: `partKinds` — not stored; editor passes the splitter's kinds, presets pass `[:]`. U-A's `origin` is unrelated and
lands later, additively.

**R30. §3's C5a dependency is a named §3 risk (amends 3j).** Risk 3j-C5a: the Drift group setter needs C5a-2's
`NoteVibratoLimits.swift`, and the Drift tool is C5a-5. If C5a stalls, §3 ships its DAWCore physics (G0-G3) and wire
verb only after C5a-2, and no Drift UI.

**R31. The plugin bundle is regenerated and checked before any new tool is called shipped (amends NT-W).**
`claude-plugin/server/index.mjs` is generated (MEASURED line 2: "GENERATED FILE … Regenerate with: cd mcp-server &&
npm run bundle:plugin"). NT-W's close-out: run `npm run bundle:plugin`, grep the bundle for all eight tool names WITH
a positive control on an existing tool (`clip_set_note_gain`), update the hand-maintained agent allowlists, and state
that `/plugin update` is the user's action. A "shipped" claim is checked against that artifact, not `server.ts`.

**Census note (gates finding 4, no R-item).** `rtk proxy grep -rn 'PitchEditSet(' Tests/` now returns 184 lines in 40
files (MEASURED this session), not X2's 181; the delta is p2-ren's untracked `ProvisionalRenderTests.swift`. X2's
ruling (no init-signature change) makes the number irrelevant; re-measure at implementation, never quote it.


## Open questions for the user

These replace the per-section question lists (§1 1(h) and D-F2, §2h Q1-Q3, §3h, §4 D4-1 and 4.h) as the ONE list
the orchestrator puts on the handoff page (revised by R25). Each has a recommended default; work proceeds on the
default until the user answers, and nothing here is asked twice. Listening items ship as 3-4 options that differ on
ONE thing, and each page ships only after its measurements put the files in the stated order.

**What you asked for → where it is in the app:** Formant tool → **Voice**; Sibilance Balance → **Consonants**
(automatic); Pitch Modulation / Pitch Drift → **Wobble / Drift**; dragging the separation line → **Slides** (and
dragging a note's rear edge up or down).

**Choices by ear (listening pages)**

- **L1. How much should a moved note keep the singer's voice size?** Two short clips, each played four ways: one note
  moved up 4 semitones, and a phrase with ordinary small corrections. 0 % (follows the note: brighter, smaller voice,
  like today), 50 %, 75 %, 100 % (the voice keeps its size). *Recommended: 100 %.* Your pick becomes the setting for
  every vocal you tune from now on, so listen to the phrase too, not only the big jump. (§1 1(h), R20)
- **L2. How gently should a moved note slide into the next one?** One note moved up 4 semitones next to an unmoved
  one: Snappy (today), Quick, Smooth, Slow. *Recommended: Smooth.* (§4 4.h, R26)
- **L3. How much slow wandering should "Steady drift" keep?** A held note and a short note, each with its wobble
  kept, and its slow wander kept at 100 %, 60 %, 30 %, 0 %. *Recommended: 30 %.* On your recording most notes are
  short, and on those Drift acts like a small pitch move, which the short-note clip lets you hear. This page exists
  only if the app first proves it can tell wander from wobble (§3 G3). It sets only what "Steady drift" does. (§3, R18)

**Choices in words**

- **Q-U1. Vocals you tuned BEFORE this update: what should happen?**
  (a) They keep sounding exactly as now, including the squeaky, jumpy big moves, until you tap "Update" on that
  vocal (one tap, one Undo).
  (b) The first note you drag on one of them updates the whole vocal (also one Undo).
  *Recommended: (a)*, because the update changes the voice size on nearly every tuned note at once, which can feel
  like the app changed your mix. Either way, vocals you tune AFTER the update, including with a preset, get the
  voice, consonant and slide improvements straight away. (X4, R16)
  ✅ **ANSWERED (b)** by the user, 2026-09-25 PDT (handoff db `nt-old-vocals = b`), against the recommendation.
  Built by D4-1: the first per-note edit that CHANGES a note updates the whole vocal, as one Undo. An edit that changes
  nothing updates nothing, per the user's "the first note you drag" (ruled by the orchestrator 2026-09-27;
  `PitchEditSet.afterHandEdit(from:)` is the one home).
- **Q-U3. Should the Drift and Wobble tools show a number (like "keeps 60 %"), or words only (like "steadier")?**
  *Recommended: words only*, which matches the rule the Wobble tool already follows. (§3h)
  ✅ **ANSWERED: words only** (`nt-readout = words`, 2026-09-25 PDT).

**For your information (no answer needed)**

- Running Auto-Tune again on an old vocal builds fresh tuning, so it uses the new sound. Tell us if you want re-runs
  to sound like before. (was Q-U2)
- Dragging a breath or an "s" on purpose still moves it, as you asked earlier; moving the NOTE next to it never
  does. (R21; was Q-U4)
- Where an "s" hands over to the vowel is set by measurement, not by ear. (was L4; R4)
- Vocals you tune with a preset after the update sound slightly different from before at big jumps and next to very
  short notes, because their joins now slide smoothly too; the slides you sang stay as sung. (R14)

**Not asked** (already ruled, or measurable and so ours): presets keep slides as sung (the user's (a-T) pick, kept
by R14); fade lengths, gap minimums, the consonant crossfade law and separator window lengths (set by measurement);
Rubber Band licensing or a PSOLA stage (not proposed; would need the user's word if ever proposed).

## Review log (revision 2, 2026-09-25)

Three critics reviewed revision 1 (lenses: dsp, product, gates). Every finding is listed here with a verdict. A finding
marked accepted has its fix in "Revision 2 amendments" (R-numbers), which OVERRIDES §1-§4 and X1-X12. Labels:
MEASURED = read or run this session; READ = seen in source; INFERRED = derived.

Every finding below was checked against source this session before its verdict. None was rejected outright; five
were accepted with a changed fix (marked "accepted, fix adjusted"), and one is logged with no change needed.

**DSP lens**

| # | Finding | Verdict | Why / evidence | Fix |
|---|---|---|---|---|
| D1 | §2 crossfade premise (dry and wet correlated) is false after moved notes | accepted, fix adjusted | READ signalsmith-stretch.h:596-603, :697-717; ProvisionalRender.swift:65-75 (ρ −0.25…0.77, 8/16 equal-power fails). Adjusted: the p2-ren FUNCTION is linear-ramp and p2-ren-owned, so only its power-matched MATH is reused | R1 |
| D2 | M-1 argmax confuses rotation with lag; stop gate can freeze the MUST | accepted | READ OfflineStretcher.swift:20-25 (alignment is structural); rotation mechanism READ as D1 | R2 |
| D3 | G7 byte equality unreachable; base=0 plant inert | accepted, fix adjusted | READ ClipSpanRenderTests.swift:203, :333; signalsmith-stretch.h:59, :175, :689-695, :983. Adjusted: the spy wraps the Swift closure, not the C shim | R3 |
| D4 | Consonant smear inside the note is kept by G-C2 and measured by nothing | accepted | READ signalsmith-stretch.h:63-65; ProvisionalRender.swift:50-54 | R4 |
| D5 | G-C3 retune unnamed; magnitude metrics blind to phase scrambling | accepted | READ natural-tuning.md 2a table (15 ms leak on the editor seed), 2g G-C3 | R5 |
| D6 | c=0 reasoning (multiplicative vs additive) wrong | accepted | READ signalsmith-stretch.h:850-856, :920-925, :110; algebra INFERRED | R6 |
| D7 | G6 plant invisible on flag-on goldens | accepted | READ shim.cpp:47-52 | R7 |
| D8 | explicit base enters 0.5 bin low | accepted, fix adjusted | READ stft.h:10, :78-80; signalsmith-stretch.h:519, :534-535. Adjusted: documented, not compensated (the shim cannot see the FFT size without new API) | R8 |
| D9 | additive threshold falls with negative F | accepted | READ signalsmith-stretch.h:921 | R9 |
| D10 | G-LAND red on correct code for soft joins | accepted | arithmetic from 4.b.2 (smoothstep 0.947 at +60 ms, Δ 500 c) | R10 |
| D11 | G5 neighbour window; per-note granularity unstated | accepted | READ OfflineStretcher.swift:536-545; signalsmith-stretch.h:63-65 | R11 |
| D12 | (verdict text) formant-vs-transpose latency can be READ, not INFERRED | accepted | READ signalsmith-stretch.h:63-65, :321 | latency note after R11; G4 kept |

**Product lens**

| # | Finding | Verdict | Why / evidence | Fix |
|---|---|---|---|---|
| P1 | §4 seam drag collides with C2's edge timing drag and with Melodyne's vertical gesture | accepted, fix adjusted | READ timing design :739-750, :801-812; MEASURED ROADMAP.md:1592 (C2 open). Adjusted: a vertical drag on a rear zone would still collide with the body pitch drag, so the spec shares C2's edge zone and uses an axis lock | R12 |
| P2 | fixed 12 pt zone takes over the pitch drag on short notes | accepted | READ PianoRollZoomModel.swift:25; timing design §3.8 | R13 (with R12) |
| P3 | presets get no soft joins; (a-T) does not cover join width | accepted | READ note-splitting design :318-323 (a-T = slide part is identity). Also found: `PitchPresetRenderGateTests` builds via `editSet` but asserts direction and identity, not bytes (READ :22, :190, :357), so 4.b.5's "stays byte-identical" was already moot under X3 | R14 |
| P4 | short holes between notes are smoothed by neither section | accepted | READ PitchCorrection.swift:1791-1796, :1826; 2b.2 (gaps < min stay wet); 4.b.2 (holes keep legacy ramps) | R15 |
| P5 | Q-U1 misdescribes the consequence; `legacyNaturalTuning` undefined | accepted | MEASURED: one occurrence (X10) before this revision | R16 + Q-U1 rewrite |

| P6 | ask #3 half-owned; Drift mostly re-centres this singer's short notes; L3 hides it | accepted | READ §3b (24/42 < 0.384 s; "mostly moves the note to its average pitch"); MEASURED ROADMAP.md:1592 (C5a open) | R18, Summary item 3, L3 |
| P7 | ask #2 has a hard stop with no fallback; Summary has no caveat | accepted | READ 2g M-1, X11; Summary item 2 | R2 (fallback), R19, Summary item 2 |
| P8 | NT-E2 waits on a p2-ren COMMIT, a hidden user decision | accepted | READ Delivery plan preamble ("uncommitted, until the user says commit") vs the NT-E2 row | R17; X5 and the lane table reworded |
| P9 | U-F2 default reverses the user's "let me move sounds" (U5) | accepted | READ unpitched design :38, :276-279 | R21 (U5 kept; Q-U4 becomes FYI) |
| P10 | L1 plays only the case that favours 100 %; option A is not "today's sound" | accepted | READ 1(h), 1(b) :98, G2b | R20, L1 |
| P11 | colliding and stale labels; 56-character upgrade line | accepted | READ PitchCorrectionPresets.swift:47 ("Gentle"); CopilotCatalog.swift:690 ("sharp" = too high); MEASURED `wc -m` = 56 | R26 (new line 40 characters, MEASURED) |
| P12 | Voice offset drawn amber, which means "refused" here | accepted | READ DESIGN-LANGUAGE.md:11; PitchEditorView.swift:666-673 | R22 |
| P13 | Simple/Pro mode does not exist in the pitch editor | accepted | MEASURED grep empty over pitch-editor sources, positive control app-wide returned files | R23 |
| P14 | "Steady" means two things; default sits on a band edge | accepted | READ 3f (double-click → 0) vs 3h ("Steady drift" → pick); bands 0.3-0.65 / 0.05-0.25 | R24 |
| P15 | question list has non-taste items; no name mapping | accepted | READ 2g (M-2 decides the edge), Q-U2 self-answering, Q-U4 on unbuilt U-A | R25, question list rewritten |

**Gates lens**

| # | Finding | Verdict | Why / evidence | Fix |
|---|---|---|---|---|
| G1 | G-BYTE plant inert (soft branch with slope 0 = legacy halves) | accepted | READ 4.b.2 step 2 | R27 |
| G2 | `PitchCurveRenderTests.swift` `covered` list goes red with no owning lane | accepted, owner adjusted | MEASURED PitchCurveRenderTests.swift:412-443 (literal list). Adjusted: owned by NT-C in **C0** (where the fields land, one test target), not NT-E1 or C4 | R28, lane table |
| G3 | `seeded(…, origin:)` collides with U-A's reserved slot-6 name | accepted | MEASURED grep empty for `NoteOrigin\|origin:` in PitchCorrection.swift, control `retuneMs` = 20; READ StretchCurvePlan.swift:381 | R29 (`partKinds:` + `seedPolicy:`), X3 row |
| G4 | X2's census 181 is stale (184) | accepted, no change | MEASURED 184 lines / 40 files; delta = p2-ren's untracked tests. X2's ruling keeps the init signature, so the number gates nothing | census note after R31 |
| G5 | §3's C5a dependency is only in the Delivery plan, not §3's risks | accepted | READ Delivery plan C3 and rule 2 | R30 |
| G6 | plugin bundle regeneration missing from NT-W | accepted | MEASURED claude-plugin/server/index.mjs:2 ("GENERATED FILE"); the bundle already embeds `clip_set_note_gain` | R31, NT-W row |

**Rejected findings: none.** Where a critic's fix could not be taken literally (D1, D3, D8, P1, G2), the reason is in
the table and the R-item carries the adjusted fix.

