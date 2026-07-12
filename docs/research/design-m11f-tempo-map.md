# Design spike (m11-f/1): Tempo track + time-signature changes

**Status: DESIGN ONLY — no code changes. Gates M12 implementation.**
**Author: daw-architect, 2026-07-11.**
**Scope:** the roadmap item text (docs/ROADMAP.md:197): *"tempo track + time-signature changes — pervasive beat↔seconds math audit, contract for a tempo map that doesn't break the anchor/no-chase invariants."*

Every claim about current behavior below cites file:line evidence that was read for this spike. Anything not verifiable in the codebase is marked UNVERIFIED.

---

## 1. Decision (summary up front)

**Adopt a piecewise-constant `TempoMap` + a separate `MeterMap`, both living in DAWCore, with all beat↔seconds conversion routed through one prefix-summed integral API. The render thread stays 100 % tempo-agnostic — tempo integration happens exclusively at schedule-build time on the main actor, exactly where it happens today. A tempo-map edit while playing routes through the SAME restart primitive `transport.setTempo` uses today, so the anchor and no-chase invariants are preserved by construction, not by new machinery.**

Recommendation: **GO-WITH-CONDITIONS** (§10).

### The two strongest alternatives, and why they lose

1. **Tempo ramps (linear/curved BPM segments, Logic-style) in v1.** Loses because every one of the ~78 conversion sites in the audit (§5) must then integrate a non-constant function AND invert it: `beats(seconds)` under a linear-BPM ramp is a logarithm, under curved ramps it has no closed form and needs iteration. The anchor invariant's core property — `derivedBeats` is an *exact, cheap, invertible* function of elapsed time (AudioEngine.swift:1296–1310) — survives piecewise-constant trivially (binary search + linear segment math) and survives ramps only with materially more code to verify. Ramps are additive later: a `curve` field on a segment is the same additive-enum move as `AutomationCurve` ("new shapes (e.g. bezier) are additive cases", Sources/DAWCore/Automation.swift:5–9). Ship steps first; they cover the 95 % musical use case (section-to-section tempo changes).
2. **Seconds-as-truth (convert the project to a seconds timeline and derive beats for display).** Loses because the entire domain model is beat-positioned by contract: clips (`Clip.startBeat`/`lengthBeats`), markers (`Marker.beat`), loop/punch (`TransportState.loopStartBeat`… Model.swift:920–933), automation (`AutomationPoint.beat`, Automation.swift:103–104), MIDI notes, quantize/groove. Migrating truth to seconds inverts the whole edit surface, breaks "beats are the source of truth under tempo change" (which is what musicians expect from a DAW tempo track), and touches vastly more code for zero musical benefit.

A third option, **reject-for-now**, was already effectively taken once (m10-q deprioritized this to a design spike). It remains viable — this is the least AI-differentiated big-ticket item — but the audit shows the refactor is mechanical and phaseable, and the null-case (single-segment map) can be gated byte-identical, so the risk argument for permanent rejection is weak.

---

## 2. The invariants, located and quoted

### 2.1 The anchor invariant

The engine never *accumulates* position. While playing, position is **derived** from an immutable value-type anchor installed at the last (re)start:

> Sources/DAWEngine/AudioEngine.swift:107–118
> ```
> /// Set while playing; nil when idle. Beats derive from the output node's
> /// sample clock against this anchor (host clock as fallback).
> private struct PlaybackAnchor {
>     let startBeats: Double
>     let tempoBPM: Double
>     let anchorSampleTime: AVAudioFramePosition
>     let anchorHostTime: UInt64
>     let outputSampleRate: Double
>     let hasSampleAnchor: Bool
> }
> ```

Derivation is a single linear formula off that anchor:

> Sources/DAWEngine/AudioEngine.swift:1300–1302
> ```
> let seconds = Double(renderTime.sampleTime - anchor.anchorSampleTime)
>     / anchor.outputSampleRate
> return max(anchor.startBeats, anchor.startBeats + seconds * anchor.tempoBPM / 60)
> ```

(The `max()` clamp is load-bearing: it pins the playhead during the ~60 ms start lead-in and for the whole count-in — AudioEngine.swift:1290–1295.)

Every discontinuity installs a **new** anchor through one primitive:

> Sources/DAWEngine/AudioEngine.swift:1174–1181
> ```
> /// The single reschedule primitive: stop-all → reschedule-from-beat →
> /// re-anchor → resume. Individual scheduled segments cannot be cancelled;
> /// costs one ~60 ms lead-in gap.
> private func restart(fromBeat beats: Double, tempoBPM: Double) {
> ```

A live tempo change is exactly that primitive, re-anchored from the engine's own derived beats:

> Sources/DAWEngine/AudioEngine.swift:408–414
> ```
> public func setTempo(_ transport: TransportState) {
>     cacheTransportFlags(from: transport)
>     guard currentAnchor != nil else { return }
>     // Engine-derived beats are authoritative here — the incoming
>     // transport.positionBeats can be a display-stale ~33 ms behind.
>     let beats = derivedBeats()
>     restart(fromBeat: beats, tempoBPM: transport.tempoBPM)
> ```

and the protocol contract says so:

> Sources/DAWCore/EngineProtocol.swift:147–150
> ```
> /// Tempo changed. If playing, the engine re-anchors from its OWN derived
> /// beats (authoritative during playback — transport.positionBeats can be
> /// display-stale) and resumes at transport.tempoBPM.
> func setTempo(_ transport: TransportState)
> ```

All schedule consumers — clip players, MIDI schedules, automation, metronome — are built for a **fixed tempo per schedule** and roll against the **same shared anchor** ("lockstep"):

> Sources/DAWEngine/PlaybackGraph.swift:1470–1471
> ```
> // main actor — microseconds, never render-thread work. Fixed tempo
> // per schedule; setTempo restarts → rebuilds (no tempo map v0).
> ```
> Sources/DAWEngine/PlaybackGraph.swift:1487, 1516–1517
> ```
> /// Starts every player against one shared anchor (lockstep). …
> // Automation rolls against the SAME anchor (live) / first-pull epoch
> // (offline) as the MIDI schedules — one seam, offline parity free.
> ```
> Sources/DAWEngine/Automation/AutomationSchedule.swift:115
> ```
> /// FIXED tempo (no tempo map v0; a tempo change restarts → rebuilds, the
> ```

