# Onboarding — "First song in ten minutes" guided tour (M8 ob-a design + headless model)

VISION anchors: pillar 4 (*radically understandable* — plain language + progressive
disclosure) and the success criterion — "a musician can go from empty project to a
mixed, mastered, partially AI-generated song without leaving the app." This tour is
the guided expression of that criterion: seven steps that walk a first-time user from
an empty project to a saved song.

**Scope of ob-a (this doc + the headless model + its tests).** ob-a ships:
`docs/research/design-onboarding.md` (this file), `Sources/DAWAppKit/OnboardingModel.swift`
(the state machine + step catalog + signal enum + injected persistence backing), and
`Tests/DAWAppKitTests/OnboardingModelTests.swift`. **No UI, no app-target code, no
control-protocol command** — the chrome (the tour card, the anchoring, the signal
wiring, the Settings "Replay tour" seam) is **ob-b**, built on top of the model landed
here. This doc's *signal wiring map* IS the ob-b contract.

The model follows the two headless idioms already in DAWAppKit:
`PanelDensityModel.swift` (the injected persistence backing) and `ExplainModel.swift` /
`ExplainCatalogTests` (the headless, style-rule-tested copy catalog).

---

## Design principles

1. **Keyless by design.** No Anthropic/OpenAI key is required. The generative step
   rides the **local ACE-Step sidecar** (the Sketchpad path) and offers an instant
   fallback — the **song-skeleton macro** (`store.applySongSkeleton`, five genres) —
   for when the sidecar is down or the user wants zero wait. Both paths satisfy the
   same completion signal: *the project gained content.*
2. **Signal-driven, zero store coupling.** The model **never reads `ProjectStore`**.
   The app (ob-b) calls `model.signal(_:)` at the real operation sites; the model
   advances **only** when the incoming signal matches the **active** step's expected
   signal. Out-of-order, duplicate, and post-dismissal signals are ignored no-ops.
3. **Never trapped.** Every task step can *also* be advanced manually (`advance()`) or
   skipped (`skipStep()`), so a missed or un-emitted signal never strands the user.
4. **Beginner voice.** Every step's copy obeys the glass-cockpit beginner rules
   (docs/DESIGN-LANGUAGE.md Rule 6): plain language, no unglossed unit jargon
   (dB / Hz / …), sentence-final punctuation. Enforced headless by
   `OnboardingModelTests` — the `ExplainCatalogTests` precedent.
5. **Resumable, then out of the way.** Mid-tour progress survives relaunch; the two
   terminal states (`completed`, `dismissed`) persist and **never auto-offer again**.
   Both are **replayable** on demand (`reset()` — the ob-b Settings seam).

---

## The script (7 steps, in order)

Each step carries a `title` (≤ 28 chars), a beginner-readable `body` (40–280 chars,
sentence-final punctuation, no unglossed jargon), a `cta` label, an optional `anchor`
(an existing `ExplainID` the ob-b card will point at — every non-nil anchor is a
registered catalog id, tested), and its **expected completion signal** (nil for
`welcome`/`done`). Copy of record lives in `OnboardingCatalog.steps`; the table below
is the rationale.

