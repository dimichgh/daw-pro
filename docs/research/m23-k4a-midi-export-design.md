# m23-k4a — Standard MIDI File EXPORT from the project

**Status: DECISIONS SETTLED AND MEASURED. Implementation not started.**
Architect read required by the `m23-k4a` roadmap line. This is the fourth item
in the SMF chain (k1 IR → k2 writer → k3 import → **k4a export**), and it does
not re-derive k1/k2/k3's conclusions — it inherits them and inverts them. Route
after this doc: `swift-app-engineer`. Scope: **DAWCore + wire only, ZERO UI**
(the drop target and File-menu entries are m23-k4b).

**Nothing in this item requires full Xcode.** No entitlements, no AUv3, no code
signing, no bundling — pure `Data` serialisation, model reads, and wire
plumbing; `./scripts/test.sh` covers all of it. The one place Xcode *is* used is
outside the build, exactly as k1/k2 used it: `MusicSequenceFileLoad` as a
third-party witness for one new fixture (§9.3). That validator was **run during
this read** on the machine (Xcode 26.6, Swift 6.3.3) and its output is in §9.3 —
it does not have to be re-run to be believed, only re-run to be regressed.

---

## Inputs read

| File | What it decided here |
|---|---|
| `/Users/dsemenov/Views/daw-pro/docs/research/m23-k3-midi-import-design.md` | the spine, D2, the verbatim meter mapping, the report idiom, the gate-discriminator discipline |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/StandardMIDIFile.swift` | the tick-native IR this item BUILDS (k1) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/StandardMIDIFileWriter.swift` | the byte-frozen encoder this item CALLS (k2): P1–P12, the `Rank` ladder, every `SMFEncodeError` |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/StandardMIDIFileMapper.swift` | `SMFTickClock` (:187–300) — the ONE producer of a beat from a tick; `MIDIImportReport` (:322–430+) — the report this one mirrors |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore+MIDIFile.swift` | the store shape the export methods mirror |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/Model.swift` | `MIDINote` (:103), `MIDIControllerType`/`Lane` (:234/:380), `Clip` (:456), `Track` (:997), `InstrumentDescriptor` (:1262), `TimeSignature` (:1603), `TransportState.tempoRange` (:1677) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/TempoMap.swift` | `Segment.init` clamp (:38–42), `TempoMap.init` ordering guard (:75–85), `MeterMap.Change.init` (:355–361), `MeterMap.init` (:393–411) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/Groove.swift` | `builtin(named:)` (:116–131) — the swing offsets DAW Pro's own quantizer produces; **this is what settles the division default** |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore+Humanize.swift` | the humanize jitter distribution (uniform ±`timingBeats`) — the realistic off-grid input |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore+Render.swift` | the destination-path policy (:274–299) this item copies |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/SoundBanks.swift`, `GMProgramCatalog.swift` | `SoundBankConfig.source`/`program`/`bankMSB`; GM bank conventions |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/MIDISchedule.swift` | :145/:149/:183 — the engine's clip window. **Read, and deliberately NOT used** (§3.4) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWControl/Commands.swift` | `allCommands` (:153), the `{report, applied}` response shape |

---

## 0. The spine, inverted — and the one place the inversion is NOT symmetric

k3's spine: for a metrical file, **`beat = tick / t`**, with no tempo term.
k4a's spine is its inverse:

```
tick(beat) = Int((beat * t).rounded())                                  // X1
```

Everything follows from X1, including two things a reader will get wrong from
memory:

1. **Export is LOSSY where import is not.** `beat = tick/t` is total: every tick
   has a beat. `tick = round(beat·t)` is not: the beats DAW Pro can hold are
   arbitrary `Double`s and only the ones with `beat·t ∈ ℤ` survive. That is the
   headline user-facing decision (§1, D-OFFGRID) and it is why the report has a
   quantization section import does not need.
2. **The note-length rule REVERSES.** k3's R3 forbids endpoint subtraction
   (`beats(tick+len) − beats(tick)`) and requires `len/t`. Export requires the
   **opposite**: `lengthTicks = tick(startBeat + lengthBeats) − tick(startBeat)`,
   NOT `round(lengthBeats·t)`. Both rules exist for the same reason — one
   rounding, not two — but they land on opposite forms because the direction
   flipped. This is the single most likely "helpful cleanup" bug in the item and
   it is measured in §2.3.

What does **not** change: **no tempo value enters X1.** Every tempo hazard in
this item is a playback-speed hazard, never a note-position hazard, exactly as in
k3. Export emits no SMPTE division at all (§4.1), so k3's absolute-time carve-out
has no export analogue: `SMFTickClock`'s absolute branch is inverted for
completeness and unit-tested, but the wire cannot reach it.

### 0.1 The measurements, in one table

Every number below is reproduced with its program in **Appendix A**. Nothing in
this document is argued where it could be measured.

| # | Question | Measured answer |
|---|---|---|
| **M1** | Worst round-trip error `|beat − round(beat·t)/t|` on realistic content | Exactly `0.5/t` beats. At **t = 9600 that is 5.2083e-5 beats = 0.026 ms at 120 BPM** — 0.02 % of a 16th note. At t = 96 it is 2.60 ms. |
| **M2** | Does a higher division FIX the loss or only MOVE it? | **Only moves it, for genuinely off-grid content.** Humanized (±0.02 beat) and free/recorded material is exact at NO division: 96…15360 all lossy. **But for grid content it genuinely fixes it** — and which grids a division captures is a hard arithmetic fact, not a matter of degree. |
| **M3** | Smallest division ≤ 32767 that exactly represents DAW Pro's own quantized output **and** everything it can import | **9600**, uniquely (exhaustive search over 1…32767). `9600 = 2⁷·3·5²`. |
| **M4** | Do the industry defaults do it? | **No, and the failure is not marginal.** 480 and 960 lose every MPC swing preset DAW Pro ships. 1200 and 2400 lose content native to **96, 192, 384 and 960** tpqn files — i.e. they corrupt re-export of files k3 just imported. 15360 loses swing. |
| **M5** | `bpm → µs/qn → bpm` (the direction EXPORT runs — D2 verified the other one) | **NOT exact. 352 of 381 integer BPMs in 20…400 fail.** Worst absolute error **0.0013101 BPM at 397 BPM** (relative 3.3e-6); inside 60…200 BPM the worst is 0.000314 BPM at 196.5. That is **0.198 ms of drift per minute of music**, ~1 ms over a five-minute song. It moves ZERO notes. |
| **M6** | Is "round-trip 666666 µs/qn" a valid gate leg for the µ rounding rule? | **NO — VACUOUS.** `60e6 / (60e6/666666)` computes to **exactly 666666.0**, so `round`, `floor`, `ceil` and `trunc` are indistinguishable on the spine fixture's own tempo. Discriminators found: **61 BPM** (frac .557: round/ceil → 983607, floor/trunc → 983606) and **104 BPM** (frac .077: ceil → 576924, the rest → 576923). |
| **M7** | Endpoint-subtracted length vs independently-rounded length | They differ on **24.9 % of 200,000 random (start, length) pairs**. Endpoint form bounds the note-END error at half a tick; independent form at a full tick. **Decisive leg: of 50,000 flush-legato pairs, the endpoint form keeps note-off tick == next note-on tick in 50,000 (100 %); the independent form breaks it in 12,420 (24.84 %).** |
| **M8** | Beats that discriminate `round` from `floor`/`trunc`/`ceil` at t = 9600 | **1.00006** (`beat·t = 9600.576`) and **1.00001** (`beat·t = 9600.096`). Together they pin `round` uniquely. `floor` and `trunc` are provably indistinguishable at non-negative beats — an honest limit of the leg, not a gap. |
| **M9** | Does Apple's loader accept a SMPTE-division file carrying `FF 58`, and expose the meter? | **YES to both, and it is a usable witness.** `MusicSequenceFileLoad` returns 0 (ACCEPTED) and reports `META type=0x58 len=4 payload=03 02 18 08` on the tempo track. **It does NOT arbitrate timing**: every timestamp comes back `-0.0` and the note duration `0.0` — Apple's beat-native model collapses SMPTE absolute time, exactly as k1's comment claims. Measured, not quoted. |
| **M10** | Tick headroom at 9600 | `0x0FFFFFFF / 9600 = 27962.0` beats = 6990 bars of 4/4 = **3.9 hours at 120 BPM** before any single delta overflows the 4-byte VLQ. |
| **M12** | Does the one available THIRD-PARTY arbiter accept a `9600` header, or is D-DIVISION argued-only? | **Accepted, and read back correctly.** Apple's `MusicSequenceFileLoad` on a hand-built 2-track format-1 file at division `0x2580` (9600): `status = 0`, both chunks present, notes at `t = 0.0`, `1.0001041889190674`, `2.0` against authored beats `0.0`, `1.0001041666666666`, `2.0`, durations `0.5 / 0.49999997 / 0.5` against an authored `0.5`. The `2.2e-8` beat gap is Apple's own `MusicTimeStamp` float32 path (it appears identically at 480 tpqn), and is **2367× smaller than our own worst quantization step at 9600** (`0.5/9600 = 5.2083e-5`), so it is invisible under the loss we already report. | `python3 scratchpad/mk9600.py && ./validate probe-9600.mid` — full program + verbatim output in Appendix A.7. **This is the leg that converts D-DIVISION from a derivation into an arbitrated fact.** The exhaustive search (M3/M4/M7) proves 9600 is the smallest division that represents DAW Pro's content exactly; M12 proves a shipping third-party reader ingests that header without complaint. Neither alone is sufficient: a division can be arithmetically perfect and still trip a reader that assumes 480/960. |
| **M11** | Wire/MCP baseline, house recipe, measured today | `allCommands` = **156** (tail `note.audition, track.reorder, project.importMIDI, clip.importMIDI`); MCP `registerTool` = **159**, 0 with a `daw_` prefix. k4a → **158 / 161**. |

---

## 1. Verdict table

Verdict vocabulary is k3's: **refuse** = the command throws and nothing is
written; **warn** = the export proceeds and the loss is named in the returned
`MIDIExportReport` (§5). No loss in this design is silent.

### 1.1 The ten open decisions