**What the anchor invariant promises today, stated precisely:**
(a) position is a pure function of (anchor, hardware clock) — no accumulation, no drift; (b) every timing consumer schedules in *frames/host-ticks relative to that one anchor*, with tempo baked in at build time on the main actor; (c) any change to the beat↔time mapping (seek, tempo, loop wrap, routing-rewire resume, device recovery) is a full stop-reschedule-re-anchor, never an in-place mutation of a rolling schedule; (d) **the render thread performs no beat math at all** — verified: the only render-side time handling converts host ticks → seconds → schedule frames with NO tempo term (InstrumentSourceNode.swift:230–245, AutomationRenderer.swift:209–214, both `Δticks · ticksToSeconds`; the tempo lives in the schedule's precomputed `sampleTime`s).

### 2.2 The no-chase invariant

> Sources/DAWEngine/MIDISchedule.swift:62–63
> ```
> ///  · NO note chase v0: the onset must also be ≥ fromBeat, else BOTH events
> ///    are dropped (a note sounding across the start point does not sound)
> ```
> Sources/DAWEngine/MIDISchedule.swift:78
> ```
> guard onBeat >= fromBeat else { continue }                 // no chase v0
> ```

This is a **beat-domain** comparison; it never touches the tempo term. The settled v0 contract (per the M4-i resolution, docs/ROADMAP.md "Blocked" section: "no-chase is the settled v0 contract (`MIDIEventSchedule`, ARCHITECTURE.md)") is that a restart mid-note silences that note until its next onset (loop wrap or replay).

**Why a tempo map cannot break these invariants if built as specified:** the map only changes *how a beat count converts to a frame offset inside a schedule build*. The anchor stays a single (startBeats, clockTime) pair; `derivedBeats` becomes the exact inverse of the same piecewise integral used by the builds; no-chase remains the untouched beat-domain guard. A map edit mid-play is routed through `setTempo`'s existing restart seam — a code path that is already live-proven for the *global* tempo change, which is strictly the harder case (it changes the mapping *everywhere*, not just after one boundary).

---

## 3. The tempo-map contract

### 3.1 Data model (DAWCore, pure)

```swift
/// Piecewise-constant project tempo (M12). Value type, Sendable, Codable.
public struct TempoMap: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Equatable {
        public var startBeat: Double   // ≥ 0; segment 0 MUST start at 0
        public var bpm: Double         // clamped to TransportState.tempoRange (20…400, Model.swift:943)
    }
    public private(set) var segments: [Segment]  // sorted by startBeat, unique, non-empty
    // Derived, rebuilt on any mutation (main-actor only):
    // prefixSeconds[i] = seconds from beat 0 to segments[i].startBeat
}
```

API (all pure, O(log n) via binary search over the prefix sums; total functions, no throwing):

```swift
func seconds(fromBeatZeroTo beat: Double) -> Double          // the integral  S(b)
func seconds(from a: Double, to b: Double) -> Double         // S(b) − S(a), signed
func beat(atSecondsFromZero s: Double) -> Double             // S⁻¹, exact per segment
func beat(from startBeat: Double, elapsedSeconds: Double) -> Double  // S⁻¹(S(start)+dt) — the derivedBeats shape
func bpm(atBeat beat: Double) -> Double                      // segment lookup (right-continuous: a change AT beat b governs [b, next))
```

Invariants enforced at mutation (store-side validation, field-named errors): sorted, unique `startBeat`s, first segment at beat 0, bpm within `TransportState.tempoRange`. Ramps are explicitly out of v1; a future `curve` field is an additive Codable case (the `AutomationCurve` precedent, Automation.swift:5–9).

**Why piecewise-constant:** every conversion in the audit reduces to a prefix sum plus one linear term; the inverse is exact (each segment is invertible in closed form); property tests can assert `beat(atSeconds:seconds(toBeat:b)) == b` to 1e-12 over random maps. Ramps forfeit closed-form inversion and add zero value to the M12 milestone.

### 3.2 Time-signature change list (separate map)

```swift
public struct MeterMap: Codable, Sendable, Equatable {
    public struct Change: Codable, Sendable, Equatable {
        public var startBeat: Double        // must fall on a barline of the accumulated meter before it
        public var beatsPerBar: Int         // ≥ 1 (TimeSignature clamps, Model.swift:907–910)
        public var beatUnit: Int
    }
    public private(set) var changes: [Change]   // change 0 at beat 0 (the project default)
}
// API: barBeat(atBeat:) -> (bar: Int, beatInBar: Double); beat(ofBar:) -> Double;
//      beatsPerBar(atBeat:) -> Int
```

Meter is **display/snap/click structure only** — it never enters audio timing math (a beat is a quarter-note duration unit everywhere today; `beatUnit` interpretation stays cosmetic in v1 exactly as it is now — `TimeSignature.beatUnit` is only ever read for display strings, e.g. DAWProApp.swift:530, CopilotEngine.swift:435). Effects of a meter change: `barsBeatsDisplay` (Model.swift:988–993), `bar` snap grid (`ClipSnap.gridBeats(beatsPerBar:)`, ClipEditModel.swift:22–25), ruler bar lines/numbers (TimelineLanesView.swift:373–401), piano-roll bar ops (PianoRollBarOps.swift:22–48), metronome downbeat pattern (Metronome.swift:107 `beat % beatsPerBar == 0` → becomes a MeterMap position query), count-in length (Metronome.swift:89–92). The barline constraint on `startBeat` makes bar numbering well-defined recursively; the store validates it (`meterChangeOffBarline`).

### 3.3 Where conversion lives, and RT-safety

- `TempoMap`/`MeterMap` live in **DAWCore** (headless, no engine imports — the `PDCPlan` precedent, LatencyCompensation.swift:3–7).
- The engine consumes the map **only at schedule-build time on the main actor**: `scheduleAll`, `MIDIEventSchedule.buildEvents`, `AutomationSchedule` build, `ClipFadeBake`, `Metronome` scheduling, and `derivedBeats` (engine-actor control code, ~30 Hz playhead task — AudioEngine.swift:1312–1339 — not the render thread).
- **Zero render-thread changes.** The render thread already never does beat math (§2.1d). This design keeps it that way. No new atomics, no publishes, no exceptions to add to ARCHITECTURE.md's RT inventory.
- `PlaybackAnchor` changes shape: `tempoBPM: Double` → `map: TempoMap` (a value copy; the anchor stays immutable) plus a monotone `mapRevision: UInt64` for staleness checks (ClipFix freeze, §3.7). `derivedBeats` becomes `map.beat(from: anchor.startBeats, elapsedSeconds: seconds)` — the same `max(startBeats, …)` clamp retained verbatim.

### 3.4 Persistence — additive, no schema bump

Follow the markers precedent exactly:

> Sources/DAWCore/ProjectDocument.swift:26–29, 32
> ```
> /// Session markers (m11-c). Additive and optional; nil when the project has
> /// no markers (an EMPTY array is stored as nil so the key is omitted on encode
> /// … `sends`/`takeGroups` omit-when-empty rule, no schemaVersion bump). …
> public var markers: [Marker]?
> ```

Add `public var tempoMap: [TempoMap.Segment]?` and `public var meterChanges: [MeterMap.Change]?` — **omitted when the map is trivial** (single segment whose bpm == `transport.tempoBPM`, single meter == `transport.timeSignature`). Old projects decode nil → single-segment map synthesized from the existing `tempoBPM`/`timeSignature` fields (ProjectDocument.swift:226–227, 265–266). `transport.tempoBPM` **remains persisted and remains authoritative for segment 0** — see wire compat, §3.6. No `schemaVersion` bump (ProjectDocument.swift:68–70 tolerates additive keys by construction).

Undo: the maps ride `EditState` (captured/restored via `captureEditState()`/`restoreEditState`, ProjectStore.swift:2580–2606), the same additive move `EditState.markers` made in m11-c. Mutations are `performEdit("Change Tempo", key: "tempo.map")` — the coalescing key makes a tempo-lane drag one undo step (UndoJournal.swift:57: "so a fader drag or tempo scrub is a single undo step"). Meter edits: `performEdit("Change Time Signature", key: "meter.map")`. `setTempo`'s existing recording guard stays and extends to ALL map edits: refuse while `transport.isRecording` (ProjectStore.swift:347–349; MIDI capture and take fan-out assume a fixed tempo per take — MIDICaptureSession.swift:12 "Tempo is fixed per take" and PendingTake freezes `tempoBPM`, ProjectStore.swift:477).

### 3.5 What happens to existing content when the map changes (the honesty section)

**Beats are the source of truth. A tempo edit moves NOTHING in the beat domain**: clips, notes, markers, loop, punch, automation points, take-group ranges, groove templates all keep their beat positions — only their wall-clock realization changes. This is already today's documented contract for the global change and stays word-for-word true per segment.

The honest consequences, each with today's evidence:

1. **Audio-clip AUDIBLE length in beats changes unless stretch compensates.** `Clip.lengthBeats` is the timeline authority; the source window consumed is derived: `sourceWindowSeconds = lengthBeats · 60/tempo / stretchRatio` (Model.swift:279–282). Faster tempo ⇒ the clip's beat-window covers fewer source seconds ⇒ the tail of the file is silently not played (region truncation, PlaybackGraph.swift:1336–1338 "the region window truncates or under-fills the file"); slower tempo ⇒ the window under-fills and the clip's tail goes silent early. **This is exactly today's global-setTempo behavior, localized** — the model doc already states it: "ABSOLUTE and tempo-independent in v0 — a tempo change slides the clip window over more or less of the (already stretched) material, never a re-render" (Model.swift:224–226). The tempo map does not create this behavior; it makes it *reachable per-section*. UI honesty: the m11-f tempo lane ships with the same amber-hint stance as stretch (Model.swift:255 "a UI amber-tint hint, never a hard block") on audio clips crossing a changed segment. A "conform audio to tempo" (Logic Flex-style follow-tempo re-render through the existing `CSignalsmithStretch` worker path) is explicitly **out of M12 scope** — noted as the natural M13 follow-on.
2. **A clip spanning a tempo boundary plays linearly through it.** Audio is never re-rendered mid-clip; the file streams at its natural rate, so beat-alignment of material *inside* the clip after the boundary shifts. Same class as (1); documented, not hidden.
3. **m11-d crossfades survive.** Fades are beat-domain (`fadeInBeats`/`fadeOutBeats`, Model.swift:217–218) and baked per schedule at the current mapping (ClipFadeBake.piecePlan is called inside every `scheduleAll`, PlaybackGraph.swift:1383–1385). A crossfaded pair's two fades span the SAME beat window (crossfade construction, ProjectStore.swift:2270–2320), hence the same seconds window under any map, and equal-power complementarity is pointwise (`g_L(x)² + g_R(x)² = 1` in normalized *beat* progress), so constant-power holds under a boundary inside the overlap too — the curves warp identically in time. What can degrade: at a much slower tempo the fade-out region may fall past the source file's end (under-fill, consequence 2) — then the seam dips because one side runs out of material, and `crossfadeNeedsMaterial`-class checks that were run at creation time (ProjectStore.swift:2298, 2316–2317 convert `half · (60/tempo) / stretchRatio` at the *current* tempo) are stale. M12 fix: those eligibility checks route through the map at the clip's position (audit rows 16–17); a later map edit that starves an existing crossfade is reported by a lint-style advisory read command, not silently "fixed".
4. **Take comps re-flatten.** Comp members' source offsets are tempo-derived; `applyTempoChange` already re-flattens every group (ProjectStore.swift:355–370, `rebuildCompMembers`). Map edits call the same hook. `TakeGroup.crossfadeSeconds` is stored in seconds and converted at flatten (Takes.swift:243 `group.crossfadeSeconds * tempoBPM / 60.0`) → converts via the map at the join beat (audit row 6).
5. **Recording/import land-lengths use the map at the landing beat.** All `durationSeconds · tempo/60` placements (takes ProjectStore.swift:524/545, imports 1590 / +AudioImportBatch.swift:107, generation +Generation.swift:69/224, bounce +Bounce.swift:126) become inverse-integral placements from their anchor beat. A take recorded ACROSS a boundary lands correctly by construction (the writer's `startOffsetSeconds` is anchor-relative by contract, RecordingWriter.swift:29–35; the store integrates instead of multiplying).
6. **In-flight Clip-Fix jobs freeze the map.** Today they freeze the scalar: "Tempo frozen at submit — a mid-job change breaks the bounced material's" (ClipFix.swift:166) and import rejects on mismatch (ProjectStore+ClipFix.swift:194–196). M12: freeze `mapRevision` and compare that — same UX, one integer.

### 3.6 Wire surface (sketch) — and `transport.setTempo` compatibility

Current tempo surface (evidence): `transport.setTempo {bpm}` → `store.setTempo` → returns the clamped scalar (Commands.swift:372–375); the snapshot carries `transport.tempoBPM`; 116 commands / 119 tools total.

M12 adds ONE namespace, keeping every existing agent working:

- `tempo.map` (read): `{segments: [{beat, bpm}], meters: [{beat, beatsPerBar, beatUnit}]}` — always present, always ≥ 1 entry each (the synthesized single segment for legacy projects).
- `tempo.setMap` (write): full-replace `{segments: […], meters?: […]}`, validated with field-named per-index errors (the `take.setComp` full-replace + per-index-error precedent, ARCHITECTURE.md take.* section), ONE `performEdit`. Idempotent full-set is the agent-friendly shape; point edits (`tempo.insertChange` etc.) are UI conveniences the store can add later without wire growth — the UI calls store methods directly.
- **`transport.setTempo {bpm}` stays, redefined as the single-segment fast path**: with a trivial map it behaves byte-identically to today (sets segment 0 = the whole timeline); with a multi-segment map it is rejected with a teaching error pointing at `tempo.setMap` *unless* `{allScale: true}`-style semantics are explicitly designed — v1 decision: **reject with guidance** (silently rescaling a authored map is destructive surprise; the error text names the map command). `transport.tempoBPM` in snapshots/overview remains = segment-0 bpm (the "base tempo"); the snapshot gains additive `tempoMap`/`meterMap` fields (wire-never-drifts: thread the Codable, the take.* precedent).
- MCP: `tempo_map`, `tempo_set_map` (mechanical name rule); `transport_set_tempo` description gains the fast-path/reject note; Copilot catalog adds both as safe/undoable.
- Commands whose **beat-domain params** are unaffected in shape (positions stay beats): `transport.seek {beats|marker}` (Commands.swift:310–328), `transport.setLoop {startBeat,endBeat}` (386–393), `transport.setPunch {inBeat,outBeat}` (395–404), all `marker.*` (330–370), `clip.*` (addAudio/addMIDI `atBeat`/`lengthBeats` 979–996, split 1036, crossfade 1115, stretchToLength 1194, delete/insertTimeRange 1213–1231), `ai.fixClipRegion {startBeat…}` (2092), automation points (beat-keyed). **No wire change for any of them** — that is the payoff of beats-as-truth.
- Commands with **mixed-domain windows** — `render.mixdown` / `render.bounce` / `render.stems` / `render.measureLoudness` / `track.bounceInPlace` all take `{fromBeat, durationSeconds}` (Commands.swift:609–613, 1558–1667): shape unchanged (a render window duration is genuinely wall-clock — it sizes a WAV), but the *default* window and the `fromBeat` offset convert through the map (audit rows 18, 20, 52). Doc-comment updates only; mcp-server tool descriptions saying "at the current tempo" (server.ts:3328, 3374, 3443, 3546, 3619) get reworded to "under the project tempo map".
- Seconds-domain params that stay seconds: `take.setCrossfade {seconds}` (Commands.swift:1462), stretch ratio (absolute, Commands.swift:1166).

### 3.7 Engine contract changes (all main-actor / engine-actor; zero render-thread)

`AudioEngineProtocol` (Sources/DAWCore/EngineProtocol.swift) currently passes scalar `tempoBPM: Double` at play/setTempo/render (132, 147–150, 162, 175). M12 change: pass the `TempoMap` value (inside `TransportState` or alongside — recommend a `transport.tempoMap` property so `setTempo(_ transport:)`'s signature survives). `OfflineRenderer.render(tracks:tempoBPM:…)` (OfflineRenderer.swift:113) takes the map. Internal seams that re-bake per restart (`scheduleAll`, `buildEvents`, `AutomationSchedule.build`, `ClipFadeBake`, `Metronome.scheduleClicks/CountIn/topUp`, punch accept-window, `MIDICaptureSession`) each take the map and integrate — mechanical, enumerated in the audit table. The rewire-resume tuple `(beats, tempoBPM)` (AudioEngine.swift:214) carries `(beats, map)`.

Live map-edit semantics: `ProjectStore` map mutation → `engine.setTempo(transport)` (same call as today, ProjectStore.swift:364) → `restart(fromBeat: derivedBeats())` — the ~60 ms reschedule seam, identical UX to today's live tempo nudge (TransportBar.swift:257–258). A tempo-lane drag therefore restarts repeatedly while scrubbing — same as holding today's +/− nudge; acceptable v1, and the store already coalesces the undo side.

### 3.8 UI sketch (level: sketch only, per the item text)

A **tempo lane** in the arrange ruler block, below the m11-c marker lane (the ruler grew 42→56 for markers; grows again ~18 pt): segment boundaries as draggable handles (beat-snapped via the existing `ClipSnap`), bpm value labels, double-click to insert a change at a bar line, context-menu delete; meter changes render as `4/4`-style flags in the same lane. Both densities show the lane; Simple hides insert/delete (read-only). Neutral dark-glass per DESIGN-LANGUAGE (no violet — not an AI surface). The transport bar's Tempo readout (TransportBar.swift:252–258) shows `bpm(atBeat: playhead)` and its nudge buttons edit the segment under the playhead. `debug.tempoLane` staging command for captures. Explain entry `.tempoMap`. Pixel design deferred to the implementing agent under ui-design-engineer.

Note: the arrange ruler itself stays **linear in beats** (`pixelsPerBeat` geometry is beat-pure everywhere — MarkerLaneGeometry/LoopRuler/ClipEdit/TakeLane/PianoRoll models take only `beatsPerBar`, never tempo). A seconds-linear ruler mode is out of scope.

---

## 4. Audit method

Greps run over `Sources/` + `mcp-server/src` (Tests excluded): `tempo|bpm` (case-insensitive, 206 Swift hits + 28 TS hits), `secondsPerBeat|beatsPerSecond|beatToSeconds|beatsToSeconds|secondsToBeats` (27 hits), `60.0 /|/ 60|* 60` with non-tempo hits triaged (3 hits, all unrelated: clock display `Model.swift:998`, crash-report age `DiagnosticsReporter.swift:158`, UI frame-dt `VibeMeterView.swift:193`), `timeSignature|beatsPerBar|4/4` (182 hits). Every hit was assigned to a site below or to the "confirmed unaffected" list (§5.3). Sites are deduplicated to one row per *conversion decision*, not per mention.

## 5. Appendix A — the beat↔seconds conversion-site audit (THE core deliverable)

**Count: 78 sites** (60 needing work: 34 integral, 12 map-lookup/pass-through, 8 meter-map, 6 contract/doc; 18 recorded as touched-but-nothing-breaks). Verdict legend:
- **integral** — must become `map.seconds(from:to:)` / inverse (today: one multiply by `60/tempo` or `tempo/60`)
- **lookup** — needs `bpm(atBeat:)` or must pass the map through instead of a scalar
- **meter** — needs `MeterMap` (bar math / downbeat pattern / bar snap)
- **contract** — signature/doc/wire-copy change only
- **nothing** — verified unaffected

| # | Site | Converts | Verdict under a piecewise map |
|---|---|---|---|
| 1 | DAWCore/Model.swift:984 `positionSeconds` | playhead beats→s | **integral** S(position) |
| 2 | Model.swift:988–993 `barsBeatsDisplay` | beats→bar.beat | **meter** (barBeat(atBeat:)) |
| 3 | Model.swift:996–1002 `clockDisplay` | via positionSeconds | **integral** (inherits #1) |
| 4 | Model.swift:279–282 `Clip.sourceWindowSeconds(tempoBPM:)` | clip beat-length→source s | **integral** over [startBeat, startBeat+lengthBeats]; signature takes map+startBeat (the tempo factor no longer cancels in `stretchClip`'s window-invariance note, Model.swift:277–278 — re-derive that proof per segment) |
| 5 | DAWCore/Takes.swift:168 `CompFlattener.flatten` `secPerBeat = 60.0 / tempoBPM` | comp segment windows | **integral** per segment span |
| 6 | Takes.swift:243 `xfBeats = group.crossfadeSeconds * tempoBPM / 60.0` | join crossfade s→beats | **integral** inverse at the join beat |
| 7 | DAWCore/ProjectStore+Takes.swift:32 flatten call at `transport.tempoBPM` | scalar pass | **lookup** (pass map) |
| 8 | ProjectStore.swift:362–370 `applyTempoChange` | sets scalar + re-flatten + engine push | **contract** → becomes map mutation entry point (re-flatten hook retained) |
| 9 | ProjectStore.swift:524 `audioLengthBeats = durationSeconds * pending.tempoBPM / 60` | take length s→beats | **integral** inverse from the take's start beat (map frozen per take) |
| 10 | ProjectStore.swift:544–545 take `startBeat = recordStart + offset × tempo/60` | anchor-relative offset s→beats | **integral** inverse from recordStart |
| 11 | ProjectStore.swift:1590 `addAudioClip` length | file s→beats at atBeat | **integral** inverse |
| 12 | ProjectStore.swift:1948 `splitClip` `splitSeconds = firstLength * 60.0 / tempoBPM` | split offset beats→source s | **integral** (the doc comment at 1926–1928 already prescribes exactly this: "a future tempo map would integrate over the split") |
| 13 | ProjectStore.swift:2035 `trimClip` offset advance | trimmed beats→source s | **integral** over the trimmed span |
| 14 | ProjectStore.swift:2106/2124 `moveClip` overlap resolve | passes tempo into trim math | **lookup** (pass map) |
| 15 | ProjectStore.swift:2147–2151 `clipTrimmedToWindow` | covered beats→source s | **integral** |
| 16 | ProjectStore.swift:2298 crossfade `rightHeadSource = half * (60/tempo) / ratio` | fade material check | **integral** at the seam |
| 17 | ProjectStore.swift:2316–2317 crossfade left tail + window end | fade material check | **integral** at the seam |
| 18 | ProjectStore.swift:2520 measureLoudness default window `(lastEnd−start)*60/tempo` | window beats→s | **integral** |
| 19 | ProjectStore.swift:3345 `startPositionTicker` `positionBeats += seconds * tempo/60` | engineless playhead advance | **lookup**: advance = map.beat(from: pos, elapsed: dt) |
| 20 | ProjectStore+Render.swift:220 `renderWindowSeconds` default | window beats→s | **integral** (shared with bounce, m11-e) |
| 21 | ProjectStore+Render.swift:28/67/168/188 render calls pass `transport.tempoBPM` | scalar→engine | **contract** (pass map through `AudioEngineProtocol`) |
| 22 | ProjectStore+Quantize.swift:71–80 `detectClipTransients` beat mapping `(t−offset)·ratio·tempo/60` | source s→timeline beats | **integral** inverse from clip start |
| 23 | ProjectStore+Quantize.swift:147 `quantizeAudio` tempo arg | scalar pass | **lookup** |
| 24 | DAWCore/AudioQuantize.swift:138–142 `spb = 60.0/tempoBPM` + window | onset s↔beats | **integral** (clip-local) |
| 25 | ProjectStore+TakeAlignment.swift:104–118 `secPerBeat`, onset windows | lane onsets beats↔s | **integral** |
| 26 | ProjectStore+TakeAlignment.swift:134 `offsetBeats = offsetSeconds * tempo / 60` | alignment nudge s→beats | **integral** inverse at the lane beat |
| 27 | ProjectStore+TakeAlignment.swift:215–218 `timelineOnsetSeconds` `clipStartSeconds = startBeat * 60/tempo` | clip start beats→s | **integral** |
| 28 | ProjectStore+ClipFix.swift:102–119 region/context/bounce/repaint conversions | fix window beats↔s | **integral** |
| 29 | ProjectStore+ClipFix.swift:194–196 tempo-freeze guard (+ ClipFix.swift:166–168 frozen scalar) | job staleness | **contract** → freeze/compare `mapRevision` |
| 30 | ProjectStore+Generation.swift:69 import length `durationSeconds * finalTempo / 60` | generated audio s→beats | **integral** inverse at atBeat (tempo *adoption* = segment-0 edit folded into the same performEdit) |
| 31 | ProjectStore+Generation.swift:224 stems import lengths | same | **integral** inverse |
| 32 | ProjectStore+Bounce.swift:106/126 bounce render + landed length | window + s→beats | **integral** both |
| 33 | ProjectStore+AudioImportBatch.swift:76/107 import lengths | file s→beats | **integral** inverse per placement |
| 34 | ProjectStore+AudioImportBatch.swift:152 import overlap resolve | tempo into trim math | **lookup** |
| 35 | DAWCore/SongSkeleton.swift:35, 73, 269 "4/4 assumed… bars → beats ×4" | section bars→beats | **meter** (bars×beatsPerBar at position; v1 may legitimately keep skeletons meter-0-only — document) |
| 36 | ProjectStore.swift:2650/2678 `tempoChanged` compare + engine push on open/recover | staleness compare | **contract** (compare maps) |
| 37 | DAWEngine/MIDISchedule.swift:71–82 `buildEvents` `secondsPerBeat = 60.0/tempoBPM`, on/off frame math | note beats→schedule frames | **integral**: `sampleTime = round(map.seconds(from: fromBeat, to: onBeat) · rate)`; no-chase guard (line 78) untouched |
| 38 | DAWEngine/PlaybackGraph.swift:1343–1375 `scheduleAll` `clipStartSec`/`regionSec`/`whenSample` | clip beats→player frames | **integral** per clip boundary (signed for pre-roll clips, line 1348 "may be < 0" — S(from,to) is signed) |
| 39 | PlaybackGraph.swift:1472–1477 staged MIDI builds | scalar pass | **contract** (pass map) |
| 40 | DAWEngine/ClipFadeBake.swift:51–52 `framesPerBeat = fileRate * 60.0 / tempoBPM` ("the ONE beats→frames" seam) | fade windows beats→frames | **integral** over the fade's beat span (piecewise inside a fade crossing a boundary) |
| 41 | ClipFadeBake.swift:68–138 `piecePlan`/`bakePiece` envelope positions | fade envelope frames | **integral** (inherits #40; envelope stays beat-normalized so equal-power complementarity is preserved, §3.5.3) |
| 42 | DAWEngine/Metronome.swift:89–92 `countInPlan` `Double(clickBeats) * 60.0 / tempoBPM` | count-in length beats→s | **lookup** (count-in pre-roll runs at the record-start segment's bpm — policy: the segment at the punch-in/record beat) |
| 43 | Metronome.swift:104–109 `scheduleClicks` click times + `beat % bar == 0` downbeat | click beats→player s + bar pattern | **integral** + **meter** |
| 44 | Metronome.swift:122–125 `scheduleCountIn` | count-in click times | **lookup** (single segment by policy, #42) |
| 45 | Metronome.swift:130–139 `topUp` (cached `tempoBPM`, line 44) | rolling click extension | **integral** (cache the map slice instead of a scalar) |
| 46 | DAWEngine/AudioEngine.swift:1014–1019 punch accept window `(punchBeat − position) * secondsPerBeat` | punch beats→host-time window | **integral** |
| 47 | AudioEngine.swift:1296–1310 `derivedBeats` `startBeats + seconds * tempoBPM / 60` | elapsed s→beats (THE anchor inverse) | **integral inverse**: `map.beat(from: startBeats, elapsedSeconds:)`; `max()` clamp retained |
| 48 | AudioEngine.swift:1362–1368 `recoverEngine` beat derivation | same formula | **integral inverse** |
| 49 | AudioEngine.swift:408–417 `setTempo` restart | live change seam | **contract**: same restart, now fired by any map edit |
| 50 | AudioEngine.swift:214/271/486/502 rewire-resume tuple `(beats, tempoBPM)` | resume state | **contract** (carry map) |
| 51 | AudioEngine.swift:111 `PlaybackAnchor.tempoBPM` | anchor field | **contract** (anchor carries map value + revision) |
| 52 | DAWEngine/OfflineRenderer.swift:220 `throughBeat = fromBeat + durationSeconds * tempoBPM / 60.0` | render window s→beats | **integral** inverse |
| 53 | OfflineRenderer.swift:113–118 / 304–308 render API scalar `tempoBPM` | API shape | **contract** (map param) |
| 54 | DAWEngine/MIDIInput/MIDICaptureSession.swift:85 `anchorBeats + seconds * tempoBPM / 60.0` (+ header math line 8) | live MIDI host-time→beats | **integral inverse** from the take anchor (v1 may keep the frozen-per-take single segment — the take-record guard in §3.4 makes this exact) |
| 55 | DAWEngine/RecordingWriter.swift:29–35 `startOffsetSeconds` anchor-relative contract | consumed by #10 | **nothing** here (stays seconds; the consumer integrates) |
| 56 | DAWCore/EngineProtocol.swift:132, 147–150, 162, 175 | protocol docs/signatures | **contract** |
| 57 | DAWControl/Commands.swift:372–375 `transport.setTempo` | wire fast path | **contract** (§3.6 reject-with-guidance on multi-segment maps) |
| 58 | Commands.swift:609–613, 1558–1667 render windows `{fromBeat, durationSeconds}` | mixed-domain wire params | **contract** (shape unchanged; doc comments updated; conversions inside are rows 18/20/52) |
| 59 | DAWControl/CopilotEngine.swift:434–435 `"TRANSPORT: … BPM …/…"` | prompt context | **lookup** (summarize map: "120 BPM at playhead; 3 tempo changes") |
| 60 | DAWControl/CopilotCatalog.swift:195–198, 350, 560–565 | schema copy "current tempo" | **contract** (copy + add tempo.map tools) |
| 61 | DAWControl/TransportBroadcaster.swift:15 (tempo in transport payload) | broadcast display | **nothing** (payload gains additive map fields with the snapshot) |
| 62 | DAWAppKit/ClipEditModel.swift:22–25, 45–50 `gridBeats(beatsPerBar:)` / `snap` | bar snap | **meter** (bar grid at the snapped position) |
| 63 | DAWAppKit/LoopRulerModel.swift:124–202 snap calls | bar snap | **meter** (inherits #62) |
| 64 | DAWAppKit/MarkerLaneModel.swift:73–83 snap calls | bar snap | **meter** (inherits #62) |
| 65 | DAWAppKit/TakeLaneModel.swift:104–111 snap calls | bar snap | **meter** (inherits #62) |
| 66 | DAWAppKit/AudioImportPlan.swift:37–45, 129 `beatsPerBar` context | bar snap | **meter** (inherits #62) |
| 67 | DAWAppKit/PianoRollBarOps.swift:22–48 bar insert/delete/number | clip-local bar math | **meter** (bar at clip position; meter-aware doc already: lines 10–11 "meter-aware (three beats in") |
| 68 | DAWAppKit/LyricsWorkshopModel.swift:66–67 tempo context | AI context | **lookup** (tempo at playhead) |
| 69 | DAWApp/ContentView.swift:285 `secondsPerBeat: 60.0 / store.transport.tempoBPM` | UI waveform mapping feed | **lookup**/**integral** (per-clip local mapping, see #71) |
| 70 | DAWApp/Timeline/TimelineLanesView.swift:31–33, 233–234, 373–401 ruler bars + `secondsPerBeat` | ruler bar lines/labels + waveform | **meter** (bar lines) + **integral** (waveform, #71) |
| 71 | DAWApp/Timeline/ClipWaveform.swift:114–129 `seconds = startOffset + (x/pxPerBeat) · secondsPerBeat` | pixel→source-seconds | **integral** over the clip's beat span (piecewise; v1 may draw per-segment spans) |
| 72 | DAWApp/Timeline/TakeLanesView.swift:23, 117, 183 `secondsPerBeat` passthrough | take-lane previews | **integral** (inherits #71) |
| 73 | DAWApp/TransportBar.swift:252–258 tempo readout + nudge | display/edit | **lookup** (bpm at playhead; nudge edits that segment) |
| 74 | DAWApp/PianoRoll/PianoRollView.swift:19, 617 `beatsPerBar` grid | roll grid/bar badge | **meter** (meter at clip start; v1 policy: one meter per clip view, documented) |
| 75 | DAWApp/DAWProApp.swift:529–530, 1055 context strings + beatsPerBar wiring | AI context/display | **lookup**/**meter** |
| 76 | mcp-server/src/server.ts:234–250 `transport_set_tempo` | tool schema | **contract** (fast-path note; new `tempo_map`/`tempo_set_map` tools) |
| 77 | server.ts:3328, 3374, 3443, 3546, 3619 render tool copy "at the current tempo" | descriptions | **contract** (copy) |
| 78 | server.ts:1643, 4084, 4091 import/lyrics copy | descriptions | **contract** (copy) |

### 5.3 Confirmed unaffected (audited, listed for exhaustiveness)

- **Render thread**: InstrumentSourceNode.swift:230–245 and AutomationRenderer.swift:209–214 (host-ticks→seconds only, tempo pre-baked into schedule frames); EffectChainProcessor / CompensationDelay / all effect DSP (sample-domain).
- **PDC**: LatencyCompensation.swift — entirely in samples ("Latencies are in samples at the current engine rate", line 34); tempo-free by construction. No tempo-map interaction.
- **Loudness/analysis**: Loudness.swift, TransientAnalyzer/TransientCache (markers are "SOURCE-FILE seconds (geometry-free)", ARCHITECTURE.md clip.detectTransients section) — the *cache* survives tempo edits; only the beat *projection* converts (rows 22–24).
- **Quantize/groove/humanize**: Quantize.swift, Groove.swift — pure beat domain, zero tempo terms (grep-verified).
- **Stretch engine**: `stretchRatio` is "ABSOLUTE and tempo-independent" (Model.swift:224); CSignalsmithStretch renders ratio-domain CAFs; scheduling math is rows 4/38.
- **Pixel geometry**: `pixelsPerBeat` sites (MIDIMapGeometry, PianoRollModel, PianoRollPlayhead, AutomationLaneModel, MarkerLaneGeometry…) — beat-pure, no tempo/meter terms beyond snap (rows 62–67).
- **DiagnosticsReporter.swift:158, VibeMeterView.swift:193, Model.swift:998** — `60`-factor hits unrelated to musical time.
- **AIServices** (Providers.swift tempo fields, ACEStepClient) — free-text/BPM *hints* to generators, not timeline math.

---

## 6. Interactions called out by the item text, resolved

| Feature | Resolution |
|---|---|
| Offline render windows (`render.stems`/`measureLoudness` `{fromBeat + durationSeconds}`) | Mixed domains stay on the wire (duration is honestly wall-clock); `fromBeat` offset and default window integrate (rows 18/20/52/58). Stems/mixdown/bounce all share `renderWindowSeconds` (ProjectStore+Render.swift:207–211 "Internal (not private) so `bounceTrackInPlace` shares the SAME default window") — one conversion site keeps the m11-e byte-equivalence class intact: bounce and stems consume the same map the same way, so the byte-identical gate re-passes by construction; it is re-run in phase B anyway. |
| Clip audio stretch (`clip.setStretch`/`stretchToLength`) | Ratio stays absolute; `sourceWindowSeconds` integrates (row 4). The `stretchClip` window-invariance identity ("the tempo factor cancels", Model.swift:277–278) no longer cancels across a boundary — `stretchToLength` re-derives the ratio from the integral. Test pinned. |
| Loop region | Beat domain; wrap check compares beats (AudioEngine.swift:1326–1331) and the wrap restart re-anchors — works unchanged once `derivedBeats` inverts the map (row 47). A loop spanning a tempo change wraps at the right WALL time automatically. |
| Markers | Beat domain (Commands.swift:330–370); positions untouched by map edits. `transport.seek {marker}` unaffected. |
| Automation lanes | Points are beat-keyed (Automation.swift:103–104); schedule build integrates (row 40 analog: AutomationSchedule.swift:121–125, audit row is part of #40's family — explicitly: AutomationSchedule.swift:121 `secondsPerBeat = 60.0 / tempoBPM` → integral). Live/offline anchor parity preserved (PlaybackGraph.swift:1516–1520). |
| MIDI scheduling | Row 37; no-chase untouched. |
| PDC | Sample domain; untouched (§5.3). |
| Arrange ruler | Stays beat-linear; bar lines/labels go through MeterMap (row 70). |
| Transport display | bars.beats via MeterMap (row 2); clock via integral (rows 1/3). |
| Wire beats-vs-seconds inventory | §3.6 (beat-param commands listed; seconds params: render `durationSeconds`, `take.setCrossfade {seconds}`, `take.autoAlign {searchWindowMs}`). |
| Recording / punch / count-in | Rows 9/10/42/44/46/54; map edits refused while recording (§3.4). |
| Take comping | Rows 5–7; re-flatten hook already exists (ProjectStore.swift:355–370). |
| Crossfades (m11-d) | §3.5.3 — survive; eligibility checks re-routed (rows 16–17). |
| Quantize/groove | Beat-pure; audio-quantize projections integrate (rows 22–24). |

---

## 7. Risks, ranked

1. **Audit-miss / split-brain conversion (HIGH).** One site left multiplying by a scalar disagrees with the map silently — a clip lands at the wrong beat only when a map is non-trivial, so tests with trivial maps stay green. *Mitigation:* Phase A converts EVERY row above to the map API and then a **lint test** (the audit-tools.test.ts precedent: mechanical source scan) fails the suite on any new `60.0 / tempo`-shaped arithmetic outside `TempoMap` itself; plus the null-case byte-equivalence gate (§9 A). This is why the refactor phase must land whole, not incrementally per feature.
2. **Anchor regression in `derivedBeats`/restart seams (HIGH impact, LOW likelihood).** The M4-i defect class ("stale render-clock anchor froze the playhead", AudioEngine.swift:1197–1209) shows how subtle this code is. *Mitigation:* the map only replaces the one linear term inside `derivedBeats`; the anchor lifecycle, `renderClockTrusted`, and the clamp are untouched; phase B adds a live gate that plays across a mid-timeline tempo boundary and asserts playhead monotonicity + wall-clock beat arrival within tolerance, plus a loop-wrap-across-boundary gate.
3. **User-model surprise on audio clips (MEDIUM).** Beats-as-truth means inserting a faster segment audibly truncates audio clip tails downstream of nothing — the clip *content* shifts against later beats (§3.5.1–2). Logic solves this with Flex/follow-tempo; we ship without it in M12. *Mitigation:* amber hint on audio clips whose span crosses a non-trivial boundary + Explain copy; "conform audio to tempo map" recorded as the M13 follow-on.
4. **Take/comp + crossfade edge staleness (MEDIUM).** Seconds-denominated stored values (`TakeGroup.crossfadeSeconds`, crossfade material eligibility) convert at *use* time; a map edit can starve material (§3.5.3–4). *Mitigation:* re-flatten hook already fires on tempo change; add an advisory check + tests for boundary-straddling groups/seams.
5. **Live-edit UX seam (LOW).** Every map edit while playing costs the ~60 ms restart gap (today's setTempo behavior, documented at AudioEngine.swift:1176). A tempo-lane drag stutters audibly. *Mitigation:* v1 documents it (same honesty as loop-wrap seam, AudioEngine.swift:1320–1323); restart-on-release for drags if QA finds it unacceptable.
6. **Copilot/agent confusion over two tempo surfaces (LOW).** `transport.setTempo` rejecting on multi-segment maps may surprise old agent flows. *Mitigation:* teaching error naming `tempo.setMap`; catalog descriptions updated; integration test pins the error text.

## 8. Explicitly NOT in scope (recorded so M12 doesn't scope-creep)

- Tempo ramps (additive later, §1-alt-1). — Audio follow-tempo re-rendering (M13 candidate). — Seconds-linear ruler mode. — `beatUnit`-aware beat *durations* (meter stays display/snap/click-structure). — SMPTE/frame-rate display. — Per-clip tempo interpretation of imported material (BPM detection already lives in generation metadata only).

## 9. Phased M12 implementation plan

**Phase A — DAWCore map types + total refactor to the map API (null-case).**
Files: new `Sources/DAWCore/TempoMap.swift` (+ `MeterMap`), edits per audit rows 1–36 (DAWCore) with the map ALWAYS trivial (built from `transport.tempoBPM`/`timeSignature`); `EngineProtocol`/engine rows 37–56 mechanically take the map value. No wire change, no persistence change yet.
Tests/gate: new `TempoMapTests` (integral/inverse round-trip property to 1e-12, segment-edit invariants, meter barline validation); **byte-equivalence gate**: offline mixdown + stems + bounce of a representative project (MIDI + audio + fades + crossfade + automation + metronome) BEFORE vs AFTER the refactor — SHA-256 identical (the m11-e byte-gate machinery); full suite green with zero behavior diffs; the anti-regression lint test lands here.
**Phase B — multi-segment engine correctness.**
Files: `MIDISchedule.buildEvents`, `PlaybackGraph.scheduleAll`, `AutomationSchedule.build`, `ClipFadeBake`, `Metronome`, `AudioEngine.derivedBeats`/punch/recovery, `OfflineRenderer` (rows 37–54) actually integrating.
Tests/gate: offline sample-position tests — schedule a note/click at beats {3.9, 4.1} around a 120→90 boundary at beat 4 and assert exact analytic sample times (the "event-timestamp tests assert `==`" discipline, ARCHITECTURE.md:143–145); fade/crossfade continuity across a boundary (windowed LUFS seam spread ≤ 0.05 dB, the m11-d gate shape); live staging gate: playhead monotonic across boundary, loop wrap across boundary, tempo edit mid-play restarts from derived beats; stems Σ ≡ mixdown and bounce-vs-stems byte-identity re-run WITH a multi-segment map.
**Phase C — persistence + wire + MCP + undo surface.**
Files: `ProjectDocument` additive fields; `ProjectStore` map mutation methods (`performEdit` + coalescing keys + recording guard + ClipFix mapRevision freeze); `Commands.swift` `tempo.map`/`tempo.setMap` + `transport.setTempo` fast-path/reject (116→118 cmds); `mcp-server` tools (119→121) + copy rows 76–78; Copilot catalog; snapshot additive fields.
Tests/gate: save→new→open round-trip incl. legacy (nil-field) project; audit-tools bijection + integration count pins; wire gate: setMap → snapshot/map agreement → undo restores prior map in ONE step → coalesced drag = one entry (the m11-c gate shape); setTempo-on-multi-segment teaching error pinned.
**Phase D — meter map consumers + UI tempo lane.**
Files: DAWAppKit snap/geometry rows 62–67; ruler bar lines row 70; transport display rows 2/73; piano-roll row 74; new tempo lane views + `debug.tempoLane` + Explain entry; DESIGN-LANGUAGE.md component note.
Tests/gate: meter bar-math unit tests (7/8 then 4/4 bar numbering exact); model tests for lane edit plans; pixel-reviewed captures (lane populated, drag, meter flag, Explain card); density inventory row.
Rough order of magnitude: A ≈ the m10-d-class refactor round; B ≈ an m11-d-class engine round; C ≈ an m11-c-class wire round; D ≈ an m11-a-class UI round.

## 10. Recommendation

**GO-WITH-CONDITIONS.** Conditions:
1. Phase A's null-case **byte-equivalence gate must pass before any multi-segment code lands** — a failed gate stops the milestone (it means the audit missed a site).
2. The **lint test against raw tempo arithmetic** ships in Phase A and stays permanently.
3. **Zero render-thread changes** — any deviation discovered during implementation returns here for a design amendment (ARCHITECTURE.md RT-invariants section addition would be required).
4. Piecewise-constant only; ramps and audio-follow-tempo are out of scope and re-spiked if demanded.
5. On landing Phase C, `docs/ARCHITECTURE.md` "Key future decisions" gets the SETTLED entry (this spike deliberately does not edit it — docs-only constraint on the two new files).

No full-Xcode requirement anywhere in this design (no entitlements, no AUv3, no signing — pure SPM work).
