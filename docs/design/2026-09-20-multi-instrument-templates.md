# Design — Multi-instrument templates (M39 wave 3)

Status: **DESIGN SPIKE. Nothing built.** Written 2026-09-20 by `daw-architect`.
Authority for the wave: the user's ruled order — (1) effects suite → (2) our own drum machine →
(3) **multi-instrument templates** → (4) loop/drum workflow depth — and the published promise
*"multi-instrument templates, so a whole arrangement can be built from one instruction."*
That sentence is the entire specification that exists; everything below is derived from the
codebase, and every load-bearing claim carries a `file:line`.

---

## 0. The answer in one page

**A template is `macro.songSkeleton`. It already exists, it is already called a template in the
shipped product, and it is missing exactly one thing: a roster entry cannot say which instrument
the part plays, except as a General MIDI program, and only from the code catalog — never from a
caller.**

So wave 3 is not "build a template system". It is:

1. give a roster entry a **full instrument descriptor** (any of the six kinds, including the drum
   machine that just shipped), plus `volume`/`pan`;
2. make that reachable **from the wire**, which the existing `program` field never was;
3. add a **read verb** so an agent can see what a genre will produce without applying it, because
   the only current answer is ~58 lines of hand-maintained prose in the MCP tool description that
   this wave would immediately rot;
4. re-voice the catalog's twelve drum tracks onto our drum machine (**needs the user's word**,
   recommended default yes).

Notes, patterns and loops are **wave 4** and are explicitly out of scope here (§6).

---

## 1. The gating answer: what a template IS on this wire

### 1.1 It is already shipped, and it is already called a template

The candidate "an extension of the existing `macro.songSkeleton`" is right, but the framing
understates it. `macro.songSkeleton` **is** the template feature as the user experiences it:

| Evidence | What it says |
|---|---|
| `Sources/DAWApp/Sketchpad/SketchpadView.swift:289-294` | The shipped button is labelled **"USE A TEMPLATE"** and its action is literally `app.store.applySongSkeleton(genre: "pop")`. |
| `Sources/DAWApp/Sketchpad/SketchpadView.swift:306` | Its help text: *"Start instantly from a template — no waiting, no key needed"*. |
| `Sources/DAWAppKit/ExplainModel.swift:698-699` | The Explain catalog entry is titled **"Use a Template"**. |
| `Sources/DAWAppKit/OnboardingModel.swift:14` | The onboarding step is described as *"instant song-skeleton template applied"*. |
| `CHANGELOG.md:3308` | Already ships the phrase *"the song templates listed each genre's tracks by name…"*. |

Shipping a second concept named "template" would put two names on one idea and — worse — two
homes on one scaffold. This tree's recorded characteristic failure is *the record says X, the
source says Y, and nothing compares them*; two scaffolders that must agree is that failure with a
build step.

### 1.2 What `macro.songSkeleton` actually does today

`ProjectStore.applySongSkeleton(genre:tempoBPM:sections:tracks:)` —
`Sources/DAWCore/SongSkeleton.swift:753-953`. In ONE `performEdit` (`:935-942`) it:

- sets tempo (caller's, else the genre default) via `applyTempoChange` (`:939`);
- appends the roster's tracks, each with a fresh mixer-preset insert chain (`:851-863`) and, when
  the catalog entry carries one, a GM `InstrumentDescriptor` (`:870-882`);
- appends an **"Arrangement"** instrument track carrying one contiguous empty MIDI clip per
  section (`:892-909`);
- drops a real session **Marker** at every section start, merged into the store's beat order
  (`:903-905`, `:938`);
- enables the loop over the whole arrangement (`:912-913`, `:940`);
- returns `SongSkeletonResult` with real ids (`:591-668`).

Catalog: `SongSkeletonCatalog.v1`, **14 genres**, `Sources/DAWCore/SongSkeleton.swift:137-153`.
It is **additive** — it never wipes (`:705-708`) — and it is **one undo step** (`:915-929`).

### 1.3 What it cannot do — the measured gap

| Cannot | Evidence |
|---|---|
| Select any instrument but a GM sound-bank program | `SongSkeletonTrack.program: SoundBankProgram?` (`SongSkeleton.swift:56`) is the *only* instrument field, and it expands to exactly `InstrumentDescriptor(kind: .soundBank, soundBank: …)` (`:870-880`). **There is no representable way for a template to select `.drumSynth`, `.sampler`, `.polySynth`-with-params, or an AU.** |
| Let a **caller** select any instrument at all | `parseSkeletonTracks` (`Commands.swift:11915-11953`) constructs `SongSkeletonTrack(name:kind:mixerPreset:)` at `:11950` and never reads `program`. See §5, defect **D1**. |
| Set volume or pan | The roster spec has no such field; `Track.init` (`Model.swift:1371`, volume/pan clamped at `:1395-1396`) accepts both. The `metal` genre ships **"Rhythm Guitar L"** and **"Rhythm Guitar R"** (`SongSkeleton.swift:479-482`) — named for a hard-panned double-track it cannot pan. |
| Create buses or sends | Refused by name: *"v1 skeletons never create buses"* (`SongSkeleton.swift:820-825`). |
| Set modulation | `Track.modulationSources` / `.modulationRoutes` shipped at m39-e (`Model.swift:1239-1243`); the roster spec cannot reach them. |
| Write a single note | Every guide clip is `notes: []` (`SongSkeleton.swift:900`); no roster track gets clips at all. |
| Know the song's key | **There is no project-level key or mode.** `playbox.generate` takes `keyTonic`/`keyMode` as params with defaults 0/major (`Commands.swift:5687-5716`). |
| Be non-4/4 | Deliberate: `beatsPerSkeletonBar = 4.0`, with a recorded reason (`SongSkeleton.swift:673-681`). |

**"Multi-instrument" names the first row. "One instruction" names the first three.**

### 1.4 The alternatives, and why they lose

**Rejected — a variant/extension of `project.new`.** `Commands.swift:6960-6990`. It takes exactly
one param (`discardChanges`), destroys the current project, carries `transportBusy` /
`unsavedChanges` guards, invalidates crash recovery, and returns a whole snapshot. It is a
**lifecycle** verb. `applySongSkeleton` is **additive** by explicit contract
(`SongSkeleton.swift:705-708`) and is a single coalesced edit that `edit.undo` reverts whole
(`:915-929`) — `project.new` is not undoable in that sense at all. Folding the scaffold into it
would put a destructive guard in front of an additive operation, break the undo contract, and
give the scaffold a second home. The two verbs compose correctly today: *"use `project_new` first
if you want a clean slate"* is already the shipped MCP guidance (`mcp-server/src/server.ts:11194`).

**Rejected — a saved-project file format / preset document.** *The existing code forces the
catalog shape.* `SongSkeletonTrack` (`SongSkeleton.swift:11`), `SongSkeletonGenre` (`:86`) and
`MixerPreset` (`MixerPresets.swift:11`) are `Sendable, Equatable` and **deliberately not
`Codable`**, with the reason written down: *"static, versioned, code-defined data, not user
data"* (`MixerPresets.swift:8-10`; the same sentence at `SongSkeleton.swift:9-10`). There is no
on-disk template store and no template bundle format. The one **user-saved** named thing in this
tree, `GrooveTemplate` (`Groove.swift:18`), lives **inside** `ProjectDocument`
(`ProjectDocument.swift:25`, additive-optional, omitted when empty) — which is circular for a
template whose entire job is to *create* a project. Building a document format means a new file
type, `AppDirectories` wiring, I/O, versioning and migration — a very large blast radius for a v1
whose real gap is one struct field. **This is the right v2 and it is named as a deferral in §6.**

**The honest fourth thing, and why it does not win either.** One could read "multi-instrument
template" as *a sound-set that is orthogonal to the genre* — a separate catalog of per-part
instrument recipes, applied on top of any skeleton (`macro.applySoundSet`). It is a real idea and
it loses on cardinality: it needs a stable part-name vocabulary ("Bass", "Keys", "Drums") to match
against, and the catalog's own names already vary ("808 Bass", "Upright Bass", "Clavinet",
"Rhythm Guitar L"). Matching by name is the silent-mismatch defect class this tree keeps paying
for. Put the instrument **on the roster entry**, where the name and the sound are authored
together and cannot drift.

