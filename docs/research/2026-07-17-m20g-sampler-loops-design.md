# Design: m20-g — Sampler sustain loops (report-only → real playback)

**Date**: 2026-07-17 · **Author**: daw-architect (design-only flight) ·
**Implements**: `docs/ROADMAP.md:317` (m20-g) — first slice of the m19-c/d v2
candidates (`docs/ROADMAP.md:296-297`).
**Implementer**: audio-dsp-engineer, next flight. This doc makes every
algorithmic choice; the implementer should make none.
**Xcode requirement**: NONE — pure SwiftPM (`swift build` /
`./scripts/test.sh`). No entitlements, no AUv3, no signing.

Everything cited below was read from the working tree on 2026-07-17; line
numbers refer to that state. §10 lists what could NOT be verified.

---

## 1. Decision summary

**D1 — Loop semantics.** Two real loop modes land on the engine:
`loop_sustain` (loop while the note is held or pedal-held; on true release
start, playback continues linearly PAST the loop end into the natural tail)
and `loop_continuous` (loop through the release; the voice frees when the
release envelope reaches exact zero). `no_loop` and `one_shot` keep today's
meaning bit-for-bit (`one_shot` already maps to the per-zone one-shot at
`SampleLibraryMapper.swift:258`; it is not a loop).

**D2 — Crossfade policy (the real decision).** Render-time **equal-gain
(linear) crossfade** across the loop seam, over the final
`X = min(512, loopStart, loopLength)` source frames of each loop pass,
blending in the pre-loop-start material `[loopStart − X, loopStart)` so the
wrap is continuous. `X` and `1/X` are resolved per zone at load (init) time;
per-voice crossfade state is **zero** — the blend gain is pure arithmetic on
the existing fractional playhead. Rationale and rejected alternatives in §3.1.

**D3 — `smpl` fallback is the SFZ-specified default, not an invention.**
sfzformat.com defines `loop_mode`'s default as "no_loop for samples without a
loop defined, loop_continuous for samples with defined loop(s)", and
`loop_start`/`loop_end` default to "the start/end point of the first loop
defined in the file". So: when the text format authored no loop opcodes, a
forward loop in the WAV's RIFF `smpl` chunk enables `loop_continuous` with the
chunk's points; authored opcodes win **per field**. An explicit `no_loop` (or
`.dspreset` `loopEnabled="false"`) suppresses the fallback entirely. §2.3.

