# Multi-instrument templates: one call that sets up a whole band (M39 wave 3, design)

**Status: SETTLED BY DESIGN 2026-09-27 (lane W7-TPL, `daw-architect`). NOT BUILT.** Nothing in this document was built,
run, rendered or tested while writing it. Every codebase fact below was read or measured on 2026-09-27 in the main tree
(`m23-wip-2026-08-10`, HEAD `813c415` plus uncommitted work from about twelve concurrent lanes).

**Supersedes** `docs/design/2026-09-20-multi-instrument-templates.md` (a design spike that was never built and whose three
questions were never asked) wherever the two differ. §1.3 states that spike's decision, what it got right, and why this
design departs from it, so the orchestrator can rule on it; §15 lists every difference.

**The ask** (the user's ruling of 2026-09-19, `docs/ROADMAP.md:13-18`): wave (3) is *"MULTI-INSTRUMENT TEMPLATES — one call
that instantiates tracks + instruments + effect chains + routing together"*. The user's own words, the evening that ruling
was made: *"what about loops and drums and maybe multi instrument presets or templates?"*
(`~/.claude/projects/-Users-dsemenov-Views-daw-pro/memory/daw-pro-project.md:1360`).

**Evidence base, all read for this design:** `Sources/DAWCore/{SongSkeleton,MixerPresets,Model,Effects,Modulation,
ProjectStore+Modulation,Automation,Sidechain,DrumKit,InstrumentParams,InstrumentFamilyResolution,ProjectDocument,
ProjectMIDIExportMapper,ProjectTranspose,AppDirectories,BundledSamples}.swift` (the parts cited),
`Sources/DAWCore/ProjectStore.swift` (tracks, sends, outputs, sidechain, effect params, instrument validation,
`performEdit`), `Sources/DAWEngine/Instruments/DrumSynthInstrument.swift:480-505`, `Sources/DAWControl/Commands.swift`
(cases `track.add`, `track.setInstrument`, `mixer.applyPreset`, `macro.songSkeleton`, `project.new`, function
`parseSkeletonTracks`, the `allCommands` array), `Sources/DAWControl/CopilotCatalog.swift`,
`Sources/DAWControl/PolySynthDescription.swift:30`, `Sources/DAWApp/Sketchpad/SketchpadView.swift:270-310`,
`Sources/DAWApp/Mixer/MixerStripView.swift:5-14`, `Sources/DAWAppKit/InstrumentPickerModel.swift:185-235`,
`Sources/DAWAppKit/StepSequencerModel.swift` (drum mode), `Sources/DAWAppKit/ExplainModel.swift`,
`Sources/DemoRender/DemoRender.swift:1-60`, `mcp-server/src/server.ts` (the `registerTool` wrapper,
`macro_song_skeleton`, `songSkeletonTrackSchema`), `mcp-server/test/nested-strict-gap.test.ts:1-30`,
`claude-plugin/agents/*.md` (tool lists), `docs/design/2026-09-19-modulation-layer.md` (§7.4 budget),
`docs/design/2026-09-20-drum-machine.md` (§1, the pad-grid note), `docs/design/2026-09-20-multi-instrument-templates.md`
(whole), `docs/design/2026-09-27-p2-sing-integration.md` (as the model for form), `docs/DESIGN-LANGUAGE.md`,
`docs/ARCHITECTURE.md` ("Key future decisions"), `docs/ROADMAP.md` (M39), the memory notes on the AU-hosting wedge,
the 64-slot budget law (`daw-pro-gate-laws.md` §2026-09-20k) and the wave ruling, and `scratchpad/w7/common.md`.

**Evidence tags:**

| Tag | Meaning |
|---|---|
| **[R]** | Read in source: `path:line`. `Sources/DAWControl/Commands.swift` is cited by **case label or function name** and `mcp-server/src/server.ts` by **tool or constant name**, because other lanes are editing both files today. |
| **[M]** | Measured by me on 2026-09-27, with the method. Every negative result was positive-controlled; the control is named. |
| **[D]** | Derived by arithmetic or logic from [R]/[M] inputs. |
| **[A]** | Assumed or chosen, not measured. Every [A] says what replaces it and in which item. |

**Counts are methods, not numbers.** No wire or MCP total is quoted as current: take them from
`node scripts/gates/doc-count-drift.mjs` at merge time (W7 lanes are changing them as this is written).

---

## 0. The decision on one page

1. **A template is a named, versioned SOUND SETUP**: a set of new tracks, each with its instrument, its insert effects
   and their settings, its volume and pan, where it sends and where it outputs, plus the buses those point at, any
   sidechain keys between them, and any modulation on them. **It never contains notes, audio, tempo, song sections,
   markers, automation, the master chain, or colour** (§4.9; colour does not exist in the model at all, §2.1).
2. **Templates own the SOUND; `macro.songSkeleton` owns the song FORM. They compose; they do not merge.**
   - `template.apply` adds a sound setup to the current song and touches nothing else.
   - `macro.songSkeleton` gains **an additive `template` parameter**, so "start a lo-fi song with a full lo-fi band" is
     ONE call: `macro.songSkeleton {genre: "lo-fi", template: "lofi-chill"}`. It also gains `dryRun`, which replaces the
     spike's proposed read verb (§6.2).
   - **Both build tracks through ONE pure builder** (`TemplateBuilder`, DAWCore). `applySongSkeleton`'s existing rosters
     are converted to template tracks and built by it, byte-identically (a golden gate proves it, §8.4).
3. **One schema for everything.** Built-in templates, saved files, inline wire objects and `template.describe` replies are
   the SAME JSON, decoded by ONE tolerant `Codable` codec in DAWCore. Tracks, inserts and modulation sources refer to each
   other by **template-local keys** — never by project UUID, never by track name.
4. **Seven new verbs**, each with an MCP tool and tests: `template.list`, `template.describe`, `template.apply`,
   `template.save`, `template.remove`, `template.import`, `template.export`. `template.apply` is ONE undo step, has
   `dryRun`, is additive (applying twice adds the band twice, the skeleton precedent), and refuses while recording when it
   would create routing.
5. **Where templates come from:** ten built-in templates covering all fourteen skeleton genres (§7.1); saved from the
   current song (`template.save`, "Save as Template…"); and `.dawtemplate` files (import/export, and the library folder).
6. **A prerequisite the drum machine needs first (TPL-0).** Our drum machine answers MIDI notes 36–43 in its own order, not
   the General MIDI drum layout that the step sequencer, MIDI files and AI-written beats use. A template that put it on a
   "Drums" track would play **the wrong drums, audibly**. TPL-0 adds an explicit, appended note-layout option; templates
   write the General MIDI layout; every saved kit keeps today's behaviour bit for bit (§3).
7. **Proof, not audibility.** Every built-in template is rendered with a fixed audition pattern and measured: every part is
   heard, every bus receives, every sidechain ducks, every drum note lands on the intended drum, loudness sits in range,
   true peak ≤ −1 dBTP. Each leg has a planted defect it must catch, plus invariance controls (§8).
8. **UI:** the Sketchpad's existing **USE A TEMPLATE** button opens a template picker card instead of silently starting a
   Pop song. Simple density shows the ten built-ins with **Start a song** and **Add to my song**; Pro adds your saved
   templates, details, import/export and **Save as Template** (§9).
9. **Not needed:** full Xcode, signing or any entitlement. **The render thread is touched in exactly one place**: TPL-0's
   note-to-drum lookup at note-on, which must stay a plain `switch` (§3.4).

---

## 1. What was decided before this document, and what it forces

### 1.1 The user's ruling and the user's own words

- **The wave order is the user's** (asked directly, 2026-09-19): *"recommended is ok, but all of them eventually, we need
  rich features and finish effects suite first."* Waves 1 (effects suite) and 2 (our own drum machine, `.drumSynth`) are
  done. Wave 3 is this one. "All of them eventually" means wave 3 is **sequenced, not optional**: do not re-ask whether it
  is wanted [R `docs/ROADMAP.md:10-22`].
- **The definition** "tracks + instruments + effect chains + routing together" was the option text the user accepted, not
  the user's own phrase. The user's own phrase was *"multi instrument presets or templates"* [R memory
  `daw-pro-project.md:1360`]. That leaves one genuine intent question, asked once in §12.
- **The user is not a musician.** Their words describe; they do not diagnose. Every user-facing sentence here is written
  for a novice, and taste decisions go to the user as 3–4 listening options differing on one axis, never as a verbal
  question (memory rule "Listening feedback").

### 1.2 What waves 1 and 2 left for this wave

- The drum machine's own design **deferred two things to templates and to wave 4**: sampled drum kits are *"content for
  item (3), multi-instrument templates"*, and hosting the drum machine on the pad grid is *"wave item (4)"*
  [R `docs/design/2026-09-20-drum-machine.md:69-71, 88-89, 879-884`].
- `drumKit` does **not** imply `kind: "drumSynth"`: sending a kit without the kind stores it and plays the saw Poly Synth,
  returning success [R `claude-plugin/agents/sound-designer.md:228-232`; confirmed in the 09-20 spike at the
  `instrument.loadDrumPreset` case].
- Automation lanes and modulated effect parameters **share one 64-slot budget per strip**; `mod.addRoute` refuses past it,
  the render schedule silently keeps the first 64 [R `Sources/DAWCore/Modulation.swift:434-438`;
  `docs/design/2026-09-19-modulation-layer.md:864-870`].

### 1.3 ⭐ The 09-20 spike: its decision, what it got right, and why this design departs (for the orchestrator's ruling)

**Its decision, verbatim** [R `docs/design/2026-09-20-multi-instrument-templates.md:122-125`]:

> *"A template is a `macro.songSkeleton` genre whose roster entries can carry a complete instrument descriptor, a mixer
> preset, and a strip position (volume/pan) — reachable both from the code catalog and from a caller's `tracks`
> override, with a read verb that reports exactly what a genre will produce. No new scaffold verb, no new document
> format, no notes."*

It deferred buses and sends, modulation, user-saved templates and per-effect settings to a "v2" (its §6 table). It was
never built [M: `grep -rn 'describeSkeleton\|describe_skeleton' Sources Tests mcp-server/src` → 0 hits; the same grep
shape found `drumPreset` in `Sources/DemoRender/DemoRender.swift:654-660` and `macro.songSkeleton` in 8 files]. Its three
questions (re-voice the GM drums, notes, a mix bus) were never put to the user [M: `grep -c '2026-09-20-multi'` over
every memory file → 0; positive control `grep -c '2026-09-20-drum-machine'` → 1 each in `daw-pro-gate-laws.md` and
`MEMORY.md`].

**What it got right, and this design keeps** (each re-verified today):

| The spike's point | Kept how |
|---|---|
| **The real constraint is "two scaffolders that must never diverge"** (its §1.1) | `applySongSkeleton` is re-pointed onto the ONE template builder, with a golden gate proving byte-identical output (§5.4, §8.4). This is the condition under which a new verb is acceptable at all. |
| D1: the roster's `program` is unreachable from the wire | Still live [R `Commands.swift` fn `parseSkeletonTracks`: builds `SongSkeletonTrack(name:kind:mixerPreset:)` and never reads `program`]. Closed by the new `template` param plus D2's refusal, which teaches it (§6). |
| D2: `tracks[i]` has no unknown-key rejection | Still live [R same function; only the top level calls `rejectUnknownKeys(["genre", "tempoBPM", "sections", "tracks"])` in case `macro.songSkeleton`]. Fixed in TPL-6, flagged as a behaviour change. |
| D3: `rock`'s "Drums" carries no instrument | Still live, and wider than the spike said: rock's "Bass" has no instrument either [R `Sources/DAWCore/SongSkeleton.swift:257-258`]. Fixed in TPL-3 as a separate, flagged step **after** the byte-identical re-point (§5.5), with the GM kit and the bass program the other genres use, plus the missing-side assertion. |
| The skeleton writes `Track(instrument:)` directly and so skips `setInstrument`'s validators | Still true [R `SongSkeleton.swift:870-882`]. The builder returns every file-backed resource and the store checks all of them before the edit (§5.3). |
| `drumKit` without `kind` must be refused, not implied | Kept, and made stricter: a template's instrument must always name its `kind`, and a `drumKit` or `drumPreset` under any kind but `drumSynth` is refused (§4.5). |
| No Audio Units in the shipped catalog (main-actor wedge) | Kept, and extended: a catalog-integrity test asserts it (§8.1). |
| Refuse, never resolve; validate outside `performEdit` so a refusal records no undo entry | Kept (§5.3). |
| Placement: immediately after `playbox.generate` | Kept and re-measured today (§6.3). |
| The describe-equals-apply gate | Kept, and joined by a save-then-apply round trip (§8.2, §8.3). |
| `project.new` is a lifecycle verb; do not fold scaffolding into it | Kept (§6.1: "Start a song" on a busy project is additive, never a wipe). |
| Notes and patterns are wave 4 | Kept (§4.9, §11). |
| Name-matching is this tree's silent-mismatch defect class | Kept as a hard rule: a template never matches anything by name, in the project or in itself (§4.4). |

**Why this design departs** — five reasons, strongest first:

1. **The spike's v1 does not meet the wave's definition.** The ruling says "effect chains + routing together"; the spike
   shipped no buses, no sends, no sidechains, no modulation and no per-effect settings. Its own §8 Q3 admitted that *"if
   the user's mental model of 'multi-instrument template' includes the mix routing, v1 will feel half-finished."* The
   brief for this wave also requires saved and file-based templates, which the spike deferred.
2. **Coupling sound to song form makes templates unusable mid-song.** Every `macro.songSkeleton` call changes the tempo,
   appends an "Arrangement" guide track and a marker per section, and turns the loop on
   [R `SongSkeleton.swift:935-942`]. Under "a template IS the skeleton", adding a band to a song you have already started
   also restructures that song. And `genre` is required even under a full roster override
   [R `SongSkeleton.swift:734-736`], so a template saved from your own session, which has no genre, has nowhere to live.
3. **The spike's argument against buses is answered by keys, not by deferral.** It deferred buses because *"the roster
   would have to reference buses by NAME to route into them, minting the UUID inside the same edit, and name-based
   resolution is this tree's recurring silent-mismatch defect"* [R spike §6 and §8 Q3]. Here, references use
   template-local **keys** that must resolve inside the same template; a dangling key is a refusal naming it, before any
   edit. A key never matches against the project, so the silent-mismatch class cannot arise.
4. **The spike's argument against a file format applied to a static catalog, not to user data.** It cited
   `MixerPreset`/`SongSkeletonTrack` being deliberately non-`Codable` because they are *"static, versioned, code-defined
   data, not user data"* [R `MixerPresets.swift:8-10`], and itself named a document format *"the right v2"*. Saved
   templates are user data by definition. One schema for built-in, saved and wire templates is what prevents a second home.
5. **Its re-voicing question (Q1) would have shipped wrong drums.** It proposed moving the twelve GM drum tracks onto our
   drum machine. The drum machine answers notes 36–43 in its own voice order, so every beat written in the General MIDI
   layout would have played a closed hat where the snare should be (§3). This design keeps the classic rosters
   byte-identical and puts the drum machine only in new templates, behind TPL-0.

**What the orchestrator is ruling on**, in one line: *"a new `template.*` surface for sound setups plus one `template`
parameter on `macro.songSkeleton`, both built by one builder"* versus *"extend `macro.songSkeleton` only"*. §15 lists every
difference. **Of the spike's questions:** Q1 (re-voice) is dissolved (classic rosters unchanged; acoustic-kit taste goes
to a listening round in TPL-4); Q2 (notes) keeps the spike's answer, no, and needs no asking; Q3 (a mix bus) is dissolved
(buses are in v1).

---

## 2. The census: what a template can carry today

### 2.1 Every `Track` field, and whether a template carries it

`Track` is `Sources/DAWCore/Model.swift:1416-1460` [R].

| Field | In a template? | Why |
|---|---|---|
| `name` | Yes, 1–40 characters | The skeleton's bound, one home: `songSkeletonSectionNameMaxLength = 40` [R `SongSkeleton.swift:689`]. |
| `kind` | Yes: `instrument`, `audio`, **`bus`** | Buses are the point of "routing together". The skeleton's bus refusal stays on the skeleton's own `tracks` roster only. |
| `volume` (0…2), `pan` (−1…1) | Yes | Ranges `Track.volumeRange`/`panRange` [R `Model.swift:1585-1586`]. |
| `isMuted`, `isSoloed`, `isArmed` | No | Session state, not sound. |
| `isAIGenerated` | No | A template's tracks are not AI-made; the violet tint must not be copied (Rule 3). |
| `clips` | No | Notes and recordings are content (wave 4). |
| `instrument` | Yes (§2.2) | |
| `outputBusID` | Yes, as a **key** | |
| `sends` | Yes, as **keys** plus level | |
| `effects` | Yes, with settings by name and the sidechain key as a **key** | |
| `automation` | No | Lanes are positioned in beats of one song; a template has no timeline. |
| `takeGroups` | No | Recordings. |
| `modulationSources`, `modulationRoutes` | Yes, keyed | |
| `voiceProvenance` | No | A fact about a past conversion. |
| **colour** | **Does not exist** | See below. |

