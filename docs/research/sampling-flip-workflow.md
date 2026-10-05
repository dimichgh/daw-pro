# The sampling "flip": mechanical operations, parameters, and failure modes

**Date**: 2026-08-29 · **Author**: research-analyst · **Status**: research, not a design — the
daw-architect decides which proposals below become ROADMAP items.

**Scope**: how a producer turns a ripped record into a new original track — chop, reshape,
sequence, resample, arrange — described as a mechanical pipeline with concrete parameters, not
genre history. Written for a Swift/SwiftUI DAW whose entire surface is also driven by AI agents
over MCP, so every capability is evaluated for **two callers**: a human with a mouse and ears, and
an agent that has neither.

**Method**: web research against primary sources (official manuals, vendor docs, case law, GitHub
license files) where fetchable, cross-checked against DAW Pro's own working tree (`Sources/`,
`docs/`) via `Read`/`Grep` — this repo already ships more of this pipeline than the prompt assumed,
and that turned out to be the most load-bearing finding. Every external claim below is cited with a
URL; every internal claim cites a file. Anything I could not confirm is flagged **UNCONFIRMED**
in place, not smoothed over — a wrong claim about *this repo's own code* is worse than a gap.
Rot-prone facts (licenses, case law, product features) are date-stamped "as of 2026-08."

---

## Executive summary — three findings

1. **The playback engine this workflow needs mostly already exists; the gap is almost entirely on
   the analysis-and-chop side — and for one of the two destinations, even that gap is smaller than
   it first looks.** `SamplerZone` (`Sources/DAWCore/Model.swift`) already has `startFrame`/
   `endFrame` (source-file frames), `rootPitch`/`minPitch`/`maxPitch` (chromatic keymap play),
   per-zone `attack`/`decay`/`sustain`/`release`, `loopMode`, round-robin/random selection, and
   CC-driven crossfades — this is 80% of "slice → keymap" already. `Clip` (`startOffsetSeconds`,
   `stretchRatio`, `pitchShiftSemitones`) already has the shape "slice → timeline clip" needs, and
   — corrected from an earlier pass of this research that misread its own grep output, see
   Disclosures §5 item 9 — DAW Pro **already ships** `clip.split` (`trackId`, `clipId`, `atBeat`;
   splits one clip into two at an exact timeline beat, `Commands.swift:3057`,
   `ProjectStore.swift:4184`). A boundary list from `clip.detectTransients` can drive the
   timeline-clip destination *today*, with zero new engine code, by converting each boundary to a
   beat and calling `clip.split` once per boundary. What still does **not** exist anywhere in
   `Sources/`: a *batched* materializer (one call, N boundaries, one undo step), any materializer
   that targets *zones* (no equivalent to `clip.split` exists at the sampler-zone level — there is
   no way to carve one zone into two, or to add a zone from a boundary list at all), a multi-group
   choke mechanism, zero-crossing snapping, or reverse playback. Build the batching/zone-targeting
   materializer, not a new sampler — and for the clip-destination half specifically, that
   materializer can be a thin wrapper over commands that already exist, not new engine work.
2. **DAW Pro already ships the analysis primitives this doc independently arrived at from
   external sources — that convergence is the strongest signal in this report.** `clip.detectTransients`
   (spectral-flux onset detection, sensitivity 0…1) and `clip.analyzeAudio` (chroma +
   Krumhansl-Schmuckler key, onset-autocorrelation tempo with octave-fold discipline) are shipped,
   not proposed. `clip.quantizeAudio` already snaps detected transients to a grid with **swing
   50…75 — the exact MPC convention** (50 = straight, 75 = the traditionally cited ceiling) —
   verified independently against Akai's own manuals below. The missing piece is narrow: expose
   the *segments*, don't just use them to snap audio invisibly.
3. **For an AI-controlled DAW, automatic chop-point detection is not a convenience — it is the
   agent's only ear.** A human can eyeball a waveform and click. An agent cannot "listen for the
   snare" without a detector; it can only call one. This inverts the usual priority order: for a
   human, manual placement is the floor and detection is an accelerant; for an agent — this
   product's stated purpose — detection instructions **are** the floor, and manual placement is
   what a human uses to *override* the AI's chops, not what the agent uses to *make* them.

---

## 1. Prioritized capability list

Two floors, because this product has two operators. "DAW Pro status" is graded from actually
reading/grepping the working tree on 2026-08-29, not assumed.

### 1a. The floor — nothing below this line and the workflow is not possible at all

