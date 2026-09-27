# Incremental note render: keep the vocal sounding after a note edit, update only the edited part

Status: WRITTEN DESIGN ONLY (daw-architect, 2026-09-25). Orchestrator edit 2026-09-25: the singer's pronouns
were made neutral (nobody has said who sings on the take). Nothing here is built. Every source claim cites
`file:line` as read on 2026-09-25 in the working tree (branch `m23-wip-2026-08-10`, uncommitted edits present);
anything not read is marked INFERRED.

The user's words (2026-09-25): "is it possible to just play segment and update segment when editing the note, maybe
raw, not precise?" "Play segment" is I1-F1 (audio-dsp-engineer, in flight). This document is "update segment": the
PLAYBACK side.

## 0. Decision summary

**Decision: layered, in three tiers.**
- **Tier 1, the bridge (now, size S).** While a clip's new render is pending, it plays the file it played a moment
  ago, as long as the time base (source, stretch ratio, and later the time warp) is unchanged. Otherwise it stays
  silent, as today.
- **Tier 2, the provisional (after I1-F1, size M).** Its last COMMITTED render, with only the changed region re-rendered
  through I1-F1's span primitive and spliced at two quiet, crossfaded seams, plays until the true whole-file render
  lands. The whole-file render always runs and always replaces it; while the transport rolls, the replacement waits
  for the next reschedule that happens anyway.
- **Tier 1b: no restart at the edit itself.** Optional under Tier 1 alone; required before Tier 2 ships, because Tier 2
  would otherwise put an edit's two whole-mix gaps ~0.3 s apart (§9).
- **Option 3 (a chunked cache that is itself the final) is rejected:** it makes a preview's seams permanent in every
  export.

**What the user hears (§8).**
- Today: the vocal disappears for ~2 s per edit on the 33 s take (longer on longer takes).
- With this design: it never disappears for a note edit; the new pitch arrives in a fraction of a second (G1 target:
  p95 ≤ 400 ms, flat in take length).
- The seams may sound faintly soft for a few seconds, and only where the voice runs on without a pause.
- Level and clear edits are exact at once.

**The finding that shapes everything (§1 R5, INFERRED from the vendored source, to be measured by I1-F1).** The
stretcher carries each frequency bin's phase from block to block, and re-anchors to the input only in near-digital
silence (`signalsmith-stretch.h:508`, `:596-600`). So:
- a re-pitched note changes the waveform, not the sound, of everything after it;
- a span rendered from a cold start cannot match a whole-file render sample-for-sample after earlier transposed
  notes;
- the brief's "splice vs final < −40 dB" is therefore probably unreachable in waveform terms. §12 gates it only if
  R5 shows it is physically reachable, and otherwise gates on pitch and spectral magnitude.

The design is written to be correct under either outcome: seams at quiet points, provisionals transient by
construction.

**Cache-key semantics.** Committed keys stay one key, one content. A provisional is never written at `<key>.caf`,
because a lost rename there counts as success and would make it permanent (`StretchRenderCache.swift:726-734`). It is
never seen by a bounce, and it is always superseded. Only a clip's NODE plays two contents under one key, in turn,
named by a notice and a snapshot field.

**Nothing on the render thread changes, nothing needs full Xcode, and nothing blocks on the user.** One heads-up for
them: the Tier 1 behaviour, §14.

**Owed by others:**
- the proposed ARCHITECTURE.md entry (end of §11), which this lane was not allowed to write;
- forwarding §1 to I1-F1;
- three named follow-ups (§13).

## 1. Requirements for I1-F1's span-render primitive (forward this section now)

**What the playback lane will do with the primitive.** It builds a PROVISIONAL render: the clip's last-played
render with the changed region replaced by a span render, crossfaded at two seams, then served while the true
whole-file render runs; the final replaces it (§6). So the primitive's output must be addressable in the WHOLE-FILE
render's frame space, and the lane must know where old and new renders stop agreeing. Priority: **R1, R2 and R8 block
the playback lane; R3 and R5 are measurements that set its numbers;** the rest are parity and format.

**R1. A frame contract in the whole-file render's delivered-output frame space, not seconds.**
- Input: the same `StretchRenderCache.Params` value the whole-file job receives, the source URL, and a requested range
  `[firstOutputFrame, endOutputFrame)` in frames of the committed CAF.
- Output: exactly `endOutputFrame − firstOutputFrame` frames per channel, planar Float32, at the source rate and
  channel count (the format `performRender` writes, `Sources/DAWEngine/Stretch/StretchRenderCache.swift:620-621`,
  `:717-723`). Result frame `i` IS whole-file frame `firstOutputFrame + i`.
- Every seconds/frames conversion goes through `StretchCurvePlan` only (`sourceSecond(forOutputFrame:)`,
  `outputFrame(forSourceSecond:)`, `firstOutputFrame(atOrAfterSourceSecond:)`,
  `Sources/DAWEngine/Stretch/StretchCurvePlan.swift:59-70`, `:76`, `:96`, `:117`), so C2-3's time warp W reaches both
  entries at once (the file's own banner, `StretchCurvePlan.swift:30-37`). The audition can wrap this with a seconds
  API; the splice cannot, because a second rounding path is a seam offset.

**R2. Start on the whole-file loop's chunk grid, and feed the stretcher exactly what the whole-file loop feeds it.**
- The curve path delivers output in `interval`-frame chunks from delivered frame 0
  (`Sources/DAWEngine/Stretch/OfflineStretcher.swift:505-526`), sets the transpose once per chunk from
  `curveLookupFrame(outputFrame: outDone, …)` (`:512-517`, arithmetic at `:287-296`), and consumes input on a GLOBAL
  schedule, `inTarget = round((outDone + outBlock) × processIn / processOut)`, derived from the WHOLE file's lengths
  (`:500-511`).
- The span entry must begin at a multiple of `interval` from delivered frame 0, sample the curve at the same lookup
  frames, and consume input at the same `inTarget` positions (computed from the whole file's `processIn`/`processOut`,
  not the span's). Otherwise every transpose step lands up to one hop away from where the final puts it: the hop is
  `sampleRate × 0.03` = 30 ms (`OfflineStretcher.swift:250-252`; m23-q research
  `docs/research/m23-q-pitch-correction-design.md:74`).
- Expose `interval` and the compensation `n` (or a "chunk boundaries" function), so the playback diff (R4) uses the
  SAME grid rather than a copy.

**R3. Warm-up and tail: measured, named, and reported as a convergence curve, not one number.**
- Report the span-vs-whole-file residual over the region after the pre-roll, for pre-roll = 0.1 / 0.25 / 0.5 / 1 / 2 s,
  split three ways: pre-roll starting in a gap (low energy) vs mid-voiced-note; note preceded by transposed notes vs
  not; ratio 1 vs 1.5.
- Export the chosen values from the primitive's own module (`minimumPreRollFrames(sampleRate:)`,
  `minimumPostRollFrames(sampleRate:)`, names theirs), so the playback lane never copies a constant.

**R4. The edit's true extent in output frames, computed on the stretcher's own grid (expose the grid; either lane can
write the function, but it lives beside the primitive).**
- Dirty chunks = the chunks `k` where the OLD and NEW plans disagree at `curveLookupFrame(k × interval)`; plus the
  frames where the two level masks disagree. Because the stretcher reads the curve ONLY at those instants, this curve
  comparison is exact, not a heuristic.
- The seam must sit outside that extent plus the stretcher's smear (analysis block `sampleRate × 0.12`,
  `OfflineStretcher.swift:250-252`), not merely outside the note: the 2379-frame compensation
  (`OfflineStretcher.swift:223`) and the retune ramps move the audible change before the note's start.

**R5. Measure the WAKE: how long do the OLD and NEW whole-file renders differ after an edited note ends?** I1-F1's brief
does not ask for this, and the splice cannot be sized without it.
- Two whole-file renders whose sets differ only in one note's offset (+200 c on one of I1's 7 notes). Report the RMS
  residual in 50 ms windows: before the note (expected bit-identical up to the first dirty chunk, since the history is
  identical), inside it, and at +0.1 / +0.25 / +0.5 / +1 / +2 / +5 s after it; and whether it ever falls under −40 dB
  before the next near-digital silence.
- **Why this is the most important number in both designs (INFERRED from source, not measured).** signalsmith carries
  an output phasor per bin, and a transpose changes its RATE of rotation, not its value (m23-q research
  `docs/research/m23-q-pitch-correction-design.md:70`; `Sources/CSignalsmithStretch/vendor/signalsmith-stretch/signalsmith-stretch.h:716`).
  The only re-anchoring to the input's phase is `makeOutput`'s fallback when the prediction's norm is at most
  `noiseFloor = 1e-15` (`signalsmith-stretch.h:596-600`, `:508`), which is near-digital silence, far below a real
  vocal's room noise. The expected consequences:
  - A cold-started span carries a per-bin phase offset against a warm whole-file render after any earlier transposed
    note, and NO pre-roll removes it.
  - Re-pitching note N changes the WAVEFORM (not the sound) of everything after N in the whole-file render.
  - Arithmetic, checked: two equal sinusoids offset by θ differ by an RMS ratio of 2·sin(θ/2). −40 dB therefore needs
    θ ≤ 0.57°. A tuned vocal accumulates radians per note (+20 c on a 200 Hz fundamental for 0.5 s is
    2π · 200 · 0.5 · (2^(20/1200) − 1) ≈ 7.3 rad).
- **If R5 confirms a persistent wake,** the waveform gate "span vs whole-file < −40 dB" is physically unreachable for
  most notes of a tuned take, and I recommend the lane add a second instrument: STFT-magnitude log-spectral distance
  plus pitch-track agreement. It passes phase-shifted, identical-sounding renders, and still goes red on the "no
  pre-roll" plant, because a warm-up error is a MAGNITUDE error. Keep the −40 dB waveform gate only where it is
  physically reachable: a note with no transposed history inside its pre-roll, and the level-only path (R6).

**R6. Level-only parity, bit-exact.** The span entry uses the SAME predicate as `performRender`
(`plan == nil`, level edits present, `OfflineStretcher.isIdentity(ratio:semitones:)`,
`StretchRenderCache.swift:668-688`). On that path the span is source × mask, so the gate is `cmp`-style byte equality
with the whole-file frames, not dB. The mask must be evaluated at GLOBAL output frames (`firstOutputFrame + i`).
Today's `applyLevelMask` is called with no frame offset (`StretchRenderCache.swift:697-701`; declared at
`StretchCurvePlan.swift:155`), so the span needs an offset parameter on that ONE function, default 0, never a copy.
Plant to show red: a span-local mask index.

**R7. Contour and fallback parity.** A contour-shaped set (Hard Tune, drift/vibrato scale ≠ 1) must use the same
detected contour through `PitchContourCache.renderContour`, and the same fallback decision, as the whole-file job
(`StretchRenderCache.swift:603-618`, `:659-664`). A span must never shape against a contour the final will not use.

**R8. Its own slot: never `StretchRenderCache.jobs[clipID]`.** That dictionary is the per-clip latest-wins slot of the
FINAL render (`StretchRenderCache.swift:233-235`, `:481-482`): a span request routed through it cancels the final.
- The primitive should be a plain function callable from any detached task, with no main-actor hop and no shared
  mutable state with the whole-file job, so both can run at once for one clip.
- Callers own their own latest-wins: the audition controller for drags, the provisional builder for playback.
- `isCancelled` is polled per chunk, like the whole-file loop (`OfflineStretcher.swift:506`).

