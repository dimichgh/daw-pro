# m22-b — EQ Frequency-Curve Editor: Design (daw-architect, 2026-07-20)

Roadmap item: docs/ROADMAP.md:334. Builds directly on the m22-a EQ v2 param
surface (docs/ROADMAP.md:333). Status: DESIGN SETTLED — implementation pending,
route ui-design-engineer (Phase 1 optionally audio-dsp-engineer, see §11).

---

## 1. Decision summary

1. **Response-math seam**: extract the RBJ coefficient math out of
   `EQEffect` into a new pure-`Double` DAWCore unit, **`EQFilterResponse`**
   (`Sources/DAWCore/EQFilterResponse.swift`), copied **expression-verbatim**
   (no algebraic rearrangement), consumed by BOTH `EQEffect`'s render-side
   coefficient derivation and the new curve model. One source of truth; the
   existing m22-a bit-exact null pin
   (Tests/DAWEngineTests/EQv2Tests.swift:229-241) is the refactor's
   MUST-STAY-GREEN gate and makes drift measurable to the bit. A
   predicted-vs-rendered pin (§8 F7) additionally locks the curve to the
   living DSP output, not just to a formula copy.
2. **Spectrum seam (v1)**: the master EQ editor's spectrum overlay polls the
   EXISTING master analysis (`appModel.vibeSeed ?? store.masterAnalysis()`,
   the exact `VibeMeterView` closure/`TimelineView` pattern,
   Sources/DAWApp/Components/VibeMeterView.swift:22-40). Zero engine change,
   zero render-thread change. The future per-insert tap seam is **named but
   not implemented** (§4.3): an `InsertAnalysisTapping` hook in the chain walk
   with an atomic-triple-buffer publish path — filed as follow-up m22-b-2
   with its cost argument.
3. **Interaction**: 6 fixed handles (HP/LS/P1/P2/HS/LP) as SwiftUI views over
   three Canvas layers (spectrum / grid / curves). Drag = freq(x)+gain(y),
   ⌥-drag vertical or scroll = Q, ⇧ = fine, double-click = band enable
   toggle. Every write goes through `EffectEditorModel.set` →
   `store.setEffectParam`/`setMasterEffectParam` — the exact `fx.setParam`
   twins with their per-(chain, effect, name) undo coalescing
   (Sources/DAWCore/ProjectStore.swift:1993-2016).
4. **Placement**: the curve editor becomes the eq kind's editor inside the
   existing `EffectEditorOverlay` card via a kind switch; the m22-a knob
   table stays as the card's **Pro density** (panel ID `"effectEditor"`,
   `SimpleProToggle`, chip rendered for `.eq` only — its two modes genuinely
   differ; every other kind's modes coincide and grow no chip, per the
   density law docs/DESIGN-LANGUAGE.md:23). The curve surface absorbs the
   slope chips and ON toggles into a band strip under the curve.
5. **Wire/MCP surface: NONE new.** Edits ride the pre-existing
   `fx.setParam`/`fx.describe`/`fx.setBypass`; the curve editor is a new VIEW
   of an already-agent-controllable surface (the loop-ruler
   "non-invokable pure-view surface" precedent, docs/DESIGN-LANGUAGE.md:24).
   The only new seams are app-tier `debug.*` extensions, off
   `allCommands`/MCP by convention (Sources/DAWControl/Commands.swift:123-136).
6. **Full Xcode: NOT required.** No entitlements, AUv3, or signing anywhere in
   this item — plain `swift build` + `./scripts/test.sh` + staging app.

---

## 2. Shipped state this builds on (anchors)

- **Param model**: `EQParams` v2 — 10 legacy fields + 12 additive optionals
  (Sources/DAWCore/Effects.swift:145-303). Nil semantics centralized in the
  `resolved*` accessors (Effects.swift:196-214): HP/LP `freq` nil = OFF
  (:201-206), slope nil = 12 snapped {12,24} (:194, :207-208), shelf Q nil =
  legacy `defaultShelfQ` 1/√2 (:191, :209-210), `*Enabled` nil = true
  (:211-214). Ranges: gains ±24 dB (:182), Q 0.1…18 (:183), HP 20…1000 Hz
  (:184), LP 1000…20000 Hz (:185), LS 20…2000 (:179), peaks 20…20000 (:180),
  HS 200…20000 (:181).
- **Param schema**: `EffectParamSpec.specs(for: .eq)` — 22 specs, slots 0…21,
  v2 fields APPENDED so automation slots never move
  (Effects.swift:603-672; append comment :625-626; `note` teaching key
  :583-586).
- **DSP**: `EQEffect` — 8 fixed biquad slots in series: HP cascade 0-1,
  LS/P1/P2/HS 2-5, LP cascade 6-7
  (Sources/DAWEngine/Effects/EQEffect.swift:40-46). Butterworth constants
  :48-54 (1/√2; 4th-order pair 0.5412/1.3066). Coefficient math: `setBand`
  :146-196 (legacy nil-Q shelf alpha kept VERBATIM `sinW0 / 2.0 * (2.0)
  .squareRoot()` :165-171), `setCutBand` :200-226, `setCutPair` :232-246,
  Nyquist clamp `min(freq, sampleRate * 0.49)` :151 and :203. Derivation
  entry `deriveRenderParams` :266-279 runs on the render thread ONLY on
  generation change / automation store (:18-22, :252-259, :292-321); the
  sample walk is :323-366.
- **Bit-exact pin**: `EQv2Tests` carries an in-test `LegacyEQReference`
  replica (Tests/DAWEngineTests/EQv2Tests.swift:113-210) and pins all-nil v2
  params BIT-IDENTICAL to it (:229-241), plus a goertzel measurement harness
  (:36-49) and slope/corner measurements (:257-318).