| # | Decision | Verdict | Rule | Rationale |
|---|---|---|---|---|
| **D-OFFGRID** | What export does with a beat that is not on the tick grid (recorded/humanized/swung material) | **quantize with `round`, and REPORT the exact loss** | `tick = Int((beat·t).rounded())` (X1). The report carries `notesQuantized` / `controllerPointsQuantized` (counts of items moved by more than `beatEpsilon = 1e-9`), `maxQuantizationErrorBeats`, `maxQuantizationErrorMs` (at the tempo in force at the worst item's beat) and, when non-zero, one `degradations` sentence naming the worst offset in milliseconds. **The error is MEASURED through the actual round trip** — `abs(beat − clock.beats(tick: clock.ticks(beat: beat)))`, both directions of the same clock — never through a formula, so the number the report prints is definitionally what a re-import will see. | **Refusing is indefensible** and **auto-choosing is worse than it looks.** M2: for genuinely off-grid content NO division ≤ 32767 is exact, so "choose a division that captures the content" cannot be a general policy — it would refuse or degrade on exactly the material it was invented for. M1: at the chosen default the worst possible error is **0.026 ms at 120 BPM**, two orders under any perceptual threshold and under the jitter of real MIDI hardware. What the user is owed is not perfection but **an exact number**, which the report gives. The remaining sliver of value in auto-selection is delivered without the machinery by D-DIVISION's derivation (the default already captures every grid the app itself produces). |
| **D-DIVISION** | Default ticks per quarter note, and whether it is a caller option | **9600, and yes — `division`, an Int in 1…32767** | `division` defaults to `SMFExportOptions.defaultTicksPerQuarterNote = 9600`. Out-of-range is a field-named `ControlError` (the iv-d contract-range precedent), not a clamp. | **9600 is DERIVED, not conventional, and the derivation is the argument** (M3, M4). It is the unique smallest division ≤ 32767 that is exact for: every dyadic subdivision down to 1/128 of a beat; every triplet and sextuplet; every quintuplet; **every MPC swing preset `Groove.builtin(named:)` produces** (offsets `P/100` and `P/200`, so 5² is required); **and content native to 24, 48, 96, 120, 128, 192, 240, 384, 480 and 960 tpqn source files** — i.e. a file k3 just imported re-exports bit-exactly. `9600 = 2⁷·3·5²`, and it is divisible by 24, so MIDI-clock alignment is preserved. The industry defaults FAIL this: **480 and 960 lose swing; 1200 and 2400 lose 96/192/384/960-native content; 15360 loses swing.** The cost is headroom (M10: 3.9 hours at 120 BPM instead of 38.8 at 960), which is not a real constraint and is guarded by a teaching refusal (§6.3). Not divisible by 7 or 9: septuplets and nonuplets quantize, and are reported like any other off-grid content. |
| **D-FLATTEN** | Overlapping clips; two notes of the SAME PITCH overlapping; notes past a clip's end; clip gain/stretch | **as AUTHORED, except where the FORMAT cannot express it** (§3) | A track's clips are flattened by absolute beat (`clip.startBeat + note.startBeat`) into one event stream. Overlapping clips simply interleave. **Same-pitch overlap: the EARLIER note is truncated to end exactly at the later note's onset**, reported as `overlappingSamePitchNotesTruncated`; if that leaves ≤ 0 ticks the earlier note is DROPPED, reported as `overlappingSamePitchNotesDropped`. **Notes and controller points past their clip's end are exported at their authored positions** and reported (`notesPastClipEnd`, `controllerPointsPastClipEnd` — k3's field names verbatim). Clip `gainDb`, `gainEnvelope`, fades, `stretchRatio`, `pitchShiftSemitones` are NOT baked into velocity or timing; a non-identity value is reported (`clipsWithGainNotExported`, `clipsWithStretchNotExported`). | **The two halves are different classes and the discriminator is sharp: SMF cannot express nested same-pitch note-ons, but it can express a note past a clip boundary perfectly well.** The first is a format limit, the second would be us applying a playback rule. See §3.4 for why the playback rule is excluded — it would break the round trip on clips **k3 itself produces** (`clip.importMIDI` deliberately keeps content past the clip end and reports it). Truncation is the only same-pitch resolution that ROUND-TRIPS: k2's `Rank` ladder emits note-off (rank 1) before note-on (rank 3) at an equal tick, so a note truncated exactly to the next onset re-imports as the same two notes. Emitting the nested pair instead produces a file that loads everywhere and comes back with the two notes' **lengths swapped** (the reader pairs FIFO) — silent corruption, the class k2's own doc comment calls out. |
| **D-MIX** | Muted and soloed tracks | **export as AUTHORED; report the mix state; do NOT honour it** | Every selected instrument track is exported regardless of `isMuted` / `isSoloed`. `mutedTracksExported` and `soloedTracksPresent` ride the report; neither pushes a `degradations` line on a project with no mutes. Callers who want the audible subset pass `trackIds`. | MIDI export **serialises the model; it does not render it** — that is the roadmap's own stated ground for naming this `project.exportMIDI` rather than `render.exportMIDI` (every `render.*` command runs the engine; this one never touches it). A muted part still exists in the project, and a user exporting to a notation program or a collaborator wants it. Honouring mute would also make the exported bytes depend on transport-adjacent state that is not part of the arrangement, and would collide with D-FLATTEN's as-authored rule with no discriminator that survives. |
| **D-AUDIO** | Audio tracks (and buses) | **skip + report** | A track whose `kind != .instrument` produces **no `MTrk`**. It appears in the report's `tracks` ledger with `exported: false` and `skipReason: "audio track — a MIDI file has nowhere to put recorded audio"` (or `"bus track — carries no notes"`). An **instrument** track with no MIDI content is still exported, as an empty named chunk. `track.exportMIDI` on a non-instrument track **refuses** (`notAnInstrumentTrack`). | k3's D4 (skip the conductor, report it) inverted. Emitting an empty chunk for an audio track would claim the file contains that part; omitting it silently would read as "my drums disappeared". The asymmetry with empty *instrument* tracks is deliberate and useful: it makes the chunk count a function of the project's **track structure** only, never of its content, so an export is deterministic in a way a content-dependent one is not, and the receiving DAW gets the track layout. `track.exportMIDI` refuses rather than writing an empty file because an explicit single-track request naming a track that cannot carry MIDI is a mistake worth naming (the `notAMIDIClip` posture). |
| **D-SHAPE** | Format 0 vs 1; conductor; end-of-track; naming | **format 1 for BOTH commands, conductor ALWAYS chunk 0. `format` is a caller option (0 or 1).** | `project.exportMIDI` and `track.exportMIDI` both emit format 1: chunk 0 is a conductor carrying the project name (`FF 03`), the whole tempo map and the whole meter map and nothing else; chunks 1…N are the exported tracks in project order. **End-of-track:** each track chunk's `endTick` is `max(tick(clip.startBeat + clip.lengthBeats) over its clips, its own last event tick)`; the conductor's is the max over all chunks and its own last tempo/meter tick. **Naming:** `FF 03` per chunk from `Track.name` verbatim (UTF-8); an empty name emits no `FF 03`. Requesting `format: 0` merges everything into one chunk and is reported (`trackNamesLostToFormat0`). | Format 1 for the single-track command too, and the reason is concrete: k2's `Part.merged` takes **"the FIRST non-nil part name"** (`StandardMIDIFileWriter.swift:541`), so a format-0 file with a conductor keeps the CONDUCTOR's name and loses the track's. That forces a choice between the tempo map and the track name — a choice format 1 does not have. Always emitting the conductor (even for a default 120 BPM / 4/4 project) keeps the chunk count independent of content and matches every DAW's output; k3's D4 skips it on re-import, so the round trip is clean. The `endTick` rule is what makes `clip.lengthBeats` survive a round trip: k3's R6 reads the clip's length back OUT of `part.endTick`, so trailing silence must be written IN. |
| **D-PROGRAM** | Program change, and MIDI channel assignment | **the exported bytes contain NO `Cn` at all — k2 cannot write one (§4.3); the IR carries it, the report names it. Channel assignment IS real: one channel per exported track, drum kits on channel 9** | **Read this row's verdict as two separate claims, because only one of them reaches the file.** (a) *Program change — DOES NOT REACH THE BYTES IN k4a.* `StandardMIDIFileWriter.buildPart` iterates `notes` and `controllers` only; it never reads `SMFTrack.programChanges`, and the writer is byte-frozen. k4a therefore **populates `SMFTrack.programChanges` on the IR** — exactly one `SMFProgramChangeEvent(tick: 0, channel: ch, program: soundBank.program)` **iff** `instrument.kind == .soundBank && instrument.soundBank?.source == .generalMIDI` — and **counts every one of them in `programChangesNotWritten`**, because none of them are encoded. An implementer who opens the exported file will find no `0xC0` byte; that is the design, not a bug, and §4.3 + §13 item 1 carry the fix. No bank-select CCs are ever emitted, now or after the k2 fix. The `source == .generalMIDI` gate is therefore doing two live jobs today: it decides which tracks the report NAMES (per-track `program` / `programName`), and it is the predicate the k2 follow-up will inherit unchanged. Every other instrument kind (`polySynth`, `sampler`, `audioUnit`, a `.file(path:)` sound bank) sets no program change and reports `program == nil`. (b) *Channels — REAL IN k4a, and independent of (a).* A track whose sound bank has `bankMSB == GMProgramCatalog.percussionBankMSB` (120) takes channel **9**; every other exported track takes the next channel from `0,1,…,8,10,…,15`, wrapping with a report line (`channelsWrapped`). | k3's D3 named this as k4's obligation. Gating on `source == .generalMIDI` and not merely on `kind == .soundBank` is load-bearing: a `.file(path:)` SF2's program number addresses **that file's** bank, and writing it as a GM program would name a different instrument in every other program that opens the file. Bank select is deliberately absent — DAW Pro's `bankMSB` 121/120 are AUSampler conventions (`kAUSampler_DefaultMelodicBankMSB`), not GM file conventions, and emitting them as `CC 0` would mean something else to every reader. **On channels, and the reason does NOT lean on program change** (which §4.3 shows does not reach the bytes yet): **channel 9 IS the drum channel in every GM player, regardless of any `Cn`**, so a drum track exported on 9 sounds like drums and one exported on 0 does not — that alone settles the drum rule. One channel per melodic track is then what every DAW does, what makes a `format: 0` export re-importable through k3's channel split, and what a receiving DAW maps to tracks. It makes the exported bytes depend on track ORDER — but chunk order already does, inescapably, so this introduces no new dependency class (§11 Alternative B's determinism argument is about CONTENT-dependence, which is a different thing). |
| **D-REPORT** | What export returns | **a new `MIDIExportReport` in DAWCore, structurally symmetric with `MIDIImportReport`** | §5. Typed counts for tests and agents, prose `degradations` for humans, every `[String]` field capped at 32 entries with a trailing `"… and N more"`. **`dryRun` computes the full report and writes NOTHING.** | k3's §5 verbatim, including the cap (a pathological project must not mint an unbounded array into an agent's context) and the vacuity guard: a clean project must produce an all-zero/empty loss section and `degradations == []`, with no exemption (gate leg G9). |
| **D-ONEHOME** | Where the beat→tick inverse lives | **ON `SMFTickClock`, in `StandardMIDIFileMapper.swift`, and it is FORCED there** | Add to `SMFTickClock`: `public func ticks(beat: Double) -> Int`, `public func noteTicks(startBeat: Double, lengthBeats: Double) -> (tick: Int, lengthTicks: Int)`, and `public var division: SMFDivision`. **`noteTicks` returns the PAIR**; there is no length-only entry point, so independently-rounded lengths are not merely discouraged, they have no API to be written through. | §2.4. The placement is not a preference: `SMFTickClock.kind` is `private`, and Swift's `private` at type scope reaches extensions **in the same file only**, so an inverse written anywhere else would have to re-destructure the division and re-derive the SMPTE frame rate — two copies of the exact relationship the type exists to own. The pair-returning signature is the mirror of k3's `metricalLength(lengthTicks:ticksPerQuarter:)` trick, which hides `tick` from the branch that must not use it; here it hides `lengthBeats` from the branch that must not round it. **Honest limit, stated so it is not overclaimed** (the k3 V.4.4 lesson): nothing stops a determined implementer pattern-matching `SMFDivision` and multiplying by hand. What the design buys is that the *natural* way to write the mapper is the only *available* way, plus gate leg G-M1, which reddens if `noteTicks` is changed to independent rounding. |
| **D-SMPTE** | The unwitnessed k3 SMPTE × meter conclusion | **WITNESSABLE, and it works — build the fixture** | §9.3. A format-1 file with a `0xE728` SMPTE division, an `FF 58 04 03 02 18 08` (3/4) and an `FF 51` on the conductor, plus a note track. **Measured (M9):** Apple's `MusicSequenceFileLoad` accepts it (status 0) and exposes the meter as `META type=0x58 len=4 payload=03 02 18 08`. It does **not** arbitrate timing — every timestamp comes back `-0.0` and the note duration `0.0`. | This converts k3's hand-built-IR-only leg into a real byte fixture for **the meter half**, which is the half that was in doubt. It does not, and cannot, witness the position half — and that limit must be written into the fixture README's "Apple-confirmed / spec-asserted" column rather than left to be assumed away. **The fixture is only a witness of OUR output if OUR writer produces those exact bytes**, so the test must assert byte-equality between `StandardMIDIFileWriter.encode(<the IR>)` and the checked-in file; without that assertion Apple is arbitrating a hand-authored artifact and not the one that ships. |

### 1.2 What k4a INHERITS and does not re-argue

