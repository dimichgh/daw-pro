# m23-q — Note-Level Vocal Pitch Correction: Design Spike (GO/NO-GO)

**Status:** COMPLETE. Verdict in §0, full decision in §12. No section is left unfinished; everything I could not verify is called out in those words (§2.4, §5.2, §9, §12 "Deliberately left unresolved").
**Date:** 2026-07-29
**Author:** daw-architect
**Roadmap:** `docs/ROADMAP.md:469` (m23-q)
**Type:** Design spike. It produces a decision, not code. On GO it seeds its own milestone — the precedent is `docs/research/2026-07-16-spike-sfz-dspreset-design.md` §10.
**Companion:** `docs/research/m23-q-pitch-correction-survey.md`.

> ⚠️ **CORRECTED BY THE COORDINATOR, 2026-07-29.** This line originally read *"a skeleton whose every section is still `TODO:` … Nothing in it was usable; this document does not depend on it and supersedes it."* **That is false and the claim is withdrawn.** The survey is 56.4 KB and COMPLETE as scoped — sections 0, 1, 2, A, B and E filled and verified, no `TODO:` remaining (D was dropped and F handed to *this* document, both on explicit coordinator direction). It was already substantive before this design doc was commissioned. The two documents were therefore written **independently and in ignorance of each other**, which is not the weakness it sounds like: where they agree, that is genuine corroboration by two separate investigations. Where they DISAGREE, see the §5 reconciliation notice below — **one such disagreement is material and is not resolved by this document.**

---
## 0. Verdict

# **GO.**

The expensive half of note-level vocal pitch correction — artefact-free, formant-compensated, **time-varying** resynthesis — is already in this tree, already wrapped, already cached, and already reaches the render thread through a proven offline seam; the missing half is a monophonic pitch detector we can write ourselves on an MIT FFT we already ship, with **no new licence obligation of any kind**.

- **Pivotal question (can signalsmith-stretch change transpose mid-stream, cleanly?): YES** — upstream documents pitch automation as a feature and specifies its timing rule; the vendored source contains no constant-multiplier state. §2. What I did **not** verify is that it is artefact-free on real sung vocals; §2.4 specifies the 2–3 day experiment, and it is phase 0.
- **Named resynthesis approach:** signalsmith-stretch v1.3.2 (`57b93f4`), transpose curve updated per analysis hop, formant compensation with `setFormantBase` fed our own measured f0. §6.
- **Named detector:** in-house pYIN on the vendored MIT `signalsmith-linear` FFT. Fallback: WORLD Harvest (modified BSD). §5.
- **Estimate:** 4.5–5.5 weeks to the first shippable thing (an agent-controllable auto-tune); 14.5–19.5 weeks for the full Melodyne-class subsystem. §11.
- **Largest unknown:** E2 — perceptual quality of time-varying signalsmith on real voices. It is the ten-month-old outstanding condition on the M5 library choice, which was validated on a polysynth. §4.2, §11.4.

Full decision, falsifiability and inherited conditions: **§12**.

---
## 1. What was asked for, and what it decomposes into

The roadmap line (`docs/ROADMAP.md:469`) states the ask as: *"split a vocal into note-level segments by detected melody, then edit pitch/timing per segment, plus vocal alignment and professional correction."* That is Melodyne's core interaction, minus polyphonic DNA.

It decomposes into five separable subsystems. They are listed here in dependency order, and §11 phases them in a **different** order deliberately, so that the first shippable thing is user-visible:

| # | Subsystem | Status in tree |
|---|---|---|
| A | **Monophonic f0 detection** — per-frame fundamental + confidence over a vocal file | **Absent.** The real gap (§5). |
| B | **Note segmentation** — f0 + confidence + transients + (optionally) word boundaries → discrete note segments | Absent, but every input exists (§3.4). |
| C | **Per-note edit model** — pitch offset, drift/vibrato depth, formant, timing, amplitude, per segment; persisted; undoable | Absent (§7.2–§7.4). |
| D | **Resynthesis** — apply a time-varying pitch (and time) contour to the source | **Present and reachable** (§2, §6). |
| E | **Editor surface** — blob view, drag handles, scale/snap, audition | Absent. The largest UI item, and the one with no substrate. |

Two things the ask is *not*, and the doc keeps them apart throughout:

- **Not voice conversion.** Conversion changes *whose voice it is* (RVC sidecar on 127.0.0.1:8002, `vc.convertVocals`, `Sources/DAWCore/ProjectStore+VoiceConversion.swift`). Correction keeps the same voice and moves its pitch. §8.4.
- **Not the whole-clip transpose we already ship.** `Clip.pitchShiftSemitones` (`Sources/DAWCore/Model.swift:503`, clamped ±24 at `:554`) shifts everything by a constant. Note-level correction is the time-varying case of the same operation, and §7.1 makes them one path rather than two.

---
## 2. THE PIVOTAL QUESTION — can signalsmith-stretch change transpose mid-stream, cleanly?

**Answer: YES.** Time-varying transposition is an *intended, documented* use of the library, not a hack, and the vendored source corroborates it. This is the finding that most changes the shape of the milestone, so the evidence is given in full — including what it does **not** establish (§2.4).

### 2.1 Upstream documents it as a supported feature — this is the strong leg

The upstream README (`https://github.com/Signalsmith-Audio/signalsmith-stretch`, raw `README.md` fetched 2026-07-29) has a section titled **"Automation"**:

> To follow pitch/time automation accurately, you should give it automation values from the current processing time (`.outputLatency()` samples ahead of the output), and feed it input from `.inputLatency()` samples ahead of the current processing time.

and in "Latency":

> You should be supplying input samples slightly ahead of the processing time (**which is where changes to pitch-shift or stretch rate will be centred**), and you'll receive output samples slightly behind that processing time. *(emphasis mine)*

The second sentence only means anything if pitch changes during a stream are expected. Upstream is not merely permitting automation; it is specifying *where in time* a change lands.

### 2.2 The vendored source corroborates it, and shows no constant-multiplier state exists

Line numbers are `Sources/CSignalsmithStretch/vendor/signalsmith-stretch/signalsmith-stretch.h` (MIT — `vendor/signalsmith-stretch/LICENSE.txt`, Geraint Luff / Signalsmith Audio Ltd.). The sibling `vendor/signalsmith-stretch/include/signalsmith-stretch/signalsmith-stretch.h` is a one-line forwarder (`#include "../../signalsmith-stretch.h"`); `shim.cpp:9` includes it through that forwarder. One real copy.

1. **The multiplier is plain mutable state, re-read every analysis block.** `setTransposeFactor` writes `freqMultiplier`/`freqTonalityLimit` (`:107-115`); `setTransposeSemitones` wraps it (`:116-118`); storage at `:513`. It is consumed at `:300` (`blockProcess.mappedFrequencies = customFreqMap || freqMultiplier != 1`, recomputed on every new block) and at `:850-856` (`mapFreq`), called from `findPeaks` (`:874`). `updateOutputMap` (`:882-917`) rebuilds the entire input→output bin map from those peaks, every block. **I looked for state that caches a mapping across blocks and there is none.** That is the source-level claim I am confident in.

2. **Phase continuity: plausible from the source, but NOT proven by it.** The phase vocoder accumulates an output phasor per bin rather than recomputing an absolute phase: at `:712-716` `outputBin.output` is multiplied by `freqTwist` (the measured input phase advance at the mapped source position) and renormalised, so changing the map changes the *rate* of phase rotation rather than the phase itself. **However**, `:712-716` is only the *preliminary* prediction. The block at `:722+` ("Re-predict using phase differences between frequencies") performs vertical phase-locking across bins using the same freshly-rebuilt `outputMap`, and the final value is a blend. Nothing stale survives a map change, so the conclusion stands — but it stands mainly on §2.1, and the click test in §2.4 is what actually settles it. I am deliberately not claiming "this is the mechanism that prevents zippering"; I am claiming "nothing in the source assumes a constant multiplier".

3. **What a map change moves discontinuously is amplitude/timbre, not phase.** `prediction.energy` (`:708-709`) samples the input spectrum at the *new* map position, scaled by the local frequency gradient. A large instantaneous map jump therefore moves the spectral envelope within one block. Perceptually that reads as "the pitch jumped" — which is the requested behaviour at a note boundary, and an artefact inside a sustained note. §6.4 turns that into a design rule.

4. **No smoothing of the multiplier exists; the change is quantised to the analysis hop.** `setTransposeFactor` assigns directly and nothing slews `freqMultiplier`. A new value takes effect at the next new-block boundary, detected at `:281` (`samplesSinceLast >= stft.defaultInterval()`), where `samplesSinceLast` is incremented **once per output sample** (`:406`). With `presetDefault` (`:63-65`) the interval is `sampleRate*0.03` = **30 ms at any rate**, i.e. a ~33 Hz automation update ceiling.

   30 ms is fine for a correction contour and marginal for *shaping* vibrato: 5.5 Hz vibrato gets ~6 update points per cycle. If that proves too coarse, `configure(channels, blockSamples, intervalSamples)` (`:71-94`) takes an arbitrary interval and buys resolution at roughly linear CPU cost. **Our C shim does not expose `configure` — it only calls `presetDefault` (`shim.cpp:28`).** Exposing it is one additive function in `Sources/CSignalsmithStretch/include/csignalsmith_stretch.h`; it is not a new library and not a second stretch layer.

5. **The hop grid is in OUTPUT time, not source time.** Because `samplesSinceLast` counts output samples (`:406`), the 30 ms update grid is 30 ms *of output*. For pitch-only correction (ratio 1) output time equals source time and this is invisible. The moment per-note **timing** edits arrive (phase 3, §11), the grid becomes non-uniform in source time — a note stretched 1.4× gets its curve sampled every ~21 ms of source. Harmless, but nobody should later assume source-time uniformity.

6. **A richer lever exists as headroom: `setFreqMap`** (`:119-122`, state `:514`) accepts an arbitrary monotonic input→output frequency map. It is a `std::function` — heap-allocating, indirect-calling — which is fine offline and disqualifying on the render thread. Not needed for v1.

### 2.3 The latency trap the implementer WILL hit

Upstream centres a parameter change at the *processing time*, which is `outputLatency()` samples ahead of the output you receive. **A curve indexed naively against the output write cursor is applied late by `outputLatency()` samples.**

The number, derived rather than guessed: `inputLatency() = stft.analysisLatency()` (`:42-44`) `= _blockSamples - _analysisOffset` (`stft.h:66-68`); `outputLatency() = stft.synthesisLatency() + _splitComputation*defaultInterval` (`:45-47`) `= _synthesisOffset` (`stft.h:69-71`). Both offsets are initialised to `_blockSamples/2` and then moved to the window's peak index (`stft.h:298`, `:311-315`) — a symmetric Kaiser, so the peak stays at or adjacent to the centre. `presetDefault` sets `blockSamples = sampleRate*0.12`, and the shim passes `splitComputation = false` (`shim.cpp:28`). **At 48 kHz that is ≈2880 samples ≈ 60 ms for each of input and output latency**, with `blockSamples = 5760` and `intervalSamples = 1440`.

60 ms of misalignment at a note boundary is grossly audible — a consonant lands on the wrong note. And `OfflineStretcher` uses upstream's `outputSeek` recipe (`Sources/DAWEngine/Stretch/OfflineStretcher.swift:146-148` → `css_output_seek`) rather than the README's plain `seek`/`flush`, so the pre-roll bookkeeping is already non-obvious and the two offsets may partly cancel. **This must be measured, not reasoned about.** It is gate item (a) below.

### 2.4 What I could NOT verify, and the experiment that settles it

I verified that mid-stream transposition is *supported and structurally sound*. **I did not verify that it is artefact-free on real sung vocals, because that requires listening to audio this spike cannot produce without writing code, which the brief puts out of scope.** Reachable is not artefact-free and I will not assert quality I did not hear.

> **E1 — curve fidelity and alignment (deterministic, automatable).**
> Add an `OfflineStretcher` variant taking `curve: [(outputFrame: Int, semitones: Double)]` that calls `css_set_transpose_semitones` between `css_process` calls, chunked at exactly `intervalSamples` instead of `blockFrames = 4096` (`OfflineStretcher.swift:35`) — a 4096-frame chunk spans ~2.8 hops at 48 k, so per-hop resolution is lost unless the chunk *is* the hop.
> Input: synthetic 220 Hz sine. Request a step 0 → +2 semitones at a known frame.
> Measure with an FFT (`signalsmith-linear` is already vendored, MIT, Accelerate-backed):
> **(a)** the frame at which output f0 actually changes ⇒ the empirical offset from §2.3, which becomes a named constant with a test;
> **(b)** peak sample-to-sample discontinuity across the step versus the same render at constant pitch ⇒ the **click test**; it should sit at the constant-pitch noise floor;
> **(c)** f0 tracking error for a 5 Hz ±50-cent sinusoidal curve ⇒ whether 30 ms hops suffice for vibrato;
> **(d)** determinism: two runs bit-identical (guaranteed by the fixed seed, `OfflineStretcher.swift:42`), and a curve that is constant-zero bit-identical to the identity bypass.
>
> **E2 — perceptual (human, un-automatable).** Same machinery on a real dry vocal already in the repo's ACE-Step/RVC material: correct to a realistic contour and listen for warble, formant wobble and consonant smear. Null-test untouched regions.
>
> **Cost: 2–3 days.** **Kill criterion:** if E1(b) shows discontinuities above the constant-pitch baseline that a ≤30 ms crossfade cannot hide, or E2 is audibly worse than the whole-clip shift we ship today, the resynthesis pick moves to the §6.5 fallback and §11's estimate grows by that fallback's integration cost.

### 2.5 Bonus finding — time-varying *time* is reachable too, with a quality ceiling

`OfflineStretcher.stretch` has **no ratio setter, because upstream has none**: `csignalsmith_stretch.h` (`css_process` doc) — "the effective stretch ratio is outputFrames/inputFrames, averaged across calls". The ratio is implied by the per-call frame counts (`OfflineStretcher.swift:158-173`). **Per-note timing correction therefore needs no new API at all** — it is a different `inTarget` schedule in that same loop. Pitch and timing become one render pass, which removes the temptation to build a splice-based timing path beside `take.autoAlign`.

**The ceiling, which is real and belongs next to the good news.** `blockProcess.timeFactor` (`:312`) feeds `randomTimeFactor = (timeFactor > maxCleanStretch)` with `maxCleanStretch = 2` (`:509`), which switches on deliberate phase randomisation (`:639-640`). A local ratio beyond 2× therefore *chooses* smearing. Upstream independently states "time-stretching sounds best for more modest changes (between 0.75x and 1.5x)" (README §intro). So per-note **timing** has a quality ceiling that per-note **pitch** does not — pitch is documented as fine over multiple octaves. Practically: clamp per-note time ratio to ~[0.7, 1.4] and surface a warning rather than silently smearing. This is a §11 phase-3 risk, not a phase-1 one.

---
## 3. Substrate inventory — what already exists, and what each obliges us to reuse

The roadmap's "build on, not duplicate" is enforced here item by item. Every row is a place where a second implementation would reproduce the m23-f defect at subsystem scale.