- **Knob-strip editor**: `EffectEditorModel` (headless,
  Sources/DAWAppKit/EffectEditorModel.swift) — descriptor reads via injected
  closure (:69-75, :116-119), eq group table (:156-169), the wire-identical
  apply path `set(name:value:)` (:303-315), eq value reader over `resolvedEQ`
  (:499-527), log/linear fraction math (:352-379). Rendered by
  `EffectEditorOverlay` (Sources/DAWApp/Mixer/EffectEditorOverlay.swift),
  340 pt card (:34), slope chip (:278-309), ON toggles (:241-271), presented
  from ContentView behind a live-descriptor gate
  (Sources/DAWApp/ContentView.swift:352-357).
- **Store write path**: `setEffectParam` validates the name against the spec
  table, clamps silently, coalesces under
  `fx.param:<trackId>:<effectId>:<name>`
  (Sources/DAWCore/ProjectStore.swift:1993-2016, key at :2009-2010); master
  twin `setMasterEffectParam` :1443-1465. m22-a law: enabling HP/LP with no
  corner materializes the spec default so the toggle is never a silent no-op
  (docs/ROADMAP.md:333).
- **Master analysis**: `MasterMixAnalyzer` — 24 geometric bands 40 Hz→16 kHz,
  2048-pt Hann / 1024 hop ≈ 46 frames/s
  (Sources/DAWEngine/Analysis/MasterMixAnalyzer.swift:12-15, 42-49), band
  edges public :80-83, asymmetric one-pole smoothing + decay-to-floor
  :17-21/:69-76, allocation-free feed :23-29/:232-284. Fed from the master
  chain host's post-fader tap; snapshot VALUE hops to main actor via `Task`
  (Sources/DAWEngine/AudioEngine.swift:2470-2515, hop :2511-2514), polled by
  `masterAnalysis()` :2522-2524 → `ProjectStore.masterAnalysis()`
  (Sources/DAWCore/ProjectStore.swift:1151-1152) → wire
  `mixer.masterAnalysis` (Sources/DAWControl/Commands.swift:1161-1171).
  Snapshot shape: `MasterAnalysisSnapshot`, 24 bands dB floor −80
  (Sources/DAWCore/Model.swift:1885-1917).
- **Debug tier**: app-layer `appCommandHandler`, `debug.*` EXCLUDED from
  `allCommands`/MCP (Sources/DAWControl/Commands.swift:123-136, router
  fallthrough :3778-3785; law restated docs/ARCHITECTURE.md:150). Existing
  seams this design reuses: `debug.effectEditor {open/add/param/value/close}`
  (Sources/DAWApp/DAWProApp.swift:2990-3064), `debug.panelDensity`
  (:1320-1339), `debug.vibeSeed` (:586-590, :1856-1884), `debug.captureUI`
  (:1199-1200). Settle law for gate scripts: act, wait ~250-300 ms, bare-read
  (docs/ARCHITECTURE.md:152).
- **Canvas contract (m16-a)**: renderer closures are `@Sendable`, value
  captures computed before the closure
  (Sources/DAWApp/Components/VibeMeterView.swift:43-45).

---

## 3. Q1 — Response-math seam: ONE source of truth in DAWCore

### 3.1 Decision

Create **`Sources/DAWCore/EQFilterResponse.swift`**: a pure, allocation-free,
`Double`-only unit holding (a) the RBJ coefficient math, (b) the 8-slot
section plan, and (c) magnitude-response evaluation. `EQEffect` and the curve
model both consume it. DAWCore stays headless and dependency-free — this is
plain libm math on `EQParams`, exactly the "pure domain model" charter
(CLAUDE.md Layout table).

```swift
/// Normalized biquad (a0 divided out) — POD, stack-only.
public struct EQBiquad: Sendable, Equatable {
    public var b0, b1, b2, a1, a2: Double
}

public enum EQFilterResponse {
    /// The engine's fixed slot layout, verbatim (EQEffect.swift:40-46).
    public static let sectionCount = 8
    public static let highPassSlots = 0...1
    public static let lowShelfSlot = 2, peak1Slot = 3, peak2Slot = 4, highShelfSlot = 5
    public static let lowPassSlots = 6...7
    /// Butterworth constants, moved verbatim from EQEffect.swift:48-54.
    public static let butterworth2Q = 0.7071067811865476
    public static let butterworth4QA = 0.5411961001461969
    public static let butterworth4QB = 1.3065629648763766

    /// RBJ gain band (kind: 0 lowShelf, 1 peaking, 2 highShelf). q nil on a
    /// shelf = the ORIGINAL S = 1 alpha expression VERBATIM (the null-pin
    /// contract). Expressions copied 1:1 from EQEffect.setBand
    /// (EQEffect.swift:146-196) including `min(freq, sampleRate * 0.49)`.
    public static func gainBand(kind: Int, freq: Double, gainDb: Double,
                                q: Double?, sampleRate: Double) -> EQBiquad

    /// RBJ HP/LP section at q — copied 1:1 from EQEffect.setCutBand
    /// (EQEffect.swift:200-226).
    public static func cutSection(highPass: Bool, freq: Double, q: Double,
                                  sampleRate: Double) -> EQBiquad

    /// THE render plan: fills caller-owned storage (sectionCount × 5
    /// normalized coeffs, laid out b0,b1,b2,a1,a2 per slot — EQEffect's flat
    /// `coeffs` shape, EQEffect.swift:72-73) and per-slot `active` flags,
    /// reproducing deriveRenderParams/setCutPair EXACTLY
    /// (EQEffect.swift:232-279): gain band active iff resolvedEnabled AND
    /// gainDb != 0; HP/LP active iff resolved*Enabled; slope 24 = both
    /// cascade slots at (4QA, 4QB), slope 12 = first slot only at 2Q.
    /// inout writes into preallocated arrays — NO allocation, render-safe.
    public static func fillRenderPlan(params: EQParams, sampleRate: Double,
                                      coefficients: inout [Double],
                                      active: inout [Bool])

    /// |H| in dB of one normalized biquad at frequency f (radians via
    /// w = 2π·f/fs):
    ///   num = b0²+b1²+b2² + 2(b0·b1 + b1·b2)·cos w + 2·b0·b2·cos 2w
    ///   den = 1 +a1²+a2² + 2(a1 + a1·a2)·cos w + 2·a2·cos 2w
    ///   dB  = 10·log10(num/den), epsilon-guarded, clamped to ±120, finite.
    public static func magnitudeDb(_ s: EQBiquad, frequency: Double,
                                   sampleRate: Double) -> Double

    /// The UI-facing band identity (6 logical bands over the 8 slots).
    public enum Band: String, CaseIterable, Sendable {
        case highPass, lowShelf, peak1, peak2, highShelf, lowPass
    }

    /// One logical band's response in dB at f (a cut band sums its active
    /// cascade slots; an inactive band returns exactly 0).
    public static func bandResponseDb(_ band: Band, params: EQParams,
                                      frequency: Double, sampleRate: Double) -> Double

    /// Composite response = Σ active-section dB (series filters add in dB).
    public static func responseDb(params: EQParams, frequency: Double,
                                  sampleRate: Double) -> Double

    /// The editor's log grid: `count` log-spaced Hz values over lo…hi
    /// inclusive (defaults 20…20_000, count 256).
    public static func logFrequencyGrid(count: Int, lo: Double, hi: Double) -> [Double]
}
```

