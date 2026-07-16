# Design: SFZ / `.dspreset` import for the built-in Sampler (m18-h, mapping half)

**Date:** 2026-07-16
**Roadmap item:** `docs/ROADMAP.md:287` (m18-h) — the daw-architect mapping-design half. The
research half is `docs/research/2026-07-16-spike-sfz-dspreset-formats.md` (cited below as
**RES §n**); its census and format facts are taken as verified input, not re-argued here.
**Status:** DESIGN ONLY. No code ships with this item. Implementation files as the four roadmap
items proposed in §10 only because this design says GO.

## 1. Executive summary

The census (RES §2) shows the gap between real free libraries and our Sampler is exactly one new
zone-selection dimension (velocity + group + round-robin/random) plus per-zone playback scalars
(tune, pan, envelope) — all of it fits the existing "zones are structural, scalars hot-swap"
RT contract (`SamplerInstrument.swift:32-38`) without any new render-thread allocation, lock, or
ObjC. The parsers are pure text/XML work that lives headless in DAWCore beside the existing
`SoundFontPresetReader` precedent. The one researcher-draft amendment that matters: `#include`/
`#define` preprocessing is promoted to MUST — it is ~150 lines of import-time string work with
zero engine cost, and without it the single most famous free piano imports as zero zones (RES
§1.5). Loops stay out of v1 (0 of 4 acoustic libraries used them, RES §2), reported honestly.
Total estimate: **10–11 days across four independently shippable items.**
**Recommendation: GO.**

## 2. Final subset decision

Baseline is the researcher's draft tiering (RES "Recommended v1 subset"). Amendments first, then
the frozen table, then the degradation policy (what v1 DOES with excluded content).

### 2.1 Amendments to the researcher's draft

| # | Amendment | Rationale (one line) |
|---|---|---|
| A1 | `#include`/`#define`: COULD → **MUST** | Pure import-time text work, zero engine cost, and it gates the flagship library entirely (RES §1.5) — the cost/benefit asymmetry overrides census frequency. |
| A2 | `ampeg_decay`/`ampeg_sustain`: flagged-open → **SHOULD (in v1, own item)** | The 4-stage envelope state machine already exists in-house (`PolySynthInstrument.swift:54-70,240-253`) — this is a pattern copy, not a rewrite; used by 3/5 libraries (RES §2). |
| A3 | `offset`/`end` (SFZ) and `start`/`end` (`.dspreset`): unlisted → **SHOULD** | The format author's own Kontakt-export tooling emits `start`/`end` on every sample (RES §3.5 item 2); engine cost is two Int32s per zone and a changed end-check, nothing more. |
| A4 | `loop_mode=one_shot`: split out of the loops COULD tier → **SHOULD**, as a per-zone one-shot override | It is not a loop — it maps to the existing one-shot behavior (`SamplerInstrument.swift:29-30`), just per-zone instead of global; drum content (GM-StylePerc class) needs it. |
| A5 | Zone `gain` upper bound relaxed 1.0 → 2.0 in the model | SFZ `volume` legally reaches +6 dB; today's clamp (`Model.swift:1329`) would silently mis-level imported content — a range *relaxation* is decode-safe for every existing project. |
| A6 | Note-name pitch values (`key=c4`, `lokey=a#3`): unlisted → **MUST** (parser detail) | Real files use note names, not just numbers; a numbers-only parser fails on legitimate MUST-tier content. |

Everything else stands as drafted: velocity layers, RR, random, key mapping, `sample`/
`default_path` + separator normalization are MUST; `tune`/`transpose`, `volume`/`pan`/
`amp_veltrack`, `ampeg_attack`/`ampeg_release` are SHOULD-shipping-in-v1; loops
(`loop_continuous`/`loop_sustain` + `smpl`-chunk fallback) are COULD/v2; the entire RES §1.4
exclusion list (filters, LFOs, EQ, crossfades, `trigger=release`, keyswitches, CC-modulation,
voice-management) is EXCLUDED, for both formats.

### 2.2 Frozen v1 tier table

