# M32 design — Sample flipping: turn a record into an instrument

Status: **DESIGN, ruled.** Written 2026-08-29 by `daw-architect` for the implementing agents.
Inputs: `docs/research/sampling-flip-workflow.md` (research), the orchestrator's engine audit,
and my own reads of the working tree. Every line number below was read from source in this
session and is at the current working tree.

This document supersedes the orchestrator's briefing where they conflict. Three conflicts are
called out explicitly in §1 — two of them cut *against* the briefing, and both are recorded
because a correction that only ever flatters the corrector is not a correction.

---

## 0. The one-paragraph version

The engine already does the hard part. Keymap playback is varispeed
(`SamplerInstrument.swift:1371`), region playback exists (`startFrame`/`endFrame`), transient
detection ships, and **chop-to-timeline is not merely composable — it is one existing call**
(`clip.quantizeAudio` at `strength: 0`). What is missing is (a) a sampler loader that does not
allocate one full copy of the source file *per zone*, (b) one command that turns a detected
boundary list into zones plus the MIDI that replays the original groove, (c) three small
character features, and (d) a skill that teaches the loop. **m32-a is the only true blocker, and
it gates exactly one other item.** Everything else can proceed in parallel — but not
concurrently in the same file, which §2 schedules.

---

## 1. Corrections to the inputs, before anything is built on them

### 1.1 ⛔ **FACT 6 IS WRONG. DAWCore does NOT read audio files, and must not start.**

The briefing states: *"DAWCore MAY read audio files — `ProjectStore+Render.swift`,
`DeliveryFormat.swift`, `MediaImporting.swift` already use `AVAudioFile`."*

Measured:

```
grep -rn '^import ' Sources/DAWCore/ | awk '{print $2}' | sort | uniq -c
    103 Foundation
      1 Observation
```

**Zero `AVFoundation`, zero `AVFAudio`, across 104 files.** You cannot name `AVAudioFile`
without one of those imports, so there is no usage. Positive control: the same grep against
`Sources/DAWEngine/` returns ten-plus files (`OfflineRenderer`, `TransientAnalyzer`,
`FileProfiler`, …), so the pattern works and the absence is real.

All three cited files mention `AVAudioFile` **only inside comments explaining why the real
implementation lives elsewhere.** `MediaImporting.swift:4` says it outright — *"DAWCore stays
engine-free: the real implementation (AVAudioFile-backed) lives in DAWEngine and is injected
into `ProjectStore.media`"* — and `Model.swift:9-10`, the doc comment on `AudioFileInfo`, states
the law in one sentence: **"DAWCore never opens files itself."**

The *spirit* of fact 6 survives and is load-bearing: **`MediaImporting` is a protocol-seam
precedent, not a file-reading precedent.** Anything in this milestone that needs a source file's
sample rate, frame count, or PCM goes through an injected protocol implemented in DAWEngine.
That is §6.2's engine seam. It is a better design than the one fact 6 would have produced —
it makes the seconds→frames unit trap unrepresentable rather than merely forbidden.

### 1.2 ✅ `clip.split` exists (the briefing is right; the research draft was wrong and self-corrected)

`Commands.swift:272` / `:3057` / `:3067`, `ProjectStore.swift:4184`. The delivered research doc
carries this as its own §5 Disclosures item 9. Nothing here depends on it.

### 1.3 ⚠️ **"A present `zones` array replaces the whole map — no merge-by-id exists" is half true, and the missing half matters for the skill.**

`zones` does replace the whole map. But **`zonePatches` (m26-g) IS merge-by-id**
(`Commands.swift:9729-9765`): it edits the zones you name and leaves every other zone standing,
in place, by index — because *"zone ORDER is load-bearing"*. Its doc comment calls it *"the ONLY
way to touch one zone of a 309-zone imported library without resending all 309."*

That is exactly the post-chop tweak path (retune pad 7, shorten pad 3), and the skill (§10) must
teach it. **The move-together rule in §11 applies to `zonePatches` too, and forgetting it is a
silent failure:** a new zone field wired into `parseZoneFields` + `makeZone` but not into
`merge()` parses fine on the `zones` path and **silently no-ops on the `zonePatches` path.**

### 1.4 ⭐⭐ **Chop-to-timeline is not "reachable by composition" — it is ONE SHIPPED CALL, and this collapses half the milestone.**

The orchestrator's mid-task note frames the clip destination as `detect` → N × `clip.split`, whose
only gap is one undo step. It is better than that. Read `AudioQuantizePlan.compute`
(`Sources/DAWCore/AudioQuantize.swift:121-217`) at `strength: 0`:

- `newBeat = beat + 0 · (target − beat)` → `beat` **exactly** (IEEE: `x + 0·y = x` for finite `y`).
- The `.clamped(to: lo...hi)` and monotone `max(newBeat, prev + minSliceBeats)` cannot bite,
  because step 1's conditioning has already guaranteed every onset is ≥ `minSlice` from both
  window edges and from its predecessor.
- In `applyCrossfades` (`:252-284`), `spacing == natural` at strength 0, so
  `baseLen = min(natural, spacing) = natural`, so the left-extension room
  `2·(natural − base)` is **0** and every crossfade self-clamps to a clean cut.

So `clip.quantizeAudio {gridBeats: <anything>, strength: 0}` replaces one audio clip with N
butt-joined slices at their **original** positions, in **one** `performEdit("Quantize Audio")`,
with **no** crossfades. That is chop-to-timeline, shipped, today.

⭐ **And it is click-free by construction, which is why the clip destination does not need the
zero-crossing snapper.** Slice *i* ends at source frame *k* and slice *i+1* begins at source
frame *k*: the concatenation is the original waveform, sample-exact. Clicks appear only when a
slice is **moved** (which is what `strength > 0` does, and what the existing equal-power
crossfade already handles) or when a slice is **played in isolation** — which is precisely the
zone destination, and precisely why §6 spends real design on snapping and §6.7 on envelopes.

**Consequence, and it is the ruling in §5:** building a second chop-to-timeline command would
create a *third* home for slice-span math. The clip destination gets **additive parameters and a
description fix**, not a command.

---

## 2. Shape of the milestone after the rulings, and the build order

| Item | What | Gated by | Route |
|---|---|---|---|
| **m32-a** | Sampler loader dedup by source URL | — | `audio-dsp-engineer` |
| **m32-b0** | `SliceBoundaries` — the ONE HOME for boundary conditioning + grid generation (DAWCore) | — | delivered by whichever of b1/b2 lands first |
| **m32-b1** | Fixed-grid division + discoverability on `clip.quantizeAudio` | — | `swift-app-engineer` |
| **m32-b2** | `clip.sliceToSampler` — the real item | **m32-a**, m32-b0 | `swift-app-engineer` (+ `audio-dsp-engineer` for the snapper) |
| **m32-d** | Reverse zones | m32-a (file-serialization, §2.1) | `audio-dsp-engineer` |
| **m32-e** | Bit-crush / SRR insert effect | — | `audio-dsp-engineer` |
| **m32-f** | Per-zone choke groups | m32-a, m32-d (file-serialization) | `audio-dsp-engineer` |
| **m32-g** | Per-zone filter | — | **DEFERRED, see §9** |
| **m32-c** | The sampling skill | m32-b2 | `swift-app-engineer` / orchestrator |

### 2.1 ⚠️ SCHEDULING CONSTRAINT — serialize every `SamplerInstrument.swift` item

**m32-a, m32-d and m32-f all touch the same four files:** `SamplerInstrument.swift` (the init
loader *and* the render loop), `Model.swift`'s `SamplerZone`, `Commands.swift`'s
`parseZoneFields`/`makeZone`/`merge`, and `ProjectDocument.swift`'s `SamplerZoneDocument`. Running
them concurrently produces merge conflicts in the most dangerous file in the milestone, in a
hot render loop, where a bad conflict resolution is inaudible until it is not.

**Run them strictly in order: a → d → f.** m32-b1 and m32-e touch none of those files and are
genuinely parallel.

### 2.2 Recommended lanes

- **Lane 1 (critical path):** m32-a → m32-b2 → m32-c
- **Lane 2 (parallel, day one):** m32-b1, then m32-e
- **Lane 3 (after m32-a, serialized behind it):** m32-d → m32-f

---

## 3. m32-a — Sampler loader dedup. THE DECISION.

### 3.1 The defect, restated with the arithmetic