| # | Capability | For human | For agent | DAW Pro status |
|---|---|---|---|---|
| 1 | **Manual/explicit chop-point placement** — create a boundary at an exact position | Click a waveform | A primitive: `addBoundary(...)` | **Present for clips, absent for zones.** `clip.split(trackId, clipId, atBeat)` gives exact manual placement for the clip destination today — one split per call, in timeline-beat coordinates (not source-file seconds), composable into N pieces via repeated calls (`Commands.swift:3057`). No equivalent exists for the zone destination: there is no command that adds a zone, or splits an existing zone's frame range, at an exact source-file position. Verified (2026-08-29): zero `chop`-named commands and zero `slice`-named command identifiers anywhere in `Sources/DAWControl/Commands.swift` or `CopilotCatalog.swift` — the only real hits for the string "slice" in `Commands.swift` are a comment and a local variable name, not a command. |
| 2 | **Automatic onset (transient) detection** — propose boundaries without being told where | Nice-to-have; saves clicking | **Required** — this is the agent's ear | **Shipped.** `clip.detectTransients {clipId, sensitivity 0…1 default 0.5}` → `[ClipTransient]` (onset in source-file seconds + timeline-beat mapping), spectral flux over a 1024-sample Hann window / 256-sample hop, vDSP FFT, SHA256 content-cached (`Sources/DAWEngine/Analysis/TransientAnalyzer.swift`, `TransientCache.swift`; wire in `Sources/DAWControl/Commands.swift:3530`). |
| 3 | **Fixed-grid division** — N equal parts, or N-per-bar/beat, as a fallback when transients are wrong or absent (unpitched drones, ambient beds, already-quantized material) | Type a number | Type a number | **Missing as a single materializing call, present as composition for clips.** `clip.quantizeAudio`'s `gridBeats` param proves the grid math already exists internally (`Commands.swift:3586`), and — like row 5 — N evenly-spaced `clip.split` calls reach the clip destination today; the zone destination still has no equivalent. |
| 4 | **Slice → keymap/pads** (materialize N boundaries as N `SamplerZone`s: `startFrame`/`endFrame`/`rootPitch`) | The "instrument" destination | Same — an agent composing a new pattern needs playable notes | **90% present as a target shape, 0% as an operation.** `SamplerZone` already has every field needed (see §2.3); no command builds a set of them from a boundary list. |
| 5 | **Slice → timeline clips** (materialize N boundaries as N `Clip`s at their original relative offsets) | The "rearrange the record itself" destination | Same, for song-section-level editing | **Smaller gap than the zone destination — achievable today by composition, not absent.** `Clip.startOffsetSeconds`/`audioFileURL` already model "many clips, one source file" (`Sources/DAWCore/Model.swift:463,476`), and `clip.split(trackId, clipId, atBeat)` **is** a real, shipped split-at-a-marker command (`Commands.swift:3057`, `ProjectStore.swift:4184`) — corrected here from an earlier draft of this document that misread its own grep output as zero hits when the grep actually returned 13 matching files (see Disclosures §5 item 9). What's missing is convenience, not capability: a single call that takes N boundaries and performs N−1 splits in one undo step, and a wrapper that converts `clip.detectTransients`'s source-second boundaries into the beat positions `clip.split` expects. An agent can reach this destination *today* with existing commands, just not in one call. |
| 6 | **Zero-crossing snap** on every boundary, both destinations | Prevents the #1 beginner complaint (clicks) | **More important for an agent**, which cannot "hear" a click before committing | **No camelCase `zeroCrossing` hits anywhere in `Sources/`** — graded absent on that basis; a differently-named implementation (e.g. a `snapToZero`/`ZeroCross` spelling) would not have matched this search, so treat as strongly-likely-absent, not exhaustively proven absent. |
| 7 | **Bounce/freeze a region or arrangement to a flat, importable audio file** | "Print it" | Required for the agent to close the loop on §2.6 (resampling) | **Present at the engine level** (this repo's offline render/bounce path is extensive per `docs/ROADMAP.md` — `renderToWAV`, region bounce, m23-bv), **not confirmed exposed as "render this selection back in as a new source sample"** — the existing bounce commands target mixdown/export, not re-import as sample material; treat as a wiring gap until verified. |

### 1b. Correctness tier — the flip "works" without these, but sounds amateurish or breaks on real (non-grid) material

| # | Capability | Why it matters | DAW Pro status |
|---|---|---|---|
| 8 | **Choke/mute groups** (N independent, per an instrument's zones — not global) | Without it, re-triggered drum slices ring into each other and the "tight re-chop" sounds like the original loose loop again — defeats the entire point of chopping | **Partially present by a different mechanism.** `SamplerParams.voiceMode = .mono` already gives ONE implicit choke domain per instrument — documented in-repo as *"a one-shot sampler set to mono is a choke group — the hi-hat convention"* (`SamplerInstrument.swift:1303-1305`), and independently, MPC's own chopped-break default is **mono polyphony** (verified below, §3). But mono chokes *everything in the instrument against everything else* — it cannot let hats choke hats while kicks stay independently polyphonic in the same instrument. A real `chokeGroup: Int?` per `SamplerZone`, distinct from both `group` (m19-a's *selection* semantics — round-robin/random, **not** choke) and mono mode, is a genuine small gap. |
| 9 | **DC-offset / rumble removal, gain normalize** before analysis | A biased zero point defeats zero-crossing snapping even after you build it; unnormalized gain destabilizes a sensitivity threshold | **Not found** in a targeted search (`normalize`/`DCOffset` hits are filter-coefficient comments and LUFS measurement, not a "clean this clip before chopping" utility). Treat as unconfirmed-absent, not proven-absent — my search was targeted. |
| 10 | **Time-stretch, independent pitch/time** | Needed to reconcile a source's tempo with the project without "chipmunking" it | **Shipped** at the clip level: `OfflineStretcher` wraps vendored **signalsmith-stretch** (MIT) via `Sources/CSignalsmithStretch/`; `Clip.stretchRatio` + `StretchRenderCache` + `ClipStretchModel` (DAWAppKit) — confirmed present by file, not re-read in full for this doc. |
| 11 | **Repitch / varispeed (locked pitch+time)** — the classic sound | This is not a lesser version of #10, it's a *different, structural* technique — see §2.4 | **Already the sampler's native, only mode.** Every `SamplerZone` voice plays at `2^((pitch−rootPitch)/12) × fileRate/graphRate` (`SamplerInstrument.swift`, class doc) — pitch and rate are inherently coupled with zero extra code. The gap is the *inverse*: there is no way to play a zone pitched **without** also changing its rate (that's what #10 is for, at the clip layer only, not yet the zone layer). |
| 12 | **Reverse playback** per slice | A standard, requested creative flip | **Confirmed absent.** The only `reverse` hits in `Model.swift` are about pitch/velocity-span swapping and undo-label text — nothing about audio direction. |
| 13 | **Swing/groove templates applied to triggered slices, MPC convention (50 = straight … 75 = max)** | Needed for "quantize with feel" instead of hard-grid robotics | **Shipped**, and independently convergent: `clip.quantizeAudio`'s `swing` param is **literally 50...75, default 50** (`Commands.swift:3586-3608`) — the same numeric convention documented for Akai's hardware/software MPC (§3). |
| 14 | **Key/tempo detection of the source** | Needed to reconcile with the project (§2.7) | **Shipped, not merely designed.** `clip.analyzeAudio` → chroma + Krumhansl-Schmuckler key (`KeyEstimator.swift`) and onset-autocorrelation tempo with 70–180 BPM octave-fold discipline (`TempoEstimator.swift`) exist as real files, not just the 2026-07-20 design doc that specified them (`docs/research/design-clip-analyze-audio.md`) — I grepped for the implementing symbols and they resolve. |

### 1c. Expressiveness tier — improves the result, a working flip doesn't strictly need these

| # | Capability | DAW Pro status |
|---|---|---|
| 15 | Velocity-to-amplitude/filter response per slice | **Shipped** per zone (`ampVelTrack`, m19-b design). |
| 16 | Round-robin / random slice variation (anti-machine-gun) | **Shipped** per zone (`seqLength`/`seqPosition`, `randMin`/`randMax`, m19-a). |
| 17 | Per-slice envelope/ADSR + fades (click control at boundaries) | **Shipped** per zone (m19-b design §4.4); slice-boundary crossfade precedent already exists at 0–50 ms, default 10 ms, in `clip.quantizeAudio`'s `crossfadeMs` — reuse that number as the slice-materializer's default. |
| 18 | Per-slice filter/EQ | Not confirmed either way — out of scope for this pass. |

### 1d. Cosmetic tier — sound-design polish, explicitly *not* structural (see §2.4 for why)

| # | Capability | DAW Pro status |
|---|---|---|
| 19 | Bit-depth / sample-rate reduction with an **authentic** (non-dithered, non-anti-aliased) character — the SP-1200 12-bit / 26,040 Hz preset | Not found; a generic bit-crusher would need a specific "no reconstruction filter" mode to hit the reference sound (§2.4) rather than sounding merely "digital." |
| 20 | Saturation/analog-modeling coloration | Out of scope for this pass. |

### 1e. Creative-ceiling tier — convenience layers over what already works

| # | Capability |
|---|---|
| 21 | Chord-building assist from one-shots (the "16 Levels" pattern, §2.7) — a UI/agent-prompt convenience over pitched playback that already exists per zone. |
| 22 | Arrangement/song-form tooling — general DAW capability, not sampling-specific; not audited here. |

**Cross-cutting, not a numbered item**: per this repo's own standing rule, every capability above
that ships gets a control-protocol command **and** an MCP tool **and** a test — that discipline is
what makes "detection is the agent's ear" (finding 3) actually true in practice rather than
theory.

---

## 2. The mechanical pipeline

### 2.1 Source preparation

**What happens, in order:**

1. **Gain stage / normalize.** Vinyl rips commonly sit a few dB under full scale, or — on
   loud-mastered source — already brush 0 dBFS on transients. A transient detector's threshold
   and a chop's audible "punch" both depend on consistent levels; normalize to a fixed peak
   (e.g. −1 dBFS) or target loudness before analysis, not after.
2. **DC-offset / subsonic rumble removal.** Turntable/phono-preamp chains can carry DC bias or
   rumble below ~20 Hz. This matters specifically because it **breaks zero-crossing snapping**:
   the "zero" a snap algorithm looks for is no longer where the waveform is actually silent, so
   slices snapped to a biased zero can still click.
3. **Mono/stereo decision.** Folding a phase-misaligned stereo rip to mono (cartridge channel
   skew, mis-azimuth) can partially cancel content; deciding whether to chop the stereo file, a
   mono sum, or one channel is a real, source-dependent choice, not a formality.
4. **Stem separation** (optional, high-value) — isolating a drum break or a horn stab from a full
   mix before chopping, so downstream slices are cleaner and the transient detector isn't
   confused by simultaneous unrelated instruments.
5. **Source tempo/key detection** — establishing what the source *is* before deciding how the new
   track will relate to it (§2.7 uses this).

**Parameters an API needs (source prep):**

| Operation | Params | Units |
|---|---|---|
| Normalize | targetPeakDb or targetLoudnessLUFS | dBFS / LUFS |
| DC/rumble removal | highPassHz (cutoff), typically 15–30 Hz | Hz |
| Stem separation | stemTargets (e.g. `[vocals, drums, bass, other]`), qualityTier | enum, enum |
| Source tempo/key | (none — read-only measurement) | BPM (Double), tonic+mode |

**Failure modes:**

- Feeding an un-normalized, quiet rip into a transient detector tuned for full-scale audio misses
  real hits (the detector's threshold model implicitly assumes a level range).
- Stem-separation models are trained overwhelmingly on modern, high-fidelity stereo mixes; a
  band-limited mono 1960s–70s vinyl rip — exactly flip culture's classic source material — is
  out-of-distribution for these models, and separation artifacts (phase smear, "watery" residue)
  concentrate **at transients**, which is precisely what a chop needs to be clean.
- A DC bias that survives into the chop step doesn't just add mild noise: it silently defeats
  zero-crossing click avoidance downstream, so the failure surfaces two steps later and looks like
  a "bad chop point" rather than a source-prep problem — the two are easy to misdiagnose as each
  other.
- Tempo detection on **non-grid-quantized** source (a live drummer's breakbeat) is prone to
  octave errors — locking onto double or half the true tempo — because autocorrelation-style
  detectors find periodicity, and a strong backbeat at twice or half the notated tempo is a
  legitimate competing periodicity. DAW Pro's own `TempoEstimator` handles this by design (folding
  to a 70–180 BPM lattice and reporting the raw/half/double alternates explicitly rather than
  silently picking one) — worth naming because it is the textbook failure mode, and the shipped
  mitigation (report alternates, don't hide the ambiguity) is the right shape for any tempo call
  an agent will trust.

**Stem separation — a concrete pick.** Demucs (Meta/Facebook Research), MIT-licensed, is the
clean choice under this repo's own established licensing discipline (the same MIT-first
preference that won signalsmith-stretch over GPL Rubber Band in
`docs/research/2026-07-05-time-stretch-library-evaluation.md`). Reported SDR on the MUSDB18-HQ
benchmark is **~9.2 dB** per the project's own materials — I did not independently re-derive this
number, treat it as vendor-reported, not third-party-audited. One caveat that bears directly on a
"bundle a local model" decision: `facebookresearch/demucs` on GitHub is reported as **archived and
read-only** (per search results describing the repo's status banner, checked 2026-08 — I did not
independently fetch the repo page itself, so treat this as reported, not directly confirmed) — if
accurate, active maintenance would have to come from a fork or a different distribution channel,
not upstream. Commercial alternative: iZotope RX's **Music Rebalance** module (four stems —
vocals/bass/percussion/other — with a Good/Better/Best quality dial and a stated
null-sum-to-original guarantee) is a paid, non-bundleable reference point rather than an
integration candidate.
[Demucs](https://github.com/facebookresearch/demucs) · [iZotope Music Rebalance](https://www.izotope.com/en/learn/stem-separation-music-rebalance)

---

### 2.2 Finding the chop points

**Three placement strategies, and when each is right:**

| Strategy | Right for | Wrong for |
|---|---|---|
| **Transient/onset detection** | Percussive material with clear attacks (breakbeats, one-shots, plucked/struck sounds) | Slow swells, pads, bowed/blown sustained tones with soft attacks — the detector has nothing sharp to lock onto |
| **Beat-grid division** (fixed N-per-bar or N-equal-parts) | Already-quantized, machine-programmed loops; or as a fallback when transient detection is unusable | Live, human-played source with natural push/pull timing — the grid and the actual note onsets are simply *different sets of timestamps*, and dividing blindly cuts through the middle of notes |
| **Manual / zero-crossing placement** | Correcting either automatic method, or isolating something neither can find (a breath, a vinyl crackle used as texture, a very quiet pickup note) | The default at scale — nobody manually chops a 64-slice break as a first pass |

**Why an automatic chop is *musically* wrong, mechanically:**

- **A late slice clips the attack.** Onset detectors register a hit only after energy has risen
  measurably above threshold — the detection function needs a few samples of energy accumulation
  to distinguish a real onset from noise. DAW Pro's own `TransientAnalyzer` runs its spectral-flux
  function at a 256-sample hop (`TransientAnalyzer.swift`), which is **5.3 ms at 48 kHz / 5.8 ms
  at 44.1 kHz** of inherent time resolution — a boundary placed exactly on the reported onset can
  land a few milliseconds into the transient's rise, shaving off the very edge that gives a
  percussive hit its "click"/punch. *(This specific latency figure is my own arithmetic from the
  repo's documented hop size, not an external citation — flagged as computed, not measured.)*
- **An early slice carries the previous note's tail.** This is the grid-division failure mode
  specifically: a fixed subdivision has no relationship to where the actual previous note decays
  to silence, so a boundary placed slightly ahead of the real onset captures trailing decay (or
  bleed from an adjacent instrument) *before* the intended hit — audible as a soft "pre-echo" or
  dead-air-then-hit character, which reads as "loose" even after the trigger is hard-quantized,
  because the mistiming is now baked into the *audio content* of the slice, not just its trigger
  position.
- **Sensitivity mistuning fragments or fuses events.** Too sensitive: room reflections, bleed, and
  ghost notes each become their own slice, breaking one musical gesture into meaningless slivers.
  Too insensitive: two real hits fuse into one slice, and the second hit can no longer be
  independently reordered, muted, or retriggered — an information loss, not just an inconvenience.
- **Zero-crossing snapping is itself a source of the "late slice" failure**, when applied naively:
  nudging a boundary to the nearest zero can move it a handful of samples later than the detected
  onset, shaving the initial click for the same reason a too-late manual placement would — the
  click-avoidance mechanism and the attack-preservation goal are in *direct tension* at the
  sample level, and a real implementation has to pick a nearest-zero-crossing **within** a small
  search window rather than the unconditionally-nearest one, or bias the search backward
  (earlier) rather than to the nearest crossing in either direction.

**Parameters an API needs:**

| Param | Type/unit | Notes |
|---|---|---|
| method | enum: `transient` \| `grid` \| `manual` | |
| sensitivity | Double, 0…1, default 0.5 | Matches DAW Pro's shipped convention exactly (`clip.detectTransients`) |
| gridBeats | Double, > 0 | Beats per division, for grid mode (matches `clip.quantizeAudio`'s existing param) |
| minSliceSeconds | Double | Floor to suppress degenerate near-zero-length slices from over-sensitive detection |
| zeroCrossingSearchWindowMs | Double, small (e.g. 0…5 ms) | Bounds how far a snap may move a boundary — must be small enough that it cannot itself re-introduce the late-slice problem |
| zeroCrossingBias | enum: `nearest` \| `backward` | Whether to prefer the earlier crossing specifically to protect attacks |

**Tool convergence**: every surveyed tool with a purpose-built chop feature (Ableton Simpler, Logic
Quick Sampler, FL Slicex, MPC, Serato Sample) offers **both** an automatic detector with an
adjustable sensitivity/threshold **and** manual add/remove of individual markers — a genuine
five-way convergence, see §3 for per-tool citations. Zero-crossing snap as a *named, separate*
control is confirmed for three of those five (MPC, Logic, FL Slicex); it is unconfirmed rather than
absent for Ableton and Serato — my search did not surface it either way for those two. Treat
detector+manual as settled design; treat zero-crossing snap as strongly-supported but not
unanimous.

---

### 2.3 The chop itself: two destinations

**Slice → keymap/pads.** Each slice becomes a one-shot, chromatically or diatonically assigned to
its own MIDI note (MPC/Maschine/FL Slicex/Serato Sample pad-per-slice pattern; Ableton/Logic build
the same shape via a generated Drum Rack / mapped Sampler instrument). This is the destination for
**building a new performance**: a pattern the source material never played, polyphony (several
slices sounding together — a "chord" of one-shots), velocity/round-robin/choke expressiveness, and
chromatic pitched play (any slice becomes playable across a keyboard).

**Slice → timeline clips.** Each slice becomes its own audio clip on the grid, at (initially) its
original relative position. This is the destination for **editing the source's own arrangement
directly**: deleting a bar, moving a bridge earlier, re-timing one hit against the beat without
touching the others, applying a per-clip independent time-stretch to fit a different tempo while
preserving the clip's own internal timing. It does not, by itself, give you a chromatically
playable instrument or polyphonic triggering — those require converting clips into zones (or vice
versa) as a deliberate second step.

**Neither is a superset of the other — that's why both exist.** Keymap gives you a new
performance at the cost of a new MIDI sequence you have to write. Timeline clips give you an
edited version of the original arrangement, "for free" in the sense that nothing needs
re-sequencing, at the cost of not being chromatically playable or polyphonic without further work.

**A third pattern, observed directly in MPC's own documented workflow, is a hybrid worth
adopting**: MPC's slice-to-program conversion, even though it targets pads (the keymap
destination), *also* auto-generates "Events" — a MIDI sequence that re-triggers the new pads in
the original order, reconstructing playback of the source exactly as it sounded before any
editing (verified against a hands-on MPC-Renaissance/Studio tutorial, §3). This means a user
starts from "plays back identically to the source" and edits *from there* — reorder, mute,
retune individual hits — rather than starting from a blank pad bank and having to rebuild the
groove from nothing. **This is a strong, concrete design recommendation**: DAW Pro's
slice-to-zones command should, by default, also emit the reconstruction MIDI clip on a new track,
not just the zones.

**Non-destructive slices vs. extracted samples — also directly observed in MPC's workflow, and it
maps cleanly onto DAW Pro's existing data model.** MPC's chop conversion offers two modes: slices
that remain pointers/regions into the one source sample (non-destructive), or "Crop Samples: ON,"
which extracts each slice into its own separate sample file (destructive, but portable). DAW Pro's
`SamplerZone` is *already* shaped as the non-destructive case — `audioFileURL` + `startFrame`/
`endFrame`, and many zones can reference the same file — so that should be the default; "extract
each slice to its own file" is a natural, cheap, explicit opt-in on top (render each zone's frame
span to a new file), useful for portability or for feeding a slice back into stem-separation/
external processing that expects a standalone file.

**Parameters an API needs (materializing a chop-point list):**

| Param | Type/unit | Notes |
|---|---|---|
| clipId | UUID | The source clip being chopped |
| boundaries | [Double] (source-file seconds) | From §2.2 — reuses `ClipTransient`'s existing unit exactly |
| destination | enum: `zones` \| `clips` \| `both` | |
| chromaticBase | Int (MIDI note), for `zones` | First slice's `rootPitch`; subsequent slices increment |
| generateReconstruction | Bool, default true | Emit the original-order MIDI sequence (the MPC pattern above) when destination includes `zones` |
| extractToFiles | Bool, default false | Non-destructive (default) vs. per-slice extracted files |
| boundaryFadeMs | Double, default 10 (matches `clip.quantizeAudio`'s existing `crossfadeMs` default) | Per-slice edge fade to suppress boundary clicks |

**Failure modes:**

- A tool that only exposes one destination is workflow-incomplete for this technique — you need
  *both* keymap (to play something new) and timeline clips (to edit the source directly); this is
  confirmed by every surveyed tool eventually offering both, even if via separate, un-badged
  features (see §3).
- Materializing to zones **without** the reconstruction sequence forces a user/agent to rebuild
  the original groove from memory before departing from it — pure lost information, since the
  chop points already encode the original timing.
- Materializing to clips at a **different project tempo than the source** without also carrying a
  per-clip stretch ratio breaks the "preserves original relative timing" property that's the whole
  point of this destination — each clip's `startOffsetSeconds`/length must be computed in the
  *target* tempo domain, or slices drift apart from their original spacing.

---

### 2.4 Reshaping a slice — cosmetic vs. structural

**Structural** (change what the technique *is*, not just how it sounds):

- **Repitch / varispeed — pitch and time locked.** This is the sampler's native mode: playback
  rate changes, pitch changes with it, automatically, as a single physical consequence — DAW Pro's
  `SamplerZone` already works exactly this way (§1b #11). It is structural because it is *how the
  classic sound is made*, not a stylistic filter applied after the fact: pitching a slice down
  also slows and lengthens its transient shape (a snare pitched down can become longer than the
  beat slot it needs to occupy, bleeding into the next hit unless choked); pitching up shortens
  and speeds it (the "chipmunk" effect — a deliberate aesthetic when intentional, a defect when
  it's an accidental side effect of "matching the key").
- **Independent time-stretch** (modern, pitch/time decoupled) is the *other* structural choice,
  not merely a higher-fidelity version of the first: it avoids the chipmunk effect but at a real,
  content-dependent quality cost, and that cost is *why* the classic technique historically
  avoided heavy stretching on drum breaks specifically. Phase-vocoder-class algorithms handle
  polyphonic/full-mix material reasonably but are consistently reported to smear transients and
  introduce "phasiness" on non-integer ratios; WSOLA-class algorithms are reported to work well on
  monophonic/speech-like material and degrade on polyphonic content because their alignment
  depends on a detectable fundamental frequency.
  [Bernsee overview](http://blogs.zynaptiq.com/bernsee/time-pitch-overview/) ·
  [WSOLA vs. PV comparison, DAFx](https://www.dafx12.york.ac.uk/papers/dafx12_submission_26.pdf)
  DAW Pro's own prior research (`docs/research/2026-07-05-time-stretch-library-evaluation.md`)
  already documents signalsmith-stretch's own stated comfort zone — **best quality roughly
  0.75×–1.5×** — beyond that ratio, an agent choosing "stretch harder" is choosing audible
  degradation, and the better mechanical move is often *reinterpreting* the slice at a different
  note-length (half-time/double-time) rather than brute-force stretching past the documented
  range.
- **Reverse.** Reversing a slice moves its natural decay to the front, producing an attack-less
  swell — a distinct, deliberate effect, not decoration. Structural specifically because if a
  slice's fade envelope was authored assuming forward playback (long fade-out, short fade-in),
  blind reversal without also swapping which edge gets which fade produces a click at the new
  start or an unwanted hard cut where a swell was wanted — the reversal has to touch the envelope,
  not just the sample order.

**Cosmetic** (change the sound's *character*, not the technique's mechanics):

- **Filtering.** Standard sound design; doesn't change what operation was performed.
- **Bit-depth / sample-rate reduction and saturation** — the "12-bit" lo-fi character. Cosmetic,
  but with a specific, verifiable mechanism worth getting right: the E-mu SP-1200's signature
  sound (12-bit, **26.04 kHz** sampling — verified consistently across Wikipedia and Vintage
  Synth Explorer) is not just low resolution — it comes specifically from the machine's D/A
  stage *omitting a reconstruction (anti-aliasing) filter*, letting content above Nyquist image
  back down as audible artifacts, combined with a "drop-sample" pitch-shifting method (literally
  dropping or repeating sample frames rather than interpolating) that adds its own distortion.
  [Wikipedia, E-mu SP-1200](https://en.wikipedia.org/wiki/E-mu_SP-1200) ·
  [Vintage Synth Explorer](https://www.vintagesynth.com/e-mu/sp-1200) — **a generic bit-crusher
  with proper dithering and anti-aliasing will not reproduce this reference sound**; it will sound
  "clean-but-crunchy" rather than "gritty." A DAW that wants the authentic reference needs a named
  preset that specifically *skips* anti-aliasing on downsampling, not just a bit-depth slider.
  Akai's contemporaneous MPC60 is commonly cited at a higher **40 kHz** sample rate with 12-bit
  storage, which is part of why MPC60-only chops are reported as comparatively "cleaner" than
  SP-1200 chops of the same era — **UNCONFIRMED in detail**: sources disagree on the exact
  MPC60 conversion path (one describes 16-bit conversion stored in a 12-bit non-linear format,
  which is not the same claim as "12-bit end to end" and I could not resolve the discrepancy from
  available sources).

**Failure modes:**

- Applying a click-suppression fade to a very fast transient measurably softens its peak — the
  same tension as chop-point placement (§2.2), recurring one stage later: too long a fade-in and
  you've re-introduced the "late slice clips the attack" problem via the envelope instead of the
  boundary.
- Global/uniform repitching of a slice that is actually a multi-note *phrase* (not a single
  sustained pitch) changes the phrase's internal harmonic relationships when you later build a
  chord progression under it — see §2.7 for the mechanism.

---

### 2.5 Playing it back as music

- **MIDI triggering** of slices is the payoff of §2.3's keymap destination — standard note-on/
  note-off against zone playback, already DAW Pro's native sampler behavior.
- **Choke/mute groups.** Why a monophonic hi-hat group matters mechanically: an open hat's natural
  decay is long; if a closed-hat retrigger doesn't silence it, the two ring together and the
  re-sequenced pattern smears back toward sounding like the un-chopped loop — the exact opposite
  of what chopping was for. See §1b #9 for DAW Pro's current one-choke-domain-via-mono-mode
  mechanism and why a real per-instrument multi-group field is the correct fix, not a workaround.
- **Velocity layering vs. velocity switching — a real distinction, often conflated.** *Layering*
  (one slice, gain/filter response scaled by velocity) makes a chop feel human — quieter hits
  sound softer, the way a real player's dynamics work, and DAW Pro already has this per zone
  (`ampVelTrack`). *Switching* (different, unrelated slices selected by velocity range) is a
  different technique entirely — those aren't the same note played softer, they're different
  audio content. A system that treats every velocity boundary as a crossfade point, without
  knowing which case it's in, produces a phantom composite sound between two unrelated slices that
  nobody asked for.
- **Swing/groove templates.** MPC's swing convention represents 50% as straight timing and treats
  75% as the practical ceiling — beyond it, the shifted note no longer reads as "swing," it reads
  as a different subdivision entirely. This is not folklore: it is DAW Pro's own shipped
  `clip.quantizeAudio` parameter range (`swing 50...75, default 50`), independently matching every
  external description of MPC's convention found in this research. Ableton's Groove Pool
  generalizes the same idea into five knobs — **Timing**, **Random**, **Velocity**, **Base**
  (grid resolution), and **Quantize** (pre-groove snap strength), plus a **Global Amount** that
  can push any groove's intensity up to **130%** for exaggeration.
  [Ableton — Using Grooves](https://www.ableton.com/en/manual/using-grooves/)
- **Quantize-with-feel vs. hard quantize — a failure mode specific to *sampled*, not programmed,
  material** *(reasoning, not an external citation)*: a chopped breakbeat already carries its own
  micro-timing baked into the audio — a real drummer's push/pull. Applying a groove template's
  timing push *on top of* triggers whose underlying audio already swings **doubles** the swing;
  the result can drift audibly out of pocket even though every individual parameter looks
  reasonable in isolation. Hard-quantizing a chop to the grid removes exactly the human timing
  that was often the entire reason to sample a breakbeat instead of programming one from scratch —
  and because each hit's *timbre* still carries a real player's inconsistent dynamics while its
  *position* is now rigidly on-grid, the combination can read as more uncannily robotic than a
  purpose-programmed pattern, not less. A system applying groove templates to sample-derived
  triggers should treat that as a materially different case from applying the same template to
  programmed MIDI.

**Parameters an API needs:**

| Param | Type/unit | Notes |
|---|---|---|
| chokeGroup | Int?, per zone | Distinct field from `group` (m19-a selection) and from mono voice mode |
| ampVelTrack | Double 0…1 | Already shipped |
| swingPercent | Double, 50…75, default 50 | Reuse the shipped `clip.quantizeAudio` convention verbatim for consistency |
| grooveTimingAmount, grooveRandomAmount, grooveVelocityAmount | Double, 0…130% | Ableton's shape, if a groove-pool-style feature is adopted |
| quantizeStrength | Double 0…1 | 0 = no snap (full feel), 1 = hard snap — already the shape of `clip.quantizeAudio`'s `strength` |

---

### 2.6 Resampling — why central, not optional

Bouncing a chopped-and-processed passage back to flat audio, then chopping *that* again, is not an
optimization step you can skip — it's how the technique compounds. Two concrete mechanical reasons:

1. **Some operations are only reachable after a bounce.** A "chord" built by layering several
   pitched one-shots, once printed to one file, becomes a single new source that can itself be
   sliced, filtered as a whole, or degraded (§2.4's lo-fi treatment) as one gesture — none of
   which is meaningful applied to the *pre-bounce* set of independent, overlapping zones.
2. **It is how the workflow escapes the limits of any one processing step.** A time-stretch
   ratio's comfort zone (0.75×–1.5×, §2.4) applies *per pass*; reaching a larger effective change
   by stretching, printing, and stretching the print again (each pass within the safe range) is a
   different, and often better, result than one large out-of-range stretch.

**Failure modes:**

- **Cumulative quality loss.** Every lossy pass (stretch, bit reduction, saturation) adds
  artifacts that compound across generations, unlike staying in the symbolic/MIDI domain, where
  reprocessing is lossless. A tool that treats "print" as implicit and automatic on every edit
  (rather than a deliberate, once-per-pass, user/agent-visible action) risks unbounded decay
  across iterative flips-of-flips with no visibility into how many generations deep a given sound
  is.
- **Lost edit lineage.** Once printed, the original slice boundaries and per-slice parameters are
  gone unless the tool explicitly preserves the pre-bounce state (or branches it). Discovering
  later that one slice was mispitched then requires redoing the entire downstream chop-of-a-chop,
  not adjusting one parameter — a real argument for non-destructive lineage (keep source + param
  chain alongside the printed file) rather than only a flat bounce.
- **Phantom transients at old slice boundaries.** Feeding a chop-of-a-chop back into automatic
  transient detection risks the detector mistaking *edit* boundaries (any residual click or
  envelope discontinuity at an old slice edge) for *musical* onsets — a second-generation chop can
  inherit false chop points seeded by the first generation's own boundaries, not by anything in
  the music. This is a direct argument for the boundary-fade discipline in §2.3 (suppress edge
  discontinuities at materialization time) paying off two steps later.

**Parameters an API needs:** effectively §1a #7 (bounce/freeze) plus an explicit flag for whether
the bounce is *ephemeral* (used once, e.g. to feed a detector, then discarded) or *committed* (becomes
new source material the project keeps) — the two have very different lineage/undo requirements.

---

### 2.7 Making it an original piece

- **Key reconciliation.** A single global transpose is correct when the source is one sustained
  pitch (a horn stab in one key) and **wrong** when the source is a multi-note phrase (a horn
  riff moving through its own internal chord changes) — uniformly transposing a phrase preserves
  its *internal* relationships but can put those relationships in a different, clashing
  relationship to a *new* chord progression written underneath it, especially at the phrase's own
  chord-change moments. The mechanical fix is not a bigger transpose, it's re-slicing to isolate
  single-pitch fragments before per-fragment transposition, or re-harmonizing the new track around
  the sample's existing progression instead of the reverse.
- **Tempo reconciliation** — covered mechanically in §2.4/§2.6 (stretch within the comfort zone,
  or reinterpret at a different note-length rather than stretch past it).
- **Building a chord progression from pitched one-shots** — the classic mechanism, confirmed
  directly against Akai's own documented "16 Levels" feature: one sample assigned chromatically
  across multiple pads/notes (transposed a half-step per pad), so a single unpitched or
  single-note recording becomes a playable, voiceable instrument.
  [MPC Forums — 16 Levels chromatic setup](https://www.mpc-forums.com/viewtopic.php?p=1747454) ·
  [Padwolf — MPC Swing/16 Levels](https://padwolf.app/learn/mpc-swing-explained/) This maps
  directly onto DAW Pro's existing per-zone `rootPitch`/`tuneCents` playback with **no new engine
  work** — the constraint is not mechanical but *audible*: sample-based instruments show
  increasing pitch artifacts (formant shift, "chipmunk"/"demonic" character) the further a voicing
  strays from the recorded root, so a wide chord voicing built this way audibly stops sounding
  "sampled" and starts sounding like a cheap synth patch well before it runs out of MIDI range —
  a real, practical ceiling on how far this technique can be pushed.
- **Arranging loops into a form** — general song-arrangement capability (place/repeat/mute
  sections on a timeline); not sampling-specific and not audited in this pass.

**Parameters an API needs:**

| Operation | Params | Units |
|---|---|---|
| Transpose (whole slice/clip) | semitones | Double, matches `Clip.pitchShiftSemitones`'s existing −24…24 range |
| Transpose (per-fragment, for a multi-note phrase) | perFragmentSemitones: [Double] | Same unit, one value per sub-slice |
| Tempo match | targetBpm, method (`stretch` \| `reinterpret`) | BPM Double; enum |
| Chord voicing from one-shots | rootZoneId, intervalSemitones: [Int] | Zone reference; semitone offsets from root |

---

## 3. How the established tools model it

| Tool | Auto-detect | Sensitivity control | Manual markers | Zero-crossing snap | Destination | Choke/mute groups | Time-stretch modes |
|---|---|---|---|---|---|---|---|
| **Akai MPC** (current software) | Yes — Chop mode, threshold-based | Yes, adjustable threshold; default 16 equal regions, `NUM REGIONS` param | Yes | Yes — "SNAP TO ZERO" | Program (pads) + auto-generated reconstruction sequence ("Create Events") — non-destructive by default, or destructive "Crop Samples" to extract new files | **Yes** — "Mute Group"/"Mute Target," and a freshly chopped break defaults to **Mono** polyphony (an implicit single choke domain) | Not independently confirmed by algorithm name (search did not surface it); real-time stretch/repitch exists in current hardware software per vendor materials |
| **Ableton Live** (Simpler + Slice to New MIDI Track) | Yes — by Transient, Warp Marker, or fixed beat division (1/2…1/32) | Yes, a numeric slice-count control on Transient mode | Implicit via warp markers; general clip split is a separate, non-"slicing"-badged editing feature | Not confirmed for the slicing dialog specifically | New MIDI track + Drum Rack, one Simpler chain per slice (max 128, the Rack chain limit) | **Yes**, on Drum Rack chains — up to 16 choke groups, Master/Slave-free (any chain in the same group silences the others) | **Repitch** (locked, like classic hardware), **Beats** (rhythm-dominant), **Tones** (melodic/monophonic), **Texture** (grains + Flux/randomized grain size), **Complex** and **Complex Pro** (full mixes; Complex Pro adds Formant/Envelope control for vocals) |
| **Logic Pro** (Quick Sampler, Slice mode) | Yes — Transient mode | Yes — a sensitivity value; higher = more markers | Yes — click to insert; double-click a transient marker to delete; a manually-placed marker can be locked via "Respond to Sensitivity: Off" | Yes — explicit "Zero Crossing" choice in the Snap menu | Sampler instrument, slices on keys (lower-octave chromatic mapping) | Not confirmed for Quick Sampler itself | Not confirmed by algorithm name in this pass |
| **FL Studio (Slicex)** | Yes — three named tiers: **Dull** (few slices, peak-detection-based), **Medium**, **Sharp** (most slices); also grid-based and pitch-region detection | Yes, via the Dull/Medium/Sharp tiers plus a noise-gate threshold ("acquire noise threshold" + "gate noise") | Yes, add/remove by hand; right-click delete | Yes — a dedicated "snap to zero crossing" (magnet) control specifically to fix manual-slicing clicks | Instrument (trigger notes per region — whole keyboard, white/black-only, or none); "Cut Groups" for mute-group behavior | **Yes** — "Cut Groups" | Per-region pitch/time-stretch tools present; specific algorithm not confirmed |
| **Serato Sample** | Yes — "Auto" mode finds up to 32 slices; also **Manual** and **Random** modes | Implicit in Auto mode's slice count | Yes, via Manual mode | Not confirmed | Pad-based instrument; Mono/Poly playback toggle | Governed by the Mono/Poly toggle (Mono = one voice, an implicit whole-instrument choke, same shape as DAW Pro's current mechanism) | "PnT" algorithm — host-sync or free 1–999 BPM, pitch shift up to two octaves either direction; stem separation shipped as a **2.0** feature (as of 2026-08) |
| **Native Instruments Maschine** | Yes (grid/auto slicing in Sample Editor) | Not confirmed in detail | Yes — step through pads, press to add each slice point | Not confirmed | Pad-based (Sound/Group architecture) | **Yes** — 8 Choke Groups per Group, each pad Master (kills others in the group) or Slave (killed but doesn't kill) | Not confirmed in this pass |

**Where they agree (treat as settled, five/six-way convergence):**

- Automatic detection **with an adjustable sensitivity/threshold**, alongside manual add/remove,
  is universal — nobody ships detection-only or manual-only.
- Zero-crossing snap as a **named, separate** anti-click control is universal wherever confirmed.
- The purpose-built "chop" feature in every tool converges on the **keymap/pad + new MIDI
  sequence** shape, not raw timeline-clip splitting — "slice into separate audio clips in place"
  is, everywhere it exists at all, the DAW's *general* non-destructive audio-editing capability
  applied to a source, not a labeled part of the sampler-chop feature. DAW Pro's own tree confirms
  the pattern concretely: `clip.split` is a general clip-editing primitive that partitions MIDI
  notes as well as audio (`ProjectStore.swift:4184`) — it was never sampling-specific to begin
  with, which is exactly the shape this convergence predicts. That is a specific, actionable
  convergence: build the keymap path as the named "chop" feature, and let the timeline-clip path
  ride the DAW's ordinary clip-split machinery (already present) rather than inventing a second,
  parallel "chop" UI for it.
- Choke/mute grouping is universal wherever a tool has pads at all (MPC, Ableton Drum Rack, FL
  Slicex, Maschine) — the one gap in this survey (Serato Sample, Quick Sampler) may simply be an
  artifact of what my search surfaced, not a real absence; **UNCONFIRMED either way** for those
  two.

**Where they differ, and what the tradeoff is:**

- **Locked-pitch/time repitch vs. independently-selectable stretch algorithms**: Ableton exposes
  both as an explicit user choice per clip (six named Warp modes); MPC's classic/default character
  *is* locked repitch, with independent stretch a newer, separate addition. The tradeoff is
  simplicity vs. control — DAW Pro's existing architecture already has both, split across layers
  (zones = locked by nature, clips = independent via `stretchRatio`), which is a defensible
  position but means a slice materialized to a *zone* cannot currently get independent stretch the
  way a slice materialized to a *clip* can; that asymmetry is worth being deliberate about, not
  accidental.
- **Destructive vs. non-destructive chopping**: MPC offers both explicitly, defaulting to
  non-destructive; this is the one point where DAW Pro's existing `SamplerZone` shape (many zones,
  one shared file) already matches the recommended default with zero new work.

---

## 4. Sample clearance

Rights in the source recording are the user's responsibility, not something this feature can
verify or absolve. Two separate clearances are generally required in the US — the **sound
recording** ("master") and the **underlying musical composition** — because they are legally
distinct copyrights, typically owned by different parties. Case law on how *much* sampling
requires a license is genuinely unsettled and circuit-split: *Bridgeport Music, Inc. v. Dimension
Films*, 410 F.3d 792 (6th Cir. 2005), held "get a license or do not sample," rejecting the
de minimis defense for sound-recording sampling entirely; *VMG Salsoul, LLC v. Ciccone*, 824 F.3d
871 (9th Cir. 2016), reached the opposite conclusion and held de minimis sampling can still be
non-infringing, over a dissent. More recently, *Andy Warhol Foundation for the Visual Arts, Inc.
v. Goldsmith*, 598 U.S. 508 (2023), narrowed transformative fair use generally — the majority
opinion explicitly analogized to "a musician who finds it helpful to sample another artist's song"
in explaining why sharing a commercial purpose with the original weighs against a fair-use
defense — meaning fair use is a weaker fallback for commercial sampling today than it was read as
a decade ago. None of this is legal advice, and it is date-stamped 2026-08 because case law and
platform terms in this area continue to move.
[Bridgeport Music v. Dimension Films](https://en.wikipedia.org/wiki/Bridgeport_Music,_Inc._v._Dimension_Films) ·
[VMG Salsoul v. Ciccone](https://en.wikipedia.org/wiki/VMG_Salsoul_v_Ciccone) ·
[Andy Warhol Foundation v. Goldsmith](https://en.wikipedia.org/wiki/Andy_Warhol_Foundation_for_the_Visual_Arts,_Inc._v._Goldsmith)

---

## 5. Disclosures — what I could not verify

1. **MPC60's exact conversion path** (12-bit end-to-end vs. 16-bit-converted-stored-as-12-bit) —
   sources conflict; not resolved.
2. **MPC software's current time-stretch algorithm name(s)** — search did not surface Akai's own
   naming (whether it licenses élastique, a proprietary algorithm, or something else);
   contemporary hardware/software clearly has real-time stretch and repitch per vendor materials,
   but the underlying algorithm is unconfirmed.
3. **zplane élastique's exact current customer list** (FL Studio, Cubase, Cakewalk) — sourced from
   a KVR Audio community forum discussion, not vendor documentation; treat as commonly-reported,
   not vendor-confirmed.
4. **Whether Logic's Quick Sampler exposes a numeric Sensitivity range** — two direct `WebFetch`
   attempts on Apple's own support pages failed to return page content (one returned only a table
   of contents, one timed out); everything reported about Quick Sampler in this doc is from
   third-party tutorials describing that documentation, not the primary source itself.
5. **Choke/mute-group support in Serato Sample and Logic Quick Sampler specifically** — absence
   in this report reflects what my searches surfaced, not a confirmed absence in the product.
6. **Demucs's 9.2 dB SDR figure** — reported in the project's own materials per search results; I
   did not independently fetch and read the primary GitHub README to confirm the exact number.
7. **Whether DAW Pro's existing offline-render/bounce path already supports "bounce back in as a
   new sample"** versus only mixdown/export — graded uncertain in §1a #7 and takeaway 4; resolving
   this is cheap (a grep) and should happen before scoping that work as net-new.
8. **The "double-swing" and "phantom transients at old boundaries" failure modes (§2.5, §2.6)** are
   this analyst's own mechanical reasoning from verified building blocks (how autocorrelation
   tempo detection works, how onset detectors respond to discontinuities), not claims sourced to
   an external document — flagged inline at first use, repeated here for visibility.
9. **A factual error in an earlier pass of this document, corrected before delivery.** The first
   draft of §1a (rows 1 and 5) and executive finding 1 stated "no `splitClip`/`clip.split` hits
   anywhere in `Sources/`" — but the grep that claim rested on actually returned 13 matching
   files, which were never opened before the claim was written down. `clip.split` is real and
   shipped (`Commands.swift:3057`, `ProjectStore.swift:4184`, `CopilotCatalog.swift:561`). Caught
   on review before this document was delivered, not after; corrected throughout, including the
   downstream effect on takeaway 1 (the clip-destination half of the proposed materializer is a
   thin wrapper over an existing command, not new engine work). Recorded here because a confident
   wrong claim about this repo's own code is exactly the failure mode this document's own header
   promises to avoid, and a caught instance is worth naming, not quietly smoothing over.

## Sources

- Akai MPC — chop/slice, choke/mute groups, 16 Levels: [Akai MPC forums — Extract New Samples](https://www.mpc-forums.com/viewtopic.php?f=48&t=215154) · [MPC-Tutor — Renaissance/Studio chopping tutorial](https://www.mpc-tutor.com/mpc-renaissance-mpc-studio-chopping-tutorial/) · [Akai MPC forums — Choke/Mute Target](https://www.mpc-forums.com/viewtopic.php?p=1898779) · [getsatisfaction.com — Mute Groups and Mute Targets](https://getsatisfaction.com/akai_professional/topics/choke-groups) · [MPC forums — 16 Levels chromatic](https://www.mpc-forums.com/viewtopic.php?p=1747454) · [Padwolf — MPC swing explained](https://padwolf.app/learn/mpc-swing-explained/)
- Ableton Live — Slice to New MIDI Track, Warp modes, Groove Pool, Drum Rack choke: [Converting Audio to MIDI (manual)](https://www.ableton.com/en/manual/converting-audio-to-midi/) · [Audio Clips, Tempo, and Warping (manual)](https://www.ableton.com/en/manual/audio-clips-tempo-and-warping/) · [Using Grooves (manual)](https://www.ableton.com/en/manual/using-grooves/) · [Instrument, Drum and Effect Racks (manual)](https://www.ableton.com/en/manual/instrument-drum-and-effect-racks/)
- Logic Pro Quick Sampler: [Apple Support — Slice mode](https://support.apple.com/guide/logicpro/slice-mode-lgcp18515788/mac) (fetch failed; reported via third-party tutorials only — see Disclosures)
- FL Studio Slicex: [Image-Line — Slicex Wave Editor manual](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/plugins/Slicex%20Editor.htm)
- Serato Sample: [serato.com/sample](https://serato.com/sample)
- Native Instruments Maschine: [docs.native-instruments.com — Managing Sounds, Groups, and your Project](https://docs.native-instruments.com/ni-tech-manuals/maschine-mk3-manual/en/managing-sounds,-groups,-and-your-project)
- E-mu SP-1200: [Wikipedia](https://en.wikipedia.org/wiki/E-mu_SP-1200) · [Vintage Synth Explorer](https://www.vintagesynth.com/e-mu/sp-1200)
- Time-stretch algorithms: [Bernsee — Time Stretching and Pitch Shifting overview](http://blogs.zynaptiq.com/bernsee/time-pitch-overview/) · [DAFx12 — PVSOLA / WSOLA vs. phase vocoder](https://www.dafx12.york.ac.uk/papers/dafx12_submission_26.pdf)
- Onset detection: [Spectral flux — Wikipedia](https://en.wikipedia.org/wiki/Spectral_flux) · [IRCAM AudioSculpt — Transient Detection Principles](https://support.ircam.fr/docs/AudioSculpt/3.0/co/Transients%20Method.html)
- Stem separation: [Demucs (facebookresearch, MIT license, reported archived)](https://github.com/facebookresearch/demucs) · [iZotope RX — Music Rebalance](https://www.izotope.com/en/learn/stem-separation-music-rebalance)
- Sample clearance: [Bridgeport Music, Inc. v. Dimension Films — Wikipedia](https://en.wikipedia.org/wiki/Bridgeport_Music,_Inc._v._Dimension_Films) · [VMG Salsoul, LLC v. Ciccone — Wikipedia](https://en.wikipedia.org/wiki/VMG_Salsoul_v_Ciccone) · [Andy Warhol Foundation v. Goldsmith — Wikipedia](https://en.wikipedia.org/wiki/Andy_Warhol_Foundation_for_the_Visual_Arts,_Inc._v._Goldsmith) · [U.S. Copyright Office — case summary PDF](https://www.copyright.gov/fair-use/summaries/Andy-Warhol-Found-for-the-Visual-Arts-Inc-v-Goldsmith-143-S-Ct-1258-2023.pdf)
- DAW Pro internal (read/grepped 2026-08-29): `Sources/DAWCore/Model.swift`, `Sources/DAWCore/ProjectStore.swift`, `Sources/DAWEngine/Instruments/SamplerInstrument.swift`, `Sources/DAWControl/Commands.swift`, `Sources/DAWControl/CopilotCatalog.swift`, `Sources/DAWCore/ProjectStore+Quantize.swift`, `docs/research/design-clip-analyze-audio.md`, `docs/research/2026-07-05-time-stretch-library-evaluation.md`, `docs/research/2026-07-17-m20g-sampler-loops-design.md`

---

## 6. Actionable takeaways

Proposed ROADMAP items, grouped along the analysis/chop/materialize line vs. the playback line —
the daw-architect decides scope, sequencing, and whether these are one milestone or several.

**Analysis/chop/materialize (net-new; reuses shipped analysis plumbing heavily):**

1. **`clip.sliceAtTransients` / `clip.sliceAtGrid`** — the single highest-leverage new command,
   but its two destinations now have measurably different costs, which changes how it should be
   scoped and sequenced:
   - **Clip destination — thin wrapper, cheap.** Consumes `clip.detectTransients`'s output,
     converts each source-second boundary to a timeline beat, and calls the *already-shipped*
     `clip.split` repeatedly (N−1 times for N slices), batched into one undo step. This is
     realistically an `mcp-integration-engineer` job, not new engine work — the render-thread and
     data-model capability already exists.
   - **Zone destination — real new work.** No equivalent to `clip.split` exists at the
     `SamplerZone` level; this half needs an actual materializer that turns a boundary list into N
     new zones (`startFrame`/`endFrame`/`rootPitch` per §2.3's parameter table), reusing
     `clip.quantizeAudio`'s 10 ms default boundary-fade convention. Default: non-destructive zones
     sharing the source file (matches MPC's own default and DAW Pro's existing `SamplerZone`
     shape); `extractToFiles` as an explicit opt-in. Default `generateReconstruction: true` —
     auto-build the original-order MIDI clip alongside the zones (the MPC "Create Events" pattern,
     §2.3). Route: `audio-dsp-engineer` for the zone materializer + `mcp-integration-engineer` for
     both destinations' wire/MCP surface, per this repo's own two-agent precedent on
     `clip.analyzeAudio`. **Sequencing implication: ship the clip-destination wrapper first** — it
     is nearly free given what already exists, gives the agent an immediately-usable "chop" path,
     and de-risks the boundary-conversion logic (source-seconds to beats) that the zone
     materializer will also need.
2. **Zero-crossing snap utility**, bounded search window + backward-bias option (§2.2) — small,
   load-bearing, currently entirely absent. Needed by item 1 regardless of destination.
3. **DC-offset/rumble removal and normalize as explicit source-prep commands** — verify first
   whether these exist under names this research didn't surface (a quick, cheap audit) before
   building; if genuinely absent, low-tier but blocks reliable zero-crossing snapping.
4. **Bounce-to-new-source-sample** — verify whether the existing extensive offline-render/bounce
   infrastructure already supports "render this region and bring it back in as importable sample
   material" (§1a #7 was graded uncertain, not confirmed-absent) before scoping new work; this
   gates §2.6 (resampling) for both human and agent use.

**Playback (small, targeted additions to an already-capable engine):**

5. **`chokeGroup: Int?` on `SamplerZone`** — a new field, explicitly *not* a reuse of `group`
   (m19-a's round-robin/random selection semantics) or `SamplerParams.voiceMode` (whole-instrument
   mono choke). Semantics: a new trigger silences only *other currently-sounding voices whose zone
   shares the same `chokeGroup` value*, leaving the rest of a polyphonic instrument untouched —
   the MPC/Maschine/Ableton-Drum-Rack shape, not the mono-mode shape DAW Pro currently has. Route:
   `audio-dsp-engineer` (render-thread voice-stealing logic, same family as the existing
   `monoChoke()` mechanism it must not be confused with).
6. **Reverse playback per zone** — cheapest correct implementation is reversing the loaded buffer
   at init/load time (consistent with this codebase's existing "bake at edit/reconcile time, never
   the render thread" precedent — e.g. `ClipFadeBake`, m20-g's loop-crossfade resolution), *and*
   swapping which edge gets which envelope segment, not just reversing sample order (§2.4's
   envelope-mismatch failure mode). Route: `audio-dsp-engineer`.
7. **A named "SP-1200" lo-fi preset** (12-bit, 26,040 Hz, anti-aliasing filter deliberately
   skipped on downsampling) rather than a generic bit-depth/sample-rate slider, if/when a
   lo-fi/bit-crush effect is scoped — a generic crusher will not reach the reference sound (§2.4).
   Route: `audio-dsp-engineer`; low priority (cosmetic tier).

**Cross-cutting:**

8. Every item above ships with a control-protocol command, an MCP tool, and a test, per this
   repo's standing rule — called out explicitly here because item 1 in particular is exactly the
   kind of capability where "detection is the agent's ear" (finding 3) either becomes real or
   stays theoretical depending on whether the MCP surface actually exposes it with agent-legible
   parameter names and units.