**R9. Determinism and invariance** (already in I1-F1's brief, restated because the playback design rests on them):
the same inputs give bit-identical output, and the whole-file entry is byte-identical before and after the change.

**R10. No file I/O inside the primitive.** ⚠ **RULED 2026-09-25 (orchestrator), after I1-F1 landed:** the primitive writes no AUDIO. A COLD contour-shaped span does write the pitch-contour cache through the shared seam, and that is ACCEPTED. The contour is a deterministic function of the source; `PitchContourCache.swift` ~:269-276 writes a unique `.partial-<UUID>` and then `moveItem`, and the first writer wins. So a span that warms it equals the whole-file render warming it. The original text follows. It returns buffers; the playback lane owns the provisional file and writes
it with `performRender`'s settings (`StretchRenderCache.swift:717-723`), and the audition owns its voice buffer.

**R11. One performance figure:** ms of wall time per second of rendered span, at 48 kHz mono and stereo, and its
independence from take length (the 300 s synthetic). The playback budget in §12 is built on it.

**Evaluated and NOT required for v1: "render with the PREVIOUS set's context".** What that would buy is removing the
LEFT seam's phase offset, by starting the span from the base render's own stretcher state (a checkpoint). That
requires copying the C++ stretcher object, which the flat-C shim does not expose: it is an opaque handle
(ARCHITECTURE.md:1033) driven through `css_create` … `css_destroy` (as used at `OfflineStretcher.swift:419-534`), and it
does not even expose `configure` (m23-q research `:76`). v1 does not need it, because the seams go where the
curves agree AND the audio is quiet (§6), where a phase offset has almost nothing to cancel. The only ask is not to
design the shim in a way that forecloses a later `css_clone(handle)` (INFERRED feasible: the stretcher's state is
standard containers; not read).

## 2. The problem, verified in the source

One note edit, followed through the code as it stands today:

1. **The edit re-keys the render.** `StretchRenderCache.Params` derives `pitchEditSetHash` from the clip's
   `PitchEditSet` in its own `init` (`Sources/DAWEngine/Stretch/StretchRenderCache.swift:100-110`), and the on-disk key
   appends `pitch:<digest>` whenever the set bends anything (`StretchRenderCache.swift:390-392`). Any change to any
   note's offset, level, clear flag or shaping therefore yields a NEW 16-hex key with no committed CAF behind it.
2. **The edit also re-keys the graph node, which tears the old node down.** `PlaybackGraph.ClipKey` carries
   `pitchEditSetHash` as schedule identity (`Sources/DAWEngine/PlaybackGraph.swift:56-66`). On reconcile, a clip whose key
   changed has its player stopped, detached and removed (`PlaybackGraph.swift:985-996`). The previous render's CAF is
   still on disk, but nothing plays it any more.
3. **The new key resolves to `.pending`, and pending means NO node.** The add loop asks the resolver
   (`PlaybackGraph.swift:1013-1014`); the engine's `resolveStretch` finds no committed file for the new key, kicks the
   render, and answers `.pending` (`Sources/DAWEngine/AudioEngine.swift:2351-2376`). The graph records a
   `PendingRenderSilence` and skips the clip: "while the render is pending the clip gets NO node — silence, never
   wrong-speed or untuned audio" (`PlaybackGraph.swift:1003-1027`; the enum's own doc at `PlaybackGraph.swift:75-84`).
4. **The render is whole-file, after a debounce.** The job sleeps 250 ms (`StretchRenderCache.swift:203`, `:497`),
   then a detached `performRender` reads the ENTIRE source into memory (`StretchRenderCache.swift:620-643`), runs the
   stretcher (or the curve stretcher, or the level-only copy) over all of it (`:659-693`), applies the level mask
   (`:697-701`), writes a Float32 CAF partial and renames it into place (`:717-734`). Its cost is linear in take
   length (INFERRED from the whole-source read and whole-source stretch; the long-take lane's results in
   `DUR/i1-long-take/` had not landed when this was written).
5. **Only completion brings the sound back.** `kickStretchRender` awaits `renderIfNeeded`, checks the key is still
   the desired one, then calls `graph.invalidateClipSchedule(clipID:)` and `tracksDidChange(lastTracks)`
   (`AudioEngine.swift:2384-2402`); the next reconcile resolves `.ready` and opens the new CAF.

**Measured cost (not re-measured here):** the I1 lane measured 1748 ms median from commit to the re-rendered note
being playable on the user's 33 s take (quoted by the brief and by
`scratchpad/briefs/i1-f1-span-render.md:10,21`). The silence window during playback is therefore about 1.75 s per
edit at 33 s, and grows with take length.

**Two amplifiers the brief does not name, both read in the code:**

- **A burst of edits keeps the clip silent for the WHOLE burst plus one render.** Each edit changes the key, so
  `renderIfNeeded` cancels the in-flight job (latest-wins, `StretchRenderCache.swift:481-482`) and starts a fresh
  250 ms debounce. Five nudges one second apart on a 33 s take mean about 4 s + 1.75 s of silence (from the first
  nudge to the last render's landing). A 180 s take, if
  render time is linear, would be tens of seconds of intermittent silence (INFERRED).
- **Undo is an edit like any other.** Undo restores the previous `PitchEditSet`, whose key's CAF is usually still on
  disk (nothing in `StretchRenderCache` deletes a superseded entry: there is no eviction code in the file,
  `StretchRenderCache.swift:1-740`). So undo is ALREADY fast, as long as the file survives: resolve finds it
  committed (`AudioEngine.swift:2366-2372`) and the clip gets a node in the same reconcile. INFERRED: not measured.
  This matters for the options below; the cache is already content-addressed, which is exactly what makes "the same
  key can never map to two contents" true today.

## 3. Why silence was chosen: spec §5 and the history of "honest silence"

**Where the rule comes from.** M5 (ii-a), 2026-07-05, settled the time-stretch seam: "debounced latest-wins async
render w/ silence-while-pending, identity = exact bypass" (`docs/ROADMAP.md:130`). ARCHITECTURE.md records the same
entry, "silence while pending", and defers "real-time preview (later via AVAudioUnitTimePitch scrub, not signalsmith
`splitComputation`)" (`docs/ARCHITECTURE.md:1502`). The full memo was a session scratchpad file, `stretch-seam-spec.md`
(`ARCHITECTURE.md:1502`). **It is UNRECOVERED:** a bounded search of this machine's session scratch root found no such
file, and the same search found this design's brief, so the search itself worked. The surviving record of "spec §5" is
ARCHITECTURE.md:1502, ROADMAP.md:130/133 and the code comments quoted below.

**What it protected against, in its own words: SPEED.**
- "never wrong-speed audio (spec §5)" (`Sources/DAWEngine/PlaybackGraph.swift:80-81`).
- "the clip schedules as silence, never wrong-speed audio" (`Sources/DAWEngine/AudioEngine.swift:2347-2350`).
- "`stretchedFileProvider` seam (nil → silent, never wrong-speed)" (`docs/ROADMAP.md:133`).

In M5 the ONLY alternative to silence was the unrendered SOURCE. A stretched clip's schedule maps its file offset as
`startOffsetSeconds × ratio` against the rendered CAF (`ARCHITECTURE.md:1502`), and the stretch fields "change which FILE
the node opens … and every frame position" (`PlaybackGraph.swift:34-36`). The source played through that schedule is at
the wrong speed AND in the wrong place. That is not an approximation of the result; it is garbage that sounds like a
bug. Silence was the honest choice against THAT alternative.

**What m23-q added: two words, and no new argument.** When pitch edits joined the render key and the node key
(`PlaybackGraph.swift:56-66`; `Sources/DAWEngine/Stretch/StretchRenderCache.swift:78-88`), the add-loop comment became
"silence, never wrong-speed or untuned audio" (`PlaybackGraph.swift:1006-1007`). No separate argument for "untuned"
appears in the sources read (the m23-q research, the pitch-editor UI design, the interaction-batch design). The
alternative in view was still the unrendered source: a tuned clip whose render is pending would otherwise play its
untuned original as if it were the result.

**What the hash in `ClipKey` guards is PERMANENT staleness, not a brief one.** "Without it, editing a note re-keys the
render CACHE … while the graph, seeing an unchanged key, keeps the clip node it already has and goes on playing the OLD
file: a correction the user made, rendered correctly, and never heard" (`PlaybackGraph.swift:58-64`). That defect is an
old file that is never replaced. A transient bridge that is always replaced when the render lands is a different
mechanism, but it must keep the guarantee. **The one path that would recreate the original defect is a render that
FAILS:** its status is `.failed` and sticky until the next job (`StretchRenderCache.swift:236-239`, `:541-547`), so a
bridge that outlived a failure would play the old file forever. §5 ends the bridge on failure.

**The house has already said silence during editing is a cost, not a virtue.**
- The pitch editor commits once, at gesture END, precisely because per-tick commits "would re-key the clip at pointer
  rate … So the vocal would go SILENT for the entire duration of every drag. Gesture-end commit keeps the previous render
  playing until release" (`docs/design/2026-09-22-pitch-editor-ui.md:1108-1113`). The previous render already keeps
  sounding DURING every drag, by construction; only the post-release window is silent.
- P10 accepted the whole-file re-render per tweak "for v1", made visible by `ClipShimmer`, with the cost to be measured
  and published (`pitch-editor-ui.md:1292`; m23-q research `docs/research/m23-q-pitch-correction-design.md:136`).
- The interaction batch names it F15: "a commit silences the clip until its render lands"
  (`docs/design/2026-09-24-pitch-editor-interaction-batch.md:161`). The user's words of 2026-09-25 name the same cost.

**The rule this design keeps (the reason survives; the letter narrows).** Never play audio whose TIME BASE differs from
the render the clip asked for. That excludes:
- the unrendered source;
- a previous render at a different `stretchRatio`;
- a previous render of a different source file (path, size or mtime; `StretchRenderCache.swift:350-357`);
- once C2-3 makes the render read the time warp, a previous render under a different W.

A previous render with the SAME time base plays at the right speed and in the right place. It differs from the
requested render only inside the edited notes, and only in pitch or level. That is the case this design opens, only
while the new render is pending, and with a notice that says what is playing (§5). Offline rendering is untouched:
`renderMixdown` still waits for pending renders and the bounce never sees a bridge or a provisional
(`docs/ROADMAP.md:133`; §6).

## 4. The mechanism today: render key, pending state, cache, restart seam

The options below modify this model, so it is stated once, precisely.

**Three identities, and what each one answers.**

| Identity | Where | Answers | Built from |
|---|---|---|---|
| Render key (`RenderKeys.resolved` / `.legacy`) | `StretchRenderCache.swift:146-160`, `:376-413` | "Which bytes are the render of this (source, params)?" | SHA256 over source path, size and mtime, the ratio and semitone bit patterns, the formant flag, the engine version, plus `pitch:<digest>` and `contour:`/`shaping:` only when used |
| Node key (`PlaybackGraph.ClipKey`) | `PlaybackGraph.swift:37-67`, built at `:919-929` | "Must this clip's player be torn down and rebuilt?" | Clip geometry, fades, gain envelope, the three stretch fields, the edit digest |
| Kick dedupe (`AudioEngine.stretchDesired`) | `AudioEngine.swift:2384-2387` | "Has a render for this key already been asked for?" | The resolved key, overwritten at every kick |