`EQEffect` changes: delete its private `setBand`/`setCutBand`/`setCutPair`/
Butterworth constants; `deriveRenderParams(_ p:)` (EQEffect.swift:266-279)
becomes a single call
`EQFilterResponse.fillRenderPlan(params: p, sampleRate: sampleRate,
coefficients: &coeffs, active: &bandActive)`. The atomic-snapshot publish,
generation adoption, automation overlay, and the sample walk are UNTOUCHED
(EQEffect.swift:105-121, :252-259, :292-321, :323-366).

### 3.2 Why this preserves the m22-a bit-exactness pin

- The null pin (EQv2Tests.swift:229-241) compares `EQEffect` output against
  the in-test `LegacyEQReference` (:113-210), which this refactor does NOT
  touch — the ground truth stays independent, so any perturbation fails the
  suite immediately. The pin is the enforcement mechanism, not a casualty.
- IEEE-754 arithmetic is deterministic: Swift performs no fast-math
  reassociation, and moving an expression across a module boundary changes
  neither operation order nor rounding. `sin`/`cos`/`pow`/`squareRoot` are
  the same in-process libm calls. Bit-identical inputs through bit-identical
  expression trees give bit-identical coefficients.
- HARD RULE for the implementer: expressions are copied CHARACTER-VERBATIM —
  in particular the legacy shelf alpha `sinW0 / 2.0 * (2.0).squareRoot()`
  (EQEffect.swift:170; evaluation order (sinW0/2)·√2 is load-bearing), the
  `pow(10.0, gainDb / 40.0)` A-form (:150), and the `min(freq,
  sampleRate * 0.49)` clamp (:151, :203). No "cleanup", no Horner, no
  refactor-for-taste inside the math.
- RT-safety: `fillRenderPlan` mutates caller-preallocated arrays via `inout`
  (in-place, uniquely referenced — no CoW copy, no allocation), pure libm
  only, no locks/ObjC — the same contract the private methods satisfied
  (EQEffect.swift:32-35, :144-146).

### 3.3 Alternatives and why they lose

- **B — duplicate the math in DAWAppKit + cross-pin test.** Two sources of
  truth; the cross-pin only covers sampled param grids, so drift hides in
  untested corners (the exact place a future 48 dB/oct or new band type gets
  added to one copy and not the other). Also needs `EQEffect` internals
  exposed for coefficient comparison anyway. Loses on the one invariant the
  roadmap names: "provably never drift".
- **C — probe the engine (impulse → FFT) for the curve.** Honest by
  construction but violates layering (DAWAppKit imports only
  Foundation/Observation/DAWCore — EffectEditorModel.swift:1-3; a DAWAppKit →
  DAWEngine edge is new coupling), costs an offline render + FFT per drag
  tick, and cannot draw per-band curves without N+1 probe renders. Loses on
  cost and architecture; we keep its IDEA as the §8 F7 predicted-vs-rendered
  pin (run once in tests, not per frame).

### 3.4 Sample rate for the drawn curve

Coefficients (and therefore the true curve near Nyquist) depend on the
engine's actual rate. Neither `EngineProtocol` nor `ProjectStore` exposes it
today (verified: no `sampleRate` accessor in
Sources/DAWCore/EngineProtocol.swift). Add ONE additive engine-seam read,
the `analyzeAudioContent` additive-default precedent
(docs/ARCHITECTURE.md "Key future decisions", m21-e entry):

- `EngineProtocol`: `func renderSampleRateHz() -> Double` with a protocol-
  extension default returning `48_000` (headless/stub-safe;
  EngineProtocol.swift:755 pattern).
- `AudioEngine`: return the live output format's rate (the same value the
  meter tap reads, AudioEngine.swift:2472-2476).
- `ProjectStore`: `public func renderSampleRateHz() -> Double
  { engine?.renderSampleRateHz() ?? 48_000 }` next to `masterAnalysis()`
  (ProjectStore.swift:1151-1152).

No wire exposure (nothing user-facing changed — it is an internal honesty
read). The curve model takes it as an injected value at open time.

### 3.5 Honesty note: automation overlay not drawn

The editor draws the STORED params from the live descriptor — identical to
the knob strip (EffectEditorModel.swift:291-294). Momentary render-thread
automation overrides (EQEffect.swift:79-80, :292-321) are not visualized in
v1. Filed in §9 (follow-up F-4).

---

## 4. Q2 — Spectrum seam

### 4.1 v1 data path (master strip's EQ only — zero engine change)

- **Source**: `appModel.vibeSeed ?? store.masterAnalysis()` — verbatim the
  vibe-meter closure (VibeMeterView.swift:22-26). The master tap always runs
  (the vibe meter depends on it), so the overlay adds ZERO tap/render cost.
  Reusing the `vibeSeed` override means `debug.vibeSeed`
  (DAWProApp.swift:1856-1884) seeds deterministic spectrum captures FOR FREE.
