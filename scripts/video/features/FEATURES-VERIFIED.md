# DAW Pro — VERIFIED feature list for the demo film intro

Repo: `/Users/dsemenov/Views/daw-pro`, branch `m23-wip-2026-08-10`, HEAD `102f00b`.
Scope of "new": `ec69328`, `a338854`, `102f00b` only. Base for comparison: `7d8a2a4`.

Everything below was checked at source or by running a gate. Commit prose and docs were
treated as claims, not facts — and **two commit-message claims turned out to be wrong**
(see "Commit prose that is false" at the end). Method is stated for every count so the
number can be re-derived rather than trusted.

---

## 0. Plain-English glossary (use these the first time the film says the word)

- **Insert effect** — a box you drop into a track's signal path. Sound goes in one side,
  a changed version comes out the other. Every track can hold a stack of them.
- **Mixer strip / channel strip** — the vertical column of controls for one track:
  volume slider, pan, mute, and the stack of insert effects.
- **LFO** (low-frequency oscillator) — an invisible knob-turner. It moves a control up
  and down over and over again, slowly, on its own. It makes no sound itself.
- **Envelope follower** — a listener. It watches how loud one signal is, moment to
  moment, and hands that loudness out as a number other things can be wired to.
- **Sidechain** — wiring one track's loudness into another track's effect, so track B
  reacts to track A. The classic use: the bass ducks every time the kick drum hits.
- **Transient** — the first few milliseconds of a sound. The *thwack* of a snare before
  the ring; the *pick* of a guitar before the note.
- **Comb filter / notch** — when a sound is added to a slightly delayed copy of itself,
  certain pitches cancel out. Those cancelled pitches are "notches". A regular ladder of
  many notches sounds like a flanger; a handful of irregular ones sounds like a phaser.
- **MIDI note number** — an integer naming a pitch. 60 is middle C. 36 is C1, three
  octaves lower — by convention the bottom-left pad on every drum pad controller.
- **Pad grid** — a 4x4 square of buttons. Each square plays one sound. Descended from the
  Akai MPC; the way beats have been finger-drummed since about 1988.

---

## 1. The insert-effect kinds — CENSUS, not a quoted number

### Headline

**22 built-in insert kinds.** 23 enum cases total, but one (`audioUnit`) is not a
built-in — it is the slot that hosts a third-party plugin.

**11 of the 22 are new in these three commits.** That is exactly half.

### Method (so the number can be re-derived)

Two independent lists were parsed programmatically and compared as sets:

1. `EffectDescriptor.Kind` — `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/Effects.swift:8`
   (`public enum Kind: String, Codable, Sendable, CaseIterable`). Cases extracted by
   brace-depth scan, not by eye.
2. `addableEffectKinds` — `/Users/dsemenov/Views/daw-pro/Sources/DAWApp/Mixer/MixerStripView.swift:11`,
   the hand-maintained array literal that builds the mixer's "+" menu.

Result:

```
enum total      : 23
enum built-in   : 22   (all cases except .audioUnit)
addable         : 22
SET EQUAL?      : True
ORDER EQUAL?    : True
in enum not addable : []
in addable not enum : []
NEGATIVE CONTROL (compare against the list minus one element): False
```

The negative control matters: it proves the comparison can return False, so `True` is a
measurement and not a broken probe.

Two gates in the repo were then run as independent artifact-level confirmation:

```
$ node scripts/gates/effect-kind-surface.mjs
effect-kind-surface: OK — 22 kinds x 5 surfaces, sentinels saturator/bitCrusher found in all.   (exit 0)

$ node scripts/gates/plugin-bundle-parity.mjs
  released bundle : 42 anchored tools, 22 effect kinds
  current source  : 42 anchored tools, 22 effect kinds
  OK — every effect kind the released prose names is addable by the released bundle.            (exit 0)
```

Three independent derivations agree on 22.

### ⚠️ The headline finding the brief asked about: THE TWO LISTS AGREE

The brief warned that a kind missing from the hand-maintained `addableEffectKinds` array
would be engine-supported but invisible in the UI. **That is not the case today.** All 22
built-in kinds are in the array, in the same order as the enum. **Every built-in insert
effect in DAW Pro is reachable from the mixer's "+" menu.** No kind is engine-only.

This is worth saying out loud in the film's fact-checking sense: the risk was real (the
array is hand-maintained and the compiler cannot catch an omission — the source comment at
`MixerStripView.swift:7-10` says so explicitly), and it did not happen.

### The full list, per kind

