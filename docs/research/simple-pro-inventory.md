# Simple ↔ Pro progressive-disclosure inventory (M8)

Status: **sp-a foundation cycle** — this doc is the survey that drives the per-panel
conversions in sp-b / sp-c / sp-d. It sweeps every user-facing surface in
`Sources/DAWApp`, grades each against the DESIGN-LANGUAGE "Panels" rule (Simple
shows the 20 % of controls used 80 % of the time; Pro reveals everything; Simple
is the default), and records the recommended work split. sp-a itself converts
**only** the piano roll (already had modes — it refits onto the shared mechanism);
no other panel is touched this cycle.

The shared mechanism sp-a lands:

- `DAWAppKit.PanelDensity` (`.simple` / `.pro`, `.simple` default) +
  `PanelDensityStore` (per-panel-ID get/set over an injected backing, `@Observable`).
- `DAWApp/Components/SimpleProToggle` — the shared SIMPLE/PRO chip pair, extracted
  verbatim from the piano roll's `modeToggle`, bound to a store + panel ID.
- Per-panel, app-sticky preference (UserDefaults key `panelDensity.<panelID>`),
  never written into the project file.
- `debug.panelDensity {panel, mode}` staging command (debug tier; not an MCP tool).

## Verdict legend

- **HAS-MODES** — already carries Simple/Pro.
- **NEEDS-MODES** — control density warrants a split; the proposed Simple (20 %)
  set and the Pro additions are listed, grounded in current file:line evidence.
- **MODES-COINCIDE** — the panel already passes the beginner test and Pro would
  add nothing; it adopts the density model formally (default `.simple`, modes
  render identically) but needs no control hiding. Documented in sp-d, not converted.

## Inventory

| Surface | Primary file | Verdict | One-line rationale |
|---|---|---|---|
| Piano roll | `PianoRoll/PianoRollView.swift` | **HAS-MODES** | The reference implementation; sp-a refits it onto the shared store + `SimpleProToggle`. |
| Mixer channel strip | `Mixer/MixerStripView.swift` | **NEEDS-MODES** | 8 control clusters per 132 pt strip; a beginner needs 4 (fader/meter/pan/M-S-A). Strongest candidate. |
| Mixer master strip | `Mixer/MixerStripView.swift:294` | **MODES-COINCIDE** | Already just fader + stereo meter + dB; nothing to hide. |
| Arrange timeline + clip chrome + snap | `Timeline/TimelineLanesView.swift`, `ContentView.swift` (toolbar) | **NEEDS-MODES** | Clip trim/fade/split/gain/stretch + the snap-resolution picker overwhelm "see clips, move, play". |
| Transport bar | `TransportBar.swift` | **NEEDS-MODES (minor)** | Small delta — PUNCH + the test-tone verify affordance are the only non-beginner controls. |
| Track list / track row | `TrackListView.swift` | **MODES-COINCIDE** | The row is already the Simple set (name/meter/M-S-R); advanced density lives in its disclosure sub-panels. |
| Automation lane editor | `Timeline/AutomationLaneEditor.swift`, `TrackListView.swift:204` | **MODES-COINCIDE** | Disclosure-gated; once open it's VOL/PAN + ON/OFF + draw — already the 20 %. |
| Take lanes / comping | `Timeline/TakeLanesView.swift`, `TrackListView.swift:325` | **MODES-COINCIDE** | Disclosure-gated advanced feature; its controls (select/flatten/paint) are already minimal. |
| Clip-fix panel (FIX WITH AI) | `ClipFix/ClipFixPanel.swift` | **MODES-COINCIDE** | Guided AI flow, beginner labels (SUBTLE/BALANCED/BOLD); region beats are essential, not advanced. |
| Sketchpad (AI generation) | `Sketchpad/SketchpadView.swift` | **MODES-COINCIDE** | STYLE + LENGTH + GENERATE is already the lean essential set; Simple-by-default. |
| Lyrics Workshop | `Sketchpad/LyricsWorkshopView.swift` | **MODES-COINCIDE** | Nested disclosure; THEME/STYLE/STRUCTURE/WRITE is already focused and plain-language. |
| Copilot rail (AI chat) | `Copilot/CopilotRailView.swift` | **MODES-COINCIDE** | A chat box (transcript + input) has no advanced controls to hide. |
| Settings / API keys | `Settings/SettingsView.swift` | **MODES-COINCIDE** | App chrome (no violet by design); rows + save/clear are already minimal. |

## Per-surface detail

### Piano roll — HAS-MODES (refit in sp-a)