- **D2 — µs/quarter is authoritative.** Export emits `Int((60_000_000.0 / bpm).rounded())`. Verified exact in the µ→bpm→µ direction over the whole clamp window (0 failures in 2,850,001; re-run as a control here, Appendix A.3).
- **Meter maps VERBATIM.** 6/8 → `numerator = 6`, `denominatorPower = 3`. Export is the identity of k3's import, which is precisely what k3's §1.3 reversal was for.
- **The spine.** `beat = tick/t`, no tempo term; every tempo hazard is a playback-speed hazard.

### 1.3 One finding D2 does NOT cover, discovered by this read

**D2 was verified in the direction IMPORT runs (`µ → bpm → µ`). Export runs the
other one (`bpm → µ → bpm`), and that direction is NOT exact.** Measured (M5,
Appendix A.3): **352 of the 381 integer BPMs in 20…400 do not round-trip
bit-exactly.** A 140 BPM project exports `round(60e6/140) = 428571` and reads
back as 140.0000023…; the worst case over the clamp window is **0.0013101 BPM at
397 BPM** (relative 3.3e-6), and inside the musical range 60…200 it is 0.000314
BPM at 196.5.

This is **not a correction to D2** — D2's claim is true as stated and as verified.
It is the other direction, which nothing in the chain had measured. Three
consequences, all of which belong in the report and the docs rather than in a
policy change:

1. **It moves zero notes.** Per the spine, note positions are tick-affine; this
   is a playback-SPEED error only. At the worst relative error it is **0.198 ms
   of drift per minute of music**, ~1 ms across a five-minute song.
2. `round` is still the right rule — it is what makes the error 3.3e-6 instead of
   6.6e-6, and it is what D2 already promised k4 would emit.
3. The report carries `maxTempoRoundTripErrorBPM` so the number is visible rather
   than folklore. On a project whose tempos happen to be exact (120, 60, 100, 96,
   150…) it is 0.0 and pushes no `degradations` line.

---

## 2. The tick math

### 2.1 The conversion (metrical)

```
tick(beat)   = Int((beat * Double(t)).rounded())                        // X1
```

`Double.rounded()` is half-away-from-zero; beats are non-negative everywhere in
the model (`Clip.init` floors `startBeat` at 0 — `Model.swift:608`; `MIDINote.init`
floors `startBeat` at 0 — `:130`), so it is half-UP and `floor` ≡ `trunc`
throughout. Say that in the gate rather than pretending the leg separates them.

Precision is not a hazard at this scale: `beat * 9600` is exact in `Double` while
the product stays under 2⁵³, i.e. for beats below **7.5e12** (Appendix A.4) —
seven orders past the VLQ ceiling that refuses first.

### 2.2 The SMPTE inverse

Implemented for totality and unit-tested, **unreachable from the wire**:

```
tick(beat) = Int((tempoMap.seconds(fromBeatZeroTo: beat) * ticksPerSecond).rounded())
```

`ticksPerSecond` is already computed and stored by the existing `init`
(`StandardMIDIFileMapper.swift:210-215`, including the `29 → 30000/1001`
drop-frame rule). Export never constructs an absolute clock: `MIDIExportOptions`
carries an `SMFDivision` built from a validated `1…32767` Int, so there is no
`division: "smpte"` on the wire to reach it. It is live, tested code rather than
dead code because §9.2's clock unit tests exercise it directly.

### 2.3 Note length — the rule that REVERSES, with the measurement

```
noteTicks(startBeat:lengthBeats:) -> (tick, lengthTicks)
    tick        = ticks(beat: startBeat)
    lengthTicks = ticks(beat: startBeat + lengthBeats) - tick            // X2
```

**X2 is endpoint subtraction, which k3's R3 explicitly forbids on import.** The
inversion is correct and it is measured (M7, Appendix A.5), at t = 9600 over
200,000 random `(start, length)` pairs:

| | endpoint form (X2) | independent form `round(len·t)` |
|---|---|---|
| the two disagree | **49,863 of 200,000 (24.9 %)** | — |
| worst error in the note's END position | **4.1667e-4 beats** (½ tick, at t=1200 in the run) | 8.3170e-4 beats (a full tick) |
| worst error in the LENGTH itself | 8.3250e-4 | 4.1667e-4 |
| **flush legato preserved** (note-off tick == next note-on tick) | **50,000 of 50,000 (100 %)** | 37,580 of 50,000 — **broken in 24.84 %** |

The legato row is the decisive one and it is not merely aesthetic: a note-off
landing one tick *after* the next same-pitch note-on turns a flush pair into an
overlap, which D-FLATTEN would then truncate on a subsequent export — a lossy
edit introduced by a rounding choice. The independent form optimises the wrong
quantity (the length, which nobody hears directly) at the cost of the right one
(the end position, which every adjacent note hears).

**Minimum length is the MAPPER's policy, not the clock's.** `MIDINote.minLengthBeats`
is 0.001, so at t = 9600 a minimum-length note is 9.6 ticks and never degenerates;
but `lengthBeats` is a `Double` the store clamps only at the floor, and a caller
may hand in exactly 0.001 at a low `division` (at t = 96 that is 0.096 ticks → 0).
The mapper applies `max(1, lengthTicks)` and counts it as
`notesWidenedToOneTick`. Two things to state so it is not mistaken for a writer
requirement: **k2 ACCEPTS `lengthTicks == 0`** (it has a dedicated
`Rank.zeroLengthNoteOff` rung, `StandardMIDIFileWriter.swift:484`), so this floor
is a deliberate choice to avoid handing the *importer* an H6c degradation on the
way back, not a constraint the encoder imposes. And the floor lives in the mapper
so the clock stays pure arithmetic.

### 2.4 ONE HOME — what the mechanism buys, exactly

Added to `SMFTickClock` (`StandardMIDIFileMapper.swift`, same file, forced by
`private let kind`):

```swift
public var division: SMFDivision { get }                     // for building the IR
public func ticks(beat: Double) -> Int                       // X1 / §2.2
public func noteTicks(startBeat: Double,
                      lengthBeats: Double) -> (tick: Int, lengthTicks: Int)   // X2
```

- **There is no `lengthTicks(_:)` entry point.** A caller who wants a length gets
  it with its onset or not at all, so `round(lengthBeats · t)` has no API to be
  written through. This is k3's `metricalLength` move with the hidden parameter
  swapped: k3 hides `tick` from the branch that must not use it; k4a hides
  `lengthBeats` from the branch that must not round it.
- **The export mapper never holds an `Int` ticks-per-quarter.** `MIDIExportOptions`
  carries `division: SMFDivision`, constructed once at the store boundary from the
  validated wire Int, and the mapper reads `clock.division` to build the IR's
  header. Multiplying by hand requires destructuring an enum for no other reason.
- **What it does NOT buy** (stated so a later reader does not over-trust it):
  this is not unrepresentability in the `ResolvedDropBeat` sense. `SMFDivision` is
  public and destructurable. The guarantee is that the natural implementation is
  the only available one, backed by gate leg **G-M1**.

---

## 3. Flattening a DAW track into one MIDI track

### 3.1 The event stream

For each exported track, in project order, over its clips **sorted by
`(startBeat, id.uuidString)`** (a total order — clips may share a `startBeat`):

```
for clip in track.clips where clip.isMIDI:
    for note in clip.notes ?? []:
        absStart = clip.startBeat + note.startBeat
        (tick, lengthTicks) = clock.noteTicks(startBeat: absStart,
                                              lengthBeats: note.lengthBeats)
        emit SMFNote(tick:, lengthTicks: max(1, lengthTicks), note: note.pitch,
                     velocity: note.velocity, releaseVelocity: 64, channel: ch)
    for lane in clip.controllerLanes:
        for point in lane.points:
            emit SMFControllerEvent(tick: clock.ticks(beat: clip.startBeat + point.beat),
                                    channel: ch, type: lane.type, value: point.value)
```

Then sort notes by `(tick, channel, note)` — the IR's stated contract
(`StandardMIDIFile.swift:205-207`) — and controllers by `(tick, type.sortKey, value)`.
k2's own sort key is total, so output bytes do not depend on this; the IR does,
and a faithful IR is what the fixtures compare against.