| # | Kind | Status | In UI "+" menu | Has editor card |
|---|---|---|---|---|
| 1 | `gain` | pre-existing | yes | yes |
| 2 | `eq` | pre-existing | yes | yes |
| 3 | `compressor` | pre-existing (**gained the de-esser mode in `102f00b`**) | yes | yes |
| 4 | `limiter` | pre-existing | yes | yes |
| 5 | `reverb` | pre-existing | yes | yes |
| 6 | `delay` | pre-existing (**feedback ceiling raised to 0.999 = echo freeze, `ec69328`**) | yes | yes |
| 7 | `saturator` | pre-existing (gained optional 2x/4x oversampling in **`102f00b`**, off by default) | yes | yes |
| 8 | `gate` | pre-existing | yes | yes |
| 9 | `chorus` | pre-existing | yes | yes |
| 10 | `bassEnhancer` | pre-existing | yes | yes |
| 11 | `bitCrusher` | pre-existing | yes | yes |
| 12 | `djFilter` | **NEW — ec69328** | yes | yes |
| 13 | `ringMod` | **NEW — ec69328** | yes | yes |
| 14 | `flanger` | **NEW — ec69328** | yes | yes |
| 15 | `hallReverb` | **NEW — ec69328** | yes | yes |
| 16 | `tapeDelay` | **NEW — ec69328** | yes | yes |
| 17 | `stereoWidth` | **NEW — ec69328** | yes | yes |
| 18 | `phaser` | **NEW — a338854** | yes | yes |
| 19 | `transientShaper` | **NEW — 102f00b** | yes | yes |
| 20 | `freqShifter` | **NEW — 102f00b** | yes | yes |
| 21 | `clipper` | **NEW — 102f00b** | yes | yes |
| 22 | `dynamicEQ` | **NEW — 102f00b** (largest kind: 4 bands x 8 params = 32 controls) | yes | yes |
| — | `audioUnit` | pre-existing; NOT a built-in — hosts third-party plugins | separate "Audio Units…" menu item | no (opens the plugin's own window) |

Per-commit counts, derived by parsing `Effects.swift` at each commit:

| Commit | Built-in kinds after | `addableEffectKinds` after |
|---|---|---|
| `7d8a2a4` (base) | 11 | 11 |
| `ec69328` | 17 | 17 |
| `a338854` | 18 | 18 |
| `102f00b` (HEAD) | 22 | 22 |

The two lists have never disagreed across these commits.

### "Editor card" — what that column means, verified

`EffectEditorModel.groupTable(for:)`
(`/Users/dsemenov/Views/daw-pro/Sources/DAWAppKit/EffectEditorModel.swift:151-452`) is a
`switch` over `EffectDescriptor.Kind` with **an explicit case for all 23 kinds and no
`default:` branch** (the `default:` cases in that file are at lines 650, 707, 736 and 949,
all in later, unrelated functions). So every one of the 22 built-ins has a named,
grouped set of on-screen controls. Adding one opens the card automatically
(`MixerStripView.swift:816`: *"m17-a: the host's add funnel — store add + editor
auto-open."*).

The card itself is `/Users/dsemenov/Views/daw-pro/Sources/DAWApp/Mixer/EffectEditorOverlay.swift:26`
— an in-window dark-glass modal over a dimmed scrim, not a floating window.

### ⚠️ Filming constraint: the mixer must be in PRO density

The inserts section (and therefore the "+" menu, and therefore every effect editor card)
**does not render in Simple mode.** `MixerStripView.swift:60-62`:

> `/// Pro density reveals the signal-flow sections (inserts / sends / output).`
> `private var isPro: Bool { densityStore.density(forPanel: MixerView.panelID) == .pro }`

`EffectEditorOverlay.swift:21-22` restates it: *"Pro-only by construction (reached only
from the Pro inserts section, which Simple never renders)."*

If the film shows the mixer in Simple mode, there are no effects on screen at all.

### Two things that are NOT kinds but ARE new capability — do not miscount them

- **Echo freeze on `delay`** (`ec69328`, m39-k). ⚠️ I initially mis-stated this and
  corrected it at source: it is **not a new parameter**. It is the existing `feedback`
  parameter's ceiling raised from 0.95 to **0.999** —
  `Sources/DAWCore/Effects.swift:1047` (`feedbackRange = 0...0.999`), documented at
  lines 1021-1045. At 0.999 the echo loses 0.0087 dB per repeat, so a 350 ms tail is
  only 3.19 dB down after 110 seconds: a freeze by any musical measure. The ceiling
  stops short of 1.0 on a measurement (at exactly 1.0 a DC input accumulates without
  bound — measured 9.66 / 96.97 / 193.94 / 290.94 after 1/10/20/30 s). A new *range*, not
  a 23rd kind, and nothing new appears on the delay's editor card.
- **A separate `freeze` parameter exists on `hallReverb`**, and it is a different thing —
  `HallReverbParams.freeze`, `Sources/DAWCore/Effects.swift:1974`, range `0...1` at line
  1989, where ">= 0.5 = infinite hold". Do not confuse the two on camera: the delay freeze
  is a feedback setting, the hall freeze is its own control.
- **The de-esser is a MODE on `compressor`, not its own kind — and it is NEW in `102f00b`.**
  Attribution measured with `git log -S deEss -- Sources/DAWCore/Effects.swift`, which
  returns `102f00b` and nothing else. A de-esser is a compressor that only listens to the
  harsh "sss" band of a voice (roughly 5-9 kHz) and turns it down when it gets too sharp.
  Source at `Sources/DAWCore/Effects.swift:4230-4232`: *"⭐ THIS IS THE DE-ESSER. There is
  no separate 'deEsser' effect kind — a de-esser IS a compressor that only listens…"*.
  If the film says "22 effects" and a viewer counts a de-esser as a 23rd, this is why —
  but the capability itself is genuinely new and can be claimed.
- **Optional 2x/4x oversampling on `saturator`** — ⚠️ **NEW in `102f00b`, not `ec69328`**
  (measured with `git log -S "public var oversampling"`, which returns `102f00b` alone;
  the string is absent from `7d8a2a4`). It **defaults to 1 (off)** because the kind shipped
  without it (`Effects.swift:22-26`), so existing projects sound bit-identical. Do not
  claim the saturator got cleaner by default — it did not, unless you turn it on.

---

## 2. The drum machine — every claim independently checked

The brief supplied six facts to confirm or refute. **All six are correct.** Details and
citations:

### 8 voices — CONFIRMED

`/Users/dsemenov/Views/daw-pro/Sources/DAWCore/DrumKit.swift:42-43`:

```swift
public enum DrumVoice: String, Sendable, Equatable, Codable, CaseIterable {
    case kick, snare, closedHat, openHat, clap, tom, rim, cymbal
```

Display names (line 62-73): Kick, Snare, Closed Hat, Open Hat, Clap, Tom, Rim, Cymbal.
Each voice is monophonic and one-shot.

### 75 parameters — CONFIRMED, and the arithmetic checks out

Source header at `DrumKit.swift:432` reads `// MARK: - The spec table: 75 names`, and the
table is built programmatically at `DrumKit.swift:500` (`cachedParamSpecs`).

The per-scope split is pinned by test at
`/Users/dsemenov/Views/daw-pro/Tests/DAWCoreTests/DrumKitTests.swift:23-37`:

```
kick 10 · snare 10 · closedHat 8 · openHat 8 · clap 9 · tom 9 · rim 8 · cymbal 9 · kit 4
```

10+10+8+8+9+9+8+9+4 = **75**. The test asserts both `paramSpecs.count == 75` and that the
per-scope split sums to 75, so the two halves cannot drift apart silently.

Parameters are addressed by a dotted name, e.g. `kick.decay`, `snare.snap`, `kit.gain`
(spelling rule at `DrumKit.swift:436-438`).

⚠️ One nuance worth knowing if the film shows a parameter being changed mid-pattern:
**only `level` and `pan` move a sound that is already ringing.** Every other parameter
takes effect at the *next* hit (`appliesAtNextNoteOn`, `DrumKit.swift:457`). This is
correct behaviour for a one-shot percussion voice, but on camera it means a knob twist
looks like it did nothing until the next beat.

### 5 kits — CONFIRMED, names exact

`DrumKit.swift:815-841`, `static let presets`, in menu order:

| Kit | The one-line summary shipped in the app |
|---|---|
| `808` | "The long boom. Deep sub kick with a slow fall, loose hats, a snare that sits back. The defaults." |
| `909` | "The hard click. Faster and deeper pitch sweep on the kick, a much shorter body, a brighter snappier snare." |
| `acoustic` | "Longer, less saturated and less synthetic: no drive, inharmonic snare modes, a wider kit image." |
| `lofi` | "Dull and driven. Everything darker, the kick saturated, the hats short and closed down." |
| `trap` | "A very long sub kick, a tight clap-forward snare and fast bright hats built for rolls." |

Note the spelling is `lofi`, one word, no hyphen — the commit message writes it "lo-fi".
Use `lofi` if the film shows the literal name on screen.

`808` is built from `DrumKitParams()`, the plain defaults. So **selecting the Drum Machine
gives you an 808 kit immediately, with no setup** — nothing to load, nothing to download.
Every sound is synthesised from numbers, not played back from sample files.

### Four control verbs — CONFIRMED

`/Users/dsemenov/Views/daw-pro/Sources/DAWControl/Commands.swift:340-343`:

```
instrument.setDrumParam
instrument.describeDrumKit
instrument.listDrumPresets
instrument.loadDrumPreset
```

Handlers at `Commands.swift:2215`, `:2265`, `:2293`, `:2308`.

Their four MCP counterparts (what an AI agent calls) are in
`/Users/dsemenov/Views/daw-pro/mcp-server/src/server.ts`:

| MCP tool | line | bridges to |
|---|---|---|
| `instrument_set_drum_param` | 4536 | `instrument.setDrumParam` |
| `instrument_describe_drum_kit` | 4595 | `instrument.describeDrumKit` |
| `instrument_load_drum_preset` | 4641 | `instrument.loadDrumPreset` |
| `instrument_list_drum_presets` | 4663 | `instrument.listDrumPresets` |

### MIDI notes 36-43 — CONFIRMED, and it is deliberately NOT General MIDI

`DrumKit.swift:74-88`:

```swift
/// The MIDI note that triggers this voice. 36–43, the MPC/Ableton Drum Rack
/// base (`PadGridGeometry.swift` lays C1 = 36 at the bottom-left square) …
/// GM percussion is deliberately NOT followed: GM scatters these
/// eight across 35–57, which would make the kit unplayable on a pad grid.
public var note: UInt8 { UInt8(36 + Int(slot)) }
```

Slot order (`DrumKit.swift:47-58`) gives the mapping:

| Note | Voice |
|---|---|
| 36 | Kick |
| 37 | Snare |
| 38 | Closed Hat |
| 39 | Open Hat |
| 40 | Clap |
| 41 | Tom |
| 42 | Rim |
| 43 | Cymbal |

Notes outside 36…43 trigger nothing (`voice(forNote:)`, line 82-85).

**This is a departure from the General MIDI standard and the film should not imply
otherwise.** In GM, 38 is a snare and 42 is a closed hat; here 38 is a closed hat and 42
is a rim. The reason given in source is that GM's eight equivalents are scattered across
35-57, which does not fit onto sixteen contiguous pads.

**Nothing in the six supplied facts is wrong.**

---

## 3. ⚠️ THE UI QUESTION — DOES THE DRUM MACHINE HAVE A UI?

## Answer: NO — no editor card, no panel, no drum view of any kind exists.

But the answer has a second half my first pass got wrong, so read (c2) below as well:
**there IS one hands-on surface that PLAYS it — the 4x4 pad grid — even though that grid
displays nothing about it.** "The drum machine has no editor" is correct. "Nothing a human
can touch plays it" would be wrong.

This is confirmed four independent ways.

### (a) No drum view file exists

```
$ find Sources -iname "*drum*"
Sources/DAWEngine/Instruments/DrumSynthInstrument.swift
Sources/DAWEngine/Instruments/DrumDSP.swift
Sources/DAWCore/DrumKit.swift
```

All three live in the audio engine and the domain model. **Zero files in
`Sources/DAWApp` or `Sources/DAWAppKit`.**

Positive control on the same command shape — `find Sources -iname "*pad*"` returns 18
files including `Sources/DAWApp/Components/PadGridView.swift` — so the probe can return
UI-layer hits, and the drum absence is a measurement rather than a broken search.

`git show --stat 102f00b | grep -i drum` (the commit that shipped the drum machine) lists
`DrumKit.swift`, `DrumDSP.swift`, `DrumSynthInstrument.swift`, five test files, a design
doc and two demo-spec files. **No view file.**

### (b) The app says so itself, in two places

`/Users/dsemenov/Views/daw-pro/Sources/DAWApp/Instrument/InstrumentPickerView.swift:233-236`:

```swift
// `.drumSynth` has no editor card yet (m39-dm ships engine + model +
// wire; the card is UI work). Showing a tune button that opens nothing
// is worse than showing none.
case .testTone, .soundBank, .audioUnit, .drumSynth:
    return nil
```

That is the `tuneAccessory` function. Poly Synth and Sampler each return a "Tune" button
that opens their editor. The Drum Machine returns `nil` — **no button is drawn.**

`/Users/dsemenov/Views/daw-pro/Sources/DAWApp/ViewUIWireSurface.swift:304-316` — this is
the `view.openEditor` handler, i.e. what happens if an agent (or a film script driving the
app) asks the app to open the drum editor. It throws:

> `"track \"<name>\" plays the drum machine, which has no editor card yet — its 75
> parameters are on the wire. Read them with instrument.describeDrumKit, set one with
> instrument.setDrumParam {name:\"kick.decay\", value:0.9}, and load a factory kit with
> instrument.loadDrumPreset {name:\"909\"}."`

**If the film tries to drive the app into a drum editor, it will get an error, not a
panel.** There is nothing to screenshot.

### (c) What a user CAN see and touch today — the complete list

This is the honest answer to "what's on screen".

1. **A row in the instrument picker.** `/Users/dsemenov/Views/daw-pro/Sources/DAWAppKit/InstrumentPickerModel.swift:210-212`:
   ```swift
   BuiltInInstrument(kind: .drumSynth, name: "Drum Machine",
                     detail: "Eight classic drum sounds you can shape — kick, snare, "
                         + "hats, clap and more."),
   ```
   It is the **second** built-in row, between "Poly Synth" and "Sampler", and it is visible
   in both Simple and Pro density (only "Test Tone" is Pro-gated).

2. **An icon.** `/Users/dsemenov/Views/daw-pro/Sources/DAWApp/Components/InstrumentChip.swift:69`
   — SF Symbol `circle.grid.2x2.fill`, a 2x2 grid of dots. This appears on the track's
   instrument chip.

3. **The track's instrument name reading "Drum Machine"** (`InstrumentPickerModel.swift:606`).

4. **It plays.** Clicking the row selects it and the track makes drum sounds on notes
   36-43 immediately, at 808 settings. That is real and demonstrable.

5. **⭐ IT IS PLAYABLE ON THE PAD GRID — a late finding that reverses my first answer.**
   See the subsection below. This is the one genuinely filmable, hands-on drum surface.

**Other than that, nothing.** No panel, no knobs, no kit picker. The five kit names are not
visible anywhere in the app — `listDrumPresets` is a wire verb only. The 75 parameters are
not visible anywhere in the app. There is no way to change a drum sound from the UI.

### ⭐ (c2) CORRECTION — you CAN finger-drum the Drum Machine on the pad grid

My first pass concluded "the pad grid shows blank squares on a drumSynth track, never film
it". That was inferred from a comment about what the grid **draws**, not from the code that
makes it **sound**. Traced properly, the two are different paths:

- `PadGridView` → `onPadDown` → `AppModel.padGridDown`
  (`/Users/dsemenov/Views/daw-pro/Sources/DAWApp/PadGridStaging.swift:74-77`)
- → `PadGridModel.padDown` (`/Users/dsemenov/Views/daw-pro/Sources/DAWAppKit/PadGridModel.swift:734-752`),
  which computes a pitch and calls `typing.pointerDown(pitch:)`
- → `MusicalTypingController.pointerDown`
  (`/Users/dsemenov/Views/daw-pro/Sources/DAWAppKit/MusicalTypingController.swift:903-906`):
  `guard AuditionPitchBounds.contains(pitch) else { return }` — **a pitch bounds check and
  nothing else. There is no instrument-kind gate anywhere on this path.**

And the base note is not derived from sampler zones:
`MusicalTypingController.swift:88` — `public private(set) var padBaseNote = 36`, with
`padBank = 0` (line 91). `PadGridGeometry.pitch(forPad:baseNote:bank:)` (line 101-106) is
`baseNote + bank * 16 + padIndex`.

`canSound` (`MusicalTypingRouting.swift:827-832`) is true for `.ready`, `.recordingArmed`
and `.recordingUnarmed`, false only for `.noTrack`, `.notInstrument`, `.previewOff` —
again, no instrument-kind gate.

**Therefore, on a Drum Machine track in PADS mode, the bottom eight pads play the kit
one-to-one, in voice order:**

| Pad | Key | Note | Sound |
|---|---|---|---|
| 1 | `Z` | 36 | Kick |
| 2 | `X` | 37 | Snare |
| 3 | `C` | 38 | Closed Hat |
| 4 | `V` | 39 | Open Hat |
| 5 | `A` | 40 | Clap |
| 6 | `S` | 41 | Tom |
| 7 | `D` | 42 | Rim |
| 8 | `F` | 43 | Cymbal |
| 9-16 | `Q W E R` / `1 2 3 4` | 44-51 | silent (outside the kit's 36…43 range) |

And PADS mode is reachable from a drumSynth track: the three mode chips at
`MusicalKeyboardStrip.swift:236-238` (`KEYS` / `CHORDS` / `PADS`) are rendered
unconditionally, with no instrument-kind gate, and `padGrid` is a single always-present
`AppModel` property (`ContentView.swift:1816`), not something created per instrument kind.

This is a real, hands-on, human-reachable way to play our own drum machine, and it is the
best thing to film for this feature.

**⚠️ But the squares will look EMPTY.** The *drawing* really does come from sampler zones
(`PadGridModel.swift:223-224`, `zonesProvider`), so on a drumSynth track all sixteen render
as unloaded, the loaded/total count reads 0, and no pad carries a label saying "Kick". The
grid **sounds** the kit and **shows** nothing about it. If the film shows this, narrate it
honestly — "the pads play it, the labels haven't caught up yet" — or shoot it in a way that
does not linger on the empty squares.

### (c3) The other ways a user can play it

- **Piano roll.** Draw notes at C1 through G1 (MIDI 36-43). A drumSynth track opens in the
  piano roll by default — see (d) below.
- **A MIDI keyboard**, playing the bottom octave.
- **Musical typing (NOTES mode).** ⚠️ The default base octave is 4
  (`MusicalTypingRouting.swift:644`, `defaultBaseOctave = 4`), and
  `baseNote(forOctave:) = (octave + 1) * 12` (line 655-657), so the keys start at note 60 —
  middle C. Note 36 needs octave 2. **That is two octave-down presses before typing reaches
  the kit at all.** A film that shows someone typing on the default setting will produce
  silence.
- **The in-app Copilot rail.** `Sources/DAWControl/CopilotCatalog.swift:387` exposes
  `track.setInstrument` to the in-app assistant and explicitly documents `drumSynth`
  ("drumSynth needs no setup at all — it plays a full 808 kit the moment you select it, on
  notes 36-43"). So typing "add a drum machine" into the Copilot works. ⚠️ But the four
  drum verbs themselves (`instrument.setDrumParam` and friends) appear in that file only
  inside that description string — they are not registered catalog entries — so the
  Copilot can *create* a drum machine and cannot *tune* one. (Method: catalog entries are
  registered by a `command:` field. `track.setInstrument` is registered at line 386; the
  only `instrument.*` verb registered anywhere in that file is `instrument.listAudioUnits`
  at line 1214. The four drum verbs appear at line 387 only, inside a description string.)

### (d) ⚠️ SECOND HEADLINE FINDING — a drum-machine track does NOT get the step grid

This one is easy to assume wrong, and the film would show the wrong screen.

The app decides between the **step sequencer** (a drum-style grid of named lanes) and the
**piano roll** (a chromatic keyboard laid on its side) using one predicate,
`SMFProjectExporter.isDrumKit`. At
`/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectMIDIExportMapper.swift:1016-1020`:

```swift
public static func isDrumKit(_ track: Track) -> Bool {
    guard let instrument = track.instrument, instrument.kind == .soundBank,
          let bank = instrument.soundBank else { return false }
    return bank.bankMSB == GMProgramCatalog.percussionBankMSB
}
```

It returns `true` **only** for a `.soundBank` instrument on the General MIDI percussion
bank. A `.drumSynth` track fails the first guard and returns `false`.

`/Users/dsemenov/Views/daw-pro/Sources/DAWAppKit/StepSequencerModel.swift:70`:
```swift
return isDrumKit ? .steps : .notes
```

**So a track playing our own Drum Machine opens in the PIANO ROLL, not the drum step
grid** — the app treats our own drum machine as a melodic instrument by default. There is
a manual mode override (`modeOverride`, `StepSequencerBridge.swift:101`) so a user can
force the step view.

And if they do force it, the lane labels are wrong. The step grid names its lanes with
`InstrumentFamilyResolver.percussionNote` (`StepSequencerModel.swift:133`), which is the
**General MIDI** table at `Sources/DAWCore/InstrumentFamilyResolution.swift:287-294`.
Measured against the kit, note by note:

| Note | Drum Machine | GM label the step grid would show | Match? |
|---|---|---|---|
| 36 | Kick | Bass Drum 1 | yes |
| 37 | Snare | *(no GM entry)* | unlabelled |
| 38 | Closed Hat | Acoustic Snare | **wrong** |
| 39 | Open Hat | *(no GM entry)* | unlabelled |
| 40 | Clap | Electric Snare | **wrong** |
| 41 | Tom | Low Floor Tom | yes |
| 42 | Rim | Closed Hi Hat | **wrong** |
| 43 | Cymbal | High Floor Tom | **wrong** |

**Two of eight correct, four actively mislabelled, two unlabelled.** Do not show the step
grid on a drumSynth track in the film.

### Bottom line for the film

The drum machine is **engine + domain model + wire protocol + MCP tools, with no editor UI
of its own.** Everything that *shapes* a drum sound — the 75 parameters, the 5 kits — is
agent-facing only. That is a genuinely strong story for an AI-native DAW ("a kit is a set
of numbers an agent can reach, not a folder of files").

The one thing a human can do hands-on is **play** it, from the pad grid or the piano roll.

The film must not show or claim: a drum editor panel, a kit browser, labelled drum pads, or
a drum step grid.

---

## 4. The modulation layer and the pad grid

### The modulation layer (new in `ec69328`)

**In plain English.** Normally you set a control on a track — its volume, say — and it
stays where you put it. The modulation layer lets you attach an invisible helper to a
control so it moves by itself. There are four kinds of helper. An **LFO** sweeps the
control smoothly up and down on a repeating cycle, which is how you get a pad that pulses
in time or a sound that drifts side to side. A **step sequencer** moves it in jumps on a
rhythmic pattern instead of smoothly, which is how you get the chopped, stuttering gate
sound. An **envelope follower** listens to how loud something is and passes that loudness
on, so one track can react to another — this is how the bass gets out of the kick drum's
way on every dance record ever made. A **macro** is just a single knob you define yourself
and then wire to several things at once, so one move changes five things together. Each
connection has a *depth*: how strongly the helper pushes. Crucially, the helper never
fights with what you already set — it nudges the value you chose up and down around it
(`Sources/DAWCore/Modulation.swift:503-505`: *"Modulation OFFSETS whatever is in control;
it never competes with it."*).

**Where it lives in source.** `Sources/DAWCore/Modulation.swift` (the four source kinds at
line 28-35: `lfo`, `stepSequencer`, `envelopeFollower`, `macro`; LFO waveforms at line 67
are named `sine`, `triangle`, `sawUp`, `sawDown` — `sawUp`/`sawDown` spelled out on
purpose because "saw" alone is the most mis-assumed direction in modulation UIs),
`Sources/DAWCore/ProjectStore+Modulation.swift`, and four files under
`Sources/DAWEngine/Modulation/`. Nine wire verbs, `Commands.swift:286-294`:
`mod.describeKinds`, `mod.addSource`, `mod.setSource`, `mod.removeSource`, `mod.addRoute`,
`mod.setRouteDepth`, `mod.removeRoute`, `mod.setMacro`, `mod.describe`.

**⚠️ WHAT IS VISIBLE ON SCREEN: NOTHING. There is no modulation UI at all.**

```
grep -rn "ModulationSource\|ModulationRoute" --include="*.swift" Sources/DAWApp Sources/DAWAppKit
  → 0 matches

POSITIVE CONTROLS, same pattern, same command shape:
  Sources/DAWCore    → 62 matches
  Sources/DAWControl → 14 matches
```

The pattern demonstrably finds these names where they exist, and finds none in either app
layer. (A first search for `ModSource|ModRoute` returned zero *everywhere including
DAWCore* — that was a broken pattern, not an absence, and was discarded. The types are
spelled `Modulation*`.)

The app's own source anticipates this: `Sources/DAWAppKit/LiveExpressionSink.swift:42` and
`Sources/DAWApp/DAWProApp.swift:4688` both refer to *"③'s dedicated modulation panel"* as
future work.

**For the film: the modulation layer is real, it runs, an agent can build it, and a
listener can hear it — but a user cannot see or touch it. Show it by ear, never by
screenshot.**

### The pad grid (new in `a338854`)

**In plain English.** A pad grid is a 4x4 square of sixteen buttons, and each button plays
one sound — the layout every drum-machine and beat-making controller has used since the
late eighties. DAW Pro already had the machinery to chop a recording into pieces: take a
drum break or a vocal take, cut it at its hits, and lay the pieces out one per button. But
until this commit that chopping could only be done by an AI agent over the control
protocol — **a human using the app could not chop anything, and could not reach a single
pad.** The pad grid is the door. It puts the sixteen squares on screen inside the keyboard
strip at the bottom of the window, and it wires the computer's own keyboard to them in a
way that matches what you see: the bottom row of letter keys plays the bottom row of pads.
Sixteen pads at a time, with banks for longer chops — a chop can run to 96 pieces, which is
exactly six banks.

**Layout, verified at source** (`Sources/DAWAppKit/PadGridGeometry.swift:52-54`, `:130-145`):

- 4 rows x 4 columns, **pad 1 at the BOTTOM-LEFT** — the note-36 convention, pinned by a
  test because "that is the commonest way this gets built backwards".
- Keyboard mapping, spatially aligned:
  `Z X C V` → pads 1-4 (notes 36-39) · `A S D F` → pads 5-8 ·
  `Q W E R` → pads 9-12 · `1 2 3 4` → pads 13-16 (the top row).
- Pads mode claims only six new keycodes (`Q R 1 2 3 4`) and only while it is on.
- Hit the pad high for a loud note, low for a quiet one (MPC/Maschine convention), with a
  floor of velocity 1, never 0 — because MIDI velocity 0 means note-off, so a pad struck
  at its very bottom edge plays quietly rather than silently releasing itself
  (`PadGridGeometry.swift:195-200`).

**What is visible on screen: a real, complete surface.** The grid is the third "face" of
the Musical Keyboard Strip, selected by a `PADS` mode chip
(`Sources/DAWApp/Components/MusicalKeyboardStrip.swift:238`), drawn by `PadGridView`
(`MusicalKeyboardStrip.swift:401`, view at
`Sources/DAWApp/Components/PadGridView.swift:36`). It shows loaded pads distinctly from
empty ones, a loaded/total count, a bank selector, a trigger-mode control, a 16-levels
toggle, and a chop notice after a chop runs. There is also a chop panel
(`Sources/DAWApp/Instrument/ChopToPadsPanel.swift`) reached from a "Cut the selected audio
clip into pads you can play" button (`MusicalKeyboardStrip.swift:482`).

**⚠️ The pad grid's DRAWING belongs to the SAMPLER; its SOUND does not.** This distinction
matters and I got it wrong on the first pass. `Sources/DAWAppKit/PadGridModel.swift:223-224`:

> `/// The LIVE sampler zones on the pad target — empty when the track is gone,`
> `/// is not an instrument track, or plays something other than the sampler.`

That governs what is *drawn*: loaded-vs-empty squares, the loaded/total count, the bank
count, the chop path (`clip.sliceToSampler`). On a Drum Machine track all sixteen squares
render as unloaded.

But the *sound* path (`padDown` → `typing.pointerDown(pitch:)`) has **no instrument-kind
check at all**, and `padBaseNote` is a hard 36 independent of zones. So the pads do play a
drumSynth track — see §3(c2) for the full trace and the pad-to-voice table.
`DrumKit.swift:74-78` says the note map was chosen so the kit "maps one-to-one onto the
existing 4×4 pad grid **when wave item (4) extends it**" — the *visual* half of that
connection is what is still planned; the *playable* half already works by construction.

**For the film:** the pad grid is fully demonstrable with a chopped audio recording on a
Sampler track (loaded squares, labels, banks, the chop panel). It is also playable on a
Drum Machine track — but with sixteen blank-looking squares, so shoot that for the sound,
not for the picture.

---

## 5. DO NOT CLAIM

Things that exist in the tree (or in the commit prose) but that a user cannot reach today.

1. **A drum machine editor / panel / card / kit browser.** Does not exist. See §3. The
   five kit names, the eight voice names and the 75 parameters are wire-only. Cited:
   `InstrumentPickerView.swift:233-236`, `ViewUIWireSurface.swift:304-316`,
   `find Sources -iname "*drum*"`.

2. **A drum step grid for the Drum Machine.** The step sequencer only opens for a General
   MIDI percussion **sound bank**, never for `.drumSynth`
   (`ProjectMIDIExportMapper.swift:1016-1020` → `StepSequencerModel.swift:70`). A drumSynth
   track opens in the piano roll by default.

3. **Pads that *show* the drum machine.** ⚠️ Revised after tracing the code: the pads
   **do play** a drumSynth track (no kind gate on the sound path — §3(c2)). What does not
   exist is the visual half: the squares draw from sampler zones
   (`PadGridModel.swift:223-224`), so on a drumSynth track they render blank and unlabelled,
   and the loaded count reads 0. Claim "you can finger-drum it"; do not claim a labelled
   drum pad surface, and do not show a close-up of the empty grid.

4. **Any modulation UI — LFO panel, routing matrix, macro knobs.** Zero references in
   either app layer, positive-controlled. See §4.

5. **Multi-instrument templates.** CONFIRMED designed but unbuilt.
   `docs/design/2026-09-20-multi-instrument-templates.md` exists; a case-insensitive grep
   for `multi-instrument template|instrumentTemplate|TrackTemplate|projectTemplate`
   across `--include="*.swift" Sources/` returns **0** — positive-controlled against
   `docs/`, where the same pattern hits the design doc, the drum-machine design doc and
   `docs/ROADMAP.md`.

6. **Tempo-synced tape delay.** `tapeDelay` has **no tempo sync in v1, deliberately**
   (`Effects.swift:99-102`: *"NO TEMPO SYNC IN v1, DELIBERATELY… Synced mode is an
   append"*). The older `.delay` does sync (`sync` / `division` params,
   `Effects.swift:1015-1018`). Do not show or say tape delay locks to the beat.

7. **Audio Units on the master chain.** The master output chain accepts built-ins only in
   v1; the "Audio Units…" menu item is hidden there rather than offered-then-errored
   (`MixerStripView.swift:820-829`, `masterChainBuiltInOnly`).

8. **Hosted-plugin modulation.** `ModulationPath.hostedRenderCall` is present in the enum
   and **REFUSED in v1** (`Sources/DAWCore/Modulation.swift:469-470`). You can modulate our
   own effects and instruments; you cannot modulate a third-party plugin's parameters.

9. **Effects in Simple mode.** The whole inserts section, the "+" menu and every effect
   editor card are Pro-density only. Filming in Simple mode shows no effects at all.

10. **"A knob twist changes the drum sound you are hearing."** Only `level` and `pan` apply
    to a ringing voice; the other 73 parameters take effect at the next note-on
    (`DrumKit.swift:456`: `appliesAtNextNoteOn: leaf != .level && leaf != .pan`). On camera
    a twist looks inert until the next hit.

11. **A separate "de-esser" effect.** It is a mode on `compressor`, not a kind
    (`Effects.swift:4230-4232`).

12. **Anything about what the installed Claude Code plugin exposes.** The source tree and
    the released bundle are in parity as of HEAD (`plugin-bundle-parity.mjs` exits 0:
    42 tools / 22 kinds on both sides). Whether the *user's installed* plugin has been
    updated to that version is a separate question that cannot be answered from the repo,
    and was not checked here because doing so would require touching a running artifact.

---

## 6. Commit prose that is FALSE (evidence that the census method was necessary)

The brief asked for facts, not claims. Two claims in the commit messages themselves do not
survive the census:

1. **`ec69328` says the wave took effects "from 10 to 17".** The census says the base
   commit `7d8a2a4` had **11** built-in kinds (gain, eq, compressor, limiter, reverb,
   delay, saturator, gate, chorus, bassEnhancer, bitCrusher), and the commit added six, so
   it went **11 → 17**. The "17" is right; the "10" is wrong.

2. **`a338854` calls `.phaser` "the tenth effect kind".** It is the **eighteenth**
   built-in kind. The same commit message's own summary line correctly says "18 effect
   kinds", so the message contradicts itself.

Neither affects the shipped software. Both are reasons not to script the film's intro from
commit prose.

Also noted but not chased: `InstrumentPickerModel.swift:198-199` comments that Pro "shows
all three" built-in instruments; the array now holds four. Stale comment, no behavioural
effect.

---

## 7. One-line summary for the narrator

> Twenty-two built-in effects, eleven of them brand new — all twenty-two reachable from the
> mixer's "+" menu in Pro mode, each with its own editor card. A modulation layer that
> makes controls move by themselves, which you can hear but cannot yet see. A sixteen-pad
> grid that finally lets a human chop a recording and play the pieces. And our own drum
> machine — eight voices, five kits, seventy-five parameters, every sound synthesised from
> numbers rather than played back from files. You can finger-drum it on the pads today;
> shaping it is still the AI's job, because it has no panel of its own yet.

---

## 8. Corrections I made to my own draft (the method, stated)

Three claims in my first pass were wrong and were caught by reading the code rather than
the comments. Recording them because they are the shape of error this list exists to
prevent:

1. **"Echo freeze is a new `freeze` parameter on delay."** Wrong. It is the existing
   `feedback` parameter's ceiling raised to 0.999. The `freeze` parameter I found at
   `Effects.swift:1974` belongs to `HallReverbParams`, a different struct entirely. Caught
   by asking which struct encloses the line, instead of trusting a grep hit.
2. **"Saturator oversampling landed in `ec69328`."** Wrong — `102f00b`. A `git log -S` on
   the bare word "oversampling" matched three commits including the initial one; searching
   for `public var oversampling` instead returned exactly one. The de-esser mode is the
   same story, and is new capability the draft had omitted.
3. **"The pad grid shows blank squares on a drumSynth track, so never film it there."**
   Half wrong, and the important half. I had read a comment about what the grid *draws* and
   concluded something about what it *sounds*. The sound path has no instrument-kind check,
   so the pads play the kit. A comment describing one code path is not evidence about a
   different one.