Current modes: `PianoRollMode` (`PianoRollView.swift:9-13`), local `@State mode`
(`:28`), chip at `:116-138`. Simple locks snap to Beat and hides the velocity
lane, snap picker, and resize handles (`:49`, `:66-69`, `:108`, `:307`); Pro adds
all three. sp-a replaces `PianoRollMode` + the local state with
`PanelDensity` + the store (panel ID `"pianoRoll"`) and swaps the inline chip for
`SimpleProToggle`. The **only** behavior change: the mode is now sticky across
panel close/reopen and app relaunch (was reset to Simple on every open). Simple's
locked-Beat / hidden-lane-picker-handles behavior is preserved exactly.

### Mixer channel strip — NEEDS-MODES (sp-b)

`MixerChannelStrip.body` (`MixerStripView.swift:23-48`) stacks, per 132 pt strip:
header + kind badge (`:52-69`), **Inserts** section with an add-menu (`:73-120`),
**Sends** with an add-menu + per-send mini-fader + dB (`:124-189`), **Output**
routing picker (`:193-230`), **Pan** knob + readout (`:234-249`), the
fader + meter + dB readout (`:253-269`), and the Mute/Solo/Arm row (`:273-287`).

- **Simple (the 20 %)**: name + kind badge, Pan knob + readout, the volume fader
  beside its meter + dB readout, and Mute/Solo/Arm. This is "set a level, place it
  in the field, mute/solo/arm" — what a newcomer reaches for first.
- **Pro adds**: the Inserts chain, the Sends section, and the Output routing
  picker (signal-flow controls a beginner doesn't touch until they're mixing with
  buses and effects).

Master strip (`:294-337`) is already fader + stereo meter + dB — **MODES-COINCIDE**;
it adopts the model but renders identically in both modes.

### Arrange timeline + clip chrome + snap — NEEDS-MODES (sp-c)

The arrange surface is dense with direct-manipulation clip editing and a snap
picker. Evidence: the arrange toolbar's grid-snap menu Off/Bar/Beat/1÷2/1÷4
(`ContentView.swift:242-273`), and the clip chrome wired in `arrangeWorkspace`
(`ContentView.swift:121-155`) + rendered in `TimelineLanesView` — move, ~6 pt
edge trim, corner fades, a gain dB chip, ⌥ time-stretch, and double-click split
(all documented in DESIGN-LANGUAGE "Clip editing").

- **Simple (the 20 %)**: see clips, drag the body to move, and play — on a Bar
  grid (snap locked to Bar, mirroring the piano roll locking Simple to Beat). Hide
  the snap-resolution picker, the trim edge-strips, the fade grips, the per-clip
  gain chip, the split affordance, and the ⌥ time-stretch cue.
- **Pro adds**: the full clip-edit interaction layer (trim / fade / split / gain /
  stretch) and the snap-resolution picker.

Note: much clip chrome is already hover/selection-gated (fade grips faint at rest,
gain chip only on hover/selection), so the Simple delta is mostly "lock snap to
Bar + suppress the edge/grip/split gestures + hide the picker" rather than a full
re-layout. Automation rows and take lanes inside the arrange sidebar keep their own
verdicts (both MODES-COINCIDE) and are unaffected.

### Transport bar — NEEDS-MODES, minor (sp-d)

`TransportBar.body` (`TransportBar.swift:9-41`): return-to-zero / play / record
(`:43-85`), the LOOP / PUNCH / CLICK chips (`:98-180`), Position + Time readouts
(`:15-28`), the tempo cluster + nudges (`:182-195`), the **test-tone** button
(`:209-222`), and the master mini-fader + meter (`:198-207`).

- **Simple (the 20 %)**: transport buttons + Position + Time + tempo + master.
  LOOP and CLICK are beginner-friendly and can stay.
- **Pro adds**: PUNCH (an advanced record window) and the test-tone verify
  affordance (a developer/diagnostic control, arguably not a Simple control at
  all). This is the smallest delta of the three NEEDS-MODES surfaces — hence sp-d.

### MODES-COINCIDE surfaces (documented, not converted — sp-d)

- **Track row** (`TrackListView.swift:104-146`): kind icon + name + mini level bar
  + clip count + the (conditional) takes/automation disclosures + M/S/R chips. The
  row is already the essential set; the two disclosure glyphs are conditional and
  low-noise (dim unless active). Its real density lives in the expandable
  Automation/Take sub-panels, which carry their own verdicts.
- **Automation lane editor** (`AutomationLaneEditor.swift`; sidebar controls
  `TrackListView.swift:204-318`): reached only through a header disclosure; once
  open it's a VOL/PAN target picker + an ON/OFF enable + delete + the breakpoint
  canvas — already exactly the 20 %.
- **Take lanes / comping** (`TakeLanesView.swift`; sidebar controls
  `TrackListView.swift:325-423`): disclosure-gated comping; per-group FLATTEN +
  per-lane select/delete + comp painting are already minimal.
