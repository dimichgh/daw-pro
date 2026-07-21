# m22-g — Reference-Track Workflow: Design (daw-architect, 2026-07-20)

Competitive anchor: EchoJay's "Reference Tracks" / "AI Compare" / "A/B" — designed natively here, not cloned.
Roadmap line: docs/ROADMAP.md:339. This document is the implementation contract for three single-agent
flights (P1 domain/persistence/analysis, P2 engine routing/A-B, P3 UI/copilot — §10). Nothing in this
design requires full Xcode: every render-side element is a stock AVAudioNode (player + mixers), no
entitlements, no AUv3, no signing.

## 1. Decision summary

| # | Question | Decision |
|---|---|---|
| D1 | Where the reference lives | A dedicated project SLOT — `ProjectStore.reference: ReferenceSlot?` mirrored by additive-optional `ProjectDocument.reference` and `ProjectSnapshot.reference`. NEVER a `Track`. Bounce/stems/mixdown exclusion is by construction: every offline path walks `tracks` and the slot is not in it. |
| D2 | One-time analysis | On import, engine-side streaming analyzer (`ReferenceAnalyzer`): integrated LUFS / max momentary / max short-term / true peak / LRA via the SAME `Loudness.Stream` code path as `Loudness.measure` (fp-identical family, m22-c convergence gate); average 24-band spectrum via the SHARED `MasterMixAnalyzer.bandEdges` fold already used by `AudioContentAnalyzer` (extract, never fork); whole-file stereo width/correlation/balance as pure DAWCore running-sum math (`StereoImage.measure`). Persisted in the slot, `analyzerVersion`-tagged. |
| D3 | Graph placement | A permanent, live-only MONITOR LANE inside the one playback engine: `masterChainHost → mixMonitorGate → monitorSum → outputNode` with `referencePlayer → referenceGain → monitorSum`. Built by `ensureMasterSandwich` under a new `referenceLaneEnabled` flag, DEFAULT FALSE — only the live `AudioEngine` enables it, so `OfflineRenderer`'s fresh graphs never contain the lane and all offline byte-invariants hold BY CONSTRUCTION. |
| D4 | A/B semantics | `reference.setMonitor {on}`: post-chain mix gate (`mixMonitorGate.outputVolume` 1→0) + reference scheduled on its own player. Mutually exclusive monitoring; transient state (never persisted, never undoable — the transport analogy). |
| D5 | Level match | Exact law in pure DAWCore `ReferenceLevelMatch` (§5.6): `gain = (mixLiveIntegrated ?? −14.0) − refIntegrated + trimDb`, clamped so `refTruePeak + gain ≤ −1.0 dBTP`. Snapshot at toggle-ON, never chased during audition. Basis + clamp surfaced honestly (`matchBasis`, `ceilingLimited`). |
| D6 | Transport | The reference FOLLOWS the timeline (start/stop/seek/restart seams) with a persisted `offsetSeconds`; file time = timeline seconds + offset. Toggle-ON mid-play re-anchors player-locally (the metronome enable-mid-play precedent). Loop wrap: v1 free-runs across a wrap while B is held; every toggle-ON re-anchors correctly (metronome-style loop unroll is the filed follow-up §11.1). |
| D7 | PDC | The reference anchor is DELAYED by `outputLatencySamples` (T + B + master, the m13-d D5 report field) at schedule time — control-plane math only, so A and B arrive time-aligned at the ear. Master-chain PDC stays report-only; no plan input changes. |
| D8 | Meters while B | Master meters/live loudness/analyzer KEEP reading the MIX — the tap stays at `masterChainHost` output, UPSTREAM of the gate (§5.5). Honesty is carried by an explicit REF-monitoring indicator, not by rewiring meters. |
| D9 | Wire/MCP | 8 additive commands in a new `reference.*` namespace (§6): import/remove/status/analyze/setMonitor/setOffset/setTrim/compare + 8 mechanical-rule MCP tools. allCommands 144→152, MCP 147→155. |
| D10 | UI | Master strip gains ONE compact 25 pt REFERENCE row shown only when a slot exists (respects the strip height budget); everything else — import, analysis readouts, spectrum overlay, deltas, offset/trim — lives in a dedicated dark-glass REFERENCE panel (EffectEditorOverlay idiom). No violet anywhere: a reference is user-chosen material, not AI. Unpaused `.periodic` polls (m22-e law). |
| D11 | Copilot | All 8 commands join `CopilotToolCatalog` with a taught "compare my mix to the reference" workflow; ~4 Explain entries. |

## 2. Shipped state this builds on (anchors — grepped, not guessed)

- **Master sandwich (m13-d §1-B)**: `mainMixerNode → masterChainHost → outputNode`, path comment
  `Sources/DAWEngine/PlaybackGraph.swift:299`; `outputNode` has a SINGLE input bus (`:327` — the
  documented tradeoff that forces a summing node for any second audible source);
  `masterChainHost` at `:332`; `ensureMasterSandwich()` at `:1712` (idempotent, fresh-nodes-only,
  never sets `needsEngineRebuild`), gated by `masterSandwichEnabled` (`:378`, guard `:1713`),
  connected to `outputNode` at `:1727`. Master fader = `mainMixerNode.outputVolume`, PRE-chain
  (docs/ARCHITECTURE.md:544).
- **Offline isolation**: `OfflineRenderer` builds its OWN engine + `PlaybackGraph`
  (`Sources/DAWEngine/OfflineRenderer.swift:236` and `:451`) and copies `masterSandwichEnabled`
  explicitly (`:245`, flag `:85`). A flag it does NOT copy defaults off in its graphs — the lever D3 uses.
- **PDC**: staged global-max plan, master chain latency REPORT-ONLY, summed into
  `outputLatencySamples = T + B + master` (docs/ARCHITECTURE.md:543, m13-d D5). The whole mix lands
  uniformly `outputLatencySamples` late against the ruler — the quantity D7 compensates.
- **Strip invariant (M12-f)**: "one MAIN audio input per strip, plus at most one KEY input"
  (docs/ARCHITECTURE.md:541). §5.2 argues the monitor lane against it.
- **Loudness homes**: offline `Loudness.measure(_ audio: RenderedAudio)`
  (`Sources/DAWCore/Loudness.swift:227`, detached wrapper `:605`), additive `loudnessRangeLu`
  (`:29`/`:79`); live `Loudness.Stream` + `LiveLoudnessSnapshot` (`:63`), held fp-identical to
  `measure()` by the m22-c in-suite convergence gate (≤ 1e-9, TP bit-exact) — the property D2 leans on.
  Live read path: `AudioEngineControlling.liveLoudness(reset:)` (`Sources/DAWCore/EngineProtocol.swift:660`,
  headless default nil `:825`) → `ProjectStore.liveLoudness` (`Sources/DAWCore/ProjectStore.swift:1179`)
  → `mixer.liveLoudness` (`Sources/DAWControl/Commands.swift:297`, router `:1185-1203` — including the
  `engineUnavailable` honesty refusal this design reuses).