### 3.1 Resynthesis — `OfflineStretcher` (reuse, extend in place)

`Sources/DAWEngine/Stretch/OfflineStretcher.swift`. Stateless pure-computation facade over the C shim. Already carries `formantPreserve` (`:61-66`, applied `:98-99`), which the shim's own comment calls **vocal mode** (`Sources/CSignalsmithStretch/include/csignalsmith_stretch.h:43-46`: "signalsmith formant compensation with auto-detected fundamental — vocal mode"). Already runs a chunked streaming loop (`:158-173`) with `outputSeek` alignment (`:148`) and `flush` tail (`:178-182`). The constant-pitch assumption is one line, `:98`, in **our facade** — not in the library.

**Obligation: the curve variant is a new entry point on this type, not a new type.** No `NoteStretcher`, no second C shim. `stretch(...)` becomes the degenerate case of `stretch(curve:)` with a one-point curve, or stays as a thin wrapper over it. There must remain exactly one place that pumps `css_process`.

### 3.2 Offline→RT delivery — `StretchRenderCache` (the precedent; it applies verbatim)

`Sources/DAWEngine/Stretch/StretchRenderCache.swift`. I read it. It is exactly the model.

- `@MainActor` service owned by `AudioEngine`; DAWCore never sees it (`:22-23`).
- Cache miss ⇒ 250 ms debounce (`:51`, `:183`) then `Task.detached(priority: .userInitiated)` (`:189`) running `nonisolated static func performRender` (`:229`), which reads the file, calls the facade, writes a `.partial-…caf` and **atomically renames** (`:283-296`).
- Per-clip latest-wins supersession with a cancellation flag polled between blocks (`:66-79`, `:170`).
- On commit, `onRenderComplete` (`:57-60`) fires on the main actor and the engine re-enters the `tracksDidChange` restart seam so the new file is scheduled.
- **The render thread only ever plays a plain Float32 CAF from disk.** Nothing about pitch correction reaches it. No allocation, no lock, no `std::function`, no FFT on the render thread — by construction, because the render thread does not know this subsystem exists.

Two properties of this cache that shape the design and are easy to miss:

- **It renders the ENTIRE source file, deliberately** (`:9-14`): "covering the ENTIRE source file (so split clips share one phase-coherent render and clip geometry never invalidates)". Consequence for us: **one note tweak re-renders the whole vocal.** §10.3 accepts that for v1 and names the cost.
- **`stretchEngineVersion` (`:46`) exists to invalidate everything on an algorithm change.** We must *not* bump it merely for adding a key (§7.3).

### 3.3 Whole-clip pitch — `Clip.pitchShiftSemitones` (subsume, do not parallel)

`Sources/DAWCore/Model.swift:503`, clamped to ±24 (`:554`), Codable-omitted at 0 (`:880`), and part of `StretchRenderCache.Params` (`:26-41`). §7.1 makes the note-edit set an *additional* term on the same render, keyed into the same cache — not a second pitch path.

### 3.4 Segmentation inputs — three, all present

- **Transients.** `AudioEngineProtocol.detectTransients(inFileAt:sensitivity:)`, already content-key cached, already used by take alignment (`Sources/DAWCore/ProjectStore+TakeAlignment.swift:90-93`).
- **Word boundaries.** `clip.transcribe` (m23-n). `ProjectStore.transcriptionSource(clipId:)` (`Sources/DAWCore/ProjectStore+Transcription.swift:42-61`) returns `(audioURL, startSeconds, endSeconds, anchorBeat, tempoMap)` — **source seconds plus the project beat that `startSeconds` sits on**. That is precisely the coordinate space a note-edit set must use (§7.1), which is a happy accident worth locking in. Note the constraint at `:50-52`: **it refuses a clip with `stretchRatio != 1`** (`transcriptionRequiresUnstretchedClip`). Word boundaries must therefore be obtained *before* any timing edit, or the feature silently declines to help exactly when timing correction is in play. Named as a phase-4 sequencing rule in §11.
- **Timing alignment.** `ProjectStore.autoAlignTake(trackID:groupID:laneID:searchWindowMs:apply:)` (`ProjectStore+TakeAlignment.swift:77`) already does whole-lane onset alignment between take lanes. Per-note timing (phase 3) is a *different* operation — intra-clip, not lane-to-lane — and must not re-implement onset detection; it consumes the same `detectTransients` seam.

### 3.5 Undo — `UndoJournal` + `performEdit` coalescing

`Sources/DAWCore/UndoJournal.swift`, entries described at `ProjectStore.swift:8-20`: `seq` increases per journaled edit, `label` for display, `key` the coalescing key (nil = never coalesces). §7.4.

### 3.6 Take groups — the material this feature is *for*

`Sources/DAWCore/Takes.swift:14-21` — **`TakeLane.clip` is a full `Clip`** ("Full take payload in ABSOLUTE timeline beats", `:18-21`), and `TakeGroup.lanes: [TakeLane]` (`Takes.swift:75, 79`). Neither type lives in `Model.swift`; they have their own file.

This is the single most consequential structural fact in the inventory and it defuses the brief's take-group trap almost entirely: **if the edit set lives on `Clip`, take lanes get it for free at the model level**. Persistence comes free too, but by a *different* mechanism than the model — see §7.3, which is where the real work hides. §7.5.

*Correction of record:* an earlier draft of this section cited `Model.swift:899`. That line is `ClipMoveResult.clip`, an unrelated move-result payload. The claim survives at the corrected citation; the citation did not.

### 3.7 Analysis neighbours — and the confirmed absence

`Sources/DAWEngine/Analysis/` holds `TempoEstimator`, `TransientAnalyzer`, `AudioContentAnalyzer`, `MasterMixAnalyzer`, `LiveLoudnessAnalyzer`, `ReferenceAnalyzer`. **No pitch tracker.**

I ran a case-insensitive repo-wide search over `Sources/` for `\bf0\b|pitchDetect|PitchTracker|\byin\b|cepstr|autocorrel|pyin|crepe|rmvpe|swipe`. Every hit was either MIDI note *pitch*, a UI *swipe* gesture, or `Clip.pitchShiftSemitones` plumbing. **No f0 estimator exists.** The coordinator independently searched for f0/RMVPE/CREPE/pYIN/SWIPE/cepstrum/autocorrelation and reached the same conclusion; the searches agree.

**One near-miss worth naming, because it cuts both ways.** `TempoEstimator.swift` already contains a hand-written **biased autocorrelation normalised by lag 0** (`:160`) with local-max candidate picking and harmonic weighting (`:11`, `:21`, `:31`, `:255`). It is *not* reusable for f0 — it runs over a spectral-flux onset envelope at lags of 0.25–2.0 s (tempo), not over a waveform at lags of 1–12 ms (pitch). But it is direct evidence that this codebase has already written, tested and shipped an estimator of exactly this shape, which is part of why §5.3's "write it ourselves" is a schedule estimate rather than a hope.

`signalsmith-linear` (`Sources/CSignalsmithStretch/vendor/signalsmith-linear/`, **MIT**, `LICENSE.txt`) is vendored and compiled with `SIGNALSMITH_USE_ACCELERATE` (`shim.cpp:4-5`), giving a vDSP-backed FFT and STFT already in the build. That is most of what a classical detector needs, with zero new dependencies. §5.

---
## 4. Prior-art decisions in this repo, and whether they transfer

### 4.1 `docs/research/2026-07-05-time-stretch-library-evaluation.md` — the decision does NOT automatically transfer, and here is exactly why

That doc is the record that chose signalsmith-stretch. I read it in full. **Its priority list (lines 6–11) scored three use cases: offline whole-clip stretch/pitch at edit time, real-time preview, and "musical quality on both polyphonic full mixes/stems AND monophonic vocals". Per-note or segmented use appears nowhere in it.**

That matters because note-level correction adds two demands the evaluation never scored:

1. **Time-varying parameter fidelity** — whether the engine can be automated per-block without artefacts. Not a criterion in that doc; answered here in §2.
2. **Monophonic-vocal formant sharpness under a *changing* pitch** — and this is upstream's **self-declared weak spot**. The evaluation itself recorded it (line 18): signalsmith "documents its own limits honestly: … formant correction is 'not as sharp as monophonic algorithms' like PSOLA — worth a directed listening test on ACE-Step vocal stems specifically."

So the M5 choice transfers as a *strong prior*, not as a settled decision. §6 re-makes it on m23-q's own criteria.

### 4.2 The validation that decision was made conditional on was never performed on vocals

This is a genuine finding and it belongs on the record. The 2026-07-05 doc closed with: *"it should be validated, not assumed, against real ACE-Step vocal stems before this becomes final"* (line 38) and made an explicit actionable: *"scope a small vocal-focused listening-test spike (ACE-Step output samples, several semitone/tempo ratios) before marking the library choice final"* (line 48).

The listening spike ran under M5 (ii-e). `docs/ROADMAP.md:69` records what actually happened, verbatim:

> Listening grid (**ACE-Step absent → live-app polySynth phrase, chords+staccato**), 36 cells … **signalsmith-stretch stamped PROVISIONAL-FINAL for 0.75–1.5× (no Rubber Band escalation), human audition pending**

**The grid was run on a polyphonic synth, not on a voice.** The vocal-specific validation the library choice was explicitly conditioned on has not been done, and the stamp is "PROVISIONAL-FINAL … human audition pending". m23-q is the first feature whose entire value depends on vocal timbre under pitch modification. **E2 in §2.4 is therefore not a new demand invented by this spike — it is the outstanding condition on a decision made ten months ago, finally being paid.** Framing it that way is the honest one, and it is why E2 is inside phase 0 rather than deferred.

One related datum from `ROADMAP.md:66` worth carrying into E1: ii-b measured a **0.75× overlap-add overshoot peak of 1.414 from 0.8 input (~+4.9 dB)**; ii-e found it did not reproduce on musical material. A time-varying curve creates locally-varying overlap conditions the ii-e grid never produced, so E1 should record true peak.

### 4.3 `docs/research/2026-07-11-vocals-voice-conversion.md` — owns the boundary, and names f0 methods

This doc chose RVC (MIT core + Applio MIT trainer) and the MLX inference fork, and it is where `vc.convertVocals` and the 8002 sidecar come from. Two things it gives m23-q:

- **The correction/conversion boundary is already drawn there.** Conversion = different voice. §8.4 restates it.
- **It names the f0 extractors the RVC ecosystem uses** (line 65): "multiple pitch extractors (RMVPE default, FCPE, Crepe/Crepe-Tiny)", and (line 67) a real user-facing observation — "the **pitch extractor matters** — RMVPE (the default) 'can sound harsh on non-harmonic voices,' with users recommending FCPE for smoother results". That is about conversion quality, not detection accuracy, but it is a caution against assuming the neural default is automatically best for a *visible* note grid.

**And it contains a trap** (§5.4): those extractors are running *today*, locally, on this machine, inside `scripts/rvc/runtime/`. Reusing them looks free. It is not.

---
## 5. Pitch detection — the actual gap, and the pick

### 5.1 The constraint that actually discriminates

The brief predicted licensing would shape this more than quality would. **That prediction is correct, but it is not the binding constraint on its own.** The binding constraint is a *conjunction*, and every candidate must clear all four:

1. **Shippable in a commercial, closed-source macOS app.** GPL/AGPL is an automatic NO however good it sounds. LGPL is a notarization/hardened-runtime fight the M5 doc already declined to have (line 26).
2. **In-process.** This drives an interactive editor. A Python sidecar round-trip per re-analysis is the wrong architecture (§5.4).
3. **No model weights, or weights we can license and ship.** Weights add hundreds of MB to a bundle, a download-and-verify flow (the M10 HF-asset SHA256 precedent), and a second licensing question that is usually *separate from the code's license* and usually unanswered.
4. **Confidence per frame.** Segmentation (subsystem B) needs voiced/unvoiced and a reliability signal, not just a number. A detector that returns f0 with no confidence forces us to re-derive it, badly.

Accuracy tables come **fourth**, not first, and here is the reason that is defensible rather than lazy: this is an *editor*, not an automatic transcription service. The user sees every detected note and can drag it. A detector that is 96% right with visible, correctable errors beats one that is 98.5% right, ships 300 MB of weights, and cannot be inspected. Melodyne's own workflow is built on the assumption that the user fixes detection errors.

### 5.2 Candidates against the conjunction

> ⚠️ **§5 RECONCILIATION REQUIRED — OPEN, NOT RESOLVED BY THIS DOCUMENT (coordinator, 2026-07-29).**
>
> This section was written without the companion survey, on the mistaken belief that it was empty (see the corrected header note). **The survey's section A independently evaluated one candidate this table does not contain at all: `SwiftF0` (Nieradzik, 2025, arXiv:2508.18440) — `lars76/swift-f0`.** It is absent here, not rejected here.
>
> On the survey's evidence it appears to clear **all four** of the conjunction above, including the one this table uses to eliminate the neural options:
> 1. **License** — **MIT**, confirmed by the surveyor via direct repo fetch 2026-07-29.
> 2. **In-process** — ships as **ONNX**, convertible to Core ML via `coremltools`; runs on-device in Swift with **no Python sidecar**, which is the architecture §5.4 demands.
> 3. **Weights** — **95,842 parameters.** Criterion 3's stated objection is "hundreds of MB to a bundle"; this model is roughly three orders of magnitude smaller than that, so the objection as written does not reach it.
> 4. **Confidence** — emits "pitch estimates in Hz and confidence scores (0.0–1.0) per frame, along with voicing decisions" — precisely the f0 + confidence + voiced/unvoiced shape §5.1(4) requires, without deriving it.
>
> And on the only benchmark either document found (`lars76/pitch-benchmark`), it is rated **Best Overall at 90.2% average** — against **pYIN's 78.7%**, the algorithm this table PICKS and proposes we hand-write.
>
> **The honest caveats, which are why this is filed as a decision and not applied as a correction:** SwiftF0 is a very new (Aug 2025) single-author project, and its accuracy numbers are **self-reported by the same author who built the benchmark it tops** — a real independence problem the surveyor flagged plainly. §5.1's "accuracy comes fourth" reasoning is sound and may well survive contact with it. Maturity risk is a legitimate reason to prefer boring in-house code.
>
> **But that trade was never made, because the candidate was never seen.** The question the seeded milestone must answer before writing a line of pYIN: *are we about to hand-write multiple weeks of DSP that a sub-megabyte MIT model already does better?* Filed as roadmap item **m23-ap**. Until it is answered, treat §5's PICK as provisional and the §11 estimate as carrying that risk.