| Tier | SFZ | `.dspreset` | Engine work? |
|---|---|---|---|
| MUST | `key`/`lokey`/`hikey`, `pitch_keycenter` (note names + numbers), `lovel`/`hivel`, `seq_length`/`seq_position`, `lorand`/`hirand`, `sample`, `default_path`, `#include`, `#define`, `<group>` layering identity | `path`, `rootNote`, `loNote`/`hiNote`, `loVel`/`hiVel`, `seqMode`(`round_robin`/`random`)+`seqLength`/`seqPosition`, `<group>` layering | Velocity+group+RR+random selection (item A). Preprocessor/paths: importer-only. |
| SHOULD (v1, item B) | `tune`, `transpose`, `volume`, `pan`, `amp_veltrack`, `ampeg_attack/decay/sustain/release`, `offset`/`end`, `loop_mode=one_shot` | `tuning`, `volume` (linear or `dB` suffix), `pan`, `ampVelTrack`, `attack/decay/sustain/release`, `start`/`end`, `trigger="attack"` only | Per-voice envelope stage machine, pan gains, tune factor, start/end frames, per-zone one-shot. |
| COULD (v2, not in these items) | `loop_mode=loop_continuous/loop_sustain`, `loop_start`/`loop_end`, WAV/AIFF `smpl`-chunk fallback; `.dslibrary` unzip | `loopStart`/`loopEnd`/`loopEnabled`/`loopCrossfade` | Loop-point playhead wrap + crossfade; zip unpack. |
| EXCLUDE | Filters, LFOs, EQ, `xfin_*`/`xfout_*`, `trigger=release/first/legato`, `sw_*` keyswitches, `_onccN` family, voice-management opcodes (RES §1.4) | `<ui>`, `<midi>`, `<effects>`, CC gating, `silencedByTags`, output routing, curve attributes (RES §3.2-3.3) | None, by definition. |

### 2.3 Degradation policy — what v1 import DOES with excluded content

House law: we surface degradation, we never silently lie — the model is the Sampler's existing
skipped-zone reporting (`SamplerInstrument.swift:120-123` + stderr notes at 215-217). The importer
returns a structured `SampleLibraryImportReport` (§6) and every decision below lands in it:

| Encountered | v1 behavior | Why |
|---|---|---|
| Excluded opcode/attribute on an otherwise-importable region (filter, LFO, EQ, crossfade, `_onccN`, curve attrs) | **Import the region, ignore the opcode**, count it: `ignoredOpcodes: {"cutoff": 43, …}` | The region still plays correctly as a zone; dropping the whole region would destroy content over a cosmetic loss. |
| `loop_mode=loop_continuous`/`loop_sustain` (or `loopEnabled="true"`) | Import the zone WITHOUT looping + degradation note "N zones have sustain loops — imported without looping; sustained notes end at the sample's natural end (loops are a planned follow-up)" | Audible but honest; matches "plays as authored until the sample ends". |
| `trigger=release`/`first`/`legato`, CC-triggered regions (`on_loccN`), `.dspreset` `trigger!="attack"` | **Skip the region**, reason-coded (`skipped: trigger=release ×49`) | Importing them would fire release noises on note-ON — actively wrong sound, worse than absence (RES §1.4). |
| Keyswitched regions (`sw_last` present) | Keep ONLY the articulation matching `sw_default` (else the lowest `sw_last` key seen); skip the rest, note "keyswitch articulations reduced to default; N regions skipped" | Without a keyswitch state machine, importing all articulations layers them simultaneously — doubled notes, a lie about the instrument. |
| Region whose sample file is missing/unreadable at import time | Skip at import with per-file note (pre-checked in the importer, not left to engine load) | Fail at the moment the user can act on it; the engine's own skip-notes remain as backstop. |
| Undefined `$VAR` after `#define` pass, unresolvable `#include` | **Abort the import with a structured error** listing the exact unresolved names/paths | A partially-macro-expanded file produces garbage zone data; refusing loudly beats importing noise. |
| Parse yields 0 zones (apply mode) | Error (with the report attached), never a silent empty instrument | A track that renders silence with no explanation is the exact dishonesty this product bans. |
| `.dslibrary` file | Error: "`.dslibrary` is a zip archive — unzip it and import the `.dspreset` inside" | v1 scope cut with a one-line user workaround (§9 Q6). |
| `.ogg`-Vorbis samples (some sfzinstruments repos) | Zones skipped with per-file notes (Core Audio cannot decode Vorbis) | Same missing-file honesty path; decode support is not our layer. |

## 3. Domain-model design (DAWCore)