**`releaseVelocity: 64`** is the one value invented rather than read: `MIDINote`
has no release-velocity field (k3's H5b), and 64 is the conventional "no
information" value that k3's own H5b exemption treats as carrying none — so a
k3-imported note round-trips through k4a without minting a
`notesWithDroppedReleaseVelocity` entry on the way back. Not reported (it would
fire on every file and be noise — the G9 lesson).

**Non-MIDI clips on an instrument track** (an audio clip parked on an instrument
track) contribute nothing and are counted in `audioClipsSkipped`.

### 3.2 Same-pitch overlap — the one place the FORMAT forces a change

`Model.swift:100-102` is explicit that "overlapping notes on the same pitch are
legal (the M3 scheduler resolves them)". SMF cannot express that: two note-ons on
one pitch/channel with no intervening note-off have no unambiguous pairing, and
k1's reader pairs FIFO, so a nested pair (A: 0…4, B: 1…2) comes back with the two
lengths **swapped**. Silent musical corruption in a file that opens everywhere —
the exact hazard `SMFEncodeError`'s doc comment says an encoder must refuse to
create.

**Rule.** Per `(channel, pitch)`, walk the flattened onsets in tick order,
carrying the currently-sounding note:
- if the next onset's tick is **strictly inside** the current note, truncate the
  current note to end at that tick and count `overlappingSamePitchNotesTruncated`;
- if truncation leaves `lengthTicks <= 0` (identical or contained-at-the-same-tick
  onsets), **drop** the earlier note and count
  `overlappingSamePitchNotesDropped`;
- an onset exactly at the current note's end is **flush, not overlapping** — leave
  both alone. k2's `Rank` ladder emits note-off (1) before note-on (3) at an equal
  tick, so the pair re-imports as two notes.

The truncation round-trips exactly, which is why it beats emitting the nested
pair. Both counters push one `degradations` sentence when non-zero.

### 3.3 What is NOT baked in

| Model field | Export behaviour | Report |
|---|---|---|
| `Clip.gainDb`, `Clip.gainEnvelope`, `fadeInBeats`/`fadeOutBeats` | not folded into velocity | `clipsWithGainNotExported` (count) |
| `Clip.stretchRatio`, `pitchShiftSemitones`, `formantPreserve` | ignored | `clipsWithStretchNotExported` (count) |
| `Track.volume`, `pan`, `effects`, `sends`, `automation` | never emitted (no CC 7/CC 10 synthesis) | not reported — mixer state is not MIDI content, and a per-project counter would fire on every project |
| `Track.isMuted` / `isSoloed` | exported anyway (D-MIX) | `mutedTracksExported`, `soloedTracksPresent` |
| `Clip.takeGroupID` | irrelevant — materialised comp clips are ordinary `clips` and export like any other | — |

Baking gain into velocity is a musical judgement with no inverse (a re-import
could never separate authored velocity from applied gain) and it would make
export non-idempotent. **There is no per-clip mute in the model** — `Clip` has no
`isMuted` field (`Model.swift:456-542`) — so "muted clips" is a decision this
item does not have to make; said explicitly so a later reader does not go looking
for the rule.

### 3.4 The rule I deliberately did NOT apply, and why

`Sources/DAWEngine/MIDISchedule.swift` windows every clip at playback:

```
:145   guard note.startBeat < clip.lengthBeats else { continue }    // [0, clipLen)
:149   let offBeat = clip.startBeat + min(note.endBeat, clip.lengthBeats)
:183   guard point.beat < clip.lengthBeats else { continue }        // [0, clipLen)
```

Mirroring it would make export "what you hear". **Rejected, on three grounds:**

1. **It breaks the round trip on clips k3 itself produces.** `clip.importMIDI`
   deliberately imports content past the clip end and reports
   `notesPastClipEnd` rather than trimming, so that the caller can compose with
   `clip.fitToContent` (`ProjectStore+MIDIFile.swift:108-118`). A windowing
   export would silently delete exactly that content. The discriminating question
   — *does a clip produced by `clip.importMIDI` with `notesPastClipEnd > 0`
   survive `track.exportMIDI` → `project.importMIDI` with the same notes?* — is
   NO under windowing and YES under as-authored.
2. **It contradicts the item's own naming argument.** The roadmap line justifies
   `project.exportMIDI` over `render.exportMIDI` on the ground that every
   `render.*` command runs the engine while this one "touches no engine at all,
   it serialises the model". Applying the engine's audibility window makes it a
   partial render under a name that promises it is not.
3. **It collides with D-MIX with no surviving discriminator.** A muted track is
   inaudible and we export it; a note past a clip end is inaudible and we would
   not. Same class, opposite verdicts.

**And it dissolves a ONE-HOME problem rather than creating one:** the windowing
rule lives in DAWEngine, which DAWCore cannot import, so mirroring it would mint
a second computation of a playback rule in a module that has no business knowing
it. Not applying it means there is no second computation and zero DAWEngine
changes. The loss is reported, using k3's field names verbatim, which is what
makes the two halves of the round trip legible as one story.

---

## 4. File shape

### 4.1 Header and chunks

```
MThd  format 1 (default; 0 on request), ntrks = 1 + exported track count,
      division = the caller's tpqn (metrical ALWAYS — export never emits SMPTE)
MTrk 0  conductor: FF 03 <project name>, the whole tempo map, the whole meter map,
        FF 2F at the song end
MTrk i  one per exported instrument track, in project order
```

The conductor is emitted **unconditionally**, including for a default 120 BPM /
4/4 project. k2's P1 routes hoisted events by `sourceTrackIndex`, so every
`SMFTempoEvent` and `SMFTimeSignatureEvent` k4a builds carries
`sourceTrackIndex: 0`.

`format: 0` is honoured (k2's `SMFWriteOptions.format` override merges via
P7/P8/P9) with one reported consequence: the merged chunk keeps only the first
non-nil name (`StandardMIDIFileWriter.swift:541`), so individual track names are
lost — `trackNamesLostToFormat0` counts them. Because D-PROGRAM gives each track
its own channel, a format-0 export still re-imports as separate parts through
k3's channel split, up to 16 tracks.

### 4.2 The conductor's payload

```
tempo:  for seg in transport.tempoMap.segments:
            SMFTempoEvent(tick: clock.ticks(beat: seg.startBeat),
                          microsecondsPerQuarterNote: Int((60_000_000.0 / seg.bpm).rounded()),
                          sourceTrackIndex: 0)
meter:  for ch in transport.meterMap.changes:
            SMFTimeSignatureEvent(tick: clock.ticks(beat: ch.startBeat),
                                  numerator: ch.beatsPerBar,           // VERBATIM (k3 §1.3)
                                  denominatorPower: log2(ch.beatUnit),  // VERBATIM
                                  clocksPerMetronomeClick: 24,
                                  thirtySecondNotesPerQuarter: 8,
                                  sourceTrackIndex: 0)
```

Four guards, each with a stated reachability:

| Guard | Verdict | Reachable? |
|---|---|---|
| `bpm` outside 20…400 | **impossible** — `TempoMap.Segment.init` clamps (`TempoMap.swift:41`), so µ ∈ [150000, 3000000] ⊂ k2's legal [1, 0xFFFFFF] | no. Stated, not coded, and NOT given a report field (a field that can never fire is worse than none — k3's H6a lesson) |
| two segments rounding to the SAME tick | **warn**, first wins | **YES.** `TempoMap.init` requires strictly increasing `startBeat` with **no minimum gap** (`TempoMap.swift:80`), so two segments 1e-6 beats apart both land on tick 0. k3's H3 keeps the first on the way back; report `tempoSegmentsCollidingAtSameTick: [String]` naming beat, tick and both BPMs |
| `beatUnit` not a power of two, or its power > 255, or `beatsPerBar` outside 1…255 | **warn** (drop the change) | **YES.** `MeterMap.Change.init` applies only `max(1, …)` (`TempoMap.swift:356-357`) and `parseMeterMap` takes the wire's pair verbatim, so `beatsPerBar: 300` and `beatUnit: 5` are both reachable over the control port. Report `droppedMeterChanges: [String]` with the cause |
| **change 0 dropped by the rule above** | substitute 4/4 at tick 0 and report | consequence of the row above. The file must carry a meter at tick 0; the SMF default is the only honest substitute, and it is reported (`substitutedDefaultMeterAtZero`) — the mirror of k3's H4b |
| meter changes colliding on one tick | **impossible** | `MeterMap.init` requires each change on a barline of the accumulated meter, so the minimum gap is one bar — over 9600 ticks. No field |

`clocksPerMetronomeClick: 24` and `thirtySecondNotesPerQuarter: 8` are the
universal defaults, and they are what DAW Pro has to say: the model carries no
metronome-subdivision quantity to source anything else from. That is the same v1
limitation `docs/ARCHITECTURE.md` §8 entry 2 already records; export does not
paper over it.

### 4.3 Channels and program change

```
next = 0
for each exported track:
    if track.instrument?.soundBank?.bankMSB == GMProgramCatalog.percussionBankMSB { ch = 9 }
    else { ch = nextNonDrumChannel(&next) }          // 0..8, 10..15, then wrap
```

`nextNonDrumChannel` walks `0,1,…,8,10,…,15` and wraps to 0, counting
`channelsWrapped`. A wrapped channel is harmless in format 1 (each track is its
own chunk and k3 re-imports by `(sourceTrackIndex, channel)`), and matters only
in a single-synth player — which is what the report line says.

Program change: set **on the IR only** (never on the bytes — see immediately
below) **iff** `kind == .soundBank && soundBank.source == .generalMIDI`, as one
`SMFProgramChangeEvent(tick: 0, channel: ch, program: soundBank.program)`.

**One k1 fact the implementer must not trip over:** `SMFTrack.programChanges` is
a stored property k3 added, and `StandardMIDIFileWriter` — byte-frozen at k2 —
**does not read it**. k3's Step 0 called this out explicitly ("k4 must either
emit `0xC0` events from `SMFTrack.programChanges` or state the drop in its own
report"). k4a must NOT reopen the writer. Two options, and the design picks the
second:

- ~~extend k2 to emit `0xC0` from `programChanges`~~ — touches a byte-frozen file
  whose 55 tests pin its output;
- **emit the program change as an ordinary event the writer already knows how to
  write.** It cannot: `Cn` is not in `MIDIControllerType`. So k4a's honest
  position is: **`project.exportMIDI` sets `SMFTrack.programChanges` on the IR it
  builds (so the IR is complete and the report is truthful), and the bytes k2
  writes do not contain them.** The report says so in a typed field
  (`programChangesNotWritten: Int`) and a `degradations` line, and the roadmap
  line for a k2 follow-up carries the fix.

**This is a real, user-visible gap and it must not be smuggled through.** It is
called out again in §13 as the first thing the user may want re-ordered: making
program change actually land requires one additive change to a byte-frozen
encoder (a new `Rank` rung between `meta` and `noteOff`, plus a `programChanges`
loop in `buildPart`), which is a small, well-understood edit but is **k2's file**,
and this design does not authorise it unilaterally.

---

## 5. The report

```swift
public struct MIDIExportReport: Codable, Sendable, Equatable {
    // --- what was written
    public var path: String                  // the path written, or WOULD be, on a dryRun
    public var written: Bool                 // false on a dryRun
    public var byteCount: Int
    public var format: Int                   // 0 | 1
    public var ticksPerQuarterNote: Int
    public var divisionDescription: String   // SMFTickClock.divisionDescription, reused

    // --- per-track ledger; index space = the PROJECT's track order, INCLUDING skipped
    public struct Track: Codable, Sendable, Equatable {
        public var index: Int
        public var name: String
        public var trackID: UUID             // wire key `trackId`
        public var kind: String              // "instrument" | "audio" | "bus"
        public var channel: Int?             // 0-based; nil when skipped
        public var chunkIndex: Int?          // MTrk index in the file; nil when skipped
        public var noteCount: Int
        public var controllerLanes: [String] // wireKeys actually written
        public var program: Int?             // THIS TRACK'S GM program, nil if not a GM sound bank.
                                             // NOT "what the file says": in k4a the file contains no
                                             // `Cn` at all (§4.3). Every non-nil `program` here is
                                             // also counted in `programChangesNotWritten` below.
        public var programName: String?      // GMProgramCatalog.name(forProgram:), same caveat
        public var isMuted: Bool
        public var exported: Bool
        public var skipReason: String?
    }
    public var tracks: [Track]

    // --- what landed
    public var tracksExported: Int
    public var notesExported: Int
    public var controllerPointsExported: Int
    public var tempoSegmentsWritten: Int
    public var meterChangesWritten: Int
    public var endTick: Int
    public var endBeat: Double

    // --- the losses. Each ZERO/empty on a clean project (gate leg G9)
    public var notesQuantized: Int                          // moved by > beatEpsilon
    public var controllerPointsQuantized: Int
    public var maxQuantizationErrorBeats: Double            // 0 when nothing moved
    public var maxQuantizationErrorMs: Double               // at the tempo in force there
    public var maxTempoRoundTripErrorBPM: Double            // §1.3
    public var notesWidenedToOneTick: Int                   // §2.3
    public var overlappingSamePitchNotesTruncated: Int      // §3.2
    public var overlappingSamePitchNotesDropped: Int        // §3.2
    public var notesPastClipEnd: Int                        // k3's name, verbatim (§3.4)
    public var controllerPointsPastClipEnd: Int             // k3's name, verbatim
    public var clipsWithGainNotExported: Int                // §3.3
    public var clipsWithStretchNotExported: Int             // §3.3
    public var audioClipsSkipped: Int                       // §3.1
    public var droppedMeterChanges: [String]                // §4.2
    public var tempoSegmentsCollidingAtSameTick: [String]   // §4.2
    public var substitutedDefaultMeterAtZero: Bool          // §4.2
    public var programChangesNotWritten: Int                // §4.3 — the k2 gap
    public var channelsWrapped: Int                         // §4.3
    public var trackNamesLostToFormat0: Int                 // §4.1
    public var mutedTracksExported: [String]                // D-MIX (names)
    public var soloedTracksPresent: Bool                    // D-MIX

    // --- the one prose channel
    public var degradations: [String]
}
```

**Rules carried over from k3's §5 without change:**

- every `[String]` field is **capped at 32 entries** with a trailing
  `"… and N more"`; the typed counts stay exact;
- `degradations` is the human roll-up the UI and copilot read; the typed fields
  are what a test asserts on;
- **informational facts are not degradations.** `soloedTracksPresent`,
  `mutedTracksExported` and `notesPastClipEnd` state facts about the project;
  they do not push a `degradations` line, so a clean export of a project that
  merely has a soloed track still satisfies G9;
- **a clean project produces an all-zero/empty loss section and
  `degradations == []`, with no exemption.** Gate leg G9.

`beatEpsilon = 1e-9` is declared on the export mapper with a comment stating that
it is the same magnitude as `MeterMap.barlineEpsilon` **deliberately and
separately**: that constant is `private` (`TempoMap.swift:375`) and means
"tolerance for a barline test", a different question. Two concepts that share a
value are not one constant with two homes — and copying a private constant is
exactly what k3's §2.4 refused to do.

---

## 6. Wire shape

Both commands are **appended at the END** of `allCommands` (measured today with
the house recipe: **156** entries, tail `note.audition, track.reorder,
project.importMIDI, clip.importMIDI` → **158**). No live command is renamed or
reordered. MCP twins carry **no `daw_` prefix** and are the snake_case mirror:
`project_export_midi`, `track_export_midi` (**159 → 161**), preserving the
`audit-tools` bijection.

### 6.1 `project.exportMIDI`