**Resolution (main actor, at reconcile).** The graph's add loop calls the resolver for a clip that needs a render
(`PlaybackGraph.swift:1013-1014`). `resolveStretch` derives the keys once, returns `.ready(url)` if
`committedURL(for:)` finds a file, and otherwise kicks the render and returns `.pending`
(`AudioEngine.swift:2351-2376`). `committedURL` checks the resolved key's file, then this session's contour-fallback
memo (`StretchRenderCache.swift:171-179`). `.pending` means the clip gets no node, and the pass records a
`PendingRenderSilence` (`PlaybackGraph.swift:1019-1027`).

**The job (`renderIfNeeded`, `StretchRenderCache.swift:467-553`).**
- Fast paths: identity params return the source (`:468-470`); a committed file returns immediately (`:471-474`).
- Single-flight on the same key (`:478-480`); latest-wins across keys, which cancels the older job (`:481-482`).
- A 250 ms debounce (`:497`), then the detached `performRender` (`:504-512`). It reads the WHOLE source (`:620-643`),
  runs one of three branches (curve stretcher, level-only copy, constant stretcher; `:659-693`), applies the level
  mask (`:697-701`), and writes a Float32 CAF `.partial-<token>` that it renames into place (`:717-734`).
- ⚠️ **A lost rename race where the target already exists counts as SUCCESS and leaves the existing file in place**
  ("identical bytes by determinism", `:726-734`). Anything written at `<key>.caf` that is not the true render of
  `<key>` would therefore become that key's permanent content. §6 depends on this.
- Status: `.rendering` while a job is in flight; `.failed` after a non-cancellation error, sticky until the next job
  (`:236-239`, `:540-547`).

**Completion: the restart seam.** `kickStretchRender` awaits the job, checks the key is still the desired one, then
calls `graph.invalidateClipSchedule(clipID:)` and `tracksDidChange(lastTracks)` (`AudioEngine.swift:2388-2402`).
- `invalidateClipSchedule` stops and detaches that clip's player and drops its signature entry
  (`PlaybackGraph.swift:2511-2530`).
- The reconcile re-adds the clip with the new CAF. If anything changed while the engine runs, `tracksDidChange`
  calls `restart(fromBeat:tempoMap:cause: .continuation)` (`AudioEngine.swift:1225-1231`).
- `restart` is "stop-all → reschedule-from-beat → re-anchor → resume … costs one ~60 ms lead-in gap"
  (`AudioEngine.swift:4398-4400`, body `:4415-4435`). It stops EVERY player, not just the edited clip's.
- So while the transport rolls, one note edit today costs TWO whole-mix restarts: one at the edit (the node key
  changed, so the node is removed) and one at completion (the node is re-added). The vocal is silent between them.
  INFERRED from the code path; not measured.

**What the user and agents are told.** `clip-stretch-pending` is posted from `scheduleAll` only, so only when playback
actually plays the gap (`PlaybackGraph.swift:3016-3031`). For a tuned clip its copy reads "the clip plays as silence
until it's ready" (`:3040-3045`).

**Offline rendering never sees a pending state.** `cachedURL` answers from committed files only
(`StretchRenderCache.swift:435-442`), and `renderMixdown` waits for pending renders (`docs/ROADMAP.md:133`).

**Files, sizes and lifetime.**
- A render is Float32 at the source rate and channel count, covering the whole source (`StretchRenderCache.swift:10-13`):
  frames × ratio × channels × 4 bytes. That is about 6.3 MB for 33 s mono at 48 kHz, and about 115 MB for 300 s stereo
  (arithmetic; the user's take's channel count was not checked).