All additions are **additive-optional Codable fields**, the house idiom from
`Model.swift:1247-1249` ("Optional so pre-sampler project files still decode") — a pre-m18-h
project decodes every new field as `nil`, and `nil` is defined to reproduce today's behavior
**exactly**. No `SamplerParams` global changes are needed beyond documentation: `oneShot`,
`attack`, `release`, `gain` (`Model.swift:1283-1313`) remain the global scalars and become the
*fallback defaults* for zones that don't override them.

Sketch (not implementation — clamping/init elided):

```swift
/// m18-h additions to SamplerZone (Model.swift:1317-1350). Every field is
/// additive-optional; nil == pre-import semantics, byte-for-byte.
public struct SamplerZone: Identifiable, Codable, Sendable, Equatable {
    // — existing, unchanged —
    public let id: UUID
    public var audioFileURL: URL
    public var rootPitch: Int
    public var minPitch: Int
    public var maxPitch: Int
    public var gain: Double                 // range relaxed 0...1 → 0...2 (A5, +6 dB)

    // — selection dimension (item A) —
    public var minVelocity: Int?            // 0...127; nil = 0
    public var maxVelocity: Int?            // 0...127; nil = 127
    public var group: Int?                  // layering identity; nil = implicit group 0 (§4.2)
    public var seqLength: Int?              // RR cycle; nil/≤1 = no RR gate
    public var seqPosition: Int?            // 1...seqLength; nil = 1
    public var randMin: Double?             // [0,1); nil = 0   (lorand)
    public var randMax: Double?             // (0,1]; nil = 1   (hirand)

    // — per-zone playback scalars (item B) —
    public var tuneCents: Double?           // transpose*100 + tune; nil = 0
    public var pan: Double?                 // -1...1; nil = 0 (center)
    public var ampVelTrack: Double?         // 0...1; nil = 1 (today's velocity/127 law)
    public var oneShot: Bool?               // nil = inherit params.oneShot
    public var startFrame: Int?             // source-file frames; nil = 0      (offset/start)
    public var endFrame: Int?               // nil = file end                    (end)
    public var attack: Double?              // per-zone envelope; nil = params.attack
    public var decay: Double?               // nil = 0 (no decay stage — today's law)
    public var sustain: Double?             // 0...1; nil = 1 (hold at peak — today's law)
    public var release: Double?             // nil = params.release

    public func contains(pitch: Int) -> Bool          // unchanged
    public func contains(pitch: Int, velocity: Int) -> Bool   // new, nil-tolerant
}
```

What stays global on `SamplerParams`: `oneShot`/`attack`/`release`/`gain` (fallbacks + the
hot-swap surface), and NOTHING new — RR counters and RNG state are engine runtime state, never
model state (§4.3), so a saved project never carries selection-state garbage.

Wire/MCP ride-along (item A): `parseSampler` (`Commands.swift:4249-4298`) accepts the same
optional keys per zone; `samplerZoneSchema` (`mcp-server/src/server.ts:677-726`) gains the same
optional fields. Wholesale-replacement semantics of the `sampler` object are untouched
(`Commands.swift:659-660`).

Persistence caution (flagged, accepted): `ProjectBundle.write` copies every zone's media into the
bundle (`ProjectBundle.swift:182-195`) via APFS clonefile — same-volume saves of a 1,000-zone
library are copy-on-write cheap, cross-volume saves are real multi-GB copies. v1 mitigation is the
import-time byte accounting in §6.5; a reference-in-place library policy is explicitly deferred.

## 4. Engine design (DAWEngine)

The whole design preserves the RT contract verbatim: zones stay **structural** (any zones change
rebuilds the instrument; files load into immutable Float32 buffers in init,
`SamplerInstrument.swift:16,154-227`), scalars keep hot-swapping via the snapshot/retire-bin
(`SamplerInstrument.swift:245-264`), and the render path adds **zero** allocation, locks, ObjC, or
unbounded work. Every new per-note cost is O(zoneCount) integer/float compares in
`apply(event:)` — the same order as today's first-match scan (`SamplerInstrument.swift:404-410`).

### 4.1 LoadedZone additions (POD stays POD)

`LoadedZone` (`SamplerInstrument.swift:51-60`) gains: `minVel/maxVel: Int32`, `group: Int32`,
`seqLength/seqPosition: Int32`, `randLo/randHi: Float`, `tuneFactor: Double` (precomputed
`exp2(tuneCents/1200)` at init), `panL/panR: Float` (constant-power, precomputed at init),
`ampVelTrack: Float`, `oneShotOverride: Int8` (-1 inherit / 0 / 1), `startFrame/endFrame: Int32`,
`envAttack/envDecay/envSustain/envRelease: Float` (with -1 sentinel = "inherit global"). All
computed once in init on the main actor; immutable thereafter. At init, zones are stable-sorted by
`group` (legacy zones all map to group 0, so their relative order — and therefore today's
first-match behavior — is preserved exactly).