### 1.5 The decision

> **A template is a `macro.songSkeleton` genre whose roster entries can carry a complete
> instrument descriptor, a mixer preset, and a strip position (volume/pan) — reachable both from
> the code catalog and from a caller's `tracks` override, with a read verb that reports exactly
> what a genre will produce. No new scaffold verb, no new document format, no notes.**

---

## 2. Model design (DAWCore)

### 2.1 `SongSkeletonTrack` — three additive-optional fields

`Sources/DAWCore/SongSkeleton.swift:11-65`. Keep every existing field and its meaning. Add:

```swift
/// The instrument this part plays, in full. ADDITIVE-OPTIONAL: nil is exactly
/// pre-wave-3 behaviour. MUTUALLY EXCLUSIVE with `program` — see the guard.
public let instrument: InstrumentDescriptor?

/// Strip position. nil = Track's own defaults (1.0 / 0.0). Refused, not
/// clamped, when out of range (the m34-q rule).
public let volume: Double?
public let pan: Double?
```

`InstrumentDescriptor` is reused **verbatim** (`Model.swift:1631-1702`) rather than given a
parallel spec type. It is already `Codable, Sendable, Equatable`; it is already what the skeleton
builds (`SongSkeleton.swift:870-880`); it is already what `Track.instrument` holds
(`Model.swift:1215`). A second vocabulary for "which instrument" is precisely the two-homes
failure. `DrumKitParams` is `Codable` via the extension at `DrumKit.swift:736`, so the descriptor
round-trips a kit with no new conformance work.

`program` **stays**. It is the ergonomic GM shorthand 40 catalog entries use, and three named test
assertions pin it (`Tests/DAWCoreTests/SongSkeletonTests.swift:152`, `:191`, `:192`). It remains a
**catalog-side Swift convenience only** and is deliberately *not* exposed on the wire — the
general `instrument` form supersedes it there, so the wire gains one spelling, not two.

### 2.1a ⭐ ONE HOME for the resolution — `resolvedInstrument`

Two things must now answer "what instrument does this roster entry produce?": `applySongSkeleton`,
which creates the track, and `macro.describeSkeleton` (§3.2), which reports it. Today the
`program → InstrumentDescriptor` expansion is written **inline** at `SongSkeleton.swift:870-880`.
Letting the read verb write its own copy would make the describe-equals-apply test (§7) a detector
of drift that has already happened, rather than a proof it cannot.

So hoist it onto the type:

```swift
public extension SongSkeletonTrack {
    /// The descriptor this entry produces — the ONE home. `instrument` wins
    /// (the two are mutually exclusive and the guard has already refused both);
    /// otherwise `program` expands to the GM sound-bank form; otherwise nil,
    /// which leaves the track on `InstrumentDescriptor.default`.
    var resolvedInstrument: InstrumentDescriptor? { ... }
}
```

`applySongSkeleton`'s build loop and `describeSkeleton` both call it, and neither spells the
expansion. This is the same argument §1.4 makes against a second scaffold verb, applied to my own
read verb: a rule that two call sites must agree on should be one function, not two expressions
that happen to match today.

### 2.2 Precedence: refuse, never resolve

`instrument` and `program` set on the same entry → **field-named error**, never a silent winner.
Precedent, verbatim in this file: *"One instrument selection per call: `audioUnit` and
`soundBank` are mutually exclusive — no silent precedence"*
(`ProjectStore.swift:4097-4101`, `ProjectError.ambiguousInstrumentSelection`).

### 2.3 The one rule the builder will get wrong if it is not written here

> **`drumKit` does NOT imply `kind`.**

Confirmed at source: `instrument.loadDrumPreset` calls `store.setInstrument(id:drumKit:)` with no
`kind` and then honestly reports `isActiveInstrument: descriptor.kind == .drumSynth`
(`Commands.swift:2322-2332`). A roster entry that carries a kit but not `kind: .drumSynth` is a
**silent inaudible success**: the track plays a saw poly synth and the call returns ok.

⚠️ **`kind` is overloaded on this surface — read the rule carefully.** A roster element's
own `kind` is the **track** kind (`"instrument"` | `"audio"`, `TrackKind`, `Model.swift:3-7`). The
**instrument** kind lives one level down, at `instrument.kind`
(`InstrumentDescriptor.Kind`, `Model.swift:1632-1651`). The rule below is about the inner one.

**Roster rule (deliberately STRICTER than `track.setInstrument`):** an `instrument` object
carrying `drumKit` whose `instrument.kind` is absent or is anything but `"drumSynth"` is
**refused** with a teaching error. A fresh track has no "current kind" for the overlay rule to
preserve, so implying it would be safe *here* — and that is exactly why it must not be done: it
would create a second rule for the same key, and a caller who learned the roster's rule would then
be wrong at `track.setInstrument`. One rule, refusal, both places.