**D4 — `smpl` `dwEnd` is INCLUSIVE (frames, little-endian).** `dwStart`/`dwEnd`
are sample-frame indices (universal tool practice; recordingblogs.com: "The
end point of the loop in samples. The end sample is also played."), so the
IR carries them in the SAME inclusive convention as SFZ `loop_end`
("This is inclusive - the sample specified is played as part of the loop",
sfzformat.com) and the ONE mapper `+1` law converts to the model's exclusive
convention — exactly the m19-c `end → endFrame + 1` law
(`SampleLibraryMapper.swift:260`). §4.3.

**D5 — One command surface, additive everywhere.** IR +2 fields, `SamplerZone`
+3 additive-optional fields (+1 new small enum type), `SamplerZoneDocument`
+3 omit-when-nil keys, report +1 additive field (`loopedZones`), wire
`instrument.set` zone schema +3 optional fields with the emit-when-set idiom.
No new wire command, no new MCP tool — the flip rides
`instrument.importSampleLibrary` / `instrument_import_sample_library`
unchanged (pins stay 127/130, same as m19-d).

### 1.1 Strongest alternatives considered (whole-feature level)

1. **Bake the crossfade into the loaded buffer at init** (zero render cost).
   Loses because `loop_sustain` must play THROUGH the loop end after
   note-off: a baked tail no longer matches the original file at the
   `loopEnd` boundary, guaranteeing a discontinuity exactly on the one path
   that must be clean. Detailed in §3.1.
2. **Import-time zero-crossing snap of loop points** (no crossfade at all).
   Loses because it mutates authored points (hand-tuned seamless libraries
   get audibly shifted loops), stereo channels rarely zero-cross on the same
   frame, and equal-amplitude-mismatch seams still click. §3.1.

### 1.2 Settled-decision line for `docs/ARCHITECTURE.md`

The implementing flight adds this under "Key future decisions"
(`docs/ARCHITECTURE.md:149`), the "SETTLED" idiom of the sequencer-clock entry:

> **Sampler sustain loops: SETTLED (m20-g, 2026-07-17)** — `loop_sustain` /
> `loop_continuous` play for real; seam policy is a render-time equal-gain
> crossfade over min(512, loopStart, loopLength) source frames using
> pre-loop-start material (zero per-voice state, no allocation); loop points
> follow the SFZ default law with WAV `smpl`-chunk fallback (dwEnd inclusive,
> the one shared +1 conversion at the mapper); model/document fields are
> additive-optional (nil = no loop = pre-m20-g byte-identical playback).

---

## 2. Semantics

### 2.1 Taxonomy → engine behavior

| Authored | Engine behavior (v1) |
|---|---|
| `loop_mode=no_loop` (SFZ) / `loopEnabled="false"` (.dspreset) | No loop — explicit. Suppresses the `smpl` fallback. Playback identical to today. |
| `loop_mode=one_shot` | UNCHANGED: per-zone one-shot (`SamplerZone.oneShot = true`, `SampleLibraryMapper.swift:258`); plays to the zone end ignoring noteOff. Never a loop. |
| `loop_mode=loop_sustain` | Voice loops `[loopStart, loopEndExcl)` while the note is held — including while CC64 defers the noteOff (sfzformat: "the player will play the loop while the note is held, by keeping it depressed or by using the sustain pedal (CC64). During the release phase, there's no looping."). At true release start the voice DISARMS its loop and plays linearly on from its current position, through `loopEnd`, into the tail, freeing at the zone `endFrame` or at envelope zero, whichever first. |
| `loop_mode=loop_continuous` / `loopEnabled="true"` | Voice loops forever ("This includes looping during the release phase", sfzformat); it frees ONLY via the release envelope reaching exact zero (`SamplerInstrument.swift:542-546`). It never reaches `endFrame`. |
| unrecognized `loop_mode` value | NEW honesty fix: tallied into `ignoredOpcodes["loop_mode"]` (today the mapper's `default: break` at `SampleLibraryMapper.swift:198-203` drops it silently). Zone imports unlooped. |
| absent everywhere (no opcodes, no `smpl` loop) | No loop — today's behavior, byte-identical. |

**One-shot × loop interplay (engine law).** A voice whose zone carries a loop
mode is NEVER one-shot: at trigger, `voice.oneShotOverride` is forced to `0`
(explicit non-one-shot), overriding both the zone override and the live
global (`SamplerInstrument.swift:635-636` resolution). Otherwise a
`loop_continuous` voice under global one-shot would ignore noteOff and drone
until stolen. The mapper can never emit the combination (SFZ `loop_mode` is a
single value; `.dspreset` has no one-shot in the imported subset,
`docs/SFZ-SUPPORT.md:44`) — only hand-built wire zones can attempt it, and
the documented rule is "loopMode wins over oneShot".

**Pedal (CC64).** noteOff under a down pedal marks `sustained = true` and does
NOT disarm a sustain loop (the sfzformat quote above). The loop disarms at the
two places a real release starts: the pedal-up sweep
(`SamplerInstrument.swift:656-668`) and the plain noteOff release
(`SamplerInstrument.swift:643-646`).

### 2.2 Absent / invalid bounds — the §2.3 policy idiom (mapper, never silent)

All checks below run in `SampleLibraryMapper.map` (the ONE policy home,
`docs/research/2026-07-16-spike-sfz-dspreset-design.md` §2.3). "Invalid"
NEVER skips the region — the zone imports UNLOOPED with a reason-coded
degradation sentence (loops were never wrong-sound; silence about them would
be the lie):

| Condition (inclusive-point domain, after §2.3 precedence resolution) | Mapper action |
|---|---|
| mode ∈ {continuous, sustain}, `loopEndIncl < loopStart` (a 1-frame loop `==` is LEGAL) | drop loop fields; count into the invalid-bounds degradation |
| `loopStart < 0` or `loopEndIncl < 0` | same (note: `loop_end` has NO `-1` disable convention — that is `end=`'s, `SampleLibraryMapper.swift:158-161`) |
| `loopStart > region.endFrame` when `end=` was authored (≥ 0) | same — the loop can never engage inside the trimmed span |
| loop extends past the REAL file end | mapper cannot know (existence-only, NO audio decode at this layer — `SampleLibraryMapper.swift:96`); the ENGINE clamps at load with a `zoneLoadNotes` line, the existing start/end idiom (`SamplerInstrument.swift:314-321`). §3.4 |
| authored loop POINTS but mode nil and no `smpl` loop | no loop (the SFZ default law); counted into a points-without-mode degradation |

Exact degradation copy (the loadNotes idiom, replacing
`SampleLibraryMapper.swift:269-272`):

- `"\(n) zone\(n == 1 ? "" : "s") author invalid loop bounds (loop end before loop start, or outside the playable span) — imported without looping"`
- `"\(n) zone\(n == 1 ? "" : "s") author loop points without a loop mode and their samples embed no smpl loop — imported without looping (the SFZ default)"`

### 2.3 Precedence (per-field, the sfzformat default law)

Resolution order for each region, run only after the sample-file existence
check passes:

1. Authored mode: SFZ `loop_mode`/`loopmode`; `.dspreset` `loopEnabled`
   (`"true"/"1"` → `loop_continuous` — the existing m19-d mapping at
   `DSPresetParser.swift:259-268`; **change**: `"false"/"0"` now records
   `loopMode = "no_loop"` instead of recording nothing, so the explicit
   author intent suppresses the fallback in the mapper).
2. Authored points: SFZ `loop_start`/`loop_end` (+ v1 spellings
   `loopstart`/`loopend` — same tolerance precedent as the `loopmode` alias,
   `SFZParser.swift:321`); `.dspreset` `loopStart`/`loopEnd` (frames).
3. `smpl` fallback — consulted ONLY when `mode == nil`, or when
   mode ∈ {continuous, sustain} with a missing point; ONLY for
   `.wav`/`.wave` files (case-insensitive); first `dwType == 0` (forward)
   loop; per-file result cached in a local dictionary for the duration of one
   `map()` call (big SFZs reference one WAV from hundreds of regions):
   - `mode == nil` and `smpl` has a forward loop → `mode = loop_continuous`.
   - `loopStart == nil` → `dwStart`; `loopEndIncl == nil` → `dwEnd`.
4. Still-missing points with a loop mode → `nil` reaches the model, meaning
   "engine resolves": `loopStart nil → 0`, `loopEnd nil → the zone's resolved
   endFrame` (the sfz defaults: 0 / sample end, clamped by any `end=` trim).
5. `mode == "no_loop"` (explicit, either format): no loop, no fallback, no
   note — authored intent honored exactly (sfzformat: `loop_end` "has no
   effect when loop_mode is no_loop").

Non-goals of the fallback (documented in SFZ-SUPPORT): `dwType` 1/2
(ping-pong/backward) loops are ignored; only the FIRST forward loop is used;
`dwPlayCount` is ignored (all loops treated as infinite); `dwFraction`
ignored; AIFF `INST`/`MARK` metadata out of scope. A malformed or absent
`smpl` chunk yields nil silently — the absence of a bonus is not a
degradation.

---

## 3. The RT loop-crossing algorithm (DAWEngine)

Verified baseline: each voice reads an immutable preloaded deinterleaved
Float32 buffer (loaded in init via `AVAudioFile` →
`AVAudioPCMBuffer` → owned `UnsafeMutableBufferPointer<Float>` blocks,
`SamplerInstrument.swift:258-354`), advancing a fractional playhead with
linear interpolation and freeing itself at the zone's exclusive `endFrame`
(`SamplerInstrument.swift:549-572`). The render path allocates nothing, takes
no locks, touches no ObjC (`SamplerInstrument.swift:67-71`); libm on the
render thread has precedent (`exp2` in the bend path,
`SamplerInstrument.swift:676`).

### 3.1 Crossfade decision (D2) — why equal-gain render-time, and what loses

**Decision**: equal-gain (linear) crossfade computed at render time over the
final `X` frames of every loop pass, where `X = min(512, loopStart,
loopLength)` source frames, resolved once per zone in init. The incoming
signal is the pre-loop-start material `[loopStart − X, loopStart)`, time-aligned
so it lands exactly on `loopStart` at the wrap. `X = 0` (i.e. `loopStart == 0`)
degrades to a raw wrap — no pre-start material exists; a loop starting at
frame 0 is almost always an already-seamless full-file loop.

- **Why equal-gain, not equal-power**: a loop seam blends two windows of the
  SAME sustained tone — highly correlated material. Equal-power
  (`sin`/`cos`) sums correlated signals up to +3 dB at the midpoint;
  equal-gain keeps constant amplitude for correlated material (the standard
  loop-crossfade recommendation; DecentSampler itself exposes linear vs
  equal-power as a choice for exactly this reason). It also needs no
  transcendentals and no gain table on the render thread.
- **Why 512 frames**: ≈ 11.6 ms at 44.1 kHz — above the click-perception
  floor, below pitch-smearing territory; clamped by `loopStart` and by the
  loop length so degenerate content can never read out of bounds.
- **Why render-time, not baked at load** (alternative A): baking the blend
  into the buffer tail is free at render time, but poisons `loop_sustain`'s
  release pass-through: the frames `[loopEnd − X, loopEnd)` would no longer
  match the original file, so playing THROUGH the loop end after note-off
  jumps from blended material back to the original tail — a guaranteed
  discontinuity on the one path that must be clean. It also destroys the
  ability to disarm loops per voice against a shared zone buffer.
- **Why not zero-crossing snap at import** (alternative B): mutates authored
  loop points (a library with hand-tuned seamless loops gets it wrong points
  moved), cannot satisfy both stereo channels simultaneously, and does not
  fix amplitude-envelope mismatch at the seam. Rejected.
- **Known accepted imperfection**: a `loop_sustain` voice that disarms while
  INSIDE the crossfade window steps from blended back to raw data on the
  next frame — worst case one small discontinuity at note-off, masked by the
  release ramp. Carrying crossfade state through disarm would need per-voice
  history; rejected for v1 and documented here.

### 3.2 New preallocated state (all resolved in init — never the render thread)

`LoadedZone` (POD stays POD, `SamplerInstrument.swift:89-121`) — 6 new fields:

```swift
var loopMode: UInt8       // 0 = none, 1 = sustain, 2 = continuous
var loopStart: Int        // resolved into 0..<frames (valid loops only)
var loopEndExcl: Int      // resolved into (loopStart+1)...endFrame
var loopLen: Double       // Double(loopEndExcl - loopStart), precomputed
var loopXfade: Int        // min(512, loopStart, loopEndExcl - loopStart); 0 = raw wrap
var invLoopXfade: Float   // loopXfade > 0 ? 1/Float(loopXfade) : 0
```

`Voice` (`SamplerInstrument.swift:163-188`) — 2 new fields, both copied at
trigger like `oneShotOverride` (`SamplerInstrument.swift:713`):

```swift
var looping = false       // armed at trigger when zone.loopMode != 0;
                          // disarmed at release start for sustain mode
var loopMode: UInt8 = 0   // zone.loopMode copy — the disarm rule reads it
                          // without a zones deref in the noteOff path
```

Both live in the existing fixed heap blocks (`zones` / 64-slot `voices`,
`SamplerInstrument.swift:190-200`) — no new allocation anywhere near render.

### 3.3 Init-time loop resolution (extends `SamplerInstrument.swift:309-321`)

Immediately after the existing `startFrame`/`endFrame` clamp (which stays
byte-identical):

```swift
// m20-g: loop resolution — model optionals collapse ONCE, defensively
// re-clamped against the REAL file length (raw Codable decode bypasses the
// model init, and these bound POINTER reads — the startFrame/endFrame rule).
var loopMode: UInt8 = 0
var loopStart = 0
var loopEndExcl = endFrame
if let mode = zone.loopMode {                       // .sustain / .continuous
    loopStart = min(max(0, zone.loopStart ?? 0), frames - 1)
    loopEndExcl = min(max(loopStart + 1, zone.loopEnd ?? endFrame), endFrame)
    if loopEndExcl <= loopStart {                   // loop outside the span
        zoneLoadNotes.append(
            "zone loop disabled (loop \(zone.loopStart ?? 0)..\(zone.loopEnd ?? endFrame) "
            + "outside the playable span \(startFrame)..\(endFrame) of "
            + "\(zone.audioFileURL.lastPathComponent))")
    } else {
        loopMode = mode == .sustain ? 1 : 2
        if (zone.loopStart.map { $0 != loopStart } == true)
            || (zone.loopEnd.map { $0 != loopEndExcl } == true) {
            zoneLoadNotes.append(
                "zone loop clamped to \(loopStart)..\(loopEndExcl) "
                + "(\(zone.audioFileURL.lastPathComponent) has \(frames) frames)")
        }
    }
}
let loopXfade = loopMode == 0 ? 0
    : min(512, loopStart, loopEndExcl - loopStart)
```

then populate the six `LoadedZone` fields (`loopLen = Double(loopEndExcl -
loopStart)`, `invLoopXfade = loopXfade > 0 ? 1 / Float(loopXfade) : 0`).

Note `loopEndExcl` is clamped to the resolved `endFrame` (not `frames`): an
`end=` trim bounds the loop too, and `loopEndExcl ≤ endFrame` is the
invariant that lets a looping voice never trip the `idx >= zone.endFrame`
free check (`SamplerInstrument.swift:560-563`).

### 3.4 Trigger / noteOff / pedal deltas (`apply(event:)` and `trigger`)

- `trigger(zoneIndex:event:)` (`SamplerInstrument.swift:690-748`): after
  `voice.oneShotOverride = zone.oneShotOverride`, add:

  ```swift
  voice.loopMode = zone.loopMode
  voice.looping = zone.loopMode != 0
  if voice.looping { voice.oneShotOverride = 0 }   // §2.1: loop wins over one-shot
  ```

- noteOff release branch (`SamplerInstrument.swift:643-646`) AND the pedal-up
  sweep (`SamplerInstrument.swift:662-666`) — at BOTH places where
  `stage = Stage.release` is set, add:

  ```swift
  if voices[index].loopMode == 1 { voices[index].looping = false }  // sustain: play through
  ```

  The pedal-deferral branch (`sustained = true`,
  `SamplerInstrument.swift:637-640`) deliberately does NOT disarm — §2.1.
  The `level <= 0` instant-free branches need nothing (voice wiped).
- `reset()` (`SamplerInstrument.swift:501-507`): nothing to add — the voice
  wipe zeroes the new fields with the `Voice()` default.

### 3.5 The per-frame read path (replaces step 2 of `renderFrame`, `SamplerInstrument.swift:549-572`)

The existing path is kept **verbatim** behind `!voices[index].looping` — that
branch is the byte-identity guarantee for every non-looping voice (old
projects, no-loop zones, and sustain voices after disarm). The looping branch:

```swift
let zone = zones[Int(voices[index].zoneIndex)]
if voices[index].looping {
    var position = voices[index].position
    // 2a. Sample-accurate wrap BEFORE the read, so idx < loopEndExcl always.
    //     One truncatingRemainder handles ANY overshoot (a tiny loop under a
    //     huge pitch-up increment can overshoot by multiples of loopLen) —
    //     constant-time libm, no allocation (render-thread precedent: exp2
    //     in the bend path).
    if position >= Double(zone.loopEndExcl) {
        position = Double(zone.loopStart)
            + (position - Double(zone.loopStart))
                .truncatingRemainder(dividingBy: zone.loopLen)
        voices[index].position = position
    }
    let idx = Int(position)
    let frac = Float(position - Double(idx))
    // 2b. Seam interpolation: the frame AFTER loopEndExcl−1 is loopStart —
    //     never 0, never left[loopEndExcl].
    let next = idx + 1 >= zone.loopEndExcl ? zone.loopStart : idx + 1
    let l0 = zone.left[idx], r0 = zone.right[idx]
    var sL = l0 + (zone.left[next] - l0) * frac
    var sR = r0 + (zone.right[next] - r0) * frac
    // 2c. Equal-gain seam crossfade over the final loopXfade frames of the
    //     pass: blend toward the pre-loop-start material, time-aligned to
    //     land exactly on loopStart at the wrap.
    if zone.loopXfade > 0 {
        let into = position - Double(zone.loopEndExcl - zone.loopXfade)
        if into >= 0 {
            let g = Float(into) * zone.invLoopXfade      // 0 → 1 across the window
            let inPos = position - zone.loopLen          // ∈ [loopStart−X, loopStart)
            let inIdx = Int(inPos)                       // ≥ 0 because X ≤ loopStart
            let inFrac = Float(inPos - Double(inIdx))
            let inNext = inIdx + 1                       // ≤ loopStart ≤ frames−1: in bounds
            let i0 = zone.left[inIdx], j0 = zone.right[inIdx]
            let iL = i0 + (zone.left[inNext] - i0) * inFrac
            let iR = j0 + (zone.right[inNext] - j0) * inFrac
            sL += (iL - sL) * g                          // (1−g)·current + g·incoming
            sR += (iR - sR) * g
        }
    }
    left += sL * (voices[index].level * voices[index].gainL)
    right += sR * (voices[index].level * voices[index].gainR)
    voices[index].position = position + voices[index].increment
} else {
    // EXISTING lines 558-572 UNCHANGED — including the endFrame self-free,
    // the interpolate-toward-0 tail, and the legacy multiply order.
}
```

Bounds proof for the crossfade reads: the window requires
`position ≥ loopEndExcl − X`, so `inPos = position − loopLen ≥ loopStart − X
≥ 0` (init guarantees `X ≤ loopStart`), and `inPos < loopStart` ⇒
`inNext ≤ loopStart ≤ frames − 1`. Immediately after a wrap,
`into < 0` (position near `loopStart`, window is at the END of the loop), so
no crossfade fires — the blend ran on the way IN and handed off continuously.

### 3.6 RT-safety and CPU statement

- **No allocation, no locks, no ObjC**: all new state is POD inside the
  existing preallocated `zones`/`voices` blocks; the algorithm adds float
  arithmetic, integer compares, and (on wrap frames only) one
  `truncatingRemainder` — a constant-time libm call with existing
  render-thread precedent (`exp2`, `SamplerInstrument.swift:676`). No new
  atomics, no snapshot changes (`ScalarParams` untouched — loop config is
  structural zone data, and zone changes already rebuild the instrument,
  `SamplerInstrument.swift:59-65`).
- **Per-voice per-frame cost**: non-window loop frames add 2 compares over
  the legacy path; window frames add 4 loads, ~10 flops. Worst case — all 64
  voices looping inside their windows — ≈ 900 extra ops/frame ≈ 43 M ops/s
  at 48 kHz, the same order as the existing interpolation + envelope work,
  and the window occupies at most `X/loopLen` of each pass (512/44100 ≈ 1.2 %
  for a 1 s loop; 100 % only for pathological ≤ 512-frame loops, which are
  64 voices × trivial arithmetic regardless).
- **NaN guard**: the existing once-per-quantum guard
  (`SamplerInstrument.swift:476-480`) already covers `position`; a
  degenerate 1-frame loop renders a constant sample (authored data), never
  NaN — `loopLen ≥ 1` by the init clamp.
- **Voice stealing**: unchanged; the crossfade is stateless from `position`,
  so a stolen looping voice leaves no orphaned state.

---

## 4. IR + parser changes (DAWCore)

### 4.1 `SampleLibraryIR.Region` — 2 new fields (`SampleLibraryIR.swift`)

```swift
/// Loop start point in source-file frames (SFZ `loop_start`/`loopstart`;
/// `.dspreset` `loopStart`; `smpl` dwStart). nil = not authored — resolves
/// to 0 / the smpl point per the §2.3 precedence law.
public var loopStartFrame: Int?
/// INCLUSIVE last loop frame (SFZ `loop_end` semantics — "the sample
/// specified is played as part of the loop"; `smpl` dwEnd, same convention).
/// The mapper does the +1 to the model's exclusive `loopEnd` — the ONE
/// shared inclusive→exclusive law (`end` → endFrame + 1).
public var loopEndFrame: Int?
```

Plus: rewrite the `loopMode` field doc (`SampleLibraryIR.swift:89-92`) — it
currently says "loop points are never stored"; it becomes "parsed so the
mapper can honor one_shot AND build real loops (m20-g)". Add both fields to
the memberwise init (defaults nil).

### 4.2 `SFZParser` (`SFZParser.swift:267-348`)

Today `loop_start`/`loop_end` fall through the not-consumed sweep into
`region.ignored` (`SFZParser.swift:337-345`) and surface as `ignoredOpcodes`.
Changes:

```swift
take("loop_start", SFZSyntax.integer, into: \.loopStartFrame)
take("loopstart",  SFZSyntax.integer, into: \.loopStartFrame)   // v1 spelling
take("loop_end",   SFZSyntax.integer, into: \.loopEndFrame)
take("loopend",    SFZSyntax.integer, into: \.loopEndFrame)
```

with the underscore spelling taking precedence when both appear (call the
alias `take` FIRST so the canonical one overwrites — mirror the existing
`merged["loop_mode"] ?? merged["loopmode"]` order at `SFZParser.swift:322`).
Add all four names to the `consumed` set (`SFZParser.swift:329-336`). An
unparseable value degrades to `ignored` — `take`'s existing contract.

### 4.3 `WAVSampleLoops` — NEW file `Sources/DAWCore/SampleLibraries/WAVSampleLoops.swift`

Pure Foundation (`FileHandle` + `Data`) byte walk — no AVFoundation, no
CoreAudio, so DAWCore stays headless/engine-free (the mapper already does
Foundation file I/O: existence + size at `SampleLibraryMapper.swift:180-195`;
this is metadata sniffing, NOT audio decode, so the §5.1 "no decode at this
layer" law holds).

```swift
/// RIFF `smpl`-chunk reader (m20-g §4.3): the loop-point fallback for WAV
/// samples whose library text authored no loop opcodes. Returns the FIRST
/// forward loop, or nil for anything else — this parser NEVER throws and
/// NEVER reads sample data (bounded header reads only; a 4 GB WAV costs a
/// few seeks).
enum WAVSampleLoops {
    struct Loop: Equatable, Sendable {
        var startFrame: Int          // dwStart, sample frames
        var endFrameInclusive: Int   // dwEnd, sample frames, INCLUSIVE (D4)
    }
    static func firstForwardLoop(in url: URL) -> Loop?
}
```

Byte-level walk (ALL integers little-endian — RIFF's defining convention):

1. Read 12 bytes: bytes 0–3 must be ASCII `RIFF`, 8–11 must be `WAVE`;
   else nil. (Bytes 4–7, the RIFF size, are read but not trusted.)
2. Chunk loop from offset 12: read an 8-byte header — 4 ASCII id bytes +
   UInt32-LE `ckSize`. If id ≠ `smpl`, seek forward `ckSize + (ckSize & 1)`
   (RIFF word alignment: odd-sized chunks carry one pad byte) and continue.
   Hard bounds: stop at file end, on any short read, or after 10 000 chunks
   (corrupt-file guard). `smpl` commonly sits AFTER `data`, so the walk must
   not stop at the first non-match — but it only ever seeks, never reads
   chunk bodies other than `smpl`'s.
3. On `smpl` (need `ckSize ≥ 36`): read the 36-byte header. Fixed layout,
   offsets within the chunk data: dwManufacturer 0, dwProduct 4,
   dwSamplePeriod 8, dwMIDIUnityNote 12, dwMIDIPitchFraction 16,
   dwSMPTEFormat 20, dwSMPTEOffset 24, **cSampleLoops 28**, cbSamplerData 32.
   Loop records start at chunk-data offset 36, 24 bytes each:
   dwIdentifier 0, **dwType 4**, **dwStart 8**, **dwEnd 12**, dwFraction 16,
   dwPlayCount 20.
4. Iterate `n = min(cSampleLoops, (ckSize − 36) / 24)` records (the min is
   the lying-header guard). Return the first record with `dwType == 0`
   (forward) and `dwEnd ≥ dwStart`, both converted through
   `Int(exactly: UInt32)` (they always fit Int on 64-bit macOS). Skip
   ping-pong (1) / backward (2) / vendor types and inverted records; none
   qualifying → nil, and the chunk walk ENDS (one `smpl` chunk is the spec
   shape; a second is not searched).
5. Any structural surprise anywhere → nil. No throws, no logging.

`dwFraction` and `dwPlayCount` are read past, deliberately unused (§2.3
non-goals). MIDI unity note is NOT consumed — root pitch stays the text
format's business (v1 boundary; note in SFZ-SUPPORT).

### 4.4 `DSPresetParser` (`DSPresetParser.swift:256-280`)

- Consume `loopstart`/`loopend` keys (attribute map is lowercased,
  `DSPresetParser.swift:153-160`):
  `take("loopstart", SFZSyntax.integer, into: \.loopStartFrame)` /
  `take("loopend", SFZSyntax.integer, into: \.loopEndFrame)`; add both to the
  `consumed` set (`DSPresetParser.swift:271-280`).
- `loopEnabled` `"false"/"0"` (`DSPresetParser.swift:263-264`): record
  `region.loopMode = "no_loop"` instead of `break` — the explicit intent
  must suppress the `smpl` fallback (§2.3). Same mapped behavior as today
  otherwise (the mapper's `no_loop` arm imports unlooped).
- `loopCrossfade` / `loopCrossfadeMode` stay UNCONSUMED → `ignored` tally
  (the engine's fixed §3.1 policy applies; per-zone crossfade length is a
  filed follow-up, §9). Update the header doc comment
  (`DSPresetParser.swift:55-56`) — it currently promises the report-only
  path.

---

## 5. Mapper flip + report honesty (`SampleLibraryMapper.swift`)

### 5.1 The flip (replaces `SampleLibraryMapper.swift:197-203` and 269-272)

Insert the §2.3 precedence/validity resolution (pseudocode; runs after the
existence check and byte accounting, before the zone append):

```swift
// — m20-g loops: precedence (opcodes > smpl > defaults), validity, honesty —
var mode = region.loopMode          // parser-normalized lowercase string
var lsIncl = region.loopStartFrame
var leIncl = region.loopEndFrame
let isLoopMode = mode == "loop_continuous" || mode == "loop_sustain"
if mode == nil || (isLoopMode && (lsIncl == nil || leIncl == nil)),
   ["wav", "wave"].contains(resolved.url.pathExtension.lowercased()) {
    let smpl = smplCache.lookup(resolved.url)       // local [String: Loop?] cache
    if let smpl {
        if mode == nil { mode = "loop_continuous" } // the sfzformat default law
        if lsIncl == nil { lsIncl = smpl.startFrame }
        if leIncl == nil { leIncl = smpl.endFrameInclusive }
    }
}
var loopMode: SamplerLoopMode? = nil
var loopStartOut: Int? = nil
var loopEndOut: Int? = nil
switch mode {
case "loop_continuous", "loop_sustain":
    let invalid = (lsIncl.map { $0 < 0 } ?? false)
        || (leIncl.map { $0 < 0 } ?? false)
        || (lsIncl != nil && leIncl != nil && leIncl! < lsIncl!)
        || (lsIncl != nil && region.endFrame != nil && region.endFrame! >= 0
            && lsIncl! > region.endFrame!)
    if invalid {
        invalidLoopCount += 1                       // → degradation sentence §2.2
    } else {
        loopMode = mode == "loop_sustain" ? .sustain : .continuous
        loopStartOut = lsIncl
        loopEndOut = leIncl.map { $0 + 1 }          // THE +1 LAW (== end→endFrame+1)
        loopedZoneCount += 1                        // now counts REAL loops
    }
case "one_shot", "no_loop", nil:
    if mode == nil, lsIncl != nil || leIncl != nil {
        pointsWithoutModeCount += 1                 // → degradation sentence §2.2
    }
default:
    ignoredTally["loop_mode", default: 0] += 1      // unrecognized value — NEW honesty
}
```

then pass `loopMode: loopMode, loopStart: loopStartOut, loopEnd: loopEndOut`
into the `SamplerZone` init (`SampleLibraryMapper.swift:242-265`). The
`oneShot: region.loopMode == "one_shot"` mapping (`:258`) is UNTOUCHED.
Delete the "imported without looping" sentence block
(`SampleLibraryMapper.swift:269-272`); add the two §2.2 sentences.

### 5.2 Report changes — additive ONLY (the wire/MCP report is a stable surface)

`SampleLibraryImportReport` (`SampleLibraryMapper.swift:50-89`) gains ONE
field, defaulted in the init like every other:

```swift
/// Imported zones that will actually loop (m20-g): sustain + continuous,
/// including smpl-fallback loops. 0 for loop-free libraries.
public var loopedZones: Int
```

Exact observable flips for the §8.3 fixture library (this is the GATE's
report assertion):

| Surface | BEFORE (m19-d behavior) | AFTER (m20-g) |
|---|---|---|
| `degradations` | `"2 zones have sustain loops — imported without looping; sustained notes end at the sample's natural end (loops are a planned follow-up)"` | sentence GONE (present only via the two new §2.2 degradation cases) |
| `ignoredOpcodes` | `{"loop_start": 1, "loop_end": 1}` (SFZ; `.dspreset`: `loopStart`/`loopEnd` entries) | those keys GONE (consumed); `loopCrossfade`/`loopCrossfadeMode` entries remain |
| `loopedZones` | (field absent) | `3` |
| `zonesImported` / `skippedRegions` | unchanged — **loops never caused skips**; the roadmap's "skipped-to-imported" shorthand actually means degradations/ignoredOpcodes → loopedZones. State this in the PR notes. | unchanged |

Wire (`instrument.importSampleLibrary`) and MCP emit the report verbatim, so
`loopedZones` appears automatically on both. **MCP copy note (edit belongs to
the implementing flight, copy law applies)**: the `dryRun` teaching
description at `mcp-server/src/server.ts:1515-1543` should stop implying loops
degrade and add one sentence, e.g. "Sustain loops play for real: SFZ
loop_mode/loop_start/loop_end, .dspreset loopEnabled/loopStart/loopEnd, and
loops embedded in a WAV's smpl chunk when the text authored none — the
report's `loopedZones` counts them." — still never a product-compatibility
claim.

### 5.3 `docs/SFZ-SUPPORT.md` edits (implementing flight)

- Move the loops row OUT of "Reported, not played" (`docs/SFZ-SUPPORT.md:50`)
  into the Supported table: SFZ `loop_mode` (`loop_continuous`/`loop_sustain`),
  `loop_start`/`loop_end` (+`loopstart`/`loopend`) | `.dspreset`
  `loopEnabled`, `loopStart`/`loopEnd` — plus a WAV `smpl` fallback row and
  the §2.3 boundary sentences (forward/first loop only, play counts ignored,
  crossfade policy one-liner, AIFF out of scope).
- Remove `loopStart`/`loopEnd` from the `.dspreset` ignored list
  (`docs/SFZ-SUPPORT.md:70-72`); keep `loopCrossfade` (+ `loopCrossfadeMode`)
  there.

---

## 6. Model, persistence, wire

### 6.1 `SamplerZone` — 3 additive-optional fields + 1 enum (`Model.swift:1329-1492`)

```swift
/// Loop behavior (m20-g). nil = no loop — the pre-m20-g playback law
/// byte-for-byte. `.sustain` loops while the note (or CC64) holds and plays
/// through past the loop end on release; `.continuous` loops through the
/// release. A looping zone's voices are never one-shot (loopMode wins over
/// `oneShot` — see SamplerInstrument).
public enum SamplerLoopMode: String, Codable, Sendable { case sustain, continuous }
public var loopMode: SamplerLoopMode?
/// Loop span in SOURCE-FILE frames, same conventions as startFrame/endFrame:
/// loopStart inclusive (nil = 0), loopEnd EXCLUSIVE (nil = the zone's
/// resolved end). Ignored when loopMode is nil. Clamped so loopEnd >
/// loopStart (raised, not swapped — the endFrame idiom); the engine further
/// clamps both into the real playable span.
public var loopStart: Int?
public var loopEnd: Int?
```

Init clamps (after the `startFrame`/`endFrame` block, `Model.swift:1473-1476`,
same idiom):

```swift
self.loopMode = loopMode
let ls = loopStart.map { max(0, $0) }
self.loopStart = ls
self.loopEnd = loopEnd.map { max($0, (ls ?? 0) + 1) }   // raise, never swap
```

No new `static let` range — frame fields are unbounded above like
`startFrame`/`endFrame`. `contains` and selection are untouched.

### 6.2 Persistence — `SamplerZoneDocument` +3 (`ProjectDocument.swift:805-920`)

Add `loopMode: String?` (the enum's rawValue — the document layer stays
string-typed like `media`; decode tolerantly: an unknown rawValue decodes as
nil rather than throwing), `loopStart: Int?`, `loopEnd: Int?`:

- `CodingKeys` (`:832-837`), `init(from z:)` (`:839-863`), `init(from
  decoder:)` via `decodeIfPresent` (`:865-890`), `encode` via
  `encodeIfPresent` (`:902-918`) — the exact m19-a/b omit-when-nil idiom.
- `instrumentDescriptor(bundleURL:warn:)` pass-through
  (`ProjectDocument.swift:739-748`): `loopMode: zd.loopMode.flatMap
  SamplerLoopMode.init(rawValue:)`, `loopStart: zd.loopStart`,
  `loopEnd: zd.loopEnd`.

**Byte-identity proof, named tests**: `Tests/DAWCoreTests/
SamplerZonePersistenceTests.swift` — `legacyDocumentShapeStable` (line 72)
asserts a nil-field zone document encodes EXACTLY
`{id, media, rootPitch, minPitch, maxPitch, gain}` and decodes every optional
as nil; it runs UNCHANGED and enforces that the 3 new keys never leak into
legacy shapes. `fullZoneRoundTrip` (line 26) extends 17 → 20 fields (update
the test name/doc comment "all 17" accordingly). Render-side byte identity:
`Tests/DAWEngineTests/SamplerSelectionTests.swift:343`
(`legacyZonesFirstMatchByteIdentical`) and the nil-field playback-law test in
`Tests/DAWEngineTests/SamplerPlaybackTests.swift:199` run unchanged — they
are the regression gate that nil loop fields render bit-identically.

### 6.3 Wire — `instrument.set` zone schema +3 (no new command; pin stays 127)

- `parseSampler` (`Sources/DAWControl/Commands.swift:4303-4396`): parse
  optional `loopMode` (string `"sustain"`/`"continuous"`; anything else →
  teaching error `sampler.zones[i].loopMode must be "sustain" or
  "continuous"`), `loopStart`/`loopEnd` via `optionalInteger`; pass into the
  `SamplerZone` init call (`:4357-4380`). Range/raise clamping stays the
  model init's job (the documented convention at `:4290-4302`).
- `instrumentJSON` (`Commands.swift:4725-4797`): emit the three fields
  when SET only (`object["loopMode"] = .string(loopMode.rawValue)` etc.) —
  the A-imp-1 emit-when-set idiom keeps legacy zones' wire shape
  byte-identical (`:4741-4744` comment law).
- Extend `Tests/DAWControlTests/SamplerZoneWireTests.swift`: set→get
  round-trip of the 3 fields + legacy-shape stability.

The import path itself needs zero wire changes
(`ProjectStore+SampleLibraries.swift:26-78` flows mapper→`setInstrument`
untouched; the report is Codable-verbatim).

---

## 7. Step-by-step implementation plan

Order chosen so every step compiles and tests green before the next:

1. **Model** — `Sources/DAWCore/Model.swift`: `SamplerLoopMode` + 3
   `SamplerZone` fields + init clamps (§6.1). Extend
   `Tests/DAWCoreTests/SamplerZonePersistenceTests.swift` is NOT yet needed
   (documents come next) but model unit asserts (raise-not-swap) go into the
   existing model-level suite in `Tests/DAWCoreTests/SamplerTests.swift`.
2. **Persistence** — `Sources/DAWCore/ProjectDocument.swift` (§6.2) + the two
   `SamplerZonePersistenceTests` updates.
3. **`smpl` reader** — NEW `Sources/DAWCore/SampleLibraries/WAVSampleLoops.swift`
   (§4.3) + NEW `Tests/DAWCoreTests/WAVSampleLoopsTests.swift` (§8.1, WAV
   bytes hand-built with the `le32`/`le16` builder idiom —
   `Tests/DAWCoreTests/GenerationImportTests.swift:39-40` precedent).
4. **IR + parsers** — `SampleLibraryIR.swift` +2 fields (§4.1);
   `SFZParser.swift` (§4.2); `DSPresetParser.swift` (§4.4); extend
   `SFZParserTests` / `DSPresetParserTests`.
5. **Mapper** — `SampleLibraryMapper.swift` (§5.1, §5.2) + `loopedZones`
   report field; extend `SampleLibraryMapperTests` (§8.2).
6. **Engine** — `Sources/DAWEngine/Instruments/SamplerInstrument.swift`:
   `LoadedZone` +6 / `Voice` +2 (§3.2), init resolution (§3.3), trigger/
   noteOff/pedal deltas (§3.4), `renderFrame` looping branch (§3.5); update
   the class-header doc comment (`:6-71`). NEW
   `Tests/DAWEngineTests/SamplerLoopTests.swift` (§8.3-8.5) on the
   `SamplerPlaybackTests` direct-render harness
   (`SamplerPlaybackTests.swift:85-153`).
7. **Wire** — `Sources/DAWControl/Commands.swift` (§6.3) +
   `SamplerZoneWireTests`; extend
   `Tests/DAWControlTests/SampleLibraryCommandTests.swift` with a looped-SFZ
   E2E (§8.6).
8. **Docs & copy** — `docs/SFZ-SUPPORT.md` (§5.3), `docs/ARCHITECTURE.md`
   settled line (§1.2), `mcp-server/src/server.ts` description sentence
   (§5.2 — MCP flight owns exact copy; npm suite re-run), roadmap tick by
   the orchestrator.

---

## 8. Test / GATE plan

### 8.1 `WAVSampleLoopsTests` (unit, hand-built bytes)

Minimal WAV builder: `RIFF` + `fmt ` (16-byte PCM) + tiny `data` + `smpl`.
Cases: (1) forward loop parsed, exact dwStart/dwEnd; (2) `smpl` AFTER `data`
found; (3) odd-sized chunk before `smpl` — pad byte honored; (4) two loops,
first is `dwType 1`, second `dwType 0` → the forward one wins; (5)
`cSampleLoops` lies high → bounded by chunk size, no crash; (6) truncated
`smpl` → nil; (7) `dwEnd < dwStart` → record rejected → nil; (8) non-RIFF /
non-WAVE / empty file → nil; (9) no `smpl` → nil.

### 8.2 `SampleLibraryMapperTests` (unit, policy)

(1) SFZ `loop_mode=loop_continuous loop_start=4410 loop_end=48509` → zone
`loopMode == .continuous`, `loopStart == 4410`, `loopEnd == 48510` (**the +1
assert**); (2) `loop_sustain` → `.sustain`; (3) `no_loop` + WAV WITH `smpl`
loop → loop fields nil (explicit suppression); (4) no opcodes + `smpl` WAV →
`.continuous` with chunk points, `loopedZones == 1`; (5) authored mode, no
points, `smpl` present → chunk points win the nil slots; authored point +
`smpl` → authored wins per field; (6) `loop_end < loop_start` → unlooped +
invalid-bounds degradation, region still imported; (7) points without mode,
no `smpl` → unlooped + points-without-mode degradation; (8) unrecognized
`loop_mode=loop_bidirectional` → `ignoredOpcodes["loop_mode"] == 1`;
(9) `ignoredOpcodes` contains NO `loop_start`/`loop_end`/`loopStart`/`loopEnd`
keys anywhere; (10) `.dspreset` `loopEnabled="true" loopStart="4410"
loopEnd="48509"` → field-identical zone to the SFZ twin (extend the m19-d
parity-GATE idiom in `DSPresetParserTests`); (11) `one_shot` mapping
unchanged (`oneShot == true`, loop fields nil).

### 8.3 The render GATE (roadmap `docs/ROADMAP.md:317` wording)

Fixture `loop440.wav`: **1.5 s @ 44.1 kHz mono = 66 150 frames**, 440 Hz sine
amp 0.5 (the `SamplerPlaybackTests.writeMono` builder,
`SamplerPlaybackTests.swift:56-83`). Zone: root 69, `loopMode: .continuous`,
`loopStart: 4410`, `loopEnd: 48510` (1.0 s loop). Graph 48 kHz — the file
exhausts at 72 000 output frames (1.5 s) without loops.

**GATE assert**: hold pitch 69 vel 127 for **10 s** (480 000 frames): every
1 s window RMS > 0.2 (expected ≈ 0.283 = 0.5 · 0.8 · 1/√2) through t = 10 s —
≥ 6.6× the file's natural length; zero-crossing count in the 8–9 s window =
880 ± 4 (440 Hz pitch integrity across ~6 wraps); then noteOff → release
decays to EXACT zeros (the `SamplerInstrument.swift:542-546` free law).

### 8.4 `loop_sustain` release-behavior proof + continuous counterpart

Fixture `loop440tail880.wav`: frames `[0, 48510)` 440 Hz; frames
`[48510, 66150)` **880 Hz** (the tail marker). Zone loop `[4410, 48510)`.

- `.sustain`: hold 4 s (≥ 3 wraps — only 440 present in every held window),
  noteOff with a long zone `release` (e.g. 1.0 s) → an 880-dominant
  zero-crossing window appears after noteOff (the playhead exits the loop and
  crosses into the tail: ≤ 1.0 s of loop remainder + 0.4 s of tail at the
  44.1→48 k rate ratio — assert 880 ± 8 in a window inside that span), then
  the voice frees at `endFrame` or envelope zero.
- `.continuous`, same fixture and events: **no** 880-dominant window EVER —
  440 through hold AND release. This pair is the semantic proof of §2.1.
- Pedal variant: noteOff under CC64-down keeps looping (440 persists past
  noteOff); pedal-up starts the release → 880 appears (sustain mode).

### 8.5 Crossfade click-bound + no-loop byte regression

- Click bound: `loop440.wav` with DELIBERATELY phase-hostile bounds (e.g.
  `loopStart 4410`, `loopEnd 48560` — 44 150 frames ≈ 440.5 periods, seam
  lands a half-cycle out of phase). Render 5 s held; assert
  `max |x[n] − x[n−1]|` over the FULL render ≤ 0.06 (natural max delta of a
  0.5-amp 440 Hz sine at 48 k ≈ 0.029; a raw wrap at half-phase would jump
  ≈ 0.8). This single number proves the §3.1 policy end-to-end.
- Raw-wrap degradation documented: same bounds but `loopStart 0` (no
  pre-start material → `loopXfade == 0`): test only asserts it still loops
  and stays finite — clicks are accepted and documented for loopStart-0.
- No-loop regression: `SamplerTests`, `SamplerSelectionTests`
  (`legacyZonesFirstMatchByteIdentical`, `SamplerSelectionTests.swift:343`),
  and `SamplerPlaybackTests` (nil-field law, `:199`) run UNCHANGED — the
  byte-identity gate for old fixtures/projects. Plus one new A/B in
  `SamplerLoopTests`: the same zone with loop fields nil renders
  byte-identical output to the same render before step 6's diff (assert
  against the non-loop twin zone in-suite).

### 8.6 E2E + report flip (`SampleLibraryCommandTests`, wire)

Import `loop-fixture.sfz` over the wire (the m19-c E2E-render-gate idiom):
r1 `loop_continuous` with explicit points; r2 `loop_sustain` no points, WAV
without `smpl`; r3 no loop anything; r4 no opcodes but WAV WITH an embedded
`smpl` forward loop. Assert the §5.2 table exactly: `zonesImported == 4`,
`loopedZones == 3`, `ignoredOpcodes` loop-key-free, no loop degradation
sentences; then render through the store-owned engine path and re-assert the
8.3 sustain criterion at reduced length (e.g. 1.5 s fixture held 4 s). MCP
side: `mcp-server` suite re-run after the description edit (no schema
change — `loopedZones` rides the verbatim report).

---

## 9. OUT of scope (v1 boundary — filed, not boxed)

- `.dslibrary` unzip; streaming/background sample load; reference-in-place
  library persistence (the remaining m19-c v2 candidates,
  `docs/ROADMAP.md:296`).
- Release-triggered samples (`trigger=release` stays a §2.3 skip).
- Ping-pong/backward (`dwType` 1/2) and multiple/nested `smpl` loops; finite
  `dwPlayCount`; `dwFraction` sub-sample points; `smpl` unity-note/pitch
  metadata; AIFF `INST`/`MARK` loop metadata.
- Per-zone authored crossfades (`loop_crossfade`, `.dspreset`
  `loopCrossfade`/`loopCrossfadeMode` — stay ignored-tallied).
- Loop-point editing UI; `loop_mode` hot-swap on live voices (zones are
  structural — rebuild law, `SamplerInstrument.swift:59-61`).

## 10. Disclosures — what I could not verify

1. **DecentSampler official docs unreachable** (decentsamples.com format page
   is a redirect stub). `loopStart`/`loopEnd`/`loopCrossfade` units (samples)
   and `loopEnabled` semantics are corroborated by a third-party writeup and
   the m19-d parser's shipped behavior, but whether DecentSampler itself
   auto-honors WAV `smpl` when attributes are absent is UNVERIFIED — the
   §2.3 fallback-for-.dspreset rule is OUR cross-format decision, anchored on
   the SFZ default law, not on DecentSampler documentation.
2. **`loopstart`/`loopend` v1 spellings**: my sfzformat.com fetches did not
   surface the alias table rows; consuming both spellings is zero-risk
   tolerance consistent with the shipped `loopmode` alias
   (`SFZParser.swift:321`). If sfzformat lists no such aliases, the extra
   `take`s are harmless.
3. **`smpl` "byte offset" spec wording**: the original 1994 spec text
   reportedly calls dwStart/dwEnd byte offsets (teragonaudio mirror timed out
   on fetch); the frames-and-inclusive reading (D4) follows recordingblogs.com
   and universal tool practice, which is the interop-correct choice.
4. **DecentSampler default crossfade length** (the "same ballpark as 512
   frames" remark in §3.1) — unverified; the 512 choice stands on the
   11.6 ms perceptual argument alone.
5. I did not build or run the suites in this design flight; all line numbers
   are from reads of the current working tree (post-`31a46aa`).

## Sources

- sfz `loop_mode` / `loop_start` / `loop_end`: https://sfzformat.com/opcodes/loop_mode , https://sfzformat.com/opcodes/loop_start , https://sfzformat.com/opcodes/loop_end
- WAV `smpl` chunk layout: https://www.recordingblogs.com/wiki/sample-chunk-of-a-wave-file , http://www.piclist.com/techref/io/serial/midi/wave.html (mirror of the classic WAVE file format reference)
- DecentSampler looping attributes (third-party corroboration): https://synthesizerwriter.blogspot.com/2022/06/looping-in-decent-sampler-quick-look.html ; official docs index: https://decentsampler-developers-guide.readthedocs.io/