`SamplerInstrument.swift:479-511` loops over `params.zones` and, per zone, opens the URL with
`AVAudioFile(forReading:)`, reads the **entire** file into an `AVAudioPCMBuffer`, then allocates
and copies a private `UnsafeMutableBufferPointer<Float>` **per channel** (`:500`, `:505`),
appending each to `ownedChannelBuffers` (`:502`, `:508`).

One copy of a 4-minute stereo 44.1 kHz rip = `240 × 44100 × 2 × 4 B` = **84,672,000 B ≈ 80.7 MiB**.

| zones on that one file | held today | held after m32-a |
|---|---|---|
| 8 | 0.63 GB | 80.7 MiB |
| 16 | 1.26 GB | 80.7 MiB |
| 32 | 2.52 GB | 80.7 MiB |
| 64 | 5.05 GB | 80.7 MiB |

It never errors. It allocates. Chopping is the *only* workflow that deliberately points many
zones at one long file, so this is exactly the axis a flip loads.

### 3.2 DECISION

**Dedup within one `init` load pass, keyed by the resolved source path, with the cache local to
`init` and the ownership ledger unchanged.** Concretely:

1. A local `var loadedFiles: [String: LoadedFile]` inside `init`, where
   `LoadedFile = (left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, fileRate: Double)`.
2. On a **miss**: today's code path verbatim — open, read, allocate, `ownedChannelBuffers.append(…)`,
   then record the entry.
3. On a **hit**: skip the open and both allocations entirely; take `left`/`right`/`frames`/`fileRate`
   from the entry. Every per-zone field (`startFrame`, `endFrame`, loops, pan, envelope, crossfade)
   is resolved exactly as it is today, against the cached `frames`.
4. `deinit` (`:698-700`) is **unchanged**: it iterates `ownedChannelBuffers` and frees each
   buffer exactly once. With dedup the list is shorter; nothing else about it moves.

**Ownership law, stated once so it can be pinned:**

> **`ownedChannelBuffers` is the sole allocation ledger. Every entry is freed exactly once, in
> `deinit`. `LoadedZone.left`/`.right` are BORROWED aliases into that ledger and are never freed
> through a zone. Two zones naming the same resolved path alias the same pair of pointers.**

### 3.3 ⭐ This generalizes an aliasing pattern that ALREADY SHIPS

`SamplerInstrument.swift:511` — for a **mono** file, `rightBase = UnsafePointer(left.baseAddress!)`.
Today, one allocation already backs two `LoadedZone` pointer fields, and `deinit` already frees
the ledger rather than the zones. **m32-a does not introduce aliasing; it widens an alias
relationship the code already relies on.** That is why the lifetime story needs no new machinery,
and it is the strongest single argument for this shape over the alternatives.

### 3.4 Keying — and the ONE-HOME ruling that comes with it

**Key = `URL.standardizedFileURL.path`.**

Not chosen freshly: it is what the tree *already* uses to decide whether two zones share a
file. `ProjectBundle.planMedia` dedups sampler-zone media on exactly this key
(`Sources/DAWCore/ProjectBundle.swift`, the zone loop: `let stdSource = zone.audioFileURL.standardizedFileURL`,
`if let name = assigned[stdPath] { refs[zone.id] = "media/\(name)"; continue }`).

⭐ **So save-to-bundle is already deduped — there is no second, on-disk blowup.** I checked
specifically because a per-zone `mediaRefs` dictionary keyed by zone id looked like it might copy
the file N times; it does not.

⚠️ **But the two keys must not be allowed to drift.** If the loader considers two zones to share
a file and `planMedia` does not (or the reverse), you get a project that plays one way and reloads
another — this tree's characteristic failure mode. **RULING: extract the existing expression into
one named home in DAWCore** —

```swift
extension SamplerZone {
    /// The identity of this zone's SOURCE FILE, for every "do these two zones
    /// share a file?" question in the tree. ONE HOME: the sampler loader's
    /// buffer dedup (m32-a) and ProjectBundle.planMedia's media-copy dedup MUST
    /// agree, or a project plays one way and reloads another.
    public var sourceFileKey: String { audioFileURL.standardizedFileURL.path }
}
```

— and change **both** call sites to use it. `planMedia`'s behaviour is byte-identical (same
expression, new name), so no shipped save path changes.

**Deliberately NOT `resolvingSymlinksInPath`.** It would catch more aliases, but it stats the
filesystem, and — decisively — changing `planMedia`'s key changes which bundle basenames a save
produces, which is a live behaviour change on a shipped path. A missed alias costs memory (today's
behaviour); a changed save key costs a user's project layout. If symlink resolution is ever
wanted, both sites move together because there is now one home. Record it as a known limitation:
**two zones reaching one file through a symlink still get two copies.**

### 3.5 Lifetime under a zones re-set — verified, and the answer is "nothing to do"

I checked the reconcile path rather than assuming. `PlaybackGraph.InstrumentTrackKey`
(`PlaybackGraph.swift:235-241`) carries `samplerZones: [SamplerZone]?`, and its doc says:

> *"EXCEPTION — sampler zones are STRUCTURAL: zone audio lives in immutable buffers loaded at
> instrument init, so any change to the zones array (files, spans, roots) must rebuild the node."*

Confirmed at the teardown site (`:967-979`): a `samplerZones` mismatch unpublishes, flushes, and
tears the node down; a **fresh `SamplerInstrument` reloads the zone files**. The in-place
`apply(params:)` path (`:1612-1618`) explicitly never carries zones.

**Therefore:** buffers are per-instrument-instance, and a zones re-set frees the old instance's
ledger through the ordinary `deinit` once the retire bin releases it. **There is no cross-instance
sharing in v1 and none is needed.** Two sampler *tracks* on the same rip still hold two copies —
80.7 MiB each, not 5 GB — and that is stated, not hidden.

### 3.6 RT-safety — what the render thread may touch, and why the invariant survives