✅ **`drumPreset` is NOT subject to this rule and cannot violate it.** It is self-contained sugar:
it expands to a *complete* descriptor — `{kind: .drumSynth, drumKit: <preset.params>}` — **before**
validation runs, so by the time the guard sees it, `kind` is already right. The rule bites only
the long form, which is the only form that can express the broken state.

### 2.4 ⛔ No Audio Units in the shipped catalog

`InstrumentDescriptor` can express `kind: .audioUnit`. A **caller-supplied** roster may use it —
their machine, their choice. The **shipped `SongSkeletonCatalog` must never**, and a catalog
integrity test must assert it.

Reason, and it is an RT/main-actor reason, not a taste one: AU instantiation is a known
main-actor wedge in this tree (a third-party AUv2 via `track_set_instrument` has wedged the main
actor for minutes). `applySongSkeleton` creates up to **25 tracks** in one edit
(`songSkeletonTrackCountRange = 1...24` at `SongSkeleton.swift:695`, plus the Arrangement track)
and hands them to the engine in one call, `engine?.tracksDidChange(self.tracks)`
(`SongSkeleton.swift:941`). A catalog genre that instantiated even two AUs would turn "one
instruction" into a multi-minute freeze with no progress surface. Our own `.drumSynth`,
`.polySynth` and `.sampler` have nothing external to resolve.

### 2.5 Render-thread safety

**Nothing in this design touches the render thread.** The whole feature is model construction on
`@MainActor` inside one `performEdit`, published through the existing
`engine?.tracksDidChange` hand-off (`SongSkeleton.swift:941`) that every `track.add` already uses.
No new engine surface, no new node type, no new parameter path, no allocation on any audio
callback. `.drumSynth` render behaviour is m39-dm's, unchanged.

The one genuinely new load characteristic is **instantiation breadth**: a 24-track genre where
every part carries a distinct built-in instrument constructs more voices at `tracksDidChange`
than today's catalog does. That is graph *setup*, off the render thread, and it is bounded by the
existing 1...24 roster ceiling — which exists for exactly this reason (*"the roster is created
inside ONE undoable edit, so an unbounded array would be an unbounded edit"*,
`SongSkeleton.swift:690-695`). No change needed; named so it is not rediscovered as a surprise.

### 2.6 `@MainActor` budget

The memory records `@MainActor` occupancy at **380/380, zero slack**, with an unbacked cadence
bump to 387. This design adds **no new `@MainActor` store entry point**: §2 extends the existing
`applySongSkeleton`, and the new read verb (§3.2) answers from `SongSkeletonCatalog` statics with
no store access at all. The builder must **re-measure** the cadence figure before quoting it; do
not carry this paragraph's claim forward as measured.

---

## 3. Wire verbs and MCP tools

### 3.1 `macro.songSkeleton` — extended, additively, per roster element

No rename, no repurpose, no change to any existing key's meaning. The top-level allow-list
(`Commands.swift:3642`) is unchanged: `["genre", "tempoBPM", "sections", "tracks"]`.

Each element of `tracks` gains four optional keys:

| Key | Type | Meaning |
|---|---|---|
| `instrument` | object | **The same object `track.setInstrument` accepts, minus `trackId`.** `{kind, waveform, attack…envelopeCurve, sampler, audioUnit, soundBank, drumKit}`. Parsed by reusing the shipped parsers: `parseInstrumentKind` (`Commands.swift:12224`), `parseSampler` (`:12975`), `parseAudioUnit` (`:13352`), `parseSoundBank` (`:13418`), `CommandRouter.parseDrumKit` (`:13817`). |
| `drumPreset` | string | Convenience: one of `DrumKitParams.presets` — `"808"`, `"909"`, `"acoustic"`, `"lofi"`, `"trap"` (`DrumKit.swift:815-841`, resolved case-insensitively by `preset(named:)` at `:843`). Expands to `{kind:"drumSynth", drumKit:<preset.params>}`. **Refused** if `instrument` is also present on the same entry. |
| `volume` | number 0…2 | Strip gain, 1 = unity (`Track.volumeRange`, `Model.swift:1368`). |
| `pan` | number −1…1 | −1 hard left (`Track.panRange`, `Model.swift:1369`). |

**Why `drumPreset` earns a key rather than "just use `instrument`".** It is the single most
common template intent in the whole wave ("this Drums track is a 909"), and spelled the long way
it is a 75-field object. One string versus 75 numbers is the difference between a template an
agent will write and one it will not. It is strictly sugar: it expands to the general form before
validation, so there is one validated path.

**Parse-side changes required, both of which are defect fixes (see §5):**

1. `parseSkeletonTracks` (`Commands.swift:11915-11953`) must read the new keys. Today it reads
   only `name`, `kind`, `mixerPreset`.
2. It must gain **per-element unknown-key rejection**. Today `rejectUnknownKeys` runs only at the
   top level, so `tracks[0].programme` is silently dropped and the call returns `ok:true`. The
   error must name the index and the key, matching the file's own per-index convention
   (`:11926`, `:11934`).

**Validation stays in the store**, per this file's existing split (*"Only SHAPE is checked here…
the store owns the CONTRACT… as the single source of truth"*, `Commands.swift:11907-11914`), and
runs **outside** `performEdit` so a bad roster records no undo entry
(`SongSkeleton.swift:738-746` states this law; `:1105`-equivalent precedent is
`validateSamplerZones` at `ProjectStore.swift:4105`).

⚠️ **The validation gap the builder must close.** `applySongSkeleton` writes
`Track(instrument:)` **directly** (`SongSkeleton.swift:881-882`) and therefore bypasses
`setInstrument` entirely — it gets none of `validateSamplerZones` (`ProjectStore.swift:4105`),
`validateSoundBank` (`:4109`), or the `ambiguousInstrumentSelection` guard (`:4099-4101`). Today
that is harmless because the only instruments it can build are GM programs pointing at
`systemGMBankPath` (`SoundBanks.swift:165-166`), which ships with macOS. The moment a roster can
name an arbitrary `.sf2` or a sampler zone path, an unvalidated roster creates a **silent,
never-sounding track**. The roster guard block (`SongSkeleton.swift:809-843`) must call the same
three validators.

### 3.2 NEW: `macro.describeSkeleton` — the read verb

```
macro.describeSkeleton { genre?: string }
```

- `genre` omitted → `{ genres: [{name, displayName, defaultTempoBPM, trackCount, sectionCount,
  audioTrackNames: [...]}], count }`
- `genre` named → the **fully resolved** template:
  `{ name, displayName, defaultTempoBPM, tracks: [{name, kind, mixerPreset?, instrument?, volume?,
  pan?}], sections: [{name, bars, startBeat, lengthBeats}], totalBeats }`