**Colour: the brief assumed a field that does not exist.** [M] `grep -rn -i 'colou?r' Sources/DAWCore | grep -i track` → 0
lines; `grep -rln -i 'trackColou?r\|TrackColou?r\|colorForTrack\|trackTint\|TrackTint\|laneColor\|TrackPalette' Sources` → 0
files; positive control `grep -rln -i 'Color(' Sources/DAWApp | wc -l` → 28. The only per-track tint anywhere is
`track.isAIGenerated ? DAWTheme.ai : DAWTheme.hairline` [R `Sources/DAWApp/Mixer/MixerStripView.swift:59`]. Track colours
would be a model field, a persistence field and a UI feature of their own; out of scope (§11).

### 2.2 Instruments

Six kinds [R `Model.swift:1849-1868`]:

| Kind | Built-in templates | Saved templates | Notes |
|---|---|---|---|
| `polySynth` | Yes | Yes | 24 named settings, the exact list `track.setInstrument` accepts [R case `track.setInstrument`, its `rejectUnknownKeys` list]. `PolySynthParams`' decoder **requires** its first eight fields [R `Model.swift:3185-3195`], so a sparse template cannot use that decoder (§4.4). |
| `drumSynth` | Yes, **only after TPL-0** | Yes | Five presets `808`/`909`/`acoustic`/`lofi`/`trap` [R `DrumKit.swift:815-843`]; 75 dotted names with a by-name reader and setter [R `DrumKit.swift:695-708`]. |
| `soundBank` | Yes (General MIDI, `source: "gm"`) | Yes (GM or a file path) | A stock Mac has exactly one bank, Apple's GM DLS, with one "Standard" kit [R `docs/ROADMAP.md:24-27`]. |
| `sampler` | **No** | Yes | Zones point at files. The only bundled sample is `builtin:test-tone-a4` [R `Sources/DAWCore/BundledSamples.swift:78-80`; M `ls Sources/DAWCore/Resources/BundledSamples` → `test-tone-a4.wav` plus W7-SD3's `sing-guides/`], so a built-in sampled kit would mean shipping sample files (§11). |
| `audioUnit` | **Never** | Yes, with a load-time warning | Hosting a third-party AU has wedged the main actor for minutes; a warm re-test did not reproduce it and a cold one was never run [R memory `daw-pro-au-hosting-wedge.md`]. |
| `testTone` | No | Yes (whatever the user had) | An engine-check instrument. |

### 2.3 Effects

- **22 built-in kinds plus `audioUnit`** [R `Sources/DAWCore/Effects.swift:8-276`].
- **Every setting is on a named surface**: `EffectParamSpec.specs(for:)` [R `Effects.swift:4186`] names them for `fx.describe`
  and `fx.setParam`. The **reader** is `EffectDescriptor.paramValue(_:)` in DAWCore [R `Effects.swift:6104-6122`]; the
  **writer** is `ProjectStore.applyEffectParam`, which is **`private static`** [R `ProjectStore.swift:3711`].
- **The writer couples one pair of settings, and the result does not depend on their order.** Turning the EQ's high-pass
  (or low-pass) on when it has no corner frequency writes a default corner of 20 Hz (or 20 kHz)
  [R `ProjectStore.swift:3746-3751`, `:3754-3759`], and the filter is on only when a corner exists and it is not switched
  off [R `Effects.swift:589`]. I traced both orders of `{highPassFreq: 120, highPassEnabled: 0}` and of
  `{highPassFreq: 120, highPassEnabled: 1}` through that code: each pair ends in the same state either way. `fx.add`
  applies its `params` object in dictionary order [R `Commands.swift:2931-2937`, `:2955-2958`], and Swift dictionaries
  iterate in an order that changes from one run to the next. That is harmless today. The template builder still applies
  settings in `specs(for:)` order, so a coupled pair added later cannot make a template sound different from one run to
  the next.
- A brand-new effect is built by `EffectDescriptor.newlyAdded(kind:)`, which gives every kind empty settings **except**
  `.clipper`, which gets explicit settings so a new clipper's `oversampling: 1` is written down while a legacy clipper
  with no settings keeps its 4 [R `Effects.swift:416-437`, `:342-355`].

### 2.4 Routing rules the builder must enforce

All [R `Sources/DAWCore/ProjectStore.swift`]:

- A bus always outputs to the master; a bus cannot output to a bus or send (`busRoutingFixed`, `setTrackOutput` :3203-3217).
- One send per source track per bus (`duplicateSend`, `addSend` :3225-3243).
- Routing changes are refused while recording (`requireRoutingMutationAllowed` :3087-3092). The guard's own comment lists a
  fresh strip wired trivially to master as *"the ONE live-proven attach-only case"* (:3075-3086); a batch of new strips
  arriving already routed is a new shape for the engine's reconcile (§5.5).
- A sidechain key sits on a **compressor or gate**; the keyed strip must be an **audio track or a bus** (an instrument
  strip has no input bus for a key); the key source must not be a bus; no feedback loop; one keyed effect per strip
  [R `setSidechain`'s doc comment and body; `Sources/DAWCore/Sidechain.swift:9-16`; cycle search `cyclePath` :63-96].
  **So "pumping pads" means: route the pads into a bus, and key the bus's compressor from the drums.**

### 2.5 Modulation

All [R `Sources/DAWCore/Modulation.swift`]:

- Four source kinds, `lfo`, `stepSequencer`, `envelopeFollower`, `macro` (:28-32); at most 16 sources and 64 routes per
  strip, and lanes plus modulated effect settings share the 64 (:431-443).
- A route's target is the same `AutomationTarget` automation uses: `volume`, `pan`, `sendLevel` (refused by modulation),
  `effectParam(effectID, paramName)`, `instrumentParam(paramName)` [R `Sources/DAWCore/Automation.swift:18-43`]. The
  `effectParam` form names the effect by **UUID**, so a template needs its own reference form (§4.4).
- Source settings already have a **pure named applier** with unknown-key refusal and clamp-and-warn:
  `ModulationSourceParams.apply(_:to:)`, which returns the new settings **and a list of warnings** (:928-930; the LFO's
  valid names :977). An envelope follower can only follow its own strip in v1
  (`crossStripKeyUnsupported`, :200-216, :1060-1066), so nothing cross-track needs remapping.
- The store's route checks, `validate(target:on:)` and `checkCombinedTrackBudget`, **look tracks up in the live store**
  [R `Sources/DAWCore/ProjectStore+Modulation.swift:260-400`]. A template's tracks do not exist yet, so these must become
  pure functions over `Track` values (§5.2).

### 2.6 The two scaffolds that exist

- **`macro.songSkeleton`** → `ProjectStore.applySongSkeleton` [R `SongSkeleton.swift:753-953`]: one `performEdit`, tempo,
  the roster with fresh mixer-preset chains and GM programs, an "Arrangement" guide track, a marker per section, the loop.
  Additive; 14 genres [R :137-153]; roster 1…24 tracks [R :695]; buses refused [R :816-825]; instruments only through
  `program` [R :56, :870-880].
- **`mixer.applyPreset`**: replaces ONE strip's insert chain with a preset; *"volume/pan/sends are never touched"*;
  12 presets [R case `mixer.applyPreset`; `MixerPresets.swift:5-10, 101-115`].
- **No template verbs exist** [M: `grep -c '"template\.' Sources/DAWControl/Commands.swift` → 0; positive control
  `grep -c '"macro\.'` → 3].

### 2.7 Hand-maintained surfaces this feature reaches

Found by reading and by per-file `grep -c`, not by a remembered count:

| Surface | Today | This design |
|---|---|---|
| `addableEffectKinds` [R `MixerStripView.swift:11-14`] | All 22 built-in kinds | **No change**: no new effect kind. Re-verify in TPL-6. |
| `InstrumentPickerModel.builtIns` [R `InstrumentPickerModel.swift:200-219`] | Poly Synth, Drum Machine, Sampler; Test Tone in Pro | **No change**: no new instrument kind. |
| Agent tool lists, `claude-plugin/agents/*.md` [M: `grep -c` per tool per file] | `macro_song_skeleton` only in `producer.md` (2 lines); `mixer_apply_preset` only in `mix-engineer.md` (2); `instrument_load_drum_preset` only in `sound-designer.md` (2) | Add the template tools (TPL-9). Regeneration alone does not reach agents. |
| In-app Copilot catalog [M: `grep -c '"<verb>"' Sources/DAWControl/CopilotCatalog.swift`] | `macro.songSkeleton` 0, `mixer.applyPreset` 0, `playbox.generate` 0; controls `track.add` 1, `fx.add` 1, `track.setInstrument` 1 | Add `template.list`, `template.describe`, `template.apply` (TPL-6). |
| `DemoRender` verb mirror [R `DemoRender.swift:16-25`] | A small, hand-mirrored set | Add `template.apply` for the gates (TPL-4). |
| MCP `macro_song_skeleton` prose and `songSkeletonTrackSchema` [R `server.ts`] | Hand-duplicated roster prose | Add `template` and `dryRun`; shrink the roster prose to one line per genre and point at `dryRun` (§6.2). |
| `EffectDocument` and `withFreshID` per-kind lists [R `ProjectDocument.swift:705-915`; `MixerPresets.swift:38-77`] | Compiler-silent per-kind lists | **Not extended.** Templates carry effect settings by name; they reach `withFreshID` only through `freshChain()` for a `mixerPreset`, exactly as the skeleton does today. |
| `claude-plugin/skills/daw-wire-reference/SKILL.md` | Hand-maintained wire table | Add the seven verbs (TPL-9). |
| `claude-plugin/agents/composer.md` | [M] `grep -n -i 'kick\|snare\|hi-hat\|drumSynth\|percussion'` → one unrelated line (:144) | Teach the drum note layout (TPL-0). |

---

## 3. The drum machine plays the wrong drums for General MIDI beats, and TPL-0 fixes it for templates

### 3.1 The facts

- **Our drum machine's notes are 36–43 in its own voice order**: kick 36, snare 37, closed hat 38, open hat 39, clap 40,
  tom 41, rim 42, cymbal 43. Its source says so and says why: *"GM percussion is deliberately NOT followed: GM scatters
  these eight across 35–57, which would make the kit unplayable on a pad grid"* [R `Sources/DAWCore/DrumKit.swift:42-86`].
- **General MIDI's layout**, from the tree's own table [R `Sources/DAWCore/InstrumentFamilyResolution.swift:279-304`]:
  kick 35/36, snare 38/40, closed hat 42 (pedal hat 44), open hat 46, toms 41/43/45/47/48/50, crash 49/57, ride 51/59. Side
  stick 37 and hand clap 39 are GM notes that table deliberately leaves out of its family map.
- **What a General MIDI beat plays on today's drum machine** [D, from the two tables above]:

  | GM note, meaning | Drum machine plays |
  |---|---|
  | 36 kick | kick ✓ |
  | 37 side stick | **snare** ✗ |
  | 38 snare | **closed hat** ✗ |
  | 39 hand clap | **open hat** ✗ |
  | 40 electric snare | **clap** ✗ |
  | 41 low floor tom | tom ✓ (coincidence) |
  | 42 closed hat | **rim** ✗ |
  | 43 high floor tom | **cymbal** ✗ |
  | 46 open hat, 49 crash, 51 ride, 45/47/48/50 toms | **nothing** ✗ |

- **Everything that writes drum notes speaks General MIDI:**
  - The step sequencer's drum mode is gated on `SMFProjectExporter.isDrumKit`, which is true only for a percussion
    **sound bank** [R `Sources/DAWCore/ProjectMIDIExportMapper.swift:1016-1020`; `Sources/DAWAppKit/StepSequencerModel.swift:64-70,
    125-133`]. A drum-machine clip therefore opens as plain notes, with no drum lane names.
  - MIDI export puts a track on the GM drum channel only when that predicate says so
    [R `ProjectMIDIExportMapper.swift:423-427` `drumChannel = 9`; `:480` `if isDrumKit(track) { return drumChannel }`].
  - The composer agent, which writes the notes, is never told the drum machine's layout [M: `grep -n -i
    'kick\|snare\|hi-hat\|drumSynth\|percussion' claude-plugin/agents/composer.md` → one unrelated line, :144]. Only the
    sound designer is [R `claude-plugin/agents/sound-designer.md:211-213`].
  - The Playbox writes chords only, never drums [M: the `playbox.generate` case (95 lines) has 0 drum words, control
    `keyTonic` → 4; `Sources/DAWCore/PlayboxProgression.swift` has 0 drum words, control `chord` → 25].
- **Nothing consumes the 36–43 layout yet except hand entry**: hosting the drum machine on the pad grid is wave 4
  [R `docs/design/2026-09-20-drum-machine.md:879-884`].

### 3.2 Why it blocks templates

A built-in template that puts the drum machine on its "Drums" track hands the novice a track where every beat the AI
writes, every MIDI file they import, and every step they click plays **the wrong drum, loudly**. That is this tree's
recurring failure exactly: audibility is not correctness. The 09-20 spike's Q1 would have spread it across twelve genres.

### 3.3 The decision: an explicit, appended note layout, written by templates (option a)

- **`DrumKitParams.noteLayout`: `pads` (today's 36–43) or `gm`.** It is a kit-level **structural** setting like
  `chokeGroup`, not one of the 75 continuous parameters: `instrument.setDrumParam` and modulation both refuse it, the
  `chokeGroup` precedent [R `claude-plugin/agents/sound-designer.md:236-240`].
- **Absent means `pads`, bit for bit.** The kit's decoder already *"starts from the defaults, then overwrites only what is
  present"* [R `DrumKit.swift:736-760`], so every saved kit, every existing wire caller and every existing render pin is
  unchanged. The layout is stored as an optional (`nil` = `pads`) and encoded only when it is `gm`, so an existing kit's
  **saved bytes** do not change either: `pads` is never written.
- **Templates write `gm` explicitly.** The `gm` map, **one home** in `DrumVoice.voice(forNote:layout:)`:

  | Voice | `pads` (today) | `gm` |
  |---|---|---|
  | kick | 36 | 35, 36 |
  | rim | 42 | 37 |
  | snare | 37 | 38, 40 |
  | clap | 40 | 39 |
  | closed hat | 38 | 42, 44 |
  | open hat | 39 | 46 |
  | tom | 41 | 41, 43, 45, 47, 48, 50 |
  | cymbal | 43 | 49, 51, 52, 53, 55, 57, 59 |

  Honest limits, stated in `instrument.describeDrumKit`'s reply rather than discovered: every tom note plays the one tom
  voice at one tuning; crashes and rides share the one cymbal; GM notes outside the table (54 tambourine, 56 cowbell, …)
  are silent and **listed**.
- **`SMFProjectExporter.isDrumKit` also answers true for a drum machine in `gm` layout.** That one predicate is what the step
  sequencer and MIDI export ask, so both follow. TPL-0 starts with a census of every caller [method:
  `grep -rn 'isDrumKit(' Sources`; on 2026-09-27 it returned five call sites: `StepSequencerModel.swift:64` (doc),
  `ProjectTranspose.swift:276`, `ProjectMIDIExportMapper.swift:480`, `StepSequencerStaging.swift:164`,
  `ContentView.swift:1917`], each checked for what "true" now means for a drum machine.
- **Why the layout lives inside the kit, not beside it on the instrument.** The store's own rule: the kit travels as one
  value that each edit *mutates*, so "a 76th parameter added to `DrumKitParams` tomorrow rides through all three paths
  with no edit here at all" [R `ProjectStore.swift:4172-4183`]. A new field on `InstrumentDescriptor` would instead have
  to be named by hand in the explicit initialiser `setInstrument` rebuilds on every call, which "compiles fine without"
  it and would delete it on every unrelated edit, with a success reply [R `ProjectStore.swift:4097-4103`, `:4195-4255`].
  That is the m39-g failure; I do not re-open it.
- **The cost of living inside the kit: two places treat a whole kit as a preset, and both must learn that the layout is
  not part of the sound.** TPL-0 fixes both, each with a test:
  1. `instrument.loadDrumPreset` replaces the whole kit [R `Commands.swift:2561-2577`, "WHOLESALE"]. Every factory preset
     has the default layout, so loading "909" onto a drum machine in `gm` layout would silently move every drum back to
     the pad keys, and every GM beat on that track would play the wrong drums. **Rule: a preset changes how the drums
     sound, never which key plays which drum.** One DAWCore home, e.g. `DrumKitParams.applyingPreset(_:)`, which keeps
     the current layout; the wire verb and `DemoRender` [R `DemoRender.swift:654`] both call it.
  2. `instrument.probeLiveness` names the preset a kit came from by whole-value equality,
     `DrumKitParams.presets.first { $0.params == kit }` [R `ProjectStore+TimbreLiveness.swift:186`]. A `gm`-layout
     "lofi" kit would be reported as a "custom kit". The comparison must ignore the layout.
  Census method, re-run by TPL-0 before and after: `grep -rn "DrumKitParams.preset\|DrumKitParams.presets" Sources`
  [M 2026-09-27: 8 lines in 3 files, `Commands.swift` ×5 (`:2552`, `:2558`, `:2571`, `:2573`, `:16930`),
  `DemoRender.swift` ×2, `ProjectStore+TimbreLiveness.swift` ×1; the definition in `DrumKit.swift:815` spells it
  `presets` and does not match, so the pattern misses unqualified uses inside `DrumKitParams` extensions]. TPL-0 also
  reads every `DrumKitParams` equality; my grep for `== kit`/`drumKit ==` found only the one above, and TPL-0 repeats it
  with a positive control.
- **Wire, additive:** `track.setInstrument`'s `drumKit` object accepts `noteLayout` (⚠️ implementer trap: `parseDrumKit`
  sends every non-voice key to its kit-level branch, which throws *"must be a number"*, so `noteLayout` needs its own
  case **before** that branch [R `Commands.swift` fn `parseDrumKit`]); `instrument.describeDrumKit` reports
  `noteLayout` and `voiceNotes` (`{kick: [35, 36], …}`); `instrument.setDrumParam` refuses the name with a sentence that
  points at `track.setInstrument`. MCP: `track_set_instrument`'s nested `drumKit` schema gains the key (nested schemas
  must be `.strict()`, the m30-c law [R `mcp-server/test/nested-strict-gap.test.ts:1-30`]).
- **Agents:** `composer.md` and `sound-designer.md` learn one rule: *read `voiceNotes` from `instrument_describe_drum_kit`
  before writing drum notes.*
- **Not in this wave:** the instrument picker's default layout for a NEW drum machine. Changing a shipped control's
  default for new instances is the m39-ac-2 shape, which went to the user; it belongs with wave 4's pad-grid work. My
  recommendation for then: `gm`.

### 3.4 Render-thread rules for TPL-0 (needs `daw-architect` review)

The lookup runs at note-on on the render thread: `DrumSynthInstrument.handle` → `DrumVoice.voice(forNote:)`
[R `Sources/DAWEngine/Instruments/DrumSynthInstrument.swift:494-497`; `DrumKit.swift:82-85`].

1. The layout reaches the render thread inside the kit parameters the engine already hands the instrument, at creation
   and on every change [R `Sources/DAWEngine/PlaybackGraph.swift:757`, `:2146`]. It is never read from the model on the
   render thread.
2. `DrumVoice.voice(forNote:layout:)` is a `switch` over `(layout, note)` returning an optional enum. **No `static let`
   table, dictionary or array**: a lazily initialised global is allocated, and guarded by `swift_once`, on its first
   touch, which could be the render thread.
3. A layout change takes effect at the next note-on; a sounding hit is latched, the drum machine's own law
   [R `sound-designer.md:233-235`].

⚠️ **Finding F-4 (unverified, for the RT reviewer):** today's lookup scans `DrumVoice.allCases` at every note-on. The
synthesized `allCases` is a computed array; whether the optimiser emits a static constant or allocates per call was not
measured. The `switch` removes the question either way.

### 3.5 Fallback (option b), if TPL-0 is declined or slips

The built-in templates that would carry the drum machine (§7.1: Pop Band, House Club, Hip-Hop 808, Lo-Fi Chill) ship with
the GM kit instead: one field each. A catalog-integrity test forbids `drumSynth` in the built-in catalog unless its layout
is `gm`. The drum machine then reaches templates only through templates users save themselves.

---

## 4. The template model (DAWCore: pure, headless, Foundation only)

### 4.1 The rule behind the shape: every block is a verb you already know

A template's JSON is made of the parameter objects of verbs that already exist, minus their ids, plus template-local
keys. An agent that can call the verbs can write a template, and one names table serves both.

| Template block | Mirrors | Wire keys it reuses [R, by case label in `Commands.swift`] |
|---|---|---|
| a track | `track.add` | `name`, `kind` |
| `instrument` | `track.setInstrument` | `kind`, the 24 flat Poly Synth names, `sampler`, `audioUnit`, `soundBank`, `drumKit` |
| `instrument.drumPreset` | `instrument.loadDrumPreset` | its `name` (template sugar, applied first) |
| each `inserts[]` item | `fx.add` | `kind`, `params`, `audioUnit` |
| `inserts[].sidechainSource` | `fx.setSidechain` | `sourceTrackId`, as a track **key** |
| `mixerPreset` | `mixer.applyPreset` | the preset name (sugar, placed before `inserts`) |
| `output` | `track.setOutput` | `busId`, as a bus **key** (absent = the master) |
| each `sends[]` item | `track.addSend` | `busId` → `bus` (a key), `level` |
| each `modulation.sources[]` item | `mod.addSource` | `kind`, `params`, `name` |
| each `modulation.routes[]` item | `mod.addRoute` | `target`, `depth`, `enabled`; `sourceId` → `source` (a key) |
| a route's `target` | the flat `{type, sendId?, effectId?, param?}` object | `type`, `param`; `effectId` → `insert` (a key) |

### 4.2 The types

New file `Sources/DAWCore/TrackSetTemplate.swift`. Value types; `Sendable`, `Equatable`, nonisolated.

```swift
public struct TrackSetTemplate: Sendable, Equatable {
    public static let currentFormatVersion = 1
    public var formatVersion: Int          // who wrote it
    public var minReaderVersion: Int       // the oldest reader that applies it correctly
    public var id: String                  // built-in: kebab-case ("lofi-chill"); saved: "user-<uuid>"
    public var name: String                // 1–40 characters
    public var summary: String?            // one sentence a novice can read, ≤ 200 characters
    public var songForm: String?           // a SongSkeletonCatalog genre name, used by "Start a song"
    public var genres: [String]            // SongSkeletonCatalog genre names this template suits
    public var tracks: [TemplateTrack]     // 1–24
}

public struct TemplateTrack: Sendable, Equatable {
    public var key: String
    public var name: String
    public var kind: TrackKind             // .instrument | .audio | .bus
    public var volume: Double              // Track.volumeRange, default 1
    public var pan: Double                 // Track.panRange, default 0
    public var instrument: InstrumentDescriptor?  // RESOLVED; instrument tracks only
    public var mixerPreset: String?        // built by MixerPreset.freshChain(), before `inserts`
    public var inserts: [TemplateInsert]
    public var output: String?             // a bus key; nil = the master
    public var sends: [TemplateSend]
    public var modulationSources: [TemplateModSource]   // JSON: modulation.sources
    public var modulationRoutes: [TemplateModRoute]     // JSON: modulation.routes
}

public struct TemplateInsert: Sendable, Equatable {
    public var key: String?                // needed only when a route targets this insert
    public var kind: EffectDescriptor.Kind
    public var bypassed: Bool
    public var params: [String: Double]    // sparse; names validated against EffectParamSpec.specs(for:)
    public var sidechainSource: String?    // a non-bus track key
    public var audioUnit: AudioUnitConfig? // kind == .audioUnit only
}

public struct TemplateSend: Sendable, Equatable { public var bus: String; public var level: Double }

public struct TemplateModSource: Sendable, Equatable {
    public var key: String
    public var kind: ModulationSourceKind
    public var name: String?               // nil = the name mod.addSource would give it
    public var params: ModulationSourceParams     // RESOLVED
}

public struct TemplateModRoute: Sendable, Equatable {
    public var source: String              // a source key on the same track
    public var target: TemplateTarget
    public var depth: Double               // ModulationRoute.depthRange, −1…1
    public var enabled: Bool
}

public enum TemplateTarget: Sendable, Equatable {
    case volume, pan
    case instrumentParam(param: String)
    case effectParam(insert: String, param: String)   // an insert key on the same track
}
```

Why these shapes, each against the model [R]:

- **Instruments are stored resolved**, as the model's own `InstrumentDescriptor` [R `Model.swift:1848-1919`]: an
  instrument has no identity, so a resolved value can be applied any number of times. The codec resolves the JSON once,
  starting from the factory values, and the builder copies the value.
- **Inserts are stored as a kind plus sparse named settings**, not as an `EffectDescriptor`, because an effect has an
  identity (`id` is a `let` [R `Effects.swift:278`]). The builder makes every insert fresh at apply time with
  `EffectDescriptor.newlyAdded(kind:)` and the ONE named writer (§5.2), so applying twice can never share an id, and the
  template never touches the compiler-silent per-kind copy list in `withFreshID()` [R `MixerPresets.swift:38-77`]
  except through `mixerPreset`, exactly as `macro.songSkeleton` does today [R `SongSkeleton.swift:850-862`].
- **`mixerPreset` stays a reference in memory**, built by `freshChain()` [R `MixerPresets.swift:35`], so the skeleton's
  own rosters keep building byte-identical chains through the shared builder (§8.4).
- **`sendLevel` is not a route target**: modulation refuses it today (`sendLevelUnsupported`)
  [R `ProjectStore+Modulation.swift:266-270`], so the template type cannot even spell it.
- **A modulation source's `name` is optional** because `mod.addSource`'s is [R `ProjectStore+Modulation.swift:57-74`];
  the model's `ModulationSource.name` is not optional [R `Modulation.swift:354-358`], and the builder fills it the same way.
- **Sends carry only a bus and a level**: that is all a `Send` is [R `Model.swift:1720-1727`]; there is no pre-fader flag.

### 4.3 One example, in full

The same JSON is a built-in template, a saved `.dawtemplate` file, an inline wire object, and a `template.describe`
reply. Every key is a real verb key and every setting name is a real `fx.describe`, `mod.addSource` or
`track.setInstrument` name [R `Effects.swift` `EffectParamSpec.specs(for:)`, djFilter `position` :4657-4660, hall
reverb ranges :2028-2029; `Modulation.swift:67-73`, `:977`]. **The numbers are [A]**; TPL-4 tunes them by measurement
and listening.

```json
{
  "format": "dawpro.template",
  "formatVersion": 1,
  "minReaderVersion": 1,
  "id": "lofi-chill",
  "name": "Lo-Fi Chill",
  "summary": "Dusty drums, a warm electric piano and a round bass, in a small, worn-tape room.",
  "songForm": "lo-fi",
  "genres": ["lo-fi"],
  "tracks": [
    { "key": "drums", "name": "Drums", "kind": "instrument", "volume": 0.9,
      "instrument": { "kind": "drumSynth", "drumPreset": "lofi", "drumKit": { "noteLayout": "gm" } },
      "inserts": [ { "kind": "saturator", "params": { "driveDb": 4 } } ],
      "sends": [ { "bus": "room", "level": 0.2 } ] },
    { "key": "bass", "name": "Bass", "kind": "instrument", "mixerPreset": "bass-round",
      "instrument": { "kind": "soundBank", "soundBank": { "source": "gm", "program": 33 } } },
    { "key": "keys", "name": "Keys", "kind": "instrument", "output": "duck", "mixerPreset": "warm-keys",
      "instrument": { "kind": "soundBank", "soundBank": { "source": "gm", "program": 4 } },
      "inserts": [ { "key": "tone", "kind": "djFilter", "params": { "position": -0.25 } },
                   { "kind": "chorus" } ],
      "sends": [ { "bus": "room", "level": 0.3 } ],
      "modulation": {
        "sources": [ { "key": "breathe", "kind": "lfo", "params": { "waveform": "sine", "rateHz": 0.25 } } ],
        "routes": [ { "source": "breathe", "depth": 0.1,
                      "target": { "type": "effectParam", "insert": "tone", "param": "position" } } ] } },
    { "key": "vinyl", "name": "Vinyl FX", "kind": "audio", "mixerPreset": "lofi-tape" },
    { "key": "duck", "name": "Keys Duck", "kind": "bus",
      "inserts": [ { "kind": "compressor", "sidechainSource": "drums",
                     "params": { "thresholdDb": -24, "ratio": 3, "attackMs": 5, "releaseMs": 180 } } ] },
    { "key": "room", "name": "Tape Room", "kind": "bus",
      "inserts": [ { "kind": "hallReverb", "params": { "mix": 1, "sizeMeters": 12, "decaySeconds": 1.2 } } ] }
  ]
}
```

- The pumping keys show the §2.4 rule: "Keys" is an instrument track, which cannot be keyed, so it outputs into the
  "Keys Duck" bus, and that bus's compressor listens to the drums.
- "Vinyl FX" is an **audio** track, because the skeleton's law is that `.audio` is for recorded material and every
  playable part is `.instrument` [R `SongSkeleton.swift:130-134`]. A built-in-catalog test pins it for templates too.
- The lo-fi skeleton's own roster uses the same two GM programs, 33 and 4 [R `SongSkeleton.swift:569-571`].

### 4.4 Keys and references

- Every track has a `key`: 1–32 characters of lowercase letters, digits and hyphens [A], unique in the template. Inserts
  and modulation sources carry a key only when something refers to them; unique within their track.
- `output` and `sends[].bus` name a **bus** key; `sidechainSource` names a **non-bus** track key; a route's `source` names
  a source key on the same track; a route's `target.insert` names an insert key on the same track.
- **Every reference must resolve inside the same template, or the whole template is refused before any edit**, naming
  the path and what does exist: *"tracks[2].sends[0]: there is no bus with the key 'verb'. The buses in this template
  are: room, duck."*
- **Nothing is matched by name, and nothing is matched against the song.** A template never routes into a bus that
  already exists in the project (§11).
- `template.apply`'s reply maps every key to the new track's id, so an agent continues by key, never by name.

### 4.5 How each block is read

A template's instrument block **must name its `kind`**. `track.setInstrument` can infer a kind from `soundBank` or
`audioUnit` [R `Commands.swift:1790-1796`], but not from `drumKit` (§1.2); a template takes no inference at all.

- **Effects.** Names are checked against `EffectParamSpec.specs(for:)`; at apply time each insert starts from
  `EffectDescriptor.newlyAdded(kind:)` [R `Effects.swift:416-437`] and its settings are written **in `specs(for:)`
  order** through the ONE writer (§2.3, §5.2). `mixerPreset` is built by `freshChain()` and placed **before** `inserts`.
- **Poly Synth.** The 24 flat names `track.setInstrument` takes, whose ranges already live in DAWCore as
  `PolySynthParams` statics [R `Model.swift:2944-2977`], and whose property names are the wire names
  [R `Model.swift:2819-2943`; `PolySynthDescription.swift:35-43`]. The names list moves to DAWCore in TPL-1 (§5.2). The
  model's own decoder is **not** used: it requires its first eight fields [R `Model.swift:3185-3195`].
- **Drum machine.** `drumPreset` first: the whole kit of that factory preset, matched without regard to case
  [R `DrumKit.swift:843-845`]. Then `drumKit`, parsed as the overlay `track.setInstrument` parses it: voice objects of
  leaf numbers, `chokeGroup` a number or null, kit-level leaves at the top, the read-only `note` ignored
  [R `Commands.swift` fn `parseDrumKit`], plus TPL-0's `noteLayout`. `drumKit` or `drumPreset` with any `kind` other
  than `drumSynth` is **refused**: the wire's silent "kit stored, saw synth plays" (§1.2) is not inherited. The names
  have one home already (`setValue`, `paramSpecs`); the object's grammar is read twice, by the wire and by the codec,
  and a parity test pins the two together (§5.2).
- **Sound bank.** `{source: "gm" | "<absolute path>", program, bankMSB?, bankLSB?}`, the object `track.setInstrument`
  takes [R `Commands.swift:1790-1796`]. The display name is derived, never stored (§4.6).
- **Sampler** (saved templates only). The same `sampler` object `track.setInstrument` takes. [A] that it can express
  every field a saved sampler has; TPL-5's round trip over a real imported multi-zone library proves it, and a missing
  field is fixed in the wire object, never in a template-only side channel.
- **Audio Unit** (saved templates only). The wire's `{type?, subType, manufacturer}` object **plus `state`**, the base64
  of `AudioUnitConfig.stateData`. The wire has no way to carry an Audio Unit's saved sound today (`parseAudioUnit` builds
  the config with `stateData: nil` [R `Commands.swift` fn `parseAudioUnit`; `Model.swift:1828-1845`]); without `state`,
  a saved template would bring the plugin back with its default sound, which is not "saving my setup".
- **Modulation sources.** `ModulationSourceParams.apply(_:to:)` over the kind's defaults: already pure, already refuses
  unknown names, and its warnings are passed through [R `Modulation.swift:928-930`, `:977`, `:1020`].

### 4.6 The canonical form, and the round-trip invariant

`template.describe` and `template.save` emit the **canonical** form: keys sorted; each setting written **only if its named
reading differs from a fresh one's** (an insert against `newlyAdded(kind:)`, read with `paramValue(_:)`
[R `Effects.swift:6104-6122`]; the synth against `PolySynthParams()`; the kit against the factory kit; a modulation
source against its kind's defaults); `mixerPreset` and `drumPreset` expanded into what they built; defaults omitted
(`volume` 1, `pan` 0, `bypassed` false, output to the master, `enabled` true); display names never written.

- **The invariant**, tested over every built-in template and over randomised settings reachable through the named
  surfaces: `canonical(capture(apply(T))) == canonical(T)`.
- **It is stated on named readings, not bytes, on purpose.** A preset chain can store a default explicitly where a fresh
  effect stores nothing (an explicit `EQParams()` versus `eq: nil`); both read, and sound, identical. Byte identity is
  asserted where it is true and matters: the skeleton golden gate (§8.4).
- **Sparse-against-fresh keeps a legacy clipper's sound** [D]: a clipper saved before the 2026-09-20 ruling reads
  `oversampling` 4 through `resolvedClipper` [R `Effects.swift:342-355`], a new one reads 1, so the 4 is written and
  survives the round trip.
- A state the named surfaces cannot express is a hole that `fx.setParam` cannot reach either. Fix the surface; never add
  a template-only side channel. (Audio Unit `state` is not a hole of this kind: it is an opaque blob the project file
  already stores.)
- **Sound-bank display names are derived, never written**, from `GMProgramCatalog` for General MIDI (the skeleton's way
  [R `SongSkeleton.swift:870-880`]) and as `"<file name> · P<n>"` for a bank file (the wire's own fallback
  [R `Commands.swift` fn `deriveSoundBankName`]). **Finding F-7:** the two existing scaffolds already label the same GM
  program differently, because the wire reads the loaded bank's names; cosmetic, recorded, not fixed here.

### 4.7 Versioning and forward compatibility

Every file carries `formatVersion` (who wrote it) and `minReaderVersion` (the oldest reader that applies it correctly).
This build reads `currentFormatVersion = 1`.

- `minReaderVersion` above the reader's version: the whole file is refused. *"This template needs a newer version of DAW
  Pro."*
- Otherwise, **one rule per element: a problem the reader can blame on the author is refused; a problem it can blame on a
  newer writer is skipped with a coded warning.**

| Problem | `formatVersion` ≤ this reader's, or omitted (every inline wire template) | `formatVersion` > this reader's |
|---|---|---|
| An unknown key, at any level | Refused, naming the path and the valid keys (the D2 lesson) | Skipped; `unknownKeySkipped` |
| An unknown effect kind | Refused | The insert is skipped, and so is anything that refers to it; `unknownEffectSkipped` |
| An unknown instrument kind | Refused | **The whole track is skipped**, and so is anything that refers to it; `unknownInstrumentSkipped`. Never a substitute sound. |
| An unknown setting name | Refused, listing the kind's valid names | Skipped; `unknownSettingSkipped` |
| An unknown modulation source kind or target type | Refused | The source or route is skipped; `unknownModulationSkipped` |
| A value out of range | Refused, naming the range | Clamped; `valueClamped` |

- **Refusing an out-of-range value is stricter than `fx.add` and `mod.addSource`, which clamp and warn** (the m27-c
  precedent [R `Modulation.swift:916-919`; `Commands.swift` case `fx.add`]). It is deliberate and it follows the newer
  law, m34-q: *"an out-of-range value is REFUSED with a readable error rather than clamped, because an agent that asked
  for 20 unison voices and silently got 8 has no way to find out"* [R `Commands.swift:1723-1727`, case
  `track.setInstrument`]. A template is written once and applied many times, so a value that does not hold is a bug to
  fix where it was written. The check is the read-back rule (§5.3), which also catches values that snap.
- **Kinds are judged as raw strings.** The codec never decodes a kind straight into a typed enum, so this format does not
  inherit the project format's hole (**Finding F-1**, §16: an unknown instrument kind fails a whole project open).
- An older file cannot legitimately contain a key, kind or range the current reader lacks, because kinds and settings are
  append-only and ranges only widen; the tree already records that *lowering* a range "would silently re-clamp stored
  values on load" [R `Effects.swift:446-473`]. Narrowing a range is therefore a migration and must bump
  `minReaderVersion`.
- **A writer bumps `minReaderVersion` only for a change that older readers would apply wrongly**, not merely
  incompletely. v1 writes 1.
- Warnings are machine-readable, `{code, path, message}`; every `message` is a sentence a novice can read.
- **An inline wire template** may omit `format`, `id`, `formatVersion` and `minReaderVersion` (it is then read as the
  current version, strictly), and `summary`, `songForm` and `genres`. It must carry `name` (the undo step is called
  "Add Template '<name>'") and `tracks`. A file must carry `format`, `id`, `formatVersion` and `minReaderVersion` too.

### 4.8 Limits

- 1–24 tracks per template: the skeleton's ceiling [R `SongSkeleton.swift:690-695`], the same constant, so the two
  scaffolds cannot drift.
- Track and template names 1–40 characters: the skeleton's one-home bound for section and track names, which the MCP
  schema also pins [R `SongSkeleton.swift:686-689`]. Summaries ≤ 200 characters [A].
- Per strip: 16 modulation sources, 64 routes, and the shared 64-slot budget [R `Modulation.swift:431-443`]. A new
  track has no automation, so the budget a template uses is its count of distinct modulated effect settings.
- A template file is refused above 2 MB [A: bounds the main-actor decode; Audio Unit `state` is the only large field;
  TPL-5 measures real Audio Unit states and sets the final bound].

### 4.9 What a template never contains

| Not in a template | Why |
|---|---|
| Notes, MIDI clips, audio, recordings | Content, not sound. Wave 4 owns patterns and loops. |
| Tempo, time signature, sections, markers, the loop, the "Arrangement" track | Song form belongs to `macro.songSkeleton`, which gains a `template` parameter. |
| Automation lanes | They are positioned in the beats of one song. |
| The master chain | A template adds a band; it must never replace the master you already have. |
| Colour | No such field exists (§2.1). |
| Mute, solo, arm, the AI-made flag | Session state and provenance, not sound. |
| Routing into buses already in the song | That needs matching against the project: the silent-mismatch class (§11). |
| One track playing several instruments at once | A different feature (a "layer"); §12 asks whether it is wanted. |

---

## 5. How it is built: codec, builder, store

### 5.1 The layers, and who may call whom

```
 .dawtemplate file ─┐                                   ┌─ template.apply ─────────┐
 built-in catalog ──┼─► TrackSetTemplateCodec ─► TrackSetTemplate ─► TemplateBuilder.plan ─► TemplatePlan
 inline wire JSON ──┘   (DAWCore, pure: names,   (value types)      (DAWCore, pure: keys,     │
                         ranges, versions)                          routing, budget, ids)      ▼
                                                   ProjectStore.applyTemplate (@MainActor): resources,
                                                   recording guard, ONE performEdit, engine notify
 macro.songSkeleton ─► genre roster ─► TemplateTrack[] ─────────────────► the same plan + the same store path
 template.save ◄── TemplateCapture (DAWCore, pure: live Tracks ─► canonical TrackSetTemplate)
```

- **Everything above the store is pure, nonisolated, Foundation-only DAWCore.** It is tested headless, in new test files,
  with no main actor (§5.8).
- **The store adds only what needs the live project**: file-backed resources, the recording guard, the edit, the engine.
- **DAWControl, the MCP server and the UI never build tracks themselves.** They pass a template (an id or JSON) to the
  store. `DemoRender` gets `template.apply` by calling the same store function (§8).

### 5.2 TPL-1: move five rules to one home each, before anything uses them

The builder must check a template's tracks **before they exist**, so every rule it shares with a live verb must be a pure
function over `Track` values that the live verb also calls. Today several are private or read the live store. Each move
is **byte-identical** for the live verb: the verb's existing tests are the gate, plus one new test per move that the
store method and the pure function agree on a table of cases.

| Rule | Today [R] | Moves to (DAWCore) | Used by |
|---|---|---|---|
| Write one effect setting by name | `ProjectStore.applyEffectParam`, `private static` (`ProjectStore.swift:3711`) | `EffectDescriptor.applySetting(_:_:)`, internal, mutating | `fx.setParam`, `fx.add`, the builder |
| Which modulation targets are allowed, and the shared 64-slot budget | `validate(target:on:)` (:260) and `checkCombinedTrackBudget` (:374) in `ProjectStore+Modulation.swift`, reading tracks from the store | `ModulationRules.validate(target:on: Track)`, `ModulationRules.slotsUsed(by: Track)` | `mod.addRoute`, `automation.addLane`, the builder |
| Sidechain: compressor or gate; audio or bus destination; non-bus source; no loop; one key per strip | Inline in `setSidechain`, plus the pure `cyclePath` (`Sidechain.swift:63-96`) | `SidechainRules.check(...)` beside `cyclePath` | `fx.setSidechain`, the builder |
| Sends and outputs: a bus outputs only to the master, no bus sends, one send per source per bus | Inline in `setTrackOutput` (:3203-3217) and `addSend` (:3225-3243) | `RoutingRules.check(...)` | `track.setOutput`, `track.addSend`, the builder |
| The 24 Poly Synth setting names | `PolySynthDescription.order`, **DAWControl** (`PolySynthDescription.swift:35-43`); ranges already in DAWCore (`Model.swift:2944-2977`) | `PolySynthParams.settingNames` plus a name-to-property table | `track.setInstrument` (its key list), `instrument.describeSynth`, the codec |

Two more shared pieces stay where they are, pinned instead of moved:

- **The drum kit object grammar.** `parseDrumKit` reads the wire's `JSONValue` [R `Commands.swift` fn `parseDrumKit`],
  which DAWCore cannot see (`JSONValue` is a DAWControl type [R `Sources/DAWControl/JSONValue.swift:5`]; [M] no JSON tree
  type exists in DAWCore: `grep -rn "case object(\[String" Sources/DAWCore Sources/AIServices` → no lines; the same
  pattern finds `JSONValue.swift:11`). The **names** already have one home, `DrumKitParams.setValue(_:forParamName:)`
  and `paramSpecs` [R `DrumKit.swift:695-708`]. The codec reads the same object shape through those, and a **parity
  test** runs one table of `drumKit` objects through both readers: every valid object gives the same kit, every unknown
  name is refused by both, and an out-of-range value is **clamped by the wire and refused by the codec**, by design
  (§4.7). The table asserts that difference explicitly, so a change on either side is noticed.
- **Clamp and refusal sentences** reuse `ClampNotice.sentence` [R `Sources/DAWCore/ClampNotice.swift:23`], the helper
  modulation and the wire already share.

### 5.3 The builder: `TemplateBuilder.plan`

New file `Sources/DAWCore/TemplateBuilder.swift`:

```swift
public struct TemplatePlan: Sendable, Equatable {
    public var tracks: [Track]                  // complete, wired among themselves, fresh ids
    public var keyToTrackID: [String: UUID]
    public var warnings: [TemplateWarning]      // {code, path, message}
    public var hasRouting: Bool                 // any output to a bus, send or sidechain key
    public var resources: [TemplateResource]    // file-backed items the store must check first
    public var slotsUsed: [String: Int]         // per track key: modulated effect settings (of 64)
}
public enum TemplateBuilder {
    public static func plan(_ template: TrackSetTemplate,
                            makeID: () -> UUID = UUID.init) throws -> TemplatePlan
}
```

It does, in this order, and **throws before returning anything** if any step fails:

1. **Checks references** (§4.4): every key resolves to the right kind of thing inside the template.
2. **Builds each track**: kind, name, volume, pan; the resolved instrument; `mixerPreset`'s `freshChain()` then each
   insert from `newlyAdded(kind:)` with its settings written in `specs(for:)` order; bypass flags.
3. **Applies the read-back rule to every written setting**: it must read back as written, within 1e-9 relative [A:
   TPL-1 measures the largest read-back error of in-range values over every spec and sets the bound]. A value that
   clamps, snaps (`phaser.stages` stores 6 when asked for 5) or is changed by a coupled setting fails here: refused for a
   same-version file, `valueChanged` warning for a newer one. **A setter's return is not proof it took; the reading is.**
   For modulation sources the applier already reports this itself: its `paramClamped` warning (a code, not free text
   [R `Modulation.swift:941-946`]) is treated exactly like a failed read-back.
4. **Wires**: outputs and sends by key, through `RoutingRules`; sidechain keys through `SidechainRules`, including the loop
   check over the template's own tracks (a template cannot route into or key from a track outside itself, so no loop
   can pass through the song).
5. **Adds modulation**: sources through `ModulationSourceParams.apply`, routes with `effectParam` targets resolved from
   insert keys to the new effect ids; each route through `ModulationRules.validate`, and each track's
   `ModulationRules.slotsUsed` ≤ 64. A `warned` target (the render-block alias note) becomes a plan warning, exactly as
   `mod.addRoute` returns it [R `Modulation.swift:420-427`].
6. **Lists the resources**: every sound-bank file, sampler zone file and Audio Unit component.

`makeID` is injected so tests are deterministic; production uses fresh UUIDs, so **applying twice can never collide**.

### 5.4 The store: `ProjectStore.applyTemplate(_:dryRun:)`

New file `Sources/DAWCore/ProjectStore+Templates.swift`, `@MainActor` like the store:

1. `TemplateBuilder.plan(template)`. A throw here records nothing.
2. **Checks every resource** with the store's existing validators, `validateSoundBank` (:4276) and `validateSamplerZones`
   (:4294), both `private` today and moved to module-internal in TPL-2 (the `performEdit` precedent: *"Module-internal
   (not private) so `ProjectStore+*` extension files funnel their mutations through the same seam"* [R
   `ProjectStore.swift:7836-7845`]). A missing Audio Unit is **not** a refusal: the track is created with the plugin
   reference, the way a project with a missing plugin opens, plus the warning `audioUnitMissing`.
3. **If `plan.hasRouting` and the transport is recording: refuse**, through `requireRoutingMutationAllowed` (:3087-3092),
   also moved to module-internal. A template of plain tracks with no routing is the guard's own *"attach-only"* case
   [R :3076-3078] and stays legal mid-take, exactly like `track.add`.
4. **`dryRun: true` stops here** and returns the full reply with `applied: false`. A dry run that succeeds means the apply
   will succeed unless the project changes in between (for example, recording starts).
5. **ONE `performEdit("Add Template '<name>'")`, with no coalescing key**, so it is exactly one undo step that never
   merges with a neighbour [R `ProjectStore.swift:7843-7845`]: append the planned tracks, then
   `engine?.tracksDidChange(tracks)` inside the edit, the skeleton's pattern [R `SongSkeleton.swift:935-942`].
6. Reply (§6.1).

Rules that follow from the order:

- **A refusal changes nothing and records no undo entry** (steps 1–3 run before the edit).
- **Additive and never idempotent**: applying twice adds the band twice, like the skeleton
  [R `SongSkeleton.swift:705-719`]. The new tracks never touch existing ones.
- **Names may repeat.** Track names are labels, not identities; the skeleton already lands its roster twice. The reply
  carries `duplicateTrackNames` so the UI can say *"You now have two tracks called Drums."* Nothing is renamed.
- **The master chain, tempo, markers, loop and every existing track are untouched.**
- **With `mixer.applyPreset` afterwards, nothing new happens:** a preset replaces the whole chain of the strip it is
  applied to, a template's sidechain-keyed compressor included, which is that verb's documented behaviour (*"the
  preset's insert chain REPLACES the strip's current chain"* [R `MixerPresets.swift:356-358`]). TPL-F9 makes its reply
  say when that removed a key, and refuses it mid-take.

### 5.5 The skeleton, re-pointed (TPL-3)

- `applySongSkeleton` gains `template: TrackSetTemplate?`. With it, the roster **is** the template's tracks; the form
  (tempo, sections, markers, "Arrangement" track, loop) is the genre's, as today. `template` and a `tracks` override
  together are refused: *"Use either a template or your own track list, not both."*
- **Without it, every genre's roster converts to `TemplateTrack`s** (name, kind, `mixerPreset`, the resolved GM
  instrument the skeleton builds today [R `SongSkeleton.swift:864-882`]) and is built by `TemplateBuilder`. The
  **golden gate** (§8.4): for all 14 genres, with and without a `tracks` override, the project JSON after the call is
  byte-identical to today's, ids aside.
- The edit label stays `"Song Skeleton '<Genre>'"` without a template, and becomes `"Song Skeleton '<Genre>' with
  '<Template>'"` with one. Still one `performEdit`.
- **D3 is fixed after the golden gate is green, as its own flagged step:** rock's "Drums" gets the GM Standard Drum Kit
  and its "Bass" GM program 33, the bass every other band genre uses [A: TPL-4's listening round may prefer 34, "Electric
  Bass (pick)"]. That step regenerates the rock fixture, and its diff must show exactly those two instruments and nothing
  else.
- A template with routing inherits step 3's recording guard. **Finding F-8:** the skeleton today changes the tempo
  through `applyTempoChange` [R `SongSkeleton.swift:939`], skipping both guards `setTempo` has, *"cannot change tempo
  while recording"* and the multi-segment tempo map refusal [R `ProjectStore.swift:945-951`; M: `grep -c
  "requireRoutingMutationAllowed\|isRecording\|transportBusy"` → 0 in `SongSkeleton.swift`, positive control 10
  `requireRoutingMutationAllowed` lines in `ProjectStore.swift`; `tempoMapOverride` → 0 in `SongSkeleton.swift`, control 4
  in `ProjectStore.swift`]. It is a pre-existing gap, not caused by templates; TPL-3 does **not** change it silently
  (the golden gate forbids that). It is item TPL-F8 (§10), flagged as a behaviour change.

### 5.6 The engine: no new render-thread code except TPL-0

- The only render-thread change in this wave is TPL-0's note-to-drum lookup (§3.4).
- A template arrives as **one reconcile with several new strips already routed to each other**. `PlaybackGraph.reconcile`
  is written for that: *"the step ORDER below is load-bearing: bus nodes are added before any source track wires into
  them"* [R `Sources/DAWEngine/PlaybackGraph.swift:1053-1055`]; step 5 wires every fresh node and every source *"whose
  referenced buses just appeared"* [R :1420-1425]; a key whose source is missing *"degrades to self-keyed — never a
  broken graph"* [R :1058-1064]. **[A] that a batch this size has been exercised**: every live-proven routing edit so far
  changed one strip. TPL-2 adds a headless engine test (a template of 6 routed strips, one reconcile, every bus receives
  signal, the key ducks), and TPL-4's render gate proves it again per built-in template.
- Each new instrument node is created off the render thread by the existing reconcile path, as the skeleton's up to 24
  new tracks are today. No allocation, lock or wait is added to the render path.
- **Modulation needs no extra publish.** A track strip's modulation edits already reach the engine through the same
  `tracksDidChange` call: *"`tracksDidChange` runs `applyParameters`, which is where the modulation snapshot is rebuilt
  and published"* [R `ProjectStore+Modulation.swift:501-503`, `:518-526`]. Only the master strip has a separate call
  (`masterModulationChanged`, :509-512), and a template never touches the master. **[A] that the snapshot is rebuilt for
  strips created in the same pass**; §8.7's "the LFO-routed setting moves" leg replaces it with a measurement.
- **During playback** (not recording), a template with routing causes the same graph rebuild any routing edit causes,
  the one the recording guard exists for. **[A] what a listener hears then** (a short gap, or nothing): not measured.
  TPL-2's engine test and TPL-8's dogfood step "Add to my song while it plays" observe it; if the gap is audible, the
  picker says so beside the button rather than hiding it.

### 5.7 Capture: `TemplateCapture` (TPL-5)

`TemplateCapture.capture(tracks: [Track], selected: [UUID], ...) -> (TrackSetTemplate, [TemplateWarning])`, pure:

- **Selected tracks, plus the buses they output or send to**, which are added automatically and reported
  (`busIncluded`): a send into a bus that is not saved cannot exist.
- **A sidechain source that is not selected is dropped, with a warning a novice can read**: *"The Keys Duck compressor
  listened to Drums, which you didn't save, so it will not duck."* The source track is **not** pulled in: that would add
  a track the user did not choose.
- Keys are derived from track names (lowercased, hyphenated, de-duplicated with `-2`, `-3`); they are local to the file,
  so this is naming, not matching.
- Settings are written sparse, against a fresh value's named reading (§4.6). Audio Unit `state` is copied as base64.
- Automation, clips, mute, solo, arm and the AI-made flag are never read.

### 5.8 Concurrency, tests and the main-actor budget

- `TrackSetTemplateCodec`, `TemplateBuilder`, `TemplateCapture` and the moved rules are nonisolated and `Sendable`: their
  tests go in **new test files with no `@MainActor`**.
- `ProjectStore+Templates.swift` is `@MainActor` because the store is. Its tests are **appended to existing `@MainActor`
  suites** (`SongSkeletonTests`, `MacroSkeletonCommandTests` [R `Tests/DAWCoreTests/SongSkeletonTests.swift:18-20`;
  `Tests/DAWControlTests/MacroSkeletonCommandTests.swift:15-16`]): the lane rule in force today is *"No new @MainActor
  suite. The cap is 394 and 393 are used"* (Wave 7 `common.md`). Re-read the cap at build time; it moves.
- The apply is synchronous on the main actor, like the skeleton. Loading General MIDI programs and our own instruments is
  the skeleton's proven cost. **Audio Units are the exception** (§2.2): a saved template that holds one warns before it
  loads (§9.3).

---

## 6. The wire and the MCP tools (TPL-6, TPL-7)

### 6.1 Seven new verbs

`template` below always means **either a template id** (a built-in's `"lofi-chill"` or a saved `"user-…"`) **or a whole
template object** (§4.3).

| Verb | Params | Reply | Refuses, in words |
|---|---|---|---|
| `template.list` | none | `{templates: [{id, name, summary, source: "builtIn"\|"saved", genres, songForm, trackCount, instruments: [kind], hasRouting, hasAudioUnits}], unreadable: [{file, message}]}` | never; an unreadable saved file is listed in `unreadable`, with the reason |
| `template.describe` | `{template}` | `{template: <canonical JSON>, tracks: [{key, name, kind, sound: "<one plain sentence>"}], slotsUsed, hasRouting, warnings}` | an unknown id; any codec refusal (§4.7) |
| `template.apply` | `{template, dryRun?}` | `{applied, name, tracks: [{key, id, name, kind}], warnings, duplicateTrackNames, undoLabel}` | an unknown id; any codec or builder refusal; a missing sound-bank or sample file; routing while recording |
| `template.save` | `{name, trackIds, summary?, songForm?, genres?, replaceId?}` | `{id, name, template: <canonical JSON>, warnings}` | no or unknown `trackIds`; more than 24 tracks after buses are added; a name over 40 characters; `replaceId` naming a built-in |
| `template.remove` | `{id}` | `{removed: id}` | a built-in id: *"Built-in templates can't be removed."*; an unknown id |
| `template.import` | `{path}` | `{id, name, warnings}` | a file that is not a template; any codec refusal; a file over 2 MB |
| `template.export` | `{id, path, overwrite?}` | `{path, bytes}` | an unknown id; an existing file without `overwrite: true`; a path the export policy refuses [A: the policy `project.exportMIDI` applies; TPL-6 reads it and matches it] |

- **`template.apply` is ONE undo step** (§5.4), has `dryRun`, is additive (twice adds twice), and changes nothing on a
  refusal.
- `template.save` writes one `.dawtemplate` file into the library folder, `AppDirectories` category `templates`
  (appended as `case templates = "Templates"` after W7-SC's singing categories [R `Sources/DAWCore/AppDirectories.swift:34-106`],
  so staging's `DAWPRO_PROFILE_ROOT` isolation [R :119, :205] covers it). `replaceId` overwrites a saved template in
  place; without it, saving never overwrites.
- `template.save` / `remove` / `import` / `export` change files, not the song: **no undo entry**, the
  `instrument.importSoundBank`-style file precedent [A: TPL-6 names the exact precedent verb it copies].

### 6.2 `macro.songSkeleton` gains two optional parameters

- `template` (optional): an id or a template object. `template` with `tracks` is refused (§5.5).
- `dryRun` (optional): builds the whole plan through the shared builder and returns what the call would create (track
  names, kinds, instruments, insert chains, the sections) with `applied: false` and **no ids**, changing nothing. This
  replaces the spike's proposed read verb `macro.describeSkeleton` [R `docs/design/2026-09-20-multi-instrument-templates.md:303-306`]
  with no new verb and no second code path: a dry run *is* the apply, stopped before the edit, so it cannot drift from it.
  It also lets TPL-7 shrink the MCP tool's hand-duplicated roster prose, which the spike measured at ~58 lines
  [R same file `:331-333`], to one line per genre plus *"call with `dryRun: true` to see exactly what it creates."*
- `rejectUnknownKeys` becomes `["genre", "tempoBPM", "sections", "tracks", "template", "dryRun"]`
  [R case `macro.songSkeleton`: today `["genre", "tempoBPM", "sections", "tracks"]`].
- The reply gains `templateKeys: {key: trackId}` when a template was used. Every existing reply field is unchanged.
- **D2 is fixed in the same item** (TPL-6): each `tracks[i]` rejects unknown keys, naming them, and a `program` key there
  gets a teaching refusal: *"A track list can't pick sounds. To choose instruments, pass a template."* **This is a
  behaviour change**: a call that sent a misspelled key inside `tracks` used to succeed while silently ignoring it. It is
  flagged in the CHANGELOG. [A: that no caller in the tree sends extra keys there; not measured for this design. TPL-6
  measures it over `mcp-server/src`, `claude-plugin`, `scripts` (with the excludes) and `Tests` before the change.]

### 6.3 Where they go in `allCommands`

Immediately **after `playbox.generate`**, before `automation.addLane` [R `Commands.swift:359`, `:375`, `:376`,
re-measured 2026-09-27]:

- `PlayboxCommandTests` pins `playbox.generate` at exactly `macro.songSkeleton` + 1 [R
  `Tests/DAWControlTests/PlayboxCommandTests.swift:86-88`], so nothing may go between those two.
- Seven test files read `allCommands.last` [M: `grep -rln "allCommands.last" Tests` → 7 files; the playbox pin is one of
  them], so nothing goes at the tail.
- The array's own rule: **no quoted strings in comments inside it** (the m25-d rule, stated in the playbox comment
  [R `Commands.swift:360-374`]).
- The command-count pins move by +7. Take the new total from `node scripts/gates/doc-count-drift.mjs` at merge time; other
  lanes are moving it today.
- The wire belongs to the wire-owning lane of whichever wave builds TPL-6 (Wave 7's `common.md`: a lane that needs a new
  wire command and is not the wire lane stops and says so).

### 6.4 Refusals and warnings, in words a novice can act on

Every refusal names the exact place and what to do. Examples, final wording in TPL-6 by `docs-scribe` review:

- *"tracks[2].sends[0]: there is no bus with the key 'verb'. The buses in this template are: room, duck."*
- *"tracks[4].inserts[0]: a sidechain can only be set on a compressor or a gate."*
- *"tracks[1]: a Poly Synth setting can only go on a track whose instrument is the Poly Synth."*
- *"tracks[0].instrument.drumKit: a drum kit needs `kind: \"drumSynth\"`. Without it, the track would play the synth
  instead."*
- *"tracks[3].inserts[1].params.stages: this setting can't hold 5; it would become 6."* The 6 comes from the read-back
  itself, never from a hand-kept list; the setting's own `fx.describe` note says why (even numbers only [R
  `Effects.swift:5480-5488`]).
- *"This template adds routing, and routing can't change while you're recording. Stop recording, then try again."*
- *"This template needs a newer version of DAW Pro."*

Warning codes (machine-readable, each with a sentence): `unknownKeySkipped`, `unknownEffectSkipped`,
`unknownInstrumentSkipped`, `unknownSettingSkipped`, `unknownModulationSkipped`, `valueClamped`, `valueChanged`,
`audioUnitMissing`, `audioUnitSlowToLoad`, `busIncluded`, `sidechainDropped`, `modulationTargetWarned`,
`duplicateTrackNames`.

### 6.5 The MCP tools

| Tool | Verb | Mutating (strict wrapper)? |
|---|---|---|
| `template_list` | `template.list` | no |
| `template_describe` | `template.describe` | no |
| `template_apply` | `template.apply` | yes |
| `template_save` | `template.save` | yes |
| `template_remove` | `template.remove` | yes |
| `template_import` | `template.import` | yes |
| `template_export` | `template.export` | yes |
| `macro_song_skeleton` (existing) | gains `template` and `dryRun` | yes (unchanged) |

- **An inline template passes through the MCP server untouched.** Its schema is
  `z.union([z.string(), z.record(z.string(), z.unknown())])`, never a nested `z.object`. The m30-c law is that a nested
  object in *strip* mode silently drops a misspelled key [R `mcp-server/test/nested-strict-gap.test.ts:1-16`]; a record
  keeps every key, so the app's codec sees the typo and refuses it with its path. A zod copy of the whole schema would be
  a second home that goes stale with every new effect setting.
- **Its test inverts the m30-c pattern on purpose:** a misspelled nested key in an inline template **reaches the bridge
  verbatim** (`calls.length === 1`, the key present), and the app's refusal comes back as `isError`. Plus the usual
  "still accepts a legitimate call" test.
- Tool descriptions say what a template is in one novice sentence, name `template_describe` as the way to read one before
  applying it, and state that `template_apply` adds tracks and never removes or changes existing ones.

### 6.6 Other surfaces that must learn the verbs (the hand-maintained ones, §2.7)

- **In-app Copilot catalog**: add `template.list`, `template.describe`, `template.apply` [R `CopilotCatalog.swift`].
- **Agent allowlists**, TPL-9 [M: `ls claude-plugin/agents` → arranger, composer, demo-director, finisher, mix-engineer,
  producer, sound-designer]: `producer.md` gets all seven tools; `arranger.md` gets `template_list`,
  `template_describe`, `template_apply`; `mix-engineer.md` and `sound-designer.md` get `template_list`,
  `template_describe`, `template_save`. [A: TPL-9 re-reads each agent's role text before adding.] The census method is per-file
  `grep -c` for each tool, run before and after, because regeneration alone does not reach agents (the drum-tools lesson,
  2026-09-21).
- **`daw-wire-reference` skill**: the seven verbs.
- **`DemoRender`**: `template.apply`, for the gates (TPL-4).

---

## 7. Where templates come from

### 7.1 Ten built-in templates, covering all fourteen skeleton genres

Built-ins ship as `.dawtemplate` JSON resources in DAWCore, `Sources/DAWCore/Resources/Templates/`, added to the
target's `resources` beside `BundledSamples` as a `.copy` [R `Package.swift:85-95`]. They are the same format a user's
file is, decoded by the same codec, so the codec is exercised by every built-in on every test run. A catalog-integrity
test decodes all of them (§8.1).

Instruments use General MIDI programs the skeleton's own rosters already use and name [R `SongSkeleton.swift:168-571`],
our drum machine's five kits [R `DrumKit.swift:815-841`], and the Poly Synth. **No Audio Unit and no sampler, ever**
(§2.2). The "GM kit" below is `{source: "gm", program: 0, bankMSB: 120, bankLSB: 0}`, the skeleton's
`standardDrumKit` [R `GMProgramCatalog.swift:46-48`, `:120-122`]. **Every setting value below is [A]**; TPL-4 tunes each
by measurement (§8), and the one real taste axis goes to a listening round (§12).

| Id, name | Song form; also suits | Tracks (→ output, ⇢ send) | What it shows a novice |
|---|---|---|---|
| `pop-band`, **Pop Band** | pop | Drums (drum machine `acoustic`, `gm` layout → Drum Bus ⇢ Reverb), Bass (GM 33, `bass-tight`), Piano (GM 0 ⇢ Reverb), Synth Pad (Poly Synth pad, `warm-keys` ⇢ Reverb), Lead Vocal (audio, `vocal-presence` ⇢ Reverb), **Drum Bus** (`drum-bus-glue`), **Reverb** (hall reverb) | A drum group on its own bus; a shared reverb |
| `piano-ballad`, **Piano Ballad** | ballad | Piano (GM 0, `warm-keys` ⇢ Hall), Strings (GM 48 ⇢ Hall), Warm Pad (GM 89 ⇢ Hall), Bass (GM 32, `bass-tight`), Lead Vocal (audio, `vocal-presence` ⇢ Hall), **Hall** (long hall reverb) | No drums, like the ballad form [R `SongSkeleton.swift:287-298`] |
| `rock-band`, **Rock Band** | rock; metal | Drums (GM kit → Drum Bus ⇢ Room), Bass (GM 33, `bass-tight`), Rhythm Guitar (GM 29, `guitar-crunch`, pan left), Lead Guitar (GM 30, `guitar-crunch`, pan right ⇢ Room), Lead Vocal (audio, `vocal-presence` ⇢ Room), **Drum Bus** (`drum-bus-glue`), **Room** (reverb) | Guitars panned apart; a drum group |
| `house-club`, **House Club** | house | Drums (drum machine `909`, `gm` ⇢ Room), Bass (Poly Synth → Pump), Chords (Poly Synth, filter with a slow LFO sweep → Pump ⇢ Echo ⇢ Room), **Pump** (compressor keyed from Drums), **Echo** (tempo-synced delay), **Room** (hall reverb) | Pumping sidechain; a moving filter; echoes in time with the song |
| `hip-hop-808`, **Hip-Hop 808** | hip-hop; r-and-b | Drums (drum machine `808`, `gm` ⇢ Room), 808 Bass (Poly Synth sine with drive), Keys (GM 4, `warm-keys` ⇢ Room), Pad (GM 89 ⇢ Room), Vocal (audio, `vocal-presence` ⇢ Room), **Room** (reverb) | A synth sub-bass that sits under an 808 kit |
| `lofi-chill`, **Lo-Fi Chill** | lo-fi | The §4.3 example: Drums (drum machine `lofi`, `gm`), Bass (GM 33, `bass-round`), Keys (GM 4, `warm-keys`, a breathing filter → Keys Duck), Vinyl FX (audio, `lofi-tape`), **Keys Duck** (compressor keyed from Drums), **Tape Room** (hall reverb) | Ducking keys; worn-tape colour |
| `jazz-combo`, **Jazz Combo** | jazz | Drums (GM kit, quieter ⇢ Club Room), Upright Bass (GM 32, `bass-round`), Piano (GM 0, pan left ⇢ Club Room), Trumpet (GM 56, `horn-section`, pan right ⇢ Club Room), Jazz Guitar (GM 26 ⇢ Club Room), **Club Room** (small reverb) | A band placed across the stereo field |
| `acoustic-folk`, **Acoustic Folk** | folk; country | Acoustic Guitar (GM 25, `acoustic-sparkle` ⇢ Room), Twang Guitar (GM 27 ⇢ Room), Fiddle (GM 40 ⇢ Room), Bass (GM 32, `bass-round`), Drums (GM kit, `drum-room`), Lead Vocal (audio, `vocal-presence` ⇢ Room), **Room** (small hall reverb) | Acoustic instruments in one shared room |
| `soul-blues`, **Soul & Blues Band** | blues; funk | Drums (GM kit, `drum-room`), Bass (GM 33, `bass-round`), Rhythm Guitar (GM 27, a filter that opens as you play harder: an envelope follower on its own filter), Lead Guitar (GM 29, `guitar-crunch` ⇢ Room), Organ (GM 16 ⇢ Room), Horns (GM 61, `horn-section` ⇢ Room), **Room** (reverb) | Touch-sensitive "wah" from modulation |
| `reggae-riddim`, **Reggae Riddim** | reggae | Drums (GM kit, `drum-room` ⇢ Dub Echo), Bass (GM 33, `bass-round`, forward), Skank Guitar (GM 27, pan right ⇢ Dub Echo), Organ (GM 16, pan left), **Dub Echo** (tempo-synced delay, long feedback), **Room** (reverb) | A dub echo you send parts into |

**Genre coverage** [D, from the column above and the catalog's 14 names, `SongSkeleton.swift:137-153`]: pop, ballad,
rock, metal, house, hip-hop, r-and-b, lo-fi, jazz, folk, country, blues, funk, reggae: **14 of 14**, each with exactly
one default template (the first built-in, in catalog order, that lists it). A test pins "every catalog genre has a
default template", so a 15th genre cannot ship without one.

Rules every built-in obeys, each asserted by the catalog-integrity test (§8.1):

1. Every playable part is an `.instrument` track; only recorded material (vocals, FX) is `.audio`
   [R `SongSkeleton.swift:130-134`, the m26-o law].
2. No `audioUnit` and no `sampler` instrument or insert.
3. A `drumSynth` track has `noteLayout: gm` (§3; while TPL-0 is not done, the four drum-machine templates carry the GM
   kit, §3.5).
4. **Echoes are tempo-synced.** A template has no tempo, so a delay set in milliseconds is right at one tempo only. Echo
   buses use `delay` with `sync` on (`sync`, `division` [R `Effects.swift:4497-4503`]); `tapeDelay` has no sync setting [R `Effects.swift:5183-5301`, its whole `specs(for:)` list: `timeMs`,
   `feedback`, `mix`, `wowDepthMs`, `wowRateHz`, `flutterDepthMs`, `saturationDrive`, `highCutHz`] and appears only as a short
   slapback [A: ≤ 150 ms].
5. **LFO rates are in Hz and slow.** Tempo-synced LFO rates are refused until m39-c lands
   [R `Modulation.swift:916-927`], so built-in LFOs are sweeps and breaths, never rhythmic pulses.
6. Names are 1–40 characters; summaries are one sentence a novice can read, ≤ 200 characters.
7. Return buses are 100 % wet (`mix: 1`), so a send adds reverb without adding a second dry copy.

### 7.2 Saved templates

- **"Save as Template…"** in the app, or `template.save {name, trackIds, …}` on the wire, captures the chosen tracks
  (§5.7) into one `.dawtemplate` file in the library folder (§6.1). The id is `"user-<uuid>"`; built-in ids never start
  with `user-`, so the two can never collide.
- A saved template can hold anything the song can: sampler zones by absolute path, sound-bank files, Audio Units with
  their saved sound. Applying it on a Mac that lacks a file refuses with the file named; a missing Audio Unit warns and
  creates the track, the way an opened project does (§5.4).
- Built-ins are read-only. Saving over one is refused; "save a copy" is the same verb with a new name.

### 7.3 Files

- Extension `.dawtemplate`; UTF-8 JSON; the first key is `"format": "dawpro.template"`; ≤ 2 MB (§4.8).
- `template.import {path}` validates the file with the full codec and copies it into the library, giving it a fresh
  `user-` id if its id is missing, is a built-in's, or is already taken, and saying so in a warning.
- `template.export {id, path}` writes the canonical form of a built-in or a saved template.
- `template.list` also shows files a user copied into the folder by hand. **A file that cannot be read is never
  silently skipped**: it is listed under `unreadable`, with the reason, and the picker shows it greyed with that reason.
  Two files with the same id: the first by file name is listed, the other goes to `unreadable` with *"Another template
  already uses this id. Import it again to give it a new one."*
- Opening a `.dawtemplate` by double-clicking it in Finder is out of scope (§11).

---

## 8. Proof: the gates

**The law this section obeys** (from the memory index, each learned by a shipped defect): *audibility is not
correctness* (five planted defects once passed `audible=true`); *identical bytes prove an axis did nothing, distinct bytes
prove nothing, so assert the physics*; *the boring invariance controls catch the bug, not the headline metric*; *a
loudness meter does not look up: check true peak too*. **Every gate below names the planted defect it must catch**, and
an item is not done until its gate has been seen to fail on the plant and pass without it.

### 8.1 Catalog integrity (TPL-3, pure, no audio)

Decodes every built-in with the real codec and checks: §7.1's seven rules; ids and names unique; every catalog genre has
exactly one default template; every `songForm` and `genres` entry is a real catalog genre; `TemplateBuilder.plan`
succeeds with **zero** warnings; every track's `slotsUsed` ≤ 64; every summary is one sentence ≤ 200 characters.

Plants: a built-in whose drum machine is in `pads` layout; one with an Audio Unit; a vocal typed `.instrument`; a genre
with no template; an unknown effect setting in a built-in file. Each must fail with a sentence naming the file and path.

### 8.2 Describe equals apply (TPL-6)

For every built-in: `template.describe`'s canonical JSON equals `TemplateCapture` of the tracks `template.apply` just
made, on a fresh project, compared on named readings (§4.6). Kept from the spike: *"a test that compares
`describeSkeleton`'s answer against what `songSkeleton` actually creates makes the two unable to drift"* [R
`docs/design/2026-09-20-multi-instrument-templates.md:334-336`]. `macro.songSkeleton {dryRun: true}` (§6.2)
gets the same gate against a real call, for all 14 genres.

Plant: a describe path that reads `mixerPreset` by name but an apply path that forgets it. Must fail.

### 8.3 The round trip (TPL-5)

`canonical(capture(apply(T))) == canonical(T)` for every built-in and for 500 random templates [A: count; the
property-test seed is printed on failure] drawn from every effect kind, every instrument kind a built-in may use, every
modulation source kind, and random in-range settings for each. Plus a real saved template holding an imported
multi-zone sampler library and a sound-bank file.

Plants: `TemplateCapture` that writes a setting only when it differs from the **spec default** instead of from a fresh
effect's reading (it would lose a legacy clipper's 4, §4.6); a capture that forgets sends. Both must fail.

### 8.4 The skeleton golden gate (TPL-3)

**Before TPL-3 changes a line**, record fixtures from today's code: for each of the 14 genres, with the default roster and
with one `tracks` override, the project JSON after `applySongSkeleton`, with UUIDs replaced by stable tokens in order of
first appearance. After the re-point, all 28 must be **byte-identical**. D3's fix (§5.5) regenerates exactly the rock
fixtures, and their diff must show only the two instruments.

Plant: a converter that drops `mixerPreset` for one genre, and one that builds the GM descriptor with a different display
name. Both must fail on bytes.

### 8.5 Codec and wire (TPL-1, TPL-6, TPL-7)

- One test per row of §4.7's table, each in both directions (same-version refused, newer-version skipped with its code),
  plus `minReaderVersion`, the 2 MB bound, a kind given as a number, and a truncated file.
- The read-back rule: `phaser.stages: 5`, `ratio` beyond its range and `highPassEnabled: 0.7` are refused with the value
  they would have become.
- **The drum-kit parity test**: one table of `drumKit` objects through the wire's `parseDrumKit` and through the codec;
  the same kit for valid rows, a refusal from both for unknown names, and the stated clamp-versus-refuse difference for
  out-of-range rows (§5.2).
- MCP: the inverted m30-c test (a misspelled nested key reaches the bridge verbatim and comes back refused), plus a
  legitimate-call test, for `template_apply`, `template_describe` and `macro_song_skeleton`'s `template`.
- D2: a misspelled key inside `tracks[i]` is refused, naming it.

### 8.6 The store (TPL-2, appended to existing `@MainActor` suites)

| Property | How it is checked |
|---|---|
| One undo step | apply → undo → the project encodes byte-identical to before; redo → byte-identical to after |
| A refusal changes nothing | after each refusal kind, the project bytes are unchanged **and** `canUndo` is unchanged [R `ProjectStore.swift:196`] |
| `dryRun` changes nothing | project bytes and `canUndo` unchanged; the reply equals the real apply's minus ids |
| Twice adds twice | two applies → two disjoint id sets; the second band's keys map to new ids |
| Existing tracks untouched | every pre-existing track encodes byte-identical before and after |
| The master chain, tempo, markers and loop untouched | encoded before and after |
| Recording | routed template refused while recording, and nothing changes; a plain template (no routing) applies mid-take |

Plant: a `performEdit` given a coalescing key (two quick applies merge into one undo); an apply that validates resources
inside the edit (a refusal leaves an undo entry). Both must fail.

### 8.7 The engine takes a routed batch (TPL-2, headless)

A 6-strip template (2 buses, 3 sends, 1 output into a bus, 1 sidechain key, 1 LFO route) arrives in one
`tracksDidChange`. With a test signal on every source: every bus's input is above a floor [A: −60 dBFS], the keyed
compressor's gain reduction rises within 20 ms of each key burst and falls back between them, and the LFO-routed setting
moves. Control: the same template with the send levels at 0 gives silence on the buses. **Owner: `audio-dsp-engineer`;
this is where §5.6's [A] is replaced by a measurement.**

### 8.8 Each built-in sounds like its description (TPL-4)

Rendered headless through `DemoRender`'s `template.apply` at the song form's default tempo, 48 kHz, 8 bars, with a fixed
**audition pattern** per role (drums: a GM beat using 36, 38, 42, 46 and 49; bass: roots; keys and pads: a four-chord
cycle; leads and guitars: a phrase). Every threshold below is [A], set in TPL-4 from the first honest renders and then
frozen.

| Leg | What is measured | Plant it must catch |
|---|---|---|
| **Every part is heard** | each part's solo render: RMS above −45 dBFS | a track whose instrument silently failed to load |
| **Every drum note lands on its drum** | each GM note alone, compared with the drum machine's own voice at its `pads` note: spectral correlation ≥ 0.9, decay time within 20 % | a `gm` map with snare and closed hat swapped |
| **Every bus receives** | bus output with its senders playing vs. with its senders muted: ≥ 20 dB apart | a builder that drops sends |
| **Every sidechain ducks** | the ducked bus's short-term level dips ≥ 3 dB within 20 ms of each kick; **control**: key removed, no dip | a key wired to the wrong source |
| **Modulation moves** | the modulated track's spectral centroid swings with the LFO's period (or, for the follower, with the input level); **control**: route disabled, centroid flat | a route whose insert key resolved to the wrong effect |
| **Level and peaks** | whole band: integrated loudness in a set window [A: −20 to −12 LUFS, an unmastered band]; **true peak ≤ −1 dBTP**; no single part clips | a template with a +12 dB gain insert |
| **Determinism** | two applies of the same template: the two bands' solo renders are bit-identical. [A: that our instruments are deterministic per instance. TPL-4 measures it first, two instances of each instrument with the same settings and notes; where one is not (noise, `drift`, `voiceJitter`), that part is compared by spectrum within a tolerance instead, and the report says which parts] | shared state between two copies |
| **Existing tracks unchanged** | a project with its own tracks renders those tracks bit-identically before and after an apply | an apply that re-orders or re-wires existing strips |
| **Legacy drum kits unchanged** | a `pads` drum machine renders bit-identically before and after TPL-0 (a byte gate **and** a decode test, since a byte gate over renders is blind to a `Codable` decode default) | a decoder that defaults an absent layout to `gm` |

Measurement craft that has bitten this tree: `ffmpeg -v error` hides `ebur128` and `astats` summaries (use
`-hide_banner`); per-frame `framelog` needs `-loglevel verbose`; a render longer than 30 s needs `DAW_TIMEOUT_MS` raised.
Every negative result is positive-controlled.

### 8.9 A person looked at it (TPL-8)

`/dogfood` on staging (port 17695, never 17600), with a test project named `tpl-<item>-<date>`: open the picker from the
Sketchpad and from the add-track menu, in Simple and in Pro; start a song; add a band to a song; add one **while the
song plays**, and note what you hear; save a template; import and export one; undo each. Screenshots of every state. And the shipped-artifact check: the built-in templates load from
the **built app bundle** (`daw-pro_DAWCore.bundle` inside `dist/DAWPro.app`), not only from the source tree.

### 8.10 The census of surfaces grep cannot see (TPL-6, TPL-9)

Before and after, with the method in the item report (§2.7): `addableEffectKinds` and `InstrumentPickerModel.builtIns`
(expected unchanged: no new kind); every `claude-plugin/agents/*.md` tool list (per-file `grep -c` per tool); the
Copilot catalog; the `daw-wire-reference` skill; `DemoRender`'s verb mirror; `node scripts/gates/doc-count-drift.mjs`
(+7 verbs, +7 tools); `node scripts/gates/effect-kind-surface.mjs` (expected unchanged). Report the method, never a
remembered number.

---

## 9. The UI (TPL-8)

### 9.1 Where a novice finds it

1. **The Sketchpad's USE A TEMPLATE button** [R `Sources/DAWApp/Sketchpad/SketchpadView.swift:283-294`]. Today it silently
   starts a Pop song (`_ = try? app.store.applySongSkeleton(genre: "pop")`, which also hides any error). It now opens the
   template picker with **Pop Band** already selected, so one press of Return still starts a pop song, now with the Pop
   Band's sound instead of the pop roster's. The onboarding
   step it drives (*"flips the project to having content (so the onboarding `generate` step advances via
   `projectGainedContent`)"*, the same comment) still advances when the song starts. It stays neutral, not violet: *"a
   song SCAFFOLD is not AI-generated audio"* (same comment).
2. **The add-track (+) menu** gains **"Add a Band from a Template…"** [A: TPL-8 names the exact control and checks the
   shortcut census before assigning any key].
3. **The Track menu** carries the same item, and in Pro, **"Save Selected Tracks as Template…"**.

### 9.2 The picker card

A centered dark-glass card, the sampler card's pattern, with its height budget decided in a headless layout type
(`DAWAppKit.TemplatePickerLayout`, the `SamplerCardLayout` precedent): the **template grid is the one region that yields**;
the header, the detail line and the buttons take fixed, computed heights [R `docs/DESIGN-LANGUAGE.md`, "Centered modal
cards — the height budget, and WHICH region yields", m26-i].

**Simple** (the default; Simple shows the 20 % of controls used 80 % of the time [R `DESIGN-LANGUAGE.md:36`]):

- Title: **"Start with a band"**. Subtitle: *"Pick a sound to start from. You can change every part later."*
- Ten tiles. Each: the name, its one-sentence summary, a row of small instrument glyphs, and "6 tracks".
- Two buttons:
  - **Start a song** (primary): *"Adds this band and a song outline: tempo, sections and a loop."*
  - **Add to my song** (secondary): *"Adds these tracks. Nothing you already have changes."*
- After it lands, a notice that fades on its own: **"Added Lo-Fi Chill: 6 tracks. The tracks are empty: add notes,
  record, or ask the Copilot to write a part. Press ⌘Z to undo."**

**Pro** adds: a **Built-in / My Templates** switch; a detail pane listing each track with its instrument and routing in
plain words (*"Keys: Electric Piano. Plays into Keys Duck. Sends to Tape Room."*); **Import…**, **Export…**, **Remove**
(saved only); and **Save as Template…**.

### 9.3 States the card must show, never hide

- **Unreadable saved files** appear greyed, with their reason (§7.3).
- **A saved template with no song form**: **Start a song** shows a small **Song style** menu beside it (the 14
  styles), set to the template's first `genres` entry, or Pop if it has none. The wire needs nothing new:
  `macro.songSkeleton` already requires `genre` [R `SongSkeleton.swift:734-736`].
- **A saved template that uses an Audio Unit** shows, before you press anything: *"Uses a plug-in: <name>. Plug-ins can
  take a while to load."* A missing plug-in: *"<name> isn't installed on this Mac. The track will be added without its
  sound."*
- **A song that already has tracks** gets **Add to my song** as the primary button, and **Start a song** says what it
  will also change before you press it: *"This also sets the tempo to 90 BPM and adds song sections and a loop. Your
  tracks stay. Notes will play at the new speed, and recordings may no longer line up with the beat."* (The skeleton is additive, but
  it re-tempos the song [R `SongSkeleton.swift:935-942`]; a novice must hear that before, not after.)
- **While recording**, a template with routing has its buttons disabled with *"Stop recording to add this band."*
- **Every refusal** from the store is shown in the card in the store's own words. No `try?` anywhere on this path.

### 9.4 Rules it keeps

- The picker calls `ProjectStore.applyTemplate` and `applySongSkeleton(…, template:)`, the functions `template.apply` and
  `macro.songSkeleton` call. **There is no UI-only path** (the one-command-surface invariant).
- Create/add affordances are **neutral chrome**, no accent at rest (Rule 3 [R `DESIGN-LANGUAGE.md`, Rules]); the
  template's tracks never get the violet AI tint.
- The picker's view state lives in a headless `DAWAppKit.TemplatePickerModel` (tiles, selection, which buttons are
  enabled and why, every string), tested without a window.

