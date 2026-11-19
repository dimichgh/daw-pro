# M39 wave 4: loop and drum workflow depth (design and build plan)

**Date:** 2026-10-07 · **Author:** W8-W4D (daw-architect lane, read-only) · **Status:** DESIGN. Nothing in this
document has been built, rendered or run. Every number below comes from reading the tree at `e7e4d24` plus the
uncommitted wave-8 tree.

**Tags.** Every factual claim carries one tag:
- **[M] MEASURED**: a command ran and its output is quoted, with a positive control for every absence.
- **[R] READ**: I read the source at the cited `file:line`.
- **[I] INFERRED**: reasoning from what I read. Nobody has run it. It needs a gate before anyone relies on it.

**The mandate (user ruling 2026-09-19, `docs/ROADMAP.md:8-24`, not to be re-asked):** *"(4) LOOP/DRUM WORKFLOW
DEPTH: choke groups, kit-aware slicing, a drum step sequencer on the modulation layer."* Waves 1-3 are built.
"All of them eventually" is part of the ruling.

**What the earlier designs handed to this wave:**
- `docs/design/2026-09-20-drum-machine.md:879-884` and `:1167`: *"Extending the pad grid to `.drumSynth` is wave
  item (4)"* [R].
- `docs/design/2026-09-20-multi-instrument-templates.md:602` and `:769-776`: *"Notes, patterns, drum loops: Wave 4
  owns them"* [R].
- `docs/design/2026-09-27-multi-instrument-templates.md:336`, `:404-406`, `:1335`, `:1381`: the default note layout
  of a NEW drum machine *"stays `pads` in this wave; it goes with wave 4's pad-grid work, where I recommend `gm`"*.
  That design treats it as the m39-ac-2 shape, which went to the user [R].
- `docs/ROADMAP.md:3133`: the `dm-hat-gain` lane is filed as wave 4. It is **already built** (W8-HAT,
  `ROADMAP.md:3084`) and waits on the user's open `hats-level` pick [R]. **This document does not re-propose it or
  re-ask it.**

---

## Contents

1. Census: what exists today
2. The decision: what "a drum step sequencer on the modulation layer" means
3. Design A: the step grid learns the drum machine (lanes, accent)
4. Design B: a tempo-synced step source (the phase problem)
5. Design C: kit-aware slicing
6. Design D: choke groups, the gaps that remain
7. Design E: the pad grid plays the drum machine
8. Design F: drum patterns
9. Build items `m39-w4-1` … `m39-w4-12`
10. Questions for the user and defaults we decide ourselves
11. What we will not build, and why
12. Failure modes, collected
13. Owed outside this document; not verified

---

## 1. Census: what exists today

### 1.1 The table

| # | Capability | State | Where | Tag |
|---|---|---|---|---|
| C1 | Choke group on a **sampler zone** | **EXISTS**: field, clamp 0…63, engine, wire, MCP, tests | field `Sources/DAWCore/Model.swift:2754`, range `:2773`; engine `Sources/DAWEngine/Instruments/SamplerInstrument.swift:690` (`chokeFiredMask`), `:2205-2206`, `:2239`; wire parse `Sources/DAWControl/Commands.swift:16289`, describe `:18354`; MCP `mcp-server/src/server.ts:1605`; tests `Tests/DAWEngineTests/SamplerChokeGroupTests.swift:157-417` (ten functions whose names contain "choke", including a byte-identical no-choke row at `:382`; a name grep, not a full census of the suite) | R |
| C2 | Choke group on a **drum machine voice** | **EXISTS**: closed and open hat default to group 0, every other voice nil | field `Sources/DAWCore/DrumKit.swift:314`, shift-safe resolve `:343-345`, hat defaults `:564`, `:569`; decode never falls back `:29-35`; engine `Sources/DAWEngine/Instruments/DrumSynthInstrument.swift:543-557` (choke fired before the slot is written), fade `:59`; wire overlay `Commands.swift:18081-18089`, describe `:18023-18026`, `:18140`; MCP `server.ts:2165-2354` | R |
| C3 | Choke **physics** on the drum machine | **EXISTS** | `Tests/DAWEngineTests/DrumSynthTests.swift:670` (closed hat cuts open hat ≥ 40 dB, isolated by subtraction), `:706` (fade takes 1.5–6 ms, not a hard cut) | R |
| C4 | Choke **UI** anywhere | **MISSING** | `grep -rc chokeGroup`: `Sources/DAWApp` **0**, `Sources/DAWAppKit` **0**; positive control `Sources/DAWCore` **48** | M |
| C5 | Choke on a **GM sound-bank kit** (Apple DLS through `AVAudioUnitSampler`) | **UNKNOWN**: nothing in the tree reasons about it, and nobody has measured it | `grep -rn -i -e "exclusive class" -e exclusiveClass -e keyGroup -e "exclusive group"` over `Sources/` and `docs/research`: **0 lines**. Positive control: the same command with `-e "mono choke"` added returns 4 lines | M |
| C6 | Choke **across tracks** | **MISSING**, and not proposed (§11) | each instrument holds its own choke state | R |
| C7 | Chop a clip into sampler pads (`clip.sliceToSampler`) | **EXISTS**, **chromatic only**: pad *i* sits on `baseNote + i` | verb `Commands.swift:5241`; `Sources/DAWCore/SliceToSampler.swift:39` (`baseNote`), `:55` (default 36), `:349` (`pitch = settings.baseNote + i`); store `Sources/DAWCore/ProjectStore+SliceToSampler.swift:146-300` | R |
| C8 | Slicing assigns choke groups | **MISSING** | `grep -c chokeGroup`: `SliceToSampler.swift` **0**, `ProjectStore+SliceToSampler.swift` **0**; controls in the same files: `baseNote` or `SamplerZone` **13** and **1** | M |
| C9 | Know what kind of drum a slice is | **MISSING**. The parts exist: per-window spectral balance + centroid, off the render thread | `Sources/DAWCore/EngineProtocol.swift:844-845` (`analyzeAudioContent`), `Sources/DAWEngine/Analysis/AudioContentAnalyzer.swift:62` (file entry), `:79` (pure core), `Sources/DAWCore/AudioAnalysis.swift:133-147` (`SpectralBalance`: 24 bands, `centroidHz`, 6-band summary) | R |
| C10 | A sampler zone can carry a name or drum role | **MISSING**: the stored fields are id, file, pitches, gain, velocity/round-robin, tuning, pan, envelope, loop, crossfade, reverse, `chokeGroup` | `Model.swift:2636` onward | R |
| C11 | Step grid over a MIDI clip (m23-cq-1) | **EXISTS**: mouse-only toggle, writes the same `[MIDINote]` the piano roll does | `Sources/DAWAppKit/StepSequencerModel.swift`, `Sources/DAWApp/PianoRoll/StepSequencerGrid.swift` | R |
| C12 | Step-grid rows know the instrument's drums | **PARTIAL**: a drum kit gets the 17 notes of the GM table; anything else gets C3–B4 (48…71) | `StepSequencerModel.swift:124-145`; GM table `Sources/DAWCore/InstrumentFamilyResolution.swift:286-304` (no 37 side stick, no 39 hand clap) | R |
| C13 | Our drum machine counts as a drum kit | **ONLY in the `gm` layout.** The default is `pads` | `Sources/DAWCore/ProjectMIDIExportMapper.swift:1023-1034` (`.drumSynth` → `noteLayout == .gm`); default `.pads` at `DrumKit.swift:443-448` | R |
| C14 | The consequence of C12 + C13 for a new drum machine | It opens in the piano roll, not the step grid. Switched to Steps, its rows are C3–B4, which play nothing: `pads` answers only 36–43 | policy `StepSequencerModel.swift:59-71`; `pads` map `DrumKit.swift:195-205` | I |
| C15 | Accent in the step grid | **MISSING**, and **the grid's default velocity sits on the accent line**: the grid (and the piano roll) write 100, and the drum machine accents every hit at velocity **≥ 100**, so every hand-entered hit is already accented and an accent has nothing to stand out from | `StepSequencerModel.swift:625-629` (`defaultVelocity = 100`, "no velocity gesture in v1"); `DrumKit.swift:413-415`, `:600` (`accentThreshold` default 100, "at or above"); `DrumSynthInstrument.swift:608-610` (`>=`) | R (cause), I (effect) |
| C16 | Step **modulation source** (`.stepSequencer`) | **EXISTS, and can lock to the beat** (`stepDivision`, shipped m39-w4-4; it was refused when this row was written) | kind `Sources/DAWCore/Modulation.swift:30`; params `:182-195`; refusal `:1019-1022`; `maxSteps = 64` `:440`; evaluator `Sources/DAWEngine/Modulation/ModulationEvaluator.swift:47-55` (`p / samplesPerStep`) | R |
| C17 | Its edges are **centred on the step boundary** | At a boundary it returns the **midpoint** of the two steps | `Modulation.swift:690-710` (`frac < h` → `raisedCosine(previous, current, (frac + h) / (2h))`, which is 0.5 at `frac == 0`) | R |
| C18 | The tempo-sync home (m39-c) | **EXISTS** for effects AND for the step sequencer (`stepSequencerRegistration`, m39-w4-4); the LFO has no entry | `Sources/DAWCore/TempoSync.swift:37-41` (names the step sequencer as the next consumer), `:97`, `:174` (`rateHz(of:atTempoBPM:)`) | R |
| C19 | The tempo map has ramps | **NO**: piecewise-constant in v1 | `Sources/DAWCore/TempoMap.swift:29-31` | R |
| C20 | Modulation position is musical | **NO**: `originSample + renderStart`, a sample count since the roll anchor. It does not wrap at a loop and does not bend at a tempo change | `Sources/DAWEngine/Automation/AutomationRenderer.swift:226-228`; `Sources/DAWEngine/PlaybackGraph.swift:2279-2284` (`modulationOrigin`) | R |
| C21 | A modulation snapshot is rebuilt when only the tempo map, meter or loop changes | **NO**: the publish key is `(strip, originSample, positionValid)` | `PlaybackGraph.swift:472-490` (`ModulationPublishKey`), fast path `:2297-2302` | R |
| C22 | Any modulation UI | **MISSING** | `grep -rc ModulationSource`: `Sources/DAWApp` + `Sources/DAWAppKit` **0**; control `Sources/DAWCore` **97** | M |
| C23 | Drum machine editor card | **MISSING**, on purpose until it is built | `Sources/DAWApp/Instrument/InstrumentPickerView.swift:233-236`; `Sources/DAWApp/ViewUIWireSurface.swift:363-376` | R |
| C24 | The drum machine's voices appear anywhere in the UI | **NO** | `grep -rc DrumVoice` over `Sources/DAWApp` + `Sources/DAWAppKit`: **0** (control: `DrumKit.swift` defines the enum) | M |
| C25 | Pad grid plays the drum machine | **NO**: its zones come from the sampler only | `Sources/DAWAppKit/PadGridModel.swift:297-298` | R |
| C26 | Drum patterns on the wire | **MISSING**. The only drum pattern in the tree is the harness-only audition pattern | `Sources/DemoRender/DemoRender.swift:263-353` (`private enum Audition`, "no wire verb writes these"); `playbox.generate` writes chords only (`Commands.swift:8353-8380`); the case census for `pattern`/`beat`/`drumPattern` returns only `groove.*` and `playbox.generate` | R / M |
| C27 | Swing and grooves | **EXISTS** | `clip.quantize` `swing` 50…75 (`Commands.swift:5017-5030`); `groove.extract/list/remove` (`:7736-7791`); 8 built-in MPC swings (`Sources/DAWCore/Groove.swift:125-133`) | R |
| C28 | Repeat a pattern | **EXISTS** as concrete copies | `clip.repeatNotes` (`Commands.swift:4488`) | R |
| C29 | Agents know the drum machine's notes | **EXISTS** | `instrument.describeDrumKit` (`Commands.swift:2749`) reports `voiceNotes`; MCP `instrument_describe_drum_kit` (`server.ts:4741`) | R |
| C30 | The documented agent convention for accents | "110 on accented steps and 80 elsewhere" | `server.ts:2514-2518` | R |