Everything in §3.2 runs in `init`, which the class header pins to *"reconcile time on the main
actor (PlaybackGraph's instrument factory) — NEVER on the render thread."* The render path's
contract (`SamplerInstrument.swift:102-106`) is unchanged and is *why* dedup is safe:

> *"voices and zone descriptors live in fixed heap blocks allocated in init; **sample memory is
> immutable after init**"*

The render thread touches sample memory only through `zones[i].left` / `zones[i].right`, and only
to **read** (`:959` and the interpolation around it). Aliasing N zones onto one immutable,
read-only buffer changes nothing observable to a reader: no new allocation, no new lock, no ARC,
no ObjC, no branch added to the render loop. `LoadedZone` stays POD. The one invariant that could
break is *double free*, and it cannot: the ledger, not the zone, owns the allocation, and the
ledger gains no duplicate entries.

Positive statement of the invariant for the reviewer: **`ownedChannelBuffers` contains no two
entries with the same `baseAddress`, and every `LoadedZone.left`/`.right` equals the
`baseAddress` of exactly one entry.**

### 3.7 The two strongest alternatives, and why they lose

**(A) A process-wide sample-buffer cache with refcounting.** Keyed by resolved path, shared across
every `SamplerInstrument` instance and across rebuilds, so a zone edit does not re-read an 80 MiB
file. Genuinely better on the flip workflow's *latency* axis (§3.8). **Loses on risk-per-value:**
it introduces a mutable global whose lifetime is decided by refcounts released from `deinit`,
which runs on whatever thread drops the last reference — including, potentially, off the main
actor, under Swift 6 strict concurrency, while the retire bin still guarantees a render thread may
be *reading* those exact bytes. That is a use-after-free class this milestone does not need to
open to get the 60× win. It is the named deferral in §12; do it when a measurement demands it,
with an explicit owner actor and no `deinit`-driven release.

**(B) Memory-map the file (`mmap` / `AVAudioFile` + `Data(contentsOf:.mappedIfSafe)`).** One copy
in the page cache, zero-copy reads, no dedup logic at all. **Loses on two hard grounds:** it
delivers *file bytes*, not `Float32` deinterleaved at the file's native layout — the current code
depends on `processingFormat`'s deinterleaved Float32 (`:482-483`), so any compressed or
integer-PCM source needs the decode-and-convert step anyway; and a mapped page fault **blocks the
render thread on I/O**, which is a direct violation of the render-path contract. This is a real
architecture for a streaming sampler and a wrong one for this loader.

### 3.8 What m32-a does NOT fix, stated plainly

Every zone edit is structural (§3.5), so **editing one zone of a 32-zone chop re-reads and
re-copies the whole 80.7 MiB file** — once, instead of 32 times, which is the win, but still once
per edit. Two consequences the implementing agent must not paper over:

1. The teardown announces a flush (all-notes-off), so **editing a zone while playing cuts sounding
   notes.** Pre-existing, unchanged by this item.
2. It is a direct argument for **m32-b2 creating all N zones in ONE edit** rather than the agent
   looping `track.setInstrument` per slice: one edit, one rebuild, one file read.

### 3.9 GATE — measured, two-directional, with an always-on positive control

New file: `Tests/DAWEngineTests/SamplerZoneBufferDedupTests.swift` (`@testable import DAWEngine`;
`SamplerInstrument` is internal).

Two internal test seams on `SamplerInstrument` — **note these sum the real allocation list; they
are a ledger reading, not a setter's return value:**

```swift
/// m32-a gate seam: total bytes ACTUALLY held. Summed from the allocation
/// ledger itself, so a loader that forgot to dedup cannot report otherwise.
var loadedSampleBytes: Int {
    ownedChannelBuffers.reduce(0) { $0 + $1.count * MemoryLayout<Float>.size }
}
var ownedSampleBufferCount: Int { ownedChannelBuffers.count }
/// Base addresses of zone i's channel pointers — the aliasing invariant.
func zoneBufferBaseAddresses(_ i: Int) -> (UInt, UInt)
```

| # | Test | Assertion |
|---|---|---|
| 1 | `sixteenZonesOneStereoFileHoldOneCopy` | 16 zones, one 2 s stereo fixture → `loadedSampleBytes == 2 · frames · 4` and `ownedSampleBufferCount == 2` |
| 2 | ⭐ `eightZonesEightFilesHoldEightCopies` | 8 zones, 8 **distinct** fixtures → `loadedSampleBytes == 8 · oneFileBytes`, `ownedSampleBufferCount == 16` |
| 3 | `sameFileZonesShareBasePointers` | `zoneBufferBaseAddresses(0) == zoneBufferBaseAddresses(15)` |
| 4 | `differentPathSpellingsShareOneCopy` | `/tmp/a/x.wav` and `/tmp/a/b/../x.wav` → one copy |
| 5 | `monoFileStillAliasesLeftAndRight` | regression pin on the existing `:511` alias: `ownedSampleBufferCount == 1`, both base addresses equal |
| 6 | `dedupDoesNotChangeRenderedAudio` | offline-render a 2-zones-one-file project and a 2-zones-two-byte-identical-files project → **identical output buffers** |
| 7 | `zoneSourceFileKeyMatchesPlanMedia` (DAWCore) | `SamplerZone.sourceFileKey` and `planMedia`'s grouping agree on the same 4-URL set |

⭐ **Test 2 is the always-on positive control and it is the reason this gate is not blind.** An
instrument that reported "one file's bytes" unconditionally — or a seam that measured the wrong
thing — passes test 1 and **fails test 2.** A gate that can only go green in one direction has not
been controlled.

**Additional implementation-time plant, recorded in the item close (the tree's established
practice):** delete the cache-hit early return, re-run, and record which tests redden. Expected:
1, 3, 4 red; 2, 5, 6 green. If 2 or 5 also reddens, the change is wrong in a second way.

**Run the new suite once under Address Sanitizer** (`swift test -Xswiftc -sanitize=address`, or the
`./scripts/test.sh` equivalent) to positively exclude a double free. A double free is the single
failure this design could plausibly introduce, and no functional test sees it.

---

## 4. m32-b0 — `SliceBoundaries`: the ONE HOME for slice-span math

New file: **`Sources/DAWCore/SliceBoundaries.swift`.** Pure, headless, no engine, no UI.

Three consumers: `AudioQuantizePlan.compute` (existing), `clip.quantizeAudio`'s new grid mode
(m32-b1), and `SliceToSamplerPlan` (m32-b2). Whichever of b1/b2 lands first **delivers** this
module; the second **consumes** it. The signatures below are the contract so the order does not
matter.

```swift
public enum SliceBoundaries {

    /// Conditions a raw onset list into usable boundaries. EXTRACTED VERBATIM
    /// from AudioQuantizePlan.compute step 1 (AudioQuantize.swift:157-168) —
    /// sorted, strictly inside the window, at least `minSlice` from BOTH window
    /// edges, and merged when closer than `minSlice` to their predecessor.
    /// Returns SOURCE-FILE SECONDS, ascending, strictly increasing.
    public static func condition(onsetsSourceSeconds: [Double],
                                 windowStart: Double,
                                 windowEnd: Double,
                                 minSliceSeconds: Double) -> [Double]

    /// N equal divisions of [windowStart, windowEnd): the interior boundaries
    /// only (count == divisions - 1), so the result is the same SHAPE as a
    /// conditioned onset list and both feed the same span builder.
    /// `divisions` must be >= 2. Boundaries closer than minSlice are dropped by
    /// the same rule as `condition`.
    public static func equalDivisions(windowStart: Double, windowEnd: Double,
                                      divisions: Int,
                                      minSliceSeconds: Double) -> [Double]

    /// Musical-grid boundaries: every multiple of `gridBeats` strictly inside
    /// the window, mapped to SOURCE SECONDS through the tempo map at the clip's
    /// position. Same conditioning rule applied on the way out.
    public static func gridDivisions(clipStartBeat: Double, windowStart: Double,
                                     windowEnd: Double, gridBeats: Double,
                                     tempoMap: TempoMap,
                                     minSliceSeconds: Double) -> [Double]
}
```

**Extraction gate (m32-b0's own):** `AudioQuantizePlan.compute` must produce **byte-identical**
output before and after the extraction. The existing audio-quantize suite is the gate; add one
explicit test that feeds a hand-built onset list with all four conditioning hazards (unsorted, one
outside the window, one inside `minSlice` of `windowStart`, one inside `minSlice` of its
predecessor) and pins the exact surviving list.

⚠️ **The extraction must not "improve" anything.** The `guard onsets.count >= 2` and the
`audioQuantizeNoTransients` throw stay in `AudioQuantizePlan`, not in `SliceBoundaries` — the
minimum-count rule differs between consumers (§6.5).

⚠️⚠️ **`gridDivisions` TAKES A SINGLE seconds-per-beat, so its caller MUST reject a window that
crosses a tempo-map boundary.** With a tempo change inside the clip window, every boundary after
it is silently misplaced — plausible-looking wrong frames, the exact failure this document spends
its length designing out. `AudioQuantizePlan.compute:141-144` already carries the verbatim
precedent (the m12-c cut): `guard tempoMap.isConstant(from: clip.startBeat, to: clip.startBeat +
clip.lengthBeats) else { throw .audioQuantizeTempoBoundaryUnsupported(clip.id) }`, and its comment
says why — the algorithm assumes ONE constant source↔timeline factor across the whole clip.
**Only the `grid` mode is affected.** `transients` and `divisions` are computed entirely in the
SOURCE-SECONDS domain and never consult the tempo map, so they are correct across a tempo change
and must NOT be rejected. (The reconstruction MIDI in §6.8 maps source seconds to beats through
`tempoMap.beat(from:elapsedSeconds:)`, which integrates the map properly and is correct in all
three modes.)

---

## 5. m32-b1 — Fixed-grid division on `clip.quantizeAudio`. NOT a new command.

### 5.1 DECISION

**No `clip.chop`, no `destination` parameter, no second chop-to-timeline materializer.** The
capability is shipped (§1.4). Two additive changes to `clip.quantizeAudio`:

1. **`divisions: Int?` (2…128)** — when present, boundaries come from
   `SliceBoundaries.equalDivisions` instead of the detector. Mutually exclusive with
   `sensitivity`; the same "exactly one of" error shape as `zones`/`zonePatches`
   (`Commands.swift:9694-9701`).
2. **`gridBeats` becomes optional when `strength == 0`** — it is irrelevant there (nothing is
   nudged) and requiring it makes the chop use-case read like a mistake. Omitted + `strength: 0`
   → the plan runs with any positive grid; the response is unchanged.
   ⚠️ Requiring it remains the behaviour for `strength > 0`, so no shipped caller changes.
3. **A description fix, in `Commands.swift` and `mcp-server/src/server.ts`**, naming the chop use
   case in the first two sentences: *"With `strength: 0` this is a pure CHOP — the clip is cut at
   its transients (or at `divisions` equal parts) into slices that stay exactly where they were,
   in one undo step, with clean sample-exact joins and no crossfades."*

### 5.2 Why the alternatives lose

**A new `clip.chop` command.** Better *discoverability* — an agent scanning a tool list finds
"chop" and never finds it under "quantize". Loses because it makes two wire verbs for one
operation, and the additive-only law means the weaker one can never be removed. Discoverability is
a *description* problem and change 3 fixes it at its actual cost. If the description fix proves
insufficient in dogfooding (m32-c will tell us — an agent either reaches for it or does not), a
thin alias is a cheap follow-up **then**, with evidence.

**A `destination: zones | clips | both` parameter on one materializer.** Loses on four grounds and
this is the ruling the orchestrator asked for:

1. **Different unit domains.** The zone destination lives in SOURCE FRAMES at the *file's* sample
   rate; the clip destination lives in TIMELINE BEATS through the tempo map. They share only the
   conditioned onset list in source seconds — which §4 already shares properly.
2. **Different dependencies.** The clip destination needs no PCM at all and no engine seam
   (§1.4: it is click-free by construction). The zone destination needs the snapper, the file's
   rate, and its frame count.
3. **Different blockers.** m32-a gates the zone destination *only*. A merged command could not
   ship until m32-a landed, which would strand a shipped capability behind an unrelated blocker.
4. **Half the parameters would be inapplicable in each mode.** `baseNote`, `generateMIDI`,
   `targetTrackId`, `snapToZeroCrossing` mean nothing for clips; `crossfadeMs`, `swing`, `groove`
   mean nothing for zones. A verb where half the params silently do nothing is the exact
   silent-success shape this tree keeps getting bitten by.

### 5.3 Gate

`Tests/DAWControlTests/ClipQuantizeAudioGridTests.swift` — (a) `divisions: 8` on a 4 s window
yields 8 clips at exact 0.5 s source offsets; (b) `divisions` + `sensitivity` together is a named
error; (c) `strength: 0` with `gridBeats` omitted succeeds and produces slices at **byte-identical**
source offsets to the same call *with* `gridBeats: 1` (the pin that the parameter really is
irrelevant); (d) every existing `clip.quantizeAudio` test still passes untouched.
Positive control: assert (c)'s two offset arrays are equal **and** that a `strength: 0.5` run
produces a *different* array — a comparison that can only ever return "equal" proves nothing.

---

## 6. m32-b2 — `clip.sliceToSampler`. THE item.

### 6.1 Shape

```
clip.sliceToSampler {
  clipId:            UUID     required   the SOURCE REGION — the clip's own window bounds the chop
  targetTrackId:     UUID?               instrument track to receive the zones; omitted = create one
  mode:              String?             "transients" (default) | "divisions" | "grid"
  sensitivity:       Double?             0…1, default 0.5            [transients]
  divisions:         Int?                2…128                        [divisions]
  gridBeats:         Double?             > 0                          [grid]
  minSliceSeconds:   Double?             default 0.05
  maxSlices:         Int?                default 32, hard cap 96
  includeHead:       Bool?               default false
  baseNote:          Int?                default 36 (C1)
  snapWindowMs:      Double?             0…20, default 3; 0 disables snapping
  generateMIDI:      Bool?               default true
  atBeat:            Double?             where the reconstruction clip lands; default = source clip's startBeat
  velocityFromStrength: Bool?            default FALSE — see §6.6
}
```

**Clip-centric, not file-centric, and that is load-bearing.** The clip's source window *is* the
capture: an agent trims a clip to the four bars it wants and chops that. It also inherits
`locateClip`, the `clipNotFound`/`transientsRequireAudioClip` vocabulary, and the
`clip.detectTransients` / `clip.quantizeAudio` idiom an agent already knows.

**One command with a `mode` enum, not three commands.** Unlike §5.2's rejected `destination`, the
three modes here differ **only** in where the boundary list comes from; every other parameter,
every unit, every output and every failure mode is identical. A `mode` that selects a boundary
source is a parameter; a `destination` that selects an output domain is a different verb.

**No `dryRun`.** `clip.detectTransients` already *is* the preview (read-only, cached, returns both
coordinates), the response below is complete enough to evaluate after the fact, and `edit.undo`
exists. Inventing a `dryRun` idiom this tree does not have, for one verb, is not worth it. Stated
as a deliberate cut so it is not re-litigated silently.

### 6.2 The engine seam — new `AudioEngineControlling` requirement

**This is where §1.1 lands.** DAWCore cannot open the file, so the file's sample rate, its frame
count, and the zero-crossing search all cross one seam, in one call:

```swift
// Sources/DAWCore/EngineProtocol.swift — new requirement + default impl.

/// m32-b2: resolve slice boundaries against a source file's own PCM.
/// `boundarySeconds` are SOURCE-FILE seconds (the clip.detectTransients
/// domain). The result carries the file's OWN sample rate and frame count
/// alongside the snapped positions IN FRAMES, so no caller ever converts
/// seconds to frames against a rate it guessed.
func resolveSliceBoundaries(inFileAt url: URL,
                            boundarySeconds: [Double],
                            snapWindowSeconds: Double) async throws -> SliceBoundaryGeometry
```

```swift
public struct SliceBoundaryGeometry: Codable, Sendable, Equatable {
    public var sampleRate: Double          // the FILE's own rate
    public var frameCount: Int             // the FILE's own length
    public var boundaryFrames: [Int]       // snapped, ascending, strictly increasing
    public var snapOffsetFrames: [Int]     // signed movement per boundary, index-aligned
    public var residualAmplitude: [Double] // max_c |x_c[k]| at the chosen frame, 0…1
}
```

Default implementation in the `extension AudioEngineControlling` block
(`EngineProtocol.swift:1055…`) **throws `ProjectError.engineUnavailable`**, following the
`renderOffline` / `writeAudioFile` "optional capability" idiom. ⭐ **That default is why this does
not break the ~20 existing `AudioEngineControlling` test doubles** — verified, not assumed:
`FakeTransientEngine` implements **16** methods against ~129 protocol requirements, so it relies
on that extension for everything else.

⚠️ **THROW, do not return an empty/zero value — and note this deliberately DIVERGES from
`detectTransients`'s neighbouring default, which returns `[]`.** An empty onset list is a
defensible "no onsets here". A fabricated `SliceBoundaryGeometry{sampleRate: 0, frameCount: 0,
boundaryFrames: []}` is not: it would flow into the planner and produce zones with nonsense frame
spans, i.e. **a plausible-looking valid answer from an engine that cannot answer** — this tree's
characteristic failure mode. The `liveLoudness` default states the same doctrine in its own
comment (*"a fabricated all-nil snapshot claiming '0 s analyzed' from an engine that CANNOT
analyze would still read like a real meter"*) and reaches the same conclusion.

Real implementation: **`Sources/DAWEngine/Analysis/BoundarySnapper.swift`**, wired in
`AudioEngine.swift` beside `detectTransients`. Test double: the `FakeTransientEngine` pattern
(`Tests/DAWControlTests/ClipTransientCommandTests.swift:10`).

⭐ **The 8.8 % unit trap is now unrepresentable, not merely forbidden.** The briefing's rule was
"the seconds→frames conversion MUST happen inside the command." This is stronger: the *only* way
to obtain a frame number is from a struct that also carries the rate those frames are in, produced
by the code that opened the file. Neither MCP glue nor agent reasoning is ever handed a seconds
value it could divide by a hardcoded 44100.

### 6.3 The snap — what it actually does, named honestly

⭐ **RULING: "boundary snap" searches ±`snapWindowSeconds` around each candidate and picks the
frame `k` minimising `max_c |x_c[k]|`, tie-broken toward the candidate.**

On a **mono** file that *is* the zero crossing. On a **stereo** file a simultaneous zero crossing
in both channels usually does not exist inside a 3 ms window, and snapping on the *sum* can land
on a point where L and R are large and opposite — a worse click than not snapping. Minimising the
per-channel maximum directly minimises the discontinuity in **both** channels, which is what "no
click" physically means. **`residualAmplitude` is reported per boundary so the caller can see
whether a real crossing was found or merely the quietest available point.** Honesty over the name;
the response and the docs both say "boundary snap", not "zero-crossing snap".

Three properties that must hold, each an assertion:

1. ⭐ **Snap each boundary ONCE and use the snapped frame as BOTH slice *i*'s `endFrame` and
   slice *i+1*'s `startFrame`.** Snapping starts and ends independently opens gaps and overlaps
   and silently destroys the `[onsetᵢ, onsetᵢ₊₁)` invariant.
2. ⭐ **Clamp `snapWindowSeconds ≤ minSliceSeconds / 2` inside the command**, so snapped
   boundaries can never reorder. Then assert the output is strictly ascending. (At the defaults,
   3 ms vs 25 ms, this never bites; it exists for the caller who passes `minSliceSeconds: 0.004`.)
3. The window is clamped to the file: no search below frame 0 or at/above `frameCount − 1`.

### 6.4 Where the work lives

| Layer | File | Contents |
|---|---|---|
| Planning (pure) | `Sources/DAWCore/SliceToSampler.swift` | `SliceToSamplerPlan.compute(...)` → `(zones: [SamplerZone], notes: [MIDINote], slices: [SliceReport])`. Mirrors `AudioQuantizePlan`. **No file I/O, no engine, no UI.** |
| Orchestration | `Sources/DAWCore/ProjectStore+SliceToSampler.swift` | validation → `engine.detectTransients` → `SliceBoundaries` → `engine.resolveSliceBoundaries` → `SliceToSamplerPlan` → one `performEdit`. Mirrors `ProjectStore+Quantize.swift`. |
| PCM | `Sources/DAWEngine/Analysis/BoundarySnapper.swift` | §6.2/§6.3. |
| Wire | `Sources/DAWControl/Commands.swift` | verb, `rejectUnknownKeys`, `allCommands` entry. |
| MCP | `mcp-server/src/server.ts` | `clip_slice_to_sampler`. |

### 6.5 Validation, in the order it must run

Fail fast **before** the (slow) detection, the `quantizeAudioClip` discipline
(`ProjectStore+Quantize.swift:172-184`):

1. `engineUnavailable` if no engine.
2. `clipNotFound` / `trackNotFound`.
3. `transientsRequireAudioClip` for a MIDI clip.
4. ⭐ **`audioQuantizeStretchUnsupported` for `!clip.isStretchIdentity`, and the same for
   `pitchShiftSemitones != 0`.** ⚠️ **This is not boilerplate — it is a correctness guard.** Zones
   read RAW source frames. A clip with `stretchRatio 0.9` *sounds* one way on the timeline and
   its source file sounds another, so the "reconstruction" would silently not match what the user
   is hearing. Un-stretch or bounce first; the error says so. (`pitchShiftSemitones` needs its own
   message — reuse the shape, add a distinct sentence.)
5. `invalidClipEdit` if the clip has no `audioFileURL`.
6. ⚠️ **`mode: "grid"` ONLY** — `audioQuantizeTempoBoundaryUnsupported` when
   `!tempoMap.isConstant(from: clip.startBeat, to: clip.startBeat + clip.lengthBeats)`. See §4:
   `gridDivisions` uses one seconds-per-beat, so a tempo change inside the window misplaces every
   later boundary. **`transients` and `divisions` are source-domain and must NOT be rejected.**
7. `targetTrackId`, when given, must name an existing track of kind `.instrument`. A non-instrument
   track is a teaching error naming the kind it found.
8. Boundary count: after conditioning, `slices = boundaries.count + (effectiveIncludeHead ? 1 : 0)`.
   > ⚠ Corrected 2026-09-24 (m33-d): the original read `includeHead`, which dropped the first piece in `divisions`/`grid` mode ("Equal pieces 8" gave 7 pads). `effectiveIncludeHead = includeHead || mode != .transients` (`SliceToSampler.swift:120-122`).
   - `slices < 1` → `audioQuantizeNoTransients` (nothing changes).
   - `slices > maxSlices` → **REJECT**, naming the count and the three levers (lower
     `sensitivity`, raise `minSliceSeconds`, trim the clip window). ⭐ **Never truncate.** Keeping
     the strongest N would silently drop the tail of the groove and return a plausible-looking
     valid answer.
   - `baseNote + slices - 1 > 127` → REJECT, naming the arithmetic. Same reason.

⚠️ **`requireNotCompMember` is NOT needed here** and must not be added. The source clip is
**read-only** in this command — it is not sliced, moved, or replaced. This is the
`detectTransients` posture, not the `quantizeAudio` posture. Adding the guard would refuse a
legitimate chop of a comp'd take for no reason.

### 6.6 ⭐⭐ RULING THAT CONTRADICTS THE BRIEFING: reconstruction velocity is 127, not `strength`

The briefing and the roadmap both say *"transient `strength` → velocity"*. **That is wrong, and
the mechanism is arithmetic, not taste.**

`SamplerInstrument.swift:1375-1379`:

```swift
let velocityAmp = 1 - zone.ampVelTrack
    + zone.ampVelTrack * (Float(event.velocity) / 127.0)
let amp = velocityAmp * zone.gain
```

With `ampVelTrack` nil (the default), `vt = 1` and `amp = velocity/127 × gain`. **The slice
already contains its own recorded amplitude.** A ghost note detected at `strength: 0.1` would be
triggered at velocity ≈ 13, i.e. **−20 dB below its own recorded level** — double attenuation.
The reconstruction would not sound like the record, which destroys the single most valuable
property of the MPC pattern the research identifies: *you start from "plays back identically to
the source" and edit from there.*

**RULING: reconstruction notes are velocity 127 by default.** 127/127 = exactly 1.0, so each
slice plays at precisely its recorded level — a bit-faithful reconstruction — while the zone's
velocity law stays **live**, so an agent writing a *new* pattern at velocity 64 still gets half
amplitude. It is the only value that satisfies both.

- `velocityFromStrength: true` restores the briefing's behaviour for callers who want the
  detector's dynamics, documented as *deliberately quieter than the source*.
- `strength` stays in the response's slice table regardless, so nothing is lost.
- Rejected alternative: `ampVelTrack: 0` on every generated zone + velocity 100. Also exact, but
  it makes velocity **inert** on a sampler instrument, which would be a baffling default.

### 6.7 Generated zone fields — every one of them, and why

For slice *i* over `[frames[i], frames[i+1])`:

| Field | Value | Why |
|---|---|---|
| `audioFileURL` | the clip's `audioFileURL` | one file, N zones — **this is m32-a's exact load** |
| `rootPitch` | `baseNote + i` | plays at recorded speed on its own pad |
| `minPitch` / `maxPitch` | `baseNote + i` (both) | one pad, one slice. A slice is a fragment of a record; letting it sound across a whole keyboard by default produces overlapping garbage on a chord. **Chromatic play stays one `zonePatches` call away** (widen `maxPitch`) and the skill teaches it — that is the "16 Levels" pattern from research §2.7 |
| `startFrame` | `frames[i]` | |
| `endFrame` | `frames[i+1]`, **and `nil` on the LAST slice** | ⭐ nil resolves to the exact file end at `SamplerInstrument.swift:535`, so no float round-trip through `durationSeconds × sampleRate` can overshoot by one frame and trigger a spurious "zone start/end clamped" note in `zoneLoadNotes` |
| `attack` | `0.0` | preserve the transient. ⚠️ **Legal and safe: `SamplerInstrument.swift` computes `attackStep = Float(1.0 / max(1.0, Double(zone.envAttack) * sampleRate))` — the `max(1.0, …)` clamps, giving a one-frame rise; there is no divide by zero.** Explicit 0 also stops a nonzero *global* attack from softening every chop |
| `release` | `0.010` | ⭐ **the real click fix at the END of a slice.** The snap makes the *start* quiet; the end is a hard stop to silence when a pad is played in isolation, and only an envelope fixes that. 10 ms is `AudioQuantizeSettings.defaultCrossfadeSeconds` — reusing the tree's number, not inventing one |
| `gain` | `1` | |
| everything else | `nil` | the nil-default law: an unauthored field must decode and render exactly as it always has |

### 6.8 The reconstruction MIDI clip

- **Same track as the zones.** A sampler instrument track plays MIDI clips; there is no second
  track and no cross-track wiring. This falls out of the design rather than being decided.
- Note *i*: pitch `baseNote + i`, velocity per §6.6.
- Start beat: ⭐ **reuse `detectClipTransients`'s exact projection**
  (`ProjectStore+Quantize.swift:81-84`) —
  `tempoMap.beat(from: clip.startBeat, elapsedSeconds: (t − windowStart) × clip.stretchRatio)`.
  ONE home for source-seconds→timeline-beats; `stretchRatio` is 1 here (§6.5 guard 4) but the
  formula stays whole so the two sites cannot drift, and it integrates the tempo map correctly in
  all three modes.
- Length: to the next boundary's beat; the last runs to the clip's window end. With `oneShot` the
  note-off is ignored, but the lengths must still be right — an agent reads them, and turning
  `oneShot` off later must not reveal wrong lengths.
- Placement: `atBeat ?? sourceClip.startBeat`, so the chop lines up with the original for A/B.

### 6.9 Track auto-creation

`targetTrackId` omitted → create an `.instrument` track named `"<clip name> chops"` with a
`.sampler` descriptor, **inside the same `performEdit`**, and report `createdTrackId` in the
response. One undo removes the track, the zones and the MIDI clip together. The usual objection to
implicit creation — "undo deletes a track the user has since edited" — does not apply, because by
then the undo stack has moved past this edit.

### 6.10 Undo

```swift
performEdit("Chop to Sampler") { ... }      // ⚠️ NO key:
```

⚠️ **No `key:`.** Coalescing is an 800 ms window intended for slider scrubs; two chops inside it
would fold into one undo step and the first chop would become unreachable. `applyAudioQuantize`
(`ProjectStore+Quantize.swift:152`) is the precedent and its comment says why: *"NO coalescing — a
re-run compounds; undo first."*

One `engine?.tracksDidChange(tracks)` at the end of the block — one structural rebuild, one file
load, deduped (§3.8.2).

### 6.11 Response

```json
{ "trackId": "…", "createdTrackId": "…"?, "midiClipId": "…"?,
  "sampleRate": 44100, "frameCount": 10584000, "sliceCount": 16,
  "headSeconds": 0.031,
  "slices": [ { "index": 0, "pitch": 36, "startFrame": 132300, "endFrame": 143521,
                "sourceSeconds": 3.0, "beat": 8.0, "strength": 0.82,
                "snapOffsetFrames": -14, "residualAmplitude": 0.0007 } ],
  "warnings": [ ... ] }
```

⭐ `headSeconds` is always reported, and when `includeHead` is false **and**
`headSeconds > 2 × minSliceSeconds` the response carries a `warnings` sentence naming the
discarded span and how to keep it. The `ClampNotice` doctrine
(`Sources/DAWCore/ClampNotice.swift`) applies verbatim: warn, do not reject, and only warn when
something actually happened — *"noise is ignored, taking the warning that mattered with it."*

`includeHead` defaults **false** because the material before the first detected onset is pre-roll,
and MPC/Recycle both start pad 1 at the first slice point. But a detector that misses the first
hit would silently eat a downbeat, so the discard is always visible.

### 6.12 Gates

- `Tests/DAWCoreTests/SliceToSamplerPlanTests.swift` — pure planning against a **fake**
  `SliceBoundaryGeometry`: span adjacency (`zone[i].endFrame == zone[i+1].startFrame`), last zone's
  `endFrame == nil`, pitch sequence, note beats, `attack`/`release`, `includeHead` both ways,
  every §6.5 rejection.
- ⭐ `Tests/DAWCoreTests/SliceToSamplerRateTests.swift` — **THE UNIT-TRAP GATE.** Run the identical
  plan against `sampleRate: 44100` and `sampleRate: 48000` geometries for the same clip and assert
  the frame numbers differ by exactly the 48000/44100 ratio. **Positive control:** a third
  assertion that the two arrays are *not* equal — a test that only ever compares one rate to
  itself cannot see a hardcoded constant.
- `Tests/DAWEngineTests/BoundarySnapperTests.swift` — on a synthesized 440 Hz sine at known phase,
  a candidate at a peak snaps to the crossing within 3 ms; `residualAmplitude` there is < 1e-3;
  a **DC-offset** fixture (no crossings at all) still returns a frame, reports a high residual, and
  does **not** throw; strictly-ascending output; `snapWindowSeconds: 0` returns the unsnapped
  frames exactly.
- `Tests/DAWControlTests/SliceToSamplerCommandTests.swift` — wire shape, unknown-key rejection,
  every error string, `createdTrackId`, `headSeconds` warning, all three modes.
- ⭐ **The reconstruction gate, and it is the one that proves the feature:** offline-render (i) the
  original audio clip and (ii) the generated sampler track playing the generated MIDI clip, with
  everything else silenced, and assert **RMS within 0.5 dB and transient count equal**. This is the
  "plays back identically to the source" property stated as a measurement.
  ⭐ **Positive control:** perturb one generated zone's `startFrame` by 2000 frames and assert the
  transient-count or RMS assertion **fails.** A reconstruction test that cannot fail is not a test.

---

## 7. m32-d — Reverse zones (shape)

**New field: `SamplerZone.reverse: Bool?`**, nil = forward = today's behaviour byte-for-byte.

**Read-backwards INDEX MATH, never a materialised reversed buffer** — a reversed copy would be a
second full-file allocation per reversed zone and would undo m32-a on exactly the workflow that
needs it.

**DECISION on the render loop: a per-voice direction scalar, not a duplicated loop body.**

At trigger, set `voice.readBase` and `voice.readDir` (+1 forward, −1 reversed) and start a reversed
voice at `endFrame − 1`. The per-frame position update becomes `base + dir × local`. For a forward
voice `base = 0, dir = +1`, so the expression is `0 + 1 × local` — an **IEEE identity**, bit-for-bit
what ships today.

- *Alternative rejected:* two specialised loop bodies selected once per voice. Trivially
  byte-identical for forward voices, but it duplicates ~30 lines of a hot loop that already handles
  loops, crossfades, envelopes and expression — and a divergence between the copies would be
  audible only in the reversed case, which is the case nobody listens to first.
- *Alternative rejected:* a `reverse` branch **inside** the per-frame loop. A predictable branch,
  but it puts a test in the innermost loop for every voice in the instrument, forever, to serve a
  minority feature.

**v1 reversed zones IGNORE loops**, stated rather than half-solved: `loopMode` is forced to 0 at
load for a reversed zone, with a `zoneLoadNotes` entry saying so. Reversed-loop interaction
(which end the crossfade belongs to, what "sustain loop" means backwards) is a real design question
and this item does not answer it.

⚠️ **Envelope note the research flags and the implementer must handle** (§2.4): reversing moves the
decay to the front. The zone's `attack`/`release` are *not* swapped automatically — they are
authored against playback time, not source time, so a 10 ms release still trims the (now
reversed-decay) tail correctly. Say this in the field's doc comment; do not swap them.

**Gates.** (a) ⭐ **Sample-exact mirror**: an asymmetric ramp fixture (0 → 1 linearly) rendered
through a reversed zone at `rootPitch` must equal the forward render **reversed**, sample for
sample. This catches the fractional-index inversion trap that a "sounds backwards" test cannot.
(b) ⭐ **Forward byte-identity**: SHA256 of an offline render of a project containing a **looping**
zone **and** a bent note — the two places the position math is hairiest — must be unchanged by this
item. (c) A reversed **looping** zone emits the note and does not loop.

---

## 8. m32-e — Bit-crush / sample-rate reduction (shape)

**An insert EFFECT, not a zone field.** The SP-1200 character comes from the machine's D/A stage —
it applies to the whole part, not per pad; the research classes it cosmetic; and the effect chain
already exists with ten precedents.

New `EffectKind.bitCrusher` + `BitCrusherParams` (DAWCore `Model.swift`), `resolvedBitCrusher`, two
cases in `EffectFactory` (`makeInstance`, `applyParams`), and
`Sources/DAWEngine/Effects/BitCrusherEffect.swift`.

| Param | Range | Default | Note |
|---|---|---|---|
| `bits` | 1…16 | **12** | the SP-1200 / MPC60 storage depth |
| `downsampleHz` | 1000…48000 | **26040** | ⭐ the measured SP-1200 rate, from the research's sources |
| `antiAlias` | Bool | **false** | ⭐⭐ **the authenticity switch the research demands.** A generic crusher *with* reconstruction filtering sounds "clean-but-crunchy", not "gritty" — the character *is* the aliasing. Default false = authentic; true = a modern, tamer crush |
| `dither` | Bool | **false** | same argument; dithering removes the quantization character |
| `mix` | 0…1 | 1.0 | parallel crush |

RT-safety: per-sample arithmetic plus one phase accumulator and one sample-and-hold register per
channel. **No allocation, no branch on a `Double` division per sample** — the downsample ratio is
recomputed only in `prepare`/`apply`, never per frame. Sample-and-hold uses a phase accumulator
a phase accumulator, **not** integer modulo of a sample counter, because the graph rate is rarely
an integer multiple of 26040.

⚠️⚠️ **THE LITERAL FORM ORIGINALLY SPECIFIED HERE IS BUGGY AND WAS REPLACED — MEASURED, NOT
ARGUED.** This line read `phase += ratio; if phase >= 1 { phase -= 1; hold = x }`. The m32-e
implementer modelled it in IEEE 754, then **planted it in-tree and rendered**: at 8 kHz into
48 kHz it emits **`[7: 1, 6: 3998]`** — `8000/48000` is not representable, six increments sum to
just *under* 1.0, and one hold run comes out a sample long.
✅ **Shipped instead: the algebraically identical COUNTDOWN form** — `if countdown <= 0 { countdown
+= period; hold = x }; countdown -= 1` — whose increment is exactly `1.0` and therefore exact.
Same accumulator class, still fractional, still carried across block boundaries (the "not integer
modulo" ruling stands), and **both forms produce an identical histogram at the 26040 default**, so
the divergence only shows at rates where the ratio is badly conditioned.
⭐ **Worth keeping as a method note: the bug was found by PLANTING THE SPEC'S OWN FORMULA and
measuring it, not by reading it.** A formula that is correct in exact arithmetic can be wrong in
floating point, and only a render will say so.

Gates: bit-depth quantization produces exactly `2^bits` distinct output levels on a ramp;
`downsampleHz` produces a measurable spectral image at `downsampleHz − f` with `antiAlias: false`
and **does not** with `antiAlias: true` (the two-directional control — a crusher that always
aliases and one that never does both pass a one-sided test); `mix: 0` is bit-identical to input;
`bits: 16, downsampleHz: <graph rate>, antiAlias: false` is a near-identity.

⛔⛔ **CORRECTED 2026-08-29 — THIS PARAGRAPH WAS FACTUALLY WRONG ABOUT THIS CODEBASE, AND THE
TRUTH IS WORSE THAN THE CLAIM.** It originally read: *"Adding an `EffectKind` case means a project
saved with a bit-crusher will not open in an older build. That is normal here (forward
compatibility is not a contract) but say it in the CHANGELOG."*

**Measured instead — the project OPENS.** `EffectDocument.kind` is a `String`, so decoding never
throws; `effectDescriptor()` returns `EffectDescriptor?` (`ProjectDocument.swift:758`); and **both**
call sites — the track insert chain (`:296`) and the master chain (`:351`) — `guard let … else`
and append *"unknown effect kind '…' — effect dropped"*.

⚠️ **So an older build opens the file, warns, drops the insert, and the track plays uncrushed —
and RE-SAVING THERE LOSES THE EFFECT PERMANENTLY.** That is a silent data-loss path, not a
refuse-to-open. It is strictly worse than what this paragraph claimed, because a refusal is
visible and a quiet drop is not.

⭐ **Kept rather than deleted so nobody re-derives the wrong version from the same reasoning**
(the m32-e implementer transcribed this line into the CHANGELOG, then caught the contradiction
against the code and fixed it). The CHANGELOG now states the measured behaviour.

---

## 9. m32-f — Per-zone choke groups (shape)

**New field: `SamplerZone.chokeGroup: Int?`, nil = no choke** (today's behaviour byte-for-byte),
**range 0…63.**

⚠️⚠️ **`zone.group` IS NOT A CHOKE GROUP and must not be reused.**
`SamplerInstrument.swift:1171` — `if zone.group == lastFiredGroup { continue }` — is an
**exclusive-group / round-robin *selector* at note-on**, running alongside `seqLength`/`seqPosition`
and `randMin`/`randMax`: one zone per group *fires* per trigger. Choke is the opposite direction —
a new note killing an **already-sounding** one. Reusing `group` would silently break round-robin
and alternate layers.

**⭐ Reuse `monoChoke()`'s exact body — ONE choke sound in the app, not two.** I read it
(`SamplerInstrument.swift`, the `monoChoke` function) rather than minting a number: it does **not**
hard-cut and does **not** use a fixed ramp. It frees any voice already at `level <= 0`, disarms a
**sustain** loop (leaving a continuous loop looping through its release), clears `sustained`, sets
`stage = Stage.release` and anchors `releaseFrom = level`. So a choked voice decays through **its
own** release. Generalize it to `choke(group:)`; do not invent a 5 ms ramp beside it.

⚠️ **The consequence, stated rather than surprising someone:** a zone with a 2 s `release` chokes
slowly. That is already true of shipped mono mode; it is not a regression. The fix is the zone's
own `release` — and **m32-b2's generated zones already ship `release: 0.010`** (§6.7), so a chop
chokes tight by construction.

**Two traps, both in note-on ordering:**

1. ⭐ **Arm at note-on, fire inside `trigger`** — the exact `monoPendingChoke` discipline
   (`:1147`, `:1333-1338`). Firing in the selection loop would let a note that selects **no** zone
   choke a sounding one, opening a hole.
2. ⭐ **A per-note-on `UInt64` mask of choke groups already fired.** Two zones in the *same* choke
   group layering on **one** note-on must not choke each other. Mono avoids this by disarming after
   the first sounding zone; groups need per-group memory. A 64-bit mask (hence the 0…63 range) is
   allocation-free, one bit test in the trigger path, and reset once per note-on.
   Voices started by *this* note-on are never choked, because `trigger` chokes **before** it
   allocates the new voice's slot.

Gates: two zones, same choke group, alternating notes → the first voice is in release before the
second sounds (assert via rendered envelope, not via a flag); same-note-on layering does **not**
self-choke; a zone with `chokeGroup: nil` is untouched by a choking neighbour; SHA256 byte-identity
on a render of a project with **no** `chokeGroup` anywhere. Positive control: give the neighbour a
`chokeGroup` and assert the byte-identity test **fails**.

---

## 10. m32-g — Per-zone filter. DEFERRED, with the reason.

Not built in M32. The master/insert chain already covers most of the need; a per-zone filter costs
a biquad state pair × 64 voices plus a per-zone coefficient resolution path in `LoadedZone`; and
**m27 leg C already added a per-voice one-pole low-pass** (`lpZ1L`/`lpZ1R`, driven by
`expressionFilterCC` with a *shared* coefficient — 2 floats per voice and no per-voice coefficient
math). When a per-zone filter is genuinely wanted, **extending that** is the cheap, already-audited
path. Building a second filter architecture beside it would be the expensive one.

---

## 11. ⚠️ Wire hygiene — the MOVE-TOGETHER SET is SIX files, not three

The briefing names three. **It is six, and two of the missing three fail silently.** Every new
`SamplerZone` field (`reverse`, `chokeGroup`) must land in **all** of these in one change:

| # | Site | What breaks if forgotten |
|---|---|---|
| 1 | `Sources/DAWCore/Model.swift` — `SamplerZone` + its clamping `init` | won't compile |
| 2 | `Sources/DAWControl/Commands.swift` — `ParsedZoneFields` + `parseZoneFields` + **`makeZone`** | the field is unsettable on the `zones` path |
| 3 | ⚠️ `Sources/DAWControl/Commands.swift` — **`merge(_:into:)`** | **SILENT.** Sets fine via `zones`, **no-ops via `zonePatches`** (§1.3) |
| 4 | ⚠️ `Sources/DAWCore/ProjectDocument.swift` — `SamplerZoneDocument` **stored property, `CodingKeys`, and both converters** | **SILENT.** Parses, plays, and then **vanishes on save/load.** ⭐ The fields are enumerated explicitly, including an explicit `CodingKeys` list — there is no synthesis to save you |
| 5 | `mcp-server/src/server.ts` — `samplerZoneSchema` (~:1002-1281) | agents cannot send it; MCP rejects the key |
| 6 | `Sources/DAWControl/…` — `instrument.describeSampler`'s echo | an agent cannot read back what it set |

**Gate, one per new field: a full ROUND TRIP.** set via `zones` → `project.save` →
`project.open` → `instrument.describeSampler` reports it → change it via `zonePatches` →
`describeSampler` reports the change. That single test walks all six sites. Anything less will pass
with #3 or #4 missing. `Tests/DAWControlTests/SamplerZoneIdentityWireTests.swift` is the existing
home for the identity half.

**Everything additive-only.** New optional-nil fields; no renamed command; no changed default; no
behaviour change on any shipped verb. Every new capability ships **control command + MCP tool +
test.**

---

## 12. Deferrals, stated plainly so nobody re-opens them by accident

1. **Per-slice elastic time-stretch. NOT re-opened.** `AudioQuantize.swift:9` cut it deliberately:
   *"the full-source-file stretch cache model forbids N per-span renders."* ⭐ **And M32 does not
   want it**: the keymap path is already varispeed (`SamplerInstrument.swift:1371`), which is the
   *structurally correct* technique for a flip (research §2.4), not a lesser version of stretching.
2. **A process-wide sample-buffer cache** (§3.7 A). Deferred with its hazard named. Revisit when a
   measurement — not a hunch — shows the per-edit re-read hurts.
3. **Symlink-aware source-file identity** (§3.4). Costs memory only; both call sites now share one
   home, so it is a one-line change when wanted.
4. **Reversed loops** (§7).
5. **Per-zone filter** (§10).
6. **Extract-each-slice-to-its-own-file** (MPC "Crop Samples: ON"). The non-destructive
   many-zones-one-file model is strictly better here and is what m32-a makes affordable. Revisit
   only for external-tool portability.
7. **A `dryRun` on `clip.sliceToSampler`** (§6.1).
8. **`clip.chop` as a distinct verb** (§5.2) — revisit only with dogfooding evidence from m32-c.
9. **Zone→clip and clip→zone conversion** (research §2.3's "deliberate second step"). Real, out of
   scope, and cheap once both destinations exist.

---

## 13. m32-c — The sampling skill

`.claude/skills/sample-flip/SKILL.md`, front-matter shape per `.claude/skills/audio-verify/SKILL.md`
(`---` / `name` / `description` / `---`).

⭐ **The resampling loop CLOSES on the shipped wire — I verified this rather than assuming it, and
the research doc listed it as "a wiring gap until verified".** `render.bounce {path, fromBeat,
durationSeconds, excludeTrackIds}` returns `{path, …}`; `clip.addAudio {trackId, path, atBeat}`
takes an arbitrary path; `render.stems` gives per-track prints. So research §2.6's
bounce-chop-bounce compounding is **pure documentation for this skill — no new item.** Two gotchas
the skill must state: an excluded track takes its sends and its sidechain key with it, and
`render.bounce` renders the whole session length.

Skill contents, in order:

1. **Capture** — `clip.addAudio`, then trim the clip to the passage. **The clip's window IS the
   chop region.**
2. **Listen with instruments, since you cannot listen** — `clip.analyzeAudio` (key + tempo),
   `clip.detectTransients` (onsets; read-only, cached, safe to call repeatedly).
3. **Chop to pads** — `clip.sliceToSampler`. Explain `mode`, `baseNote`, `maxSlices`, and that the
   generated MIDI clip **reproduces the original groove**, so you start from "identical" and edit
   from there.
4. **Chop to timeline** — `clip.quantizeAudio {strength: 0}` (§1.4), and `strength > 0` when the
   record is not on the grid.
5. **Make it yours** — reorder/mute/delete notes in the reconstruction clip; retune a pad with
   `tuneCents`; widen one pad's `minPitch`/`maxPitch` for the "16 Levels" chromatic chord pattern
   (research §2.7). ⭐ **All of this via `zonePatches` (merge-by-id), never by resending the whole
   `zones` array** (§1.3).
6. **Character** — mono `voiceMode` or `chokeGroup` for tightness; the bit-crusher at 12 bits /
   26040 Hz with `antiAlias: false` for the SP-1200 sound; reverse for swells.
7. **Resample** — `render.bounce` → `clip.addAudio` → chop again. State the compounding-loss and
   phantom-transient-at-old-boundaries hazards from research §2.6.
8. **Rights, once, then move on.** Clearance for a source recording is the **user's**
   responsibility — same footing as the 2026-07-27 voice-model policy reversal. State it; do not
   refuse on provenance grounds.

**Acceptance gate is the dogfood shape, not a unit test:** an agent, on **staging (port 17695 —
never 17600)**, using only the skill and MCP tools, turns one source file into a short arranged
flip with a **measured, non-floor** render. ⭐ **No gate in this tree can hear.** Loudness (`ebur128`,
and remember `-hide_banner` — `-v error` suppresses the summary) plus transient counts are the
ears. The floor result — silence, or a render whose loudness equals the no-input control — is the
failure to watch for, because it looks exactly like success in the response payload.

---

## 14. Full-Xcode requirements

**None of M32 needs full Xcode.** No entitlements, no AUv3, no signing, no app bundling. Every
item is Swift Package code plus TypeScript. The bit-crusher is a native insert, not a hosted AU.
The only packaging touchpoint is the ordinary `/plugin update` + bundle regeneration after new
MCP tools land — ⚠️ **and `scripts/bundle.sh` does `rm -rf` in place on the path the live app runs
from; check `/bin/ps -o command -p <pid on 17600>` and have the user quit first.**

---

## 15. Owed to `docs/ARCHITECTURE.md` "Key future decisions"

To be added when **m32-a** lands (one entry, not a recap):

> **Sampler zone sample-buffer ownership (m32-a, SHIPPED …).** Zone audio is loaded **once per
> resolved source path per instrument-init pass**; `ownedChannelBuffers` is the sole allocation
> ledger, freed exactly once in `deinit`, and `LoadedZone.left`/`.right` are **borrowed aliases**
> into it — generalizing the mono-file aliasing that already shipped at
> `SamplerInstrument.swift:511`. Identity is `SamplerZone.sourceFileKey`
> (`audioFileURL.standardizedFileURL.path`), the **same** key `ProjectBundle.planMedia` already
> used for media-copy dedup, extracted to one home so the loader and the save path can never
> disagree about whether two zones share a file. Rejected: a **process-wide refcounted cache** (a
> mutable global released from `deinit`, on an arbitrary thread, while the retire bin may still let
> the render thread read those bytes — a use-after-free class not worth opening for the same 60×
> win); and **mmap** (delivers file bytes rather than deinterleaved Float32, and faults I/O on the
> render thread). Deferred: symlink-aware identity, and cross-instance sharing. Known cost: a zones
> change is structural, so each zone edit re-reads the file **once** (not N times).

---

## 16. Decision summary

| # | Decision |
|---|---|
| 1 | ⛔ **Fact 6 is wrong — DAWCore does not read audio files** (103 files, `Foundation` only; positive-controlled). All file access crosses a protocol seam implemented in DAWEngine. |
| 2 | **m32-a: dedup within one `init` pass**, keyed by `SamplerZone.sourceFileKey` = `standardizedFileURL.path` — extracted to one home shared with `ProjectBundle.planMedia`. `ownedChannelBuffers` stays the sole ledger; `deinit` unchanged; zones alias. |
| 3 | **m32-a's gate is two-directional**: same file → 1×, distinct files → N×. The second is an always-on positive control; a blind instrument cannot pass both. Plus ASan for double-free. |
| 4 | **Chop-to-timeline is SHIPPED** (`clip.quantizeAudio {strength: 0}`, proven from source). m32-b1 = additive `divisions` + optional `gridBeats` at strength 0 + a description fix. **No `clip.chop`, no `destination` param.** |
| 5 | **m32-b2 `clip.sliceToSampler`: ONE command, clip-centric, `mode` selects the boundary source.** A `mode` picking a boundary source is a parameter; a `destination` picking an output domain is a different verb. |
| 6 | **ONE new engine seam** returns `sampleRate` + `frameCount` + snapped `boundaryFrames` together, making the 8.8 % unit trap **unrepresentable** rather than merely forbidden. Default impl throws `engineUnavailable`, so no existing test double breaks. |
| 7 | ⭐ **Reconstruction velocity is 127, not `strength`** — `amp = velocity/127 × gain` means strength-mapped velocity double-attenuates the slice's own recorded level. Opt in via `velocityFromStrength`. **Contradicts the briefing on measured arithmetic.** |
| 8 | **`clip.sliceToSampler` requires `isStretchIdentity` and `pitchShiftSemitones == 0`**; it does **not** require `requireNotCompMember` (the source clip is read-only). |
| 9 | **Boundary snap = minimise the per-channel PEAK magnitude** `max_c abs(x_c[k])` (a true zero crossing on mono), snapped ONCE and shared by both adjacent spans, window clamped to `minSlice/2`, residual reported. |
| 10 | **m32-d reverse = per-voice direction scalar** (`base + dir × local`, an IEEE identity forward), gated by a **sample-exact mirror** test plus forward byte-identity **including a looping and a bent voice**. Reversed zones ignore loops, and say so. |
| 11 | **m32-f `chokeGroup: Int?` (0…63), reusing `monoChoke()`'s exact body** — one choke sound, no invented ramp — armed at note-on, fired in `trigger`, with a per-note-on `UInt64` fired-mask so same-group layers do not self-choke. |
| 12 | **m32-e is an insert effect** with `antiAlias: false` / `dither: false` **defaults** — the aliasing is the character. |
| 13 | **The move-together set is SIX sites, not three.** `merge()` and `SamplerZoneDocument` are the two that fail **silently**. Gate = one full save/load/patch round trip per field. |
| 14 | **The resample loop closes on the shipped wire** (`render.bounce` → `clip.addAudio`) — verified, so m32-c needs no extra item. |
| 15 | **Serialize m32-a → m32-d → m32-f** (same four files, hot render loop). m32-b1 and m32-e are genuinely parallel. |
| 16 | **Nothing in M32 needs full Xcode.** |