### 4.2 Selection algorithm (noteOn path in `apply(_:)`)

One pass over the group-sorted zone array; **one voice per group per note-on**, groups layer:

```
draw = nextRandom01()                       // ONE xorshift draw per note-on (SFZ semantics)
lastFiredGroup = Int32.min
for index in 0..<zoneCount:
    z = zones[index]
    pitch/velocity outside z's spans        → continue
    rrCounters[index] &+= 1                 // counter advances on every RANGE match (ARIA
    c = rrCounters[index] - 1               //  per-region convention, RES §1.3 seq_length row)
    z.seqLength > 1 && c % seqLength != seqPosition-1 → continue
    !(z.randLo <= draw && (draw < z.randHi || z.randHi >= 1)) → continue
    z.group == lastFiredGroup               → continue   // group already produced its voice
    triggerVoice(zoneIndex: index, ...)     // same slot-scan/oldest-steal as today
    lastFiredGroup = z.group
```

Why one-per-group: velocity layers and RR/random partition *within* a group so exactly one zone is
eligible per group; multi-mic/layered patches author layers as separate `<group>`s (or separate
ungrouped regions, which the importer gives unique group IDs, §5.3) so layers fire together. And
because every legacy/no-field zone lands in implicit group 0, a project saved before this item
selects **identically to today** — first eligible wins, rest of group 0 skipped
(`SamplerInstrument.swift:18,404-410` behavior preserved as the degenerate case). `noteOff`
already releases by `noteID` sweep across all voices (`SamplerInstrument.swift:442-454`), which is
exactly right for multi-group layers — no change.

Voice pool: **16 → 64** (`SamplerInstrument.swift:108`). Velocity-layered pianos under the sustain
pedal exhaust 16 voices immediately even without layering; 64 keeps the existing fixed-block
allocation (init-time), the existing O(voiceCount) scans, and the existing oldest-steal policy
(`SamplerInstrument.swift:414-427`) — just a bigger constant. Measured render cost stays trivial
(the per-frame loop skips inactive voices on a bool test).

### 4.3 Where RR/RNG state lives, and why it is RT-safe

- `rrCounters: UnsafeMutablePointer<UInt32>`, capacity `zoneCount`, allocated + zeroed in init
  (main actor), **mutated only inside `apply(event:)` on the render thread** — exactly the
  discipline of `bendFactor`/`pedalDown` (`SamplerInstrument.swift:129-136`). No atomics needed:
  single-writer, single-reader, same thread.
- RNG: one `UInt64` xorshift64* state var, render-thread-only, seeded in init from
  `SystemRandomNumberGenerator` (internal init parameter `randomSeed: UInt64? = nil` as the test
  seam). One multiply+shifts per note-on; no allocation.
- The structural/hot-swap split survives untouched: RR counters and RNG are **runtime** state, not
  params — they are not in `ScalarParams`, not in the snapshot, not in the model. A zones change is
  structural (rebuild → counters reset to zero), which is acceptable and matches what real players
  do on instrument reload. `reset()` (flush contract, `SamplerInstrument.swift:334-340`) does NOT
  zero counters — a mid-song stop/seek should not restart every RR cycle; offline-render
  determinism comes from fresh structural init + the seed seam, not from reset.

### 4.4 Envelope scope decision: 4-stage is IN (item B)

Decision: per-voice linear ADSR using the exact `Stage` state-machine pattern already shipped in
`PolySynthInstrument.swift:54-70,240-253` — attack → decay → sustain-hold → release. Per-voice
`attackStep/decayStep/sustainLevel/releaseSlope` are computed at TRIGGER time (four divides; the
noteOn path already does an `exp2`, `SamplerInstrument.swift:434-435`) from the zone's envelope
fields, falling back to the global coefficients for `nil`/sentinel fields. Defaults (`decay` nil →
0, `sustain` nil → 1) collapse the machine to today's attack→hold→release exactly
(`SamplerInstrument.swift:27-30`), so legacy behavior is bit-compatible. Global `attack`/`release`
stay hot-swappable; the one semantic shift — a global change now affects only *newly triggered*
voices with no zone override — is documented and negligible at anti-click time scales. The
release-to-exact-zero + NaN-guard contracts (`SamplerInstrument.swift:310-317,350-357`) carry over
unchanged.

