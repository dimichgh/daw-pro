# Design-compliance audit — M8 (glass-a)

App-wide sweep of every shipped surface against `docs/DESIGN-LANGUAGE.md`. Method:
a full read of the design language + the token type (`Sources/DAWApp/Theme.swift`),
a code sweep of the view layer (raw `Color(`/hex/`.gray`/`.secondary`/`Font.system`
on numeric labels), and a capture sweep — the prebuilt `.build/debug/DAWApp` driven
over the control WebSocket (port 17695) through the `ui.show*` / `debug.*Seed`
staging commands, one PNG per surface, each viewed by the auditor. Before/after
captures live in `scratchpad/glass-a/`.

Scope guard honored: pure view / design-system pass (`Sources/DAWApp` + one token
pair used by `DAWAppKit` token tests). No control commands, MCP, renames, deps,
or Simple/Pro work; `DAWCore`/`DAWEngine`/`DAWControl` untouched.

## Verdict table

| Surface | Verdict | Violations |
|---|---|---|
| Transport bar | CLEAN | 0 |
| Arrange — track-list sidebar | FIXED | 1 (mute accent) |
| Arrange — timeline (clips/fades/stretch/gain) | CLEAN | 0 |
| Automation lane editor | CLEAN | 0 |
| Take lanes | CLEAN | 0 |
| Piano roll | FIXED | 1 (raw-hex key colors) |
| Mixer console | CLEAN | 0 |
| Sketchpad (+ candidate cards) | CLEAN | 0 |
| Clip-fix panel (+ job cards) | CLEAN | 0 |
| Lyrics workshop | CLEAN | 0 |
| Copilot rail | CLEAN | 0 |
| Settings panel | CLEAN | 0 |
| Design tokens (`Theme.swift`) | FIXED | token pair added; 3 cross-cutting FOLLOW-UPs |

Net: 2 in-place fixes, 3 cross-cutting FOLLOW-UPs (restyle-sized / design-decision,
deferred per the "no half-fix" rule). The codebase already routes essentially all
color through `DAWTheme`, uses SF Mono for every numeric readout, applies the glow
recipe to state-only, and reserves violet for AI surfaces — the two fixes are the
only hard rule breaks found.

---

## Transport bar — CLEAN
`Sources/DAWApp/TransportBar.swift`

- Position / Time / Tempo are `DigitalReadout` (SF Mono, letterspaced, glow) — Rule
  "SF Mono for every numeric readout" holds. Position/Time cyan; Tempo neutral
  `textPrimary` (correct — tempo is not a playback/position value, so cyan would
  *mis*claim it; keeping it neutral respects "one accent per meaning").
- Play/Record/loop/punch/click chips: cyan playback, amber record/punch, green
  click; glow only when engaged (never static chrome). Master fader cyan + meter.
- All chrome tokenized (`DAWTheme.*`); no raw color, no stock AppKit control.

## Arrange — track-list sidebar — FIXED
`Sources/DAWApp/TrackListView.swift`

- **Mute chip accent (FIXED).** `TrackListView.swift:130` → the row `M` chip used
  `onColor: DAWTheme.record` (amber). Rule 3 ("one accent per meaning") + the
  design language's explicit "**Mute = red**" + the mixer console (`MixerStripView.swift:275`
  already uses `DAWTheme.clip`). In the sidebar the `M` (mute) and `R` (arm) chips
  both lit **amber**, so they were indistinguishable and mute mis-signalled
  "record". Fix: `onColor: DAWTheme.clip` (red), matching the doc and the mixer.
  Verified in `arrange-before.png` (Bass `M` amber) → `arrange-after.png` (`M` red).
- Solo `S` = cyan (active), Arm `R` = amber (record), disclosures cyan (automation)
  / signal-green (takes), AI tracks violet-bordered — all correct. Clip-count
  `N ♪` in SF Mono.

## Arrange — timeline (clips, fades, stretch, gain, splice) — CLEAN
`Sources/DAWApp/Timeline/TimelineLanesView.swift`, `ClipWaveform.swift`