- **Gating**: the overlay renders only when
  `model.target?.trackID == nil` (nil = master chain,
  EffectEditorModel.swift:9-17) AND `kind == .eq`. Track-strip EQ editors
  draw NO spectrum in v1 (an absent layer, not a fake one — display honesty).
- **Cadence**: its own `TimelineView(.animation(paused: controlActiveState ==
  .inactive))` wrapping ONLY the spectrum Canvas (the VibeMeterView pattern
  :36-49), so the 60 fps tick never invalidates the grid/curve/handle layers.
  Underlying data refreshes at the analyzer's ~46 frames/s
  (MasterMixAnalyzer.swift:12-13) via the existing main-actor hop
  (AudioEngine.swift:2511-2514).
- **Display smoothing** (headless, in the new `EQCurveEditorModel` file): a
  per-band asymmetric one-pole in the `VibeMeterModel.smooth` idiom
  (Sources/DAWAppKit/VibeMeterModel.swift:178-184) — attack τ 0.05 s,
  release τ 0.32 s (the house ballistics :71-74) on top of the analyzer's own
  meter ballistics, so the fill breathes instead of strobing; silence decays
  to nothing (the analyzer floors at −80,
  MasterMixAnalyzer.swift:17-21).
- **Mapping honesty**: the 24 bands are drawn at their TRUE geometric edges
  40 Hz→16 kHz (`MasterMixAnalyzer.bandEdges`, :80-83) inside the 20 Hz→
  20 kHz axis — never stretched to fill it. Band dB maps over −72…−6 dB
  (the vibe meter's punchy span precedent, VibeMeterModel.swift:59-60) to
  0…0.85 of the plot height, drawn as a bottom-anchored filled smooth path.
  The spectrum has NO y-axis relationship with the EQ-gain dB scale and gets
  no dB labels of its own — it is context, not a measurement readout
  (a one-line `.help` says so).

### 4.2 Colors (Rule 3 compliance, docs/DESIGN-LANGUAGE.md:9-15)

Spectrum fill = `signal` green at low opacity (live healthy signal
semantics); composite curve = `playback` cyan with the glow recipe (the curve
IS a gain readout — the knob strip's "cyan only for genuinely level/gain-
flavored" rule, EffectEditorOverlay.swift:22-25); per-band curves = dim
neutral white; NO violet anywhere (nothing here is AI content).

### 4.3 The FUTURE per-insert tap seam (named now, NOT built)

```swift
/// DAWEngine (follow-up m22-b-2). One per opted-in insert instance.
protocol InsertAnalysisTapping: AnyObject {
    /// RENDER THREAD, called from the chain walk immediately after (or
    /// before — pre/post is a v2 decision) the target insert's process().
    /// Contract: no allocation, no locks, no ObjC, bounded work per call.
    func consume(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int)
    /// Main-actor poll. Reads a lock-free published snapshot.
    func snapshot() -> MasterAnalysisSnapshot   // reuse the 24-band shape
}
```

- **Hook point**: the chain walk in `EffectChainProcessor.process`
  (Sources/DAWEngine/Effects/EffectChainProcessor.swift:334-343) /
  `ChainEffectUnit.processActive` (:175) — the unit already owns per-insert
  identity and preallocated scratch (:44-51), so a tap slots in as one more
  preallocated member armed at snapshot-build time (main actor), consumed in
  the walk.
- **Why deferred (the honest cost argument)**: the master path rides
  AVFoundation's serial TAP queue — off the render thread — and publishes via
  `Task { @MainActor }` (AudioEngine.swift:2481-2514). A per-insert tap runs
  ON the render thread, where BOTH of those are forbidden: (a) the
  `Task`-based publish allocates → it needs a new preallocated
  triple-buffer/seqlock publish (the `daw_atomic_ptr` retire-bin idiom,
  EQEffect.swift:56-121, but with fixed inline band storage instead of a
  heap array — `MasterMixAnalyzer.snapshot()`'s 24-element array (:290-292)
  is main-actor-tier and may NOT be called render-side); (b) the FFT cost
  (2048-pt Hann + vDSP, ~10-20 µs/hop on Apple Silicon) lands in the render
  budget — fine for 1-2 instances, needs an explicit budget/opt-in policy
  ("analysis armed only while that editor is open") before N strips × FFT is
  honest; (c) per-instance state is ~100 KB (ten fftSize/half buffers,
  MasterMixAnalyzer.swift:106-117). None of this is hard; all of it is real
  engineering that would have doubled m22-b. v1 keeps the render thread
  untouched — the invariant wins.

---

## 5. Q3 — Interaction model

### 5.1 Plot geometry (headless, `EQCurveGeometry` in DAWAppKit)

- x: log₂ frequency, fixed domain 20 Hz → 20 kHz (≈ 9.97 octaves).
  `x = width · log(f/20) / log(20000/20)`; inverse for hit/drag. (The fixed
  editor axis is deliberately NOT `EffectEditorModel.Scale`'s per-spec range
  mapping (:352-379) — every band shares one axis; per-spec clamping still
  applies on write.)
- y: linear dB, domain −24…+24 (`EQParams.gainDbRange`, Effects.swift:182),
  0 dB center line. Curves that plunge past −24 (HP/LP skirts) clip at the
  plot edge.
- Grid: horizontal hairlines every 6 dB (labels ±6/±12/±18, SF Mono,
  `textDim`); vertical hairlines at 20/50/100/200/500/1k/2k/5k/10k/20k with
  labels ("100", "1k", "10k") — beginner-readable, no scientific notation.
- Curve sampling: `EQFilterResponse.logFrequencyGrid(count: 256, 20, 20000)`,
  composite + up to 6 band curves; recompute only when `resolvedEQ` or the
  sample rate changes (Observation-driven — the view reads the descriptor
  through the model, so a wire `fx.setParam` moves the curve live, the
  EffectEditorModel live-read law :69-72).

### 5.2 Handles

Six fixed handles (the shipped topology — band add/remove is out, §9):

| Band | x | y | Drag x | Drag y | ⌥-drag / scroll | Double-click |
|---|---|---|---|---|---|---|
| LS, P1, P2, HS | freq | gainDb | freq (clamped to that band's spec range, Effects.swift:179-181) | gainDb ±24 | Q (log: `Q·2^(−dy/48pt)`, scroll `Q·2^(Δy·0.05)`, clamp 0.1…18) | toggle `*Enabled` |
| HP, LP | resolvedFreq | pinned to 0 dB line | freq (HP 20…1k, LP 1k…20k, Effects.swift:184-185) | — (ignored) | — (slope lives in the band strip chip) | toggle `*Enabled` |

- A DISABLED band's handle renders as a dim hollow ring at its stored
  position (`resolved*Freq` puts an OFF HP/LP at its range edge,
  Effects.swift:203-206); double-click re-enables — writing
  `highPassEnabled = 1` materializes the default corner per the m22-a
  never-a-silent-no-op law (docs/ROADMAP.md:333).
- Visual: 12 pt filled dot + SF Mono micro-tag (HP·LS·1·2·HS·LP), 28 pt hit
  target (generous, beginner rule). Rest = neutral white; hovered = bright;
  dragged/selected = cyan + glow (earned active state); disabled = dim
  hollow. Selected band's own curve brightens; others stay dim.
- Modifiers: ⇧ = fine (0.25× drag rate — ⌥ is TAKEN by Q per the roadmap
  spec, a deliberate, documented deviation from the knob ⌥-fine convention
  (docs/DESIGN-LANGUAGE.md:21); the footer hint teaches it).
- Keyboard (P2 within the flight, cuttable): with a selected handle,
  ←/→ = ∓1/12 octave, ↑/↓ = ±0.5 dB, with ⇧ = 1/48 octave / 0.1 dB.
- While dragging: an SF Mono readout chip near the handle —
  `"1.02 kHz · +3.5 dB · Q 1.4"` (the `EffectEditorModel.readout` formats,
  :428-480, reused for consistency).

### 5.3 Layering (what is Canvas, what is SwiftUI)

Bottom → top inside the plot area:
1. **Spectrum Canvas** (master EQ only) — own `TimelineView`, §4.1.
   `.allowsHitTesting(false)`.
2. **Grid Canvas** — redraws on size change only. `.allowsHitTesting(false)`.
3. **Curves Canvas** — per-band dim curves + glowing composite (glow recipe:
   wide faint bloom under a crisp core stroke, docs/DESIGN-LANGUAGE.md:15).
   Redraws on param change via Observation, NEVER on a timeline tick.
   `.allowsHitTesting(false)`. All three obey the m16-a `@Sendable`
   value-capture contract (VibeMeterView.swift:43-45).
4. **Handle layer** — six SwiftUI views `.position()`-ed by the model, owning
   hover/drag/double-click/scroll gestures, `.help` tooltips, and
   accessibility (`.accessibilityValue` = the readout string). One
   transparent full-plot gesture surface underneath resolves scroll-over-plot
   to the hovered/selected band.

Hit-testing rule: nearest handle center within 28 pt wins; ties break to the
smaller-Q (harder-to-grab) band; empty-plot double-click is a no-op in v1.

### 5.4 Write-through (UI == wire, undo)

Every edit calls `EffectEditorModel.set(name:value:)`
(EffectEditorModel.swift:303-315) — the SAME injected
`store.setEffectParam`/`setMasterEffectParam` closures the knob strip and the
wire's `fx.setParam` use (:51-58; ProjectStore.swift:1993-2016, :1443-1465).
Consequences, stated honestly:

- Coalescing is per (chain, effect, name) (`fx.param:…`,
  ProjectStore.swift:2009-2010): a freq-only or gain-only drag is ONE undo
  step; a diagonal drag writes two names → TWO undo steps. **Accepted for
  v1** (zero new store surface, identical semantics to scrubbing two knobs).
  Follow-up F-2 (§9) files the batched
  `setEffectParams([(name, value)])`-under-one-key refinement.
- Double-click toggle writes `*Enabled` 0/1 through the same path (the m22-a
  toggle convention, EffectEditorOverlay.swift:241-271).
- The model clamps to the spec range before applying and the store clamps
  again (belt-and-suspenders, EffectEditorModel.swift:303-315).
- Drag tick rate = gesture callback rate (~display rate); each tick is one
  `set` per changed name — the knob strip already sustains this per-tick
  store-edit cadence by design (EffectEditorOverlay.swift:16-19).

### 5.5 Band strip (absorbing the m22-a chips)

A compact strip under the plot: six band cells —
color-consistent micro-tag + name, ON toggle (the m22-a toggle idiom), and
for HP/LP the 12/24 slope chip (EffectEditorOverlay.swift:278-309 reused
verbatim). Clicking a cell selects that band (sync with handle selection).
The strip + the drag readout + the footer hint line
("Drag a handle to shape · ⌥-drag or scroll for width (Q) · double-click a
handle to switch its band off") carry the beginner-readability duty
(EffectEditorOverlay.swift:114-118 precedent).

### 5.6 New headless model

`Sources/DAWAppKit/EQCurveEditorModel.swift` — `@MainActor @Observable`,
constructed over the existing `EffectEditorModel` (same module; tests build
that with fake closures, the established pattern):

- Pure static: `EQCurveGeometry` (freq↔x, dB↔y, grid line positions, label
  strings), handle layout from `EQParams` + resolved accessors, hit-testing,
  drag/scroll/keyboard → `[(name, value)]` deltas, Q log-mapping, per-band
  freq-range clamps, curve path point generation from `EQFilterResponse`.
- Stateful: `selectedBand`, `hoveredBand`, `dragReadout`, injected
  `sampleRate`, the spectrum display smoother (§4.1).
- ALL writes route through `EffectEditorModel.set` — the model owns zero
  store access of its own.

---

## 6. Q4 — Editor placement and density switching

- **Mechanism: kind check, not a registry.** Inside `EffectEditorOverlay`,
  `model.kind == .eq` switches the card body to the curve surface; every
  other kind renders the knob card unchanged. One built-in editor card
  exists (ContentView.swift:352-357); a per-effect editor registry buys
  nothing until a second custom editor exists (YAGNI — revisit if m22-e's
  compressor GR view wants one; noted in §9 F-5).
- **Fallback density = the knob table.** The card adopts the house
  `SimpleProToggle` with panel ID `"effectEditor"`
  (`PanelDensityStore`-backed, app-sticky, never project data —
  docs/DESIGN-LANGUAGE.md:23): **Simple = curve editor (default)**, the
  direct-manipulation beginner-visual surface; **Pro = the m22-a 6-section
  knob table** (exact numeric control, all 22 params). The chip renders ONLY
  when `kind == .eq` — for every other kind the modes coincide and the
  density law forbids a do-nothing toggle (docs/DESIGN-LANGUAGE.md:23).
  Using the density store (vs a local CURVE/KNOBS chip) buys persistence and
  the existing `debug.panelDensity` staging seam for free
  (DAWProApp.swift:1320-1339).
- **Card size**: eq-curve mode widens the card to 560 pt (plot ≈ 528×260 +
  header + band strip + footer, total ≈ 430 pt tall); knob mode and all
  other kinds keep 340 pt (EffectEditorOverlay.swift:34) and the existing
  hugging-height math (:68-78). Still the same centered in-window dark-glass
  modal — `debug.captureUI` snapshots it (the captureUI law,
  EffectEditorOverlay.swift:8-11).
- The curve surface ABSORBS the slope chips and ON toggles (§5.5); the knob
  table keeps its own copies (it is the fallback, complete on its own).

---

## 7. Q5 — Wire/MCP surface (none new) and debug seams

- **Expected wire/MCP delta: ZERO.** The user-facing CAPABILITY — reading and
  writing every EQ parameter, with teaching notes — already ships as
  `fx.describe` / `fx.setParam` / `fx.setBypass` (+ MCP twins), which is how
  the "every capability = command + tool + test" convention is satisfied
  here: the curve editor is a new SURFACE over the same capability, the
  loop-ruler non-invokable-pure-view precedent (docs/DESIGN-LANGUAGE.md:24).
  No renames, no additive commands. (The §3.4 `renderSampleRateHz` engine
  read is internal — not a command.)
- **Debug seams (app tier, OFF `allCommands`/MCP,
  Commands.swift:123-136)** — extensions to EXISTING commands only:
  1. `debug.effectEditor` state response gains, when the open card is an eq:
     `editorMode` (`"curve"`/`"knobs"`), `selectedBand`, and — when the
     caller passes optional `probeHz: [Double]` — `responseDb: {"<hz>": dB}`
     computed through the SAME `EQFilterResponse` call the Canvas draws
     (numeric E2E without pixel-parsing). Bare call stays read-only
     (the m11-a law, DAWProApp.swift:2999-3000).
  2. `debug.panelDensity {panel: "effectEditor", mode: …}` flips
     curve↔knobs — already exists, nothing to build (:1320-1339).
  3. `debug.vibeSeed` already stages a deterministic spectrum (§4.1) — reused
     as-is (:1856-1884).
  4. `debug.captureUI` frames the card as today (in-window modal law).

---

## 8. Q6-adjacent — Accuracy fixtures and performance targets

### 8.1 Response-math unit pins (`Tests/DAWCoreTests/EQFilterResponseTests.swift`)

Closed-form RBJ identities (exact, tolerance ±0.001 dB unless stated):

- **F1 peaking exact-at-fc**: peaking 1 kHz, +6 dB, Q 1 → response at fc =
  **+6.000 dB exactly** (|H(f₀)| = A² is an algebraic identity of the RBJ
  peaking form). Also −6 dB → −6.000. Log-symmetry: response at fc/2 vs 2·fc
  equal within ±0.02 dB.
- **F2 cut corners exact**: HP 12 dB/oct @ 100 Hz → −3.0103 dB at fc
  (|H(f₀)| = Q = 1/√2 identity); HP 24 @ 100 Hz → −3.0103 at fc
  (0.5412·1.3066 = 1/√2, the 4th-order Butterworth property); same pins for LP
  @ 2 kHz. Tolerance ±0.005 dB (warping at these fc/fs is < 0.001).
- **F3 slope attenuation, matching the m22-a MEASURED numbers**
  (docs/ROADMAP.md:333, EQv2Tests.swift:257-318): HP @ 100 Hz at 50 Hz =
  −12.30 dB (slope 12) / −24.10 dB (slope 24), ±0.05; LP @ 2 kHz at 4 kHz
  −12.59/−24.70 ±0.1 (warping included, same in-test tolerance philosophy).
- **F4 shelf plateau + midpoint**: LS 200 Hz +6 dB (nil Q) → +6.00 ±0.1 at
  20 Hz, 0.00 ±0.05 at 20 kHz, **+3.00 ±0.05 at fc** (RBJ shelf half-gain
  midpoint); mirror for HS. Nil-Q vs explicit Q=0.7071067811865476 produce
  identical curves within 1e-9 (the `defaultShelfQ` equivalence,
  Effects.swift:189-191).
- **F5 neutrality/bypass**: all-default params → 0.000000 dB at every grid
  point (no active sections, exact zero); a band with `*Enabled = false` or
  gain exactly 0 contributes exactly 0 (mirrors the DSP skip law,
  EQEffect.swift:24-30, :148).
- **F6 plan equivalence**: `fillRenderPlan` marks active slots exactly per
  the resolved semantics for a matrix of params (HP off/12/24, each band
  on/off/0 dB), and slot coefficients equal `gainBand`/`cutSection` outputs
  bit-for-bit.

### 8.2 Anti-drift pin (`Tests/DAWEngineTests/EQResponsePinTests.swift`)

- **F7 predicted-vs-rendered**: rich param set (HP 24 @ 120, LS −4 @ 150 Q 2,
  P1 +5 @ 800 Q 3, P2 −6 @ 2.5 k Q 0.8, HS +3 @ 8 k, LP 12 @ 12 k); render
  sines at 10 log-spaced frequencies through the REAL `EQEffect` using the
  existing goertzel harness (EQv2Tests.swift:36-49, :246-256) and assert
  |`EQFilterResponse.responseDb` − measured| ≤ **0.1 dB** per frequency.
  This is the "provably never drifts from the engine" gate: the curve is
  pinned to the living DSP output.
- **F8 the standing null pin**: `EQv2Tests` entire suite green UNCHANGED —
  explicitly listed as a gate criterion of the refactor (the
  bit-exact fingerprint law, EQv2Tests.swift:229-241).

### 8.3 Model/UI pins (`Tests/DAWAppKitTests/EQCurveEditorModelTests.swift`)

- Geometry round-trips: x↔freq (log) and y↔dB exact at edges/center; 1 kHz
  sits at x/width = log(50)/log(1000) ≈ 0.566.
- Handle layout from params incl. disabled/nil states (`resolved*` reads,
  Effects.swift:196-214); OFF HP handle at 20 Hz dim-hollow.
- Drag → writes: a (dx, dy) on P1 emits `peak1Freq`+`peak1GainDb` clamped to
  spec ranges; HP drag emits freq only; ⌥-drag/scroll emits `peak1Q` with
  the log law and 0.1…18 clamp; ⇧ scales rates; double-click emits
  `*Enabled` flip; all THROUGH a recorded fake `EffectEditorModel` apply
  closure (the established fake-store pattern).
- Wire-parity: a recorded drag's writes replayed via `fx.setParam` yield the
  identical descriptor (UI == wire seam).
- Spectrum display: smoother attack/release asymmetry, decay-to-zero on
  floor snapshots, band-edge x mapping vs `MasterMixAnalyzer.bandEdges`
  (:80-83), the −72…−6 span mapping.
- Density/selection: chip only for `.eq`; selection sync handle↔strip.

### 8.4 Performance targets (numeric)

- Full recompute (composite + 6 band curves, 256-pt grid, ~8 sections):
  **< 1 ms** budget on the main actor per param change; expected < 100 µs
  (≈ 50 k flops). Measure once in a test with `ContinuousClock` and assert
  the 1 ms bound (generous, CI-safe).
- Drag write path: ≤ 2 store edits per gesture tick (freq+gain), each the
  existing per-tick knob cost — no new store mechanism.
- Spectrum layer: 24-band smoothing + one filled path per frame ≤ 0.5 ms;
  isolated `TimelineView` so param layers never redraw at 60 fps; paused
  when the window is inactive (VibeMeterView.swift:36-39).
- **Render thread: ZERO change in behavior or cost** — same coefficient math
  on the same adoption-only trigger (EQEffect.swift:20-22), no new taps, no
  allocation/locks anywhere near it (the constitution's non-negotiable).

---

## 9. Scope fence — v1 cuts, each argued

- **C-1 Per-track/per-insert spectrum tap** → follow-up **m22-b-2** (§4.3
  protocol + hook + cost argument already written down). Cut because it is
  the only part of m22-b that touches the render thread, and it deserves its
  own budget/publish design rather than riding a UI milestone.
- **C-2 Batched multi-param undo** (`setEffectParams` under one coalescing
  key so a diagonal drag is ONE undo step) → small store follow-up; v1's
  two-step undo is identical to scrubbing two knobs and zero new surface.
- **C-3 Solo-band audition** (Pro-Q's headphone-band) — needs new DSP state
  (a render-side band-solo flag) and an engine param not in `EQParams`;
  entirely separable.
- **C-4 Automation-overlay visualization** (curve following momentary
  automated values) — needs a render→UI param feedback path that does not
  exist for ANY effect; out (matches the knob strip's honest behavior today,
  §3.5).
- **C-5 Dynamic EQ / match-EQ** — new DSP / belongs with reference-track
  m22-g (docs/ROADMAP.md:339) respectively.
- **C-6 A/B preset slots** — a generic insert-preset concern
  (MixerPresets.swift exists in DAWCore); not EQ-specific.
- **C-7 Band add/remove (dynamic band count)** — the shipped DSP is a fixed
  8-slot topology (EQEffect.swift:40-46) and the param surface is flat named
  fields (Effects.swift:127-129); variable bands are a param-model break, not
  an editor feature.
- **C-8 Spectrum peak-hold/freeze, piano-key axis underlay** — polish
  candidates once the surface exists.
- **F-5 (note, not cut)**: if m22-e's compressor editor also goes custom, THEN
  introduce the per-kind editor registry; today's kind-check stands.

---

## 10. Failure modes and mitigations

- **Bit-drift in the extraction** (the big one): mitigated by
  expression-verbatim copying (§3.2 hard rule) and CAUGHT deterministically
  by F8 (the untouched in-test legacy replica) + F7. If F8 ever fails during
  Phase 1, the refactor is wrong — fix the extraction, never the pin.
- **Curve lies near Nyquist at non-48 k rates**: mitigated by §3.4
  `renderSampleRateHz`; headless/stub sessions honestly fall back to 48 k.
- **Editor open during `fx.remove`**: already handled — the card renders only
  while the descriptor resolves (ContentView.swift:352-357,
  EffectEditorOverlay.swift:50-52); the curve surface inherits the gate.
- **60 fps spectrum tick invalidating the whole card**: prevented by
  structure — the spectrum owns its private `TimelineView` (§5.3); a
  regression here shows up as param-layer redraw churn; the capture gate's
  smoothness eyeball plus Instruments-spot-check if suspected.
- **Store-edit flood during drags**: bounded by gesture-tick cadence, same as
  knobs; coalescing keys keep the journal at one entry per name per drag
  (ProjectStore.swift:1989-1991).
- **Q-scroll hijacking window scroll**: the scroll gesture attaches to the
  plot area only, and only acts when a band is hovered/selected; otherwise
  the event falls through.
- **Two-undo diagonal drag surprising users**: footer-adjacent honesty; F-2
  filed; explicitly accepted.
- **npm-suite tempo-lint scans Swift sources** (env lore): engine/core edits
  can regress the npm suite — the gate runs BOTH suites, always.

---

## 11. Implementation plan (for ui-design-engineer)

Three phases, one flight each; Phase 1 is core/engine-touching and may be
delegated to audio-dsp-engineer if preferred — its gate is entirely
mechanical (suite-green + new pins).

### Phase 1 — the shared response math (DAWCore + EQEffect refactor)

Files:
- NEW `Sources/DAWCore/EQFilterResponse.swift` (§3.1 API; expressions copied
  verbatim from EQEffect.swift:146-246; slot layout + Butterworth constants
  move here).
- MOD `Sources/DAWEngine/Effects/EQEffect.swift`: delete private math
  (:48-54, :146-246); `deriveRenderParams` (:266-279) → one `fillRenderPlan`
  call into the preallocated `coeffs`/`bandActive` (:72-75). NOTHING else
  changes.
- MOD `Sources/DAWCore/EngineProtocol.swift` + `Sources/DAWEngine/AudioEngine.swift`
  + `Sources/DAWCore/ProjectStore.swift`: additive `renderSampleRateHz()`
  with 48 k default (§3.4).
- NEW `Tests/DAWCoreTests/EQFilterResponseTests.swift` — F1…F6.
- NEW `Tests/DAWEngineTests/EQResponsePinTests.swift` — F7.

Gate: `./scripts/test.sh` FULLY green including the UNCHANGED `EQv2Tests`
(F8) — if the null pin moves, stop and fix the extraction. npm suite green
(tempo-lint lore). No wire snapshot diffs.

### Phase 2 — the headless editor model (DAWAppKit)

Files:
- NEW `Sources/DAWAppKit/EQCurveEditorModel.swift` (§5.6: `EQCurveGeometry`
  statics, handle layout/hit-test/drag/scroll/keyboard math, selection state,
  spectrum display smoother §4.1; all writes via the wrapped
  `EffectEditorModel`).
- NEW `Tests/DAWAppKitTests/EQCurveEditorModelTests.swift` — §8.3 list, plus
  the < 1 ms recompute bound (§8.4).

Gate: suite green; zero imports beyond Foundation/Observation/DAWCore
(the DAWAppKit purity law, EffectEditorModel.swift:1-3).

### Phase 3 — the view, placement, and debug seams (DAWApp)

Files:
- NEW `Sources/DAWApp/Mixer/EQCurveEditor.swift` — plot (3 Canvas layers +
  handle layer, §5.3), band strip (§5.5), drag readout, footer hint; glow
  recipe + Rule 3 colors (§4.2); m16-a `@Sendable` Canvas contract.
- MOD `Sources/DAWApp/Mixer/EffectEditorOverlay.swift` — kind switch, 560 pt
  eq-curve card width, `SimpleProToggle` (panel `"effectEditor"`, eq-only
  chip), knob table as Pro density (§6).
- MOD `Sources/DAWApp/DAWProApp.swift` — extend `effectEditorDebug`
  (:2990-3064): `editorMode`/`selectedBand` in the state echo; optional
  `probeHz` → `responseDb` via `EQFilterResponse` (§7.2.1).
- MOD `docs/ROADMAP.md` (tick m22-b at close), `CHANGELOG`, and
  `docs/ARCHITECTURE.md` "Key future decisions" (add the settled entry:
  response-math seam = DAWCore `EQFilterResponse` shared by engine + UI,
  bit-exactness preserved under the standing null pin; per-insert spectrum
  tap = named `InsertAnalysisTapping` seam, deferred with cost argument,
  master-analysis reuse for v1 — pointer to this doc).

Tests (app tier rides the headless models — no new UI-test framework):
- Extend `Tests/DAWAppKitTests/EQCurveEditorModelTests.swift` if any
  view-motivated math lands during build-out (the math must live in the
  model, not the view — enforced by review).

### Gate script outline (staging 17695 ONLY — never 17600; PIDFILE-exact kill)

1. Build staging app; `project.new {discardChanges: true}`.
2. `fx.add {trackId: "master", kind: "eq"}` → capture effect id.
3. `debug.effectEditor {open: true, trackId: "master"}`; settle 300 ms
   (docs/ARCHITECTURE.md:152).
4. `debug.panelDensity {panel: "effectEditor", mode: "simple"}` → curve mode.
5. Shape a curve over the WIRE (UI==wire seam): `fx.setParam` ×N —
   HP 24 @ 80 Hz enabled, P1 +6 @ 1 kHz Q 1, HS −3 @ 8 kHz, LP off.
6. `debug.effectEditor {probeHz: [100, 1000, 10000]}` → assert `responseDb`
   equals the F1/F3 expectations within ±0.05 dB and `editorMode == "curve"`.
7. `debug.vibeSeed {bands: <pink-ish 24-band shape>}`; settle;
   `debug.captureUI` → EYEBALL: green spectrum under glowing cyan composite,
   six labeled handles (LP dim-hollow at 20 kHz), band strip chips, grid
   labels, readability.
8. `debug.effectEditor {param: "peak1GainDb", value: -6}` (the open-card
   apply path) → bare-read echoes the new value; capture again → curve dipped.
9. `debug.panelDensity {panel: "effectEditor", mode: "pro"}` → capture →
   the m22-a knob table intact (fallback density regression).
10. `edit.undo` twice → `fx.describe` confirms per-name undo granularity.
11. `./scripts/test.sh` AND npm suite both green (both-suites law).

---

## 12. Convention checklist

- Control command / MCP tool / test convention: SATISFIED by the existing
  `fx.*` surface (§7) — no new wire/MCP entries; new tests per §8.
- Swift 6 strict concurrency: models `@MainActor @Observable`; Canvas
  closures `@Sendable`; render thread untouched.
- DAWCore stays headless/dependency-free (`EQFilterResponse` is pure libm);
  DAWEngine specifics stay behind `AudioEngineProtocol` (one additive
  default-implemented read, §3.4).
- Design language: Rule-3 semantic colors only (§4.2), glow earned by state,
  SF Mono readouts, beginner hint line, generous hit targets, density law
  respected (§6).
- debug.* stays off `allCommands`/MCP (§7).