### 4.5 Per-zone pan on the two-channel path

Constant-power gains precomputed per zone at init (`panL = cos((p+1)·π/4)`, `panR = sin(…)`); the
voice stores `gainL/gainR` (= `amp × panL/R`) at trigger and `renderFrame()`
(`SamplerInstrument.swift:345-386`) multiplies per channel — two multiplies replacing today's one
shared `gainNow`, zero new branches. Mono files keep playing both channels
(`SamplerInstrument.swift:191`), now panned; stereo files get standard balance gains. Channels
beyond stereo keep mirroring (`SamplerInstrument.swift:319-327`).

Amp law extension (item B): `amp = (1 − vt + vt·velocity/127) × zone.gain × params.gain` with
`vt = ampVelTrack` (nil → 1 ⇒ today's `velocity/127` law, `SamplerInstrument.swift:25`,
preserved). We keep our linear curve as a documented approximation of SFZ's default power curve.

## 5. Importer design

### 5.1 Placement

All parsing lives in **DAWCore** — pure Foundation text/XML + file-existence checks, no UI, no
audio decode, no engine types; the exact precedent is `SoundFontPresetReader.swift:1-15` (a binary
SF2 parser already living headless in DAWCore). New directory `Sources/DAWCore/SampleLibraries/`:

| File | Responsibility |
|---|---|
| `SFZPreprocessor.swift` | `#include` (main-file-relative, RES §1.5; depth cap 16, ≤256 files, canonical-path cycle detection) + `#define` (`$VAR` textual substitution, longest-name-first, last-definition-wins; undefined `$VAR` at use → structured abort). Import-time allocation is fine — nothing here ever touches the render thread. |
| `SFZParser.swift` | Tokenizer + header inheritance. Tokenizer warts owned here, each with a test: `//` line and `/* */` block comments; CRLF; `opcode=value` where `sample`/`default_path` values may contain SPACES (value extends to the next `word=` token or EOL — the sfizz rule); note-name pitch values (`c4`, `a#3`, case-insensitive, C-1…G9); dB parsing for `volume`. Inheritance: effective region opcodes = `<control>` → `<global>` → `<master>` → `<group>` → `<region>` dictionary merge (RES §1.1). Output: format-neutral IR. |
| `DSPresetParser.swift` | Foundation `XMLDocument` → the same IR: `<groups>`/`<group>`/`<sample>` attribute inheritance (RES §3.1-3.2); `<ui>`/`<midi>`/`<effects>` ignored by design (RES §3.3); `volume` accepts linear or `"NdB"`; `tuning` semitones → cents. |
| `SampleLibraryMapper.swift` | IR → (`SamplerParams`, `SampleLibraryImportReport`). The ENTIRE §2 tier/degradation policy lives here in one place: skip rules, keyswitch reduction, ignored-opcode counting, group-ID assignment, dB→linear, velocity/pitch clamps, missing-file pre-check, byte accounting. |
| `ProjectStore+SampleLibraries.swift` | `importSampleLibrary(trackID:path:dryRun:force:) throws -> SampleLibraryImportReport` — orchestration: extension dispatch (.sfz / .dspreset / .dslibrary error), mapper call, then (apply mode) the existing instrument-set path so it journals like any other instrument edit (one command surface: UI and wire converge on ProjectStore). |

### 5.2 Path normalization

One shared helper: backslash → slash, `default_path` prepend, percent/space tolerance, resolve
against the main file's directory (SFZ) or the preset file's directory (`.dspreset`), reject
escapes above the library root only with a note (some libraries legitimately use `..\Samples`,
RES §1.3 — allowed, just resolved).

### 5.3 Group identity assignment

SFZ: each `<group>` header = one fresh group ID in file order; regions outside any group each get
their OWN unique ID (SFZ semantics: independent regions layer). `.dspreset`: each `<group>`
element = one ID. The importer therefore never emits `group == nil` — implicit group 0 is reserved
for hand-built/legacy zones (§4.2 back-compat rule).

### 5.4 `#include`/`#define` failure story