### 1.2 What the census changes about the mandate

1. **Choke groups are mostly built.** The mechanism, the wire, MCP, and physics tests exist for both of our
   instruments (C1–C3). What is left: no UI (C4), sliced kits never get one (C8), the GM kit is unmeasured (C5).
   This wave does **not** redesign the mechanism.
2. **The step grid already exists, and our own drum machine falls through it** (C12–C14). Making the grid read the
   drum machine's own note map is the smallest build with the most value for a beginner in this wave.
3. **"On the modulation layer" has one real blocker: phase.** The step source exists but runs free (C16). It cannot
   land on bar lines until it reads a musical clock (C19–C21). Its centred edges (C17) would also make a drum
   parameter that is read at note-on take the average of two steps.
4. **The grid's default velocity sits on the drum machine's accent line** (C15), so accents cannot stand out on the
   surface this wave builds. It goes in the plan as a defect fix. The lever is the entry velocity, not the kit (§3.4).
5. **Patterns belong here** (the templates design says so), and nothing writes one on the wire (C26).

---

## 2. The decision: what "a drum step sequencer on the modulation layer" means

The tree already has two things called "step sequencer":
- the **grid** (m23-cq-1): a note editor over a MIDI clip's `[MIDINote]`, and
- the **modulation source** (`.stepSequencer`): a value that changes over time and is routed to parameters. By
  design it never makes a sound or starts a note.

Neither one is a drum step sequencer on its own.

**Decision: build them as two halves of one grid.**
- **The notes half**: the step grid, made kit-aware. Its rows are the drums of the instrument on the track, it opens
  in steps for every drum instrument, and it has an accent row. Notes stay in MIDI clips, their one home.
- **The sound half**: the step modulation source learns tempo sync. It reads a musical clock, so step *k* of a 1/16
  pattern lands on the *k*-th sixteenth after the bar line, through tempo changes and loops. Routed to a drum
  parameter (`openHat.decay`, `snare.tune`), it gives each step its own sound, like the "parameter locks" on
  hardware drum machines. The drum machine reads its parameters when a hit starts, so each hit takes the value of its
  step.

A novice sees one surface: rows of drums, an accent row, and (last item) a "sound" row under a chosen drum. An agent
gets the same through `clip.setNotes` plus `mod.addSource {kind: stepSequencer, stepDivision: "1/16"}`.

**Alternative 1, rejected: a modulation source that triggers drum hits.** It would put notes in a second home. Every
consumer of `[MIDINote]` (step grid, piano roll, quantize, grooves, `clip.repeatNotes`, MIDI export, the pattern
verb) would be blind to them. It would also need a new event path on the render thread. The research costed that
as the "Tier B / event queue" problem (`docs/research/2026-09-19-modulation-macros.md:325`, `:616`). And it breaks the
modulation layer's contract that a source is a value at a position.

**Alternative 2, rejected: the grid only, with no sync.** It drops the "on the modulation layer" half of the ruling.
It also leaves per-step sound impossible, because a free-running source drifts off the grid after the first tempo
change (C20).

**Alternative 3, rejected for now: per-note parameter overrides** (a `MIDINote` field holding "this hit's decay").
It is exact by construction, and the override moves with its note. But it is not the modulation layer. It adds a
field to the most widely consumed type in the tree. And only the drum machine would honour it. It stays a candidate
if per-step sound proves too fragile in practice (§11).

---

## 3. Design A: the step grid learns the drum machine (lanes, accent)

### 3.1 What a novice sees

> You add a Drum Machine, double-click its clip, and the step grid opens. The rows read **Kick, Snare, Closed Hat,
> Open Hat, Clap, Tom, Rim, Cymbal**, kick at the bottom. Below them is an **Accent** row: click a column and every
> hit in it plays harder. The same happens for the General MIDI kit and for a loop you chopped into a kit (§5).

Today, the same steps open a piano roll. Flipped to Steps, the rows are C3 to B4, and none of them makes a sound (C14).

### 3.2 One home for "which rows does a drum instrument have": `DrumLaneMap`

New file `Sources/DAWCore/DrumLaneMap.swift` (pure, headless, no UI types):

```swift
public struct DrumLane: Sendable, Equatable {
    public let note: Int            // the MIDI note this row writes
    public let label: String        // what a beginner reads ("Kick", "Open Hat", "Kick 2")
    public let voice: DrumVoice?    // the drum, when the instrument knows it
}
public enum DrumLaneMap {
    /// nil = not a drum instrument; the grid keeps its melodic window.
    public static func lanes(for instrument: InstrumentDescriptor?) -> [DrumLane]?
}
```

- **`.drumSynth`**: eight lanes, one per `DrumVoice`, at a new one-home `DrumVoice.primaryNote(in: layout)`. In
  `pads` it is `note` (36 + slot). In `gm` it is kick 36, rim 37, snare 38, clap 39, closed hat 42, tom 45, open hat
  46, cymbal 49. It is a `switch` (render-thread style is not needed here, but it keeps the F-4 shape). A test pins
  `voice(forNote: primaryNote(in: l), layout: l) == self` for both layouts, so the new function is derived from the
  one map and cannot become a second table. Labels are `DrumVoice.displayName` (`DrumKit.swift`, "Kick" … "Cymbal").
- **`.soundBank` on the percussion bank**: today's 17-row GM table, **unchanged** (C12). Adding 37 and 39 there is a
  separate question (§11).
- **`.sampler` whose zones carry `drumRole`** (Design C): one lane per distinct single-key zone pitch that has a
  role, labelled by role, with an ordinal when a role repeats ("Kick", "Kick 2").
- **Everything else**: nil.

`StepSequencerLanes.lanes` keeps its rule that **every pitch present in the clip gets a row**
(`StepSequencerModel.swift:116-122`); a present note outside the map is labelled by its note name, as today. Rows
stay in descending pitch order (`:107-115`). For `pads` that puts the kick at the bottom with no special case [I].

### 3.3 The editor-mode predicate moves to the lane map, and `isDrumKit` stays as it is

`ClipEditorModePolicy.resolve(override:isDrumKit:)` (`StepSequencerModel.swift:68-71`) is fed today by
`SMFProjectExporter.isDrumKit` (`Sources/DAWApp/ContentView.swift:1934-1938`). Feed it `DrumLaneMap.lanes(for:) != nil`
instead.