```
params:
  path      string   optional  destination; omitted -> a unique file under
                               NSTemporaryDirectory()/DAWPro/ (the renderBounce policy);
                               `~` expands; ".mid" appended unless already present
                               (case-insensitive); parents created; OVERWRITES an
                               existing file (the caller chose the path)
  trackIds  array    optional  which tracks; omitted = every track, in project order.
                               Non-instrument tracks in the selection are SKIPPED and
                               reported, never an error (D-AUDIO)
  division  number   optional  ticks per quarter note, 1...32767, default 9600
  format    number   optional  0 | 1, default 1
  dryRun    bool     optional  default false — full report, NOTHING written

returns: { "report": <MIDIExportReport>, "written": bool }
```

`rejectUnknownKeys(["path","trackIds","division","format","dryRun"], verb: "project.exportMIDI")`
— the F5 hardening rule; a typo'd `tracks` or `ppq` must never masquerade as an
accepted default.

### 6.2 `track.exportMIDI`

```
params:
  trackId   string   REQUIRED  an instrument track
  path      string   optional  as above
  division  number   optional  as above
  format    number   optional  as above
  dryRun    bool     optional  as above

returns: { "report": <MIDIExportReport>, "written": bool }
```

Identical file shape to `project.exportMIDI` with `trackIds: [thatOne]` — a
conductor chunk plus one track chunk — so the two commands differ only in
selection, and a single implementation serves both.

### 6.3 Error surface

| Condition | Error |
|---|---|
| `path` not absolute after `~` expansion | `ControlError("'path' must be an absolute path")` |
| `division` outside 1…32767 | `ControlError` naming the field and the range (the iv-d contract-range idiom) |
| `format` not 0 or 1 | `ControlError` listing the legal values |
| unknown `trackId` / an id in `trackIds` | `ProjectError.trackNotFound(id)` |
| `track.exportMIDI` on a non-instrument track | new `MIDIExportError.notAnInstrumentTrack(name:kind:)` |
| the project (or selection) has **no instrument track at all** | new `MIDIExportError.nothingToExport(contained:)`, naming what it DID find |
| content past the VLQ ceiling | new `MIDIExportError.contentTooFarFromStart(beat:limitBeats:division:)` — pre-checked as `maxTick <= 0x0FFFFFFF`, which is conservative-and-correct because every delta is a difference of ticks in `[0, maxTick]`. At 9600 the limit is **beat 27962.0** (M10). The message names a lower `division` as the escape |
| the write fails | new `MIDIExportError.writeFailed(path:reason:)` |
| any `SMFEncodeError` | surfaced **verbatim** — k2's messages are already teaching-grade, and k3 set the precedent for `SMFDecodeError` |

**`dryRun` returns BEFORE the `nothingToExport` refusal**, matching
`importMIDIFile`'s order (`ProjectStore+MIDIFile.swift:68-71`): the whole point of
a dry run is to find out.

**No transport guard, and the asymmetry is deliberate.** k3's D1″ refuses import
while recording because import MUTATES and folds tempo adoption inside its own
`performEdit`. Export mutates nothing, opens no `performEdit`, and leaves no
journal entry, so there is no half-state to protect and nothing to explain.

---

## 7. Implementation plan

Ordered so each step is independently testable.

### Step 1 — extend `SMFTickClock` (the ONE home)

`/Users/dsemenov/Views/daw-pro/Sources/DAWCore/StandardMIDIFileMapper.swift`

Add `division`, `ticks(beat:)` and `noteTicks(startBeat:lengthBeats:)` per §2.4,
**in this file** (forced by `private let kind`). Do not add a length-only entry
point. Carry the doc comments that say why `noteTicks` returns a pair and why the
metrical/absolute split is the clock's business and not the caller's — the k3
comments at `:255-289` are the model.

Nothing else in this file changes. `MIDIImportReport`, `MIDIImportPlan` and
`SMFProjectMapper` are untouched; the discriminator that this step is safe is
that **every existing test in `Tests/DAWCoreTests/StandardMIDIFileMapperTests.swift`
and the k3 import suites passes unchanged, with no edits to those files.**

### Step 2 — the export mapper (pure, headless, store-free)

New file: `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectMIDIExportMapper.swift`

```swift
public struct MIDIExportOptions: Sendable, Equatable {
    public var division: SMFDivision          // built from the validated wire Int
    public var format: SMFFormat
    public var trackIDs: [UUID]?
    public static let defaultTicksPerQuarterNote = 9600
}
public struct MIDIExportPlan: Sendable, Equatable {
    public let file: StandardMIDIFile
    public let report: MIDIExportReport
    fileprivate init(...)                     // the MIDIImportPlan mechanism, verbatim
}
public enum SMFProjectExporter {
    public static func map(tracks: [Track], projectName: String,
                           tempoMap: TempoMap, meterMap: MeterMap,
                           options: MIDIExportOptions) throws -> MIDIExportPlan
}
```