- **Clip-fix panel** (`ClipFixPanel.swift`): a single guided AI action with
  plain-language STRENGTH labels (`:225-231`); region START/END beats are essential
  to the feature, not an advanced extra.
- **Sketchpad** (`SketchpadView.swift`): STYLE + LENGTH + GENERATE + candidates is
  already the lean essential flow; the one advanced sub-surface (the Lyrics
  Workshop) is itself a disclosure.
- **Lyrics Workshop** (`LyricsWorkshopView.swift`): nested disclosure, plain fields.
- **Copilot rail** (`CopilotRailView.swift`): a chat transcript + input — no
  advanced controls exist to hide.
- **Settings** (`SettingsView.swift`): app chrome (no violet by design); provider
  rows + Save/Clear are already minimal.

For these, sp-d's job is to have each adopt `PanelDensity` formally (so the whole
app is uniformly density-aware and a future Pro-only control has a home) while
rendering identically in both modes — or to explicitly record the surface as
density-exempt with this rationale. No control hiding is required.

## Recommended sp-b / sp-c / sp-d split

- **sp-b — Mixer.** Convert `MixerChannelStrip` to `PanelDensity` (panel ID e.g.
  `"mixer"`): Simple = name/kind + pan + fader/meter/dB + M-S-A; Pro adds
  inserts + sends + output. Master strip modes coincide. Self-contained, highest
  beginner value, one file — the natural first conversion.
- **sp-c — Arrange.** Convert the arrange timeline + clip chrome + snap (panel ID
  e.g. `"arrange"`): Simple = move + play on a Bar grid with the snap picker and
  the trim/fade/split/gain/stretch affordances suppressed; Pro = the full clip-edit
  layer + snap-resolution picker. Larger (gesture-gating in `TimelineLanesView`),
  so it follows the mixer.
- **sp-d — The rest.** (1) The minor Transport split (hide PUNCH + test-tone in
  Simple). (2) Formally adopt the density model on the MODES-COINCIDE surfaces
  (track row, automation editor, take lanes, ClipFix, Sketchpad, Lyrics Workshop,
  Copilot, Settings), documenting each as coincident/exempt. Closes out uniform
  density coverage across the app.

## Density adoption status (sp-d close-out, 2026-07-10)

With sp-d landed, density coverage is **uniform** across `Sources/DAWApp`. Four
surfaces carry a live `SimpleProToggle` (a real Simple/Pro delta); every other
user-facing surface's Simple and Pro modes **COINCIDE** by design — nothing a
beginner shouldn't see, nothing Pro would add — so they stay chip-free. A toggle
that changes nothing is worse than none.

| Surface | Panel ID | Status | Rationale |
|---|---|---|---|
| Piano roll | `pianoRoll` | **LIVE CHIP** | Simple locks snap to Beat and hides the velocity lane, snap picker, and resize handles; Pro adds all three (sp-a, the reference refit). |
| Mixer console | `mixer` | **LIVE CHIP** | Simple = name/kind + pan + fader/meter/dB + M-S-A; Pro adds inserts, sends, and output routing (sp-b). |
| Arrange timeline | `arrange` | **LIVE CHIP** | Simple = move + play on a Bar grid; Pro adds trim/fade/split/gain/stretch + the snap-resolution picker (sp-c). |
| Transport bar | `transport` | **LIVE CHIP** | Simple = transport + LOOP/CLICK + Position/Time + tempo + master; Pro adds PUNCH and the test-tone verify affordance (sp-d). |
| Mixer master strip | — | **COINCIDENT-EXEMPT** | Already just fader + stereo meter + dB; nothing to hide. |
| Track row | — | **COINCIDENT-EXEMPT** | Already the Simple set (name/meter/M-S-R); advanced density lives in its disclosure sub-panels. |
| Automation lane editor | — | **COINCIDENT-EXEMPT** | Disclosure-gated; once open it's VOL/PAN + ON/OFF + draw — already the 20 %. |
| Take lanes / comping | — | **COINCIDENT-EXEMPT** | Disclosure-gated advanced feature; select/flatten/paint are already minimal. |
| Clip-fix panel | — | **COINCIDENT-EXEMPT** | Guided AI flow with beginner labels (SUBTLE/BALANCED/BOLD); region beats are essential, not advanced. |
| Sketchpad | — | **COINCIDENT-EXEMPT** | STYLE + LENGTH + GENERATE is already the lean essential set; Simple-by-default. |
| Lyrics Workshop | — | **COINCIDENT-EXEMPT** | Nested disclosure; THEME/STYLE/STRUCTURE/WRITE is already focused and plain-language. |
| Copilot rail | — | **COINCIDENT-EXEMPT** | A chat box (transcript + input) has no advanced controls to hide. |
| Settings / API keys | — | **COINCIDENT-EXEMPT** | App chrome (no violet by design); rows + Save/Clear are already minimal. |