**Do not widen `SMFProjectExporter.isDrumKit`.** It also picks MIDI export channel 10
(`ProjectMIDIExportMapper.swift:423-427`, `:480`, cited by the templates design at `:330`). A `pads` drum machine or
a sliced kit with extras above note 81 is not a General MIDI kit, and exporting it on channel 10 would make every
other program play the wrong drums. Two questions, two predicates.

The staging surface already emits `isDrumKit` (`Sources/DAWApp/PianoRoll/StepSequencerStaging.swift:194`). **Add a
key** (`drumLanes`: the row count, or 0). Do not change what `isDrumKit` means there; existing gates read it.

### 3.4 Accent: move the entry velocity, not the kit

**Decision.** A hand-entered note's velocity comes from ONE home in `DAWCore`:

```swift
public enum NoteEntryDefaults {
    public static let melodicVelocity = 100
    /// Held at 100 (today) until the user's listening pick (§10, L1). Below 100 = un-accented on the drum machine.
    public static let drumVelocity = 100
    public static let accentVelocity = 127
    public static func velocity(hasDrumLanes: Bool) -> Int
}
```

Both note-minting gestures read it:
- `Sources/DAWAppKit/PianoRollModel.swift:495-497` (`addNote`, today a literal `velocity: 100`), and
- `Sources/DAWAppKit/StepSequencerModel.swift:629`, `:723-725` (`StepSequencerEdit.defaultVelocity`).

**Census method** [M]: `grep -rn "MIDINote("` over `Sources/DAWApp` and `Sources/DAWAppKit` returns 8 sites. Two of
them mint a fresh note with a default velocity: the two above. The other six rebuild an existing note and carry its
velocity: `PianoRollModel.swift:676, 730, 816, 848, 858` and `PasteAnchorPolicy.swift:742`. The six are READ by their
shape (`velocity: $0.velocity` at `:742`), not each traced, so treat them as [I] and re-census before building. Live
playing (`AuditionController.defaultVelocity`, `Sources/DAWCore/Audition.swift:51`; the musical-typing and pad
velocity) is **performance velocity**, has its own controls (K/L, O/P), and is out of scope.

The predicate is `DrumLaneMap.lanes(for:) != nil`, never `isDrumKit`. Through `isDrumKit`, the GM kit would get the
drum default and our own `pads` drum machine would get the melodic one.

**Why the entry velocity and not the kit's `accentThreshold`.** I first planned to raise the kit's threshold to 110
for new kits. The census killed that idea three times over [R]:
1. Every factory preset starts from `DrumKitParams()`: the 808 IS `DrumKitParams()` (`DrumKit.swift:1165`), and the
   other four begin `var p = DrumKitParams()` (`:1216`, `:1241`, `:1269`, `:1295`). Every preset would inherit the new
   threshold.
2. `matchingPreset` is defined as "loading this preset would change nothing" (`:1206-1212`). Every saved kit stores
   `accentThreshold: 100` (the encoder writes every non-trim kit leaf, `:1132-1139`), so every saved "909" would
   start reading as a custom kit.
3. Three built-in templates (`hip-hop-808`, `house-club`, `lofi-chill`) name a `drumPreset` and set no threshold
   [M: `grep -c` per template file, `accentThreshold` 0 in all ten, `drumSynth` 1 in those three]. Their audition
   snare plays at 105 and their crash at 100 (`DemoRender.swift:340-352`), so both would lose their accent. That
   would move template sounds the user has already listened to.