- Clip tint: signal-green audio / playback-cyan MIDI / violet AI (`tint(_:)`),
  matching the doc. Selected clip brighter + glow; playhead a glowing cyan hairline
  offset (not a per-frame Canvas redraw).
- Fades render translucent (`DAWTheme.background.opacity(0.5)`) so the waveform
  reads through; gain chip cyan SF Mono; stretch badge amber only out-of-band
  (0.75–1.5× band); render-fail red border + red dot; splice line signal-green;
  ClipShimmer diagonal sweep as the "working" cue (never a spinner). Bar numbers +
  all cursor readouts SF Mono. Waveform dual-tone (body + brighter core), off-main
  cached. No per-frame allocation (Paths rebuilt on data change only).

## Automation lane editor — CLEAN
`Sources/DAWApp/Timeline/AutomationLaneEditor.swift`

- Volume lane tracks fader cyan; pan lane neutral `textPrimary` white (pan claims
  no accent) — exactly the doc's mixer semantics. Disabled lane dims. Neon polyline
  drawn bloom-under-core (glow recipe); glowing breakpoint dots; dashed neutral
  guide; SF Mono cursor readout (dB volume / L-C-R pan). VOL/PAN + ON chips correct.

## Take lanes — CLEAN
`Sources/DAWApp/Timeline/TakeLanesView.swift`

- Signal-green take glyph/header/select-dots; newest lane a green accent bar + bold
  SF Mono tag; comp regions glow (bloom under bright core-stroke) over dim material;
  glowing splice seams + "group · N" SF Mono badge on the main lane. Violet only
  when a lane clip is itself AI. FLATTEN escape hatch present. Verified `takes-before.png`.

## Piano roll — FIXED
`Sources/DAWApp/PianoRoll/KeyboardSidebar.swift`, `PianoRollView.swift`, `VelocityLane.swift`