`fileprivate init` suppresses the synthesized memberwise initializer, so
`SMFProjectExporter.map` is the only producer and the store is typed to consume
one. **`MIDIExportPlan` must NEVER conform to `Codable`** — a public `Codable`
struct synthesizes a public `init(from:)`, a second producer no `fileprivate` can
stop (k3's V.4.4). If a snapshot ever needs to show a plan, encode the `report`,
which IS `Codable`.

Everything in §1–§4 lives here. It touches no store, no engine, and no
`Foundation` beyond `Data`/`UUID`. Every verdict is unit-testable with no
`ProjectStore`.

### Step 3 — the store methods

`/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore+MIDIFile.swift`
(the existing MIDI-file extension — this is its other half)

```swift
@discardableResult
public func exportMIDIFile(path: String? = nil, trackIDs: [UUID]? = nil,
                           ticksPerQuarterNote: Int = MIDIExportOptions.defaultTicksPerQuarterNote,
                           format: Int = 1, dryRun: Bool = false) throws -> MIDIExportReport

@discardableResult
public func exportTrackMIDIFile(trackID: UUID, path: String? = nil,
                                ticksPerQuarterNote: Int = MIDIExportOptions.defaultTicksPerQuarterNote,
                                format: Int = 1, dryRun: Bool = false) throws -> MIDIExportReport
```

Body shape:

1. Validate `ticksPerQuarterNote` and `format`; resolve `trackIDs` (unknown id →
   `trackNotFound`; for the single-track verb, `kind != .instrument` →
   `notAnInstrumentTrack`).
2. `SMFProjectExporter.map(...)`.
3. `if dryRun { return plan.report }` — **no file, no `performEdit`, no journal
   entry, no engine call.**
4. `nothingToExport` refusal (after the dry-run return).
5. Resolve the destination (`Self.midiExportDestination(from:)`, modelled on
   `ProjectStore+Render.swift:274-285`), `createDirectory(withIntermediateDirectories:)`
   for the parent, then `try StandardMIDIFileWriter.write(plan.file, to: url,
   options: SMFWriteOptions(format: ...))` — which is already atomic
   (`StandardMIDIFileWriter.swift:429-432`).
6. Return the report with `path`, `written: true` and `byteCount` filled in.

**No `performEdit` anywhere in this step.** Export is a read; a `performEdit` that
mutates nothing but appends an undo entry is exactly the bug gate leg G7 exists
for.

### Step 4 — the wire

`/Users/dsemenov/Views/daw-pro/Sources/DAWControl/Commands.swift`: two `case`
blocks with the full teaching comment block each command in this file carries,
`rejectUnknownKeys` first, and the two names **appended at the end** of
`allCommands` (156 → 158). Response `{report, written}` via
`try JSONValue(encoding: report)` — the `project.importMIDI` shape.

### Step 5 — MCP

`/Users/dsemenov/Views/daw-pro/mcp-server/src/server.ts`: `project_export_midi`
and `track_export_midi` (159 → 161). Descriptions must name **the default
division and why it is 9600**, the `dryRun` workflow, and the fact that muted
tracks are exported — an agent that does not know the last one will re-implement
mute filtering client-side. The `audit-tools` bijection test must stay green.

### Step 6 — fixtures and tests (§9)

### Step 7 — docs

- `docs/ROADMAP.md`: tick `m23-k4a`, close-out record with a SHA-256 pin for the
  new fixture — **by the orchestrator, not the implementing agent.**
- `CHANGELOG.md`: **edit the existing `## In progress — MIDI file support (.mid)`
  block and tick its box; do NOT add a dated entry** (the convention set at k1).
- `docs/ARCHITECTURE.md`: the §10 entries below.
- `Tests/DAWCoreTests/Fixtures/SMF/README.md`: the new fixture row, with the
  "Apple-confirmed / spec-asserted" column filled in **honestly** — see §9.3.

---

## 8. The gate

Every leg names the specific mutation that reddens it. A leg with no
discriminator is vacuous, and this chain has now shipped three of those.

### 8.1 Legs

| # | Leg | DISCRIMINATOR — the mutation that reddens it |
|---|---|---|
| **G1** *(the headline; replaces the roadmap's vacuous round-trip leg)* | Author a clip with notes at beats **1.00006** and **1.00001** (plus ordinary on-grid notes), export at `division: 9600`, re-import, assert the two beats come back as `Double(9601)/Double(9600)` and `Double(9600)/Double(9600)` — **written as those expressions, never as decimal literals, and never computed via the formula under test.** | Change `ticks(beat:)` to `floor`: beat 1.00006 comes back `1.0` instead of `9601/9600`. Change it to `ceil`: beat 1.00001 comes back `9601/9600` instead of `1.0`. **`floor` and `trunc` are provably indistinguishable at non-negative beats — stated as an honest limit of the leg, not a gap.** The roadmap's original leg ("re-imports with the same notes") passes under all four rules on every fixture in the repo, because their beats are exact integer multiples of the division. |
| **G2** | **Flush legato survives.** Two same-pitch notes, the second starting exactly where the first ends, at an OFF-GRID boundary (e.g. start 0.30007, length 0.70003): assert the exported note-off tick **equals** the next note-on tick, and that a re-import returns two notes with the same boundary. | Change `noteTicks` to independently-rounded lengths (`round(lengthBeats·t)`). **Measured: that breaks the boundary on 24.84 % of random legato pairs** (M7) — but only at off-grid positions, so the leg MUST use an off-grid boundary or it is vacuous. This is the direct mirror of k3's G2, which had to move from a dyadic to a triplet length for the same reason. |
| **G3** | **Same-pitch overlap.** A clip with notes (pitch 60, 0…4) and (pitch 60, 1…2): assert `overlappingSamePitchNotesTruncated == 1`, and that a re-import returns lengths **1.0 and 1.0** — not the swapped 2/3 pair that a nested emission produces. | Remove the truncation and emit the nested pair: the file still loads (Apple accepts it), but the re-imported lengths swap. A leg that only asserted "two notes come back" would pass the broken implementation. |
| **G4** | **µs/quarter rounding.** A two-segment tempo map at **61 BPM** and **104 BPM**: assert the emitted `microsecondsPerQuarterNote` values are **983607** and **576923**. | 61 BPM has `60e6/bpm = 983606.557`, so `floor`/`trunc` give 983606; 104 BPM has `576923.077`, so `ceil` gives 576924. **The obvious leg — the k3 spine value 666666 — is VACUOUS: `60e6/(60e6/666666)` computes to exactly 666666.0, so all four rules agree** (M6). Both tempos are needed; either alone leaves one rule alive. |
| **G5** | **D2's inherited exactness, in the direction export runs.** Sample µ over `150000…3000000` and assert `Int((60e6/(60e6/Double(µ))).rounded()) == µ`, **including µ = 2,807,175 as a NAMED input** (k3's measured worst case, 4.65661e-10). Separately assert `maxTempoRoundTripErrorBPM` is **> 0** for a 140 BPM project and **== 0** for a 120 BPM project. | Sample, do not exhaust — 2.85 M iterations in a debug build costs seconds and would be mistaken for the known `EQCurveEditorModelTests` perf flake. The second half is the discriminator for §1.3: an implementation that reports 0 unconditionally passes the first half. |
| **G6** | **The conductor and the round trip of tempo + meter.** Export a project with a 2-segment tempo map and a 3-change meter map; assert chunk 0 carries all of them and no notes; re-import with `tempoPolicy: "adopt"` into an empty project and assert the maps come back **equal** (6/8 stays `(6, 8)`). | Emit the meter translated (`beatsPerBar = numerator·4/denominator`): 6/8 comes back as `(3, 8)` or `(12, 8)`. This is k3's §1.3 reversal, gated from the other side — and it is the leg that proves export is the identity of import for meter. |
| **G7** | **`dryRun` is inert.** Identical `report` (modulo `written`, `path`, `byteCount`), **no file on disk at the reported path**, and `store.undoHistory().undo` an **IDENTICAL label list** before and after. | A `performEdit` that runs and mutates nothing still appends a journal entry. A `project.snapshot` comparison does NOT observe the journal — `undoHistory()` (`ProjectStore.swift:146`, `UndoJournal.swift:115`; on the wire `edit.history`) is the seam that does. k3 paid for this lesson once. |
| **G8** | **Apple's loader accepts what we write.** For the whole-project export of the fixture project, `MusicSequenceFileLoad` returns `noErr`, reports the expected track count, and returns notes at the expected beats with the expected durations. | Run OUTSIDE the build (LAW L9: `AudioToolbox` never enters `Sources/DAWCore`), as a checked-in validator script under `scripts/`. It is the third-party arbiter of the bytes; a round trip through our own reader alone would pass a mirrored encoder/decoder bug — k2's own doc comment on why it is not gated by a round trip. **The harness used for this design is in Appendix B and was verified against `apple-type1.mid`**, where it reproduces k3's G4 expectations exactly (notes at 0/1/2/3, durations 0.5, tempo 120 then 90.00009000009 at beat 4). |
| **G9** | **Vacuity guard.** A clean project (on-grid notes, 120 BPM, 4/4, no mutes, no overlaps) exports with **every** loss field zero/empty and `degradations == []`, no exemption. | Without it, a mapper that reports something on every project passes every hazard leg and the report becomes noise nobody reads. The fields most likely to break it: `notesPastClipEnd` (must not count a note ending exactly AT the clip end), `maxTempoRoundTripErrorBPM` (must be exactly 0 at 120 BPM), and `notesQuantized` (must use `beatEpsilon`, not `!= 0`, or FP residue on swung content fires it). **Fixture constraint the implementer must honour, or G9 fails on an ordinary project through no fault of the mapper: the clean-project fixture's tracks must NOT carry GM sound-bank instruments**, because every GM track increments `programChangesNotWritten` (§4.3, the k2 gap) and that is a loss field. Use `polySynth` tracks. This is the same trap as k3's failure-mode 8 (`notesWithDroppedReleaseVelocity` on a file we wrote): a loss field that fires on perfectly ordinary input turns the vacuity guard into a permanently-red leg, and the next agent "fixes" it by exempting the field — which is exactly what the guard exists to prevent. When the k2 follow-up lands and program changes are actually written, this constraint lifts and the fixture may use GM banks. |
| **G10** | **Export is DETERMINISTIC.** Export the same project twice to two paths; assert the two files are **byte-identical**. | Group controller lanes (or tracks, or channels) through a `Dictionary` without sorting. k2's own sort key is total, so the bytes only wobble if the IR's construction order does — which is precisely the bug this catches, and no functional leg catches it. |
| **G11** | **As-authored, not as-heard** (§3.4). A clip with `lengthBeats: 2` carrying a note at `startBeat: 3` and a note at `startBeat: 1, lengthBeats: 4`: assert both survive export at their authored positions and lengths, and that `notesPastClipEnd == 2`. | Apply `MIDISchedule`'s window: the first note vanishes and the second is truncated to end at beat 2. **This is the leg that pins the decision the design most nearly went the other way on**, and it is also the round-trip guarantee for clips `clip.importMIDI` produces. |
| **G12** | **Mix state is exported, not honoured** (D-MIX). A project with one muted and one soloed track: assert **both** are exported, `mutedTracksExported` names the muted one, and `degradations == []`. | Filter on `isMuted`/`isSoloed`. The `degradations == []` half is what keeps the leg honest against an implementation that exports everything but shouts about it. |
| **G13** | **Skips and refusals.** An audio track in a project export produces no chunk and one `exported: false` ledger row with a reason; an **instrument** track with no clips produces an EMPTY chunk with its name; `track.exportMIDI` on an audio track **throws** `notAnInstrumentTrack`; a project with only audio tracks **throws** `nothingToExport`, while the SAME project with `dryRun: true` **succeeds** and reports what it found. | The dry-run half is the conjunction that matters: a leg testing only the refusal passes an implementation that also refuses the dry run, which is the one call whose entire purpose is to find out. k3's G13 shape. |
| **G14** | **Meter guards.** A meter map with `beatUnit: 5` and one with `beatsPerBar: 300` (both reachable over `tempo.setMap`) drop with a cause-naming `droppedMeterChanges` entry; when the dropped change is at beat 0, `substitutedDefaultMeterAtZero == true` and the file carries `FF 58 04 04 02 18 08`. | Silently coercing 5 to 4 (or clamping 300 to 255) produces a file that names a meter the project never held. The at-zero half catches an implementation that drops the change and leaves the file with no meter at tick 0. |
| **G15** | **Tick-ceiling refusal.** A clip parked past beat 27962 at `division: 9600` throws `contentTooFarFromStart` naming the beat and the limit; the same project at `division: 480` **succeeds**. | Let `SMFEncodeError.deltaTimeTooLarge` surface raw: the message speaks in ticks, names no beat and offers no escape. The second half proves the limit is division-dependent and not a project-size cap. |
| **G16** | **The SMPTE witness** (§9.3, D-SMPTE). Build the IR, encode with `StandardMIDIFileWriter.encode`, assert the bytes **equal the checked-in fixture**, then feed the fixture through `StandardMIDIFileReader` + `SMFProjectMapper` and assert `resolvedTempoPolicy == "adopt"`, `tempoAdoptionDegradedToIgnore == true`, `meterChangesAdopted == 1`, and the adopted change is `(3, 4)`. | **The byte-equality assertion is the whole point.** Without it Apple has arbitrated a hand-authored blob and not our writer's output, and the leg witnesses nothing about k4a. If the bytes differ, that difference IS the finding — report it, do not adjust the fixture to match. |
| **G17** | **Wire round-trip on staging.** Both commands over the control port on 17695: response shape, a typo'd `ppq` rejected by `rejectUnknownKeys`, error text for each row of §6.3, and a per-track and whole-project export both read back with `project.importMIDI` on a fresh project. | The roadmap names it. Staging port only — **17600 is the user's live app and is never touched.** |
| **G18** | **Suites + baselines.** Full Swift suite 0-warn on a **FORCED FULL rebuild** (`find Sources Tests -name '*.swift' -print0 \| xargs -0 touch` + the manifest; read SwiftPM's own `[n/N]`, and inject a warning-shaped vacuity probe to prove the gate is not blind); npm suite; wire **156 → 158** proven as an exact-PREFIX extension of HEAD's list; MCP **159 → 161**; `audit-tools` bijection green. | The standing close-out contract. Counts measured today, house recipe, §0.1 M11. |

### 8.2 Mutation legs (the ONE-home law)

| # | Mutation | Must redden |
|---|---|---|
| **G-M1** | Change `noteTicks` to `(ticks(beat: startBeat), Int((lengthBeats·t).rounded()))` | **G2** (flush legato at an off-grid boundary). Nothing else does — G1 and G11 both pass. |
| **G-M2** | Make `MIDIExportPlan.init` internal | the **build** must break. Adding `Codable` to `MIDIExportPlan` is caught by review, not by test, and the reason is written into the type's doc comment. |
| **G-M3** | Compute the quantization error from a formula (`0.5/t`) instead of through `clock.beats(clock.ticks(beat:))` | a project whose notes are all on-grid must report `maxQuantizationErrorBeats == 0`, not `0.5/t`. G9. |
| **G-M4** | Emit the meter translated instead of verbatim | **G6**. |
| **G-M5** | Apply the `MIDISchedule` window | **G11**. |

---

## 9. Fixtures

### 9.1 Existing, and what each serves here

`apple-type1.mid` is the round-trip anchor: import it, export it, re-import, and
assert the notes, the two tempo segments and the absence of any meter map survive.
**Note what it CANNOT gate:** its beats are 0/1/2/3 at length 0.5 and its tempo is
666666 µs/qn, so it discriminates **neither** the beat→tick rule (G1) **nor** the
µ rounding rule (G4). Both of those need the authored fixtures above. The
`encode-*.mid` files remain k2's expected-output pins and are not inputs here.

### 9.2 New — authored in Swift, no bytes

Every leg in §8.1 except G8 and G16 is a `ProjectStore` (or pure-mapper) test with
a hand-built project: on-grid notes, the two off-grid beats, the legato pair, the
same-pitch overlap, the two-segment tempo map, the meter guards, the far-parked
clip. **No new `.mid` byte fixtures are needed for any of them** — the same
scoping k3's V.3.11 applied to mapper cases, for the same reason: these encode
MAPPING decisions, and the input is a project value. Where reachability is itself
the claim, use bytes — which is exactly §9.3.

The clock's own unit tests (Step 1) additionally cover: `ticks(beat:)` on the
metrical and absolute paths; `ticks(beats(tick)) == tick` for a sweep of ticks;
and the pair-return contract.

### 9.3 New byte fixture — `hazard-smpte-meter.mid`, and exactly what it witnesses

**One new byte fixture, because here reachability IS the claim.** k3 left one
conclusion with no third-party arbiter: that a SMPTE-division file's METER
survives import. The shipped set carries no `FF 58` on a SMPTE file.

**Measured during this read (M9). It works.** The fixture: format 1, division
`0xE728` (25 fps × 40 ticks/frame = 1000 ticks/s), chunk 0 = `FF 03 "Conductor"`
+ `FF 51 07 A1 20` (500000 µs/qn) + `FF 58 04 03 02 18 08` (3/4) + end at tick
1000; chunk 1 = `FF 03 "Lead"` + note 60 vel 100 at tick 0 for 1000 ticks
(= 1.0 s = 2.0 beats at 120 BPM, matching the existing `hazard-smpte-division.mid`
expectation). 84 bytes.

Apple's verdict, verbatim from the run in Appendix B:

```
MusicSequenceFileLoad status = 0  (ACCEPTED)
track count (excluding tempo track) = 2
  [tempo] t=-0.0 TEMPO bpm=120.0
  [tempo] t=-0.0 META type=0x58 len=4 payload=03 02 18 08
  [track 0] t=-0.0 META type=0x03 len=9 payload=43 6F 6E 64 75 63 74 6F 72
  [track 1] t=-0.0 META type=0x03 len=4 payload=4C 65 61 64
  [track 1] t=-0.0 NOTE ch=0 pitch=60 vel=100 dur=0.0
```

**What Apple arbitrates, and what it does not — this goes in the fixture README's
"Apple-confirmed / spec-asserted" column verbatim, because getting it wrong is
how a leg drifts into claiming more than it proves:**

- **Apple-confirmed:** the file is a valid SMF; a `0xE728` division does not
  prevent parsing; the `FF 58` payload bytes `03 02 18 08` are present and
  readable. That is the meter half of k3's unwitnessed conclusion, and it is now
  witnessed by bytes a third party read.
- **NOT Apple-confirmed — spec/design-asserted, exactly as before:** any timing.
  **Every timestamp comes back `-0.0` and the note duration `0.0`** — Apple's
  beat-native model collapses SMPTE absolute time, which is k1's "reads it
  degenerately" claim, now measured rather than quoted. The contrast is sharp and
  is itself evidence the harness is sound: run against `apple-type1.mid` the same
  script returns notes at 0.0/1.0/2.0/3.0 with `dur=0.5` and tempo 120 → 90.00009000009
  at beat 4.
- **Therefore the claim "the note lands at 2.0 beats through the project tempo
  map" remains ours alone**, and the report must not imply otherwise.

**The fixture must be produced by OUR writer.** G16 asserts
`StandardMIDIFileWriter.encode(<the IR>) == <the checked-in bytes>`; without that,
Apple validated a hand-authored artifact and not the one k4a ships. The bytes
hand-derived during this read (for the implementer to compare against, NOT to
copy in blind) are:

```
4d546864 00000006 0001 0002 e728
4d54726b 00000021 00 ff03 09 436f6e647563746f72 00 ff5103 07a120 00 ff5804 03021808 8768 ff2f00
4d54726b 00000015 00 ff03 04 4c656164 00 903c64 8768 803c40 00 ff2f00
sha256 f6eea5727a18dc65a8e4ccbf396933e9fc6d2962e072e510ea6fc067642a72a1
```

If our writer's output differs, **the difference is the finding** — record it and
re-flag the leg; do not adjust the fixture to match.

The generator and validator both live under `scripts/` this time rather than in a
session scratchpad — k3 paid for that once when k1's `gen-smf-fixtures.py` and
`validate-smf.swift` had to be rewritten from nothing.

---

## 10. `docs/ARCHITECTURE.md` — "Key future decisions", paste-ready

**APPLIED 2026-07-27** — both entries are now live in `docs/ARCHITECTURE.md`
under "Key future decisions" (the new k4a entry sits immediately after the k3
entry; the amendment is appended to the existing `MeterMap` entry). Kept here
verbatim as the record of what was written and why. Note the scope line: the
architect owns the DECISIONS LOG, the orchestrator owns the ROADMAP CHECKBOX —
this read applied the former and touched none of the latter.

1. **MIDI file export (m23-k4a): SETTLED (2026-07-27; design
   `docs/research/m23-k4a-midi-export-design.md`)** — export inverts k3's spine:
   `tick = round(beat · division)`, no tempo term, metrical division always (the
   wire cannot request SMPTE). The inverse lives **on `SMFTickClock`**, in the
   same file as the forward map, because that type's `private` state makes any
   other home a second copy of the relationship; `noteTicks(startBeat:lengthBeats:)`
   returns the **pair** so an independently-rounded length has no API to be
   written through, and **note lengths are ENDPOINT-SUBTRACTED — the exact rule
   k3's R3 forbids on import** (measured: independent rounding breaks flush
   legato on 24.84 % of off-grid pairs). Default division is **9600 = 2⁷·3·5²**,
   derived not conventional: it is the unique smallest division ≤ 32767 that is
   exact for dyadic subdivisions to 1/128 beat, all triplets and quintuplets,
   **every MPC swing preset `Groove.builtin(named:)` produces**, and content
   native to every common SMF division up to 960 — so a k3-imported file
   re-exports bit-exactly. 480/960 lose swing; 1200/2400 lose 96/192/384/960-native
   content. Off-grid content is **quantized and reported** (worst case 0.026 ms at
   120 BPM), never refused and never auto-re-divided: no division captures
   humanized or recorded material, so auto-selection would fail on exactly the
   input it was invented for. Export is **as-authored, not as-heard**: muted and
   soloed tracks export, and notes past a clip's end export at their authored
   positions and are reported with k3's own `notesPastClipEnd` field name —
   `MIDISchedule`'s playback window is deliberately NOT mirrored, because
   `clip.importMIDI` deliberately creates exactly that content and windowing
   would break the round trip on clips DAW Pro itself produces. The only
   as-authored exception is a FORMAT limit: SMF cannot express nested same-pitch
   note-ons, so the earlier note is truncated to the later's onset and reported.
   Export mutates nothing — no `performEdit`, no journal entry, no engine call,
   and no recording guard (the deliberate asymmetry with k3's D1″).
   **`bpm → µs/qn → bpm` is NOT exact** (352 of 381 integer BPMs in 20…400;
   worst 0.0013101 BPM at 397, ≈ 0.2 ms drift per minute): D2 verified the
   opposite direction, this one is new, it moves zero notes, and it rides the
   report as `maxTempoRoundTripErrorBPM`.

2. **Amendment to the existing entry "`MeterMap` conflates 'the numerator' with
   'quarter notes per bar' — OPEN, found at m23-k3":** m23-k4a exports the
   numerator/denominator pair VERBATIM, so import and export are now mutual
   inverses and the defect is confined to the bar GRID exactly as k3 left it —
   it does not become an export-only behaviour, and fixing the bar-length
   quantity later changes no exported byte.

---

## 11. The two strongest alternatives to the overall shape, and why they lose

**Alternative A — one `render.exportMIDI` that walks the engine's schedule.**
Build the file from `MIDISchedule.buildEvents` output rather than from the model,
so what you export is exactly what you hear, mute and clip windows included. It
reads well and it would need no flattening rules at all.

It loses on three counts. The schedule is in **seconds and sample frames**, so
every note would come back through the tempo map into beats and the spine's
"tempo is not in the loop" guarantee would be gone — every tempo hazard would
become a position hazard. It would put a DAWCore serialiser behind a DAWEngine
dependency, which the module boundary forbids and which would make the whole item
untestable headless. And it breaks the round trip on clips `clip.importMIDI`
itself creates (§3.4). The one thing it buys — WYSIWYG — is delivered instead by
the report, which names every difference between the file and what plays.

**Alternative B — `division: "auto"`, choosing the smallest exact division per
export.** Attractive after M3: for grid content there really is a right answer,
and a search over a ladder is fifteen lines.

It loses because it makes the exported bytes a function of the CONTENT rather
than of the request. Adding one humanized note silently changes the file's
header; two exports of "the same" project produce different files; G10's
byte-determinism leg becomes untestable; and a byte pin becomes impossible.
Meanwhile the value is small, because the derived default (D-DIVISION) already
captures everything DAW Pro's own quantizer and importer can produce — the
residue is septuplets, nonuplets, and material that **no** division captures. The
information an auto-selector would act on is better placed in the report, where
an agent can act on it explicitly with `dryRun` → read → re-export, which is k3's
own answer to the same shape of question.

---

## 12. Failure modes to watch during implementation

1. **Independently-rounded note lengths** — the reflex of anyone who remembers
   k3's R3. Caught by **G2 only**, and only at an off-grid boundary.
2. **Quantization error computed from a formula** rather than through the clock's
   own round trip: the report then lies about clean projects. G9 + G-M3.
3. **Applying `MIDISchedule`'s clip window** because it looks like the obvious
   truth. G11.
4. **A `performEdit` around the export** because every other store method has
   one. G7's journal leg is the only thing that sees it.
5. **`notesPastClipEnd` counting a note that ends exactly AT `clip.lengthBeats`.**
   The engine's own rule is a half-open interval; the report's must be too, or
   G9 fails on every ordinary project.
6. **Grouping lanes or tracks through a `Dictionary`.** Passes every functional
   leg; only G10's byte-determinism catches it.
7. **Forgetting the conductor's `endTick`.** k2 checks `endTick >= lastEventTick`
   **after** the P1 hoist (`StandardMIDIFileWriter.swift:388-397`), so a tempo
   change past the last note throws `endTickBeforeLastEvent` on the conductor
   chunk — which is why §4.1's rule includes the conductor's own last event tick.
8. **Emitting bank-select CCs** from `bankMSB` 121/120. They are AUSampler
   conventions, not GM file conventions.
9. **Reopening `StandardMIDIFileWriter`** to make program change land. It is
   byte-frozen at k2 with 55 tests pinning its output; §4.3 states the gap and
   §13 hands the decision to the user.
10. **`releaseVelocity` other than 64.** Anything else makes a k3 re-import mint
    `notesWithDroppedReleaseVelocity` on a file we wrote, and G9 on the return
    leg fails.
11. **Writing the expected beats in G1 as decimal literals** (`1.0001041666666666`)
    or as `1.00006` recomputed through the same rounding. Both re-open the
    vacuity k3's G1b was rewritten to close.
12. **Assuming `floor` ≠ `trunc` is testable.** It is not, at non-negative beats.
    State it; do not write a leg that pretends otherwise.

---

## 13. Explicitly the USER's call, not mine — with the default I ship meanwhile

1. **Whether program change should actually LAND in the bytes, which requires
   reopening k2.** Today's design builds a complete IR and reports
   `programChangesNotWritten`, because `StandardMIDIFileWriter` is byte-frozen and
   does not emit `0xC0`. Making it land is a small, well-understood additive edit
   to that file (one `Rank` rung, one loop in `buildPart`, and its own byte pin) —
   but it is **k2's file**, its 55 tests pin its output, and this design will not
   authorise touching it unilaterally. **I ship the honest gap.** If the user
   wants exported files to open in another DAW with the right GM instruments, this
   is the one thing standing in the way and it should be its own line (`m23-k4a-i`
   or a k2 amendment), not a rider.
2. **Default division 9600.** Derived and defended (M3/M4), but it is a policy
   number: it trades headroom (3.9 hours of music at 120 BPM instead of 38.8) for
   exactness on swung and re-imported content. A user who works exclusively with
   straight grid material and wants the industry-standard header would set 480 and
   lose nothing they can hear. One-word change; the option is on the wire.
3. **Whether export should honour mute/solo** (D-MIX). I ship as-authored plus a
   report, on the grounds that export serialises the model. A `honourMix: true`
   parameter is purely additive if the user's mental model is "export what I
   hear".
4. **Whether same-pitch overlap should TRUNCATE (my default) or emit the nested
   pair.** Truncation is lossy but round-trips exactly; nesting preserves the
   bytes' intent and comes back with lengths swapped. Every other DAW I know of
   truncates. A `samePitchOverlap: "truncate" | "nest"` param is additive.
5. **Whether the bar-length defect (`docs/ARCHITECTURE.md` §8 entry 2) should be
   fixed before or after this item.** k4a makes export the exact inverse of
   import, so fixing it later changes no exported byte — which is a *reason* to
   land k4a first, not a reason to defer the fix. Restated here only because k3
   raised it and the user has not yet answered.

---

## Appendix A — the measurement programs and their actual output

All arithmetic is IEEE-754 `double`, identical to Swift's `Double`. Swift's
`Double.rounded()` is half-away-from-zero, modelled as
`math.floor(x + 0.5)` for the non-negative values used throughout (Python's
built-in `round` is banker's rounding and is **not** used).

### A.1 Off-grid round-trip error by division (M1, M2)

```python
def rnd(x): return math.floor(x+0.5)
def rt(beat, t): return rnd(beat*t)/t
```
Distributions: 1/16 grid (64 onsets); 8th triplets (48); DAW Pro `swing8:66`
(offset `(2·66/100 − 1)·0.5`, 32 onsets); humanize ±0.02 beat (`seed 20260727`,
64 onsets); free/recorded (uniform on [0,16), 2000 onsets).

```
worst |beat - roundtrip(beat)| in BEATS
set                             96           192           384           480           960          1920          2400          4800         15360
A 1/16 grid              0.000e+00     0.000e+00     0.000e+00     0.000e+00     0.000e+00     0.000e+00     0.000e+00     0.000e+00     0.000e+00
B triplets               0.000e+00     0.000e+00     0.000e+00     0.000e+00     0.000e+00     0.000e+00     0.000e+00     0.000e+00     0.000e+00
C swing8:66              3.750e-03     1.458e-03     1.146e-03     4.167e-04     4.167e-04     1.042e-04     2.220e-16     2.220e-16     2.604e-05
D humanize +-0.02        5.208e-03     2.580e-03     1.282e-03     1.042e-03     4.967e-04     2.513e-04     2.082e-04     1.011e-04     3.172e-05
E free/recorded          5.208e-03     2.604e-03     1.302e-03     1.041e-03     5.206e-04     2.603e-04     2.082e-04     1.041e-04     3.253e-05

  t=480     half-tick = 0.001042 beat = 0.5208 ms @120bpm
  t=960     half-tick = 0.000521 beat = 0.2604 ms @120bpm
  t=9600    half-tick = 0.0000521 beat = 0.02604 ms @120bpm
```

At 9600 over the same humanize and free distributions (5000 onsets):

```
  humanize +-0.02    worst = 5.1196e-05 beats = 0.02560 ms @120bpm
  free/recorded      worst = 5.2081e-05 beats = 0.02604 ms @120bpm
  a note at the WORST case is off by 0.0208% of a 16th note
```

**Note the 2.220e-16 entries for swing at 2400/4800: that is ONE ULP, not
quantization.** The swing *rational* is exactly representable there; the residue
is the `Double` representation of 0.16, which no scheme removes. This is why
`notesQuantized` counts against `beatEpsilon = 1e-9` and not against zero.

### A.2 Which division captures which grid (M3, M4) — exhaustive over 1…32767

```
EXACT (<=1e-9) coverage by candidate default division
t        source divisions it preserves EXACTLY      dyadic/128 triplets   quintupl   swing
480      24,48,96,120,240,480                       NO         yes        yes        NO
960      24,48,96,120,192,240,480,960               NO         yes        yes        NO
1200     24,48,120,240                              NO         yes        yes        yes
1920     24,48,96,120,128,192,240,384,480,960       yes        yes        yes        NO
2400     24,48,96,120,240,480                       NO         yes        yes        yes
4800     24,48,96,120,192,240,480,960               NO         yes        yes        yes
9600     24,48,96,120,128,192,240,384,480,960       yes        yes        yes        yes
15360    24,48,96,120,128,192,240,384,480,960,15360 yes        yes        yes        NO
19200    24,48,96,120,128,192,240,384,480,960       yes        yes        yes        yes
28800    24,48,96,120,128,192,240,384,480,960       yes        yes        yes        yes

smallest t in 1..32767 exact for ALL of the above (grids+swing+source divisions <=960): 9600
  9600 = 2^7*3*5^2 ; /128=75 /3=3200 /5=1920 /25=384 /200=48 /480=20 /96=100 /960=10
  9600 does NOT divide by 7 (1371.4286) or 9 (1066.6667)
```

Individually: 64th notes need 16; 32nds 8; 8th triplets 3; 16th triplets 6;
quintuplets 5; septuplets 7; **swing8 across 54…75 needs 100; swing16 needs 200**
(the offsets are `P/100` and `P/200`, so 5² is what 480/960/15360 lack).

### A.3 The tempo round trip (M5, M6)

```
=== D2 as k3 verified it (mu -> bpm -> mu), re-run here as a control ===
  values=2850001 failures=0 worst_abs_err=4.65661e-10 at mu=2807175

=== THE NEW DIRECTION (bpm -> mu -> bpm), which k4a export runs ===
  integer bpm 20..400: 352 of 381 do NOT round-trip bit-exactly
  worst abs bpm error = 0.0013101 at bpm=397  (relative 3.3e-06)
  first ten that fail: [21, 22, 23, 26, 27, 28, 29, 31, 33, 34]
  60..200 bpm at 0.1 steps: worst = 0.000314399 BPM at 196.5 (relative 1.6e-06, 0.0960 ms/min)
  20..400 bpm at 0.1 steps: worst = 0.0013101  BPM at 397.0 (relative 3.3e-06, 0.1980 ms/min)
  a 5-minute song at the worst relative error drifts 1.0 ms end to end

=== the k3 spine value 666666 us/qn -> bpm, and its export back ===
  bpm = 60e6/666666 = 90.000090000089997
  60e6/bpm computes to 666666            <-- EXACTLY
  round = 666666   floor = 666666   ceil = 666666   trunc = 666666
                                          ^^ ALL FOUR AGREE -> the obvious leg is VACUOUS

=== discriminating BPMs in the musical range ===
  frac>=0.5 (round&ceil -> N+1 ; floor&trunc -> N):
     bpm=61     60e6/bpm=983606.557377049   round=983607 floor=983606 ceil=983607
  0<frac<0.15 (ceil -> N+1 ; round,floor,trunc -> N):
     bpm=104    60e6/bpm=576923.076923077   round=576923 floor=576923 ceil=576924
```

### A.4 Beat→tick discriminators at t = 9600 (M8) and precision headroom

```
  beat=1.00006    beat*t=9600.576000 frac=0.5760 | round=9601 floor=9600 trunc=9600 ceil=9601
  beat=1.00001    beat*t=9600.096000 frac=0.0960 | round=9600 floor=9600 trunc=9600 ceil=9601

   authored 1.00006 -> round 9601 (=9601/9600 = 1.0001041666666666) | floor/trunc 9600 (= 1)   | ceil 9601 (= 1.0001041666666666)
   authored 1.00001 -> round 9600 (=9600/9600 = 1)                  | floor/trunc 9600 (= 1)   | ceil 9601 (= 1.0001041666666666)

  Double exactness of beat*t holds while |beat*t| < 2^53 = 9.01e+15
     -> at t=9600 that is 9.39e+11 beats, seven orders past the VLQ ceiling
  VLQ ceiling 0x0FFFFFFF: t=480 -> 559240.5 beats | t=960 -> 279620.3 | t=1920 -> 139810.1
                          t=9600 -> 27962.0 beats (6990.5 bars of 4/4 = 3.9 h at 120 BPM)
                          t=15360 -> 17476.3
```

### A.5 Endpoint vs independent length rounding (M7)

```
t=1200, 200000 random (start,length) pairs, start~U(0,64), length~U(0.02,4)
  the two forms give DIFFERENT lengthTicks in 49863 of 200000 cases (24.9%)
  worst error in the NOTE END position:  endpoint 4.166659e-04 beats | independent 8.316966e-04 beats
  worst error in the LENGTH itself:      endpoint 8.324994e-04 beats | independent 4.166660e-04 beats
  half a tick = 4.166667e-04 beats ; one tick = 8.333333e-04 beats

  of 50000 flush-legato pairs, the note-off tick != the next note-on tick:
     endpoint form:    0      (0.00%)
     independent form: 12420  (24.84%)
```

---

### A.7 Apple's loader on a 9600-tpqn file (M12) — D-DIVISION arbitrated

`scratchpad/mk9600.py` builds a 2-chunk format-1 file at division 9600, with a
conductor chunk (name / 500000 µs-qn / 4:2:24:8) and a `Lead` chunk carrying
three notes: on-grid at beat 0, **one tick off-grid at tick 9601** (the beat that
discriminates `round` from `floor` in G1), and on-grid at beat 2, each 4800 ticks
= 0.5 beat long.

```python
T = 9600
ons = [0, 9601, 19200]; L = 4800; END = ons[-1] + L
hdr = b"MThd" + (6).to_bytes(4,'big') + (1).to_bytes(2,'big') \
                                     + (2).to_bytes(2,'big') + T.to_bytes(2,'big')
```

Run against the same `validate` binary used for M9 (Appendix B), so the harness
is the one already proven sound against `apple-type1.mid`:

```
$ python3 mk9600.py && ./validate probe-9600.mid
division word = 0x2580 expected beats: [0.0, 1.0001041666666666, 2.0] expected dur: 0.5
=== probe-9600.mid ===
MusicSequenceFileLoad status = 0  (ACCEPTED)
track count (excluding tempo track) = 2
  [tempo] t=0.0 TEMPO bpm=120.0
  [tempo] t=0.0 META type=0x58 len=4 payload=04 02 18 08
  [track 0] t=0.0 META type=0x03 len=9 payload=43 6F 6E 64 75 63 74 6F 72
  [track 1] t=0.0 META type=0x03 len=4 payload=4C 65 61 64
  [track 1] t=0.0 NOTE ch=0 pitch=60 vel=100 dur=0.5
  [track 1] t=1.0001041889190674 NOTE ch=0 pitch=61 vel=100 dur=0.49999997
  [track 1] t=2.0 NOTE ch=0 pitch=62 vel=100 dur=0.5
```

Three things this settles that the arithmetic could not:

1. **A non-standard division word is not rejected.** 9600 is outside the
   24/48/96/480/960 family every shipping file uses; Apple parses `0x2580`
   as a plain metrical division and divides by it, with no special-casing.
2. **The off-grid tick survives the reader.** `9601/9600 = 1.0001041666…`
   comes back as `1.0001041889…`. The `2.23e-8` beat discrepancy is float32
   in `MusicTimeStamp` — it appears at 480 tpqn too and is **not** a
   9600-specific artifact. Compare scales: our own worst-case quantization
   loss at 9600 is `0.5/9600 = 5.2083e-5` beats (M1), i.e. 2367× larger. A
   reader's own float error is two and a half orders of magnitude below the
   loss we already disclose in the report.
3. **Durations survive.** `0.49999997` for an authored `0.5` is the same
   float32 residue, not a widened or dropped note (§2.3's
   `notesWidenedToOneTick` would show a `1/9600` duration, which is not what
   came back).

**Scope, stated honestly, same as M9:** this proves Apple's *parser* accepts and
correctly scales a 9600 header. It does not prove any other DAW does — no other
third-party reader was available in this environment. If a receiving DAW is ever
found that mis-handles a non-480-family division, D-DIVISION's caller-settable
`division` parameter (1…32767) is the escape hatch, and that is precisely why it
is a parameter rather than a constant.

---

## Appendix B — the Apple-loader witness (M9)

Run on this machine during this read: **Xcode 26.6 (Build 17F113), Apple Swift
6.3.3, arm64-apple-macosx26.0**, built with `xcrun swiftc -O validate.swift -o
validate`. `AudioToolbox` appears in the validator only — **never** in
`Sources/DAWCore` (LAW L9). The script should be checked in under `scripts/` this
time rather than left in a scratchpad.

Shape: `NewMusicSequence` → `MusicSequenceFileLoad(seq, url, .midiType, [])` →
walk the tempo track and every `MusicTrack` with a `MusicEventIterator`, printing
`kMusicEventType_Meta` (type byte + payload, read at offset 8 into
`MIDIMetaEvent`), `kMusicEventType_ExtendedTempo` and
`kMusicEventType_MIDINoteMessage`.

**Harness soundness check — `apple-type1.mid`, the k3 spine fixture:**

```
MusicSequenceFileLoad status = 0  (ACCEPTED)
track count (excluding tempo track) = 2
  [tempo] t=0.0 TEMPO bpm=120.0
  [tempo] t=4.0 TEMPO bpm=90.00009000009
  [track 0] t=0.0 NOTE ch=0 pitch=60 vel=70  dur=0.5
  [track 0] t=1.0 NOTE ch=0 pitch=62 vel=80  dur=0.5
  [track 0] t=2.0 NOTE ch=0 pitch=64 vel=90  dur=0.5
  [track 0] t=3.0 NOTE ch=0 pitch=66 vel=100 dur=0.5
  [track 1] t=0.0 NOTE ch=1 pitch=48 vel=70  dur=0.5
  [track 1] t=1.0 NOTE ch=1 pitch=50 vel=80  dur=0.5
  [track 1] t=2.0 NOTE ch=1 pitch=52 vel=90  dur=0.5
  [track 1] t=3.0 NOTE ch=1 pitch=54 vel=100 dur=0.5
```

Beats, durations and both tempi reproduce k3's G4 expectations exactly, so the
harness reads metrical files correctly — which is what makes the SMPTE run's
degenerate timestamps evidence about the FILE and not about the script.

**The new fixture — `hazard-smpte-meter.mid` (84 bytes):** output in §9.3.
The existing `hazard-smpte-division.mid` behaves identically (`status = 0`, one
track, `t=-0.0`, `dur=0.0`), which confirms the degeneracy is a property of SMPTE
division and not of this fixture's construction.