---

## 10. Staged delivery, in order

**Standing constraints for every item** (brief every agent on these):

- Work on staging (port 17695) only. **Never touch 17600**, the user's live app; identify a process by its listening
  port, never by its path.
- Name every test project `tpl-<item>-<date>`.
- Test with `./scripts/test.sh --filter …`, never bare `swift test`. **No new `@MainActor` test suite**: append to an
  existing one (§5.8). New test files are for nonisolated code only.
- No `git checkout`, `stash`, `restore`, `clean` or `reset`. **No commits without the user's word.**
- Never touch `.env`, `scripts/ace-step/`, `scripts/rvc/`, `scripts/video/` or any audio device. Grep `scripts/` only
  with `--exclude-dir=video --exclude-dir=ace-step --exclude-dir=rvc --exclude-dir=node_modules`. Nothing here needs
  the ACE sidecar: never start it.
- Additive wire only; never rename a live verb. 0 new warnings in `Sources/`, measured from the item's own build log.
- `Commands.swift`, `server.ts`, `ProjectStore.swift`, `Package.swift` and `AppDirectories.swift` are edited by other
  lanes: cite and edit them by function or case name, and re-read before each edit.
- Copy for users is beginner-readable, in the active voice, and never names the user.

| Id | Item | Route | Depends on | Gate |
|---|---|---|---|---|
| **TPL-0** | The drum machine learns the General MIDI layout: `DrumKitParams.noteLayout` (`pads`/`gm`, absent = `pads`); `DrumVoice.voice(forNote:layout:)` as a `switch`; the layout published to the render instance with the kit; `isDrumKit` true for a `gm` drum machine (census of its 5 callers first); `instrument.loadDrumPreset` keeps the layout; `probeLiveness` ignores it when naming a preset; wire `drumKit.noteLayout` (its own case in `parseDrumKit`, before the kit-level number branch), `describeDrumKit` `noteLayout` + `voiceNotes`; the MCP nested key; the one-line rule in `composer.md` and `sound-designer.md` (§3) | `audio-dsp-engineer` (model and render); `mcp-integration-engineer` (wire, MCP, agent docs); **RT review by `daw-architect`** | — | A `pads` kit renders bit-identically before and after, plus a decode test (§8.8). Every GM note in §3.3's table lands on its voice, by spectral correlation. Loading each of the 5 presets onto a `gm` kit keeps `gm`. A `gm` "lofi" kit is still reported as the lofi kit. The RT review signs off: a `switch`, no `static let` table, no `allCases` scan at note-on (F-4). Nested-strict MCP test. |
| **TPL-1** | `TrackSetTemplate` and its types; `TrackSetTemplateCodec` (raw-string kinds, the §4.7 table, versions, size bound, the read-back rule); the five moves of §5.2, each byte-identical for its live verb; the Poly Synth names table; the drum-kit parity test | `swift-app-engineer` | — (runs beside TPL-0; `noteLayout` joins the codec when TPL-0 lands) | §8.5's codec rows. Each moved rule: the live verb's existing tests unchanged, plus a table test that the store method and the pure rule agree. The parity test. |
| **TPL-2** | `TemplateBuilder.plan`; `ProjectStore.applyTemplate(_:dryRun:)`; `validateSoundBank`, `validateSamplerZones` and `requireRoutingMutationAllowed` to module-internal; the headless engine batch test | `swift-app-engineer` (DAWCore); `audio-dsp-engineer` (§8.7) | TPL-1 | §8.6's table, with its two plants. §8.7, which replaces §5.6's [A] with a measurement. |
| **TPL-3** | **Golden fixtures first**, then: the ten built-in `.dawtemplate` files and their `Package.swift` resource entry; the catalog-integrity test; `applySongSkeleton(template:)` and its `dryRun` plan path over the shared builder; then D3 as its own flagged step | `swift-app-engineer` | TPL-2; TPL-0 for the four drum-machine templates (else §3.5's fallback) | §8.4: 28 fixtures byte-identical, and the D3 step's diff limited to rock's two instruments. §8.1 with every plant. |
| **TPL-4** | `template.apply` in `DemoRender`; the audition patterns; §8.8's legs; every [A] value in §7.1 tuned by measurement; the Pop Band drums listening page (Q2) | `audio-dsp-engineer` + `qa-test-engineer` | TPL-3 (TPL-0 for the drum leg) | §8.8, every leg seen failing on its plant. True peak ≤ −1 dBTP on all ten. The listening page published as a handoff artifact, 4 options on one axis. |
| **TPL-5** | `TemplateCapture`; the `templates` directory category (after W7-SC's); save, remove, import and export in the store; Audio Unit `state`; the 2 MB bound checked against real Audio Unit states | `swift-app-engineer` | TPL-2 | §8.3 with both plants. Import and export round trips. An unreadable file is listed, never skipped. Staging's `DAWPRO_PROFILE_ROOT` keeps saved templates out of the user's library. |
| **TPL-6** | The seven verbs; `macro.songSkeleton`'s `template` and `dryRun`; the D2 fix; placement after `playbox.generate`; the Copilot catalog entries; the count pins | `mcp-integration-engineer`, as the wire-owning lane of its wave | TPL-3, TPL-5 | §8.2 for templates and for all 14 genres. The playbox pin still holds and nothing is at the tail. D2's refusal. Every refusal sentence reviewed against §6.4. `doc-count-drift.mjs`: +7, exit 0. |
| **TPL-7** | The seven MCP tools; `macro_song_skeleton`'s two params as an opaque passthrough; its roster prose shrunk to one line per genre | `mcp-integration-engineer` | TPL-6 | The inverted m30-c test and a legitimate-call test per tool (§8.5). `npm test` green. Tool count +7 by `doc-count-drift.mjs`. |
| **TPL-8** | The picker card (Simple and Pro), the Sketchpad button, the add-track and Track menu items, the Save as Template sheet, `TemplatePickerModel` and `TemplatePickerLayout` | `swift-app-engineer` + `ui-design-engineer` | TPL-3, TPL-5 (the built-ins and the store functions); TPL-6 not required | §8.9: `/dogfood`, screenshots of every state, and the built app bundle check. Headless tests of the model and the layout. |
| **TPL-9** | Docs and release: §17's entry into `ARCHITECTURE.md` and `template.*` into its namespace list; ROADMAP boxes; CHANGELOG, flagging D2 and D3; the `daw-wire-reference` skill; the agent allowlists (§6.6); the plugin bundle regenerated. `/plugin update` is the user's action | `docs-scribe`; allowlists and regeneration by `mcp-integration-engineer` | TPL-7, TPL-8 | §8.10's census before and after. The tools are present in the bundle the user actually loads, not only in the source tree. |
| **TPL-10** | *Recommended, after v1.* **Hear a template before you pick it**: an 8-bar preview per built-in, rendered by TPL-4's gate itself, with a staleness test that re-renders and compares | `audio-dsp-engineer` + `ui-design-engineer` | TPL-4, TPL-8 | Each preview audible, true peak ≤ −1 dBTP; the staleness test fails when a template or an instrument changes without a new preview. |
| **TPL-F8** | *Separate.* `macro.songSkeleton` gets `setTempo`'s two guards (recording; a multi-segment tempo map) (F-8) | `swift-app-engineer` | TPL-3 | Refused mid-take and on a multi-segment map, with `setTempo`'s own sentences; flagged in the CHANGELOG. |
| **TPL-F9** | *Separate.* `mixer.applyPreset` refuses mid-take when the chain it replaces holds a sidechain-keyed effect, and its reply names a removed key (F-9) | `swift-app-engineer` + `mcp-integration-engineer` | — | Guarded exactly when keyed (the `removeEffect` rule); the additive reply field; flagged in the CHANGELOG. |

**Order.** Two can start at once: TPL-0 and TPL-1. Then TPL-2; then TPL-3 and TPL-5 side by side; then TPL-4 and TPL-6;
then TPL-7 and TPL-8; then TPL-9. The critical path is TPL-1 → TPL-2 → TPL-3 → TPL-6 → TPL-7 → TPL-9. If TPL-0 slips,
TPL-3 ships §3.5's fallback and the four templates switch to the drum machine in a one-field follow-up once TPL-0 lands.

---

## 11. Out of scope, on purpose

- **Notes, patterns and loops.** Templates hold sound, not content; wave 4 owns drum patterns and loops, and the pad grid.
- **One track playing several instruments at once** (a layer). Asked once, in §12.
- **Sampled drum kits in the built-ins.** The drum machine's design called sampled kits *"content for item (3),
  multi-instrument templates"* [R `docs/design/2026-09-20-drum-machine.md:69-71`]. The tree ships one sample, a test tone
  (§2.2), so a sampled kit means sourcing, licensing and shipping sample files. Recommended follow-up: a
  `research-analyst` spike on openly licensed (CC0) drum samples and a size budget, then a content item. Saved templates
  already carry a user's own sampled kits (TPL-5).
- **Routing a template into buses already in the song, or re-voicing existing tracks.** Both need matching against the
  project, the silent-mismatch class (§4.4). If wanted later, they take explicit track ids, never names.
- **Master-chain templates.** Mastering belongs to the finishing flow, not to a band setup.
- **Track colours.** No model field exists (§2.1).
- **Tempo-synced LFO rates.** Refused until m39-c [R `Modulation.swift:916-927`].
- **Pre-fader sends.** The model has none [R `Model.swift:1720-1727`].
- **Double-clicking a `.dawtemplate` in Finder.** A document-type registration in the app bundle; the picker's Import… is
  the route for now.
- **An "AI, make me a template" generator.** Agents can already write an inline template and pass it to
  `template.apply`; a dedicated generator is a later feature.

---

## 12. Questions for the user

Only two, and **neither blocks any item**: every item in §10 proceeds on the recommended default.

**Q1. "Multi-instrument presets": a band of tracks, or also one track that plays several instruments at once?**
*When you asked for "multi instrument presets or templates", did you also mean one track that plays two instruments
together, for example piano and strings from the same keys?*
**Recommended default: no, not now.** This design builds whole bands of separate tracks, which is what "one call that
sets up tracks, instruments, effects and routing" means. Playing two instruments from one track would be a separate,
later feature, filed only if you say yes.

**Q2. Pop Band's drums** (a listening page, published when TPL-4 has renders; not a question in words).
Four versions of the same Pop Band beat that differ **only in the drum sound**: our drum machine's **808**, **909** and
**acoustic** kits, and the Mac's **General MIDI kit**. Your pick sets one field.
**Recommended default: the drum machine's acoustic kit.**

**Decided here, not asked** (listed so no one re-asks; the orchestrator may overrule any of them):

- **USE A TEMPLATE opens the picker** instead of silently starting a pop song, with Pop Band pre-selected so Return still
  starts a pop song (with the Pop Band's sound). The button's own label promises a choice.
- **The spike's questions:** Q1 (re-voice the GM drums) and Q3 (a mix bus) are dissolved by this design; Q2 (notes)
  keeps the spike's answer, no (§1.3).
- **Built-in templates never use Audio Units**, and use the drum machine only in the General MIDI layout.
- **D2** (refuse unknown keys inside `tracks[i]`) and **D3** (rock's Drums and Bass get instruments) are defect fixes,
  flagged in the CHANGELOG.
- **Templates refuse out-of-range values** (the m34-q law, §4.7).
- **The default layout of a newly added drum machine** stays `pads` in this wave; it goes with wave 4's pad-grid work,
  where I recommend `gm`.

**For the orchestrator, not the user:** rule on §1.3, *"a new `template.*` surface for sound setups plus `template` and
`dryRun` on `macro.songSkeleton`, all built by one builder"* versus the spike's *"extend `macro.songSkeleton` only"*.

---

## 13. Full Xcode, signing, entitlements

**None needed.** No AUv3, no entitlement, no signing change, no new target. Built-in templates ship as a SwiftPM
resource of an existing target, which `swift build` handles; TPL-8's gate checks that the resource reaches the built app
(§8.9). Xcode 26.6 is installed on this machine in any case (memory index, "Env quirks").

---

## 14. Invariants the implementation must keep

1. **One command surface.** The picker, `template.apply` and `macro.songSkeleton {template}` all call
   `ProjectStore.applyTemplate` / `applySongSkeleton`; there is no UI-only path and no wire-only path.
2. **The render thread never allocates, locks or waits.** The only render-thread change in this wave is TPL-0's
   `switch`; everything else happens on the main actor or in the reconcile that already runs there.
3. **DAWCore stays headless and dependency-free.** The codec, builder, capture and rules are Foundation-only and
   nonisolated. No AppKit, no AVFoundation, no engine type in the template model.
4. **DAWEngine hides CoreAudio.** The engine sees a template only as tracks arriving through `tracksDidChange`.
5. **Additive wire.** Seven new verbs, three new optional parameters (`template`, `dryRun`, `drumKit.noteLayout`), two
   new describe fields; no rename. D2 is the one deliberate tightening, flagged.
6. **One undo step per apply; a refusal records nothing; `dryRun` changes nothing.**
7. **A template never reads or writes existing tracks, the master chain, tempo, markers or the loop** (`template.apply`).
8. **Nothing is matched by name.** Keys are local to one template.
9. **Built-ins: no Audio Unit, no sampler; the drum machine only in `gm` layout; every playable part an instrument
   track.**
10. **The round trip holds** (§4.6), and **the skeleton golden gate holds** (§8.4).

---

## 15. Every difference from the 09-20 spike

| Topic | Spike [R `docs/design/2026-09-20-multi-instrument-templates.md`] | This design |
|---|---|---|
| What a template is | A `macro.songSkeleton` genre roster with richer entries | A sound setup of its own, which the skeleton can use (§0) |
| New verbs | One read verb, `macro.describeSkeleton` | Seven `template.*` verbs; `dryRun` on the skeleton replaces the read verb (§6) |
| Buses, sends, sidechains, modulation | Deferred to v2 | In v1, by template-local keys (§4) |
| Per-effect settings | No; mixer presets only | Yes, by `fx.describe` name, sparse (§4.5, §4.6) |
| Saved and file templates | Deferred | In v1 (§7.2, §7.3) |
| A document format | Rejected for v1 (static data should not be `Codable`) | One JSON schema, because saved templates are user data (§1.3 reason 4) |
| Re-voicing the 12 GM drum tracks onto the drum machine | Asked (Q1), default yes | Not done: it would have played wrong drums (§3); classic rosters stay byte-identical |
| The drum machine's note layout | Not found | TPL-0 (§3) |
| Notes in templates | No (Q2) | No |
| A mix bus | Asked (Q3) | Buses are in v1 |
| D1, D2 | Fix | Fix; D2 flagged as a behaviour change (§6.2) |
| D3 | Rock's Drums | Rock's Drums **and** Bass (§1.3) |
| One undo, refuse before the edit | Yes | Yes (§5.4) |
| Placement | After `playbox.generate` | After `playbox.generate`, re-measured (§6.3) |
| Describe-equals-apply | Yes | Yes, plus the round trip and the golden gate (§8) |

---

## 16. Findings for other owners

| Id | Finding | Evidence | Where it goes |
|---|---|---|---|
| **F-1** | Opening a project that names an unknown instrument kind fails the whole open, while an unknown effect kind is dropped with a warning | [R `Sources/DAWCore/ProjectDocument.swift:923`, `:972` (typed instrument kind) vs `:296-306` (effect kind as a raw string, dropped with a warning)] | Project-format owner (`swift-app-engineer`); this design does not inherit it (§4.7) |
| **F-2** | D1: `macro.songSkeleton`'s `tracks[i]` can never set an instrument | [R `Commands.swift` fn `parseSkeletonTracks`] | TPL-6, via `template` |
| **F-3** | D2: `tracks[i]` ignores unknown keys | [R same function; only the top level rejects] | TPL-6, flagged |
| **F-4** | The drum machine scans `DrumVoice.allCases` at every note-on; whether that allocates was not measured | [R `DrumKit.swift:82-85`; `DrumSynthInstrument.swift:494-497`] | TPL-0's RT review |
| **F-5** | D3: rock's Drums and Bass have no instrument | [R `SongSkeleton.swift:257-258`] | TPL-3, flagged |
| **F-6** | A General MIDI beat plays the wrong drums on our drum machine | §3.1 [R + D] | TPL-0 |
| **F-7** | The skeleton and `track.setInstrument` label the same GM program differently | [R `SongSkeleton.swift:870-880`; `Commands.swift` fn `deriveSoundBankName`] | Cosmetic; recorded only |
| **F-8** | `macro.songSkeleton` changes the tempo without `setTempo`'s recording and multi-segment guards | [R `SongSkeleton.swift:939`; `ProjectStore.swift:945-951`; M §5.5] | TPL-F8 |
| **F-9** | `mixer.applyPreset` has no recording guard, and replacing a chain that holds a sidechain-keyed effect clears a key edge, which the `removeEffect` rule refuses mid-take | [R `MixerPresets.swift:369-385`; `ProjectStore.swift:3066-3070`; M: `grep -c "requireRoutingMutationAllowed\|isRecording\|transportBusy"` → 0 in `MixerPresets.swift`, positive control 89 in `ProjectStore.swift`] | TPL-F9 |
| **F-10** | `fx.add` applies its `params` object in dictionary order, which varies from run to run; harmless today because no two settings depend on order | [R `Commands.swift:2931-2937`, `:2955-2958`; §2.3] | Latent; TPL-1's one writer makes the builder deterministic |
| **F-11** | The Sketchpad's USE A TEMPLATE swallows any error with `try?` | [R `SketchpadView.swift:290`] | TPL-8 |

---

## 17. The entry owed to `docs/ARCHITECTURE.md` "Key future decisions"

My lane may not edit `ARCHITECTURE.md`. This is the exact text for TPL-9 (or the orchestrator) to add, in the format the
section already uses [R `docs/ARCHITECTURE.md:378-392`]:

```markdown
- **Multi-instrument templates (M39 wave 3): a template is a named, versioned SOUND SETUP (tracks, instruments, insert
chains, buses, outputs, sends, sidechain keys, modulation, volume and pan) with template-local keys, applied by a new
`template.*` surface and by one additive `template` parameter on `macro.songSkeleton`, both through ONE pure builder
(SETTLED 2026-09-27 by design; NOT YET SHIPPED. Full reasoning, every `file:line`, the gates and the rejected
alternatives: `docs/design/2026-09-27-multi-instrument-templates.md`).**

  - **Sound, not form.** Templates own the sound; `macro.songSkeleton` owns the form (tempo, sections, markers, loop). A
    template never contains notes, automation, tempo, the master chain or colour, and `template.apply` never touches an
    existing track.
  - **One schema, one builder.** Built-in, saved, file and inline templates are the same JSON, decoded by one codec in
    DAWCore that judges kinds as raw strings (unknown from a newer writer: skipped with a coded warning; from the same
    version: refused). `TemplateBuilder` is pure; the skeleton's own rosters are re-pointed onto it behind a
    byte-identical golden gate.
  - **Keys, never names.** References resolve inside the template or the template is refused before any edit.
  - **One undo step**, `dryRun`, additive (twice adds twice), refused while recording only when it adds routing.
  - **Prerequisite TPL-0:** the drum machine gains an explicit, appended General MIDI note layout (absent = today's
    36–43 pads, bit for bit); templates write `gm`. The only render-thread change: a `switch` at note-on.
  - **Alternatives that lost:** (1) *extend `macro.songSkeleton` only* (the 09-20 spike): no buses, sends, sidechains,
    modulation or saved templates in v1, and adding a band mid-song would also re-tempo and re-mark the song;
    (2) *a template as a whole-project snapshot*: it carries content and song state, cannot be added to a song, and
    inherits the project format's fail-the-whole-open handling of unknown instrument kinds.
```

---

## 18. Verification ledger (what I checked, and how)

- **Read in source, 2026-09-27**, every [R] above, re-read in this session where other lanes are editing:
  `Commands.swift` by case and function name; `ProjectStore.swift` line numbers re-verified for `setInstrument`
  (:4085-4255), the routing guard (:3050-3092), `setTempo` (:945-951), `applyEffectParam` (:3711-3759), the validators
  (:4276, :4294), `performEdit` (:7836-7850).
- **Measured**, each negative with its positive control stated where it is used: colour fields (§2.1); the spike never
  built and its questions never asked (§1.3); zero template verbs (§2.6); the agent tool census (§2.7); the drum preset
  census (§3.3); `isDrumKit` callers (§3.3); no JSON tree in DAWCore (§5.2); the skeleton's missing guards (§5.5); the
  mixer preset's missing guard (F-9); the `allCommands` placement and its pins (§6.3); the agents directory (§6.6).
- **Derived**: the GM-beat table (§3.1), genre coverage (§7.1).
- **Assumed**, each with what replaces it: every setting value in §4.3 and §7.1 (TPL-4); read-back tolerance (TPL-1);
  the 2 MB bound (TPL-5); render thresholds (TPL-4); that a routed batch has been exercised by the engine (TPL-2, §8.7);
  the sampler wire object's completeness (TPL-5); the export path policy and the file-verb undo precedent (TPL-6); the
  add-track control's name (TPL-8); the agent allowlist split (TPL-9).
- **Not done, by the brief:** no build, no test, no render, no app, no model run. Nothing in this document has been
  executed.

---

## Errata 2026-10-05 (W7-TPL2)

Appended after TPL-2 was built and its plants run. Nothing above this heading was edited. Each item says how it was
established: [M] measured, [R] read in source.

**(a) §8.6's second plant has a different symptom from the one the design states.** The design says an apply that
validates resources inside the edit would leave "a refusal [with] an undo entry". That cannot happen: `performEdit`
runs `let result = try body()` and only then `journal.recordEdit(...)`, so a body that throws records no undo entry at
all [R `ProjectStore.swift`, `performEdit`]. Measured with that plant in place (the resource check moved inside the
edit, after the tracks are appended): the undo depth and `canUndo` stayed unchanged, and the project BYTES changed. The
template's tracks stayed in the song with no undo step that could take them out, which is worse than the stated
symptom [M: `SongSkeletonTests/tpl2RefusalChangesNothing` was the only red test, failing only on its bytes check for the
missing sound-bank and missing sample cases, and on their dry runs, which then succeeded]. The §8.6 row should read:
*"an apply that validates resources inside the edit (a refusal leaves the template's tracks in the song with no undo
step to remove them): the bytes check after a refusal fails."* A refusal test must therefore check the project bytes,
not only `canUndo` and the undo depth.

**(b) Line references that had drifted by the time TPL-2 read them** [M, `grep -n` on the file before TPL-2's edits →
after them]:

| What | This document says | Before TPL-2 | After TPL-2 |
|---|---|---|---|
| `validateSoundBank` | `ProjectStore.swift:4276` | :3877 | :3868 |
| `validateSamplerZones` | :4294 | :3895 | :3888 |
| `performEdit`, its "Module-internal" doc sentence and its signature | :7836-7845 (and :7843-7845) | :7460, :7464 | :7453, :7457 |
| `requireRoutingMutationAllowed` | :3087-3092 | :3087 | :3090 |
| `setTrackOutput` | :3203-3217 | :3203 | :3208 |
| `addSend` | :3225-3243 | :3225 | :3224 |
| `setInstrument` (§18) | :4085-4255 | :3686 | :3676 |
| `applyEffectParam` (§5.2, §18) | :3711 | gone: TPL-1 moved it to `EffectDescriptor.applySetting` in `EffectSettingRules.swift` | same |
| the skeleton's one `performEdit` and its `tracksDidChange` | `SongSkeleton.swift:935-942` | :935, :941 | unchanged |

Cite these by function name; the numbers move with every edit to the shared file.

**(c) `RoutingRules` did not exist after TPL-1.** §5.2's fourth row (a bus outputs only to the master, a bus has no
sends, one send per source per bus) was not moved by TPL-1, which had no grant for `setTrackOutput` and `addSend`
[R: TPL-1's lane record; M: `grep -rln "RoutingRules" Sources Tests` returned nothing, while the same command found
`SidechainRules` in 5 files]. TPL-2 created `Sources/DAWCore/RoutingRules.swift` (`checkOutput(of:to:in:)`,
`checkSend(from:to:in:)`), and in its second round re-pointed both store verbs to it and deleted their inline guards.
It is now the ONE home: the store and the template builder both call it [R]. A plant that removed the duplicate-send
guard from it failed both store-path tests (`BusRoutingStoreTests/addSendRefusesDuplicateDestination`,
`tpl2StoreRefusesEveryRoutingCase`) and both builder-path tests (`TemplateBuilderTests/stepFourRefusesRoutingTheRulesForbid`,
`RoutingRulesTests/outputAndSendRulesInTheStoresOrder`), and nothing else [M]. Every refusal sentence is the one the
store always threw; a test pins them as literals [M].

**(d) A read-back proves nothing unless the write went through the live verb's clamp.** `EffectDescriptor.applySetting`
(formerly `applyEffectParam`) is documented to take "an already-clamped parameter", and it STORES an out-of-range value
exactly as given; `paramValue` reads that value straight back [R]. `fx.setParam` clamps to the spec's range before
calling it. TPL-2's first builder draft did not, so a compressor ratio ten times its maximum was written, read back
unchanged, and passed the §5.3 read-back rule [M: the planted-clamp row of
`TemplateBuilderTests/readBackRefusesAPlantedSnapOrClamp` was planned instead of refused, then refused once the builder
clamped first]. **Warning for TPL-5 (`TemplateCapture`) and for anyone who calls `applySetting` outside the store:** clamp
to `EffectParamSpec.specs(for:)`'s range first, exactly as `fx.setParam` does, or the "the reading is the proof" rule
silently proves nothing.

## Errata 2026-10-05 (W7-TPL2B, the engine batch test, §5.6 / §8.7)

Appended by the orchestrator from W7-TPL2B's report; verified by the orchestrator's own run (38 tests, 0 failed,
2026-10-05 09:25). No line above was edited. Test file: `Tests/DAWEngineTests/TemplateBatchEngineTests.swift`
(an extension of `BusRoutingRenderTests`). [M] = measured, [R] = read, [I] = inferred.

1. **§5.6 "[A] a batch this size has been exercised" is now MEASURED.** A 6-strip routed template (2 buses, 3 sends,
   1 output into a bus, 1 sidechain key, 1 LFO route), applied through `ProjectStore.applyTemplate`, reached the
   engine in ONE `tracksDidChange` and was wired by ONE `reconcile` onto a graph that already held a strip. Both buses
   received their feeds at exactly their send levels (gains 1.3 / 1.4 / 1.5 within 2e-5), clearing −60 dBFS by at
   least 29 dB; with every send at 0 the send-fed bus was exactly silent [M]. The premise needs a correction [R, and
   the plants]: since m13-a, every routing edit on an engine that has run cold-builds ALL strips in one reconcile
   (`AudioEngine.rebuildEngine`), as every bounce does. Two reconcile plants turned 12 existing tests red, so batches
   were already exercised indirectly. What was new: every routing kind plus an LFO in one pass onto existing strips,
   with the store's single call proven.
2. **§8.7 "the key ducks" is MEASURED.** Attack 1 ms, release 50 ms, ratio 4, threshold −24 dB: 8.969 dB of reduction
   10–20 ms after each key burst (the formula gives 8.9691), and the engine's published meter read 8.969 dB within
   20 ms. The audio was back under 0.021 dB 300 ms after each burst, and the meter read 0 again before the next one
   [M]. Those times follow from the attack/release settings and the meter's fall rate, not from the batch [I].
3. **§5.6 "[A] the modulation snapshot is rebuilt for strips created in the same pass" is MEASURED:** an LFO route on
   a strip created by the batch moved its gain between 0.5002 and 1.4998 (expected 0.5–1.5) [M].
4. **§5.6 "[A] what a listener hears during playback" is PARTLY measured.** Any template with a bus, an audio track or
   any routing takes the whole-engine rebuild path, the same interruption that adding an audio track causes; a single
   routing-free instrument track attaches live with no rebuild [M]; an all-instrument template likely does too [I].
   The interruption resumes at the position wall-clock time has reached [R]. Its LENGTH cannot be measured offline:
   a manual-rendering engine has no wall clock. It needs a device: TPL-8's dogfood step "Add to my song while it plays".
5. **For TPL-4:** an `applyTemplate` render compared byte-for-byte with a cold bounce can differ by one float step
   (1.19e-7 measured). The likely cause is the main mixer summing its inputs in a different order [I]. Compare like
   with like, or allow 1e-6.

## Errata 2026-10-05 (W7-TPL3 and W7-TPL5, the orchestrator)

- **D3's symptom (§1.3, §0) was stated wrongly in the TPL-3 brief, not in this document:** rock's Drums and Bass were
  not silent. A track with no instrument falls back to `InstrumentDescriptor.default`, whose kind is `.polySynth`
  [R `Model.swift:1926`], so both played a synth tone. The CHANGELOG says so.
- **§7.1, reggae-riddim:** the table gave its Room bus no feed. The catalog-integrity test (§8.1) refuses a bus nothing
  plays into, so W7-TPL3 fed it from Skank Guitar and Organ. Pans and volumes the table left open were chosen by
  TPL-3 as placeholders for TPL-4.
- **§5.5:** the skeleton's dry run is `planSongSkeleton(...)`; `SongSkeletonResult` gained `templateKeys` and
  `warnings`. Without a template the skeleton still checks no sound-bank file, as before (a new check would change
  what it refuses where the golden gate cannot see it); with one, the order is plan → files → recording guard, as
  `applyTemplate`. `checkTemplateResources` lost `private` so both paths share it.
- **§8.3, plant 1 as worded is inert in this tree** [M, W7-TPL5]: for every setting, the spec default and a fresh
  effect's reading agree (0 differ), and no built-in uses a clipper. The plant that does lose a legacy clipper's 4 is
  "fresh" taken as an effect with no params; it reddens `legacyClipperKeepsItsFour` and the random round trip.
- **§4.6, keys:** the canonical form re-keys tracks from their names, because built-in keys need not match names
  (`sub-bass` for "808 Bass"); without it §8.3 cannot hold [M].
- **§5.7:** `capture` returns a `Result` struct, not a tuple; a gate's dropped sidechain gets its own sentence ("so it
  will not open and close with it").
- **§4.8, the 2 MB bound is kept** [M on 25 Apple Audio Units]: default states 159–1,290 B; AUSampler holding the
  General MIDI drum kit 49,239 B as a plist, 65,652 B as base64. 24 such tracks ≈ 1.58 MB [I]. Third-party states
  were not measured.
- **§7.2 is NOT yet true for samplers:** the codec refuses a `sampler` block, so `template.save` refuses a track that
  plays a Sampler with its own files, in a plain sentence. `TemplateBuilder` also copies a Sampler's zone ids, which
  would share ids between a source track and its copy (unreachable while no file can carry one). Filed as TPL-5b,
  before TPL-6 ships `template.save`.
- **§6.1 `template.import`:** the new-id warning uses the existing `valueChanged` code (path `id`) until an
  `idReplaced` code is added (TPL-5b).

## Errata 2026-10-05 (W7-TPL5B, samplers in templates)

- **§7.2 is now true for samplers** [M]: a template carries a Sampler's zones by absolute path, `~/` path or
  `builtin:<name>`. Zone ids are never written (placeholders in the canonical form) and the builder mints new ones from
  `makeID`, so a copy never shares ids with its source. The previous erratum's "NOT yet true for samplers" is retired.
- **§4.7, no version bump** [M]: a reader from before this change refuses the whole file at
  `tracks[0].instrument.sampler` as `notSupported`; it never drops the block, so it can never build a silent track.
- **§5.1, one departure:** the codec reads the app bundle to resolve `builtin:` sample names, so it is no longer free
  of the file system.
- **§6.4:** the warning-code list gains `idReplaced` (import's new id), replacing the `valueChanged` stopgap.
- The codec is stricter than `parseSampler` on purpose: of 117 pinned rows, 28 are values the wire silently clamps,
  swaps or drops; a version-1 template refuses them by the §5.3 read-back rule.

## Errata 2026-10-05 (W7-TPL4, §8.8 measured)

- **Every [A] in §8.8 is replaced by a measurement** [M]: part heard > −45 dBFS RMS; a drum note lands at spectral
  correlation ≥ 0.9 with decay ratio 0.8–1.2 (20 wrong-voice checks per template must not land); a bus ≥ −60 dBFS and
  ≥ 20 dB over all-silent; a duck ≥ 3 dB within 20 ms of each kick, key-removed control ≤ 0.5 dB; an LFO r ≥ 0.8 and a
  follower r ≥ 0.6, route-off swing < 1/3 and the route-off repeat identical; band −20 to −12 LUFS integrated, true
  peak ≤ −1 dBTP, every part's sample peak < 1.0. The shipped values meet tighter margins: band −19 to −14 LUFS at
  ≤ −2.0 dBTP.
- **Determinism is not an assumption any more** [M]: every instrument in all ten built-ins renders bit-identically
  across two applies and across two processes; no part needs the spectral fallback.
- **The "existing tracks unchanged" leg was blind as first written** [M]: a whole-mix byte compare missed a planted
  re-wire through house-club's pump bus, which passes a signal at unity while its key is silent. The leg now also
  renders each pre-existing track as its own stem before and after; each must be bit-identical, and an after-render
  that cannot produce one is red.
- **The gate is a script, not a test suite**, and it lives in scratch (`$S/w7/TPL4/gate/`); TPL-10 needs it moved into
  `scripts/gates/`.
- **Q2 (§12):** published as four versions differing only in the drum instrument, each drum track's volume set so the
  drums alone match within 1.7 LU (the unmatched set spread 6.5 LU, which would have made the Mac's kit lose on level).
- Limits values cannot fix: the drum machine's peak-to-loudness ratio (13–20 dB) holds pop, house and hip-hop near
  −18 LUFS at the true-peak limit (a drum-bus limiter is the follow-up); two GM guitars and the GM kit sit quiet at the
  fader's 2.0 cap.

## Errata 2026-10-05 (Q2 answered)

- **§7.1 / §12 Q2: Pop Band's drums are the General MIDI Standard Drum Kit, by the user's pick** (volume 1.12, as the
  user heard it). Lines that say Pop Band uses the drum machine are superseded; three built-ins (House Club, Hip-Hop
  808, Lo-Fi Chill) now use the drum machine, so §8.8's drum-note leg covers three, not four.
- **Why the drum machine read "too quiet" to the user while measuring louder** [M]: its hi-hats sit ~24 dB under the
  GM kit's, and the kick is 77–86% of what the loudness meter counts in our kits (48% in the GM kit). Values cannot fix
  it; a new drum-machine hi-hat gain is filed (`dm-hat-gain`), with saved projects keeping today's sound.

## Errata 2026-10-11 (m39-panlaw-new, measured)

- **§8.8's "≤ −2.0 dBTP" (W7-TPL4 errata above) holds only in a song saved before 2026-10-11** [M]. A NEW song uses the
  equal-power pan rule (a panned part plays up to +3 dB louder on its near side), so the panned templates lose headroom
  when applied to one: Jazz Combo −2.54 → −1.76 dBTP, Reggae Riddim −2.17 → −1.83, Soul Groove −2.53 → −2.13, Folk
  −2.40 → −2.09, Rock Band −2.93 → −2.30 (loudness rises 0.4–1.2 LU). All still meet the gate's ≤ −1 dBTP; none meets
  −2.0 in a new song. Measured 8 bars, `$S/w9/PANFIX/r2-panfix1/r2.json`; a saved song keeps the old figures bit-for-bit.