- unknown genre → the error that **lists every valid name** (the shipped
  `songSkeletonGenreNotFound` convention, `SongSkeleton.swift:760-763`)

Pure read. **No store access** — it answers from `SongSkeletonCatalog` statics, so it is
headless-safe, cannot block, and adds nothing to the `@MainActor` budget. It resolves each entry
through `resolvedInstrument` (§2.1a), never its own copy of the expansion.

⚠️ **STATED LIMIT: the described `instrument` is not byte-copyable back into a `tracks` override
for a PolySynth part.** `track.setInstrument` takes the synth's params **flat** (`waveform`,
`attack`, … — `Commands.swift:1567-1575`), while an encoded `InstrumentDescriptor` nests them
under `polySynth` (`Model.swift:1656`). The `soundBank`, `drumKit` and `sampler` sub-objects DO
round-trip; the synth params do not. This asymmetry is **pre-existing and not introduced here** —
`instrument.describeSynth` already carries it — but because an AI agent is the primary caller and
"describe then copy" is the obvious workflow, the limit must be stated in the tool description
rather than discovered. Unifying the two shapes is a separate, wire-visible change and is **not**
in this wave.

**Why it earns a slot rather than being MCP prose.** The `macro_song_skeleton` tool description
(`mcp-server/src/server.ts:11071-11128`) hand-duplicates all fourteen rosters as ~58 lines of
prose — every track name, every mixer preset, every `[audio]` tag. It is already a rot hazard, and
this wave changes **every roster**. A read verb makes the catalog self-describing, and a test that
compares `describeSkeleton`'s answer against what `songSkeleton` actually creates makes the two
unable to drift (§7). Precedent for the shape: `fx.describe`, `mod.describe`,
`instrument.describeSynth` / `describeSampler` / `describeDrumKit`, `instrument.listDrumPresets`.

### 3.3 ⛔ PLACEMENT — a measured pin, not a preference

**The new verb goes immediately AFTER `playbox.generate`, at `Commands.swift:367`.**

`Tests/DAWControlTests/PlayboxCommandTests.swift:85-91` pins three things at once:

```swift
#expect(index == (skeleton.map { $0 + 1 } ?? -1))          // playbox == songSkeleton + 1
#expect(index != CommandRouter.allCommands.count - 1)       // not at the tail
#expect(CommandRouter.allCommands.last == "vc.installEmbeddedVoice")
```