- **Spectrum geometry home**: `MasterMixAnalyzer` — 2048-pt Hann / 1024 hop, 24 geometric bands of
  [40, 16000] Hz (`Sources/DAWEngine/Analysis/MasterMixAnalyzer.swift:12-14`, `fftSize:62`,
  `bandCount:66`); `AudioContentAnalyzer` already folds a mean power-DENSITY spectrum into
  `MasterMixAnalyzer.bandEdges` (`Sources/DAWEngine/Analysis/AudioContentAnalyzer.swift:232-276`) —
  the fold D2 extracts into one shared home (the m22-b `EQFilterResponse` extraction precedent).
- **Stereo-image home (m22-d)**: live ballistic correlation/width/balance in `MasterMixAnalyzer`
  (τ 300 ms, dead-channel snap +1, floors +1/0/0 — `MasterMixAnalyzer.swift:23-40`). D2's offline
  aggregates are a DIFFERENT quantity (no ballistics) with a cross-consistency pin (§9 T6).
- **Engine analysis seam precedent (m21-e)**: `analyzeAudioContent` on `AudioEngineControlling`
  (`Sources/DAWCore/EngineProtocol.swift:301` protocol, method `:354`, THROWING default `:752` —
  "a fabricated empty analysis would be a lie"). D2 adds a sibling with the same shape.
- **Persistence precedents**: `ProjectDocument` (`Sources/DAWCore/ProjectDocument.swift:12`) with
  additive-optional omit-when-empty fields (`masterEffects?:56`, `copilotChats?:70` + lossy decode
  counter `:73`); `ProjectSnapshot` mirror (`Sources/DAWCore/Model.swift:1704`, `masterEffects:1714`
  — the m12-f three-surface mirror-DTO discipline). Media bundling:
  `ProjectBundle.planMedia(tracks:bundleURL:)` (`Sources/DAWCore/ProjectBundle.swift:116`) called from
  `ProjectStore.saveProject` (`Sources/DAWCore/ProjectStore.swift:4740`, call `:4776`) — tracks-only
  today, gains an additive parameter (§3.3). Stable pre-save home precedent: the generation-imports
  directory comment (`ProjectStore.swift:321`).
- **File-facts seam**: `MediaImporting.audioFileInfo(at:)` (`Sources/DAWCore/MediaImporting.swift:7`)
  — DAWCore stays engine-free; the AVAudioFile-backed implementation lives in DAWEngine.