In scope (amendment A1), so the "honest failure if deferred" question dissolves; the residual
honest-failure cases are: missing include file → abort listing the path; cycle → abort naming the
cycle; undefined `$VAR` → abort listing names. Abort = thrown structured error, nothing applied.

### 5.5 Reporting surface

```swift
public struct SampleLibraryImportReport: Codable, Sendable, Equatable {
    public var format: Format                    // .sfz | .dspreset
    public var zonesImported: Int
    public var groupCount: Int
    public var velocityLayerCount: Int
    public var skippedRegions: [String: Int]     // reason → count ("trigger=release": 49)
    public var ignoredOpcodes: [String: Int]     // opcode → count ("cutoff": 43)
    public var degradations: [String]            // human sentences, loadNotes idiom
    public var totalSampleBytes: Int64
}
```

Size guard (import-time, per §3 persistence caution + main-actor synchronous load risk): report
always carries `totalSampleBytes`; ≥ 500 MB adds a degradation warning; > 4 GB refuses unless
`force:true` — the error names the limit and the flag.

## 6. Control / MCP surface sketch

One new wire command (never renaming anything live; `instrument.importSoundBank` at
`Commands.swift:790-804` is untouched and remains the .sf2/.dls verb):

**`instrument.importSampleLibrary`** — params `{trackId (required), path (required, absolute,
.sfz|.dspreset), dryRun? (bool, default false), force? (bool, default false)}`. Apply mode sets
the track's instrument to `kind:"sampler"` with the mapped zones through the store (journaled,
undoable — unlike the library-only `importSoundBank`, this IS a project mutation). Result:
`{report: <SampleLibraryImportReport as JSON>, applied: bool}`. Errors follow the
MediaImporting tone (`Commands.swift:793-795`): wrong extension (with the `.dslibrary` unzip
hint), missing file, relative path, zero-zones-on-apply (report attached), size refusal.
`rejectUnknownKeys` like every sibling (`Commands.swift:796-797`).

MCP twin: **`instrument_import_sample_library`** (`mcp-server/src/server.ts`, beside
`instrument_import_sound_bank` at server.ts:1296-1323) — zod schema mirroring the params; the
description teaches agents the two formats, the subset posture ("imports `.sfz` (documented
subset) and `.dspreset` files" — NEVER "DecentSampler-compatible", RES §3.4), and the
dryRun-first flow. Existing `track.setInstrument` sampler schema gains the §3 optional zone
fields in item A.

UI hook (item C, small): "Import Sample Library…" beside the sound-bank panel flow
(`DAWProApp.swift:2646` `importSoundBankViaPanel` precedent), presenting the report's
degradations through the existing notice idiom. Pins: wire 126→127, MCP 129→130, catalog/Explain
updated per house gate rules.

## 7. Test strategy

House fixture idiom throughout — programmatic fixtures in temp dirs, no bundle resources
(the `SamplerTests` pattern, `Tests/DAWEngineTests/SamplerTests.swift:23-40`; `Package.swift`
declares no test resources today and this keeps it that way). `.sfz`/`.dspreset` fixtures are
small inline Swift string literals written to `FileManager.temporaryDirectory`; audio fixtures are
the existing generated sines.

- **`Tests/DAWCoreTests/SFZParserTests.swift`** — tokenizer warts (spaces in `sample=` values,
  note names, comments incl. block, CRLF, backslash paths, dB values); header inheritance
  precedence (control/global/master/group/region); `#define` substitution incl. redefinition and
  undefined-var abort; `#include` nesting, main-file-relative resolution, cycle + missing aborts;
  a miniature Salamander-shaped fixture (wrapper file + 2 includes + defines) proving the flagship
  topology parses.
- **`Tests/DAWCoreTests/DSPresetParserTests.swift`** — groups/sample attribute inheritance,
  seqMode variants, dB-vs-linear volume, tuning→cents, `<ui>`/`<midi>` ignored, malformed XML
  error, `trigger="release"` skip.
- **`Tests/DAWCoreTests/SampleLibraryMapperTests.swift`** — every §2.3 policy row asserted:
  keyswitch reduction counts, ignored-opcode tallies, loop degradation note, missing-file skip,
  zero-zone error, byte accounting, group-ID assignment (ungrouped SFZ regions get unique IDs),
  gain relax to 2.0, Codable round-trip of report and of new optional zone fields (old-JSON
  decode → all nil → equality with legacy zone).