| Candidate | License (verified) | In-process? | Weights | Confidence | Verdict |
|---|---|---|---|---|---|
| **YIN / pYIN implemented in-house on `signalsmith-linear`** | Our code. `signalsmith-linear` is **MIT** (`vendor/signalsmith-linear/LICENSE.txt`, "Copyright (c) 2025 Signalsmith Audio"). Zero new dependency. | Yes, Swift/C++ in the existing target | None | pYIN's HMM yields per-frame voiced probability natively | **PICK** |
| **pYIN — Queen Mary Vamp plugin** (the reference implementation) | **GPL.** Confirmed: c4dm/qm-vamp-plugins is GPL; QMUL sells a separate commercial licence through its eshop (`https://eshop.qmul.ac.uk/product-catalogue/special-offers/special-offers/pyin-pitch-tracker`). | Would need a Vamp host | None | Yes | **NO** as vendored source. The paid QMUL licence is a live fallback if in-house pYIN underperforms — same shape as the Rubber Band fallback. |
| **librosa `pyin`** | ISC (`librosa/LICENSE.md`) — permissive | **No** — Python | None | Yes | **NO** for shipping; **YES** as the offline *reference oracle* for our test fixtures (§5.5) |
| **WORLD (`mmorise/World`) — Harvest / DIO** | **Modified (3-clause) BSD**, verified by fetching `LICENSE.txt` (2026-07-29): the "Redistribution and use in source and binary forms" / "Neither the name of the M. Morise" clauses. Upstream also states there is no patent in any of its algorithms. | Yes — plain C++, no exotic build; the vendoring shape is identical to signalsmith's | None | Harvest returns f0 + a voicing/aperiodicity path | **STRONG SECOND.** The one to take if in-house YIN/pYIN misses. |
| **CREPE** (`marl/crepe`) | Code **MIT** (verified, `LICENSE`, "Copyright (c) 2018 Jong Wook Kim"). **Weights' licence not separately stated in that file — I did not verify it and will not assume the code licence covers the model.** | No — TensorFlow/Torch. CoreML conversion is a project of its own | ~85 MB (full) | Yes, per-frame | **NO** for v1 |
| **RMVPE** (`Dream-High/RMVPE`) | **Apache-2.0** (verified, `LICENSE`). Weights again a separate question. | No | Yes | Yes | **NO** for v1. Also: trained for pitch in *polyphonic* music — solving a harder problem than we have, and the m23 voice-conversion doc records users finding it "harsh on non-harmonic voices". |
| **SWIPE′** | Reference implementations vary; **I did not verify a specific artefact's licence** | — | None | Yes | Not pursued — no advantage over pYIN that justifies the verification work |
| **Apple `SNAudioAnalysis` / `AVFAudio` / vDSP** | System framework, zero licence risk | Yes | n/a | n/a | **Not applicable.** vDSP is a primitive library, not a pitch tracker, and we already reach it through `signalsmith-linear`. SoundAnalysis ships sound *classification*, not f0. **I found no Apple-supplied monophonic f0 estimator.** |

### 5.3 The pick, and why it is not a cop-out

**Implement pYIN in-house, in Swift + the existing MIT `signalsmith-linear` FFT, as `Sources/DAWEngine/Analysis/PitchTracker.swift`.**

The reasoning:

- **The licence question disappears entirely.** No fourth-party artefact, no weights, no GPL trap, nothing to re-verify at ship time. Given that licensing is the constraint most likely to kill a choice late, removing it is worth real accuracy.
- **The algorithm is well-specified and small.** YIN is a difference function + cumulative mean normalisation + parabolic interpolation over a lag range; on a 48 kHz vocal with an 80–1000 Hz search range that is a few hundred lines. pYIN adds a set of candidate thresholds with prior weights and a Viterbi decode over a pitch-state HMM — that is where the octave-error robustness and the voiced probability come from, and it is the part worth doing properly rather than shipping bare YIN.
- **It is offline and unconstrained.** No RT budget, no allocation limit (`StretchRenderCache`'s detached-task lane, §3.2). We can afford autocorrelation over generous lag ranges and a full Viterbi pass.
- **The `signalsmith-linear` FFT is already Accelerate-backed** (`shim.cpp:4-5`, `SIGNALSMITH_USE_ACCELERATE`), so the expensive part is already vectorised and already in the build.
- **It gives per-frame confidence natively**, satisfying constraint 4 without a second mechanism.

**The case against this pick**, stated because a pick without one is not a decision:

- *We are writing DSP we could have vendored.* True. WORLD's Harvest is BSD, weights-free, and battle-tested in the vocoder/SVC world. **If pYIN's measured accuracy on the §5.5 fixtures misses the bar, take Harvest — that is a vendoring exercise, not a redesign.** The estimate in §11 carries this as a bounded risk, not an open one.
- *Neural detectors are more accurate on hard material* (noisy, breathy, heavily-processed vocals). True, and irrelevant to a v1 whose input is a dry recorded or RVC-produced vocal and whose output is user-correctable. Revisit if users report detection pain on real material; the model layer is behind a protocol either way (§7.6).
- *"Implement a published algorithm" is where schedules go to die.* Real risk. Mitigated by §5.5 — a fixture-based accuracy gate written before the implementation, with librosa as the oracle — and by the fact that phase 1 (§11) ships something useful even with a plain-YIN-quality detector.

### 5.4 The RVC-sidecar reuse temptation — a documented rejection, not an omission

RMVPE, FCPE and CREPE weights are **already installed and running on this machine**, under `scripts/rvc/runtime/src/` (confirmed by read-only listing: `tools/convert_rmvpe_weights.py`, `tools/convert_crepe_weights.py`, `src/test_all_f0_methods.py`, `rvc/realtime/pipeline.py`). The sidecar is a FastAPI app on 127.0.0.1:8002 exposing `/health`, `/v1/voice/list`, `/v1/voice/{id}/status`, `/v1/voice/convert`, `/v1/voice/train` (`scripts/rvc/server.py:199-368`). Adding `/v1/pitch/detect` looks like an afternoon.

**Reject it, for two independent reasons, either of which is sufficient:**

1. **It requires editing a forbidden path.** `scripts/rvc/` contents are off-limits under this repo's standing constraints. An f0 endpoint means editing `scripts/rvc/server.py`. **That needs explicit user sanction and cannot be assumed by an implementing agent.**
2. **Even fully sanctioned, it is the wrong architecture.** A note editor re-analyses on segment split/merge, on undo, on re-open. A Python process round-trip — plus sidecar liveness, plus a `pip` environment the user must have installed, plus a 500 when it is down — turns an interactive edit into a distributed-systems problem. It also makes note detection **silently unavailable** to any user who never installed the RVC sidecar, for a feature that has nothing to do with voice conversion.

The honest summary: the weights being present is a coincidence of a neighbouring feature, not a substrate.

### 5.5 How the detector gets verified (write this gate before the code)

- **Fixtures**: synthetic first — sine sweeps, vibrato at 4/5/6 Hz, an octave leap, a glide, and a silence/breath gap — where ground truth is exact and an error is a number, not an opinion. Then a small set of real dry vocal phrases from the repo's existing ACE-Step/RVC material.
- **Oracle**: `librosa.pyin` (ISC, Python, dev-time only — never shipped) run once offline to produce a reference contour committed as a fixture. This is the standard way to test a reimplementation without shipping the reference.
- **Bar**: on synthetic material, ≥99% of voiced frames within ±10 cents and **zero octave errors**; on real vocals, ≥95% of voiced frames within ±25 cents of the oracle, gross-error (>50 cents) rate under 2%, and voiced/unvoiced agreement ≥95%.
- **Kill criterion**: bar missed after one round of tuning ⇒ vendor WORLD Harvest (BSD) behind the same protocol. Budgeted in §11.

### 5.6 RECONCILIATION — the SwiftF0 decision (m23-ap, 2026-08-03, `daw-architect`)

> **STATUS: RECOMMENDATION AWAITING THE USER'S SIGN-OFF. NOT SETTLED.**
> A new vendored artefact of this weight is the user's call, not a cycle's — the same standing rule recorded for **m23-n3c** ("the pick is the user's, no cycle may resolve it"). **Nothing has been vendored, downloaded, converted, or added to the build by this amendment. It changes this one file and no code**: no `Package.swift` edit, no `Models/`, no `.gitignore` entry, no dependency. §5.1–§5.5 above are left exactly as written — they are the record of what was decided on 2026-07-29 and why — and the ⚠️ notice in §5.2 stays as the flag that produced this subsection.

#### 5.6.1 The decision

**Vendor SwiftF0 (`lars76/swift-f0`, MIT) as the primary detector. Demote in-house pYIN from "the PICK" to the named fallback, off the critical path.**

**The one line:** pYIN loses to SwiftF0 on *every* metric that discriminates for this subsystem, and the one that breaks the tie is not the accuracy headline — it is **voicing recall 0.633 vs 0.871** (F1 0.731 vs 0.885). §5.1 criterion 4 exists to serve segmentation (subsystem B). A detector that misses **a third of voiced frames** is a segmentation defect, and the "it is an editor, the user drags it" argument of §5.1 does not cover it: the user cannot drag a note that was never proposed. §5.1's reasoning survives contact with SwiftF0 in general — accuracy *is* fourth — but it was applied to a candidate that also happens to win on criterion 4 itself, which is first-class.

**What does NOT change:** §5.1's conjunction (all four criteria still binding, and SwiftF0 clears all four); §5.4's rejection of the RVC-sidecar route (below, 5.6.9); §5.5's existence as a gate written before the code; §7.6's absolute prohibition on pitch DSP reaching the render thread; §7.8's "one home" list.

#### 5.6.2 The criteria, re-run against the candidate §5.2 never saw

| §5.1 criterion | SwiftF0 | Verdict |
|---|---|---|
| 1. Commercial closed-source shippable | **MIT**, and — the part that matters — **`swift_f0/model.onnx` is a tracked blob inside that same MIT repo**, so the weights fall under the repo `LICENSE` rather than being a separate, unstated grant. **This is precisely why §5.2's CREPE objection ("weights' licence not separately stated … I will not assume the code licence covers the model") does not reach this candidate.** Verified by listing the repo tree via the GitHub API, 2026-08-03. | **PASS**, and on the exact axis that eliminated the other neural options |
| 2. In-process, no Python sidecar | Achievable, but **not by the route §5.2's notice claims** — see 5.6.3. Three real routes, one with a shipping-app witness. | **PASS**, at a higher integration cost than the notice implied |
| 3. No weights, or weights we can license and ship | **397,987 bytes** — the measured size of `swift_f0/model.onnx`, not an estimate. Criterion 3's stated objection is "hundreds of MB". This is 0.39 MB. | **PASS**, by three orders of magnitude |
| 4. Confidence per frame | The ONNX graph returns **two** tensors, `pitch_hz` and `confidence`; **voicing is derived, not emitted** — `_compute_voicing` in `swift_f0/core.py` is `confidence > DEFAULT_CONFIDENCE_THRESHOLD (0.9)` plus an `fmin`/`fmax` range check. Criterion 4 still passes and the derivation is three lines of Swift, but §5.2's notice ("emits … voicing decisions") overstates it: that is the *Python package's* API, not the model's output head. | **PASS**, with the wording corrected |

#### 5.6.3 Every figure in the §5.2 notice, checked against source — including one that does NOT hold

Re-verified 2026-08-03 against the live upstream, not against the survey's summary of it.

- ✅ **90.2% average vs pYIN's 78.7%** — HOLDS, verbatim, in the current `lars76/pitch-benchmark` README (fetched 2026-08-03), which has been re-run since the survey read it.
- ✅ **95,842 parameters** — this is **the paper's claim** (arXiv:2508.18440 abstract), corroborated but not independently derived: I measured the artefact (397,987 bytes), not the graph. Stated as such.
- ✅ **MIT** — HOLDS. GitHub API reports `MIT` for the repo, and the model file is inside it (5.6.2).
- ✅ **f0 + confidence per frame** — HOLDS. **Voicing: derived, not emitted** (5.6.2).
- ❌ **"ONNX → Core ML via `coremltools`" — DOES NOT HOLD ON TODAY'S TOOLING.** `coremltools`' ONNX converter was deprecated at coremltools 6 with users directed to the unified TensorFlow/PyTorch API, and the standalone `onnx-coreml` package is frozen and explicitly unmaintained. The current Core ML Tools "supported source frameworks" list is TensorFlow 1/2, PyTorch, LibSVM, scikit-learn and XGBoost — **ONNX is not on it.** SwiftF0 publishes **only** ONNX weights (no PyTorch checkpoint, and **no training code** — issue #4, unanswered), so there is no upstream artefact for the supported conversion path to consume. *(The deprecation is pinned to coremltools 6 and the absence from the current supported-source list is pinned; no exact removal version is asserted.)*
- ⚠️ **"Best Overall at 90.2%" must not stand alone.** The benchmark's own TL;DR reads **"Best Human singing: RMVPE (87.2%, best on Vocadito and MIR-1K)"**, and SwiftF0's average lead is partly carried by NSynth (89.3 vs RMVPE's 68.2) and PTDBNoisy — instrument and noisy-speech material, not singing. **The honest framing for a vocal editor is the singing columns against the algorithm we would otherwise hand-write, and there SwiftF0 still wins decisively: MIR1K 95.0 vs pYIN 91.2, Vocadito 92.6 vs pYIN 79.5.** Vocadito is solo vocal recordings — the *cleanest* form of our actual input — and pYIN is 13.1 points down on it.

**The detail table (`benchmark_report.md`, fetched 2026-08-03) is more damning for pYIN than the headline, and this is the material neither prior document had:**

| Metric | SwiftF0 | pYIN | Note |
|---|---|---|---|
| Voicing F1 (precision / recall) | **0.885** (0.903 / **0.871**) | 0.731 (0.913 / **0.633**) | **The tie-breaker.** §5.1(4)'s whole purpose. |
| Cents error ↓ | **35.4** | 62.9 | Best of 12 vs mid-field |
| RMSE (Hz) ↓ | **25.1** | 41.2 | |
| **Octave error** ↓ | **0.012** | 0.032 | SwiftF0 is **best of all 12 algorithms**; see 5.6.5 for why that is not the whole story |
| Gross error ↓ | **0.017** | 0.041 | |
| Contour smoothness rank ↓ | **4.5** (tied best) | **8.0** (2nd worst) | Directly relevant: the contour *is* the transpose curve fed to §6's resynthesis. A jittery contour is a jittery render. |
| RPA ↑ | 0.905 | 0.878 | CREPE leads here (0.928) — reported for fairness |

#### 5.6.4 Maturity as of 2026-08-03 — the one fact neither prior document could have had

Both documents wrote their caveat on 2026-07-29 about "a very new (Aug 2025) single-author project." It is now ~11 months later than that project's last commit. Measured, not inferred:

**Upstream is dormant.**
- `lars76/swift-f0`: created 2025-07-08; **last commit 2025-09-02**; **8 commits total, every one by `lars76`** (the contributors API returns exactly one entry); **zero GitHub releases**; one tag (`v0.1.1`) though the code is at 0.1.2; 176 stars, 22 forks, 3 open issues. Last PyPI release **0.1.2, 2025-07-24**.
- Open issues and their age: **#1** (2025-08-30, Hugging Face offering to host the checkpoint and the SpeechSynth dataset) — **never answered, 11 months**. **#3** (2025-10-16, opset-18 request) — answered in 2 days with a zip, still open. **#4** (2026-08-01, *"Request for training code or training details"*) — **unanswered**. **#2** (2025-09-02, ONNX graph simplification) — answered *and fixed the same day*.
- The paper is **arXiv v1, 2025-08-25, never revised, no `journal_ref`, no venue** (arXiv API, 2026-08-03). At ~11.3 months it remains an **unreviewed preprint**.
- Semantic Scholar returns **2 citing papers**, both 2026, both *tool use* rather than evaluation: a TTS-evaluation paper (arXiv:2606.31729) whose citation context reads *"f0 correlation computed with SwiftF0 [34]"*, and CHI 2026's *FlueBricks* (arXiv:2604.03636, DOI 10.1145/3772318.3790595). **No independent benchmark, and no reproduction of the accuracy claims by anyone unaffiliated.**

**Argue dormancy correctly rather than fearing it.** Eleven idle months on an *evolving library you depend on* is a maintenance risk. Eleven idle months on a **frozen 389 KB MIT blob you vendor** is close to a feature — the same property that makes `signalsmith-stretch` v1.3.2 (`57b93f4`) safe to pin in §6. We would be vendoring a file, not depending on a maintainer. **The two genuine losses are specific and should be stated as such: (a) training code was never released, so we can neither retrain, fine-tune, nor audit how the model was produced; (b) no third party has re-run the benchmark end to end.**

**The self-benchmarking objection is weaker than it was on 2026-07-29, and this is the single strongest new fact.** The benchmark has been **audited by a hostile-interest party, and the maintainer shipped the correction against his own model**: on 2025-09-01 `yxlllc` — who trained the RMVPE checkpoint the benchmark used — filed `lars76/pitch-benchmark` issue #3 with four specific implementation defects (wrong window length, wrong hop, wrong threshold, fp16 vs fp32 checkpoint); `lars76` engaged substantively the same day, `yxlllc` submitted PR #4, it was **merged within ~2 hours**, all benchmarks were re-run, and **RMVPE moved to 2nd overall and took "best on human singing" (MIR1K, Vocadito) away from SwiftF0.** The benchmark also carries third-party contributions (`korguchi`, +DIO/Harvest via pyworld, merged 2026-03-28) and is still being engaged with (issue #6, 2026-06-09). That is not independent *reproduction* — nobody has re-run the suite from scratch — but it is materially better than "unaudited", and the numbers the survey quoted are **post-correction**.

**Third-party production adoption is real, and includes an Apple-platform, in-process, shipping case.** GitHub code search: **26** hits for `from swift_f0`; **187** issues/PRs mentioning it outside the author's own repos.
- **`baijum/ukulele-companion`** — a shipping iOS + Android app: `iosApp/setup_onnxruntime.sh`, `docs/spec/22-neural-pitch-supervisor.md`, and PR #174 (2026-06-08) loading the model on iOS inside `Task.detached(priority: .userInitiated)` with `SwiftF0 Loading… / Active / Fallback` UI states. **This is the existence proof for criterion 2: SwiftF0 running in-process in a Swift app — via ONNX Runtime, not Core ML.**
- **`rakuri255/UltraSinger`** — karaoke transcription on *sung vocals*, our exact material; a fork PR (2026-07-05) reads *"Revert default pitcher to swiftf0"*, i.e. it is the default.
- **`musicmuni/voxatrace`** — commercial music-education pitch product, JNI bindings, docs and JVM demo apps.
- **`kjranyone/RCWX`** PR #4 (2026-07-23): *"SwiftF0デフォルト化"* — made default. Also `SoulMelody/anyf0`, `tan90xx/distillw2n`, `gzivdo/pitch-core`, `Alok2221/Vocal2MIDI-Live`, `NewComer00/expressive`.
- Ports exist (`jhartquist/candle-pitch` in Rust; `a5632645/swift_f0_cpp` in C++) but **none is a credible dependency** — the C++ one is a one-day experiment, 0 stars, **no licence**. Named so nobody mistakes them for a vendoring target. Its one useful datum: ~38% of a laptop CPU core for *real-time* operation, which is irrelevant to us and reinforces §7.6 — **this detector is offline machinery, exactly like everything else in this milestone.**

#### 5.6.5 The strongest counter, in its sharpest form — and why it does not reverse the pick

The sharp version is **not** "SwiftF0 makes octave errors": in aggregate it makes the *fewest* of the twelve algorithms measured (0.012, 5.6.3). It is this:

> **`Alice-Sabrina-Ivy/Syrinx` #81 (2026-06-10) reports that on weak-fundamental low-F0 phonation (H2 louder than H1) in the 80–110 Hz register, SwiftF0 read 2×F0 on 25.6% of frames (49% correct, 19.1% null) — and the octave-up frames carried the *same confidence distribution as the correct ones* (median 0.82), so no threshold could separate them.** The project had replaced pYIN with SwiftF0 a month earlier (#75, 2026-05-07) and reverted to a Praat-style autocorrelation tracker. The stated mechanism is spectral H1−H2 dominance (correct frames +12 dB median, octave-up frames −3 dB).

**Why this matters more than a benchmark row:** it makes criterion 4 **partially hollow on that register**. Segmentation is designed to gate on confidence (survey §B failure mode 3; §5.1(4)); a confidently-wrong octave is invisible to that gate. And this is *our* material — the survey's own open question 9 names low male voices and "grit" as the case Logic's Flex Pitch is reported to fail on, and tells us to test there specifically.

**Why it does not reverse the pick, stated with its provenance:**
1. **Provenance is one agent-authored PR body in a small repository.** The mechanism (H1/H2 dominance defeating a spectrogram-input CNN) is physically coherent and independently checkable; the numbers are not independently verifiable. It is **not** a hit piece — the same table reports SwiftF0 *winning* on vocadito (97.8 vs 95.0) and FDA (90.3 vs 84.2), and it corrects a measurement error that had previously *understated* SwiftF0 on PTDB (74.5 → 88.0%).
2. **In an editor an octave error is visible and one drag fixes it** — this is exactly the case §5.1's "accuracy comes fourth" reasoning was written for, and here it genuinely applies. A *missing* note (voicing recall 0.633) is the error class that argument does not cover; a *wrong-octave* note is the class it does.
3. **The alternative is not immune.** pYIN's whole design purpose is octave robustness and it still measures 0.032 — 2.7× SwiftF0's rate — while a from-scratch implementation would have no measured octave behaviour at all until we produced one.

**So it becomes a gate requirement, not a rejection. §5.5 gains a named leg:**

> **§5.5 new fixture leg (low-F0 weak-fundamental).** Male/low-register phonation in the **80–110 Hz** band with **H2 > H1**, synthetic first (where the H1/H2 balance is a dial and ground truth is exact), then real. **Ceiling: octave-error rate ≤ 2% of voiced frames, AND no octave-up frame may carry confidence above the median confidence of correct frames** — the second clause is the one that tests the actual claim. Failing this leg does **not** re-open the pick; it triggers the mitigation below.
>
> **Mitigation if that leg fails — contingent, deliberately NOT pre-decided:** an autocorrelation-based *octave sanity check* over the detector's own output (autocorrelation recovers the period regardless of which partial dominates, which is why the Praat-class trackers did not fail in the report above), used only to verify-and-halve, never to track. Cost ≈ **+0.5 week**, on `signalsmith-linear`'s existing Accelerate-backed primitives (§5.3's reasoning about vDSP transfers intact). **This is named as a costed contingency on a measurement nobody has made yet — it must not be built speculatively, and if it is built it lives in the one detector home, not as a second tracker.**

Second, weaker real-world report, recorded for completeness: `walterfr/UltraStarKaraokeMaker` #7 (2026-07-17) finds SwiftF0's contour anti-correlated with ground truth on two densely-produced songs after stem separation (2% of notes within 2 semitones), and explicitly names two unseparated suspects — the extraction *or* the metric. **Undiagnosed; do not weigh it as a finding.** It is relevant only as a reminder that our input is a dry or RVC-produced vocal (§8.1), not a stem cut out of a dense mix.

#### 5.6.6 What this changes in the plan

**The integration route is an open sub-decision, and the notice's answer to it was wrong (5.6.3).** Three routes, ranked by *evidence status*, not by preference:

| Route | Status | Cost / risk |
|---|---|---|
| **A. ONNX Runtime in-process** via Microsoft's official `onnxruntime-swift-package-manager` (**MIT**, release **1.24.2**, 2026-02-25; upstream `microsoft/onnxruntime` is MIT and actively maintained) | **The only route with a shipping-app witness on Apple platforms** (`baijum/ukulele-companion`, 5.6.4) | Works, licence-clean — but drags a **large binary runtime** into a bundle whose entire competing option is 389 KB, and adds a second inference stack the app otherwise does not have. This is a dependency the user may well decline on size grounds alone. |
| **B. Dev-time ONNX → PyTorch → Core ML**, committing a small `.mlpackage`; **no inference dependency ships** | **Plausible and UNVERIFIED.** I have not checked that any converter handles this graph, nor that the result is numerically equivalent. | Architecturally the best fit (nothing new links; Core ML is a system framework). **Must not be nominated as preferred until a fidelity spike proves it.** Contingency: the in-repo model is **opset 20**; an opset-18 variant exists **only as an attachment on GitHub issue #3** — fragile provenance if a converter needs it, irrelevant if it does not. |
| **C. Hand-port the graph** onto Accelerate/BNNS/MPSGraph, reading the ONNX weights | Feasible in principle at 95,842 parameters and a plain STFT + 2D CNN | Re-creates the "we are writing DSP" cost the pick was meant to remove, and creates a second home for the model. **Fallback of last resort.** |

> **⚠️ REQUIRES FULL XCODE — flagged per the standing obligation, same convention as §8.2.** Neither route changes the pick; both change what the spike must confirm. **Route B**: compiling a committed `.mlpackage` to `.mlmodelc` is Xcode build-system tooling and is **not available under Command Line Tools** — so route B needs either a pre-compiled artefact produced once on a full-Xcode machine and committed, or `MLModel.compileModel(at:)` at first run (which moves the cost to the user's machine and needs a cache + failure path). **Route A**: embedding an xcframework lands in this repo's *existing* bundling/signing full-Xcode territory rather than adding new territory. **Check `xcodebuild -version` before either.**

**Prerequisite: a conversion/fidelity spike that settles A vs B and proves numerical equivalence against the Python package on the §5.5 fixtures.** Ratification of this recommendation is ratification of *running that spike*, not of a particular runtime.

**Where the spike belongs: phase 0, alongside E1 and E2 — not inside phase 1.** §11.2 says of phase 0 that *"this phase exists **to** absorb the risk"*, and this spike has a kill criterion and gates a structural choice, which is the same shape as E1/E2. Relocating it costs nothing: **phase 0 becomes 1–1.5 wk, phase-1 sub-item (1) drops to ~1 wk, and phase 0 + 1 stays at 4–4.5 wk either way** (5.6.7). The reason to prefer the relocation is §11.4's own argument — the ladder should run *before* anything is built on top of it.

**The one home does not move.** §5.3 named `Sources/DAWEngine/Analysis/PitchTracker.swift`. **That file stays the single home for detection**; it now wraps a vendored artefact instead of containing a hand-written algorithm. Decimation, framing, timestamps, the confidence threshold and the voicing derivation all live behind it. **Do not create a second file for "the SwiftF0 wrapper" beside it** — that would re-create exactly the kind of second home §7.8 exists to forbid.

**Concrete integration facts, read from `swift_f0/core.py` (2026-08-03), that the implementing milestone must plan around:**
- `TARGET_SAMPLE_RATE = 16000` — our audio is 48 kHz, so **a 3:1 decimation with proper anti-aliasing is mandatory input conditioning**. This repo already has an SRC story worth reusing rather than re-deriving: `AudioEngine.projectSampleRate` and the m20-b/m20-d output-edge conversion work (m20-b measured that edge at +0.004 ms). Note this is *offline analysis* conditioning — it does not touch the live graph and must not acquire a second rate home.
- `HOP_LENGTH = 256` at 16 kHz ⇒ **62.5 frames/s, 16 ms per frame.** **This is finer than §6's ~30 ms resynthesis hop, so detection is not the limiter §2.4's E1(c) worried about** — the analysis grid is denser than the grid we can act on, which is the right way round.
- `MODEL_FMIN = 46.875 Hz`, `MODEL_FMAX = 2093.75 Hz` (G1–C7) — covers the full sung range including bass and soprano, and is *wider* than §5.3's proposed 80–1000 Hz pYIN search. Note that 5.6.5's failure register (80–110 Hz) sits well inside the supported range, so it is a model-behaviour question, not a range question.
- `DEFAULT_CONFIDENCE_THRESHOLD = 0.9` produces **deliberate gaps** where the model declines to commit; the author states that post-processing to close them *reduced* benchmark accuracy. Segmentation must treat holes as signal (survey §B failure mode 3), not as something to fill. A third party lowered the threshold to 0.7 for a different application — **the threshold is ours to tune against the §5.5 fixtures, and it belongs in the one detector home.**
- `swift_f0/music.py` ships `segment_notes()` / `export_to_midi()`. **Do NOT adopt it.** It splits on pitch deviation and unvoiced runs — precisely the naive scheme survey §B failure mode 1 says will chop vibrato into fragments. Subsystem B remains ours to design. Recorded here only so an implementer does not "discover" it and shortcut §B.

**§5.5's gate survives and changes role, which is the most important consequence for the implementer.** It was written to validate *code we wrote*, with `librosa.pyin` as the reimplementation oracle. It now validates a *vendored artefact plus our wrapper*, so:
- The bar and the fixtures stay (synthetic sweeps, vibrato at 4/5/6 Hz, octave leap, glide, silence/breath gap; then real dry vocal phrases), **plus the new low-F0 leg of 5.6.5**.
- **The highest-value new test is Swift-vs-Python parity: identical WAV in, our in-process path vs the upstream `swift-f0` package, compared frame-for-frame.** That is what catches the errors this route actually makes — decimation, framing/timestamp alignment, opset or converter drift, threshold mismatch — and none of them are errors `librosa.pyin` can see.
- `librosa.pyin` stays as a *second opinion* on the fixtures, dev-time only, never shipped (unchanged from §5.5). It is no longer the oracle for a reimplementation, because there is no longer a reimplementation.

**pYIN's new status:** the fallback, not the plan. §5.3's reasoning for it remains correct and is why it is a *credible* fallback — no licence question, no artefact, well-specified algorithm, native confidence. It simply is not worth 2–3 weeks up front to arrive at a detector that measures worse on our material on every axis we care about. **The §5.2 table's `PICK` cell and §0's "Named detector" line should be read as superseded by this subsection** (left in place deliberately, per the no-rewrite rule).

**Fallback ladder, replacing §5.5's single kill criterion:** SwiftF0 → (low-F0 leg fails) octave sanity check, +0.5 wk → (still fails, or the fidelity spike finds no acceptable in-process route and the user declines the ORT dependency) in-house pYIN exactly as §5.3 specifies, at §11's original cost. **Note that WORLD Harvest — the currently-named fallback in §5.5/§11 — has no number in the only benchmark either document found** (DIO/Harvest were added to the suite in March 2026 but do not appear in the published results table). Its accuracy on our material is unmeasured; that does not disqualify it, but it must not be cited as a *known-good* escape hatch.

#### 5.6.7 Effect on §11 — a re-shape, not a subtraction

§11.2's phase-1 sub-item (1) — *"`PitchTracker` — pYIN on `signalsmith-linear`, with the §5.5 fixture gate"*, called out there as **"the only one without precedent and … the bulk — 2–3 weeks"** — is replaced, not deleted. Do not read this as "removes 2–3 weeks." What replaces it:

| Replacement work | Estimate |
|---|---|
| Conversion / fidelity spike: settle route A vs B (5.6.6), produce an in-process artefact, prove numerical equivalence vs the Python package on the §5.5 fixtures. **Real chance of falling back to the heavier route.** | 0.5–1 wk |
| Swift wrapper: 48 k → 16 k anti-aliased decimation, framing and timestamp alignment, confidence threshold + fmin/fmax voicing derivation, the detector protocol seam (§7.6 keeps the model layer behind a protocol either way) | 0.5 wk |
| §5.5 gate — unchanged in existence, changed in role, **plus** the low-F0 leg and the Swift-vs-Python parity comparison | 0.5 wk |
| **Sub-item (1) total** | **1.5–2 wk** (was 2–3) |

*The table books the spike against sub-item (1) so the line is directly comparable with §11.2's own "2–3 weeks" for the pYIN item. **5.6.6 recommends running it as a phase-0 leg instead; that moves 0.5–1 wk from phase 1 to phase 0 and leaves every total below unchanged.***

**Phase 1: 4–5 wk → 3.5–4 wk. Phase 0 + 1 (first shippable value): 4.5–5.5 wk → 4–4.5 wk. Full subsystem: 14.5–19.5 wk → 14–18.5 wk.** Sub-item counts are unchanged (5 for phase 0+1, 15–16 total) — the spike replaces the pYIN item rather than adding one. The arithmetic is shown so a reader can disagree with the inputs rather than with the conclusion.

**Contingencies (§11.3) change shape:** the "+1 week to escalate to WORLD Harvest" line is superseded by the ladder in 5.6.6 — **+0.5 wk** for the octave sanity check, and only if *both* the low-F0 leg fails *and* that check fails does the original **+2–3 wk** pYIN cost return. The Rubber Band contingency (+2 wk, £590–£1,490) is untouched.

**But the tail gets WORSE, and saying otherwise would be false. The ladder is cumulative: the SwiftF0 route front-loads sunk cost that the pYIN fallback does not recover.**

| | Detector work, worst case | Full subsystem, worst case (detector ladder only) |
|---|---|---|
| §11.3 as written | 2–3 (pYIN) + 1 (Harvest) = **3–4 wk** | **15.5–20.5 wk** |
| This recommendation | 1.5–2 (spike + wrapper + gate, already spent) + 0.5 (octave check) + 2–3 (pYIN returns) = **4–5.5 wk** | **16.5–22 wk** |

**So: expected case ~1 week better, worst case ~1–1.5 weeks worse.** That trade is still right, and the reason is not the mean — it is *where the risk sits*. §11.3's version puts 2–3 weeks of unwritten Viterbi DSP with no measured behaviour on the critical path and only discovers whether it clears the §5.5 bar at the end of it. This version spends 0.5–1 week on a spike with a binary answer, against an artefact whose behaviour on our exact datasets is already published and partially audited. **A worse tail bought with a much earlier and cheaper falsification point is a good trade for a subsystem this size — but it is a trade, and an implementer planning the milestone must budget it as one.**

**The more valuable change is the risk shape, not the number.** §11.4 states *"E2 is the only architecture risk"* and lists the detector as bounded schedule risk. **That claim gets stronger, not weaker:** unwritten DSP with no measured behaviour is replaced by a vendored artefact with published, partially-audited numbers on our exact datasets, and the residual risk moves to an *integration* question (route A vs B) that a half-week spike answers definitively. **§11.4's conclusion stands unchanged: E2 — the perceptual quality of time-varying signalsmith-stretch on a real voice — remains the largest and only architecture risk, and phase 0 still runs first.**

#### 5.6.8 What would reverse this recommendation

Discriminating conditions, each falsifiable and none of them a matter of taste:

1. **The user declines.** This is a recommendation; a new vendored artefact is their call (5.6 header). No further justification is needed or should be sought.
2. **The §5.5 low-F0 leg fails past its stated ceiling** (5.6.5) **and** the octave sanity check does not recover it. Then the confidence signal is not trustworthy on a register we must support, criterion 4 fails in substance rather than in form, and §5.3's pick returns at §11's original cost.
3. **The fidelity spike cannot produce an in-process artefact without vendoring ONNX Runtime, and the user rejects a dependency that size.** Route C (hand-port) then competes directly with in-house pYIN on effort, and pYIN wins that comparison on "no fourth-party artefact at all."
4. **Ship-time licence re-verification fails** — i.e. the repo's `LICENSE` no longer covers `model.onnx`, or upstream restates the weights' terms. 5.6.2 is a 2026-08-03 reading and **must be re-verified at ship time, exactly as §9 requires of every row.**
5. **An independent reproduction contradicts the benchmark materially.** None exists today (5.6.4). If one appears and moves SwiftF0 below pYIN on cents error, voicing recall or octave rate on singing material, this decision should be re-run against it.

**What would NOT reverse it:** upstream staying dormant (we are vendoring a frozen file — 5.6.4); the paper never being peer-reviewed (the artefact's measured behaviour on our fixtures is what we ship against, not its citation count); RMVPE outscoring SwiftF0 on singing (RMVPE is rejected on architecture in §5.4, not on accuracy — see below).

#### 5.6.9 Loose ends this subsection deliberately does not fix

- **§5.4's rejection of the RVC-sidecar / RMVPE route stands, and is unaffected by RMVPE now being "best on human singing."** Both of §5.4's reasons are architectural and neither is an accuracy claim: it requires editing a forbidden path (`scripts/rvc/`, user sanction required), and a Python round-trip per re-analysis is the wrong shape for an interactive editor. **A better accuracy number does not touch either.** Stated explicitly so a reader arriving at RMVPE's 96.4% Vocadito does not reopen a closed decision.
- **The survey and this document disagree on RMVPE's licence** because they checked *different repositories* — the survey found `yxlllc/RMVPE`'s LICENSE 404 and left it UNCONFIRMED; §5.2/§9 fetched `Dream-High/RMVPE` and read Apache-2.0. Both readings are correct about the repo each read. Pointer only; RMVPE is rejected on architecture either way and resolving it is not this item's job.
- **§13's source list still describes the survey as "(skeleton, all `TODO:`)"** — the same false belief the line-10 header note already withdrew, surviving in a second place. **Noted, not edited**, per this amendment's one-addition scope. Anyone reading §13 should read line 10 first.
- **§0's "Named detector" bullet and §5.2's `PICK` cell are not rewritten** — they are the 2026-07-29 record. This subsection supersedes them on ratification.

#### 5.6.10 Sources for this subsection (all fetched or queried 2026-08-03)

- `lars76/swift-f0` — repo metadata, commit list, contributors, releases/tags, issues #1–#4, and the recursive file tree giving `swift_f0/model.onnx` = **397,987 bytes** (GitHub API). https://github.com/lars76/swift-f0
- `swift_f0/core.py` (raw fetch) — `TARGET_SAMPLE_RATE`, `HOP_LENGTH`, `MODEL_FMIN`/`MODEL_FMAX`, `DEFAULT_CONFIDENCE_THRESHOLD`, `_compute_voicing`, and the two-tensor model output. `CHANGELOG.md` (0.1.0 → 0.1.2). https://raw.githubusercontent.com/lars76/swift-f0/main/swift_f0/core.py
- PyPI `swift-f0` — release history, last upload 0.1.2 on 2025-07-24. https://pypi.org/pypi/swift-f0/json
- `lars76/pitch-benchmark` — current `README.md` (overall table, TL;DR recommendations) and `benchmark_report.md` (voicing precision/recall/F1, RPA/RCA/cents/RMSE/octave/gross error, smoothness); repo metadata and contributors; issues #2, #3, #6 and PR #4 (the `yxlllc` RMVPE correction, merged 2025-09-01). https://github.com/lars76/pitch-benchmark
- arXiv API for 2508.18440 — v1 published 2025-08-25, never updated, no `journal_ref`. https://arxiv.org/abs/2508.18440
- Semantic Scholar citations API for arXiv:2508.18440 — 2 citing papers with contexts: arXiv:2606.31729 (TTS evaluation, *"f0 correlation computed with SwiftF0"*), arXiv:2604.03636 (*FlueBricks*, CHI 2026, DOI 10.1145/3772318.3790595).
- Core ML Tools — supported source frameworks (TF1/TF2, PyTorch, LibSVM, scikit-learn, XGBoost; ONNX absent): https://apple.github.io/coremltools/docs-guides/source/convert-learning-models.html · ONNX/Keras converter deprecation at coremltools 6 and the frozen, unmaintained `onnx-coreml`: https://github.com/onnx/onnx-coreml · https://apple.github.io/coremltools/docs-guides/source/faqs.html
- ONNX Runtime — `microsoft/onnxruntime` (MIT, actively maintained) and `microsoft/onnxruntime-swift-package-manager` (MIT, release 1.24.2, 2026-02-25). https://github.com/microsoft/onnxruntime-swift-package-manager
- Third-party adoption and failure reports (GitHub code/issue search): `baijum/ukulele-companion` PR #174 and `iosApp/setup_onnxruntime.sh` · `rakuri255/UltraSinger` + `MrDix/UltraSinger` PR #103 · `musicmuni/voxatrace` issue #1 · `kjranyone/RCWX` PR #4 · `SoulMelody/anyf0` · `a5632645/swift_f0_cpp` (unlicensed experiment) · **`Alice-Sabrina-Ivy/Syrinx` #75/#79/#81** (the low-F0 octave report) · **`walterfr/UltraStarKaraokeMaker` #7** (undiagnosed dense-mix contour report).

---
## 6. Resynthesis — the NAMED approach

### 6.1 The name

**signalsmith-stretch v1.3.2 (commit `57b93f4`, vendored verbatim per `ROADMAP.md:66` and `VENDORED.md`), driven with a transpose curve updated once per analysis hop, in formant-compensation mode with `setFormantBase` fed our own measured f0.**

Concretely that is: a **phase-vocoder with spectral-peak tracking and vertical phase locking** — peaks found per block (`findPeaks`, `signalsmith-stretch.h:859-880`), a piecewise-smoothstep input→output bin map built between them (`updateOutputMap`, `:882-917`), a preliminary per-bin phase-advance prediction (`:697-719`), then re-prediction using inter-bin phase differences (`:722+`) — plus **cepstral-domain formant envelope compensation** (`updateFormants`, invoked `:689-693`; envelope metric `formantMetric`, `:90`; inverse formant map `:920-925`).

Not "a phase-vocoder approach". That specific library, that specific commit, that specific mode, driven that specific way.

### 6.2 The quality argument — evidence, not assertion

**A. Measured in this repo, on this build.** M5 ii-b's committed tests measured pitch accuracy directly (`ROADMAP.md:66`): `440 → 440.00` Hz for the identity case and `+7 st → 659.00` Hz against a theoretical `659.26`. That is a **1.7-cent** error at a musically relevant interval, on our own vendored copy, in a test that still runs. A note editor's smallest meaningful gesture is ~5 cents, so the engine's intrinsic pitch accuracy is roughly 3× finer than the interaction it must serve. That is the single most decision-relevant measurement available, and we own it.

**B. Measured in this repo, on level behaviour.** M5 ii-e's 36-cell grid (`ROADMAP.md:69`): true peaks −7.67 to −1.69 dBTP, 0/36 over 0 dBFS, lengths exact; the ii-b 0.75× overshoot (1.414 from 0.8 input) did **not** reproduce on musical material. Caveat carried forward in §6.3: polysynth, not voice.

**C. Documented upstream behaviour, with citation.** Automation is a documented feature with a documented timing rule (§2.1), and pitch-shifting is documented as good over "a wide-range of pitch-shifts (multiple octaves)" while it is *time*-stretching that is limited to 0.75×–1.5× (README intro). Since v1 changes pitch and not time, we operate in the range upstream says is strong.

**D. Third-party adoption and a published comparison, via the repo's own evaluation.** `2026-07-05-time-stretch-library-evaluation.md:18` records a direct offline A/B on a KVR DSP-developer thread where a drum-sampler author preferred signalsmith over Rubber Band and switched, plus production use as the pitch-compensation engine in Qt/FFmpeg's `QMediaPlayer` and as the default backend in Python `audiomentations`.

**E. A quality lever unique to this milestone.** Today the shim requests auto-detection of the fundamental: `css_set_formant_preserve` calls `setFormantBase(0)` (`shim.cpp:47-52`), which routes to the library's internal `estimateFrequency()` (`signalsmith-stretch.h:983`) — whose own declaration comment calls it a **"Rough guesstimate of the fundamental frequency, used for formant analysis"** (`:132`). **m23-q is the first feature that will have a real, HMM-decoded f0 contour, and can feed it in per hop.** Upstream explicitly asks for this value ("It also needs you to give it a rough estimate of fundamental frequency", README §Formant compensation). Replacing a guesstimate with a measurement, in the exact subsystem upstream names as its weak spot, is a concrete improvement available only here. Exposing `setFormantBase` is one additive shim function. **Unverified:** how much it improves things — E2 should A/B auto vs measured base, and that A/B is cheap once E1 exists.

**F. Zero integration cost and zero new licence surface.** MIT, already vendored, already wrapped, already cached, already deterministic (fixed seed, `OfflineStretcher.swift:42`), already null-tested against the identity bypass.

### 6.3 The case against — in strength order

1. **Upstream itself says formant correction is the weak spot, verbatim:** *"The formant correction is not a sharp as monophonic algorithms (such such as PSOLA)."* (README §Formant compensation, `sic` throughout.) Vocal pitch correction is precisely the monophonic case where PSOLA-class algorithms are strongest. **This is the strongest argument against the pick and it comes from the vendor.**
2. **Commercial engines are reported meaningfully better on exactly our axis.** `2026-07-05-…:34`: "Commercial-grade quality (Elastique, Bungee Pro) is reported as meaningfully better specifically on **vocal timbre preservation** — the axis DAW Pro cares about most". Reported, not measured by us.
3. **The vocal validation was never done** (§4.2). The stamp is "PROVISIONAL-FINAL … human audition pending" and the grid used a polysynth. **We are making a vocal-quality decision on non-vocal evidence.** That is why E2 is inside phase 0.
4. **A 30 ms automation grid** (§2.2.4). Adequate for correction contours, marginal for vibrato shaping. Mitigable via `configure`, at CPU cost.
5. **Per-note *timing* has a hard ceiling** (§2.5): `maxCleanStretch = 2` triggers deliberate phase randomisation, and upstream advises 0.75×–1.5×.
6. **Single-maintainer dependency.** Same class of risk as Rubber Band's, and we already accepted it at M5.

### 6.4 Design rules the resynthesis choice imposes

- **Smooth inside a note, steep only at boundaries.** Because a map change moves the spectral envelope discontinuously (§2.2.3), the correction curve should be C¹-smooth within a segment and allowed a fast (but not instantaneous) transition across a boundary — a ~20–40 ms ramp, which is 1–2 analysis hops, i.e. free.
- **Never bypass the identity path.** A clip with an empty edit set must still hit `OfflineStretcher.isIdentity` (`:50-52`) and play the original file byte-for-byte. This is the existing null-test guarantee and pitch correction must not weaken it.
- **Curve in absolute output semitones, not deltas.** The renderer receives `semitones(atOutputFrame:)`, already summed from `Clip.pitchShiftSemitones` + per-note offset + any drift/vibrato scaling. One evaluator, one place to be wrong.
- **`setFormantBase` gets the measured f0 of the SOURCE**, not the corrected target — the envelope is being held at the source position.

### 6.5 Why not TD-PSOLA, and what the escalation path actually is

**TD-PSOLA is the textbook right tool for monophonic vocal pitch modification** — pitch-synchronous overlap-add resamples the *spacing* of glottal epochs while leaving each grain's waveform intact, so the formant envelope is preserved inherently rather than corrected after the fact. It is cheap, it is public-domain as an algorithm, and it is exactly what upstream is comparing itself unfavourably against. It deserves an answer, and "we already have signalsmith" is not one.

**Why not, in v1:**

1. **It needs a second, harder detector.** TD-PSOLA needs *pitch marks* (glottal closure instants), not just f0. Epoch detection is its own literature with its own failure modes, and a misplaced epoch is an audible buzz, not a small error. We would be taking on two detection problems instead of one to ship phase 1.
2. **It degrades where DAW vocals actually live.** PSOLA assumes strict monophony and clear periodicity. Breathy onsets, fry, sibilants, double-tracked or harmonised takes, and headphone bleed all break its assumption. Signalsmith's spectral approach degrades gracefully on the same material.
3. **It would be a second resynthesis engine.** A PSOLA path beside `OfflineStretcher` is precisely the "second home for something that exists" defect the roadmap forbids — two engines, two cache key shapes, two sets of artefacts, two things to keep in sync.
4. **Melodyne is not TD-PSOLA either.** Celemony's DNA / Local Sound Synthesis is proprietary and not a classical PSOLA; citing PSOLA as "what the pros do" would be wrong.

**The escalation path, in order, if E2 fails:**

- **First**, feed measured f0 to `setFormantBase` (§6.2E) and re-listen. Cheapest possible fix, targets the named weakness directly.
- **Second**, shorten the analysis interval via `configure` (§2.2.4) and re-listen. Also cheap.
- **Third**, **Rubber Band Library commercial licence** — £590 attribution / £1,490 non-attribution under 10 employees, one-time perpetual, pricing verified in `2026-07-05-…:16` and re-stated at `CHANGELOG.md:1809`. Its GPL track is unusable for us; the paid track is not. It has `OptionFormantPreserved` and a real-time shifter, and the offline API shape is close enough that it lands behind the same facade. **Budgeted in §11 as a +2 week integration with a known cash cost.**
- **Fourth and last**, a PSOLA *stage* — and only if E2 localises the failure to sustained-vowel formant smear specifically, which is the one symptom PSOLA is definitively better at. Even then it is an extra milestone, not a v1 decision.

**Bungee OSS is not on this list.** The 2026-07-05 evaluation found the vendor's own published comparison shows the free tier deliberately capped below Bungee Pro and Elastique on tonal accuracy, with no formant controls advertised on the OSS API. It is not a safer bet than what we have.

---
## 7. Architecture

### 7.1 The data model — one type, on `Clip`, in source seconds

```
PitchEditSet            // NEW, Sources/DAWCore/PitchCorrection.swift
  analysisVersion: Int      // bumps when the detector changes; a stale set is
                            // still honoured, never silently re-detected
  segments: [NoteSegment]

NoteSegment
  id: UUID
  startSeconds / endSeconds: Double   // SOURCE-FILE seconds, like transcription
  detectedHz: Double                  // median f0 as detected (never mutated by an edit)
  detectedConfidence: Double
  pitchOffsetCents: Double            // THE edit: user's correction, signed
  driftScale: Double = 1              // 0 = flatten macro pitch drift, 1 = keep
  vibratoScale: Double = 1            // 0 = remove vibrato, 1 = keep, >1 = exaggerate
  formantOffsetSemitones: Double = 0  // phase 4
  timeStartDeltaSeconds / timeEndDeltaSeconds: Double = 0   // phase 3
  amplitudeDb: Double = 0             // phase 4
```

Four decisions embedded here, each with a reason:

- **Source seconds, not project beats.** It matches `ClipTranscriptionSource` exactly (`ProjectStore+Transcription.swift:19-25`: `audioURL`, `startSeconds`, `endSeconds`, `anchorBeat`, `tempoMap`), which means word boundaries drop straight in with no coordinate conversion. It also means the edit set survives clip trim, split, move and tempo change — the same geometry-independence `StretchRenderCache` engineered for at M5 ii-a ("geometry-free keys — trim/split/move/tempo never invalidate", `ROADMAP.md:65`).
- **`detectedHz` is stored and never mutated.** The rendered curve is a pure function of `(detected contour, edit set)`. Re-running detection on already-edited audio — the classic way these features rot — is structurally impossible.
- **Drift and vibrato are *scales* on the detected contour, not separate curves.** That is what makes "correct this note to A4 but keep its vibrato" a single number rather than a curve editor, and it is why the detector must produce a contour rather than one number per note.
- **The set lives on `Clip`.** Not on a sidecar table keyed by clip id — see §7.5.

**The one evaluator** (the repo's "ONE home" law): a single pure function

```
PitchCorrectionCurve.semitones(atSourceSecond:) -> Double
```

in `Sources/DAWCore/PitchCorrection.swift`, which sums `Clip.pitchShiftSemitones` (the existing whole-clip term) and the per-segment terms, with the boundary ramp from §6.4. Both the renderer and any UI readout call it. Follow the `ArrangeDropSnap` model the repo already names as the one to copy: `fileprivate init` so divergence is unrepresentable.

### 7.2 Render path — the existing cache, unchanged in shape

`StretchRenderCache.Params` (`StretchRenderCache.swift:26-41`) gains a fourth member: `pitchEditSetHash: String?`, `nil` when there is no edit set. `performRender` (`:229`) resolves that back to the curve and calls the curve-taking `OfflineStretcher` entry point. **Everything else is untouched**: 250 ms debounce (`:51`), latest-wins per clip (`:170`), detached render (`:189`), partial + atomic rename (`:283-296`), `onRenderComplete` → `tracksDidChange` (`:57-60`).

**Cache key, and the trap in it.** `cacheKey` (`:115-136`) hashes a fixed list of fixed-width fields. A note-edit set is variable-length. **Append the canonicalised edit-set hash ONLY when non-empty**, mirroring the Codable omit-when-default rule — otherwise every existing key changes and every existing render is orphaned in one release. **Do NOT bump `stretchEngineVersion` (`:46`) for this**; that constant exists to invalidate renders when the *algorithm* changes, and bumping it nukes every cached render on every user's disk for a feature most of them are not using. Bump it only when the curve renderer's output for an *unchanged* input would differ.

**`analysisVersion` must be part of the hashed material, not just the model.** §7.1 stores `analysisVersion` on the edit set and §7.3 deliberately does **not** persist the detected f0 contour (it is regenerable, and it lives in the cache directory). Those two decisions combine into a silent-corruption path: user corrects a vocal → render commits → the OS purges `~/Library/Caches` → a later release ships an improved detector → the same key re-renders against a *different* contour → **the vocal quietly sounds different with no user action**. Fix: fold `analysisVersion` into the canonicalised edit-set hash so a detector change re-keys, and treat a contour/version mismatch on re-render as a visible re-detection notice rather than a silent substitution. One clause now; a very confusing bug report later.

### 7.3 Persistence — additive, omitted-when-empty, byte-identical for existing projects

The precedent is explicit and repeated in `Clip`'s own Codable. `Model.swift:879-880` writes `stretchRatio`/`pitchShiftSemitones` only when non-default; the gain-envelope and controller-lane comments (`:882-889`) state the rule outright — *"written ONLY when non-empty, so a clip without one carries no new key (byte-identical to a pre-m13-e save)"*.

**⚠️ But `Clip`'s own Codable is NOT the project file format, and this is the trap in the section.** `.dawproj` persists through **`ClipDocument`** (`Sources/DAWCore/ProjectDocument.swift:1038`), a hand-maintained mirror type, while `Clip`'s Codable serves the wire (`project.snapshot`, command round-tripping). Adding a field therefore has **four** touch points, not one:

1. `Clip` — the stored property plus its Codable (`Model.swift:827` CodingKeys, `:851-853` decode, `:879-889` encode). This is the wire.
2. `ClipDocument` — the optional property (the `stretchRatio`/`gainEnvelope` shape at `:1062-1079`), the `CodingKeys` (`:1088`), and `decodeIfPresent` (`:1130-1131`).
3. `ClipDocument.init(from clip:)` — the omit-when-default write (`:1107-1111`: `gainEnvelope = clip.gainEnvelope.isEmpty ? nil : clip.gainEnvelope`).
4. The reverse mapping `ClipDocument` → `Clip` (`:249-258`: `gainEnvelope: cd.gainEnvelope ?? []`).

**What is genuinely free:** `TakeLaneDocument.clip` is a `ClipDocument` (`ProjectDocument.swift:1247`), so step 2–4 covers take lanes with no extra work. §7.5's "free" claim holds at the persistence layer — but via `ClipDocument`, not via `Clip`'s Codable.

With all four done: a project with no pitch edits saves byte-identically to today. A project *with* them opens in an older build with the key ignored and the clip plays uncorrected — lossy but non-destructive, exactly how `gainEnvelope` and `controllerLanes` already behave.

**Sizing, because it is the "boring omission" the brief warned about:** a 3-minute vocal at ~2.5 notes/second is ~450 segments. At roughly 200 bytes of JSON each that is ~90 KB per corrected clip — fine inline in the project document. The *detected contour* (one f0 sample per ~10 ms = 18,000 doubles) must **not** be persisted in the project; it is regenerable analysis and belongs in the cache directory beside the renders, keyed by content like everything else. Persisting it would grow `.dawproj` by megabytes for no user-visible benefit.

### 7.4 Undo — `performEdit` with a per-segment coalescing key

`ProjectStore` journals via `performEdit`; entries carry a `label` and an optional `key`, and `key == nil` means "never coalesces" (`ProjectStore.swift:8-20`).

- **Continuous edits coalesce per segment**: key `pitch.segment:<clipID>:<segmentID>` for a pitch drag, `pitch.drift:<clipID>:<segmentID>` and `pitch.vibrato:<clipID>:<segmentID>` for those. A drag becomes one undo entry; dragging a *different* note starts a new one, because the key differs. This is exactly the `track.volume:<uuid>` shape at `ProjectStore.swift:17`.
- **Structural edits never coalesce** (`key: nil`): split a segment, merge two, re-run detection, apply/clear a whole-clip auto-correct pass. Precedent: `ProjectStore.swift:1669` — "never coalesced (the track-chain rule: a deliberate on/off is its own edit)".
- **Re-detection is one undoable edit that replaces the whole set**, and it must warn when it would discard existing edits rather than silently dropping them.
- Multi-select edits are **one** entry over N segments (the m23-g2 `clip.moveMany` group-verb precedent), not N entries.

### 7.5 Take groups — in scope at the model level, scoped at the UI level

`Sources/DAWCore/Takes.swift:21`: `TakeLane.clip` **is a full `Clip`**, and `TakeGroup.lanes` is `[TakeLane]` (`Takes.swift:79`). Because the edit set lives on `Clip`, take lanes get pitch correction **free** — model, undo, and the render cache key all work on a lane clip exactly as on a timeline clip, with no new code and no second storage. Persistence is free as well, but only because `TakeLaneDocument.clip` is a `ClipDocument` (`ProjectDocument.swift:1247`), so the one `ClipDocument` change in §7.3 covers lanes too. That is the whole reason §7.1 puts the set on `Clip`.

What is *not* free is the editor surface: the pitch editor must be openable on a lane's clip, and a comped clip's edit set must have defined behaviour. The decisions:

- **Phase 2 (editor) opens on any `Clip`, addressed by clip id**, whether it sits in `track.clips` or in `TakeGroup.lanes[].clip`. The editor takes an id, not a track-and-index. This costs approximately nothing if it is decided now and is expensive to retrofit.
- **Comping (`take.flatten`) carries each lane clip's edit set through with the segments it contributes.** Segments are in source seconds and comp segments are time ranges, so the mapping is a filter, not a transform.
- **Deliberately deferred: editing pitch on the comped result and having it flow back to lanes.** That is a two-way binding and it is out of scope; edits after flatten live on the flattened clip.

### 7.6 The offline / real-time boundary — nothing new crosses it

`StretchRenderCache` is the precedent and it applies verbatim. The chain, with citations: `@MainActor` service (`:22-23`) → `Task.detached(priority: .userInitiated)` (`:189`) → `nonisolated static performRender` (`:229`) → CAF on disk → `onRenderComplete` (`:57-60`) → engine invalidates and re-enters the `tracksDidChange` restart seam → the render thread plays a **plain Float32 CAF**.

**The render thread never sees pitch correction.** No FFT, no `std::function` (the `setFreqMap` hazard, §2.2.6), no allocation, no lock — not because we were careful, but because the render thread does not know the subsystem exists. The RT invariant is preserved by construction, which is the only way it stays preserved.

The one place RT pressure could sneak in later is **live audition while dragging a note**. The answer, decided now: **cached render + debounce, never signalsmith on the render thread.** The 250 ms debounce (`:51`) already produces exactly the "settled value renders" behaviour a drag needs, and `ClipShimmer` (`ROADMAP.md:69`) is the existing visual language for "this clip is re-rendering". `Sources/DAWCore/Audition.swift` is the *policy-home* precedent (m23-d: "THE policy home for note audition … UI-free and engine-free … which is what makes" all three entry points execute one path) but it is MIDI note audition, not audio — it is the pattern to copy for where the policy lives, not a mechanism we can reuse for audio.

**If anyone later proposes running signalsmith on the render thread for live preview: it allocates, it uses `std::function`, and its computation is bursty by design (`splitComputation` exists precisely because "the library will occasionally do a bunch of computation all at once", README §Split computation). It is an offline engine here. Flag any design that says otherwise.**

### 7.7 Command surface — additive only, one home

CLAUDE.md's invariant: every user-facing capability ships a control command, an MCP tool, and a test; UI and the control protocol both converge on `ProjectStore`. There is no pitch-correction UI action that is not one of these verbs.

Proposed verbs (final naming is the implementer's, the shape is not):

| Verb | Phase | Notes |
|---|---|---|
| `clip.detectPitch` | 1 | Runs detection, stores the segment set. Async job like `clip.transcribe`. |
| `clip.autoCorrectPitch` | 1 | Scale, strength 0–1, retune-speed ms, preserve-vibrato flag. The phase-1 headline. |
| `clip.clearPitchEdits` | 1 | One undo entry; returns to byte-identical playback. |
| `clip.setNotePitch` | 2 | Per-segment cents / drift / vibrato. Coalesces (§7.4). |
| `clip.splitNote` / `clip.mergeNotes` | 2 | Structural; no coalescing. |
| `clip.setNoteTiming` | 3 | Per-segment time deltas, clamped per §2.5. |
| `clip.setNoteFormant` / `clip.setNoteGain` | 4 | |

`project.snapshot` carries the edit set for free via `Clip`'s Codable — the same "rides Track's encoding for free" property M4 vii-d relied on (`ROADMAP.md:52`). Wire delta at phase 4 completion: **165 → ~174** commands. I measured 165 myself from `Sources/DAWControl/Commands.swift:183`; the MCP figure of 168 is carried from the m23-y close record and I did **not** re-derive it. **Additive only — no existing verb is renamed or repurposed** (the standing constraint). Note that `dist/DAWPro.app` is already behind the tree at 161 commands, so this milestone widens an existing gap; that is a bundling issue, not a design one.

### 7.8 What must NOT be built

- ❌ A second stretch facade beside `OfflineStretcher`.
- ❌ A second render cache, or a second cache-key derivation.
- ❌ A second whole-clip pitch path beside `Clip.pitchShiftSemitones` — the curve *subsumes* it (§6.4).
- ❌ A second onset detector beside `detectTransients`.
- ❌ A sidecar dependency for detection (§5.4).
- ❌ Persisted f0 contours in `.dawproj` (§7.3).
- ❌ Any pitch DSP reachable from the render thread (§7.6).

---
## 8. Scope split — audio import, plugin hosting, voice-model import; and correction vs conversion

The roadmap requires this resolved explicitly, so it is stated in three tiers plus a boundary.

### 8.1 Tier 1 — importing vocal AUDIO: **in scope, already works**

Dropping a `.wav`/`.aiff`/`.mp3` vocal onto a track is existing functionality (`Sources/DAWCore/MediaImporting.swift`, the audio-import batch path). Pitch correction operates on whatever audio is on the clip and does not care where it came from — recorded, imported, ACE-Step-generated, or RVC-converted. **No new policy, no new code, no restriction.**

### 8.2 Tier 2 — hosting third-party pitch PLUGINS: **in scope, already works, with one Xcode flag**

Auto-Tune, Waves Tune, MAutoPitch and friends are Audio Units. DAW Pro hosts AUs (`HostedAUEffect`, M4 v). A user who wants Antares rather than ours inserts Antares. That is correct and we should not compete with it on the insert-effect axis; m23-q's differentiator is the *note-level editor*, which a plugin insert cannot give you.

> **⚠️ REQUIRES FULL XCODE — flagged per the standing obligation.** AUv3 hosting needs entitlements, an app bundle, and code signing; `xcodebuild -version` must show full Xcode, not Command Line Tools. This is *pre-existing* AU-hosting territory and m23-q adds nothing to it — but nothing in this milestone should be planned as if a plugin-hosting change were free. See also the known AU-hosting wedge with third-party AUv2 instruments recorded in project memory.

### 8.3 Tier 3 — importing third-party VOICE MODELS: **PERMITTED**

**The user withdrew the previous own-voice-only prohibition on 2026-07-27.** Their words, quoted in `docs/ROADMAP.md:469`:

> *"We need to support third-party voice models and let user deal with repercussions… our model should be open and not restrict."*

**Provenance and licensing of any imported voice model are the USER'S responsibility, not the app's.** DAW Pro does not police what a user loads. Any older text in this repo implying otherwise is stale and must not be followed.

**The one limit the user did not withdraw:** wire up **importing user-supplied model files** — a file picker, a path, a drop target. **Do not build scrapers or indexes that go out and FIND celebrity voice models at scale.** The line is between *a user brings a file they have* and *the app becomes a discovery service for other people's voices*. The first is a file import; the second is a product decision the user has not made.

**Where this touches m23-q at all: barely, and that is worth saying.** Voice models belong to *conversion* (§8.4), which is a shipped feature on a different code path. Pitch correction does not use a voice model — it modifies the pitch of audio that already exists. The scope split is resolved here because the roadmap asked, not because the milestone depends on it. Concretely, the only m23-q-adjacent work is that a *converted* vocal is just audio on a clip and is a first-class input to correction (§8.1).

### 8.4 Correction vs conversion — different features, different code, one pipeline

| | **Pitch correction** (m23-q) | **Voice conversion** (shipped) |
|---|---|---|
| Changes | *What notes* the voice sings | *Whose voice* is singing |
| Where | In-app, offline render, `OfflineStretcher` + cache | RVC sidecar, FastAPI on 127.0.0.1:8002 |
| Verb | `clip.autoCorrectPitch` et al. (new) | `vc.convertVocals` (`ProjectStore+VoiceConversion.swift`) |
| Model | None | A trained voice model |
| Dependency | None beyond the app | Sidecar must be installed and running |

They compose in one direction and the ordering matters: **correct first, then convert.** RVC re-synthesises from its own f0 extraction, so any correction applied afterwards would be fighting a signal RVC already reshaped, and correction artefacts would be baked in before conversion could mask or exaggerate them. Correcting the source vocal and then converting gives RVC clean, in-tune input — which the voice-conversion doc's own finding supports (`2026-07-11-…:67`: RVC quality is "extremely sensitive to training-data cleanliness"; the same sensitivity applies to the input being converted). **Sequence is a UX teaching point, not an enforced constraint** — nothing should refuse the other order.

---
## 9. Licensing — every named dependency, verified

DAW Pro ships commercially and closed-source. **GPL and AGPL are automatic NOs however good the library sounds.** Every row below was verified on 2026-07-29 by fetching the licence text or reading the vendored file, except where the row says otherwise.

| Dependency | Licence | Verified how | Ships in a commercial closed-source macOS app? |
|---|---|---|---|
| **signalsmith-stretch** v1.3.2 (`57b93f4`) | **MIT** | Read `Sources/CSignalsmithStretch/vendor/signalsmith-stretch/LICENSE.txt` — "Copyright (c) 2022 Geraint Luff / Signalsmith Audio Ltd." | **YES.** Already shipping. Obligation: reproduce the notice. |
| **signalsmith-linear** (`7f53cdd`) | **MIT** | Read `vendor/signalsmith-linear/LICENSE.txt` — "Copyright (c) 2025 Signalsmith Audio" | **YES.** Already shipping. |
| **In-house pYIN** (the §5.3 pick) | Ours | n/a | **YES.** No third-party artefact at all — that is the point of the pick. The *algorithm* is published (Mauch & Dixon, ICASSP 2014); algorithms are not copyrightable and upstream asserts no patent. |
| **pYIN — QM Vamp plugin** (reference impl.) | **GPL** | `github.com/c4dm/qm-vamp-plugins`; QMUL sells a separate commercial licence via its eshop | **NO** as vendored source. The paid QMUL licence is a live fallback, same shape as Rubber Band's. **⚠️ The name "pYIN" hides two licence outcomes — do not vendor the QM sources.** |
| **librosa** (`librosa.pyin`, test oracle only) | **ISC** | `github.com/librosa/librosa/blob/main/LICENSE.md` | Permissive, but **not shipped** — dev-time fixture generation only (§5.5). |
| **WORLD / Harvest** (fallback detector) | **Modified 3-clause BSD** | Fetched `github.com/mmorise/World/master/LICENSE.txt`: "Redistribution and use in source and binary forms…", "Neither the name of the M. Morise…". Upstream also states there is no patent in any of its algorithms. | **YES.** Obligation: reproduce notice, no endorsement claim. |
| **CREPE** (rejected) | Code **MIT** (`github.com/marl/crepe/LICENSE`, "Copyright (c) 2018 Jong Wook Kim"). **Model weights: licence NOT separately stated in that file and NOT verified by me.** | Fetched the LICENSE file | Code yes; **weights unverified — do not assume the code licence covers the model.** Rejected on architecture anyway (§5.2). |
| **RMVPE** (rejected) | **Apache-2.0** (`github.com/Dream-High/RMVPE/LICENSE`). Weights again a separate, unverified question. | Fetched the LICENSE file | Code yes (notice + NOTICE-file obligations); weights unverified. Rejected on architecture. |
| **Rubber Band Library** (escalation) | Dual: **GPLv2-or-later** OR a **paid commercial licence** | `2026-07-05-…:16`, restated `CHANGELOG.md:1809` | **Only via the paid licence.** £590 attribution / £1,490 non-attribution under 10 employees, perpetual, no royalties. Its GPL track is explicitly unusable for App Store / proprietary distribution. |
| **SoundTouch** | LGPL-2.1 | `2026-07-05-…:17,26` | Legally workable via a dynamic framework, but it drags in hardened-runtime library-validation friction — and it was already rejected on quality. Not a candidate. |
| **Bungee OSS** | MPL-2.0 | `2026-07-05-…:19,28` | File-level copyleft; static linking is fine. Rejected on quality evidence (§6.5), not licence. |
| **Apple Accelerate / vDSP** | System framework | n/a | **YES**, zero risk. Reached through `signalsmith-linear` with `SIGNALSMITH_USE_ACCELERATE` (`shim.cpp:4-5`). |

**Verdict on the brief's prediction.** The brief predicted licensing would shape or kill the detector choice more than quality would. **Correct, and it did — but by *removing* candidates rather than choosing among them.** GPL knocked out the pYIN reference implementation (the single most-cited artefact for this exact task); weights-licence uncertainty plus architecture knocked out both neural options; what survived the conjunction were two options with *no* licence question at all — our own code on an MIT FFT we already ship, and a BSD C++ library. Quality then chose between those two survivors, and it chose the one with zero new dependency surface. So licensing set the menu and quality picked from it. **No dependency in the recommended plan carries any copyleft obligation whatsoever.**

---
## 10. Failure modes

Ordered by (probability × damage). Each names the symptom, the cause, and what is done about it.

**F1 — Detection is right and the *notes* are wrong.** f0 tracking can be near-perfect while segmentation is musically nonsense: a legato slide split into three notes, a vibrato peak read as a neighbour note, a two-syllable word read as one. This is the failure users actually report about Melodyne-class tools, and it is *segmentation*, not detection. *Mitigation:* segmentation consumes three independent signals — f0 stability, `detectTransients` onsets, and (phase 4) `clip.transcribe` word boundaries — and **split/merge are first-class user operations from phase 2**, not a repair mechanism bolted on later. Accept that the first pass will be wrong sometimes and make fixing it a one-click gesture.

**F2 — Octave errors.** Bare YIN's signature failure: an octave-down halving on low breathy notes, an octave-up on strong second harmonics. One octave error is far more damaging than fifty 20-cent errors because it *sounds broken*. *Mitigation:* pYIN's Viterbi decode over a pitch-state HMM exists specifically for this; the §5.5 gate makes **zero octave errors on synthetic fixtures** a hard bar; and the UI must show detected pitch, so a wrong octave is visible before it is audible.

**F3 — E2 says the resynthesis is not good enough on real voices.** The largest unknown (§11.4). *Mitigation:* it is phase 0, it is 2–3 days, and the escalation ladder is pre-costed (§6.5) — measured `setFormantBase`, then a shorter interval, then Rubber Band commercial at a known price and a budgeted +2 weeks.

**F4 — Whole-source re-render latency on long vocals.** The cache renders the entire source file by design (`StretchRenderCache.swift:9-14`), so one note tweak re-renders a 4-minute vocal. *Mitigation, and the honesty about it:* the 250 ms debounce (`:51`) already means only settled values render, and `ClipShimmer` already communicates "re-rendering". **Accept it for v1 and state the number** — measure a real 4-minute render in phase 1 and publish it. Region-scoped rendering is the known optimisation and it is **not** free: its stated cost is the phase-coherence guarantee that makes split clips share one render. Do not design it speculatively; revisit only if the measured number is bad.

**F5 — The `outputLatency` misalignment (§2.3).** Silent, systematic, and easy to ship: everything "works", but every correction lands ~60 ms late and consonants smear. *Mitigation:* E1(a) measures it; the offset becomes a named constant with a regression test that fails if the vendored library's latency changes.

**F6 — Curve resolution insufficient for vibrato.** 30 ms hops = ~6 points per vibrato cycle (§2.2.4). Symptom: `vibratoScale` produces a stepped, warbling result instead of a smooth one. *Mitigation:* E1(c) measures it before the UI is built. Fix is `configure` with a shorter interval, one additive shim function, at CPU cost.

**F7 — Per-note timing pushed past 2×.** `maxCleanStretch = 2` turns on deliberate phase randomisation (§2.5). Symptom: one aggressively-moved note smears while its neighbours are clean. *Mitigation:* clamp local ratio to ~[0.7, 1.4], surface the clamp honestly in the readout rather than silently applying it — the `ClipsMoveResult` `requestedDelta`/`effectiveDelta`/`clamped` precedent (`Model.swift`, m23-g2) is the house pattern for reporting a clamp instead of hiding it.

**F8 — Cache-key regression orphaning every existing render.** Appending the edit-set hash unconditionally changes every key (§7.2). Symptom: one release, every user re-renders every stretched clip. *Mitigation:* append only when non-empty; add a test that pins the key for a clip with no pitch edits to its pre-m23-q value.

**F9 — Persistence forward/backward asymmetry.** An older build opening a corrected project ignores the key and plays uncorrected audio. *Mitigation:* this is the existing behaviour class for `gainEnvelope` and `controllerLanes`; it is lossy-but-non-destructive and acceptable. What is *not* acceptable is an older build **saving over** the project and dropping the key — the same hazard those two fields already carry, so no new mechanism, but it should be stated in the milestone's risk note rather than discovered.

**F10 — Detection re-run silently discarding user edits.** Symptom: a user re-detects to fix one bad segment and loses an hour of corrections. *Mitigation:* `analysisVersion` on the set (§7.1); re-detection is one non-coalescing undo entry and must warn before discarding.

**F11 — The editor cannot open a take lane.** The material this feature is *for* lives in `TakeGroup.lanes[].clip` before comping (§7.5). Symptom: half a feature for exactly its intended use. *Mitigation:* the phase-2 editor addresses clips **by id**, not by track-and-index — decided now because it is free now and expensive later.

**F12 — Someone proposes live pitch preview on the render thread.** Symptom: allocations, `std::function` calls and bursty FFT work on the audio thread; dropouts under load. *Mitigation:* §7.6 forbids it explicitly, with the reasons, so a future reviewer has something to point at.

---
## 11. Phase breakdown and honest estimate

### 11.1 How to read these numbers

Estimates are given as **engineer-weeks for one focused lane** and as **roadmap sub-items** (this repo executes roughly one substantive sub-item per agent cycle, each shipping code + tests + a verification record). Both are given because the first is comparable to the outside world and the second is comparable to *this repo's own history*, which is the more useful anchor.

**The calibration anchor is M5 (ii), the closest precedent by shape** — a new vendored DSP library, a new offline render path, a new cache, new wire verbs and new UI: `ii-a` design/seam, `ii-b` vendor + facade + 8 tests, `ii-d` cache + resolver + wire + 8 tests + a 16-check live E2E, `ii-e` UI + headless model + 14 tests + a 36-cell listening grid (`ROADMAP.md:65-69`). **Four substantive sub-items for a complete offline-DSP subsystem with UI.** m23-q's phases are sized against that, scaled by how much of the work has no substrate.

Every phase below carries: what ships, why it is independently valuable, the basis for the number, and its own risk.

### 11.2 The phases

---

**Phase 0 — Prove the curve. `0.5 weeks` / 1 sub-item.**

E1 and E2 from §2.4: the curve-taking `OfflineStretcher` entry point, hop-sized chunking, the FFT measurement harness, the alignment constant, and a human listen on a real vocal.

*Ships:* nothing user-visible. This is the only phase for which that is acceptable, and it is half a week.
*Basis:* the machinery is one loop change plus a test harness; `ii-b` did comparable vendor-and-measure work in one item, and this is smaller because the library is already vendored, wrapped, and deterministic.
*Risk:* this phase exists **to** absorb the risk. **Kill/escalate criterion is written in §2.4 and the ladder is pre-costed in §6.5.**

---

**Phase 1 — Global auto-correct. `4–5 weeks` / 4 sub-items. THE FIRST SHIPPABLE THING.**

`clip.detectPitch` + `clip.autoCorrectPitch` + `clip.clearPitchEdits`, with strength (0–1), retune speed (ms), scale/key, and preserve-vibrato. Rendered through the curve path and the existing cache. Minimal UI: a control in the clip inspector plus the existing `ClipShimmer` re-render affordance.

*What the user gets:* **an Auto-Tune-class vocal corrector that works on any clip, driveable by an AI agent in one command.** Not Melodyne — Melodyne is phase 2 — but genuinely useful on its own, and the single most common thing anyone does to a vocal.

*Why this is the right phase 1, explicitly:* the brief's named failure mode is "phase 1 is 'build a pitch detector' with nothing a user can see, and the milestone stalls the first time priorities move." Phase 1 **contains** the detector but is not *defined* by it — it exercises detection → curve → render → cache → wire → UI end-to-end. If m23-q is parked forever after phase 1, the user has a working vocal tuner and the repo has a tested `PitchTracker` other features can use. **Nothing in phases 2–4 requires reworking phase 1; they are purely additive.**

*Sub-items:* (1) `PitchTracker` — pYIN on `signalsmith-linear`, with the §5.5 fixture gate; (2) `PitchCorrectionCurve` + the auto-correct policy (scale quantisation, strength, retune speed) as a pure DAWCore evaluator; (3) render integration — `Params` extension, cache-key rule, `OfflineStretcher` curve path, `setFormantBase` fed measured f0; (4) wire + MCP + inspector UI + tests.

*Basis for 4–5 weeks:* sub-item (1) is the only one without precedent and is the bulk — 2–3 weeks for pYIN with a Viterbi decode, fixtures, an oracle comparison and a tuning round. This is not a blind number: `TempoEstimator` (§3.7) is a hand-written biased-autocorrelation estimator with candidate picking and harmonic weighting that this codebase already built and shipped, and pYIN is the same shape of work with an HMM decode added. (2)–(4) map almost one-to-one onto `ii-a`/`ii-d`/`ii-e` work already done once in this codebase, on the same seams, at roughly a week each — including the **four-touch-point persistence change** of §7.3, which is cheap but is four places, not one, and is the classic spot to leave a field half-wired.

*Risk:* the detector. Bounded by §5.5's kill criterion — miss the bar after one tuning round and vendor WORLD Harvest (BSD) behind the same protocol, **+1 week**, not a redesign.

---

**Phase 2 — The note editor. `5–7 weeks` / 5–6 sub-items. The Melodyne-class feature.**

Segmentation into notes; a blob/piano-roll-hybrid editor; per-note drag for pitch, drift and vibrato; split/merge; scale snap; selection and multi-edit; audition.

*Ships:* the actual ask.
*Basis:* segmentation is 1.5–2 weeks (three input signals to fuse, and F1 says the failure is here, not in detection). **The editor UI is 3–4 weeks and is the single largest chunk in the milestone, because it has no substrate** — the comparable in-repo items are the m22-b EQ curve editor and the m23-d note-audition surface, each of which needed a full design doc of its own before implementation. Wire, undo keys and tests are ~1 week.
*Risk:* UI scope creep. Mitigation: **phase 2 should get its own design doc before implementation**, exactly as m22-b and note-audition did. Treat the number as covering an editor with the operations listed and nothing more.

---

**Phase 3 — Per-note timing. `2–3 weeks` / 2 sub-items.**

Per-segment time deltas via the varying `inTarget` schedule (§2.5), with the [0.7, 1.4] clamp reported honestly.

*Ships:* Melodyne-class timing on top of the phase-2 editor.
*Basis:* **no new API and no new render pass** (§2.5) — the cost is the edit model, the drag interaction on an existing surface, the clamp reporting, and tests. Small precisely because §2.5 found the substrate.
*Risk:* the `maxCleanStretch` ceiling (F7). Quality-bounded, not schedule-bounded.

---

**Phase 4 — Polish. `3–4 weeks` / 3 sub-items.**

Per-note formant and gain; vibrato *shaping* (not just scaling); word boundaries from `clip.transcribe` feeding segmentation; the take-lane editor entry point (§7.5).

*Ships:* the difference between "we have this feature" and "this feature is good".
*Basis:* each is a small independent addition on finished surfaces.
*Risk:* the `clip.transcribe` sequencing constraint (§3.4) — it refuses `stretchRatio != 1` (`ProjectStore+Transcription.swift:50-52`), so word boundaries must be fetched **before** any phase-3 timing edit. Cheap if known now, a confusing bug report if discovered later. Also F6: if E1(c) said 30 ms hops are too coarse, vibrato shaping needs the `configure` change first.

---

### 11.3 Totals

| | Weeks | Sub-items |
|---|---|---|
| **Phase 0 + 1 — first shippable value** | **4.5–5.5** | 5 |
| Phase 2 | 5–7 | 5–6 |
| Phase 3 | 2–3 | 2 |
| Phase 4 | 3–4 | 3 |
| **Full Melodyne-class subsystem** | **14.5–19.5** | **15–16** |

Contingencies, each already costed rather than hand-waved: **+1 week** if the detector escalates to WORLD Harvest (§5.5); **+2 weeks and £590–£1,490** if the resynthesis escalates to Rubber Band commercial (§6.5). Worst case with both: ~17.5–22.5 weeks.

**This estimate excludes:** live real-time correction (explicitly out of scope, §7.6); polyphonic separation (Melodyne DNA — not asked for and a different problem class); and any AUv3/entitlement work, which m23-q does not need (§8.2).

### 11.4 The largest unknown, named as such

**E2 — the perceptual quality of time-varying signalsmith-stretch on real sung vocals.**

Not the detector (bounded, with a named BSD fallback at +1 week). Not the API (answered, §2). Not persistence, undo or the RT boundary (all have working precedents in this tree, cited).

E2 is the largest unknown because it is the only one that can invalidate a *structural* choice: a failure there re-plumbs §6, changes the licence surface, adds cash cost, and shifts every downstream phase. It is also — and this is the uncomfortable part — **the validation the 2026-07-05 library decision was explicitly made conditional on, which was then run on a polysynth instead of a voice** (§4.2). The debt is ten months old. Phase 0 pays it in half a week, before anything is built on top.

Everything else in this document is a schedule risk. E2 is the only architecture risk.

---
## 12. GO / NO-GO

### **GO.**

Build it. Phase 0 (§11.2) is the first half-week *inside* the GO, not a condition on it, and it carries a pre-costed kill/escalate ladder so a bad result changes the plan rather than reopening the decision.

**The one-line reason:** the expensive half of this feature — artefact-free, formant-compensated, *time-varying* resynthesis — is already vendored, already wrapped, already cached, already deterministic, and already reaches the render thread through a proven offline seam; what is missing is a monophonic pitch detector we can write ourselves on an MIT FFT we already ship, with no new licence obligation of any kind.

### What makes this a GO rather than a "GO, if…"

Four things that usually sink a subsystem of this size are answered, not deferred:

1. **The pivotal technical question is answered YES, with an upstream citation and source corroboration** (§2), and the one thing it does *not* answer has a named 2–3 day experiment with a kill criterion and a pre-costed fallback (§2.4, §6.5).
2. **Licensing is fully clean.** Not "probably fine" — every dependency in the recommended plan is MIT or our own code, verified by reading the licence text (§9). No GPL, no LGPL, no weights of uncertain provenance, no cash cost unless the escalation fires.
3. **Every "second home" hazard has an owner** (§7.8): one stretch facade, one render cache, one cache-key derivation, one pitch evaluator, one onset detector. Take groups are handled *structurally* by putting the edit set on `Clip` (§7.5) rather than declared out of scope.
4. **Phase 1 ships something a user wants even if the milestone is then parked forever** (§11.2): an agent-controllable auto-tune. Phases 2–4 are additive on top of it, not a rework of it.

### What a NO-GO would have looked like, so the GO is falsifiable

I would have said NO-GO if any of these had held. None do:

- Mid-stream transpose is unsupported ⇒ a segment-shift-splice architecture, the classic artefact source, and a materially larger and riskier estimate. **Refuted in §2 — upstream documents automation as a feature and specifies its timing rule.**
- The only credible detectors are GPL or carry weights we cannot license. **Refuted in §5/§9 — the GPL trap is real for the pYIN reference implementation, and it is avoided by two independent clean routes.**
- Correction requires a real-time path ⇒ pitch DSP on the render thread. **Refuted in §7.6 — editing is offline, `StretchRenderCache` is the proven delivery seam, and the render thread plays a plain CAF.**
- Nothing shippable before the full editor exists. **Refuted in §11.2 — phase 1 is a standalone auto-tune.**

### Conditions the implementing milestone inherits (not conditions on the GO)

1. Phase 0's E1 and E2 run **first**, and E2 is a **human listen** — it cannot be delegated to an assertion.
2. `stretchEngineVersion` (`StretchRenderCache.swift:46`) is **not** bumped for the schema addition; the edit-set hash enters the cache key **only when non-empty** (§7.2, F8).
3. The phase-2 editor gets **its own design doc** before implementation (the m22-b / note-audition precedent).
4. The editor addresses clips **by id** so take lanes work from day one (§7.5, F11).
5. **No pitch DSP on the render thread, ever** (§7.6, F12).
6. **Third-party voice-model import stays permitted** (§8.3). Any future text re-imposing the withdrawn own-voice-only rule is stale and must be corrected, not obeyed.

### Deliberately left unresolved

Stated plainly, because a spike that hides its gaps is worse than one with holes in it:

- **Whether time-varying signalsmith sounds good on a real voice.** Not verifiable without writing code and listening; §2.4 specifies exactly how to settle it. This is the largest unknown (§11.4).
- **The exact `outputLatency` alignment offset.** Derived to ≈2880 samples at 48 kHz from the source (§2.3) but **not measured**; E1(a) measures it.
- **Whether in-house pYIN clears the §5.5 accuracy bar.** Unknowable without building it; the fallback is named and costed.
- **The phase-2 editor's interaction design.** Out of scope for a GO/NO-GO; it needs its own doc.
- **The measured cost of a whole-source re-render on a 4-minute vocal** (F4). Phase 1 must measure and publish it.
- **CREPE's and RMVPE's model-weight licences.** Not verified, because both were rejected on architecture regardless (§5.2, §9). If either is ever reconsidered, **verify the weights separately from the code.**
- **MCP tool count (168).** Carried from the m23-y close record; I measured the 165 wire commands myself (`Sources/DAWControl/Commands.swift:183`) but did not re-derive the MCP figure.

---

## 13. Sources

**Repo (all read directly, 2026-07-29):**
`docs/ROADMAP.md:65,66,68,69,469` · `CHANGELOG.md:1809` · `docs/research/2026-07-05-time-stretch-library-evaluation.md` (full) · `docs/research/2026-07-11-vocals-voice-conversion.md:64,65,67,104,156,158` · `docs/research/m23-q-pitch-correction-survey.md` (skeleton, all `TODO:`) · `Sources/CSignalsmithStretch/vendor/signalsmith-stretch/signalsmith-stretch.h` (`:38-47, 63-94, 107-135, 280-330, 378-406, 495-530, 620-720, 722+, 820-925, 929-983`) · `.../vendor/signalsmith-stretch/LICENSE.txt` · `.../vendor/signalsmith-linear/stft.h:50-80, 267-320` · `.../vendor/signalsmith-linear/LICENSE.txt` · `Sources/CSignalsmithStretch/shim.cpp:4-9, 25-60` · `Sources/CSignalsmithStretch/include/csignalsmith_stretch.h:43-46` and the `css_process`/`css_output_seek`/`css_flush` docs · `Sources/DAWEngine/Stretch/OfflineStretcher.swift` (full) · `Sources/DAWEngine/Stretch/StretchRenderCache.swift` (full) · `Sources/DAWCore/Model.swift:495-507, 552-554, 827, 851-853, 879-889` · `Sources/DAWCore/Takes.swift:10-48, 75-110` · `Sources/DAWCore/ProjectDocument.swift:249-258, 1038, 1058-1088, 1107-1111, 1130-1131, 1244-1263` · `Sources/DAWEngine/Analysis/TempoEstimator.swift:11,21,31,160,255` · `Sources/DAWCore/ProjectStore.swift:8-20, 1669` · `Sources/DAWCore/ProjectStore+Transcription.swift` (full) · `Sources/DAWCore/ProjectStore+TakeAlignment.swift:60-95` · `Sources/DAWCore/Audition.swift:1-30` · `Sources/DAWControl/Commands.swift:183` (165 commands, counted) · `Sources/DAWEngine/Analysis/` (listing) · `scripts/rvc/server.py:199-368` and `scripts/rvc/runtime/src/` (read-only listing; **nothing under `scripts/rvc/` was modified**)

**External (fetched 2026-07-29):**
- signalsmith-stretch README — https://github.com/Signalsmith-Audio/signalsmith-stretch (Automation, Latency, Formant compensation, Pitch-shifting sections)
- Signalsmith Stretch design blog — https://signalsmith-audio.co.uk/writing/2023/stretch-design/ (checked; contains **no** statement on mid-stream parameter changes)
- Signalsmith Stretch project page — https://signalsmith-audio.co.uk/code/stretch/
- pYIN (Queen Mary) — https://code.soundsoftware.ac.uk/projects/pyin · https://github.com/c4dm/qm-vamp-plugins · commercial licence https://eshop.qmul.ac.uk/product-catalogue/special-offers/special-offers/pyin-pitch-tracker
- librosa licence (ISC) — https://github.com/librosa/librosa/blob/main/LICENSE.md
- WORLD licence (modified BSD) — https://github.com/mmorise/World (LICENSE.txt fetched)
- CREPE licence (MIT, code only) — https://github.com/marl/crepe (LICENSE fetched)
- RMVPE licence (Apache-2.0) — https://github.com/Dream-High/RMVPE (LICENSE fetched)
- Rubber Band licensing/pricing — https://breakfastquay.com/technology/license.html (via `2026-07-05-…:16`, not re-fetched in this cycle)