- **Single-player mid-roll anchor precedent**: the metronome enable-mid-play re-anchor
  (`Sources/DAWEngine/AudioEngine.swift:358`, `:2382`; docs/ARCHITECTURE.md:240 "toggle =
  click-player-local stop/re-anchor, transport untouched") — exactly the mechanism D6 reuses for
  toggling B during playback.
- **Master strip real estate**: `Sources/DAWApp/Mixer/MixerStripView.swift:519-557` — fader block
  `minHeight 180` (`:531`), `MasterLoudnessReadout` (`:535`, view `:742`), `MasterStereoImageBlock`
  (`:544`). The strip is already at its height budget — D10 adds one conditional 25 pt row, nothing more.
- **Debug seed precedent**: `debug.scopeSeed` staging (`Sources/DAWApp/DAWProApp.swift:608` region),
  app debug tier, off `allCommands`/MCP.
- **Copilot catalog**: `Sources/DAWControl/CopilotCatalog.swift` (header contract: one `CopilotTool`
  per exposed command, dotted→underscore names, parity test-asserted).
- **RT-safety law**: docs/ARCHITECTURE.md:36-52 (Tier 1/Tier 2, the three sanctioned crossing shapes,
  documented-exception list). This design adds ZERO render-thread code — §5.7 audits it.
- **Control-plane tempo law (m22-f)**: tempo math is resolved on the control plane only
  (docs/ARCHITECTURE.md:541, DelayTempoSync entry). All reference scheduling math is control-plane
  beats→seconds via the tempo map integrals (§5.4).

## 3. Q1 — Model & persistence: the dedicated slot

### 3.1 Decision

New file `Sources/DAWCore/Reference.swift`:

```swift
public struct ReferenceAnalysis: Codable, Sendable, Equatable {
    public var integratedLufs: Double?        // nil = gated-silent program (JSON has no −inf)
    public var maxMomentaryLufs: Double?
    public var maxShortTermLufs: Double?
    public var truePeakDbtp: Double?          // 4× oversampled, Annex 2 (Loudness home)
    public var loudnessRangeLu: Double?       // EBU 3342
    public var bandsDb: [Double]              // exactly MasterAnalysisSnapshot.bandCount (24), floor −80
    public var correlation: Double            // whole-file aggregate, −1…+1, dead-channel/mono = +1
    public var width: Double                  // Σside² / (Σmid² + Σside²), 0…1
    public var balance: Double                // (ΣR² − ΣL²) / (ΣL² + ΣR²), −1…+1
    public var durationSeconds: Double
    public var sampleRateHz: Double
    public var analyzerVersion: Int           // = ReferenceAnalyzer.version (1)
}

public struct ReferenceSlot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String                   // display name, defaults to the file's basename
    public var sourcePath: String             // absolute in memory; save rewrites to bundle media/ path
    public var offsetSeconds: Double          // file time = timeline seconds + offsetSeconds; default 0
    public var trimDb: Double                 // user trim on top of the match law; default 0, clamp ±24
    public var analysis: ReferenceAnalysis?   // nil until analyzed / after a failed analysis
}
```

Held as `ProjectStore.reference: ReferenceSlot?` (nil = no reference). It is PROJECT DATA:
import/remove/analyze/offset/trim are journaled edits (`performEdit`, §3.4); the A/B monitor state is
NOT (transient, like `isPlaying` — the "transient state never persists" law, docs/ARCHITECTURE.md:258).

**Exclusion by construction.** `render.mixdown`/`render.bounce`/`render.stems`/`bounceTrackInPlace`
and `StemPlan` consume `tracks` (+ `masterEffects`); the slot is not a track, so no exclusion flag,
no filter, no new code path exists to get wrong. `Σ stems ≡ mixdown` and byte-identical bounce are
untouched at the MODEL level; §5 keeps them untouched at the GRAPH level too.

### 3.2 Persistence (tolerant, additive)

- `ProjectDocument` gains `public var reference: ReferenceDocument?` (mirror DTO in
  `ProjectDocument.swift`, beside `masterEffects?` `:56`) — omit-when-nil, NO schemaVersion bump.
  Pre-m22-g saves re-encode byte-identical (pinned, §9 T1).
- **Tolerant decode**: decode the sub-tree via a lossy wrapper — a corrupt/unknown-shape `reference`
  value decodes to nil plus a load WARNING (the `copilotChats` lossy-decode precedent,
  `ProjectDocument.swift:70-73`); it never fails the open. A `bandsDb` of the wrong count sanitizes to
  nil-analysis with a warning (the m13-d hand-edited-load sanitize precedent).
- `ProjectSnapshot` gains the additive `reference` mirror (`Model.swift:1704`) so `project.snapshot`
  exposes the slot to agents — the m12-f three-surface mirror-DTO discipline (Model + Document +
  Snapshot land together in P1, never drift).

### 3.3 File handling (the MediaImporting precedent)

- **Import copies, never moves** (the SoundBank/VoiceDataset law): `reference.import` copies the
  source file into `~/Library/Application Support/DAWPro/References/` (uniquified on collision), the
  stable pre-save home (the generation-imports precedent, `ProjectStore.swift:321`), and probes
  duration/rate/channels via `ProjectStore.media` (`MediaImporting.audioFileInfo`,
  `MediaImporting.swift:7`).
- **Save folds it into the bundle**: `ProjectBundle.planMedia` gains an additive parameter —
  `planMedia(tracks:reference:bundleURL:)` with `reference: ReferenceSlot? = nil` so existing call
  sites compile unchanged — and the reference file joins the URL-keyed dedupe/copy/rewrite into
  `media/` exactly like clip audio (`ProjectBundle.swift:116`; call site `ProjectStore.swift:4776`).
  In-memory `sourcePath` rewrites to the bundle path at save, resolves relative at load (the clip
  URL mechanism verbatim).
- **Missing file at load** is NOT an error: the slot (and its persisted analysis) survive;
  `reference.setMonitor`/`reference.analyze` refuse with a verbatim teaching error
  (`referenceFileMissing`, naming the path and `reference.import` as the fix) — honest absence,
  never a silent drop.
- Autosave snapshots serialize the slot verbatim with absolute refs, zero copies (the crash-b law).

### 3.4 Store surface (`Sources/DAWCore/ProjectStore+Reference.swift`, all @MainActor)

| Method | Edit label / key | Notes |
|---|---|---|
| `importReference(path:name:) async throws -> ReferenceSlot` | `performEdit("Import Reference")` | copy → probe → analyze (engine seam §4.2; analysis failure lands the slot with `analysis: nil` + a warning in the result, the sanitized-load idiom) → set slot (replacing any existing in the SAME edit; one undo restores the prior slot) |
| `removeReference() throws` | `performEdit("Remove Reference")` | empty slot → `referenceNotSet` teaching error |
| `analyzeReference() async throws -> ReferenceAnalysis` | `performEdit("Analyze Reference")` | re-runs on demand (missing/stale/analyzer-version-bumped analysis) |
| `setReferenceOffset(seconds:) throws` | key `reference.offset` (coalesced) | if monitoring & playing → single-player re-anchor (§5.4) |
| `setReferenceTrim(db:) throws` | key `reference.trim` (coalesced) | clamp ±24; if monitoring → recompute + re-apply match gain (§5.6) |
| `setReferenceMonitor(on:) throws -> ReferenceMonitorResult` | NOT journaled | transient; requires slot + analysis with `integratedLufs` + live engine (§5.6 refusal ladder) |
| `referenceStatus() -> …` | read-only | slot + monitor state + would-be match gain |
| `referenceCompare() throws -> …` | read-only | assembles mix live numbers + slot analysis + deltas (§6) |

**Undo journal**: P1 MUST verify the `performEdit` snapshot capture includes the new field and pin
undo-restores-slot (import → undo → nil; remove → undo → slot back, analysis included).

**Recording guard**: none of these verbs is announce-capable (the lane is permanent, §5.1), so all
stay legal mid-record per the m13-c doctrine — `requireRoutingMutationAllowed` is NOT extended.
Import's file copy + analysis run detached off the main actor (the m10-n detached-load precedent).

### 3.5 REJECTED alternatives (slot placement)

- **A hidden `Track` (kind or flag) in `tracks[]`** — REJECTED. Exclusion stops being "by
  construction": `StemPlan`, mixdown, snapshot, mixer UI, solo math, sends, automation, take
  machinery all walk `tracks` and would each need a correctness-critical exclusion branch; one
  missed consumer ships the reference into a client's master. It also drags the slot into strip
  invariants (M12-f) it must never participate in. This is precisely what the roadmap line forbids.
- **App-side preference (UserDefaults) instead of project data** — REJECTED. A reference is part of
  the project's creative context ("mix this song against THAT record"); it must travel with the
  `.dawproj`, survive relaunch on another machine, and be agent-visible in `project.snapshot`.
  Preferences are for panel density, not material.

## 4. Q2 — One-time offline analysis

### 4.1 What is measured (and which home owns each number)

| Quantity | Home | Reuse |
|---|---|---|
| Integrated LUFS, max momentary/short-term, true peak, LRA | DAWCore `Loudness.Stream` (`Loudness.swift:63` family) | fed chunk-wise on a worker; fp-identical to `Loudness.measure` by the m22-c convergence gate — the reference's LUFS and `render.measureLoudness`'s LUFS are THE SAME MATH by construction |
| Average 24-band spectrum | `MasterMixAnalyzer.bandEdges` geometry | extract the mean power-DENSITY fold (`AudioContentAnalyzer.swift:232-276`) into a shared internal helper (e.g. `SpectrumBandFold` in DAWEngine/Analysis) consumed by BOTH `AudioContentAnalyzer` and `ReferenceAnalyzer` — the m22-b ONE-home extraction rule; `AudioContentAnalyzer` output must stay bit-identical (pinned §9 T5) |
| Stereo correlation / width / balance | NEW pure DAWCore `StereoImage.measure` (small unit in `Reference.swift` or its own file) | whole-file running sums (Pearson r, side/mid energy ratio, R²−L² balance); mono/dead-channel = +1 correlation, width 0 — the m22-d floor conventions. The LIVE ballistic home stays `MasterMixAnalyzer` untouched; a cross-consistency pin ties them on steady signals (§9 T6) |

### 4.2 Engine seam (`Sources/DAWEngine/Analysis/ReferenceAnalyzer.swift`)

Additive method on `AudioEngineControlling` (`EngineProtocol.swift:301`):

```swift
func analyzeReferenceFile(at url: URL) async throws -> ReferenceAnalysis
```

with a THROWING default (the m21-e `analyzeAudioContent` precedent, `EngineProtocol.swift:752`) — a
headless engine never fabricates an analysis. Implementation: AVAudioFile decode in bounded chunks
(64 k frames, Float32 deinterleaved) feeding (a) `Loudness.Stream`, (b) the shared band fold's frame
accumulator (2048/1024 Hann, mean power density per band over the whole file), (c) `StereoImage`
running sums — **streaming, never a full-file buffer** (a 10-minute 48 k stereo file would be
~230 MB whole; chunked it is a few hundred KB resident). Runs entirely on the control plane
(detached worker) — zero render-thread contact. NaN/Inf frames are skipped whole (the
MasterMixAnalyzer poison rule). No cache: the result persists in the project; re-analysis is a rare
explicit verb (unlike m21-e's per-edit windowed analysis, so `AudioAnalysisCache` is NOT reused —
deliberate).

### 4.3 REJECTED alternatives (analysis)

- **Reuse `clip.analyzeAudio` / `AudioContentAnalyzer` wholesale** — REJECTED as the surface (it
  returns key/tempo/chroma and NO LUFS/TP/LRA/stereo; bolting loudness on would bloat every clip
  analysis) but its band fold is REUSED via extraction. Key/tempo of the reference are a cheap
  follow-up on the same seam (§11.4).
- **Analyze in DAWCore from a file URL** — REJECTED: DAWCore is dependency-free and cannot decode
  audio files (the `MediaImporting`/TransientAnalyzer boundary). Buffers-in math (Loudness,
  StereoImage) stays DAWCore; decode + FFT (vDSP) stay DAWEngine.
- **Live-tap "learn" pass (play the reference through the meter)** — REJECTED: minutes-long,
  transport-entangled, and poisons the live mix meters' accumulation. Offline is seconds-class and
  deterministic.

## 5. Q3 — Graph placement & A/B monitoring

### 5.1 Decision: a permanent, live-only monitor lane in the ONE playback engine

```
mainMixerNode ──► masterChainHost ──► mixMonitorGate ──┐
 (master fader,      (m13-d §1-B,       (AVAudioMixerNode,  ├──► monitorSum ──────► outputNode
  PRE-chain)          built-ins)         outputVolume 1|0)  │    (AVAudioMixerNode,
                                                            │     unity, graph fmt)
referencePlayer ────► referenceGain ────────────────────────┘
(AVAudioPlayerNode,    (AVAudioMixerNode: SRC from file rate
 schedules the ref      — the sumMixer precedent — plus
 file, control-plane    outputVolume = level-match gain)
 anchored)
```

- Created inside `ensureMasterSandwich()` (`PlaybackGraph.swift:1712`) under a new
  `PlaybackGraph.referenceLaneEnabled` flag, **DEFAULT FALSE**; only the live `AudioEngine` sets it
  true at graph creation. `OfflineRenderer` builds its own graphs (`OfflineRenderer.swift:236`,
  `:451`) and never touches the flag → **no reference node ever exists in an offline render**: the
  m12-b anchor SHAs, byte-identical bounce, and `Σ stems ≡ mixdown` survive by construction, not by
  filtering. (It also does not copy the flag the way it copies `masterSandwichEnabled` at `:245` —
  default-off is the fail-safe direction.)
- The lane is **permanent for the life of a live graph**: import/remove/toggle NEVER mutate topology,
  so nothing here is announce-capable — no `willMutateRoutingTopology`, no engine rebuild, legal
  mid-play and mid-record (m13-c untouched). The m13-d creation-site pins extend verbatim: single
  creation site, idempotent, fresh-nodes-only, never sets `needsEngineRebuild`.
- With the flag FALSE the sandwich keeps today's exact shape (`chainHost → outputNode`, `:1727`);
  with it TRUE the mix path gains two series unity mixers post-chain. `outputNode` still has exactly
  one input (`monitorSum`) — the single-input-bus constraint (`:327`) is why a summing node exists
  at all.
- **All mutable state is param-class**: `mixMonitorGate.outputVolume` (1 = hear mix, 0 = hear ref)
  and `referenceGain.outputVolume` (level-match linear gain) are the SAME node-level property the
  strip faders and send gains already trust — main-actor sets, no snapshot republish, no atomics,
  no new render code.
- `engine.rebuildEngine(reason:)` cold-builds → the lane is recreated by `ensureMasterSandwich` and
  the store re-pushes slot + monitor state (the taps/metronome re-wire precedent).

### 5.2 Why this does NOT violate the M12-f strip invariant

"One MAIN audio input per strip, plus at most one KEY input" (docs/ARCHITECTURE.md:541) governs
STRIPS — nodes that carry a `ChainHostAU`, participate in sends/solo/automation/PDC alignment, and
appear in the stem partition. The monitor lane is none of these: it has no chain host, no sends, no
solo/mute participation, no automation lanes, no stem identity; it enters the graph at `monitorSum`,
DOWNSTREAM of the last strip summing point AND of the master chain; no strip reads it and it reads
no strip (unlike a sidechain key edge). It is monitor furniture in the same category as the
metronome's click player — with the deliberate difference that the click feeds `mainMixerNode`
PRE-chain (it is part of the mix program) while the reference feeds POST-chain because the spec
requires it to bypass the master chain. Strip independence is untouched.

### 5.3 PDC interaction

The mix reaches the ear `outputLatencySamples` (= T + B + master, docs/ARCHITECTURE.md:543) late
against the ruler; the reference lane has zero processing latency. At schedule time the control
plane therefore anchors the reference `outputLatencySamples / graphRate` seconds LATER than the
naive timeline anchor, so A and B present the same musical moment. This is pure control-plane
arithmetic on an existing REPORT field — the master chain's PDC contribution stays report-only
(m13-d D5) and no plan input, ring target, or render-side quantity changes. A chain edit mid-B moves
`outputLatencySamples` while the reference keeps its old anchor: ms-class misalignment accepted
until the next toggle/restart re-anchor (documented; a recompute-triggered re-anchor is a one-line
follow-up if it ever matters — §11.6).

### 5.4 Transport follow, offset, loop

- **Mapping law**: reference file time `f(t) = t_timeline_seconds + offsetSeconds`, where timeline
  seconds come from the tempo-map integrals on the CONTROL plane (the m22-f law: the render thread
  never does tempo math). Negative `f` → the player's start is deferred until `f = 0`.
- **Scheduling is monitor-gated**: the reference player is scheduled ONLY while monitoring is ON.
  OFF = never scheduled — the m19-f schedule-gated ledger then guarantees the player costs zero
  start/stop handshakes and never posts warnings (docs/ARCHITECTURE.md:177-188).
- **Toggle ON while playing**: player-local schedule + re-anchor — the metronome enable-mid-play
  mechanism verbatim (`AudioEngine.swift:358`, `:2382`; one player, the historic 0.06 s lead).
  Toggle OFF: player-local stop. The transport, strip players, and roll anchor are untouched.
- **Toggle ON while stopped**: monitor state arms; the reference is scheduled at the next transport
  start. Stopped = silent (the reference follows the transport strictly; free-audition preview is
  §11.3).
- **Restart-class seams** (seek, stop, tempo/track edits, loop-bounds edits): the reference player
  joins `stopAllPlayers`/`startAllPlayers` and is re-scheduled in the same pass when monitoring is
  ON — one hook beside the metronome's in the schedule path, control-plane only.
- **Loop wrap (v1 honesty)**: the reference does NOT join the m14 gapless unroll. Holding B across a
  wrap lets the reference free-run linearly (documented in the panel's Explain copy); every
  toggle-ON re-anchors to the correct mapped position — and rapid A/B toggling IS the actual usage
  gesture, so each B engagement is correctly placed. Metronome-style per-cycle unroll on the
  reference player is the filed follow-up (§11.1) with the eager-queue-law cost argument.

### 5.5 Meters while auditioning B — the mix meters keep reading the MIX

Decision: the master meter tap + `MasterMixAnalyzer` + `Loudness.Stream` stay where m13-d put them —
at `masterChainHost`'s output, now UPSTREAM of `mixMonitorGate`. While B is engaged the meters,
live loudness, GR ladders, and the vibe/scope views continue to read the still-rolling mix. Argued:

1. **The level-match basis must survive auditioning.** The match law reads the mix's live gated
   integrated (§5.6). If the reference program fed the same `Loudness.Stream`, every audition would
   blend the reference into the mix's integrated reading — corrupting the very number the feature
   depends on, and every other consumer of `mixer.liveLoudness` besides.
2. **The reference's numbers are already known.** Its loudness/spectrum/stereo are measured ONCE and
   persisted (§4); the comparison panel shows them side-by-side with the live mix. A live meter of a
   static file we already measured adds nothing but ambiguity.
3. **Honesty is carried explicitly, not by rewiring**: while B is engaged the master strip's REF
   chip is cyan-lit + glowing and the panel states MONITORING: REFERENCE (user language, the m10-q
   register law). The LOUDNESS/STEREO IMAGE blocks are mix instruments and keep saying so.

REJECTED: switching the tap to `monitorSum` output ("meter what you hear") — it poisons the
integrated basis (1), turns every meter into a mode-dependent instrument (agents polling
`mixer.liveLoudness` mid-audition would silently read reference data), and moves a settled m13-d
seam for zero information gain.

### 5.6 The level-match law (exact; pure DAWCore `ReferenceLevelMatch`)

```
inputs:  mixIntegratedLufs : Double?   // ProjectStore.liveLoudness().integratedLufs (gated, m22-c)
         refIntegratedLufs : Double    // slot.analysis.integratedLufs (refusal below if nil)
         refTruePeakDbtp   : Double    // slot.analysis.truePeakDbtp (0.0 assumed if nil — conservative)
         trimDb            : Double    // slot.trimDb, clamp ±24

constants: fallbackTargetLufs = −14.0      // the streaming convention render_bounce already teaches
           ceilingDbtp        = −1.0      // the house true-peak ceiling default (M5 iv-d)

law:     basis          = mixIntegratedLufs ?? fallbackTargetLufs
         requestedDb    = (basis − refIntegratedLufs) + trimDb
         headroomDb     = ceilingDbtp − refTruePeakDbtp
         matchGainDb    = min(requestedDb, headroomDb)
         ceilingLimited = matchGainDb < requestedDb
         matchBasis     = mixIntegratedLufs != nil ? "liveIntegrated" : "fallbackTarget"
         linearGain     = pow(10, matchGainDb / 20)     // → referenceGain.outputVolume
```

- **Snapshot at toggle-ON** (and re-applied on `setTrim` while monitoring): the gain NEVER chases
  the evolving live integrated during an audition — a drifting gain would corrupt the comparison
  mid-listen. The next toggle-ON picks up the newer basis.
- **No mix reading yet** (fresh session, meter reset, or nothing played): basis = −14.0 LUFS,
  surfaced as `matchBasis: "fallbackTarget"` and spoken in the panel ("No mix loudness yet — the
  reference is matched to −14 LUFS. Play your mix to match against it."). REJECTED: unity gain
  (G = 0) as the fallback — playing a mastered reference at full loudness against an unmastered mix
  is exactly the louder-sounds-better trap this feature exists to kill.
- **Ceiling clamp**: matching UP (quiet reference / loud mix) can push the reference's true peak
  over full scale; the clamp keeps `refTP + gain ≤ −1.0 dBTP` and reports `ceilingLimited: true`
  (the `render.bounce` `limitedByCeiling` honesty precedent). Static gain shifts BS.1770 gated
  integrated by exactly the gain (block loudness is linear in signal power; only blocks straddling
  the −70 absolute gate can wobble the result by ≪ 0.1 LU) — so the law is analytically honest, and
  §9 T8 measures it anyway.
- **Refusal ladder for `setMonitor {on:true}`** (each a verbatim teaching error): no slot →
  `referenceNotSet` (points at `reference.import`); slot without analysis → `referenceNotAnalyzed`
  (points at `reference.analyze`); `integratedLufs == nil` → `referenceSilent` (a gated-silent file
  cannot be level-matched); file missing on disk → `referenceFileMissing`; headless/fake engine →
  `engineUnavailable` (the `mixer.liveLoudness` honesty precedent, `Commands.swift:1185` region — a
  monitor is never faked).

### 5.7 RT-safety & failure-mode audit

- **Zero new Tier-1 code**: player + mixers are stock AVAudioNodes; every mutable quantity is a
  main-actor `outputVolume` or a control-plane schedule. No allocation, locks, atomics, or tempo
  math on the render thread. No new documented-exception entries needed.
- **Transparency risk (the load-bearing gate)**: two series unity mixers post-chain must be
  audibly AND numerically transparent. Gate: a `MasterSandwichTransparencyTests`-style A/B — the
  same session manual-rendered through lane-off vs lane-on graphs (reference silent), byte-identical
  expected (§9 T7). Known theoretical wrinkle: a summing mixer can flip `−0.0` samples (minted by
  fade-out multiplies) to `+0.0`. If T7 hits exactly that, compare bit-patterns modulo zero-sign and
  DOCUMENT it here as the accepted delta; if T7 fails beyond zero-sign, FALLBACK LADDER: (1) create
  the lane only while a reference slot exists (import/remove become rebuild-class — rare, ~140 ms +
  ~6 ms/player, m18-c cost model — and no-reference projects keep the exact historic path); (2) if
  even that fails, promote REJECTED-alternative B (§5.8, separate audition engine). Both fallbacks
  preserve every offline invariant unchanged.
- **A/B click**: `outputVolume` flips may click (AVFoundation's internal ramping is unspecified) —
  accepted v1, the fx-bypass "toggles click" precedent; a short dual-gate crossfade is §11.5.
- **Sample-rate mismatch**: `referenceGain` performs SRC from the file's processing format to the
  graph format — the per-strip sumMixer precedent (docs/ARCHITECTURE.md:541), zero custom code.
- **Device rate change / config recovery**: the lane rides the existing rebuild path (§5.1 last
  bullet); the m19-k device-rate machinery sees only stock nodes.
- **Watchdog/telemetry**: reader-side only, unaffected; the reference player adds one player to the
  m18-c per-player cost model ONLY while monitoring (scheduled) — the ledger skip covers it otherwise.

### 5.8 REJECTED alternatives (graph placement)

- **B — separate audition `AVAudioEngine`** (the InputCapture side-by-side precedent): strongest
  rival — zero master-path risk, invariants by construction. LOSES on: (1) a SECOND output engine's
  full lifecycle (device change, config recovery, watchdog, teardown discipline) duplicated for one
  feature; (2) transport mirroring (start/stop/seek/loop) becomes app-glue with ms-jitter against a
  render clock we don't share scheduling with; (3) the mix mute must then happen PRE-chain
  (composing a gate into `mainMixerNode.outputVolume`), which pumps master-chain dynamics on every
  toggle-back and makes the GR/loudness meters read a gated feed — collapsing the §5.5 meters
  decision. KEPT as the named fallback of last resort (§5.7).
- **C — reference into `mainMixerNode` (pre-chain)**: the reference would pass through the master
  chain — violates the spec outright, and the mix's limiter/EQ would color the reference, making the
  comparison meaningless.
- **D — per-input volumes on one post-chain mixer** (instead of the series `mixMonitorGate`):
  requires `AVAudioMixingDestination`, rejected as under-proven at M4 (i), and reintroduces the
  m13-d C0 per-input scaling accumulation trap. Node-level `outputVolume` on series unity mixers is
  the trusted primitive.
- **E — reference as a master insert ("Metric-AB shape")**: puts file playback inside an effect's
  render context (file I/O on the render thread — a Tier-1 violation by construction) and buys a
  plugin-shaped UX we don't need — we own the DAW.
- **F — app-side `AVAudioPlayer`** (the Sketchpad candidate-preview shape): no timeline sync, no
  level-locked toggle, no PDC alignment — right for candidate previews, wrong for a monitor tool.

## 6. Q4 — Wire/MCP surface (ADDITIVE-ONLY: new `reference.*` namespace, nothing renamed/moved)

Eight commands (`Sources/DAWControl/Commands.swift`, `allCommands` `:153` → 144 + 8 = **152**), every
mutating verb with `rejectUnknownKeys` naming all valid keys, every response threading the model's
own Codable (`ReferenceSlot`/`ReferenceAnalysis` encode verbatim — the take.* can-never-drift rule).
MCP tools follow the mechanical rule cleanly (no Table-A override needed), each with `.strict()` zod
(server.ts:92-105 wrapper): **147 + 8 = 155 tools**.

| Command | Params | Response (result) | MCP tool |
|---|---|---|---|
| `reference.import` | `path` (required, absolute audio-file path), `name?` | the full slot: `{id, name, path, offsetSeconds, trimDb, analysis?, warnings?}` — `analysis` omitted + `warnings` naming the cause when analysis failed (slot still lands; `reference.analyze` retries) | `reference_import` |
| `reference.remove` | — | `{removed: true, name}` | `reference_remove` |
| `reference.status` | — | `{reference?, monitoring, matchGainDb?, matchBasis?, ceilingLimited?}` — `reference` omitted when no slot; match fields present only while monitoring (plus a `wouldMatchGainDb?` preview when a computable slot exists); read-only, never throws | `reference_status` |
| `reference.analyze` | — | the fresh `ReferenceAnalysis` | `reference_analyze` |
| `reference.setMonitor` | `on` (required bool) | `{monitoring, matchGainDb?, matchBasis?, mixIntegratedLufs?, referenceIntegratedLufs?, ceilingLimited?}` (match fields only when `on`) | `reference_set_monitor` |
| `reference.setOffset` | `seconds` (required number) | slot echo | `reference_set_offset` |
| `reference.setTrim` | `db` (required number, ±24) | slot echo + `{matchGainDb?}` when monitoring | `reference_set_trim` |
| `reference.compare` | — | `{mix: {integratedLufs?, maxTruePeakDbtp?, loudnessRangeLu?, width?, correlation?, bandsDb?}, reference: {…the stored analysis…}, delta: {lufs?, truePeakDb?, lra?, width?, correlation?, bandsDb?}}` — delta = reference − mix per field, each omitted when the mix side lacks evidence (nil-tolerant, the m22-c omission law) | `reference_compare` |

- `reference.compare`'s mix side reads `ProjectStore.liveLoudness()` (integrated/TP/LRA) and
  `masterAnalysis()` (bands/width/correlation). Headless/fake engine → `engineUnavailable` verbatim
  (floors would fake deltas — the m22-c "a live meter is never faked" law). The response documents
  that mix `bandsDb` are the recent live spectrum (ballistic) vs the reference's whole-file average —
  the schema description teaches an agent to poll during steady playback of a representative section.
- `reference.setMonitor` refusal ladder: §5.6. `reference.import` file errors surface the
  `MediaImporting` error verbatim.
- Monitor state is NEVER in `project.snapshot`'s persisted fields; `ProjectSnapshot.reference`
  carries the slot only (transient-state law).
- Teaching-error additions to `ProjectError` (`MediaImporting.swift:14` enum): `referenceNotSet`,
  `referenceNotAnalyzed`, `referenceSilent`, `referenceFileMissing` — each naming the fixing verb.
- ARCHITECTURE.md bookkeeping at each phase close: the command-count paragraph (`:61`), a new
  `reference.*` wire paragraph, and — when the design lands — a SETTLED entry under "Key future
  decisions" (`:161`).

REJECTED surface shapes: a single `reference.set {…}` mega-verb (the house style is per-property
verbs with coalescing undo keys — `track.setVolume` precedent); overloading `mixer.*` (the slot is
project material, not console state); making `reference.import` async-job-shaped (analysis is
seconds-class, not minutes — the render.measureLoudness blocking precedent + the MCP
`LONG_RUNNING_COMMANDS` 180 s allowance cover it; add `reference.import` to that allowlist in
`mcp-server/src/` alongside the render verbs).

## 7. Q5 — Comparison surface (DESIGN-LANGUAGE)

### 7.1 Master strip: ONE conditional 25 pt row (the height-budget answer)

The master strip already carries fader (minHeight 180, `MixerStripView.swift:531`) + LOUDNESS
(`:535`) + STEREO IMAGE (`:544`) — it cannot afford a spectrum overlay. The strip gets exactly one
compact row, rendered ONLY when a reference slot exists (zero cost for every project without one),
placed after `MasterStereoImageBlock` (order: LOUDNESS / STEREO IMAGE / REFERENCE), both densities
(an A/B listening check is beginner-relevant — the stereo block's "phone speaker" argument):

- `REF` micro-label (SF Mono 9 pt, `textSecondary`) + the reference name tail-truncating.
- A **MIX | REF** toggle chip pair (the `SimpleProToggle` active-half idiom): REF half **cyan-lit +
  glowing while monitoring** — an earned ACTIVE state (Rule 3: cyan = active; NEVER violet — a
  reference is user-chosen material, not AI content).
- While monitoring: an SF Mono match-gain readout ("−6.2 dB", cyan — dB readouts are cyan);
  `ceilingLimited` tints it amber with a plain-language tooltip.
- Clicking the label/row opens the REFERENCE panel. The row carries `.explainable(.referenceRow)`.

### 7.2 The REFERENCE panel (dedicated surface — the roadmap's "consider a panel" branch, taken)

A centered dark-glass card over a scrim (the AU-picker/EffectEditorOverlay idiom — in-window, so
`debug.captureUI` can snapshot it), ~520 × 420 pt. Anatomy top→bottom:

1. **Header**: neutral waveform glyph + "REFERENCE" + name + close ✕. No violet edge (contrast with
   the Sketchpad family — this panel is not an AI surface).
2. **Empty state**: beginner copy ("Compare your mix against a finished song you trust.") + a full
   `IMPORT REFERENCE…` button (NSOpenPanel → `store.importReference`; import copies, never moves).
3. **Loaded state**: file name + duration/rate line (SF Mono) + quiet REPLACE / REMOVE verbs
   (REMOVE red only on hover-confirm — the chat-delete in-row idiom, never a system alert).
4. **A/B cluster**: the big MIX | REF chip pair (same component as the strip row — ONE shared
   control, ONE Explain id), the match-gain readout + basis line in plain language: "Matched to your
   mix's loudness" / "No mix loudness yet — matched to −14 LUFS. Play your mix to match against it."
   / amber "Turned down to protect your speakers" when `ceilingLimited`.
5. **OFFSET / TRIM**: cyan SF Mono steppers (numbers are cyan, the Sketchpad length-stepper rule);
   offset teaches itself ("line the reference's chorus up with yours").
6. **SPECTRUM overlay** (Canvas, ~180 pt tall): the reference's 24-band average as a NEUTRAL WHITE
   filled-under polyline (static material, no glow — never glow static chrome), the live mix bands as
   a CYAN glowing polyline (the active signal), log-x on the shared band geometry. The mix side is
   EMA-smoothed app-side (τ ≈ 2.5 s) and labeled "MIX (recent average)" so a ballistic snapshot is
   never passed off as an average — the honesty note from §6.
7. **DELTA row**: Δ LUFS / Δ TRUE PEAK / Δ LRA / Δ WIDTH / Δ CORR in SF Mono, sign explicit,
   neutral color (no green/red verdicts v1 — a delta is information, not a judgment), "—" where the
   mix lacks evidence. Beginner sub-caption per m22-e's plain-language convention ("your mix is
   2.1 loudness units quieter than the reference").

Poll cadence: **unpaused `.periodic` TimelineView** for the mix curve + deltas (the m22-e LAW —
meters keep ticking when the app isn't frontmost; control-driven captures depend on it). Density:
COINCIDENT by design — no SIMPLE/PRO chip (record the verdict in
docs/research/simple-pro-inventory.md, the "never a do-nothing toggle" rule).

### 7.3 Headless models + debug seam

- `Sources/DAWAppKit/ReferencePanelModel.swift`: panel state machine (empty / importing / analyzing
  / ready / fileMissing), match-basis + delta formatting (nil-tolerant), EMA smoothing, refusal
  surfacing VERBATIM (the one-vocabulary law). The `SketchpadModel`/`StereoScopeModel` precedent —
  injected providers, no UI import.
- `Sources/DAWAppKit/ReferenceSpectrumGeometry.swift` (or a section of the model): band→x log
  mapping, dB→y, polyline points — the `EQCurveEditorModel`/`StereoScopeModel` geometry precedent.
- `debug.referenceSeed {slot?, analysis?, monitoring?, matchGainDb?, ceilingLimited?, panel?}` —
  app debug tier in `DAWProApp.swift` (the `debug.scopeSeed` precedent, `:608` region), OFF
  `allCommands`/MCP, bare call read-only (the m11-a law). Stages every §7.1/§7.2 state for pixel
  gates and E2E.

## 8. Q6 — Copilot & Explain teaching

- **CopilotToolCatalog** (`Sources/DAWControl/CopilotCatalog.swift`): all 8 commands join, each
  entry landing WITH its command's phase (the capability convention). The `reference_compare` and
  `reference_set_monitor` descriptions carry the workflow: "To compare a mix to the reference:
  `reference_status` (is one loaded + analyzed?) → play a representative section →
  `reference_compare` → read the deltas (negative Δlufs = your mix is quieter; band deltas name
  low/mid/high energy gaps) → suggest concrete moves (EQ bands, the built-in limiter for loudness) →
  offer `reference_set_monitor` so the human hears the A/B level-matched (louder-sounds-better bias
  removed)." Catalog count 61 → 69; parity tests updated.
- **Explain entries** (`DAWAppKit.ExplainCatalog`, Rule-6 copy contract — no raw unit jargon):
  `.referenceRow`, `.referencePanel`, `.referenceABToggle` (shared by strip + panel — ONE id),
  `.referenceSpectrum`. Explain count floor bumps accordingly.
- The A/B toggle answers "why does the reference sound quieter than on streaming?" in its Explain
  body (level matching explained in beginner words) — the feature's core teaching moment.

## 9. Test & gate plan (fixtures by ID; each phase's gate lists the IDs it must hold)

| ID | Suite / location | Pin |
|---|---|---|
| T1 | `Tests/DAWCoreTests/ReferenceSlotTests.swift` | Codable round-trip; a pre-m22-g `ProjectDocument` re-encodes BYTE-IDENTICAL (omit-when-nil); tolerant decode: corrupt `reference` sub-tree → nil + load warning, open succeeds; wrong-count `bandsDb` sanitizes to nil-analysis + warning |
| T2 | same | `ReferenceLevelMatch` law table: basis fallback at nil mix; trim composition; ceiling clamp exact (`refTP + gain == −1.0` when limited); `ceilingLimited`/`matchBasis` flags; linear conversion |
| T3 | same | `StereoImage.measure`: mono → corr +1 / width 0; dead channel → +1 (the m22-d snap rule); anti-phase → corr −1 / width 1; hard-pan balance ±1; NaN-poisoned chunks skipped |
| T4 | `Tests/DAWEngineTests/ReferenceAnalyzerTests.swift` | LUFS/TP/LRA parity: analyzer output on a synthesized program EXACTLY equals `Loudness.measure` of the same samples (same code path — the m22-c convergence idiom); chunk-size invariance (64 k vs whole-file identical) |
| T5 | same | Band-fold parity: `ReferenceAnalyzer` bands == `AudioContentAnalyzer`'s fold on the same file (shared-helper anti-fork pin); `AudioContentAnalyzer` outputs bit-identical pre/post extraction |
| T6 | same | Stereo cross-consistency: steady synthesized signals → offline aggregates within tolerance of `MasterMixAnalyzer`'s settled ballistic values |
| T7 | `Tests/DAWEngineTests/ReferenceLaneTransparencyTests.swift` | Lane-off vs lane-on manual render of the same session (reference silent): byte-identical (zero-sign-modulo escape documented in §5.7 ONLY if hit); m12-b offline anchor SHAs byte-identical with a slot imported + monitoring on; `Σ stems ≡ mixdown` + bounce==stem byte-equal with a reference present (the null-invariant re-run) |
| T8 | same / staging | LEVEL-MATCH HONESTY (the roadmap GATE): apply `matchGainDb` to the reference's samples in-test, `Loudness.measure` of the gained audio == basis within 0.2 LU (analytic per §5.6, tolerance covers gate-boundary blocks); ceiling-clamped case measured ≤ −1.0 dBTP |
| T9 | `Tests/DAWControlTests/ReferenceCommandTests.swift` | all 8 shapes; `rejectUnknownKeys` teaching errors; the §5.6 refusal ladder verbatim; slot-echo Codable threading; undo restores slot (import→undo, remove→undo); monitor state absent from snapshot persistence |
| T10 | `mcp-server` npm | audit bijection/schema-richness auto-covers the 8 new tools; `LONG_RUNNING_COMMANDS` gains `reference.import`; integration round-trip import→status→compare against the stub binary |
| T11 | DAWAppKit tests | `ReferencePanelModel` state machine + formatting + EMA + nil-tolerance; spectrum geometry; Explain catalog completeness + count floor |
| T12 | staging (port 17695, PIDFILE-EXACT kill) | wire exercise: import a fixture WAV → status → setMonitor on (assert matchGainDb + basis) → toggle off → compare during playback (deltas present) → remove → teaching errors on empty slot. Pixel gates via `debug.referenceSeed` + `debug.captureUI` |

**Honesty note on the acoustic gate**: a true device-output capture of A/B at equal LUFS needs
BlackHole (m20-b, USER-BLOCKED). T8 measures the LAW end-to-end (gained samples through the real
loudness math) and T12 verifies the applied node gain over the wire; the acoustic loop is filed to
the m20-b bundle explicitly — named, not silently skipped.

## 10. Phase plan (single-agent flights; routing per CLAUDE.md)

**P1 — Domain, persistence, analysis** (agent: `audio-dsp-engineer`, fable)
- `Sources/DAWCore/Reference.swift` (types, `StereoImage.measure`, `ReferenceLevelMatch`),
  `ProjectError` cases, `ProjectDocument`/`ProjectSnapshot` mirrors + tolerant decode,
  `ProjectBundle.planMedia` additive param, `ProjectStore+Reference.swift`
  (import/remove/analyze/status), undo-journal coverage.
- `Sources/DAWEngine/Analysis/ReferenceAnalyzer.swift` + the shared band-fold extraction
  (`AudioContentAnalyzer` refactor) + `analyzeReferenceFile` seam on `AudioEngineControlling`
  (throwing default).
- Wire: `reference.import/remove/status/analyze` + 4 MCP tools + catalog entries.
- GATE: T1-T6, T9 (its four verbs), T10 (audit legs), both suites green 0-warn.

**P2 — Engine routing, A/B, level match** (agent: `audio-dsp-engineer`, fable)
- `PlaybackGraph`: `referenceLaneEnabled` flag + lane creation in `ensureMasterSandwich`
  (`PlaybackGraph.swift:1712`), reference scheduling hooks (start/stop/seek/restart + metronome-style
  mid-play toggle), PDC anchor offset, `AudioEngine` push paths (`referenceChanged`,
  `setReferenceMonitor` — protocol seams with no-op/throwing defaults per §5.6).
- Store: `setReferenceMonitor/Offset/Trim`, `referenceCompare`.
- Wire: `reference.setMonitor/setOffset/setTrim/compare` + 4 MCP tools + catalog entries +
  `LONG_RUNNING_COMMANDS`.
- GATE: T7 (the load-bearing transparency + null re-runs), T8, T9/T10 remainder, T12 wire legs,
  suites green. If T7 fails beyond zero-sign → execute the §5.7 fallback ladder BEFORE landing.

**P3 — UI + copilot polish** (agent: `ui-design-engineer`, fable)
- Strip row + panel + shared MIX|REF chip (`Sources/DAWApp/Mixer/MixerStripView.swift`, new
  `Sources/DAWApp/Mixer/ReferencePanelView.swift`), DAWAppKit models + geometry,
  `debug.referenceSeed`, Explain entries, simple-pro-inventory verdict, DESIGN-LANGUAGE.md addendum
  (the REFERENCE row/panel paragraph), CHANGELOG + ROADMAP tick + ARCHITECTURE.md wire paragraph,
  counts, and the "Key future decisions" SETTLED entry.
- GATE: T11, T12 pixel legs, suites + npm green, staging exercise of the panel via seed + live wire.

Split rationale: P1 and P2 are both engine-adjacent but each is a full capability slice (commands +
tools + tests land with their phase, per the house convention); merging them makes the flight larger
than the m22-c/e single-flight precedents. UI is cleanly severable because every P3 surface is a
thin view over P1/P2 store state + headless models.

## 11. Deferred follow-ups (§-numbered; file as m22-g-2…)

- **§11.1 Reference loop unroll** — join the m14 gapless machinery via metronome-style per-cycle
  segment enqueues on the reference player (eager-queue law applies). Cost: touching the sacred
  loop-plan code for a case the toggle-ON re-anchor already serves well (rapid A/B toggling is the
  real gesture); deferred until a user holds B across wraps and cares.
- **§11.2 Multiple reference slots (A/B/C)** — the slot becomes an array + an active index; every
  §3-§6 shape was chosen to extend additively (`reference.import` gains `slot?`). Deferred: one
  great reference beats three mediocre ones for v1, and the UI cost (slot picker) is real.
- **§11.3 Free-audition preview** — play the reference transport-independently from the panel (the
  Sketchpad `AVAudioPlayer` preview shape is RIGHT for this non-monitor use). Cheap; deferred to
  keep P3 lean.
- **§11.4 Key/tempo of the reference** — one more consumer of the m21-e analyzer on the same file;
  teaches "the reference is in A minor at 124". Deferred: not needed for the compare loop.
- **§11.5 Crossfaded A/B toggle** — a ~10 ms dual-gate ramp to kill the toggle click; needs a small
  ramped-gain idiom on two mixers. Deferred with the fx-bypass click precedent.
- **§11.6 Re-anchor on PDC recompute while monitoring** — closes the ms-class drift window of §5.3;
  one recompute-event hook. Deferred until audible in practice.
- **§11.7 Spectrum-match suggestions** — the AI move "make my lows sit like the reference's":
  copilot reads `reference.compare` band deltas → proposes concrete EQ edits. Pure
  catalog/prompt-side work once this lands; no new wire needed. The strongest EchoJay
  differentiator; file for the next AI wave.
- **§11.8 Acoustic A/B capture gate** — joins the m20-b BlackHole bundle (blocked on the user
  installing `blackhole-2ch`).

## 12. Open questions for the orchestrator (before P1 launches)

1. **Fallback target constant**: −14.0 LUFS as the no-mix-reading basis (§5.6) — confirm, or prefer
   a settable app preference (design says constant now, preference later if asked).
2. **T7 zero-sign escape**: pre-approve the "byte-identical modulo −0.0/+0.0" comparison ONLY if the
   transparency gate hits exactly that delta (§5.7), or require the fallback ladder immediately.
3. **Catalog breadth**: all 8 commands into `CopilotToolCatalog` (design says yes) vs a curated 4
   (import/status/setMonitor/compare) if catalog size pressure exists.
4. **`reference.import` replace semantics**: importing over an existing slot replaces it in one
   undoable edit (design says yes — the agent-friendly idempotent shape) vs refusing until
   `reference.remove`.

— End of design. Implementation contract begins at §3; every seam cited was grepped in-tree on
2026-07-20 against the uncommitted working tree on top of b4c2013.