| # | step | signal | anchor | why this step, why here |
|---|------|--------|--------|-------------------------|
| 1 | `welcome` | — (manual) | — | The promise up front: "your first song in about ten minutes." A no-signal gate: it advances on the **Start** CTA (or the user dismisses the whole tour). Sets expectations without doing anything to the project. |
| 2 | `generate` | `projectGainedContent` | `.aiSketchpad` | Content first — an empty project is nothing to tour. Points at the **AI Sketchpad**, suggests a starter prompt, and offers the **instant template** (skeleton) fallback so the keyless/offline path is first-class, not a footnote. |
| 3 | `listen` | `playbackStarted` | `.transportPlay` | Immediate payoff: press Play and *hear* the thing. Doubles as the introduction to the **Vibe Meter** ("watch the mix glow") — the signature visualization sells itself the moment audio moves. |
| 4 | `shape` | `editPerformed` | `.clipBlock` | Ownership: make **one** edit (drag a clip, mute a track, nudge the tempo). Deliberately broad — any journaled edit counts — so the user succeeds however they poke at it. |
| 5 | `mix` | `mixerAdjusted` | `.mixerFader` | Switch to the **Mix** view and touch a fader (or drop a mixer preset). Introduces the per-track mixer and the Simple/Pro idea without a lecture. |
| 6 | `export` | `renderCompleted` | — | Close the loop the success criterion demands: **bounce** the song to a file. No `ExplainID` exists for an export control yet (there is no export UI today — see the wiring map), so the anchor is nil until ob-b builds one. |
| 7 | `done` | — (terminal) | `.aiCopilot` | Celebration + where to go next: turn on **Explain** to learn any control by hovering, or ask the **Copilot** to make changes in plain words. Advancing (**Finish**) marks the tour `completed`. |

Copy notes of record:

- **welcome** leads with the ten-minute promise and offers "skip the tour" in the same
  breath — a tour you can leave is a tour a beginner will start.