So inserting **between** `macro.songSkeleton` and `playbox.generate` breaks a test that is
asserting something true, and appending at the **tail** breaks the last assertion plus every
`dropLast(N)` window in the suite. Inserting immediately after `playbox.generate` — ~150 entries
from the end — leaves all of them true by construction. This is exactly the `pad.playEffort`
precedent recorded in the `allCommands` chain comment at
`Tests/DAWControlTests/RenderCommandTests.swift:683` (*"placed immediately AFTER `chord.voice`
rather than beside the verb it shares machinery with, because three adjacency pins run through
that block"*).

**And the verb BELOW is unpinned — measured, not assumed.** The m34-f precedent comment records
that they verified "nothing pins the verb below"; the same check here:

```
grep -rn 'firstIndex(of: "automation\.' Tests/ --include="*.swift"   -> 0 hits (exit 1)
```

Positive-controlled by censusing **every** `firstIndex(of:)` pin in `Tests/` — the list contains
`playbox.generate` (1) and `macro.songSkeleton` (1) but **no `automation.*` entry at all**, so
`automation.addLane` (`Commands.swift:368`) is not pinned to `playbox.generate + 1` and the
insertion is safe on both sides. The only window assertions in the suite are
`allCommands.suffix(21)` / `suffix(23)` (`MIDIFileExportCommandTests.swift:66,70`,
`MIDIFileImportCommandTests.swift:99`), all measured from the END — an insertion ~150 entries from
the tail leaves them true by construction.

Count pin to update: `RenderCommandTests.swift:683`, **231 → 232**, extending the inline chain
comment in the established style.

### 3.4 MCP

| Change | Detail |
|---|---|
| **New tool** `macro_describe_skeleton` | Direct `server.registerTool` (pure read, only optional params — the `mod_describe` / `fx_describe` precedent). Tool total **236 → 237**. |
| `macro_song_skeleton` schema | `songSkeletonTrackSchema` (`server.ts:11147-11171`) gains `instrument`, `drumPreset`, `volume`, `pan`. **No new tool**, so the command↔tool bijection in `mcp-server/test/audit-tools.test.ts` is unaffected by this half. |
| Genre-enum description | Shrink the ~58-line roster dump (`server.ts:11081-11128`) to one line per genre (name, tempo, track count, which tracks are `[audio]`) plus *"call `macro_describe_skeleton` for the exact roster"*. **Keep the `[audio]`-vs-`instrument` warning inline** — that is the part that prevents a real error class (a MIDI clip written to an audio track), and it must not cost a round trip. |

⚠️ **Counts are re-measured, never quoted.** Run `node scripts/gates/doc-count-drift.mjs` (the
pin that derives the total two independent ways and self-positive-controls); `grep -c
'registerTool('` lies. The 231/236 figures above are this spike's reading of
`RenderCommandTests.swift:683` and the memory index — **the builder re-derives them before
editing anything.**

### 3.5 In-app Copilot catalog — measured, and the answer is "optional"

`Sources/DAWControl/CopilotCatalog.swift` is a **curated subset**, not a mirror. Measured:
`macro.songSkeleton` and `playbox.generate` are **absent** (grep returned zero, positive-controlled
against `track.add`, which is present at `CopilotCatalog.swift:324`). The file's header states the
invariant as *"only catalog↔`CommandRouter.allCommands` parity matters"* (`:20-22`) — i.e. the
catalog must be a subset, not a superset. **A new verb therefore forces no entry here.**

Recommendation: add `macro.describeSkeleton` anyway. It is a pure read with one optional param —
the cheapest possible entry — and it lets the in-app Copilot answer *"what's in the pop
template?"* without a round trip through the MCP server it never talks to.

⛔ **Census, do not count.** Per the standing law, the builder must census every hand-maintained
registry this change can reach rather than trusting a per-site number from this document. The two
that grep cannot see for instrument kinds are `MixerStripView.swift:11`'s `addableEffectKinds` and
`InstrumentPickerModel.builtIns` (`Sources/DAWAppKit/InstrumentPickerModel.swift:200-221`, whose
own comment warns: *"a kind missing from here is INVISIBLE IN THE UI while remaining fully
functional over the wire"*). This design introduces **no new `InstrumentDescriptor.Kind`**, so
neither array should need an edit — verify that, do not assume it.

---

## 4. Re-voicing the catalog: the twelve drum tracks

### 4.1 The census (method, not a remembered number)

```
grep -n "standardDrumKit" Sources/DAWCore/SongSkeleton.swift        -> 12 sites
grep -c "program: GMProgramCatalog" Sources/DAWCore/SongSkeleton.swift -> 52 assignments
```

Sites: `SongSkeleton.swift:173, 204, 234, 324, 354, 382, 413, 445, 476, 514, 537, 567`.
Thirteen genres carry a Drums (or Percussion) track; **twelve** of those carry a GM kit. `ballad`
has no drum track at all, by design. Do not carry "twelve" forward as a fact — carry the command.

### 4.1a ⛔ D3 — the `rock` genre's Drums track has NO instrument at all

`Sources/DAWCore/SongSkeleton.swift:257`:

```swift
SongSkeletonTrack(name: "Drums", kind: .instrument),
```

No `program`, no `mixerPreset`. Censused: it is the **only** one of the thirteen drum/percussion
entries with no instrument (`grep -n 'SongSkeletonTrack(name: "Drums"' Sources/DAWCore/SongSkeleton.swift`
— twelve carry arguments, `:257` does not). So `macro.songSkeleton {genre:"rock"}` ships a track
called **Drums** that plays the default saw Poly Synth (`InstrumentDescriptor.default`,
`Model.swift:1676`, `kind: .polySynth`).

This is m34-o's own stated defect — *"every generated part — the one named 'Drums', the one named
'Piano' — came out as the same saw poly synth"* (`SongSkeleton.swift:32-36`) — surviving in one
genre, on a genre-defining part, unnoticed because the catalog-integrity test only visits entries
that HAVE a program (`SongSkeletonTests.swift:143`, `guard let program … else { continue }`).
**A test that skips the nil case cannot see the nil case.** Wave 3 fixes it for free, and the
builder should add the missing-side assertion: every entry NAMED for a drum part must carry an
instrument.

### 4.2 ⛔ The test consequence, measured exactly

`Tests/DAWCoreTests/SongSkeletonTests.swift`:

- `:152-153` — *"the only non-melodic entry is the drum kit"*. This sits inside
  `guard let program = strip.program else { continue }`, so a drum entry that moves to
  `instrument` simply stops being visited. **Does not fail.**
- `:191` — `#expect(program("pop", "Drums")?.bankMSB == GMProgramCatalog.percussionBankMSB)`.
  **Fails** (becomes nil).
- `:192` — `#expect(program("folk", "Percussion") == GMProgramCatalog.standardDrumKit)`.
  **Fails** (becomes nil).
- The anti-vacuity floor `#expect(assigned >= 40)` (`:160`, comment: *"40 is a floor under the 52
  assignments the catalog carries"*). **52 − 12 = exactly 40.** It passes with **zero margin** —
  the single worst state for a floor to be left in, because the next entry that stops carrying a
  program silently converts a real guard into a tripwire nobody meant to arm.

**The builder must re-base that floor** (to the new melodic count minus a small margin) **and add
a parallel floor for the new field** (`assignedInstruments >= 10`), so neither half can go vacuous.

### 4.3 The mapping, if the user says yes

| Genre | Kit | Why |
|---|---|---|
| hip-hop, r-and-b | `808` | the lineage the parts are named for ("808 Bass") |
| house, funk, metal, pop | `909` | the hard click; four-on-the-floor and modern pop/rock production |
| rock, blues, jazz, country, folk, reggae | `acoustic` | *"longer, less saturated and less synthetic"* (`DrumKit.swift:827-830`) |
| lo-fi | `lofi` | named for it (`DrumKit.swift:832-835`) |

`trap` (`DrumKit.swift:836-840`) has no genre slot in the v1 catalog and stays reachable by
`drumPreset`. Summaries are quoted from the preset catalog so the mapping is auditable against
source rather than taste.

⚠️ **`metal`, `rock` and `jazz` are the honest weak cases** — a real acoustic kit is a sampled
instrument, and our drum machine is a synthesised 808/909-lineage kit by design
(`docs/design/2026-09-20-drum-machine.md` §1). The `acoustic` preset is *"less synthetic"*, not
acoustic. This is a genuine trade against the GM `gs_instruments.dls` kit (which is sampled, and
present: `/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls`,
1.9 MB — verified on this machine). **This is why it is a user question (§8 Q1), not my call.**

### 4.4 Why it is safe to change a shipped surface, mechanically

The skeleton writes the descriptor into the new track **explicitly**
(`SongSkeleton.swift:864-882`), and the m34-o comment records why that matters: *"this changes
only songs generated from now on — it cannot reach a project already on disk"* (`:52-55`). The
"a shipped kind may not change tone" law's mechanism (a `Codable` decode default silently
re-voicing a saved project) **does not apply here**: there is no decode default in this path. An
existing `.dawproj` carries its own resolved descriptor and is untouched.

---

## 5. Claims in my brief that were WRONG

### Checked and CORRECT (so you know the check happened)

| Claim | Verified at |
|---|---|
| `macro.songSkeleton` exists | `Commands.swift:351` (registration), `:3610` (handler), `SongSkeleton.swift:753` (store) |
| `project.new` exists and is a blank-slate verb | `Commands.swift:539`, `:6960-6990` |
| `track.setInstrument` exists | `Commands.swift:272`, `:1504`; `ProjectStore.swift:4039` |
| Four `instrument.*Drum*` wire verbs shipped | `Commands.swift:340-343` |
| `DrumKit.swift` / `DrumSynthInstrument.swift` exist | `Sources/DAWCore/DrumKit.swift`, `Sources/DAWEngine/Instruments/DrumSynthInstrument.swift` |
| `MixerPresets.swift` exists | `Sources/DAWCore/MixerPresets.swift` |
| Wire is at 231 commands | `RenderCommandTests.swift:683` |
| "A verified NAME is not a verified SIGNATURE" | Heeded — `setInstrument`'s signature is 26 parameters (`ProjectStore.swift:4039-4092`), and it is **not** on the skeleton's path at all. |

### WRONG or materially misleading — four

⭐ **Precise verdict first, because the section heading overstates it: no claim in the brief was
FALSE.** Every checkable assertion above verified. What follows is three **load-bearing omissions**
(facts whose absence would lead a builder to ship the wrong thing) and one **false dichotomy**.
The genuinely new information is not in this list — it is D1/D2/D3 below, three shipped defects
the brief could not have known about.

**W1 — "the drum machine … a template that includes drums is the obvious case, so know how it is
addressed."** The unstated premise is that a template *can* address it. **It cannot.** The roster
spec's only instrument field is `program: SoundBankProgram?` (`SongSkeleton.swift:56`) and it
expands to exactly `kind: .soundBank` (`:870-880`). There is no representable way for any
skeleton — catalog or caller — to select `.drumSynth`. The ask is not "know how it is addressed";
it is "it is not addressable, and making it so is the wave."

**W2 — "How a track gets an instrument today (`track.setInstrument`)."** True in general and
**false on the path this wave touches.** `applySongSkeleton` never calls `setInstrument`; it
constructs `InstrumentDescriptor` inline and passes it to `Track.init`
(`SongSkeleton.swift:870-882`). Consequence, and it is load-bearing: the skeleton path gets
**none** of `validateSamplerZones` (`ProjectStore.swift:4105`), `validateSoundBank` (`:4109`), or
the `ambiguousInstrumentSelection` guard (`:4099-4101`). A builder who assumed the skeleton routes
through `setInstrument` would ship an unvalidated instrument path and find out via a silent,
never-sounding track. §3.1 carries the fix.

**W3 — "`MixerPresets.swift` exists — is that a precedent for the persistence shape, or a red
herring?"** A false dichotomy. It is **neither**: it is a strong precedent for the **catalog**
shape and an explicit **anti-precedent** for persistence. `MixerPreset` is `Sendable, Equatable`
and **not `Codable`**, and the file says why in the type's own doc comment: *"a static, versioned,
code-defined catalog, not user data"* (`MixerPresets.swift:8-10`). The persistence precedent you
were reaching for is `GrooveTemplate` (`Groove.swift:18`) — `Codable`, user-created, stored
additive-optionally in `ProjectDocument` (`ProjectDocument.swift:25`).

**W4 — the framing "an extension of the EXISTING `macro.songSkeleton`" understates what was
found.** `macro.songSkeleton` is not a macro that could be extended *into* a template — it **is**
the shipped template, under that exact word, in the UI (`SketchpadView.swift:289-294`), in Explain
(`ExplainModel.swift:698-699`), in onboarding (`OnboardingModel.swift:14`) and in the changelog
(`CHANGELOG.md:3308`). This matters for the wave's framing: nothing is being introduced. One
field is being added to a feature the user has already used.

### Two shipped defects found that the brief did not know about

**D1 — the `program` field is unreachable from the wire.** `parseSkeletonTracks`
(`Commands.swift:11915-11953`) builds `SongSkeletonTrack(name:kind:mixerPreset:)` at `:11950` and
never reads `program`. So m34-o's entire *"the instrument decides"* fix is **catalog-only**: the
moment a caller passes its own `tracks` roster — which the shipped MCP description **explicitly
recommends** (*"If none of these fits, keep the nearest `genre` and pass your own `tracks`
roster"*, `server.ts:11126-11128`) — **every part comes back as the default saw poly synth**,
which is precisely the defect m34-o exists to fix, still live on the override path. An AI agent,
the primary caller, hits this on the first non-catalog genre it is asked for.

**D2 — roster elements have no unknown-key rejection.** `rejectUnknownKeys` runs only at the top
level (`Commands.swift:3642`); inside `tracks[i]` an unknown key is silently ignored. So
`{name:"Drums", kind:"instrument", program:0}` returns `ok:true` today and creates a saw synth.
This is this tree's recorded characteristic failure verbatim — *fails silently by returning
something that looks like a valid answer.* Fixing it is a behaviour change for callers currently
sending junk keys; it is the right change and it is flagged rather than smuggled.

**D3 — the `rock` genre's "Drums" track carries no instrument at all** (`SongSkeleton.swift:257`), so it plays the default saw Poly Synth. Full write-up, census method and the reason the existing catalog test cannot see it: §4.1a.

D1 and D2 are in v1 scope and are one-function edits; D3 is a one-line catalog fix plus the missing-side assertion.

---

## 6. v1 scope, and what is explicitly NOT proposed

### Ships in v1

1. **Model** — `SongSkeletonTrack` gains `instrument: InstrumentDescriptor?`, `volume: Double?`,
   `pan: Double?`. `program` stays, mutually exclusive with `instrument`, catalog-side only.
2. **Wire** — `macro.songSkeleton`'s roster elements accept `instrument`, `drumPreset`, `volume`,
   `pan`, **and reject unknown keys per element** (closes D1 + D2). Validation moves into the
   existing guard block, outside `performEdit`, calling the same three validators
   `setInstrument` uses.
3. **Catalog** — two independent edits: (a) the twelve drum tracks re-voice to `.drumSynth` with
   genre-appropriate kits — **gated on user question Q1**, default yes; (b) `rock`'s
   instrument-less Drums track gets one (**D3**, §4.1a) and `metal`'s Rhythm Guitar L/R get
   `pan: −0.75` / `+0.75`, which is what their names have always promised. **(b) is NOT gated on
   Q1** — it is a defect fix and a pan value, neither of which depends on the drum-machine
   question. If Q1 is answered "no", (b) still ships and `rock`'s Drums track takes the GM kit
   every other genre already uses.
4. **Read verb** — `macro.describeSkeleton` + MCP `macro_describe_skeleton`, placed immediately
   after `playbox.generate`; the MCP genre-enum prose shrinks to a summary plus a pointer.
5. **Tests** — §7, anchored by the describe-equals-apply anti-drift gate.

### Explicitly NOT proposed, and why

| Not doing | Why |
|---|---|
| **Notes, patterns, drum loops** | **Wave 4 owns them** (*"loop/drum workflow depth"*). A template that also composed would make waves 3 and 4 the same item, and it would need a key/scale the project does not have. The wire already composes: `macro.songSkeleton` → `playbox.generate` → `clip.setNotes`. |
| **Buses and sends in a roster** | The skeleton refuses `.bus` by name with a stated reason (*"a bus with nothing routed into it is dead weight"*, `SongSkeleton.swift:816-825`). Doing it properly means routing by roster **name** to a UUID minted in the same edit — a new resolution concept, and name-matching is this tree's favourite silent-mismatch bug. v2. |
| **User-saved / on-disk templates** | §1.4. A real feature, a real file format, a different wave. `GrooveTemplate` (`Groove.swift:18`) is the shape to copy when it comes. |
| **A PolySynth preset catalog** | **Verified absent**: `grep -rn "PolySynthPreset\|synthPreset\|SynthPreset" Sources/` returns zero, positive-controlled against `DrumKitPreset` which returns `Sources/DAWCore/DrumKit.swift`. Until one exists, a template addresses the synth by `kind: "polySynth"` plus the same 24 param keys `track.setInstrument` takes. A named synth-preset catalog is the natural follow-on and is **not** in this wave. |
| **Modulation sources/routes on a roster entry** | m39-e shipped them on `Track` (`Model.swift:1239-1243`). Adding them here means the roster carries `AutomationTarget`s into tracks that do not yet exist, and lanes+routes share one 64 budget per strip. Separable, later. |
| **Project-level key/scale** | Does not exist anywhere in the model (verified: no `keyTonic`/`keyMode` in `Model.swift` or `ProjectDocument.swift`). `playbox.generate` takes them as params (`Commands.swift:5687-5716`). Introducing a project key is its own decision with its own blast radius. |
| **Meter-aware skeletons** | Deliberately 4/4, with the reasoning already written down (`SongSkeleton.swift:673-681`). Unchanged. |
| **Per-effect param overrides in a roster** | A roster entry names a whole `mixerPreset`; overriding individual effect params would fork `MixerPreset`'s "fresh chain" contract (`MixerPresets.swift:32-35`). Use `fx.setParam` after. |
| **A new `macro.applyTemplate` verb** | §1.1 — two scaffolders that must never diverge. Additive-only permits new verbs; it does not make a second home for the same logic wise. |
| **Touching `project.new`** | §1.4. It composes correctly already. |

---

## 7. Implementation plan

Each step is independently buildable and leaves the suite green.

### Step 1 — Model (`Sources/DAWCore/SongSkeleton.swift`)

- Add `instrument`, `volume`, `pan` to `SongSkeletonTrack` (`:11-65`), all defaulted in the
  memberwise init (`:58-64`) so every existing call site compiles untouched.
- Extend the roster guard block (`:809-843`) with, in this order:
  - `instrument` and `program` both set → `invalidSongSkeleton("tracks[i]: set either
    'instrument' or a catalog program, not both")`;
  - `instrument` on a non-`.instrument` track → refuse (mirror the existing `program` rule at
    `:829-834`, which is already exactly this error for exactly this reason);
  - `drumKit != nil && kind != .drumSynth` → refuse, teaching the rule (§2.3);
  - `audioUnit != nil && soundBank != nil` → `ambiguousInstrumentSelection`;
  - `sampler` → `validateSamplerZones`; `soundBank` → `validateSoundBank`;
  - `volume`/`pan` out of `Track.volumeRange` / `Track.panRange` (`Model.swift:1368-1369`) →
    **refuse, do not clamp** (the m34-q rule: *an agent that asked for 3.0 and silently got 2.0 has
    no way to find out*).
- In the build loop (`:849-885`), resolve `spec.instrument ?? spec.program.map { … }` and pass
  `volume`/`pan` into `Track.init` (`Model.swift:1371`).

### Step 2 — Catalog re-voicing (same file) — **gated on user Q1**

- Replace the twelve `program: GMProgramCatalog.standardDrumKit` sites with
  `instrument: InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams.<kit>)` per §4.3.
- `metal`: `pan: -0.75` / `pan: 0.75` on Rhythm Guitar L/R (`:479-482`).
- Add a catalog-integrity test: **no catalog entry may be `.audioUnit`** (§2.4), and every
  `drumKit`-bearing entry has `kind == .drumSynth`.

### Step 3 — Wire (`Sources/DAWControl/Commands.swift`)

- `parseSkeletonTracks` (`:11915-11953`): read the four new keys; add per-element
  `rejectUnknownKeys` against `["name","kind","mixerPreset","instrument","drumPreset","volume","pan"]`
  with an index-named error; expand `drumPreset` via `DrumKitParams.preset(named:)`
  (`DrumKit.swift:843`), refusing an unknown name by listing every valid one (the
  `instrument.loadDrumPreset` wording at `:2318-2321` is the model).
- Reuse the shipped instrument parsers listed in §3.1 — **do not write new ones**.
- Register `macro.describeSkeleton` in `allCommands` **immediately after `playbox.generate`**
  (`:367`) — §3.3. Add its handler beside the `macro.songSkeleton` case (`:3610`).
- Update `RenderCommandTests.swift:683` 231 → 232, extending the chain comment in house style.

### Step 4 — MCP (`mcp-server/src/server.ts`)

- Extend `songSkeletonTrackSchema` (`:11147-11171`) with the four keys, each `.describe()`d in the
  musician-facing register the file uses.
- Register `macro_describe_skeleton` directly (pure read).
- Shrink the genre-enum roster dump (`:11081-11128`), keeping the `[audio]` warning.
- Re-run `node scripts/gates/doc-count-drift.mjs` and `mcp-server/test/audit-tools.test.ts`.

### Step 5 — Docs

- `docs/ARCHITECTURE.md` → **"Key future decisions"** (heading at `:294`): add an entry
  *"Multi-instrument templates — the template IS `macro.songSkeleton`, extended per roster entry;
  no new scaffold verb, no template document format (SETTLED 2026-09-20 by design spike; …)"*,
  naming the two rejected alternatives and pointing at this file. Follow the existing entries'
  format (SETTLED/SHIPPED + the alternatives that lost).
- `docs/ROADMAP.md` → tick the wave-3 item when it lands.
- `CHANGELOG.md` → an entry; note the **behaviour change** that unknown roster keys are now
  refused (D2).

### Step 6 — Tests (`./scripts/test.sh`, never bare `swift test`)

**`Tests/DAWCoreTests/SongSkeletonTests.swift`**

- a roster `instrument` lands on the created `Track` **verbatim** (`==` on the descriptor);
- `drumPreset` expands to exactly `DrumKitParams.preset(named:)?.params`;
- `instrument` + `program` together → field-named refusal;
- `drumKit` without `kind: .drumSynth` → refusal (the §2.3 trap);
- `volume`/`pan` out of range → **refusal**. The control is *"no track was created"* — a refused
  call stores nothing, so there is no clamped value to inspect. Pair it with an in-range case that
  DOES store the exact value, so a parser that refuses everything cannot pass both;
- a `.soundBank` roster entry naming a missing file → throws **before** any edit. Assert on a
  FRESH store that `store.canUndo == false` afterwards (`ProjectStore.swift:196`, public) and the
  track count is unchanged — the no-undo-on-failure law. (`journal.undoLabels`,
  `UndoJournal.swift:115`, is `internal`, so it is reachable only under `@testable import
  DAWCore`; `edit.history` is wire-only and not available to a core test.);
- re-based anti-vacuity floors, both halves (§4.2);
- catalog integrity: no `.audioUnit`, every kit-bearing entry is `.drumSynth`.

**`Tests/DAWControlTests/MacroSkeletonCommandTests.swift`**

- **the D1 regression**: a wire `tracks` roster carrying `instrument` produces a track whose
  descriptor matches — with a **negative control** proving the same roster without `instrument`
  still produces the default;
- **the D2 regression**: `tracks[0].programme` (typo) is refused naming index and key — with a
  **positive control** that the correctly-spelled key is accepted, so an always-refusing parser
  cannot pass this test;
- registration + adjacency: `macro.describeSkeleton` index `== playbox.generate + 1`, not the
  tail, tail still `vc.installEmbeddedVoice`;
- `allCommands.count == 232`.

**⭐ The gate that matters most — describe-equals-apply.** For **every** genre in
`SongSkeletonCatalog.names`: call `macro.describeSkeleton {genre}`, then
`macro.songSkeleton {genre}` on a fresh store, and assert the described roster equals the created
tracks **field by field** — name, kind, instrument descriptor, volume, pan — and the described
sections equal the created guide clips' names, start beats and lengths.

This is the one test that attacks this tree's named characteristic failure directly: *the record
says X, the source says Y, and nothing compares them.* Without it, `describeSkeleton` is a second
record of the same fact and will drift, exactly as the MCP prose did.

**`mcp-server/test/`** — bijection at 237; schema round-trip for the four new roster keys.

### Step 7 — Live verification (staging **17695** only)

⛔ **Port 17600 is the user's live app. Never connect to it.** Identify any process **by port**
(`lsof -nP -p <pid> | grep -i listen`), never by path; kill staging **pidfile-exact**.

1. `project.new` on staging, then `macro.songSkeleton {genre:"hip-hop"}`.
2. `instrument.describeDrumKit {trackId:<Drums>}` → confirm `isActiveInstrument: true` and the
   808 values. **This is the check that would have caught the `drumKit`-does-not-imply-`kind`
   trap**, and it is the one an "it returned ok" smoke test misses.
3. Write a two-bar kick/snare pattern with `clip.addMIDI` + `clip.setNotes` and
   `render.mixdown` it.
4. ⛔ **Measure loudness AND TRUE PEAK.** A loudness gate has passed a clipping render in this
   tree (`audible=true` with takes at +1.5/+0.8 dBTP). `ffmpeg -hide_banner` — `-v error`
   suppresses `ebur128`/`astats`, and per-frame `framelog` needs `-loglevel verbose`.
5. ⛔ **Audibility is not correctness.** Five planted defects have passed `audible=true` here.
   Pair the render with an **invariance control**: the same template applied twice must produce
   byte-identical descriptors, and a template whose only change is the drum kit must produce a
   render that differs **only** on the drum track's stem.

### Flags

- **Nothing here needs full Xcode.** No entitlements, no AUv3, no signing, no code-signed bundle.
  It is DAWCore + DAWControl + MCP + tests, all reachable from `swift build` and
  `./scripts/test.sh`. (Xcode 26.6 is installed, but this wave does not require it.)
- **No render-thread risk.** §2.5. Nothing in this design allocates, locks or blocks on the audio
  callback; the whole feature is model construction on `@MainActor` in one `performEdit`.
- **`DAWCore` stays headless.** The model change touches no UI and no engine type;
  `macro.describeSkeleton` reads statics only.
- **No commits.** The tree has ~43 untracked files and commits need the user's explicit word,
  which has not been given.

---

## 8. Open questions that need the USER's ruling

Each has a recommended default, so **nothing here blocks the build**. Ask once; do not re-ask.

**Q1 — Should the fourteen genre templates' drum tracks move from the General MIDI kit to our own
drum machine?**
*Recommended default: **YES**, with the §4.3 kit mapping.*
Why it needs a ruling rather than my call: it changes what `{genre:"pop"}` **sounds like** on a
surface the user has already used, and the honest trade is real — GM's `gs_instruments.dls` kit is
*sampled*, ours is a *synthesised* 808/909 lineage, so `rock`, `jazz` and `metal` arguably get a
less realistic kit even as every genre gets a kit the user can actually shape (75 parameters, five
presets, no external file to resolve). Why yes anyway: wave 2 was ruled to be **our own drum
machine**, and templates that cannot reach it make wave 2 unreachable from the fastest path into
the product. Cost if yes: two named assertions plus an anti-vacuity floor (§4.2). Cost if no: the
"multi-instrument" promise ships with the one instrument the user just commissioned excluded from
every default.

**Q2 — Does "a whole arrangement can be built from one instruction" include NOTES?**
*Recommended default: **NO** in wave 3.*
My reading of the codebase says no: "Arrangement" is already a specific shipped thing here — the
guide track of named, marked sections that `macro.songSkeleton` builds (`SongSkeleton.swift:887-909`)
— so the promise is satisfied by tempo + form + tracks **that sound like their parts**. Wave 4 is
*"loop/drum workflow depth"*, which is where patterns belong, and notes would additionally require
a project key/scale that does not exist (§1.3). If the user means notes, that is a **larger item
than this wave** and should be sequenced, not absorbed.

**Q3 — Should a genre template be allowed to create a mix bus (e.g. a "Drum Bus" with the drum
tracks routed into it)?**
*Recommended default: **NO** in v1 — deferred to v2 (§6).*
It is the most defensible next increment and it is a genuinely bigger change than it looks: the
roster would have to reference buses by **name** to route into them, minting the UUID inside the
same edit, and name-based resolution is this tree's recurring silent-mismatch defect. Worth asking
because if the user's mental model of "multi-instrument template" includes the mix routing, v1
will feel half-finished and we should know that before building it rather than after.

---

## 9. Summary for the implementing agent

- The template already exists. **You are adding one field to `SongSkeletonTrack` and making it
  reachable from the wire.** Do not build a new verb for the scaffold.
- The two highest-value lines of code in this whole wave are in `parseSkeletonTracks`
  (`Commands.swift:11915-11953`): reading `instrument`, and rejecting unknown keys per element.
  Everything else is scaffolding around those.
- The single most dangerous trap is `drumKit` without `kind` — a **silent inaudible success**.
  Refuse it (§2.3).
- The single most dangerous *placement* is anywhere but immediately after `playbox.generate`
  (§3.3) — `PlayboxCommandTests.swift:85-91` pins the neighbourhood.
- **Census, never quote.** Every per-site count in this document is a *method* (the grep) plus a
  reading taken 2026-09-20. Re-run it. A number in a design doc has an expiry date, and the ones
  in this tree have rotted while reading as measured.
- **A tool that never ran and a tool that ran and found nothing produce identical output.** Every
  absence you rely on gets a positive control.