- **Nothing evicts renders.** The `StretchRenders` folder is referenced only where it is defined
  (`StretchRenderCache.swift:10`, `:271`) and by the contour cache's subfolder (`PitchContourCache.swift:15`). A grep of
  `Sources/` for eviction or removal of these files found nothing else. Every committed edit leaves a whole-file CAF
  behind. That is why undo is usually instant today (the old key's file is still there), and also an unbounded disk
  cost (§10).
- A player streams its file from its own thread ("`scheduleSegment` streams from that instance on its own thread",
  `PlaybackGraph.swift:94-97`). A file must therefore never change after a node opens it.
- The dedupe remembers that a key was ASKED FOR, not that its file still exists. A committed CAF deleted under a running
  app plays silence until the key changes (`StretchRenderCache.swift:16-22`). Any design that reuses an old file must
  re-check that it exists.

## 5. Option 1: stale-but-sounding

**The idea.** While a clip's new render is pending, keep playing the file it played a moment ago, as long as that
file has the same time base (§3's rule). It is called "the bridge" below.

**Mechanism (engine only; `ClipKey` unchanged).**
1. **A memo of what each clip last played.** `AudioEngine` keeps `lastPlayed[clipID] = (fileURL, sourceIdentity,
   ratio, timeWarpDigest?)`. The graph reports it through a closure every time its add loop opens a file for an audio
   clip (`PlaybackGraph.swift:1012-1035`), for identity clips (their source) and rendered clips (their CAF) alike. The
   memo lives in the engine rather than the graph because `rebuildEngine` discards the graph but keeps the caches
   (`docs/ARCHITECTURE.md:1508`). It is pruned in `syncStretchRenders` (`AudioEngine.swift:2439`).
2. **A new resolution case.** `StretchResolution` gains `.bridge(URL)` beside `.ready` and `.pending`
   (`PlaybackGraph.swift:75-84`). `resolveStretch` returns it where it returns `.pending` today
   (`AudioEngine.swift:2374-2375`), still after kicking the render, when the memo passes ONE predicate:
   - the source identity fields are equal (path, size, mtime; `StretchRenderCache.swift:350-357`);
   - `stretchRatio` is bit-equal;
   - the time-warp digest is equal, but only once the render reads W (C2-3). Until then timing deltas are not part of
     the time base, because the render ignores them (`docs/ARCHITECTURE.md:579`);
   - the clip's status is not `.failed`;
   - the memo's file still exists (the deleted-CAF caveat, `StretchRenderCache.swift:16-22`).
3. **The graph treats `.bridge(url)` exactly like `.ready(url)`: it opens the file.** It also records a
   `PendingRenderBridge` for the notice, in place of `PendingRenderSilence` (`PlaybackGraph.swift:1025-1026`).
4. **The bridge ends on any of four events:**
   - the render commits → the existing completion seam swaps in `.ready(new)` (`AudioEngine.swift:2396-2401`);
   - the render FAILS → the kick's catch path (`AudioEngine.swift:2393-2395`, which today simply returns) gains the
     same invalidate + `tracksDidChange`, so the next resolve sees `.failed`, answers `.pending`, and the clip goes
     silent with its failure visible. This is the rule that stops §3's "never heard" defect from coming back;
   - the time base changes → the predicate fails → silence, as today;
   - the file vanishes → silence, as today.
5. **The notice.** A new, additive code `clip-render-previous`, posted from `scheduleAll` like `clip-stretch-pending`
   (`PlaybackGraph.swift:3016-3031`): "'NAME' is playing its previous version for a moment: your latest change is
   still being prepared." The `clip-stretch-pending` copy stays for true silence, since today it says "plays as
   silence" (`:3040-3045`) and would lie about a bridge.

**Tier 1b (optional; measured before it ships): no restart at the edit itself.** Today the digest in `ClipKey`
forces a teardown at the edit, and that teardown is what triggers re-resolution (`PlaybackGraph.swift:984-996`, `:58-64`).
The refinement: when two keys differ ONLY in `pitchEditSetHash`, re-resolve in place (which still kicks the render). If
the answer is the file the node already has open (the bridge), keep the node and adopt the new key. This saves one
~60 ms whole-mix gap per edit while rolling. It cannot recreate "never heard", because completion ALWAYS invalidates
the clip explicitly (`AudioEngine.swift:2400`), whatever the key says. Gate: the existing edit-reaches-the-node
behaviour stays green, and a spy counts restarts per edit (2 → 1).

**The brief's axes:**
- **Cache-key semantics.** Unchanged, and nothing is written. Every committed key still maps to exactly one content;
  the bridge serves an OLD key's file under the NEW node key. The graph's "node key → file" is many-to-one while a
  render is pending. That is acceptable because it is never persisted, never seen offline (`cachedURL` is
  committed-only, `StretchRenderCache.swift:435-442`), and is named by the notice.
- **Seams.** None. The bridge is a complete, self-consistent render; the switch to the final swaps the whole file.
- **Stretch ratio ≠ 1.** It bridges only when the ratio is unchanged, so a stretch edit keeps today's silence. That is
  exactly the case the M5 rule was written for.
- **I7a level-only path and cleared notes.** It bridges (same time base), so a just-cleared breath keeps sounding until
  the render lands. That is Tier 1's most noticeable artefact, and the notice names it. The level-only render never runs
  the stretcher (`StretchRenderCache.swift:678-688`), so its render time is INFERRED to be far below 1.75 s and
  dominated by the 250 ms debounce (not measured).
- **C2 time warp.** Before C2-3 a timing-only edit re-keys (`ARCHITECTURE.md:579`) but renders identical audio, so the
  bridge is EXACT. After C2-3 a different W fails the predicate and the clip is silent, as today. W(D) = D
  (`ARCHITECTURE.md:579`) means the previous render is wrong only locally, so widening this is a v2 question, not
  designed here.
- **Render-completion restart seam.** Unchanged.
- **Transport running while the swap lands.** The same two restarts per edit as today (one with Tier 1b), each a
  ~60 ms whole-mix gap (`AudioEngine.swift:4398-4400`). **Not glitch-free**, but no new gap: what changes is sound
  between the gaps instead of silence.
- **Disk and memory.** Zero new bytes; one more open `AVAudioFile`.
- **Undo/redo.** Undo to a committed key → `.ready`, as today (§2). Undo to a key whose render was superseded
  (latest-wins) → the bridge, so it does not mute.
- **Real-time safety.** No render-thread change. The graph opens and schedules a file exactly as for `.ready`. The memo
  and predicate are main-actor bookkeeping, plus a `fileExists` and the stat the key derivation already pays.

**What it does NOT do:** deliver the new pitch sooner. The user still waits the full render (1.75 s at 33 s, growing
with length) to hear the edit in playback. And once I1-F1 ships, the release audition plays the NEW pitch while
playback, a moment later, plays the OLD one.

**Size S · `audio-dsp-engineer`.**

## 6. Option 2: splice, served as a provisional render

**The idea.** On an edit that keeps the time base (§3), build a PROVISIONAL file: the clip's last COMMITTED render,
with the region the edit changes replaced by a span render (I1-F1's primitive), joined at two crossfaded seams at quiet
points. Serve it until the true whole-file render commits. The whole-file job is unchanged and always runs, so every
approximation here is TRANSIENT by construction. Tier 1's bridge (§5) covers the moments before the provisional
exists.

**Mechanism.**
1. **Base = the last COMMITTED file this clip played with the same time base,** or its source if it was an identity
   clip. Never another provisional: chaining would make the content depend on edit history. The engine memo of §5
   gains a second slot, `lastCommitted[clipID] = (fileURL, Params, keys)`, updated only on `.ready` or an identity
   open.
2. **The dirty extent, from the two edit sets alone, on the stretcher's grid (R4).**
   - Chunks where the two plans' transpose values differ at `curveLookupFrame(k × interval)`; a missing plan counts as
     the zero curve.
   - Frames where the two level masks differ.
   - After C2-3, chunks where the input schedule differs (a changed W moves WHICH source audio feeds an output frame,
     even at equal pitch).
   - Plus the stretcher's smear. An empty extent means the new render is predicted identical: the base itself is
     served (see "timing-only edits" below).
3. **The cap.** Build a provisional only when its whole span (extent, seam search, pre-roll and post-roll) is at most
   40 % of the file's output length AND at most 20 s. Otherwise the bridge plays until the final. Both numbers are
   defaults to be set by measurement (§12).
4. **Seams at quiet points, outside the extent.**
   - Search the BASE render over [extent start − 1.0 s, extent start − smear] for the left seam, and the mirror window
     for the right seam. Pick the frame of minimum 10 ms RMS.
   - At or below −40 dB under the clip's active RMS: a 10 ms crossfade. Otherwise (continuous singing): a 30 ms
     crossfade.
   - The crossfade law comes from the two sides' measured normalised correlation over the window: ρ ≥ 0.9 gives
     equal-gain (the sides are the same signal, and equal-power would bump +3 dB); below that, equal-power.
   - Every number is a measured default (§12). The phase reasoning is §1 R5: a cold-started span and a warm base carry
     different per-bin phases whenever transposed notes precede them, and a quiet seam leaves that offset almost
     nothing to cancel.
5. **The span render.** I1-F1's primitive over [L − xf/2 − preRoll, R + xf/2 + postRoll], snapped outward to the chunk
   grid (R1-R3).
6. **The file: clone and patch, never at `<key>.caf`.**
   - Clone the base (`FileManager.copyItem`; INFERRED to be an O(1) copy-on-write clone on APFS, not measured) to a
     `.partial` name.
   - Overwrite frames [L − xf/2, R + xf/2) in place through AudioToolbox `AudioFileWritePackets` (one Float32 LPCM
     frame per packet; INFERRED supported for CAF in read-write mode). Close, then rename to
     `StretchRenders/Provisional/<session>/<newKey>~<baseKey>.caf`.
   - The REFERENCE implementation is a streaming rewrite with `performRender`'s settings
     (`StretchRenderCache.swift:717-723`); it is also the fallback when cloning fails. The gate: clone-and-patch output
     is byte-identical to the rewrite.
   - The name is load-bearing: a file at `<newKey>.caf` would become that key's permanent render through the
     lost-rename rule (`StretchRenderCache.swift:726-734`, §4).
7. **A resolution tier.** `resolveStretch` answers, in order:
   - committed → `.ready(url)`;
   - a provisional for (newKey, baseKey) exists → `.provisional(url)`;
   - bridge-eligible → `.bridge(url)`, and kick the provisional build;
   - otherwise `.pending`.

   The final's kick is unchanged in every branch. Provisional builds run in their own latest-wins slot, keyed by clip,
   with one in flight and one queued (R8); they never touch `jobs[clipID]`.
   ⚠️ **The provisional slot has NO debounce.** A pitch-editor edit is already one commit per gesture
   (`docs/design/2026-09-22-pitch-editor-ui.md:1091-1092`), so latest-wins is the provisional's only rate limit.
   Copying the whole-file job's 250 ms debounce (`StretchRenderCache.swift:497`) would eat most of G1's 400 ms budget
   by itself.
8. **Completion.** A provisional that lands re-enters the same seam as a final (`invalidateClipSchedule` +
   `tracksDidChange`, `AudioEngine.swift:2396-2401`).
9. **Deferred final swap while rolling** (gated by the §12 perceptual gate). When the final commits while the transport
   rolls AND the clip is playing its provisional, the engine does not restart at once. It marks the clip, and the swap
   rides the NEXT reschedule that happens anyway: stop, seek, another edit, a loop change, a rebuild (every such path
   ends in `startPlayers`, `AudioEngine.swift:4433`). A stopped transport swaps at once, at no audible cost. If the
   gate fails (the provisional is audibly different from the final), swap at once.
10. **Honesty surfaces (additive).**
    - A notice `clip-render-preview`: "'NAME' is playing a quick preview of your change; the exact version replaces it
      in a moment."
    - A per-clip snapshot field `renderAudible: exact | preview | previous | silent`, so an agent knows what it is
      hearing.
    - A bounce is unaffected: it waits for the final (`docs/ROADMAP.md:133`).

**Two special cases that are EXACT, and cost no span render.**
- **Level-only diffs on the curve path** (the set bends pitch elsewhere; the edit changes only a level or a clear).
  - The curves are equal, so the stretcher output is identical, and the mask is applied pointwise after it
    (`StretchRenderCache.swift:694-701`). So provisional = base × newMask / oldMask over the extent, exact to float
    rounding, with no seams.
  - Valid only where oldMask ≥ 1e-3. Un-clearing a note cannot be recovered from a zeroed base, so it takes the
    general path.
- **The level-only branch on both sides** (ratio 1, no pitch edits; `StretchRenderCache.swift:678-688`). The span is
  source × mask, bit-exact with the final (R6).
  - The seams join identical frames, so they are hard cuts with no crossfade, and the provisional is byte-identical to
    the final.
  - Its later swap is inaudible, so it is always deferred.
- **A SOURCE base** (an identity clip's first edit) is not a Float32 CAF; the source may be 16- or 24-bit WAV/AIFF.
  So its provisional always takes the streaming-rewrite path, reading through `AVAudioFile.processingFormat` exactly
  as `performRender` does (`StretchRenderCache.swift:620-643`). The level-only case above then stays byte-identical to
  the final.
- **Timing-only edits before C2-3.** These re-key without changing the audio (`docs/ARCHITECTURE.md:579`). The extent
  is empty and the base is served as the provisional: exact, and instant.

**The brief's axes:**
- **Cache-key semantics.** Committed keys stay one key, one content: a provisional is never at `<key>.caf`, never
  returned by `committedURL`/`cachedURL` (`StretchRenderCache.swift:171-179`, `:435-442`), and never seen offline. At
  the NODE level one key (newKey) plays two contents in turn, provisional then final. A provisional's content is a pure
  function of (baseKey, newKey, seam parameters, primitive version): deterministic and reproducible, just not newKey's
  content. That is acceptable under four guards: never at the key's path, never offline, always superseded (by the
  final or a newer edit), always named.
- **Seams.** As mechanism step 4. Warm-up is covered by the pre-roll (R3); phase by quiet placement (R5); crossfade
  10 ms or 30 ms; law by correlation.
- **Stretch ratio ≠ 1.** Handled: all arithmetic is in the whole-file render's OUTPUT frames (R1), and chunk-grid
  alignment (R2) is what keeps transpose steps where the final puts them when `processIn / processOut ≠ 1`. Ratio
  changes are not provisional (§3).
- **I7a level-only path and cleared notes.** The exact special cases above.
- **C2 time warp.** Once the primitive is W-aware, a timing edit keeps the file length (W(D) = D,
  `ARCHITECTURE.md:579`), so a splice in output frames works, with the input-schedule term in the extent. Tier 2 covers
  timing edits where Tier 1 must stay silent.
- **Render-completion restart seam.** Unchanged and reused. Two completions per edit (provisional, final); the final's
  swap is deferred while rolling.
- **Transport running while a swap lands.** Provisional-in costs one ~60 ms whole-mix gap
  (`AudioEngine.swift:4398-4400`). That is the moment the user's edit arrives, so the gap marks it. Final-in rides the
  next reschedule (zero extra gaps). The edit itself costs one gap, or none with Tier 1b. So 2 gaps per edit (1 with
  Tier 1b), against today's 2. **Not glitch-free; nothing through `restart` can be.** A glitch-free swap needs a
  per-clip mid-roll join with a baked crossfade: a new graph capability under the engine-lifecycle rules
  (`ARCHITECTURE.md:1508`, `:1022`). Named as a follow-up in §10, not in v1.
- **Disk and memory.** About span-sized per provisional with clone-and-patch (INFERRED), about full-file with the
  fallback rewrite (up to ~115 MB for 300 s stereo). At most 2 live per clip; deleted on supersession; the session
  folder is wiped at launch. Memory: the span buffer (at most ~7.7 MB at the 20 s cap, stereo 48 kHz) plus ≤ 2 s of
  seam-search reads.
- **Undo/redo.** Undo to a committed key → `.ready`, instant. Undo to a superseded key → a provisional from the base,
  with the bridge meanwhile. Provisionals are memoised by (newKey, baseKey), so undo then redo reuses one still on disk.
- **Real-time safety.** Nothing new on the render thread:
  - the diff, seam search, span render and file assembly run in detached tasks;
  - resolution and the node swap use the existing main-actor seam;
  - a provisional is complete and renamed before any node can open it, and never modified after (the streaming-thread
    rule, `PlaybackGraph.swift:94-97`);
  - no new nodes, scheduling code or locks.

**Size M (engine) + S (surfaces) · `audio-dsp-engineer`, `mcp-integration-engineer`; `swift-app-engineer` optional
(§13).**

## 7. Option 3: segment-granular cache

**The idea.** A clip's render becomes a composition of chunks with FIXED boundaries. Each chunk is rendered on its own
(cold-started, with pre-roll) and keyed by the source identity, its bounds, the clip params, and the edits that
intersect it plus context. An edit re-renders only the dirty chunks, and the composition IS the final: there is no
background whole-file render.

**Its one real advantage: the cleanest key semantics of the three.** Each chunk key maps to one content, and the
composition is a pure function of the chunk keys. The same key never maps to two contents, even transiently, and there
is only one swap per edit.

**Why it loses.**
- **"Raw" becomes permanent.** A concatenation of cold-started chunks equals no continuous render: the phase-carry
  argument of §1 R5 applies at every boundary. So the seams live in every bounce and every export. The user accepted
  raw as the price of a fast PREVIEW ("maybe raw, not precise", while editing), not for the finished song.
- **The house has rejected this shape twice.** M5 chose whole-file renders because "full-file rendering makes split
  points seamless (shared phase-vocoder output)" (`docs/ARCHITECTURE.md:1502`). The C2 timing design rejected cutting
  at note boundaries: "It multiplies clips, crossfades and cache entries by the note count, breaks the whole-file render
  that keeps a split clip phase-coherent, and puts a seam where the singer did not stop" (`ARCHITECTURE.md:579`).
  Chunks at SOURCE quiet points instead of notes soften the last clause, not the first two. And a singer who holds a
  legato line for 15 s either gets a 15 s chunk (slow) or a voiced seam (audible, permanently).
- **Boundaries must be stable across edits, or keys cascade.** So they must come from the source alone (a per-source
  analysis cached like the contour, `PitchContourCache`). But after C2-3 a timing edit moves audio across a boundary: W
  changes in the gap beside a moved edge (`ARCHITECTURE.md:579`), so the chunk layout itself becomes edit-dependent.
- **Migration.** A new key scheme re-renders every tuned clip on every user's disk. The m23-q design named exactly that
  as a failure to avoid for the digest: "one release, every user re-renders every stretched clip"
  (`docs/research/m23-q-pitch-correction-design.md:753`). Or it keeps two render definitions (chunked for tuned clips,
  whole-file for stretched ones), with twice the parity surface.
- **Playback must play the composition.** Either a composed file per edit (a full-length write, as in §6's fallback) or
  several files per clip in the graph. The latter is a scheduling change across fade bake, piece plans and loop unroll
  (`PlaybackGraph.swift:3048+`): RT-adjacent code that neither other option touches.

**The brief's axes, briefly:**
- **Cache-key semantics:** clean (above).
- **Seams:** permanent; quiet where the source allows, voiced in long legato.
- **Ratio ≠ 1:** workable, but every chunk needs R2's grid alignment.
- **I7a:** level-only chunks are exact.
- **C2:** hard (above).
- **Restart seam:** one completion per edit.
- **Transport running:** 1-2 gaps per edit, like §6.
- **Disk:** chunk versions accumulate per edit and need their own eviction, plus a composed file per edit.
- **Undo:** fast (chunks cached).
- **RT safety:** fine with composed files; a risk if the graph schedules chunk lists.

**What it would need that the others do not:** a listening gate with the user's pick on a PERMANENT change to how
every tuned vocal sounds (the house listening rule: show options, their pick is the feedback).

**Size L-XL · `audio-dsp-engineer` (render, keys, migration), `swift-app-engineer` (none unless chunks surface),
plus a user listening round.**

## 8. What the user hears, per option (plain words)

The scene: a phrase is looping while you fix one note. You drag the note up and let go. (The "stutter" below is the
split-second gap the app already makes for EVERY edit during playback, `AudioEngine.swift:4398-4400`. No option here
makes it worse, and removing it is a separate follow-up, §10.)

**Today.** The moment you let go, the whole song stutters and the singer disappears. The music plays on without the voice
for about 2 seconds on the half-minute recording (measured: 1.75 s median). It is longer on a whole song: it grows with
the recording's length, and those measurements have not landed yet. Then the song stutters again and the voice comes back,
singing your new note.

**Option 1: keep the old version playing.** The moment you let go, the song stutters, but the singer keeps singing,
with your note still the OLD way. After the same ~2 seconds (longer on long recordings), the song stutters again and
the note jumps to your new pitch. If you just silenced a breath, you still hear the breath until that moment.

**Option 2: a quick patched version, then the exact one (recommended).** The moment you let go, the song stutters and
the singer keeps singing (the old version, for a moment). Within about a fifth to half a second (the target; to be
measured), the song stutters once more and your note sounds at its new pitch.
- Right where the patch joins the rest of the recording, you may hear a faint softness or "swish" for a moment, and
  only if the voice ran on without a pause there. The patch is placed in the singer's pauses whenever there is one within a
  second.
- A few seconds later the exact version takes over. While the song keeps playing you will not hear that swap: it
  waits until you stop, jump, or make another edit.
- Making a note quieter, or silencing it, is exact from the first moment.

**Option 3: rebuild only the changed piece, for good.** Like Option 2, the new pitch arrives within a fraction of a
second and nothing is swapped later. But the joins between pieces stay in the song permanently, in the exported file
too. In a long, smooth sung line you might hear a faint "swish" at each join, forever.

**If the transport was stopped and you press play right after the edit:**
- Today: silence where the vocal should be, then it pops in.
- Option 1: the old note.
- Option 2: the old note for at most about half a second, then the new one.
- Option 3: the old note, or silence, for a fraction of a second, then the new one.

**With Tier 1b** (§5), every option loses the stutter at the moment you let go.

## 9. Comparison, decision, and why the two strongest alternatives lose

| | Today | 1: bridge | 2: provisional splice | 3: chunked cache |
|---|---|---|---|---|
| New pitch audible after | full render (1.75 s at 33 s; grows) | full render | provisional (target p95 ≤ 400 ms, §12) | chunk render (similar to 2) |
| Silence after an edit | the full render | none while the time base holds | none while the time base holds | chunk render, unless bridged |
| Committed key → content | 1:1 | 1:1 (nothing written) | 1:1 (provisionals never at `<key>.caf`) | 1:1 |
| Node key → content | 1:1 | old file while pending | provisional, then final | 1:1 |
| Seams | none | none | 2 per edit, quiet-placed, TRANSIENT | at every chunk, PERMANENT |
| Level/clear edits | full render | old level until the render | EXACT at once (§6) | exact |
| Timing edits (after C2-3) | full render | silence (time base differs) | provisional (length is pinned) | layout shifts |
| Restarts per edit while rolling | 2 | 2 (1 with 1b) | 2 (1 with 1b); final deferred | 1-2 |
| Disk per edit | 1 whole-file CAF (never evicted) | +0 | + about span-sized (INFERRED), deleted | chunk versions + composition |
| Render-thread change | none | none | none | none with composed files |
| Needs I1-F1 | no | no | yes (R1-R11) | its own primitive |
| Size | | S | M (+ S surfaces) | L-XL + migration + listening round |

**DECISION: layered. Tier 1 (the bridge, §5) now; Tier 2 (the provisional splice, §6) on top of it once I1-F1 lands
and R3, R5 and R11 are measured; Tier 1b (no restart at the edit) behind its measurement; Option 3 rejected.** Tier 1
stays underneath Tier 2 permanently: it covers the ~0.2-0.5 s before a provisional exists, and every case a provisional
declines (over the cap, a failed span, a missing base). The layers fail SAFE. If the Tier 2 perceptual gate fails,
Tier 2 ships disabled and Tier 1 stands alone; if the bridge predicate fails, the clip falls to today's silence.

**Ordering pressure: Tier 1b becomes required before Tier 2 ships.** While rolling, Tier 2 puts an edit's two
restarts (the edit's own, then the provisional's) about 0.3 s apart instead of ~1.75 s apart. Two ~60 ms gaps that
close together read as a stammer, not as two events. Tier 1b is optional under Tier 1 alone; it becomes required
before Tier 2 ships, gated by G6's restart-count spy.

**The asymmetry that decides the swap policy.**
- A provisional is perceptually the final, so its final swap may wait for the next natural reschedule.
- A bridge is audibly NOT the final (it is the old pitch), and the user is waiting to hear the change, so a bridge must
  swap the moment anything better lands, gap accepted.

**Strongest alternative A: Option 1 alone. It loses.**
- It is the smallest and safest, and it is kept as Tier 1. But on its own it does not do what the user asked: "update
  segment" means hearing the NEW pitch soon, and Option 1 makes them wait the full render, only without the silence.
- Worse, once I1-F1 ships, the release audition plays the NEW pitch while playback, a moment later, plays the OLD one
  for 1.75 s (more on long takes). The two voices of the same app would disagree about the same note.

**Strongest alternative B: Option 3. It loses.**
- It has the cleanest key semantics and a single swap per edit. But it converts a transient approximation into a
  permanent property of every exported tuned vocal, and the user priced "raw" for editing, not for the song.
- It reverses the whole-file rationale the house has now upheld twice (`ARCHITECTURE.md:1502`, `:579`), forces a
  key-scheme migration, makes chunk layout edit-dependent under C2, and needs a listening round on a permanent sound
  change.

**Also rejected, for the record:**
- **Splice-as-final** (Option 2 without the background render): content that depends on edit history, under one key.
- **Live pitch DSP on the render thread**: forbidden by the UI design's P8 and interaction-batch §11
  (`docs/design/2026-09-24-pitch-editor-interaction-batch.md:505`).

## 10. Failure modes

| # | Failure | Mechanism | Mitigation | Gate (plant shown red) |
|---|---|---|---|---|
| 1 | A bridge outlives a FAILED render: the old file plays forever (§3's "never heard", reborn) | A failure is sticky (`StretchRenderCache.swift:236-239`), and today the kick's catch just returns (`AudioEngine.swift:2393-2395`) | On a real failure whose key is still desired, NOT on a cancellation: invalidate + `tracksDidChange`; the predicate refuses `.failed` | An injected render failure leaves the clip silent with `.failed`. Plant: drop the invalidation |
| 2 | A provisional becomes a key's permanent render | The lost-rename rule treats an existing target as success (`StretchRenderCache.swift:726-734`) | Provisionals live only under `Provisional/<session>/`, named `<newKey>~<baseKey>` | After the final commits, the committed file equals a fresh render. Plant: write the provisional at `<key>.caf` |
| 3 | A bounce or stems use a provisional or bridge | A new lookup path leaks into `cachedURL` | `committedURL`/`cachedURL` unchanged (`:171-179`, `:435-442`) | With a provisional present and the final pending, `renderMixdown` waits and equals the final's bytes |
| 4 | An older provisional plays after a newer edit | A late completion | Resolution is keyed by (newKey, baseKey); the provisional slot is latest-wins | Two quick edits, the first provisional landing late, is never opened |
| 5 | The extent misses a change the render reads (a future shaping field, a contour dependency) | The diff read set FIELDS instead of the render's own evaluations | The extent comes from what the render evaluates: transpose at the lookup frames, the mask, and (after C2-3) the input schedule | Randomised differential: final(new) vs final(old) is bit-identical BEFORE the extent, and magnitude-equal after it (the phase wake is expected; §1 R5). Plant: compare only `offsetCents` |
| 6 | Seam click or comb flicker | Phase offset between the cold span and the warm base in continuous singing (R5) | Quiet-point seams, a correlation-chosen law, 30 ms at voiced seams, a transient lifetime | The first-difference bound and the local-envelope bound (§12). Plant: a hard cut |
| 7 | Wrong-speed audio after all | A time-base change the predicate missed | Full source identity, ratio bit pattern, W digest after C2-3, AND a length check: base frames = `round(frames × ratio)` of the new render | A ratio edit never bridges or provisions. Plant: drop the ratio term |
| 8 | C2-3 ships and timing edits bridge with the old timing | The predicate forgot W | The predicate reads the render's own "reads timing" switch, beside `StretchCurvePlan` | Once flipped, a timing edit resolves `.pending` or provisional, never `.bridge` |
| 9 | Disk fills (PRE-EXISTING, amplified) | Every committed edit leaves a whole-file CAF, and nothing evicts (§4). Up to ~115 MB per edit on a 300 s stereo take; faster editing means more edits | This design adds no persistent bytes and deletes provisionals | **Follow-up, not designed here:** LRU eviction for `StretchRenders/` (each clip's current and last N renders, plus a global byte cap) |
| 10 | Stutters while rolling | Every swap goes through stop-all `restart`, ~60 ms (`AudioEngine.swift:4398-4400`) | Tier 1b (−1 per edit); deferred final (−1 per edit) | A restart-count spy per edit. **Follow-up:** a glitch-free per-clip swap, i.e. a mid-roll single-player join with a baked crossfade, under the engine-lifecycle rules (`docs/ARCHITECTURE.md:1508`, `:1022`), with its own design and RT review |
| 11 | The provisional is barely faster than the final | Short clips, or a big extent | The cap (40 % of the file, 20 s); no provisional for clips under ~5 s | The §12 latency measurement on the 33 s and 300 s takes |
| 12 | Provisional latency blows its p95 under load | It runs concurrently with the final (`.userInitiated`, `StretchRenderCache.swift:504`) and with I1-F1's audition renders | Measure under realistic concurrency; consider running the final at `.utility` while a provisional is in flight (a measured knob) | p95 recorded with the final render running |
| 13 | The base file vanished (an OS purge, a user clearing the cache) | The dedupe remembers the ask, not the file (`StretchRenderCache.swift:16-22`) | The predicate checks `fileExists` | A deleted base gives `.pending`, today's behaviour |
| 14 | An engine rebuild mid-provisional | `rebuildEngine` discards the graph | The memo and the provisional slot live in the engine; completion re-enters `tracksDidChange` on the new graph | A rebuild during a pending provisional; the provisional still lands |
| 15 | Split clips sharing one render | Equal sets give equal keys, so one committed render (§3 of the M5 spec, `StretchRenderCache.swift:11-13`) | Provisionals are keyed by (newKey, baseKey), so they are shared too; memos stay per clip | Two split halves with equal sets play one provisional file |

## 11. Implementation plan: steps, file paths, tests

Standing constraints for every implementing lane:
- `./scripts/test.sh --filter <pattern>` only.
- Add NO new `@MainActor` suite (the cap stood at 393 of 394 per `scratchpad/briefs/i1-f1-span-render.md:91`; re-count
  it before trusting that). Extend existing suites.
- Never start audio hardware in a test.
- No commits.
- Port 17600 is the user's app.

**Stage A: Tier 1, the bridge. Now; independent of I1-F1. `audio-dsp-engineer`, size S.**
1. **Time base, one home.** A new file, `Sources/DAWEngine/Stretch/RenderTimeBase.swift`:
   - `RenderTimeBase { sourceIdentity: [String]; ratioBits: UInt64; timeWarpDigest: String? }`, built from
     `StretchRenderCache.sourceIdentityFields(source:)` (`StretchRenderCache.swift:350-357`);
   - `static let readsTimeWarp = false`, declared in `StretchCurvePlan.swift` beside its C2-3 note (`:30-37`), so the
     change that makes the mapping read W flips the predicate in the same diff.
2. **The memo.** `AudioEngine` gets `lastPlayed[clipID]` (file URL, time base, frame count). It is fed by a new graph
   closure `onClipFileOpened`, wired beside `stretchResolver` (`AudioEngine.swift:808-810`), and pruned in
   `syncStretchRenders` (`:2439`).
3. **The graph.**
   - `StretchResolution.bridge(URL)` (`PlaybackGraph.swift:75-84`).
   - The add loop opens it like `.ready` (`:1013-1035`) and records a `PendingRenderBridge` in place of
     `PendingRenderSilence` (`:1025-1026`).
   - `onClipFileOpened` fires after every successful open (`:1031-1037`), identity clips included.
4. **The resolver.** In `resolveStretch` (`AudioEngine.swift:2374-2375`): after the kick, return `.bridge(url)` iff ONE
   function, `bridgeFile(for:keys:)`, passes:
   - the time base is equal;
   - the status is not `.failed`;
   - `fileExists` is true;
   - the memo's frame count equals the expected `round(sourceFrames × ratio)` (failure mode 7).
5. **The failure ends the bridge.** In `kickStretchRender`'s catch (`AudioEngine.swift:2393-2395`): when the status is
   `.failed` AND `stretchDesired[clipID] == key`, call `invalidateClipSchedule` + `tracksDidChange`. A cancellation
   (a superseding edit) must NOT do this.
6. **The notice.** `postPendingRenderSilence` (`PlaybackGraph.swift:3023-3031`) also posts `clip-render-previous` for
   bridged clips (§5 copy). The `clip-stretch-pending` copy (`:3040-3045`) is unchanged.
7. **Tests** (extend `StretchEngineTests` and the existing graph/engine suites):
   - a pitch-only edit resolves `.bridge(previous)`;
   - an identity clip's first edit bridges on its source;
   - a ratio edit never bridges (plant: drop the ratio term → red);
   - an injected render failure ends the bridge (plant: remove step 5 → red);
   - a CANCELLED render does not end it;
   - a deleted base gives `.pending`;
   - a bounce with a render pending waits and equals the final's bytes;
   - the existing identity null tests and the edit-reaches-the-node behaviour stay green unchanged.

**Stage A′: Tier 1b, no restart at the edit. After A, behind a measurement. `audio-dsp-engineer`, size S.**
8. In the reconcile's changed-key loop (`PlaybackGraph.swift:984-996`): when old and new `ClipKey` differ ONLY in
   `pitchEditSetHash`, re-resolve in place (which still kicks the render). If the answer is the file the node already
   has open, adopt the new key and keep the node.
   - Test: a restart-count spy reads 1 per edit while rolling (plant: always tear down → 2).
   - Test: an edit still reaches the node once its render commits, because completion always invalidates
     (`AudioEngine.swift:2400`).

**Stage B: Tier 2, the provisional. After I1-F1 lands and R3/R5/R11 are measured. `audio-dsp-engineer`, size M.**
9. **The extent.** A new file, `Sources/DAWEngine/Stretch/RenderDiff.swift`, beside the primitive:
   `RenderDiff.extent(old:new:sourceFrames:sampleRate:detector:) -> [Range<Int>]?`.
   - Transpose compared at `OfflineStretcher.curveLookupFrame` (`OfflineStretcher.swift:287-296`) on the chunk grid
     the primitive exposes (R2); the mask compared per note region; after C2-3, the input schedule too.
   - Returns `nil` when the branch or time base makes the difference non-local.
   - Plans are built through `StretchCurvePlan.make` exactly as `performRender` builds them
     (`StretchRenderCache.swift:659-664`), contour included (R7).
10. **The builder.** A new file, `Sources/DAWEngine/Stretch/ProvisionalRender.swift`, detached and pure but for file
    I/O. Its steps: seam search on the base, span render through the primitive, assembly, rename.
    - Assembly is clone-and-patch through `AudioFileWritePackets`, plus the reference streaming rewrite (which is also
      the fallback, and the path for a SOURCE base).
    - The level-only-branch and rescale special cases (§6).
    - Naming `Provisional/<session>/<newKey>~<baseKey>.caf`; other sessions' folders are wiped at init.
11. **The slot.** A per-clip latest-wins provisional slot (one in flight, one queued, NO debounce; §6 step 7), separate from
    `StretchRenderCache.jobs` (`StretchRenderCache.swift:233-235`; R8), with a lookup
    `provisionalURL(newKey:baseKey:)`. `StretchRenderCache` itself stays the committed-only store.
12. **The resolution tier and base selection.**
    - `StretchResolution.provisional(URL)` and the order committed → provisional → bridge (and kick the provisional) →
      pending.
    - The memo's `lastCommitted` slot selects the base.
    - Deferred final: the final's completion (`AudioEngine.swift:2396-2401`) marks rather than invalidates when the
      transport rolls and the clip plays a provisional. Every later `restart` (`:4415`) and `stopPlayback` (`:1103`)
      first invalidates the marked clips and reconciles, then reschedules.
13. **Tests:**
    - the extent on synthetic sets (one note; level-only; a split gives empty; a ratio change gives `nil`);
    - the randomised differential (failure mode 5);
    - clone-and-patch bytes equal the rewrite's;
    - the level-only-branch provisional equals the final byte for byte (`cmp`);
    - rescale within 1e-6 relative;
    - the seam gates of §12 (plant: a hard cut);
    - the resolution order; a stale provisional is never opened; offline never sees one; GC; the session wipe;
    - the deferred swap (a fake rolling transport: no invalidate at completion, a swap at the next reschedule);
    - env-gated on the user's take (`DUR/take/dry-norm.wav`): the §12 latency and the splice-vs-final numbers;
    - invariance: the ContourRender md5 recipe from I1-F1's brief (`i1-f1-span-render.md:86-90`), and byte-identical
      offline renders with no edits.

**Stage B′: surfaces. With B. `mcp-integration-engineer`, size S.**
14. An additive per-clip snapshot field `renderAudible` (`exact | preview | previous | silent`), through a
    defaulted `AudioEngineControlling` accessor (`Sources/DAWCore/EngineProtocol.swift`) and the snapshot builder in
    `Sources/DAWControl/Commands.swift`.
    - Document the notice codes `clip-render-previous` and `clip-render-preview`.
    - The MCP descriptions of the note-edit tools say: "playback may briefly play a preview; a bounce always waits for
      the exact version".
    - No new verbs: the wire count is unchanged. Re-pin `node scripts/gates/doc-count-drift.mjs` anyway.

**Stage B″: optional UI. `swift-app-engineer`, size XS.** The existing `ClipShimmer` keeps meaning "rendering"; a
"Preview" caption on the pitch editor's status line when `renderAudible == preview`. It is optional: the notice
already says it.

**Docs owed (not written by this lane: its brief allows editing only this file).** A "Key future decisions" entry for
`docs/ARCHITECTURE.md`, proposed text:
> **Pending renders play, when the time base allows (2026-09-25, design `docs/design/2026-09-25-incremental-note-render.md`).**
> M5's "silence while pending" protected SPEED, and its reason stands: never play audio whose time base (source
> identity, stretch ratio, and the time warp once the render reads it) differs from the requested render. Within
> that rule, a pending clip plays (1) a PROVISIONAL, its last committed render with the changed region spliced from
> a span render at quiet seams, else (2) the BRIDGE, the file it last played. Provisionals are never committed under
> a render key (the lost-rename rule), never used offline, always superseded by the true whole-file render, and named
> by `clip-render-preview` / `clip-render-previous` and the snapshot's `renderAudible`. A chunked final render was
> rejected: it makes a preview's seams permanent.

Plus the `docs/ROADMAP.md` line or lines for Stages A, A′, B and B′ wherever the orchestrator files them.

## 12. Gates: the measurements that decide whether it shipped

Rules for all measurements:
- Record the load average at start and end, with nothing else of yours running (house law).
- Run on the user's take `DUR/take/dry-norm.wav` (never copied into the repo; `DUR="/Users/dsemenov/Music/DAW Pro
  Dogfood/2026-09-24 p2-seg physics"`) AND a synthetic 300 s voice-like take.
- Measure with the final render running concurrently: that is the real load.
- Use the same start point I1 used for its 1748 ms: the store commit returning.

**G1. Edit → the new pitch is audible (Tier 2), p50/p95/max over ≥ 50 edits.**
- End point: the anchor host time of the first schedule pass that plays the clip's provisional (the restart's
  lead-in included).
- **Pass:** p95 ≤ 400 ms on both takes, AND p95(300 s) ≤ 1.25 × p95(33 s). That the latency does not grow with length
  is the point.
- Baseline, reported beside it: today's 1748 ms at 33 s, and the long-take lane's figures from `DUR/i1-long-take/`
  when they land.
- Tier 1's own figure: edit → the clip sounding again while rolling. **Pass:** p95 ≤ 100 ms (the restart lead-in,
  since the bridge re-adds the node in the same pass).

**G2. Splice vs final (Tier 2): per note of I1's 7-note harness (`DUR/I1-latency/`), plus the synthetic cases.**
Three regions, three instruments:
- **Prefix (before the extent's first chunk): bit-identical.** Hard gate: zero differing samples. The history is
  identical there, so any difference is a defect.
- **The extent:**
  - Pitch-track agreement on voiced frames: median |Δ| ≤ 5 c, p95 ≤ 15 c (the independent tracker I1's physics test
    uses).
  - Magnitude log-spectral distance ≤ 1.5 × the phase-carry floor that R5 measures in the wake of two whole-file
    renders.
  - Waveform RMS difference: REPORTED.
- **Downstream (after the right seam):** the same magnitude bound; waveform RMS reported.
- **Exact cases, hard gates:**
  - level-only branch: provisional == final, `cmp`;
  - curve-path level rescale: max relative difference ≤ 1e-6;
  - an edit the render ignores (a split; a timing-only edit before C2-3): final == base, `cmp`.
- **The brief's "< −40 dB", decided by R5 (§1), not by preference.**
  - If R5 shows the wake falls under −40 dB within the post-roll, gate the waveform RMS at < −40 dB over the extent and
    downstream, as the brief asks.
  - If it does not, the −40 dB number is physically unreachable for a cold-started span after transposed history.
    It is then reported with R5's data as the reason, and the magnitude and pitch instruments above carry the gate.
  - This is the one place this design replaces a number from its brief, and it does so only on a measurement.

**G3. No click at the seams.**
- **First-difference bound.** Over each seam's crossfade window ± 2 ms:
  max |y[n] − y[n−1]| ≤ 1.1 × max(max |Δbase|, max |Δspan|) over the same window.
  - Why it holds for a real crossfade: y = (1−g)·b + g·s with |Δg| ≤ 1/xfFrames gives
    |Δy| ≤ max(|Δb|, |Δs|) + |Δg|·|b − s|.
  - The extra term is small: for a 30 ms fade at 48 kHz on a 200 Hz tone of amplitude a, |Δg|·|b − s| ≤ 2a/1440 ≈
    0.0014a, against |Δb| ≈ 2π·200/48000·a ≈ 0.026a.
  - Plant: a hard cut (no crossfade) goes red at a voiced seam, where |Δy| ≈ |b − s|.
- **Local-envelope bound.** Across the crossfade, the 2 ms RMS stays within [−6 dB, +1.5 dB] of the mean of the two
  sides' 2 ms RMS. This catches comb dips from a phase offset, and the +3 dB bump of equal-power on correlated sides.
  Plant: force equal-power on identical sides, and it goes red.
- Report every seam's position and local RMS: whether it actually landed quiet.

**G4. Byte identity when nothing was edited.**
- `StretchEngineTests.editFreeClipKeyIsUnchanged` stays green (`StretchRenderCache.swift:60-63`).
- An unedited project's offline render is byte-identical before and after the change.
- The ContourRender harness's 8 WAV md5s equal `DUR/F-metric/verify-orch/contour/` (the recipe at
  `scratchpad/briefs/i1-f1-span-render.md:86-90`). Positive-control that it ran and wrote 8 files.
- A spy over an unedited open → play → seek → stop session counts 0 bridge resolutions, 0 provisional builds and 0
  files in `Provisional/`.

**G5. Safety gates.**
- An injected render failure never leaves a bridge.
- A ratio edit never bridges or provisions.
- A bounce with a provisional present equals the final's bytes.

**G6. Restarts per edit while rolling (spy):** today 2; Tier 1 2; Tier 1b 1; Tier 2 with the deferred final 2, or 1
with 1b. Never more than today.

**G7. Disk.**
- After 50 edits on the 300 s take, `Provisional/` holds ≤ 2 files per clip, and its `du` total is ≤ 2 × the largest
  span plus headers. That turns the copy-on-write claim from INFERRED into measured; if cloning is unavailable, the
  number is reported and the rewrite cost joins G1.
- After a relaunch: 0 files.

## 13. Size and routing

| Stage | What | Size | Route | Depends on |
|---|---|---|---|---|
| A | Tier 1: the bridge, the failure rule, the `clip-render-previous` notice | S | `audio-dsp-engineer` | nothing; can start now |
| A′ | Tier 1b: no restart at the edit | S | `audio-dsp-engineer` | A, then the G6 spy; REQUIRED before B ships (§9) |
| B | Tier 2: extent, builder, slot, resolution tier, deferred final | M | `audio-dsp-engineer` | I1-F1 landed; R1, R2, R8 in its API; R3, R5, R11 measured |
| B′ | `renderAudible` snapshot field, notice docs, MCP descriptions | S | `mcp-integration-engineer` | B |
| B″ | "Preview" caption in the pitch editor | XS, optional | `swift-app-engineer` | B′ |
| V | Independent re-run of G1-G7, plants included | S | `qa-test-engineer` | each stage |

**For the orchestrator, now:**
1. Forward §1 to the I1-F1 lane. R5 (the wake) and R2 (the chunk grid) are the two it would not otherwise measure or
   build.
2. Stage A can be briefed at once. It touches `PlaybackGraph.swift` and `AudioEngine.swift` (an I1-F1 lane may be in
   those files; stage it after I1-F1's edits land, or brief the file-level overlap explicitly).
3. File three follow-ups this design names but does not design:
   - LRU eviction for `StretchRenders/` (failure mode 9, pre-existing);
   - a glitch-free per-clip swap (failure mode 10);
   - widening the bridge to timing edits after C2-3 (§5).
4. File the ARCHITECTURE.md entry proposed at the end of §11 (this lane's brief allowed editing only this file).

## 14. What needs the user's word

**Nothing blocks building.** The user's question of 2026-09-25 asks for fast feedback and accepts "raw, not precise".
Tier 2 is exactly that, and every approximation in it is transient and replaced by the exact render.

**One behaviour change to SHOW them, not to wait on: Tier 1.** While an edit is being prepared, the vocal keeps
playing its PREVIOUS version instead of going silent. It reverses the letter of M5's "silence while pending", which was
an architecture decision (`docs/ARCHITECTURE.md:1502`); no ruling by the user on it was found in any source read. It
keeps that rule's reason: never wrong-speed audio. If they prefer silence, reverting it is one predicate. Put it on the
handoff page as a heads-up they can veto, in words like: "While a change you made is being prepared, the vocal keeps
playing the way it sounded before, instead of going quiet. Tell me if you'd rather hear silence."

**Delegated defaults, not theirs to set** (the recorded user rule of 2026-09-25: measurable defaults are delegated,
taste stays theirs):
- the seam crossfade lengths (10 / 30 ms) and the quiet threshold (−40 dB under the clip's active level);
- the provisional cap (40 %, 20 s);
- deferring the final swap while rolling;
- the provisional's priority against the final.

§12 sets each one by measurement.

**Would need their word, if anyone revives it:** Option 3. It permanently changes how every tuned vocal sounds,
exported files included, so it needs a listening round with 3-4 options differing on one axis.

**Optional, only if taste input on "how raw" is wanted:** a listening fixture of one voiced seam at four crossfade
lengths (5 / 10 / 30 / 60 ms) plus the exact version. Check first that the seam can be heard at all (the house
audibility rule). It is not needed to ship.

## 15. Full Xcode, entitlements, signing

**None.**
- Every stage is Swift in `DAWEngine`, `DAWControl` and `DAWCore`, plus two system APIs: `FileManager.copyItem` (the
  clone) and AudioToolbox's `AudioFileOpenURL` / `AudioFileWritePackets` (the in-place patch). Both are in the macOS
  SDK that Command Line Tools ship. That is INFERRED for AudioToolbox's file API under CLT: the package already
  builds AVFAudio code; the exact symbols were not compiled here.
- No AUv3, no entitlements, no signing, no bundle change.
- The cache location is unchanged (`~/Library/Caches/DAWPro/StretchRenders/`, `StretchRenderCache.swift:267-271`);
  provisionals live in a subfolder of it.

## 16. Verified vs INFERRED ledger

**VERIFIED: read in the working tree on 2026-09-25.**
- **Pending means no node, and the edit digest is node identity:** `PlaybackGraph.swift:56-66`, `:75-84`, `:985-996`,
  `:1003-1027`.
- **Key derivation, and the digest appended only with edits:** `StretchRenderCache.swift:376-413`, `:390-392`.
- **The job:**
  - identity fast path, committed fast path, single-flight, latest-wins (`:467-482`);
  - 250 ms debounce (`:203`, `:497`);
  - whole-source read, three branches, mask after the stretcher, CAF write (`:596-739`);
  - the lost-rename-as-success rule (`:726-734`);
  - sticky `.failed` (`:236-239`, `:540-547`).
- **Completion re-enters the seam:** `AudioEngine.swift:2384-2402`; `invalidateClipSchedule` at `PlaybackGraph.swift:2511-2530`.
- **Restart on change while running:** `AudioEngine.swift:1225-1231`.
- **The restart primitive is stop-all with a "~60 ms lead-in gap":** `AudioEngine.swift:4398-4435`. The 60 ms is the
  source's own claim; it was not measured here.
- **Nothing in `Sources/` evicts `StretchRenders/`:** a grep, whose hits were the directory's definition, the
  contour subfolder, and unrelated evictions elsewhere.
- **The notice copy says "plays as silence":** `PlaybackGraph.swift:3016-3045`.
- **The stretcher's grid and compensation:** chunk loop, `inTarget`, per-chunk transpose, `curveLookupFrame`, the
  2379-frame compensation, the 30 ms hop and 120 ms block (`OfflineStretcher.swift:223`, `:250-252`, `:287-296`,
  `:419-537`).
- **signalsmith re-anchors only at `noiseFloor = 1e-15`:** `signalsmith-stretch.h:508`, `:596-600`, `:716`.
  Positive-controlled: the same grep found `setTransposeFactor` at `:107`.
- **History of the rule:** `docs/ARCHITECTURE.md:1502`, `:1033`, `:579`, `:1508`; `docs/ROADMAP.md:130`, `:133`;
  `docs/design/2026-09-22-pitch-editor-ui.md:1108-1113`, `:1292`;
  `docs/design/2026-09-24-pitch-editor-interaction-batch.md:161`, `:505`;
  `docs/research/m23-q-pitch-correction-design.md:70`, `:74`, `:76`, `:136`, `:753`.

**INFERRED: from code paths or reasoning; not measured, or not read.**
- The 1748 ms figure. It is I1's measurement, quoted by the brief; not re-measured.
- Render cost linear in take length. The long-take lane's `DUR/i1-long-take/` did not exist when this was written.
- Two whole-mix restarts per edit while rolling today (from the code path).
- Undo being instant when the old CAF survives (from the code path).
- **The phase wake:** re-pitching a note changes the waveform of everything after it until near-digital silence, and a
  cold-started span cannot match a warm whole-file render after transposed history. This follows from the vendored
  source and the m23-q research's reading of it; R5 measures it. §6 and §12 are written to be correct either way.
- The level-only render being far faster than 1.75 s.
- The APFS clone being O(1) copy-on-write through `FileManager.copyItem`, and `AudioFileWritePackets` overwriting CAF
  LPCM frames in place. G7 and the byte-equality test with the rewrite turn both into measurements.
- The C++ stretcher state being copyable (only relevant to the non-required "previous context" option).
- An unlinked-but-open provisional staying readable (POSIX semantics).
- File sizes (arithmetic; the channel count of the user's take was not checked).
- The `@MainActor` suite cap (quoted from I1-F1's brief; not re-counted).

**UNRECOVERED.** The original `stretch-seam-spec.md` §5 text. The surviving record is the list under VERIFIED.

## 17. Erratum and as-built notes: Stage B (2026-09-25)

Written by the Stage B lane. Where the design above and the build disagree, this section is the record; §0-§16 are
left as written. Every number here was measured on this machine on 2026-09-25 unless it says INFERRED.

**E1. The in-place patch is `clonefile(2)` + `pwrite`, not `AudioFileWritePackets` (§6 step 6, §11 step 10, §15).**
- The base is cloned with `clonefile` (APFS copy-on-write). The patch frames are written, interleaved little-endian
  Float32, at `payloadOffset + frame × bytesPerFrame`. The offset comes from parsing the base's CAF chunks
  (`ProvisionalRender.CAFLayout`).
- The parse refuses anything but the layout `performRender` writes: the `data` chunk last, Float32 little-endian
  interleaved, and a size consistent with the frame count. On a refusal, or when `clonefile` fails, the build takes the
  streaming rewrite.
- MEASURED: the clone-and-patch output is byte-identical to the rewrite
  (`ProvisionalRenderTests.cloneAndPatchEqualsRewrite`). A committed render's payload starts at byte 4096
  (`cafLayoutOfARenderFile`).
- The rewrite uses `StretchRenderCache.renderFileSettings(sourceFormat:)`, extracted verbatim from `performRender`.
  - MEASURED: the render files' bytes are identical before and after the extraction (the old inline form against the
    new one, 4 cases, in an isolated copy).
  - The whole-file goldens are unchanged too (`wholeFileGoldenCapture`).
- NOT measured: the space a clone shares with its base. `du` cannot see clone sharing, so G7's "du ≤ 2 × span" was
  not decidable that way. What G7 did measure: at most 1 provisional file on disk during 50 edits, and 0 files and 0
  bytes after the final landed.

**E2. The base may be on the other loop, and the prefix is then approximate (§6 step 1; §12 G2 "prefix: hard gate").**
- An identity clip's first pitch edit takes its SOURCE as the base. A level-only render (source × mask) can also be
  the base of a curve-path edit. The final, though, runs the whole file through the stretcher at 0 st.
- That stretcher output is not the source bit for bit. MEASURED on the user's take (`firstEditColouringProbe`): after
  the file's first 0.2 s it is −127 to −130 dB from the source. Over whole prefixes it is −76 to −84 dB, dominated by
  the stretcher's start.
- `RenderDiff.Extent.prefixExact` is false for such pairs.
  - G2's zero-difference prefix gate applies only when it is true: 7/7 render bases gave 0 differing samples.
  - For the 7 source bases, the prefix residual measured −75.9 to −84.0 dB against the final's prefix RMS, and was
    reported, not gated.
- A formant-preserving side across loops is refused (`formantAcrossLoops`). The 0-st equivalence was measured
  without formant preservation, and the stretcher takes another branch with it.

**E3. G3's local-envelope window is 20 ms, not 2 ms (§12 G3).**
- On a 110 Hz voice, a 2 ms RMS window follows the waveform, not its envelope. It flags a FLAT crossfade (identical
  sides, equal-gain) as an envelope breach.
- MEASURED in `seamInstrumentPositiveControls`: the 2 ms window fails that flat crossfade; the 20 ms window reads it
  flat; the 20 ms window still fails equal-power on identical sides (+3 dB) and a hard cut.

**E4. The crossfade law below ρ 0.9 is POWER-MATCHED, not equal-power (§6 step 4).**
- Gains are the linear ramp divided by √(s² + b² + 2ρsb), with ρ clamped to [0, 1]. At ρ = 0 this is equal-power; at
  ρ = 1 it is equal-gain. Equal-gain is still used at ρ ≥ 0.9.
- MEASURED (`seamLawMeasurement`, 8 single-note edits on a synthetic voice, 16 seams): equal-power failed the
  envelope bound at 8/16 seams (partially correlated sides bump). Power-matched passed 16/16.
- On the user's take: 28/28 seams passed G3 (7 notes × 2 bases × 2 seams).

**E5. The seam search window is 0.5 s, not 1.0 s (§6 step 4); a delegated default, set by measurement.**
- On the user's take, W = 1.0 s gave 1.61 s of patch (mean) against 1.08 s at W = 0.5, and the chosen seams were only
  1.7 dB quieter. Both numbers are independent of load.
  - The two runs' build times are NOT compared here: the W = 0.5 run started LOADED (1-minute load 63.6) and the
    W = 1.0 run at 3.3.
  - Build-time claims come from G1, measured under the timing lock at load ≤ 3.8.
- At either W, no seam on the take reached the −40 dB "quiet" threshold: 0 of 56. The nearest came 28 dB short. So the
  10 ms fade was never exercised on real singing; every seam there used 30 ms, and passed.

**E6. Per-cluster spans and a PATCH MEMO (§6 steps 1 and 5): the pre-memo build FAILED G1.**
- As designed, the base is the last COMMITTED render. In a burst of edits, finals lag, so every provisional's extent
  held every edit since that render, and the span grew with the burst.
- MEASURED on the 33 s take, 50 edits ~1 s apart, finals concurrent: p50 566, p95 781, max 870 ms (fails ≤ 400).
- As built:
  - The extent is split into clusters, each with its own seams. The frames between clusters are the base's.
  - A per-session memo holds each cluster's patch (64 MB, least recently used out). Its key is a SHA-256 over
    everything that patch reads: the base's name, the ratio / semitones / formant bits, the tuning fingerprint, the
    cluster, its chunk range, every transpose on the chunks the span renders (pre-roll included), and the mask over
    the window, or "no mask" when it is all ones.
- MEASURED:
  - a memoised build writes the same bytes as a memo-less one (`patchMemoIsPure`). Three cases must miss: a level
    edit inside a memoised region, a re-drag of the same note, and a level-only re-edit of a levelled region;
  - plants: dropping the transposes from the key, or the mask, turns that test red. Each went green until the case
    that isolates it was added (the re-drag, the level-only re-edit): the first level case also changes the cluster's
    range, which forces its miss by another term;
  - G1 after the memo: 33 s p50 183 / p95 277 / max 315 ms; 300 s p50 184 / p95 220 / max 225 ms (ratio 0.79);
  - take33 rendered 3.84 M span frames and reused 9.56 M; take300 rendered 2.77 M and reused 12.76 M.

**E7. G2's DOWNSTREAM bound measures the edit's own wake (§12 G2).**
- After the right seam, a spliced provisional IS its base, so the compare is final(new) against the base: the phase
  wake of the edit itself (R5: it does not converge). No provisional that ends its span at a seam can reduce it; only
  the final can. The floor it is held to (a final against a final with one extra edit ≥ 2 s earlier) is a different
  wake.
- MEASURED on the user's take, W = 0.5:
  - downstream LSD 0.27-0.60 dB against floors of 0.11-0.45 dB;
  - under the design's strict 1.5 × floor, 4/14 pass downstream, and 13/14 in the extent (note 4, render base:
    0.27 dB against a 0.26 dB limit).
- ⚠️ **A RELAXATION THAT TURNED A FAILING GATE GREEN; OPEN FOR THE ORCHESTRATOR TO RULE ON.** The gate as built is
  max(1 dB, 1.5 × floor): 14/14 pass in both regions.
  - The absolute 1 dB term is this lane's choice, not the design's.
  - Downstream, the reason is above: the compare is the edit's own wake, which only the final removes.
  - In the extent it rescues one case (0.27 dB against a 0.26 dB limit).
- Pitch agreement (render bases): median ≤ 2.1 c, p95 ≤ 8.0 c. Waveform residual in the extent: −9.2 to +5.9 dB
  (render bases; the wake, as R5 predicts, so −40 dB is unreachable) and −120.8 to −134.1 dB (source bases).

**E8. Restarts per edit while rolling (§12 G6): MEASURED with the fake rolling transport (`provisionalRestartsPerEdit`).**
- With the deferred final: a pitch edit costs 1 restart (the provisional's arrival), a timing-only edit 0, and a ratio
  edit 2.
- Without the deferred final: 2, 1 and 2.
- The timing-only 0 comes from Stage A′. A timing-only edit before C2-3 has an empty extent, so its provisional IS the
  base, the file the node already has open. The resolution relabels the adopted bridge as a preview and reschedules
  nothing.
- A ratio edit builds no provisional and plays no bridge.

**E9. The dead-session wipe runs at a session's first build, not at launch (§6 "Disk and memory", §12 G7).**
- `ProvisionalRenderStore.ensureSessionDirectory` removes `Provisional/<pid>-<uuid>` folders whose pid is not
  running, and leaves live ones alone: the user's app and a staging instance share the cache.
- MEASURED: `sessionWipeKeepsLiveSessions`.
- Consequence: after a relaunch, a crashed session's files stay until the first provisional build. A launch-time call
  is an app-side hook (Stage B′ or B″); the function is `ProvisionalRenderStore.wipeDeadSessions(in:except:)`.

**E10. Concurrency (§10 failure mode 12).**
- Provisional builds run on ONE dedicated serial `DispatchQueue` (`.userInitiated`), machine-wide. They are not on the
  cooperative pool the whole-file renders use.
- So Stage B adds at most ONE concurrent render beside the finals; two clips' builds queue.
  - This is INFERRED by construction (`ProvisionalRenderStore.swift:68`, one serial queue; the finals'
    `Task.detached` in `StretchRenderCache` is untouched). No spy measured the peak number of concurrent renders.
  - One qualification: a build that is cancelled keeps running until its loops next poll the flag. During that time
    it still holds the one queue slot, so it delays the next build rather than adding a second one beside it.
- The final's priority is unchanged. G1 passed with the finals rendering concurrently, so the `.utility` knob was not
  needed.

**E11. G3's first-difference bound is too weak to rule out a click on a stretched voice; a SMOOTH-GAIN residual is
added (§12 G3).**
- MEASURED under the hard-cut plant (every seam a cut, no fade), synthetic voice: the first-difference bound flagged 2
  of 22 seams (1 of 16 in `seamLawMeasurement`, 1 of 4 in `twoRegionsAreTwoSpans`, 0 of 2 in
  `splicedProvisionalOnASyntheticVoice`).
  - The reason: the stretched voice's own max |Δ| in a seam window is 0.11-0.28, where the source's 10-harmonic
    sawtooth has about 0.026. A step the size of the local signal (about 0.03 at a −30 dB seam) hides under that.
- The added instrument fits y ≈ gb(n)·base + gs(n)·span over the fade ± 2 ms, with gb and gs piecewise linear:
  - knots every 1 ms and on both fade edges, so it holds any real law, including the corner where a fade starts;
  - a cut cannot be fitted: its step stays in the residual.
- The number is the worst 1 ms of residual power against the window's mean output power. The limit is −40 dB.
- MEASURED (`seamInstrumentPositiveControls` and the synthetic-voice seams):
  - real crossfades read −74.1 to −145.3 dB: equal-gain, equal-power, power-matched, and every product seam;
  - a cut between two phases of a tone reads −12.0 dB;
  - a cut hidden in a hissy voice reads −18.1 dB. The first-difference bound PASSES that cut (0.196 against 0.216).
- MEASURED under the hard-cut plant:
  - synthetic voice: 22 of 22 seams fail (−6.5 to −23.3 dB);
  - the user's take: 21 of 28 fail, against 8 for the first-difference bound. The 7 that pass are the source bases'
    left seams, where span and base agree to ρ = 0.99999999999995 (the stretcher at 0 st, E2). There a cut changes
    nothing audible, and the residual reads −132 to −139 dB.
- The PRODUCT on the user's take: 28 of 28 seams pass all three bounds; smooth-gain reads −66.2 to −140.0 dB.
- G3 is now: first-difference AND envelope AND smooth-gain.

### E7 ruling (orchestrator, 2026-09-25 ~17:40): ACCEPTED

The G2 spectral-distance bound as built, `max(1 dB, 1.5 × floor)`, is accepted as a measurable default. The user delegated those ("pick the options that would produce best results").

Why:
1. After the right seam the preview IS the previous render, so the distance there measures the edit's own phase wake. R5 shows that wake never converges, at +5.7 dB from 1 to 5 s. The FINAL render differs from the old one in the same way, so a stricter bound would measure the stretcher, not the splice.
2. The preview is temporary: the exact whole-file render replaces it (G5 ends a preview whose final failed).
3. Inside the edited region, 13 of 14 cases passed the strict bound (0.27 vs 0.26 dB).

**Verified by me before ruling:**
- regression: 162/162 in 10 suites (`ren-b/logs/b5-regression.log`);
- the Stage B suite: 18/18;
- G1: p50 183 / p95 277 ms on the 33 s take, and p95 220 ms on the 300 s take (the JSON summaries);
- G4: goldens identical (`goldens-after2.log`).

**Follow-up filed:** tests created an empty `Provisional/` folder in the user's real `~/Library/Caches/DAWPro/StretchRenders`. Tests must use a temp cache root, not the user's cache.