- **generate** names the fallback explicitly ("Use a Template … an instant starting
  point with no waiting") so the offline/keyless path reads as a choice, not a
  consolation.
- **listen** is the only step that sells a second thing (the Vibe Meter) because that
  is the moment the Vibe Meter first *does* anything.
- **shape** says "Any small edit counts" on purpose — the signal is broad, so the copy
  matches the machine.
- **done** points at two next-steps (Explain, Copilot); the card anchors on the Copilot
  chip (`.aiCopilot`), and the body carries the Explain hand-off in prose.

---

## State machine

States (`OnboardingState`, persisted):

| state | meaning | `shouldOfferTour` | terminal? |
|-------|---------|-------------------|-----------|
| `inactive` | fresh, never started (or `reset()`) — **tour eligible** | **true** | no |
| `active(stepIndex:)` | on step *i* (0…6) | false | no |
| `completed` | finished step 7 (`done`) | false | **yes** |
| `dismissed` | skipped the whole tour | false | **yes** |

Both terminals are replayable via `reset()` (→ `inactive`), the ob-b "Replay tour" seam.

Transitions (all persist through the injected backing):

| from | trigger | to |
|------|---------|-----|
| `inactive` | `begin()` | `active(0)` — `welcome` |
| `active(i)` | `advance()` | `active(i+1)`, or `completed` when *i* is the last step (`done`) |
| `active(i)`, step has a signal | `signal(s)` where `s == step.expectedSignal` | `active(i+1)` (or `completed` if it were last — no signal step is last) |
| `active(i)`, step is a task (has a signal) | `skipStep()` | `active(i+1)` |
| `active(i)` / `inactive` | `dismissTour()` | `dismissed` |
| **any** | `reset()` | `inactive` |

No-op rules (all tested):

- `signal(s)` when **not** `active`, or when `s` ≠ the active step's expected signal
  (wrong signal, or a **duplicate** arriving after the step already advanced) → ignored.
- `begin()` when not `inactive`; `advance()`/`skipStep()` when not `active` → ignored.
- `skipStep()` on `welcome` or `done` (steps with **no** signal — they carry explicit
  CTAs) → ignored. This is what distinguishes `skipStep()` (task-steps only) from
  `advance()` (the general driver, incl. `done → completed`).
- `dismissTour()` on `completed`/`dismissed` → ignored (already terminal, already
  never re-offers).

`welcome` (index 0) and `done` (index 6) have `expectedSignal == nil`; the five middle
steps each carry exactly one signal, in enum order.

---

## Signal wiring map (the ob-b contract)

The model is store-decoupled: **ob-b emits `model.signal(_:)` at these real sites.**
Each signal fires only once meaningfully — the model ignores it unless the matching
step is active. All file:line refs below are grounded in the current tree; ob-b's brief
is written from this map.

> **Design rule for ob-b:** emit each signal from a **specific UI/operation site**,
> *not* from a single global journal observer. `editPerformed` and `mixerAdjusted` both
> ultimately journal an edit (see `performEdit` below); if ob-b watched the journal
> globally, a fader move would fire `editPerformed` too and the `shape`/`mix` steps
> would collapse. Emit `editPerformed` from arrange/transport edit actions and
> `mixerAdjusted` from Mix-view mixer actions.

### 1. `projectGainedContent` — the project gained audio/track content

Two paths satisfy this step; ob-b emits from whichever the user takes.

- **Sketchpad import (primary):** a candidate flips to `.imported` at
  `Sources/DAWAppKit/SketchpadModel.swift:225` (inside `importCandidate(_:)`). The app
  triggers it from the row's onImport at `Sources/DAWApp/Sketchpad/SketchpadView.swift:252`
  (`await model.importCandidate(candidate.id)`); the store pipeline it drives is
  `ProjectStore.importGeneration` (`Sources/DAWCore/ProjectStore+Generation.swift:27`),
  wired through the app importer closure at `Sources/DAWApp/DAWProApp.swift:263-268`.
  **Emit site:** in the app after `importCandidate` returns and the candidate reads
  `.imported` (or in the `DAWProApp.swift:263-268` importer closure after
  `store.importGeneration` returns).
- **Instant template (fallback):** `ProjectStore.applySongSkeleton(genre:tempoBPM:sections:)`
  at `Sources/DAWCore/SongSkeleton.swift:301`; the control command that calls it is
  `macro.songSkeleton` at `Sources/DAWControl/Commands.swift:642-658`. **There is no UI
  trigger for the skeleton today** — ob-b adds a "Use a Template" button on the
  `generate` card that calls `store.applySongSkeleton(genre:)` and emits
  `projectGainedContent` on success.

### 2. `playbackStarted` — transport began playing

- **UI (primary):** the play button action at `Sources/DAWApp/TransportBar.swift:112`
  (`store.transport.isPlaying ? store.stop() : store.play()`). **Emit** right after the
  `store.play()` branch.
- Store method: `ProjectStore.play()` at `Sources/DAWCore/ProjectStore.swift:188`
  (idempotent — a second `play()` while already playing early-returns, so a stray emit
  is harmless).
- Control-plane equivalent (for E2E, same store call): `transport.play` at
  `Sources/DAWControl/Commands.swift:237-239`.

### 3. `editPerformed` — a project edit landed (non-mixer surface)

- **Canonical source of truth:** every undoable mutation funnels through
  `ProjectStore.performEdit(_:key:_:)` at `Sources/DAWCore/ProjectStore.swift:1944-1953`,
  which journals via `UndoJournal.recordEdit` (`Sources/DAWCore/UndoJournal.swift:68`)
  only when state actually changed; observable seam is
  `ProjectStore.canUndo` / `undoLabel` at `Sources/DAWCore/ProjectStore.swift:51`/`:55`.
- **Concrete `shape`-step emit sites** (per the copy — drag a clip / mute a track /
  nudge the tempo):
  - clip drag → the arrange clip gestures route through the store clip methods (the
    five clip mutators; `TimelineLanesView` / clip interaction layer),
  - mute a track → `Sources/DAWApp/Mixer/MixerStripView.swift:299`
    (`store.setTrackMute(...)`) — note: a mute lives in the mixer strip, but it is a
    *track state* edit the copy invites at the `shape` step; ob-b should emit
    `editPerformed` (not `mixerAdjusted`) for a mute so the `shape` step is reachable
    from a mute,
  - tempo nudge → `Sources/DAWApp/TransportBar.swift:251-252`
    (`store.setTempo(...)`).

### 4. `mixerAdjusted` — a mixer level/pan/preset moved (Mix view)

- **Fader (primary):** `Sources/DAWApp/Mixer/MixerStripView.swift:281`
  (`store.setTrackVolume(id:volume:)`); store method
  `Sources/DAWCore/ProjectStore.swift:661`.
- **Pan:** `Sources/DAWApp/Mixer/MixerStripView.swift:259`
  (`store.setTrackPan(id:pan:)`); store method `Sources/DAWCore/ProjectStore.swift:668`.
- **Mixer preset:** `ProjectStore.applyMixerPreset(trackID:presetName:)` at
  `Sources/DAWCore/MixerPresets.swift:206`; control command `mixer.applyPreset` at
  `Sources/DAWControl/Commands.swift:615-627`. **No mixer-preset UI exists today** — if
  ob-b surfaces preset-apply in the `mix` step it emits `mixerAdjusted` there too.

### 5. `renderCompleted` — a bounce/mixdown finished writing a file

- Store methods: `ProjectStore.renderBounce(...)` at
  `Sources/DAWCore/ProjectStore+Render.swift:60` (returns a `BounceResult` on success)
  and `renderMixdown(...)` (called at `Sources/DAWControl/Commands.swift:1228`).
- Control commands: `render.bounce` at `Sources/DAWControl/Commands.swift:1258-1300`,
  `render.mixdown` at `:1216`.
- **There is no export UI in DAWApp today** — ob-b builds the export affordance (an
  export sheet/button) that calls `store.renderBounce` (or `renderMixdown`) and **emits
  `renderCompleted` on the success return.** This is the one step whose UI ob-b must
  create from scratch; hence the `export` step's anchor is nil until then.

---

## Model API surface (`Sources/DAWAppKit/OnboardingModel.swift`)

`@MainActor @Observable public final class OnboardingModel`:

- `init(backing: OnboardingStateBacking? = nil)` — defaults to a non-persistent
  in-memory backing (previews/tests); the app injects the UserDefaults backing. On init
  the model **restores** `state` from the backing (mid-tour resume).
- `public private(set) var state: OnboardingState`
- `var shouldOfferTour: Bool` — `state == .inactive`
- `var currentStep: OnboardingStep?` / `var currentInfo: OnboardingStepInfo?` /
  `var stepIndex: Int?` — the active step, its catalog copy, and its index (nil unless
  active).
- `func begin()` — `inactive → active(0)`
- `func advance()` — manual next; `active(i) → active(i+1)`, or `→ completed` from `done`
- `func skipStep()` — skip a **task** step (has a signal); no-op on `welcome`/`done`
- `func signal(_ s: OnboardingSignal)` — advances **only** if `s` matches the active
  step's expected signal; otherwise a no-op
- `func dismissTour()` — `→ dismissed` (no-op on terminals)
- `func reset()` — `→ inactive` (the ob-b "Replay tour" seam)

Supporting types (same file):

- `enum OnboardingSignal: String, CaseIterable, Sendable` —
  `projectGainedContent, playbackStarted, editPerformed, mixerAdjusted, renderCompleted`.
- `enum OnboardingStep: String, CaseIterable, Sendable` —
  `welcome, generate, listen, shape, mix, export, done` (CaseIterable order **is** the
  tour order; index = position).
- `struct OnboardingStepInfo: Sendable, Equatable` —
  `{ step, title, body, cta, anchor: ExplainID?, signal: OnboardingSignal? }`.
- `enum OnboardingCatalog` — `static let steps: [OnboardingStepInfo]` (one per step, in
  order) + `static func info(for:) -> OnboardingStepInfo`. Single source of truth for
  copy **and** the per-step expected signal (the model reads it for advancement).

### Persistence (`OnboardingStateBacking`)

The `PanelDensityBacking` idiom exactly: an injected `@MainActor` protocol
(`loadState() -> OnboardingState?`, `storeState(_:)`), with an in-memory implementation
(default) and a UserDefaults implementation (the app wires this). **Key: `onboarding.state`**
(`UserDefaultsOnboardingStateBacking` default). State serializes to a compact string —
`inactive`, `active:<i>`, `completed`, `dismissed` — via `OnboardingState.persistedValue`
/ `init?(persisted:)`; a stale/corrupt `active:<i>` whose index is out of range parses
to nil and the model falls back to `.inactive` (never crashes on a bad stored value).
Onboarding progress is an **app-side preference** (like panel density), never project
data — it survives relaunch but is never written into the `.dawproj` file.

---

## ob-b handoff checklist

Everything below is **explicitly out of ob-a scope** and is ob-b's job:

- The tour **card** chrome (glass popover anchored beside the step's `anchor`; the
  ExplainCard idiom), Start/Next/Skip/Finish/Dismiss controls wired to the model API.
- The five **signal emits** at the sites in the wiring map above.
- The **export affordance** (new UI — no export control exists today) driving
  `store.renderBounce`/`renderMixdown`.
- The **"Use a Template"** skeleton button on the `generate` card (`applySongSkeleton`).
- Wiring `OnboardingModel(backing: UserDefaultsOnboardingStateBacking())` into the app,
  offering the tour on first launch when `shouldOfferTour`.
- A Settings **"Replay tour"** control calling `reset()`.
- A **control-protocol command** to drive/inspect the tour (e.g. `debug.onboarding`
  staging, the `debug.panelDensity`/`debug.explainMode` precedent) **and** a note to
  expose it in `mcp-server` (or a TODO with the exact tool name) — per the project
  every-user-facing-op rule.

---

## Addendum (ob-b, as built) — the observing-adapter deviation

ob-b **supersedes the per-site "signal emits" plan** of the *Signal wiring map* above
(the "emit `model.signal(_:)` at each real UI/operation site" design rule). Instead,
signals are fired by a single **app-side observing adapter**, `OnboardingSignalAdapter`
(DAWApp, owned by AppModel), that watches `ProjectStore` and translates its mutations
into `model.signal(_:)` calls.

**Why (orchestrator-authorized):** (ob-c) walks the tour over the **control wire**, so
every signal must fire for wire-driven actions too — not just UI clicks. Both the UI
and the wire mutate the same `@Observable` store, so observing the store ONCE catches
both, whereas per-UI-site emission would miss every wire-driven action. The model's
strict active-step matching makes firing several signals for one action benign (the map's
own point): e.g. an `applySongSkeleton` flips content **and** journals an edit, so the
adapter emits both `projectGainedContent` and `editPerformed` — only the one the active
step expects advances; the other is a tested no-op.

**How it stays faithful to the map's shape/mix warning.** The map warns that a global
journal observer would collapse `shape` (`editPerformed`) into `mix` (`mixerAdjusted`),
because both journal an edit. ob-b honors this not by per-site emission but by a pure,
tested **classifier** (`DAWAppKit.OnboardingEditClassifier`) over the new
`ProjectStore.lastEditEvent`: the level/pan/master/preset family →  `mixerAdjusted`,
everything else → `editPerformed` (**a fader move never reads as `editPerformed`** — a
mute deliberately does, so `shape` is reachable from a mute, per the map).

**Minimal DAWCore seam it observes** (added in ob-b, tested):
- `ProjectStore.lastEditEvent: EditEvent?` — `{seq, label, key}`, published inside
  `performEdit` exactly when a journal entry records (no-op edits stay silent); `seq`
  strictly increases so coalesced same-key edits still tick.
- `ProjectStore.renderCompletedCount: Int` — incremented on every successful
  `renderBounce` / `renderMixdown` return.

**Anchor change.** The `export` step's anchor is no longer nil: ob-b builds the transport
**EXPORT** affordance (`ExplainID.transportExport`) and the step now anchors on it. The
Sketchpad also gains a **"Use a Template"** button (`ExplainID.sketchpadTemplate`).

**Staging.** `debug.onboardingState {set?, signal?}` (app-level, debug tier — off
`allCommands`/MCP, the `debug.vibeSeed` precedent) forces a state and/or injects a signal
through the same `model.signal(_:)` path; it is NOT exposed as an MCP tool (tour chrome is
UI, driven by the protocol directly, not by an agent-facing tool).