The velocity lever has none of these. Notes store their own velocity, so no saved project, template or preset
changes. Both editors read one function, which keeps the law at `StepSequencerModel.swift:625-628` ("a note authored
in either editor sounds identically") **by construction**. Today it holds only because two literals happen to agree.
Held at 100 until the user picks, the item lands with **zero behaviour change**, which is the W8-HAT shape.

### 3.5 The accent row

- One row under the drum rows, labelled **Accent**. Mouse-only, like the rest of the grid (the m23-cq-1 scoping
  rule: no keyboard on this surface).
- **Write.** Clicking a column sets every note that starts in that column to `accentVelocity` (127). Clicking it
  again sets them back to `drumVelocity`. A note toggled on in an accented column is born at 127. Each click is one
  commit through the grid's existing `commit()` funnel, so it is one undo step.
- **Read: against the accent constant, never against the kit's threshold.** A column shows as accented when every
  note in it is at or above 127, and as a half-state when the notes in it disagree. If it read `kit.accentThreshold`
  (100 by default), then under the "100" listening option every column would light up. That is the obvious wrong way
  to build it, so the gate plants it (§9, `m39-w4-3`).
- On a GM kit or a sampler, which have no accent bus, an accent is simply velocity 127. On the drum machine, it also
  passes the threshold, so it gets the extra `accentDepth` level and tone (`docs/design/2026-09-20-drum-machine.md`
  §5).

### 3.6 Persistence

Nothing new is stored. Lanes are derived from the instrument. Accents are note velocities. The entry default is a
constant. Old projects decode and render byte-identically, because nothing they contain is read differently.

---
## 4. Design B: a tempo-synced step source (the phase problem)

### 4.1 The problem, measured from the source

- **The rate needs one tempo, but the phase needs the whole tempo map.** The evaluator computes
  `p / samplesPerStep` (`ModulationEvaluator.swift:47-55`). Here `p = originSample + renderStart`
  (`AutomationRenderer.swift:226-228`), a sample count since the roll anchor [R]. After a tempo change, a rate
  derived from one tempo drifts off the bar lines. Inside a transport loop, `p` keeps counting up (the roll timeline
  is unrolled), so a pattern whose length does not divide the loop restarts in the wrong place [I]. The m39-c row
  (`ROADMAP.md:5778`) recorded the first half. The second half follows from C20.
- **There are no tempo ramps** (`TempoMap.swift:29-31`) [R]. The map is piecewise-constant, so between tempo changes
  the beat is an exact linear function of the sample. Alignment is cheap.
- **A snapshot is not rebuilt for a tempo, meter or loop edit alone** (C21). `restart(.continuation)` on a tempo
  change mid-roll (`AudioEngine.swift:1363-1376`) moves the anchor and so `originSample`, which does republish. An
  edit made while stopped, after the play position, leaves `originSample` unchanged, so the old clock would survive
  the next play press [I].
- **Centred edges** (C17): at a step boundary the source returns the midpoint of the two steps. The drum machine
  reads modulation **when a hit starts** (`DrumSynthInstrument.swift:538-539`, `trigger(…, modulation:,
  modulationSample:)`) [R]. A hit exactly on the grid line would latch the average of two steps [I].
- **Rounding.** MIDI events land on `round(seconds(from: fromBeat, to: beat) · rate)` (`MIDISchedule.swift:163-166`)
  [R]. If the clock places a step edge with any other expression, roughly half the hits that sit on the grid read the
  step before [I].

### 4.2 Decision: one musical clock per snapshot, compiled on the control plane

`ModulationSnapshot` gains a variable-length array of plain values, sized and filled by `ModulationSnapshotBuilder`
on the main actor exactly like `sources`, `routes` and `steps` already are (`ModulationSnapshotBuilder.swift:55-60`),
and freed by the same retire bin:

```swift
struct ClockSegment {              // POD, no references
    var startSampleExact: Double   // roll-relative, UNROUNDED: seconds(from: fromBeat, to: startBeat) · rate
    var startBeat: Double          // project beat at the segment start
    var beatsPerSample: Double     // constant inside the segment (no ramps)
    var patternOriginBeat: Double  // where step 0 sits: song beat 0, or the bar of the last meter change
}
```

**Segments split at:** the roll anchor; every tempo change; every meter change (which also resets
`patternOriginBeat`); every loop-cycle start. Cycles are unrolled with **the same `offsetSeconds` arithmetic as
`AutomationSchedule.buildLoopCycleBreakpoints`** (`AutomationSchedule.swift:205-213`) and the MIDI schedule's cycle
blocks, for as many cycles as those builders unroll. Whatever extends them also extends the clock.

**Render side, for a synced step source at roll sample `n`.** The evaluator's `p` is project-absolute
(`originSample + renderStart`, C20), so `n = p − snapshot.originSample`. Index the clock by `n`, never by `p`, or
every roll that does not start at beat 0 reads the wrong segment.

```
seg      = the last segment with floor(startSampleExact) <= n      // binary search, a `while` loop
beat     = seg.startBeat + (Double(n) + 0.5 - seg.startSampleExact) * seg.beatsPerSample
stepPos  = (beat - seg.patternOriginBeat) / divisionBeats
value    = ModulationMath.stepSequencer(stepPosition: stepPos + h, …)   // h = half the edge fraction
```

- **`+ 0.5` is the rounding alignment.** A hit scheduled at frame `N = round(x)` for an edge at exact sample `x`
  has `N + 0.5 − x` in `[0, 1]`, so it reads step *k*. Frame `N − 1` reads step *k − 1*. This is the same boundary
  the MIDI schedule's `round` draws [I, and gated by G5].
- **`+ h` makes the edge trailing.** The existing centred closed form, evaluated `h` later, ramps over
  `[k − 2h, k)` and returns exactly step *k* at the boundary. **The math in `ModulationMath` does not change**, and
  free-running sources do not get the shift, so they render bit-identically.
- **No state carries across blocks.** The binary search runs per evaluation, which is stateless and obviously
  seek-exact. A block-local hint is allowed as an optimisation only if it is recomputed from the position every
  block: the no-accumulator law (`ModulationEvaluator.swift:58-64`) is test-pinned, not style.
- **The render thread never sees a `TempoMap`.** It does a multiply-add on plain values. The TempoSync law ("the
  render thread never does a tempo lookup", `TempoSync.swift:28-31`) should be restated as *"…never consults the
  tempo map; it may read a precomputed clock"*. That is an owed doc edit (§13).

**The publish key gains the clock.** `ModulationPublishKey` (`PlaybackGraph.swift:472-490`) gets
`clock: ClockFingerprint?`, and it is part of `structural`. The fingerprint is the tempo-map events, meter-map events,
loop region and on/off, and `fromBeat`. It is **nil when the strip has no synced source**, so every existing strip
keeps exactly today's publish behaviour. Every path that edits tempo, meter or loop must reach `publishModulation`
for strips that do have a synced source, including while stopped.

**What is unlocked, and only this.** `stepDivision` on `.stepSequencer` (one of the 18 `NoteDivision` values,
`TempoMap.swift:266`). `TempoSync` gets the sibling table its own header asks for (`TempoSync.swift:37-41`), keyed by
source kind. `syncDivision` on the LFO **stays refused**. The clock makes it possible, but that is a separate item
(§11).

**Where a pattern starts.** Step 0 sits at song beat 0, and the pattern starts again at every time-signature
change. A 16-step 1/16 pattern therefore repeats once per 4/4 bar. In 3/4, use 12 steps. `mod.describe` says this in
words, and reports `stepsPerBar` at the current meter.

### 4.3 What it costs and what it does not do

- One pattern per source covers the whole track: the source belongs to the strip, not to a clip. Different sounds
  per section need several sources, switched with a macro or automation. This is the price of putting per-step
  sound on the modulation layer (§2, alternative 3).
- When the transport is stopped, `positionValid` is false and the source holds neutral (`ModulationSnapshot.swift:20-25`),
  so pad hits while stopped play the plain sound [R].
- A hit nudged **early** by humanize lands in the previous step's ramp. That is inherent to anything keyed by
  position. Swing only delays off-beats, so swing is safe [I].
- **m39-d, by target class** (`ROADMAP.md` m39-d row; the live block size is unmeasured):
  - **Instrument parameters** are evaluated in the instrument's per-frame loop (`PlaybackGraph.swift:2311-2314`)
    and latched at note-on, so drum per-step sound does not depend on block size [R].
  - **Volume and pan** are summed per sample in the stage [R].
  - **Effect parameters** are block-rate, so a synced gate on an effect could differ between monitoring and
    bouncing.
  - The unlock reaches every target class at once, and we do not invent a per-target refusal to dodge that. So
    **m39-d's 64/128/1024-frame measurement must be recorded before the unlock merges.** The build can run in
    parallel.

### 4.4 Wire, MCP, persistence

- **Wire** (additive): `mod.addSource` / `mod.setSource` stop refusing `stepDivision` on `stepSequencer`
  (`Modulation.swift:1019-1022`). When it is set, `rateHz` is **inert**. The setter says so in the reply, built by
  the same function `mod.describe` uses: the W7-SMP lesson, where an inert sampler release replied success
  (`ROADMAP.md` W7-SMP block, ~:3006). `mod.describe` reports `stepDivision`, `stepsPerBar` and the sentence about
  where the pattern restarts.
- **MCP**: the nested `stepSequencer` params schema in `mod_add_source` / `mod_set_source` (`server.ts:14881`,
  `:14932`) gains `stepDivision` as a strict enum (nested schemas are `.strict()`, the m30-c law). The description,
  written for a novice: *"`stepDivision: "1/16"` locks the steps to the song's sixteenth notes, so step 1 is always
  the bar line."*
- **Persistence**: none new. `stepDivision: String?` is already in the model and already
  `encodeIfPresent`/`decodeIfPresent` (`Modulation.swift:182`, `:297`, `:328`) [R]. Every saved project has nil,
  because the store refused anything else, so it renders free-running exactly as today. A hand-edited file that
  carries a value would start syncing; no verb can produce one [I].

---
## 5. Design C: kit-aware slicing

### 5.1 What a novice sees

> You drop a drum loop on a track, open **Chop to Pads**, and tick **"Sort the hits into a drum kit"**. The kicks
> land on the kick pad, the snares on the snare pad and the hi-hats on the hat pads. A closed hat cuts off a ringing
> open hat, like on a real kit. Anything it does not recognise goes on the last row of pads. The step grid's rows
> say Kick, Snare, Closed Hat, Open Hat. Any beat written for the General MIDI kit now plays your loop's sounds.

Today every slice lands chromatically on `36 + i` (C7). A General MIDI beat played on that kit triggers whichever
slice happens to sit on 38 or 42.

### 5.2 Decision

`clip.sliceToSampler` gains two additive, optional parameters:
- `mapping`: `"chromatic"` (absent = today, byte-identical) or `"kit"`;
- `roles`: an override map, slice index → `"kick" | "snare" | "closedHat" | "openHat" | "other"`, applied
  before classification. This is the shape of `template.audition`'s `roles` override (`DemoRender.swift:1032-1044`)
  [R].

In `kit` mode the store makes one more off-render-thread call, then three pure steps:

1. **Engine: measure each slice** (new `AudioEngineControlling` method, `Sources/DAWCore/EngineProtocol.swift`):
   `analyzeSliceTimbres(inFileAt:frameRanges:) async throws -> [SliceTimbre]`. It reads the file **once** and runs a
   pure per-slice feature function in a detached task, like `detectTransients`. It reuses the band/centroid code in
   `AudioContentAnalyzer` (`:232-275`) by factoring out the spectral-balance helper. It does not call the whole
   `analyze`, which also estimates key and tempo. Features: share of energy below 150 Hz, share above 5 kHz,
   centroid over the first 80 ms, decay time from peak to −20 dB, spectral flatness. It slots in between
   `resolveSliceBoundaries` and `SliceToSamplerPlan.compute` (`ProjectStore+SliceToSampler.swift:259-270`), with the
   file's re-locate-after-every-await discipline.
2. **`DrumHitClassifier`** (DAWCore, pure): features → `(role: DrumVoice?, confidence)`, where the role is kick,
   snare, closedHat or openHat, and **nil means "other"**. Open versus closed hat is decided by decay time.
   Thresholds are fitted on the corpus in §9 and then frozen with a test.
   **Why only four:** Ableton's "Convert Drums to New MIDI Track" *"attempts to identify kick, snare and hihat
   sounds"* and names no others (its manual, fetched 2026-10-07; sources at the end). Third-party write-ups say its
   hi-hat lane catches everything else; that part is a search summary I did not verify. We keep an explicit "other"
   instead of folding it in. That is the GM table's own rule against folding (`InstrumentFamilyResolution.swift:279-285`).
3. **`KitSliceLayout`** (DAWCore, pure): roles and transient strengths → notes, **in General MIDI numbering**.
   Within a role, the strongest slice gets the role's first note: kick 36 then 35, snare 38 then 40, closed hat 42
   then 44, open hat 46. Overflow and "other" go to **extras from note 84 upward**, in time order. 84 is the first
   pad of bank 4 (36 + 48), and no General MIDI drum sits there, so no extra is ever labelled as a GM drum. If the
   extras would pass 127, the call is refused with a sentence, in the style of the existing "MIDI stops at 127"
   refusal (`SliceToSampler.swift:252-257`).

**Zones.** Each zone gets `drumRole` (new field, §5.3). In kit mode, closed and open hats get `chokeGroup: 0`. The
sampler's choke mechanism (C1) does the rest; there is **no new render code**. Chromatic mode writes neither.

**Reconstruction clip.** Same timing, length and velocity as chromatic mode, at the assigned notes.

**Result.** Each pad gains `role` and `confidence`, plus one sentence: *"Sorted into 4 kicks, 3 snares, 8 closed
hats, 1 open hat and 2 other hits."* After the fact, `sampler.zonePatches` (the m26-g merge path) accepts `drumRole`,
so a person or agent can correct one zone without re-chopping.

### 5.3 The one new stored field: `SamplerZone.drumRole: DrumVoice?`

Optional and `encodeIfPresent`, so an absent key decodes as nil and old projects re-save byte-identically. It reuses
the one-home enum (`DrumKit.swift`). It is **not** named `role` or `group`: `SamplerZone.group` is already the
round-robin group.

**Why store it rather than only report it.** A role reported only in the chop result would vanish on reopen. The
grid would then fall back to C3–B4 for the kit, which is the C14 gap all over again (`isDrumKit` is false for
`.sampler`, `ProjectMIDIExportMapper.swift:1031`). And a person's correction to a wrongly sorted hit could not
persist. Storing the role is what lets `DrumLaneMap` (§3.2), the pad grid (§7) and `instrument.describeSampler` say
"Kick".

**Census method for the implementer, not a number:** every site that names `chokeGroup` or `reverse` on a
`SamplerZone` is a site `drumRole` must visit. That covers `Model.swift`, `ProjectDocument.swift`, the zone parse and
describe in `Commands.swift`, `TemplateCapture.swift`, `TrackSetTemplateCodecInstruments.swift`, the kitchen-sink
fidelity fixture, `SamplerZoneIdentityWireTests`, `TemplateSamplerWireParityTests`, and `server.ts`. Run the census;
do not trust this list.

### 5.4 Choices made, and why the alternatives lose

| Choice | Rejected | Why the rejected option loses |
|---|---|---|
| Distinct notes per slice | Round-robin on one key (`group`/`seqLength`/`seqPosition`) | The reconstruction replay would depend on cycle state, so a seek or loop would play a different kick. |
| Distinct notes per slice | Velocity layers on one key | The replay's level would depend on velocity scaling, so it would stop being the original loop. |
| General MIDI numbering | `pads` (36–43, one note per drum) | `pads` cannot hold a second kick, and a GM beat (the pattern verb, a MIDI file) would play the wrong drums. |
| Store `drumRole` | Report the role only | Labels vanish on reopen, and corrections cannot persist (§5.3). |
| Four roles + "other" | All eight drum voices | Tom/snare and cymbal/open-hat confusions are where classifiers fail. "Other" is honest, and a person can relabel. |

---

## 6. Design D: choke groups, the gaps that remain

The mechanism, wire, MCP and physics are done for both of our instruments (C1–C3). Three gaps remain, and one of
them is unmeasured:

1. **Sliced kits never get a choke group.** Closed by Design C.
2. **No UI anywhere** (C4). Closed by a small, honest surface on the pad grid (§7): a link mark between pads that
   cut each other, with an explanation in plain words. There is no editor for choke numbers. A beginner needs to see
   that hats cut each other, not to type group 0. Agents already set any group through `track.setInstrument`'s
   `drumKit` overlay (`Commands.swift:18081-18089`) or `sampler.zonePatches`.
3. **The General MIDI kit is unmeasured** (C5), and since the user's 2026-10-05 pick it is the drum sound of the pop
   band template. Measure first (`m39-w4-1`):
   - **(a)** Play 46 then 42 at +100 ms, isolate by subtraction (the `DrumSynthTests.swift:670-697` method), and
     compare the open-hat tail against an un-choked control.
   - **(b)** Does a short note-off on 46 shorten it at all?
   - **Outcomes:**
     - Apple's DLS chokes natively: nothing to build, record the measurement.
     - It does not choke, but note-off works: a **control-plane** synthetic choke (`m39-w4-9`).
     - Neither: it cannot be fixed without replacing the sampler. Say so to agents, and steer them to the drum
       machine.

**The synthetic choke, if needed (`m39-w4-9`).** For a track whose lane map is the GM kit, a note-on of 42 or 44
emits a note-off for any sounding 46 **at the same frame**. It is built in two control-plane places:
`MIDIEventSchedule.buildEvents` (`MIDISchedule.swift:156`) for playback, and the main-actor `LiveNoteSink` push for
pads and musical typing. **Zero render-thread code.**

Saved projects must not change, so it hangs off a new optional flag on the sound-bank descriptor (`hatChoke: Bool?`,
absent = off). New GM drum tracks get `true`. That is a delegated default (§10): an open hat that keeps ringing under
a closed hat is not a taste, it is a physical impossibility on a real kit.

---

## 7. Design E: the pad grid plays the drum machine

Both earlier designs deferred this here (`drum-machine.md:879-884`, `templates.md:336`) [R].

- **Labels.** For a `.drumSynth` track, the pad grid reads `DrumLaneMap` instead of sampler zones. Pads 1–8 show the
  eight drums. The grid's zone provider (`PadGridModel.swift:297-298`) stays sampler-only, and **this model still
  never writes zones** (its own safety note at `:299-306`).
- **Notes.** In `pads` layout, pad *i* is note 36 + *i*, exactly today's geometry. In `gm` layout, pad *i* sends
  `DrumVoice.voice(forSlot: i)?.primaryNote(in: .gm)` (`voice(forSlot:)` is `DrumKit.swift:136-148`). That way the eight drums sit on pads 1–8 in either layout, and the
  user's spatial key mapping (Z X C V = pads 1–4, `ROADMAP.md:1222-1227`) still lands kick, snare, closed hat and
  open hat under the left hand.
- **Choke made visible.** Pads in the same choke group get a thin link glyph and the tooltip *"These cut each other
  off, like a real hi-hat."* It is drawn for drum-machine voices and for sampler zones alike.
- **Sliced kits.** The chop panel gets the "Sort the hits into a drum kit" toggle (Design C), and a sorted kit's
  pads show their roles.
- **RT.** None. The grid pushes notes through the existing `MusicalTypingController` → `LiveNoteSink`, the "one
  controller, one pusher" rule (`PadGridModel.swift:284-290`).

---

## 8. Design F: drum patterns

The templates design handed "notes, patterns and loops" to this wave (`2026-09-27-multi-instrument-templates.md:709`,
`:1335`). Today no verb writes a drum pattern (C26).

- **The library** (`Sources/DAWCore/DrumPatternLibrary.swift`, pure): a handful of named patterns written in **drum
  roles**, not note numbers (kick, snare, closedHat, openHat, clap, rim, tom, cymbal), each 1–2 bars on a 1/16 grid.
  Velocities are authored musically, ghost notes included. Only the accent constant
  (`NoteEntryDefaults.accentVelocity`) is shared; the patterns do **not** read the entry default. Proposed set:
  basic rock, four on the floor, boom bap, trap, half-time, breakbeat, one drop.
- **The verbs** (additive): `pattern.list` (names, novice descriptions, bars, roles used) and `clip.addDrumPattern
  {trackId, pattern, bars?, atBeat?}`. It makes one MIDI clip through the existing `addMIDIClip` funnel, so it is
  **one undo step**.
- **Roles become notes through the target's own map**, the one home: `DrumVoice.primaryNote(in: layout)` for the
  drum machine, `primaryNote(in: .gm)` for the GM kit, and for a sorted sampler kit the zone with that role on the
  role's first note.
  - A role the kit lacks (a sliced kit with no open hat) is **left out with a warning that names it**, never
    swapped for a different drum.
  - A non-drum track is refused with a sentence.
- **MCP**: `pattern_list`, `clip_add_drum_pattern`.
- **UI**: when a drum clip's step grid is empty, a **"Start from a beat"** menu lists the pattern names.
- **`DemoRender.Audition` is frozen, and not moved or re-expressed.** Every template measurement compares against it
  (`DemoRender.swift:263-266`). Changing it would move baselines the user has already listened to.

---
## 9. Build items

**Gate rules for every item** (from the gate laws; each was paid for by a cycle):
- "Audible" is never a gate.
- Every item has an **invariance control**: old projects decode and render byte-identically. A byte gate over
  renders cannot see a `Codable` decode default, so any new field also gets a JSON fixture that **omits** the key.
- Every item has a **physics assertion** with a pre-registered bar, and **at least one plant per gate**, reddened as
  predicted and then restored byte-identically.
- Any render meant for ears also checks **true peak**, not only loudness.
- Wire counts are checked with `node scripts/gates/doc-count-drift.mjs`, never with `grep -c registerTool(`.

### 9.1 Summary

| Id | What | Weight | Route | Depends on |
|---|---|---|---|---|
| `m39-w4-1` | **Measure** whether the GM kit chokes its hats (Apple DLS) | XS | `audio-dsp-engineer` | — |
| `m39-w4-2` | `DrumLaneMap` + kit-aware step-grid rows + editor-mode predicate | S | `swift-app-engineer` | — |
| `m39-w4-3` | `NoteEntryDefaults` (one home for entry velocity) + the Accent row | S | `swift-app-engineer` | w4-2 |
| `m39-w4-4` | The musical clock + `stepDivision` unlock (engine, DAWCore, wire) | M | `audio-dsp-engineer` | m39-c (done); **m39-d recorded before the unlock merges** |
| `m39-w4-5` | MCP leg for w4-4 (`mod_add_source` / `mod_set_source` schema + text) | S | `mcp-integration-engineer` | w4-4 |
| `m39-w4-6` | Kit-aware slicing core: `analyzeSliceTimbres`, `DrumHitClassifier`, `KitSliceLayout`, `SamplerZone.drumRole`, wire params | M | `audio-dsp-engineer` | w4-2 |
| `m39-w4-7` | MCP leg for w4-6 (`clip_slice_to_sampler` `mapping`/`roles`; `drumRole` in describe + zone patches) | S | `mcp-integration-engineer` | w4-6 |
| `m39-w4-8` | Pad grid plays the drum machine; role labels; choke link glyph; chop-panel "Sort into a kit" toggle | S | `swift-app-engineer` (+ `ui-design-engineer` look) | w4-2, w4-6 |
| `m39-w4-9` | GM kit synthetic hat choke (**only if w4-1 says it is needed and possible**) | S | `audio-dsp-engineer` | w4-1, w4-2 |
| `m39-w4-10` | Drum patterns: `DrumPatternLibrary`, `pattern.list`, `clip.addDrumPattern`, MCP tools, "Start from a beat" menu | M | `mcp-integration-engineer` (wire/MCP) then `swift-app-engineer` (menu) | w4-2, w4-3 |
| `m39-w4-11` | The **Sound row** in the step grid: the first modulation UI | L | `ui-design-engineer` + `swift-app-engineer` | w4-2, w4-4 |
| `m39-w4-12` | Docs: agent guides, CHANGELOG, plugin regen, ARCHITECTURE "Key future decisions" | XS | `docs-scribe` | each item as it lands |

**Order.** w4-1 ∥ w4-2 → w4-3 ∥ w4-6 ∥ w4-4 → w4-5 ∥ w4-7 ∥ w4-8 → w4-9 ∥ w4-10 → w4-11.
- **w4-2 first.** Every surface reads `DrumLaneMap`.
- **w4-4 runs in parallel** with the grid work, but its unlock waits for m39-d.
- **w4-11 last.** It is the largest UI piece and the first modulation UI; a person must look at it.

### 9.2 Per item

#### `m39-w4-1`: measure the GM kit's hat choke (XS, audio-dsp-engineer)
- **What:** an offline render harness on the Apple DLS Standard kit (bank MSB 120). (a) 46 at t = 0, 42 at
  t = 100 ms; (b) 46 alone with a 50 ms note versus a 2 s note. Record the numbers in the item and in
  `docs/research/`.
- **Method (the `DrumSynthTests.swift:670-697` isolation):** subtract the closed-hat-only render, then compare the
  130–200 ms RMS of what remains against a 46-alone control.
- **Positive control:** the **same harness** on our drum machine (known choke) must read ≤ −40 dB.
- **Negative control:** kick then open hat (no choke expected) must read within 0.5 dB of the control.
- **Gate:** the measurement is the deliverable. A harness that cannot fail its positive control is not a
  measurement.
- **Touches no product code.**

#### `m39-w4-2`: `DrumLaneMap` and kit-aware rows (S, swift-app-engineer)
- **Build:**
  - `Sources/DAWCore/DrumLaneMap.swift`.
  - `DrumVoice.primaryNote(in:)` in `DrumKit.swift`.
  - `StepSequencerLanes.lanes` reads the map (`StepSequencerModel.swift:124-145`).
  - The editor-mode predicate at `ContentView.swift:1934-1938` becomes "lane map is non-nil".
  - New staging key `drumLanes` at `StepSequencerStaging.swift:~194`.
  - `SMFProjectExporter.isDrumKit` is **untouched**.
- **Invariance gates:**
  - (I1) Lanes for a GM sound-bank track and for a melodic track are `==` to today's output, pinned against the
    current function on fixtures.
  - (I2) MIDI export channel assignment is unchanged for every fixture track (`isDrumKit` untouched).
  - (I3) The staging `isDrumKit` key is unchanged.
- **Physics gate (P1), "a row labelled X plays X":** for both layouts, render each lane's note alone through
  `DrumSynthInstrument` and require it to be byte-equal to a render of that lane's voice at its known note.
- **Unit gate (P2):** `voice(forNote: primaryNote(in: l), layout: l) == self` for all 8 voices in both layouts.
- **Plants:**
  - Swap two labels in the map: P1 goes red.
  - Feed the editor mode from `isDrumKit`: a fixture asserting a `pads` drum machine opens in Steps goes red.
  - Make `primaryNote(in: .gm)` return 35 for the kick: P2 stays green, P1 stays green, and the I1-style golden for
    the gm lane list goes red. This plant is there to prove the golden list is read.

#### `m39-w4-3`: entry velocity in one home, and the Accent row (S, swift-app-engineer)
- **Build:**
  - `NoteEntryDefaults` in DAWCore (§3.4), with `drumVelocity = 100` until the user's L1 pick.
  - `PianoRollModel.swift:495-497` and `StepSequencerModel.swift:629/723-725` read it.
  - The Accent row (§3.5).
- **Invariance gates:**
  - (I1) With `drumVelocity = 100`, a note toggled on in either editor on any track is born at 100, exactly as today.
  - (I2) Opening and rendering a saved drum clip with no edits is byte-identical. Velocities live on the notes, so
    this gate is almost free; state it anyway.
- **Physics gates:**
  - (P1) With a fixture constant of 80: a step toggled on a drum-lane track has velocity 80, and on a melodic track
    100.
  - (P2) On the drum machine with a constant of 80: a normal hit's peak matches the §5 velocity formula with no
    accent term, and an accented hit matches it with the term, each within 0.1 dB
    (`docs/design/2026-09-20-drum-machine.md:700-718`).
- **Plants:**
  - Choose the drum default through `isDrumKit`: a `pads` drum machine gets 100, so P1 goes red.
  - Make the accent row read against `kit.accentThreshold`: under the "100" fixture every column lights, which a
    test asserting "no column lit" turns red.
  - Leave `PianoRollModel` on its literal: a test that both editors read the one function turns red.

#### `m39-w4-4`: the musical clock and the `stepDivision` unlock (M, audio-dsp-engineer)
- **Build (§4.2):**
  - `ClockSegment` array in `ModulationSnapshot`, built in `ModulationSnapshotBuilder`.
  - Clock inputs threaded from the roll context (`PlaybackGraph.swift:4174-4177` for live, `:2472` for offline).
  - `ModulationPublishKey.clock`.
  - Evaluator branch for synced step sources (`+0.5`, `+h`).
  - `TempoSync` sibling table.
  - Remove `refuseSync("stepDivision")`, plus the inert-`rateHz` setter warning.
- **RT review is required** (daw-architect) before merge.
- **Invariance gates:**
  - (G1) Byte gate, before versus after: free-running step source, LFO, envelope follower, macro, and no
    modulation. One fixture has a tempo change and a loop, so a free-running source that accidentally followed the
    clock shows.
  - (G7) Zero allocations in the render callback with four synced sources, using the counter harness the W8-RTFIX
    review used (`DrumNoteLayoutRenderTests`).
- **Physics gates:**
  - (G2) **Edges on the map.** A synced 1/16 source with steps alternating 1/0 is routed to volume on a steady tone;
    the tempo goes 120 → 90 at bar 3, the meter becomes 3/4 at bar 5. Every gain edge must sit within ±1 frame of
    `round(seconds(from: fromBeat, to: B_k) · rate)`. Positive control: the same edge finder on an automation hold
    lane reads within ±1 frame.
  - (G3) **Loop-exact.** Loop from beat 1.5 to bar 4, three cycles. Cycles 2 and 3 must be bit-equal to cycle 1.
  - (G4) **Seek-exact.** A render from bar 6 must be bit-equal to bar 6 of a full render.
  - (G5) **Latch.** `openHat.decay` is driven by a synced source with alternating short/long steps, with an open hat
    on every sixteenth, at 90, 120 and 174 BPM and across a loop wrap. **Every** hit's measured −20 dB decay matches
    its authored step within 5 %.
  - (G6) **Stopped edit.** While stopped, change the tempo at a bar after the playhead, then press play. The first
    edge after the change obeys G2.
  - (G8) **Live versus offline**, for an effect-param target: reuse m39-d's harness. This is the merge gate for the
    unlock.
- **Plants:**
  - (B1) Single-tempo resolve with no clock: G2 red after bar 3.
  - (B2) Clock left out of the publish key: G6 red.
  - (B3) No `+0.5`: G5 red on roughly half the edges.
  - (B4) Centred edge for synced sources: G5 red.
  - (B5) A cursor carried across blocks: G4 red.
  - (B6) The clock applied to free-running sources: G1 red.

#### `m39-w4-5`: MCP leg for the clock (S, mcp-integration-engineer)
- **Build:**
  - Strict nested `stepDivision` enum on `mod_add_source` / `mod_set_source` (`server.ts:14881`, `:14932`).
  - Novice-readable description.
  - `mod_describe` text for `stepsPerBar` and the restart rule.
- **Gates:**
  - (I) Existing schema tests unchanged.
  - (P) Each of the 18 `NoteDivision` raw values round-trips through the schema against the wire's own list. That
    list is derived from `NoteDivision.allCases` in a test, never copied into the test.
- **Plant:** drop one division from the zod enum: the parity test goes red.

#### `m39-w4-6`: kit-aware slicing core (M, audio-dsp-engineer)
- **Build (§5):**
  - `analyzeSliceTimbres` on the engine protocol, with a no-op default for test engines like the existing
    `detectTransients` stub at `EngineProtocol.swift:2118`.
  - `DrumHitClassifier` and `KitSliceLayout` in DAWCore.
  - `SamplerZone.drumRole`.
  - Wire `mapping` / `roles` on `clip.sliceToSampler`.
  - `drumRole` in `instrument.describeSampler` and `sampler.zonePatches`.
  - The sampler branch of `DrumLaneMap`.
- **Invariance gates:**
  - (C1) `mapping` absent: the plan JSON for three fixture clips is byte-equal to goldens captured **before** the
    change, the zones carry no `drumRole` and no `chokeGroup`, and the render is byte-identical.
  - (C7) A JSON fixture that **omits** `drumRole` decodes to nil and re-saves byte-identically. A kit-sliced
    project round-trips `drumRole` and `chokeGroup`.
- **Physics gates:**
  - (C2) Kit mode's reconstruction render versus chromatic mode's, on a fixture loop: expected **bit-identical**.
    Every zone's root equals its key, so nothing is transposed. Each slice ends at the next onset, so a choke never
    cuts a slice that is still sounding [I]. If a single frame differs, the gate prints the first differing frame,
    and the implementer explains it **by mechanism** before any tolerance is admitted.
  - (C3) **Synthetic corpus, truth known.** Five one-shots with known boundaries: 60 Hz sine with a 150 ms decay plus
    a 2 ms click; 200 Hz sine plus noise over 120 ms; 8 kHz high-passed noise over 40 ms; the same over 400 ms;
    1 kHz sine over 300 ms. They must land on 36, 38, 42, 46 and 84 respectively, 5 of 5.
  - (C4) **Our drum machine as ground truth.** Kick, snare, closed hat and open hat of all five presets.
    Pre-registered bar: kick 5/5, snare 5/5, closed hat ≥ 4/5, open hat ≥ 4/5. The **full confusion matrix** goes in
    the report, including clap, tom, rim and cymbal. Those may land on their nearest role or on "other", **never**
    on kick for a cymbal. GM-kit renders are reported only.
  - (C5) **"Other" is never folded:** the 1 kHz tone is on 84 with role "other".
  - (C6) **Choke on a sorted kit:** 46 then 42 at +100 ms (played notes, not the reconstruction). With the
    subtraction isolation, the open-hat tail is ≤ −40 dB 30 ms after the closed hat.
- **Plants:**
  - Swap the kick/hat band comparison: C3 and C4 red.
  - Fold "other" into closed hat: C5 red.
  - Make kit mode the default: C1 red.
  - Round-robin collisions instead of distinct notes: C2 red.
  - Drop `drumRole` from the encoder: C7 red.

#### `m39-w4-7`: MCP leg for slicing (S, mcp-integration-engineer)
- **Build:**
  - `mapping` (enum) and `roles` (record of index → role enum) on `clip_slice_to_sampler` (`server.ts:8668`).
  - `drumRole` on the zone schemas (`:1605` block) and in `instrument_set_sampler_zones` patches (`:5182`).
- **Gates:**
  - (I) The schemas still accept every existing call, against the existing fixtures.
  - (P) A `roles` value outside the enum is refused by zod **and** by the wire with the same sentence (the parity
    pattern).
- **Plant:** loosen the enum to a string: the parity test goes red.

#### `m39-w4-8`: pad grid plays the drum machine (S, swift-app-engineer, ui-design-engineer look)
- **Build (§7):**
  - Lane-map-driven pad labels and notes for `.drumSynth`.
  - Choke link glyph.
  - Role labels for sorted kits.
  - The chop-panel toggle.
- **Invariance gate (I):** the sampler pad grid's existing tests stay green, unchanged.
- **Physics gates, with a spy on `LiveNoteSink`:**
  - (P1) Pad 2 on a `gm` drum machine pushes note 38 (snare), and on `pads` note 37 (snare).
  - (P2) The hats' glyph shows on exactly the pads whose resolved choke group matches.
- **Plants:**
  - Identity mapping (pad *i* → 36 + *i*) in `gm`: P1 red.
  - Glyph keyed on voice name instead of group: a fixture with the hats' choke cleared goes red.
- **A person looks at it** (the design language: glass, neon, beginner labels). A UI phase is not done until someone
  has looked at it.

#### `m39-w4-9`: GM kit synthetic hat choke (S, audio-dsp-engineer; only if w4-1 says so)
- **Build (§6):**
  - `hatChoke: Bool?` on the sound-bank descriptor, `true` for new GM drum tracks.
  - The control-plane note-off in `MIDIEventSchedule.buildEvents` and in the `LiveNoteSink` push.
- **Invariance gate (I):** saved GM projects (flag absent) render byte-identically. A JSON fixture omits the key.
- **Physics gates:**
  - (P1) On a new GM kit track, 46 then 42 at +100 ms: the open-hat tail is ≤ −40 dB within the release time w4-1
    measured.
  - (P2) The same with 44 (pedal hat) as the choker.
- **Plants:**
  - Ignore the flag: P1 red.
  - Choke only on 42: P2 red.

#### `m39-w4-10`: drum patterns (M, mcp-integration-engineer then swift-app-engineer)
- **Build (§8):**
  - `DrumPatternLibrary`, `pattern.list` and `clip.addDrumPattern`.
  - `pattern_list` and `clip_add_drum_pattern`.
  - The "Start from a beat" menu.
- **Invariance gates:**
  - (I1) The wire count rises by exactly 2 and MCP by 2 (`doc-count-drift.mjs`).
  - (I2) The template audition measurements are unchanged, because `Audition` is frozen.
- **Physics gates:**
  - (P1) **Layout independence:** the same pattern on a `pads` drum machine and a `gm` drum machine renders
    **byte-identically**. Every role resolves to the same voice.
  - (P2) "four on the floor" on the drum machine: kick onsets, found on the kick-isolated render, sit on every beat
    within 1 frame.
  - (P3) On a sorted kit with no open hat: no note is written on 46, and the reply names "open hat".
- **Plants:**
  - Resolve roles through a fixed GM table instead of the lane map: P1 red.
  - Substitute the closed hat for a missing open hat: P3 red.

#### `m39-w4-11`: the Sound row (L, ui-design-engineer + swift-app-engineer)
- **Build:**
  - Under a chosen drum row, a strip of step bars bound to one parameter, picked from a short beginner list per
    voice: Length, Pitch, Tone, Level.
  - Drawing a bar creates or edits a **synced** step source plus one route, through the existing `ProjectStore`
    modulation functions. **No new wire verb:** the store functions the wire already calls are the one surface.
  - Step count follows the clip's meter.
- **Invariance gates:**
  - (I1) Opening the grid, or showing the row, creates no modulation source (opening an editor must not mutate).
  - (I2) A track whose sources were made by an agent shows them without rewriting them.
- **Physics gate (P):** raise step 5 on Open Hat · Length, then render. Hit 5's decay is longer by the step's depth,
  and hits 4 and 6 are unchanged (G5's method).
- **Plant:** create the source unsynced, with its Hz rate set for 60 BPM, and run P at 120 BPM: hit 5 reads the
  wrong step, so P goes red.
- **A person looks at it.**

#### `m39-w4-12`: docs (XS, docs-scribe)
- **Agent guides:**
  - `claude-plugin/agents/composer.md` and `sound-designer.md`: read the drum rows (`instrument_describe_drum_kit`
    `voiceNotes`) before writing drum notes; accent = 127 via the accent row's constant (the documented "110 on
    accents" in `server.ts:2516-2517` still accents at threshold 100); `stepDivision`; `mapping: "kit"`; patterns.
  - The sound designer's **hand-maintained allowlist** gains the new tools. Regenerating alone does not reach agents
    (the 2026-09-21 release lesson).
- **Everything else:** CHANGELOG, plugin bundle regen, the ARCHITECTURE "Key future decisions" entry (§13).
- **Gate:** `doc-count-drift.mjs` exit 0. A grep of the guides for each new tool name, with a positive control on an
  existing name.
- **`/plugin update` is always the user's action.**

---
## 10. Questions for the user and defaults we decide ourselves

The user's standing rules apply:
- Ship 3–4 options that differ on **one** axis, and treat their pick as the feedback.
- They describe; they do not diagnose.
- Measurable defaults are delegated (2026-09-25).
- Never ship a sound demo without checking it can be heard.

### 10.1 For the handoff page (a decision, not a listening test)

**H1: Which notes should a NEW drum machine answer to?** Explicitly handed to this wave
(`2026-09-27-multi-instrument-templates.md:404-406`, `:1381`; its author recommended `gm`). It is not a listening
question: all three options sound the same until a beat written for another kit is played.
- **(a) Pad order, 36–43** (today). Pads 1–8 are the eight drums in order.
- **(b) General MIDI.** A beat written for the Mac's GM drum kit, a MIDI file, or a template plays the right drums.
- **(c) General MIDI, with the pad grid still showing the eight drums on pads 1–8** (needs `m39-w4-8`; the grid
  translates pad to drum).
- **What (a) costs, read from the two maps** (`DrumKit.swift:195-216`) [I]. A General MIDI beat (kick 36, snare 38,
  closed hat 42, open hat 46, crash 49, the notes `DemoRender.swift:336-352` uses) played on (a):
  - the kick is right;
  - **the snare plays as a closed hat;**
  - **the closed hats play as a rim;**
  - **the open hat and the crash are silent.**
  On (b) and (c) all five are right.
- **Recommendation: (c).**
- **Saved projects are unaffected by any answer.** A `pads` kit stores no layout key and a `gm` kit stores
  `"gm"` (`DrumKit.swift:1140-1143`).

**H2 (for information, not a question): the GM kit's hats will cut each other on new tracks**, if `m39-w4-1` shows
they do not already. Saved projects are unchanged. It is listed so the user is not surprised; it is a delegated
default (below).

**Already open, do not re-ask:** `hats-level` (the `dm-hat-gain` lane, W8-HAT; handoff page v67).

### 10.2 For the listening page

**L1: How much quieter is a normal drum hit than an accented one?** One axis: the velocity a hand-entered drum hit
gets.
- **Options:** **100** (today), **90**, **80**, **70**. Accented hits are always 127.
- **Material:** the same two-bar beat on the drum machine (808), with accents on beats 1 and 3, rendered four times.
- **Page note:** "100" is today's state. On the drum machine every hit is then already accented, so the only
  contrast is velocity.
- **Scale of the axis** [I, from the formula in `docs/design/2026-09-20-drum-machine.md:700-703`]: from velocity
  scaling alone, the snare (sensitivity 0.85) sits about 1.7 / 2.5 / 3.3 / 4.2 dB under a 127 hit. Below 100, the
  accent bus adds its `accentDepth` on top.
- **Audibility (the user's rule):**
  - Loudness-match the four renders, so the pick is about contrast and not level.
  - Print the **measured** accent-versus-normal difference for each option on the page.
  - Check true peak ≤ −1 dBTP.
  - Refuse to publish if two adjacent options differ by less than 1 dB of contrast.
- **The pick sets `NoteEntryDefaults.drumVelocity`.** Saved notes keep their velocities.

**L2: The first beat "Start from a beat" puts in.** One axis: how busy the hi-hats are, over the same basic backbeat
(kick on 1 and 3, snare on 2 and 4).
- **Options:** quarter notes / eighths / sixteenths / sixteenths with an open-hat lift on the last off-beat.
- **Material:** the drum machine (808).
- **Same audibility checks as L1.**
- **The pick sets which pattern the menu offers first.** The library's other patterns are conventional definitions
  (delegated).

### 10.3 Delegated: measurable defaults we decide, with what decides each

| Default | Value | Decided by |
|---|---|---|
| Drum rows of each instrument | derived from the instrument's own note map | `m39-w4-2` P1: a row labelled X plays X |
| Accent velocity | 127 | the MIDI maximum: at or above any possible threshold |
| Accent threshold of the drum machine | **unchanged (100)** | §3.4: changing it moves presets, `matchingPreset` and three templates |
| Sorted-kit note numbers | General MIDI, strongest hit first, extras from 84 | §5.4; gates C1–C5 |
| Sorted-kit hats | choke group 0, closed and open | the drum machine's own hat default (`DrumKit.swift:564`, `:569`) |
| Sorted-kit roles | kick / snare / closed hat / open hat / other | Ableton's own scope (sources); gate C4 |
| Classifier thresholds | fitted once on the C3 and C4 corpora, then frozen | gates C3/C4 |
| Synced step edges | trailing, with half-sample alignment | gate G5 |
| Where a synced pattern restarts | song start and every time-signature change | §4.2; gate G2 |
| GM kit hat choke on new tracks | on, if `m39-w4-1` shows it is needed | physical fact; gate `m39-w4-9` P1 |
| Pattern definitions (other than L2's) | conventional placements | `m39-w4-10` P2 |
| Sound-row parameter names | Length / Pitch / Tone / Level per voice | design language; a person looks at it |

---

## 11. What we will not build, and why

1. **A modulation source that triggers drum hits.** It would be a second home for notes, a new event path on the
   render thread, and a break in the "value at a position" contract (§2, alternative 1).
2. **Per-note parameter overrides ("parameter locks" stored on each note).** They are exact and move with their
   note, but they are not the modulation layer, they add a field to the most widely used type in the tree, and only
   the drum machine would honour them. Revisit only if early hits drifting into the previous step (§4.3) turns out
   to matter to people.
3. **Choke groups across tracks.** A choke is decided at note-on inside one instrument's render. Across tracks it
   would need shared state between two instrument nodes on the render thread, with no defined order between nodes
   in a quantum. Keeping a kit on one track (the drum machine, a sorted kit) covers the case.
4. **Choke as an automatable or modulatable parameter.** It is structural and discrete (`drum-machine.md` §4).
5. **Looping a MIDI clip without copying its notes.** That would make a second, virtual note truth that every
   consumer of `[MIDINote]` must learn or silently ignore. `clip.repeatNotes` and the pattern verb write concrete
   notes.
6. **Recognising toms, claps, rims and cymbals when slicing** (v1). Those are the classes classifiers confuse.
   "Other", plus a relabel, is honest.
7. **Round-robin or velocity layers for repeated slices** (§5.4).
8. **Changing `DemoRender.Audition`** (§8).
9. **Adding side stick (37) and hand clap (39) to the GM kit's step rows** in this wave. That table is shared with
   instrument-family resolution, which excludes them on purpose (`InstrumentFamilyResolution.swift:279-285`). A
   lane-only list derived from `DrumNoteLayout.generalMIDIPercussionNotes` is a follow-up candidate.
10. **Unlocking the synced LFO.** The clock makes it possible. It belongs with the effects and modulation work, and
    the m39-c row says not yet.
11. **The drum machine's editor card** (C23). It is a real gap for beginners, but it is instrument editing, not
    loop/drum workflow. File it on its own (`m39-dm-card`) rather than hiding it inside this wave.
12. **A bundled library of sampled loops.** The repo has no drum content, and licensing would follow it. The drum
    machine plus patterns makes loops.
13. **Per-step probability, ratchets, conditional trigs.** Hardware depth; later, if asked.
14. **Changing the drum machine's accent threshold or accent depth defaults** (§3.4).
15. **Widening `SMFProjectExporter.isDrumKit`** (§3.3).

---

## 12. Failure modes, collected

| Failure | Shape | Caught by |
|---|---|---|
| A new drum machine opens in a piano roll whose rows play nothing | the C14 gap | `m39-w4-2` P1 + mode fixture |
| Every hand-entered hit is already accented | the C15 gap | `m39-w4-3` P2 + L1 |
| Accent row lit everywhere | reading against the kit threshold | `m39-w4-3` plant |
| GM export breaks for a `pads` kit | widening `isDrumKit` | `m39-w4-2` I2 |
| Synced steps drift after a tempo change | single-tempo rate | G2 / plant B1 |
| Old clock survives a stopped edit | publish key without the clock | G6 / plant B2 |
| A hit on the grid latches the previous step or the average of two | rounding mismatch, centred edge | G5 / plants B3, B4 |
| Seek or loop plays different steps | state carried across blocks | G3, G4 / plant B5 |
| Free-running sources start following the clock | clock applied to all | G1 / plant B6 |
| Monitoring and bounce differ for a synced effect gate | block-rate effect params | G8, merge-gated on m39-d |
| A slice lands on the wrong drum | classifier | C3, C4; relabel via `zonePatches` |
| An unrecognised hit pretends to be a hat | folding | C5 |
| Reconstruction no longer replays the loop | collisions / choke | C2 |
| Sorted kit loses its labels on reopen | role not stored | C7 |
| A pattern plays the wrong drums on a `pads` kit | fixed GM table | `m39-w4-10` P1 |
| A missing drum is silently swapped | substitution | `m39-w4-10` P3 |
| The GM kit's open hat rings under closed hats | unmeasured DLS | `m39-w4-1`, `m39-w4-9` |
| Template sounds move | changing presets or Audition | §3.4, §8; `m39-w4-10` I2 |
| A shipped tool never reaches agents | allowlist not updated | `m39-w4-12` |

---

## 13. Owed outside this document; not verified

### 13.1 Owed (this lane may write only this file)

- **`docs/ARCHITECTURE.md` "Key future decisions"** (`:416`). Proposed entry:
  *"Musical clock for tempo-synced modulation (2026-10-07, wave 4 design). Synced modulation sources read a
  per-snapshot clock: segments of (exact start sample, start beat, beats per sample, pattern origin), compiled on the
  main actor from the roll context, with the MIDI schedule's rounding. The render thread never consults the tempo
  map. A drum step sequencer is the step grid (notes in MIDI clips, one home) plus a synced step source for per-step
  sound. It is not a note-emitting modulation source."*
- **The TempoSync header law** (`TempoSync.swift:28-31`): add "…it may read a precomputed clock".
- **ROADMAP rows** `m39-w4-1` … `m39-w4-12` under M39 wave 4, carrying the order in §9.1.
- **CHANGELOG** lines per item as they land (`m39-w4-12`).

### 13.2 Not verified (each needs its gate before anyone leans on it)

- Everything about Apple's DLS kit and chokes: **unmeasured** (`m39-w4-1` exists for this).
- Classifier accuracy on real loops. Gate C4 covers our own kit only.
- C2's bit-identity of the sorted-kit reconstruction, given the choke [I].
- That `restart(.continuation)` reaches `publishModulation`. I read that it moves the anchor; I did not trace the
  call.
- The per-sample cost of the clock's binary search. Measure it against the render budget in `m39-w4-4`.
- How many loop cycles the automation and MIDI builders unroll, and what extends them. The clock must follow the same
  trigger.
- The six "carry the existing velocity" note-construction sites in §3.4, read by shape only.
- Whether the step grid's columns and a synced source agree after a mid-song meter change. `StepSequencerGeometry`
  aligns columns to the song's grid (`StepSequencerModel.swift:185-260`); `m39-w4-11` must assert they agree.

### 13.3 Sources (external)

- Ableton Live manual, "Converting Audio to MIDI": *"The command also attempts to identify kick, snare and hihat
  sounds…"* (fetched 2026-10-07): https://www.ableton.com/en/manual/converting-audio-to-midi/
- Search-result summaries (not verified by fetch) describing the hi-hat lane as a catch-all:
  https://modeaudio.com/magazine/instant-live-drum-feel-in-ableton · https://www.soundonsound.com/node/4903896