- **`Tests/DAWEngineTests/SamplerSelectionTests.swift`** — direct-render (512-frame quanta,
  hand-built events, distinct fixture frequencies as zone fingerprints): velocity 30 vs 100 routes
  to the right layer; 4-slot RR rotates deterministically over 8 triggers; seeded RNG partitions
  lorand/hirand; two groups layer (RMS ≈ sum) while one group picks one zone; per-zone ADSR stages
  measured; pan L/R channel ratios; start/end frame honoring; per-zone one-shot ignores noteOff;
  64-voice steal still oldest-first. **Regression gate: the entire existing `SamplerTests` suite
  runs UNCHANGED and green — nil-field zones must select and sound byte-identically.**
- **`Tests/DAWControlTests`** — `instrument.importSampleLibrary` happy path (temp .sfz + generated
  WAVs → applied sampler visible in snapshot), dryRun leaves project untouched, error shapes
  (.dslibrary hint text, zero zones, size refusal), unknown-key rejection; pin bumps 127/130.
- **MCP** — `integration.test.ts` count + one tool-shape test, per the import_sound_bank pattern.
- **End-to-end gate (item C):** offline render RMS-above-silence through the full chain
  (importSampleLibrary → clip.addMIDI → render.measureLoudness), the m17-e gate idiom.

## 8. Days-scale estimate

"Parse the opcode" vs "engine can act on it" split respected (RES cross-cutting note): parsing
costs live in items C/D; engine-action costs live in items A/B and exist even with no importer.

| Phase (= roadmap item) | Scope | Days |
|---|---|---|
| **A — selection dimension** | Model fields (selection subset) + parseSampler/MCP schema ride-along + engine selection (velocity ∩ group ∩ RR ∩ random, group-sorted zones, counters/RNG, voices 16→64) + SamplerSelectionTests + legacy-regression gate | **3.0** |
| **B — per-zone playback scalars** | tune/pan/ampVelTrack/one-shot/start-end + 4-stage per-voice envelope (PolySynth pattern) + model fields + tests | **2.0** |
| **C — SFZ importer + surface** | Preprocessor, tokenizer, inheritance, mapper + report + `instrument.importSampleLibrary` + MCP tool + panel hook + fixtures/tests + E2E render gate + FREE-INSTRUMENTS.md row | **3.5** |
| **D — `.dspreset` importer** | XML parser onto the shared IR (mapper/report/command reused, format dispatch already in C) + fixtures/tests | **1.5** |
| Contingency | SFZ tokenizer warts found in the wild (the known unknown) | **+1.0** |
| **Total** | | **10–11** |

## 9. Risks (top 5)

1. **Main-actor synchronous load freeze / RAM blow-up.** Structural rebuild loads every file fully
   in init at reconcile time (`SamplerInstrument.swift:154-227`); a flagship piano is GB-scale.
   *Mitigation:* §5.5 byte warn/refuse gates now; streaming/background preload filed as an
   explicit follow-up, not smuggled into v1.
2. **Back-compat regression in zone selection.** Any drift breaks shipped projects.
   *Mitigation:* implicit-group-0 rule makes legacy input degenerate to today's exact first-match;
   the unchanged existing `SamplerTests` suite is a hard gate on items A and B.
3. **SFZ tokenizer wild-file warts** (spaces in paths, note names, encodings, stray headers).
   *Mitigation:* warts enumerated as first-class tests (§7), tolerant-but-reporting tokenizer,
   +1 day contingency, sfizz's published parsing rules as the reference behavior (RES §5).
4. **Voice-pool pressure from layered groups + pedal.** *Mitigation:* pool to 64 (fixed block,
   init-time); oldest-steal unchanged; importer notes unusually high group counts in the report.
5. **Scope creep toward a full SFZ player.** *Mitigation:* §2.2 table is frozen for v1; a
   sfizz-style public support matrix ships in user docs (RES §5 shows this is the professional
   norm), so "unsupported" is a documented boundary, not a bug report generator.

Explicit non-Xcode note: everything above builds with Command Line Tools (`swift build` +
`./scripts/test.sh`). Nothing here needs entitlements, AUv3, or signing. One future flag: if the
app is ever sandboxed for distribution, importing user-chosen library paths will need
security-scoped bookmarks — full-Xcode territory, out of v1 scope.

## 10. GO/NO-GO recommendation