- **Raw-hex key colors (FIXED).** `KeyboardSidebar.swift:29` drew the keyboard-gutter
  rows with inline `Color(hex: 0x11141C)` (black keys) / `Color(hex: 0x2C3242)`
  (white keys) — a breach of the `Theme.swift` contract ("All color in the app goes
  through these — **no raw hex literals in views**") and token-hygiene Rule 6. Fix:
  added `DAWTheme.keyBlack` / `DAWTheme.keyWhite` (same hex, zero visual change) and
  referenced them. This was the *only* raw hex outside `Theme.swift` in the whole
  view layer.
- Notes cyan / violet-when-AI, velocity→opacity, selected brighter + bloom; octave
  labels + velocity readouts + AI badge SF Mono; middle-C cyan tick; Simple/Pro chip
  pair (cyan-lit active); Pro snap picker restyled (not stock gray). All compliant;
  before/after piano-roll captures are pixel-identical except the tokenization is a
  pure passthrough (`pianoroll-before/after.png`).

## Mixer console — CLEAN
`Sources/DAWApp/Mixer/MixerStripView.swift`, `MixerControls.swift`, `MixerView.swift`

- **Mute = red, Solo = cyan, Arm = amber (breathing halo)** — correct, and the
  reference the sidebar fix aligns to. Kind badges: audio signal-green, instrument
  playback-cyan, bus neutral slate; violet never codes a kind (AI flagged by
  border+dot only). Faders + dB readouts cyan; pan + send neutral white; SF Mono dB
  / pan / send readouts; meters green→amber→red with level-tracked glow; master
  cyan-accent-bordered with a faint glow. Knobs/faders Canvas-drawn, value-driven
  redraw. Verified `mixer-before.png`.

## Sketchpad — CLEAN
`Sources/DAWApp/Sketchpad/SketchpadView.swift`, `SketchpadCandidateRow.swift`

- Violet through-line: panel edge, header dot, section-tag buttons, GENERATE (violet
  when armed), candidate accents, IMPORTED badge — all `DAWTheme.ai`. LENGTH stepper
  cyan SF Mono (numeric readout, not an AI signal — correct exception). Sidecar
  banner amber (installed-not-running) / red (error) / neutral. Candidate lifecycle:
  QUEUED / STEP n/m + NN% over a violet bar under a shimmer (working cue) / SF Mono
  BPM·LEN + cyan PREVIEW + violet IMPORT / red failed / violet IMPORTED. (Capture:
  the real machine has no sidecar, so the banner shows amber not-running and the
  candidate strip sits below the fold — behavior, not a design issue.)

## Clip-fix panel — CLEAN
`Sources/DAWApp/ClipFix/ClipFixPanel.swift`, `ClipFixJobCard.swift`

- Violet AI surface; START/END beat fields cyan SF Mono (the numeric-readout
  exception); STRENGTH chips beginner-labelled (SUBTLE/BALANCED/BOLD), active half
  violet; FIX THIS REGION violet-when-armed. Cards: running (shimmer + violet bar),
  READY green + violet IMPORT, red failed, amber stale, violet IMPORTED. Verified
  `clipfix-jobs-before.png` (all three states read correctly).

## Lyrics workshop — CLEAN
`Sources/DAWApp/Sketchpad/LyricsWorkshopView.swift`

- Violet is correct here (every word is AI-authored): violet wash + hairline,
  violet section chips + quick-add, WRITE/REWRITE violet-when-armed, APPLY violet.
  The inline WRITING… spinner is explicitly sanctioned by the doc for this surface
  (distinct from the shimmer rule on the other AI panels). Red error strip. Verified
  `lyrics-before.png`.

## Copilot rail — CLEAN
`Sources/DAWApp/Copilot/CopilotRailView.swift`, `CopilotTranscriptEntryView.swift`

- Most AI-identified surface: violet edge, identity dot, assistant prose, tool-call
  chips, send arrow. The one sanctioned exception is tool RESULTS — semantic left
  edge **green ok / red error** (fastest outcome read). Failure = red strip. WORKING
  shimmer row (never a spinner). Cancel = red stop. Verified `copilot-before.png`.

## Settings panel — CLEAN
`Sources/DAWApp/Settings/SettingsView.swift`

- App CHROME, **no violet** (correct — a keys panel manages access, it doesn't
  produce audio). Centered glass card over a dimmed scrim (in-window, not a stock
  prefs window). Status badges: green CONFIGURED·ENV (lock) / CONFIGURED·KEYCHAIN
  (key) / neutral NOT SET; red CLEAR only when a key is present; green session mask;
  Suno DORMANT; ACE-Step green NO KEY NEEDED. SF Mono throughout. Verified
  `settings-before.png`.

## Design tokens (`Theme.swift`) — FIXED
`Sources/DAWApp/Theme.swift`

- Added `DAWTheme.keyBlack` / `DAWTheme.keyWhite` (piano-key row surfaces) so the
  keyboard gutter draws from tokens, not inline hex. `glow(_:)` already implements
  the doc recipe exactly (default `radius 8, intensity 0.6` → shadow(8, 0.6) +
  bloom(20, 0.15)); `glassPanel` gives the raised-panel + hairline. No change needed
  there.

---

## FOLLOW-UPs (deferred — restyle-sized or a design-language decision; not half-fixed)

- **FU-1 — cyan "+" add-affordances.** The add-track (`TrackListView.swift:20`) and
  add-insert / add-send (`MixerControls.swift:110,178`) `+` glyphs use
  `DAWTheme.playback` (cyan). Cyan is reserved for "playback/position/active"; a
  generic *create* action is arguably not "active". Pervasive and debatable (cyan
  reads as the app's primary interactive tint). Resolution is a design-language call:
  either sanction cyan-as-interactive-accent explicitly in the doc, or restyle add
  affordances to a neutral accent. Deferred — not a lone in-place fix.

- **FU-2 — secondary/placeholder contrast (Rule 5).** Empty-state and placeholder
  text uses `DAWTheme.textDim.opacity(0.6–0.7)` (e.g. "No inserts"/"No sends"
  `MixerStripView.swift:82,133`, editor placeholders in Sketchpad/ClipFix/Lyrics,
  empty-state subtitles in `MixerView`/`TrackListView`). At 60–70 % of the already-
  dim token these likely dip below the 4.5:1 label bar. A contrast pass (raise the
  dim-secondary token or introduce a `textFaint` that still passes) touches many
  views — deferred as a coherent restyle, not scattered opacity tweaks.

- **FU-3 — grid-emphasis hairline literals.** Three near-duplicate one-off literals
  encode the same "brighter-than-hairline grid line" meaning at slightly different
  strengths: `Color.white.opacity(0.14)` (timeline bar line,
  `TimelineLanesView.swift:212`), `0.16` (piano-roll bar line, `PianoRollView.swift:249`),
  `0.12` (keyboard octave marker, `KeyboardSidebar.swift:41`). They should collapse
  into one `DAWTheme` grid token, but unifying the three values is a (small) visual
  reconciliation — outside a pure-refactor's "no visual change" bound — so it is
  recorded here rather than forced now.

## Deviations

- Sketchpad candidate cards were below the fold in `sketchpad-before.png` (tall
  composer + a 713 pt window) and the real machine has no ACE-Step sidecar, so the
  GENERATE-armed violet state isn't shown there; the identical card idiom is fully
  verified in `clipfix-jobs-before.png` and the code. No design finding rides on it.

---

## glass-c execution addendum

Execution of the three glass-a FOLLOW-UPs (M8 sub-item glass-c). Design decisions
were settled in the brief and implemented as-is (not relitigated): FU-1 create
affordances go neutral, FU-2 a measured contrast pass via new text-hierarchy tokens,
FU-3 one `gridEmphasis` token at 0.14. Same scope guard as glass-a. Captures for the
changed pixels live in `scratchpad/glass-c/`.

### FU-1 — "+" create affordances → neutral chrome

Rule 3 ("never reuse cyan for anything but playback/activity") is unambiguous, so the
generic *create* "+" glyphs drop `DAWTheme.playback` (cyan) for `DAWTheme.textPrimary`
on the same raised-chip treatment (hairline, no accent, no glow at rest). An accent is
earned by state, not by inviting a click. Sites changed:

| Site | Was | Now |
|---|---|---|
| `TrackListView.swift:21` (add track) | `DAWTheme.playback` | `DAWTheme.textPrimary` |
| `Mixer/MixerStripView.swift:110` (add insert) | `DAWTheme.playback` | `DAWTheme.textPrimary` |
| `Mixer/MixerStripView.swift:178` (add send, enabled branch) | `DAWTheme.playback` | `DAWTheme.textPrimary` |

The add-send disabled branch keeps `DAWTheme.textDim` (correct — a disabled affordance
stays muted). The Sketchpad length stepper `±` (`SketchpadView.swift:187`) is **not**
a create affordance — it nudges a numeric readout, so its cyan is the sanctioned
SF-Mono-readout exception and is left as-is.

### FU-2 — measured contrast pass (WCAG relative luminance)

Method: sRGB→linear per channel, `L = 0.2126R+0.7152G+0.0722B`, ratio
`(L_hi+0.05)/(L_lo+0.05)`; `.opacity(α)` sites alpha-composited over the opaque
surface first. Surfaces: base `#0B0D12`, raised panel `#12151D`, panelRaised chip
well `#181C27` (the lightest common surface = worst case for light text). Plain
`textDim` (#8A93A6) was measured at **5.51–6.30:1** — already ≥ 4.5, so every plain-
`textDim` label (section captions, dB readouts, empty-state titles) is already
compliant and left untouched. The only sub-legible text was the ad-hoc `.opacity()`
blends below it.

New tokens (Theme.swift): `textSecondary` #9FA9BC (legible secondary labels, ≥ 4.5),
`textFaint` #767E90 (placeholder/decorative floor, ≥ 3.0, visibly dimmer than
`textDim`). Hierarchy stays monotonic: primary 14.4–16.4 > secondary 7.2–8.2 >
dim 5.5–6.3 > faint 4.2–4.8 (all on the three surfaces).

Before → after (worst-case surface shown; full per-surface math in `scratchpad/contrast.py`):

| Site | Text | Class | Was (blend) | Was ratio | Now token | Now ratio | Pass |
|---|---|---|---|---|---|---|---|
| `Mixer/MixerStripView.swift:82` | "No inserts" | label (names section state) | `textDim@0.7` | 3.39:1 | `textSecondary` | 6.71:1 | ≥4.5 |
| `Mixer/MixerStripView.swift:133` | "No sends" | label (names section state) | `textDim@0.7` | 3.39:1 | `textSecondary` | 6.71:1 | ≥4.5 |
| `ClipFix/ClipFixPanel.swift:175` | editor placeholder | placeholder | `textDim@0.6` | 2.84:1 | `textFaint` | 4.18:1 | ≥3.0 |
| `Sketchpad/SketchpadView.swift:161` | editor placeholder | placeholder | `textDim@0.6` | 2.84:1 | `textFaint` | 4.18:1 | ≥3.0 |
| `Sketchpad/LyricsWorkshopView.swift:251` | editor placeholder | placeholder | `textDim@0.6` | 2.84:1 | `textFaint` | 4.18:1 | ≥3.0 |
| `Copilot/CopilotRailView.swift:200` | field prompt | placeholder | `textDim@0.7` | 3.39:1 | `textFaint` | 4.18:1 | ≥3.0 |
| `TrackListView.swift:39` | empty-state hint subtitle | decorative hint | `textDim@0.7` | 3.39:1 | `textFaint` | 4.18:1 | ≥3.0 |
| `Mixer/MixerView.swift:71` | empty-state hint subtitle | decorative hint | `textDim@0.7` | 3.39:1 | `textFaint` | 4.18:1 | ≥3.0 |
| `Mixer/MixerView.swift:65` | empty-state icon (26pt glyph) | decorative | `textDim@0.6` | 2.84:1 | `textFaint` | 4.18:1 | ≥3.0 |

Worst-case overall: **2.84:1 → 4.18:1** (the `.opacity(0.6)` placeholders, which sat
below even the 3.0 legibility floor).

Judgment calls (recorded per brief point 5):
- "No inserts"/"No sends" are classified as **real labels** (they name the state of a
  named section), so they take `textSecondary` (≥ 4.5), not the faint floor.
- The `MixerView` empty-state **icon** is decorative (not text, so WCAG doesn't gate
  it) but is routed to `textFaint` to keep the faint decorative tier coherent with the
  subtitle beside it, rather than leaving it below the subtitle at the old 0.6 blend.
- Native chrome left as-is: the Settings `SecureField("Paste key…")` prompt (system-
  managed placeholder color; Settings audited CLEAN) and the Copilot first-use hint's
  violet arrow glyph (`CopilotRailView.swift:169`, an AI accent, not a dim label).

### FU-3 — single grid-emphasis token

Three near-duplicate "brighter-than-hairline bar/marker" literals collapse into one
`DAWTheme.gridEmphasis = Color.white.opacity(0.14)` (the middle value; a deliberate
small reconciliation). Plain hairlines stay on `DAWTheme.hairline`.

| Site | Was | Now | Shift |
|---|---|---|---|
| `Timeline/TimelineLanesView.swift:212` (timeline bar line) | `white@0.14` | `gridEmphasis` (0.14) | none |
| `PianoRoll/PianoRollView.swift:249` (piano-roll bar line) | `white@0.16` | `gridEmphasis` (0.14) | −0.02 |
| `PianoRoll/KeyboardSidebar.swift:41` (keyboard octave marker) | `white@0.12` | `gridEmphasis` (0.14) | +0.02 |

Two surfaces shift by 0.02: the piano-roll bar line dims a hair (0.16→0.14) and the
keyboard octave marker brightens a hair (0.12→0.14) — both now read at the identical
grid-emphasis strength as the timeline. The middle-C tick in `KeyboardSidebar` keeps
its `DAWTheme.playback.opacity(0.7)` cyan (unchanged).