**GO.** Reasoning trail: (1) demand is real and the subset is legitimate — all 8 core categories
appear in ≥3 of 5 real libraries and the pro precedent for tiered support is documented (RES §2,
§5); (2) the engine delta fits the existing RT architecture without bending any invariant — new
state is init-allocated, render-thread-owned, and the structural/hot-swap split survives (§4.3);
(3) the model delta is pure additive-optional Codable, per house idiom (§3); (4) the honest
alternatives lose: **hosting sfizz** buys full SFZ at the cost of a C++ dependency inside our RT
path, an opaque second command surface agents can't edit zone-by-zone, and no `.dspreset`;
**parse-only-flatten** (import top velocity layer, drop RR — zero engine work) silently discards
the musical core of the census content, which the honesty posture forbids; (5) ~10 days buys
native access to the largest free-instrument corpus that exists, the exact gap FREE-INSTRUMENTS.md
filed (ROADMAP.md:272 item 4).

**Proposed roadmap split** (each independently shippable, testable, and gated; suggested IDs for
the orchestrator to file):

- **(m19-a)** Sampler selection dimension: velocity/group/RR/random + wire/MCP zone fields +
  64 voices. Gate: SamplerSelectionTests + existing SamplerTests unchanged-green. *(Ships value
  alone: agents can hand-build velocity-layered kits over the wire today.)*
- **(m19-b)** Per-zone playback scalars + 4-stage envelope + pan + start/end. Gate: staged
  envelope/pan measurements + legacy suite green. *(Depends on nothing in A except the model file;
  orderable A→B or B→A, A→B preferred.)*
- **(m19-c)** SFZ importer + `instrument.importSampleLibrary` + MCP tool + panel hook + docs
  (support matrix, FREE-INSTRUMENTS.md row; ARCHITECTURE "Key future decisions" gains the SETTLED
  entry when this lands). Gate: mini-Salamander fixture imports; E2E render RMS gate; pins 127/130.
- **(m19-d)** `.dspreset` importer onto the shared IR. Gate: fixture parity tests + E2E render.
  *(v2 candidates filed separately, not as boxes: loops + `smpl` chunk; `.dslibrary` unzip;
  streaming/background sample load.)*

### 10.1 The researcher's 7 open questions, answered

1. **Velocity on `SamplerZone` vs a parallel structure?** On the zone, as additive-optional
   `minVelocity`/`maxVelocity` (nil = 0/127) — no Codable break (the `Model.swift:1247` idiom),
   no parallel structure to drift out of sync; §3.
2. **Where does RR/random state live; does it survive the structural/hot-swap split?** Render-
   thread-owned per-zone counter block + one xorshift state var, allocated in init, mutated only
   in `apply(event:)` — the `bendFactor`/`pedalDown` discipline. It is runtime state, not params:
   zones changes stay structural (counters reset with the rebuild, acceptable), scalar hot-swap
   is untouched, RR state is never model/wire state; §4.3.
3. **Does decay/sustain need a real 4-stage rewrite, and is it in scope?** It needs the 4-stage
   machine, but that machine already ships in `PolySynthInstrument.swift:54-70,240-253` — a
   pattern copy, per-voice, computed at trigger. In scope as its own item (m19-b), with nil
   defaults collapsing to today's exact behavior; §4.4.
4. **`#include`/`#define` in v1?** Yes — promoted to MUST (amendment A1): import-time-only string
   work gating the flagship library. Failure story: structured aborts naming missing includes,
   cycles, undefined `$VAR`s — never a silent zero-region import; §5.1, §5.4, §2.3.
5. **`smpl`-chunk parsing?** Out for v1, and so is looping entirely: loop opcodes are parsed only
   to REPORT the degradation ("imported without looping"), never stored as dead model fields the
   engine ignores. Loops + `smpl` fallback file together as one v2 item; §2.3.
6. **`.dslibrary` unzip?** Out for v1 — raw `.dspreset` + sibling samples only. The error message
   carries the one-line workaround ("it is a zip archive — unzip and import the `.dspreset`
   inside"). No third-party zip dependency enters DAWCore for this; v2 may shell out to system
   tooling at import time; §2.3.
7. **Naming posture?** Confirmed and encoded in the deliverable itself: all user-facing and MCP
   copy reads "imports `.sfz` (documented subset) and `.dspreset` sample-library files" — never
   "DecentSampler-compatible", never implying certification (RES §3.4); the MCP tool description
   in §6 is the enforcement point, and the item-C docs task carries the copy rule.
