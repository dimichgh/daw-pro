# m16-a design note — the "Canvas-closure crash class" is an AVFAudio NSException poisoning the MainActor

Date: 2026-07-13
Author: daw-architect (agent)
Input: audit-m16.md §1-F1 + §2-B1; the three audit `.ips` (2026-07-13-070338/-070831/-071806); ROADMAP m16-a.
Session evidence: 3 NEW reproduced crashes (`DAWApp-2026-07-13-075840/-081434/-081527.ips`), 3 reproduced silent
wedges (one live-probed under lldb), the poisoner caught in the act with its reason string, and binary-level
disassembly of the exact faulting instructions (the crash binary `.build/debug/DAWApp` UUID-matches all six .ips).
Probes/scripts in session scratchpad (`m16a-storm.mjs`, `m16a-twotrack.mjs`, `m16a-loop.sh`, `lldb-throwhunt.txt`,
`throwhunt.log`, `canvas-probe.swift`, `dawapp-disasm.txt`, `dis-out*.txt`, `hang-sample*.txt`). No source changed.

## VERDICT: GO — with a corrected diagnosis

The audit's framing ("Canvas closures capture references; SwiftUI re-evaluates against a stale capture") is
**wrong in the load-bearing place**, and the audit's default fix (value-snapshot capture discipline) is
**measured insufficient on its own**. The real chain, proven end-to-end this session:

1. **Poisoner (root cause)**: `-[AVAudioPlayerNode playAtTime:]` raises an ObjC `NSException` —
   verbatim reason **"player started when in a disconnected state"** — inside
   `PlaybackGraph.startAllPlayers` (`Sources/DAWEngine/PlaybackGraph.swift:2561`), which runs inside the
   **MainActor task job** for the `transport.play` wire command (full stack captured live:
   `ControlServer.dispatch` → `CommandRouter.route` `Commands.swift:310` → `ProjectStore.play()`
   `ProjectStore.swift:405` → `AudioEngine.startPlayback` `AudioEngine.swift:533` → `startPlayers` `:1677` →
   `PlaybackGraph.startAllPlayers` → `playAtTime:` → `+[NSException raise:format:]`).
2. **The wound**: Swift cannot unwind ObjC exceptions. The exception tears through the Swift concurrency job
   frames and is swallowed below (AppKit/runloop). The runtime's `ExecutorTrackingInfo` — a stack-resident
   record whose pointer lives in thread TSD slot 104 (`TPIDRRO_EL0+0x340`) — **leaks**: TLS keeps pointing at
   dead stack. The thread even keeps its hijacked `'Task N'` name (observed live: idle main thread named
   `Task 6848`). The process survives, poisoned.
3. **Two presentations**:
   - **Crash**: the next *compiler-emitted dynamic actor-isolation check* (SE-0423; Swift 6 inserts one at the
     top of every `@MainActor` closure that is passed to a nonisolated closure parameter — `Canvas.renderer`,
     `GeometryReader` content, `HStack` `@ViewBuilder` content …) calls
     `swift_task_isCurrentExecutor(MainActor.shared.unownedExecutor)`; the runtime loads the *current* executor
     from the leaked record (disassembly-proven: `WithFlagsImpl+44` `ldr q0, [x8]` where `x8 = TLS[0x340]`) and
     `swift_getObjectType()`s reused-stack debris → SIGSEGV or `brk #0xc472` (both getObjectType exits matched
     to corpse registers instruction-exactly). 60 fps Canvas closures under `TimelineView(.animation)` are simply
     the most probable *first check inside the poisoned window* — hence 4 of 7 known corpses are Canvas sites.
   - **Wedge**: if no check runs first, the MainActor job queue never drains again while the runloop stays
     healthy — **the wire goes silently dead** (connects fine, every command times out). Observed 3× this
     session; live-probed: TLS slot = `0x16f8b5260` (main-thread stack, 0x90 above idle `sp`), leaked record's
     ActiveExecutor = `[0x18fb8ade4, 0x20]` — **byte-identical** to the garbage executor in audit crashes 2+3
     (`0x18fb8ade4` = a QuartzCore `__TEXT` address, i.e. a spilled return address in reused stack).

**Killing the poisoner kills both presentations. Capture discipline alone kills neither** (a plain closure with
value-only captures still gets the SE-0423 check — probe-verified, see §3-E — and no capture change can fix
the wedge). The fix below is therefore three-legged: root fix in the engine, an exception barrier at the
engine seam, and the Canvas hardening (with `@Sendable` as the load-bearing part, not just snapshots).

Two audit questions answered with evidence:
- **Not an M15 regression**: `DAWApp-2026-07-06-051559.ips` (a week pre-M15) has the identical runtime chain,
  faulting in `closure #1 in ContentView.body.getter` under `GeometryReader.Child.updateValue`. Same OS build
  (25E246) then and now. M15 changed nothing load-bearing; the m13/m15 audits were lucky (their storms had no
  missing-media play).
- **Not debug-only**: SE-0423 checks are emitted in `-O` release builds too (probe-verified: 2 checks with `-O`,
  0 with `-disable-dynamic-actor-isolation`). The shipping app carries the same detonators.

## 1. Repro results (honest numbers)

| Recipe | Iterations | Poisonings | Presentation |
|---|---|---|---|
| **Missing-media 2-track** (audit crash-3 recipe): `project.new` → instrument+audio track → `clip.addAudio` (real file) → `clip.setFades` + `clip.setGainEnvelope` → delete the file → `transport.seek {beats:1}` → `transport.play` (12 s) → `stop`; repeat | 6 sequences | **6/6 — deterministic**, always on the 2nd play-bearing cycle (~60-90 s to kill) | 3 crashes (.ips 075840 TransportBar-HStack, 081434, 081527) + 3 wedges |
| **B1 storm** (40 tracks + clips + volumes at wire speed, 16 limiters, play 12 s) | 5 iterations | 0/5 alone this session (audit saw 2 in ~35 min — the racier variant of the same throw: a player attached-but-not-yet-connected while reconcile churns) | — |

First play with a freshly deleted file *survives* (the schedule-time `bakeReader()` catch at
`PlaybackGraph.swift:2497` falls back to the still-open original `AVAudioFile` — the unlinked fd plays fine);
the *disconnected player* materializes one `project.new`/reconcile cycle later. The deterministic script is the
class's regression gate (C1). The exact disconnector inside AVAudioEngine's reconfig is deliberately NOT chased
further here — the guard in Leg 0 is origin-agnostic — filed as rider R3.

## 2. Corrections to the audit record (for the annotation)

- F1's mechanism sketch ("SwiftUI re-evaluates the display list against a stale captured reference") is
  disproven: the garbage pointer is the **current executor from leaked TLS**, not a closure capture. The
  captures were all alive.
- The class is not Canvas-specific: corpse sites now span Canvas ×4 (VibeMeter, grid ×3), GeometryReader ×1
  (ContentView, 07-06), plain `@ViewBuilder` HStack content ×1 (TransportBar, 075840). Any per-frame-hot
  isolated closure is a detector.
- The agent-visible symptom list gains the **wedge**: wire connects but every command times out, no .ips. Same
  root. (Audit F3's "instance 2 crashed" sessions likely included wedges nobody could distinguish.)
- The 07-10/07-12 `.ips` batch (AVAudioEngineGraph `_Connect`/`RemoveNode` EXC_BAD_ACCESS) is the *same
  exception family* crashing outright instead of being swallowed — the m13-a class and this class are cousins:
  AVFAudio raising where Swift can't unwind. Leg 1 armors both.

## 3. Evidence inventory (what was proven, how)

- **(A) Faulting instruction, binary-exact**: `.build/debug/DAWApp` UUID `FD41E5A2…` == all six .ips. Disassembly
  of `closure #1 in TimelineLanesView.grid.getter` (+560..+624): `ScMMa` → `ScM.shared` → `unownedExecutor`
  witness dispatch → `swift_task_isCurrentExecutor` — the SE-0423 prologue check, mid-closure after stack setup.
- **(B) Runtime path**: `swift_task_isCurrentExecutorWithFlagsImpl` disassembly: `+36 ldr x8,[TSD+0x340]`,
  `+44 ldr q0,[x8]` (current executor FROM the tracking record), `+68 bl SerialExecutorRef::isMainExecutor` =
  the corpse frame. `swift_getObjectType` `+76 brk #0xc472` == crashes 2/3 pc; `+88 ldrb [x0,#0x20]` == crash 1
  fault address (`x0+0x20`), register-exact in all three corpses.
- **(C) Live wedge necropsy**: idle main thread named `Task 6848`; TSD slot 104 → stack address; record contents
  byte-identical to crash corpses' garbage executor. (lldb transcript in scratchpad.)
- **(D) The throw, in the act**: lldb `objc_exception_throw` breakpoint during the deterministic recipe:
  `+[NSException raise:format:]` ← `AVAudioPlayerNodeImpl::StartImpl` ← `playAtTime:` ←
  `PlaybackGraph.swift:2561`, thread `'Task 1057'`, queue com.apple.main-thread; `$x0` description =
  **"player started when in a disconnected state"**. App wedged right after. (`throwhunt.log`.) The 64
  AudioToolbox-internal `__cxa_throw`s in the same log are caught inside AudioToolbox — benign noise.
- **(E) Fix-lever probes** (`canvas-probe.swift`, swiftc 6.3.3, same toolchain): plain closure w/ ref capture →
  check emitted; plain closure w/ **value-only** captures → **check still emitted**; `@Sendable` closure →
  **no check**. `-O` keeps checks; `-disable-dynamic-actor-isolation` removes all.

## 4. The fix — three legs, all mandatory

> **IMPLEMENTATION AMENDMENTS (2026-07-13, legs 0+1 landing — the deviation law):**
> **(A1) The Leg 0 predicate alone is MEASURED-INSUFFICIENT.** First hardened run: 10/10 alive, but the raise still
> fired from the play loop on a player that PASSES the public connection-points check — caught only by Leg 1's entry
> armor. Mechanism, named: iteration 1 survives because the never-run engine wires strips before first start;
> iteration 2+ raises because `rebuildEngine` (project.new) starts the fresh EMPTY engine first, and strips then
> attach to a RUNNING engine — AVFAudio's internal active-render-graph state has no public mirror. Shipped shape:
> predicate-fail skips + posts `clip-unplayable`; predicate-PASS plays inside a PER-NODE barrier whose catch posts
> the same notice and lets every other player start. The per-node barrier is what makes Leg 0 origin-agnostic;
> naming the exact AVFoundation reconfig defect remains rider R3 (this is the strongest lead for it).
> **(A2) Non-throwing transport entries do NOT rethrow.** `startPlayback`/`stopPlayback`/`seek` are non-throwing on
> `AudioEngineControlling`; converting them ripples into ProjectStore and DAWApp views and changes wire behavior.
> Shipped: guarded WIND-DOWN (players+metronome stopped inside their own barriers, anchor/loop cleared, meters dark,
> playhead pushed) + `engine-exception` notice + stderr. Throwing entries (`prepare`, `startTake`, offline renders,
> `startTestTone`) rethrow the converted error into the existing LocalizedError mapping as designed. C1 post-fix
> shows the entry armor never fires once Leg 0's per-node guard exists (0 `engine-exception` in 10 runs).
> **(A3) Wrap-table additions beyond the note:** `setTempo`, `loopChanged`, `metronomeChanged`, `startTake`/
> `startRecording`, `startTestTone` — every control-plane path that reaches a `play()`/restart seam.

### Leg 0 (root fix, DAWEngine — audio-dsp-engineer)

`startAllPlayers`/`prepareAllPlayers` must never hand a disconnected/detached player to AVFAudio.

- File: `Sources/DAWEngine/PlaybackGraph.swift` — `startAllPlayers(at:)` (:2553, the `forEachClip { $0.player.play(at: anchor) }`)
  and `prepareAllPlayers(withFrameCount:)` (:2540).
- Guard, origin-agnostic:
  ```swift
  forEachClip { node in
      guard let host = node.player.engine,
            !host.outputConnectionPoints(for: node.player, outputBus: 0).isEmpty else {
          skipped.append(node)   // collect; notice once per clip below
          return
      }
      node.player.play(at: anchor)
  }
  ```
  (Same guard shape in `prepareAllPlayers`.) Control-plane only — main-actor graph mutation path; **zero new
  render-thread surface**.
- For each skipped node, post through the existing plumbed `noticeSink` (the m15-e surface — the sink is already
  threaded to this type; see `:733`): code `"clip-unplayable"`, message naming the clip and, when
  `!FileManager.default.fileExists(atPath: node.file.url.path)`, saying the file is missing (coordinate wording
  with m16-c's `clip-file-missing` — same honesty family, different site; do NOT collapse the two items, m16-c
  still owns the build-time catch at `:747-752`).
- The guard is cheap (per transport start, not per frame) and also covers the audit's storm-flavored crashes
  (player attached-but-not-yet-connected during reconcile races).

### Leg 1 (armor at the engine seam, DAWEngine — audio-dsp-engineer)

Swift cannot catch NSExceptions; add the classic ObjC barrier so no AVFAudio raise can ever cross a MainActor
job frame again.

- New SwiftPM target `ObjCExceptionGuard` (ObjC, the `CAtomics` precedent — tiny, dependency-free;
  `DAWEngine` depends on it; **DAWCore must NOT** — the domain stays dependency-free). Plain SwiftPM/CLT —
  **no full Xcode required**.
  ```objc
  // include/ObjCExceptionGuard.h
  NSException * _Nullable DAWCatchObjCException(void (NS_NOESCAPE ^ _Nonnull block)(void));
  // impl: @try { block(); return nil; } @catch (NSException *e) { return e; }
  ```
- Swift wrapper in `Sources/DAWEngine/` (new file `ObjCExceptionBarrier.swift`):
  ```swift
  func withObjCExceptionBarrier<T>(_ context: @autoclosure () -> String, _ body: () throws -> T) throws -> T
  ```
  Converts a caught NSException to a `LocalizedError` (`engineException(name:reason:context:)`) so the standing
  wire LocalizedError mapping produces a teaching error (`"the audio engine raised '<reason>' during <context> —
  playback was stopped; play again, or reopen the project if it persists"`).
- Wrap sites: the bodies of `AudioEngine`'s public `AudioEngineProtocol`-implementing methods that reach
  AVFAudio from the control plane — at minimum `startPlayback` (`AudioEngine.swift:533` — the proven path),
  stop/seek, reconcile/rebuild, prepare, offline-render entry. On catch inside `startPlayback`: best-effort
  `stopPlayback()` (inside its own barrier), post notice `"engine-exception"`, rethrow the converted error.
  Zero-cost on the happy path (arm64 zero-cost EH); never on the render thread (barrier lives at control-plane
  entry points only — the render callback path is untouched).
- This also downgrades the m13-a-cousin family (07-10/07-12 corpses) from process-death/poison to an honest
  command error wherever the raise happens under a barrier.

### Leg 2 (Canvas hardening, DAWApp — swift-app-engineer)

Every `Canvas` renderer closure in `Sources/DAWApp` becomes **`@Sendable` with value-only captures**. `@Sendable`
is load-bearing: it makes the closure nonisolated, which (probe-proven) removes the SE-0423 check — the exact
faulting instruction — from the closure, and the compiler then *enforces* the value-capture contract forever
(a reference or MainActor-state capture is a compile error, so the convention cannot erode; this subsumes the
roadmap's "greppable convention comment" with something stronger). It also ends the
`Attribute.syncMainIfReferences` reference-walking on these attributes. Pattern per site:

```swift
// CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures only,
// computed before the closure. See docs/research/design-m16a-canvas-crash.md.
let phase = smoother.phase            // 1. snapshot everything the closure needs
Canvas { @Sendable context, size in   // 2. @Sendable
    Self.draw(state, phase: phase, …) // 3. static/free helpers only (no self)
}
```

Site table (all 17 `Canvas {` in Sources/DAWApp; DAWAppKit has none):

| # | Site | Captures today (refs in bold) | Snapshot / change |
|---|---|---|---|
| 1 | `Components/VibeMeterView.swift:43` | **`smoother`** (`VibeSmoother` class via `@State`) read as `.phase` inside (:44); `state`, `rgb`, `color` already outside | `let phase = smoother.phase` next to the existing `state` line; closure becomes `@Sendable`; `Self.draw` already static. `VibeSmoother` stays a class (advance already outside — no structural change) |
| 2 | `Timeline/TimelineLanesView.swift:512` (`grid`) | **`self`** → **`waveformStore`**, **`densityStore`**, ~20 **closure props**, `tracks`, `meterMap`, `rowHeight`, `content`, `laneTop(_:)`, `totalBeats` | Precompute value inputs: `laneCount`+`rowHeight`+lane-top offsets (or a `[CGFloat]` of tops), and a per-beat classification array `[(x: CGFloat, isBar: Bool, barLabel: String?)]` from `meterMap` (one pass, same math as today's in-closure loop); capture those + `content` + theme constants. Drawing loop body unchanged |
| 3 | `Timeline/TimelineLanesView.swift:1734` (`ClipBlock.decorations`) | **`self`** (ClipBlock: `clip`, `geometry`, `hovering`/`isSelected` `@State`, `tint`, `ppb`, **callback closures**) | Snapshot `fadeInBeats/fadeOutBeats/curves/gripBright/tint/ppb`; `fadeInPath/fadeOutPath/gripTriangle/fadeShape` become `static` taking values |
| 4 | `Timeline/TimelineLanesView.swift:1853` (`gainEnvelopeOverlay`) | **`self`** via `drawGainEnvelope(&ctx,size:)` (`envPoints`, `envX/envY`, gain range) | Snapshot `envPoints` + the affine x/y mapping params; `drawGainEnvelope` becomes `static` |
| 5 | `Timeline/TimelineLanesView.swift:2194` (`CrossfadeSeamBadge`) | none (theme statics only — `DAWTheme` statics are nonisolated `let`s, fine) | add `@Sendable` only |
| 6 | `Timeline/ClipMIDIMap.swift:27` | `notes`, `lengthBeats`, `geometry` (Sendable struct), `tint`, `opacity` — already values | add `@Sendable`; hoist `geometry` computed-prop read to a `let` |
| 7 | `Timeline/ClipWaveform.swift:119` | `peaks` (Sendable), offsets, `tint` — already values | add `@Sendable` |
| 8 | `Timeline/AutomationLaneEditor.swift:92` | **`self`** via 4 draw methods (`draft`, `lane.isEnabled`, `geometry`, `param`, `accent`, `selection`) | Snapshot a small value context struct; the 4 `draw*` methods become `static` taking it |
| 9 | `PianoRoll/KeyboardSidebar.swift:22` | **`model`** (`PianoRollModel` — plain class), `octaveLabel(self)` | Snapshot `(rowHeight, contentHeight, pitchCount)`; y-mapping is affine — compute inline or precompute row rects; `octaveLabel` → `static` |
| 10 | `PianoRoll/VelocityLane.swift:33` | **`model`** (`draft`, `x(forBeat:)`, `isSelected`), `activeNote` `@State`, `noteColor` | Snapshot `draft: [MIDINote]` (Sendable ✓), ppb mapping, selected-ID `Set`, `activeNote`, `noteColor` |
| 11 | `PianoRoll/PianoRollView.swift:585` (`PianoRollGrid`) | **`model`** via 4 draw methods | Snapshot `(rowHeight, pixelsPerBeat, clipLengthBeats, draft, selectedIDs, beatsPerBar, snapStep, noteColor)`; methods → `static`. (This view is Equatable-pinned to never redraw during playback — lowest risk; sweep for uniformity) |
| 12 | `Components/SegmentMeter.swift:20` | `meter` (Sendable ✓), `heldPeak` `@State` value, `zoneColor(self)` | `let peak = heldPeak` outside; `zoneColor` → `static`; `@Sendable` |
| 13 | `Components/MiniLevelBar.swift:28` | `meter`, `segmentCount`, `zoneColor(self)` | `zoneColor` → `static`; `@Sendable` |
| 14 | `Components/MasterVolumeFader.swift:18` | `volume`, `Self.range` (static let ✓) | hoist `fraction` computation outside; `@Sendable` |
| 15 | `Mixer/MixerControls.swift:29` (`VerticalFader`) | `fraction`/`unity` locals ✓, `accent` | `@Sendable` (locals already outside) |
| 16 | `Mixer/MixerControls.swift:122` (`PanKnob`) | `fraction` computed prop, `arc/point(self)` | hoist `fraction`; `arc`/`point` → `static`; `@Sendable` |
| 17 | `Mixer/MixerControls.swift:178` (`SendMiniFader`) | `fraction`/`unity` locals ✓ | `@Sendable` |

Prerequisites checked: `MIDINote`, `MeterFrame`, `VibeMeterModel`, `MIDIMapGeometry`, `WaveformPeaks` are already
`Sendable`; `Color`/`Path`/`Text` construction inside a `@Sendable` closure is nonisolated-legal; `DAWTheme` is an
enum of `static let`s. Any DAWCore/DAWAppKit struct that turns out non-Sendable gets an additive `: Sendable`
(value types — no semantic change). If a site resists (a capture that genuinely can't be a value), stop and
return to design — do not weaken to non-`@Sendable`.

### Rejected alternatives (and why)

- **Value-snapshot discipline without `@Sendable`** (the audit's default): measured no-op against the crash —
  the SE-0423 check stays in a plain closure with value-only captures (probe B). Rejected as the primary fix;
  it survives only as part of Leg 2's mechanics.
- **Module-wide `-disable-dynamic-actor-isolation` on DAWApp** (kills every remaining detector, incl. the
  TransportBar/GeometryReader family): rejected. It does nothing for the wedge presentation, silences a
  legitimate safety net in release too, needs `unsafeFlags`, and — decisive — it converts any *future* unknown
  poisoner's crash (diagnosable, has an .ips with the check's frame) into a silent wedge (near-undiagnosable in
  the field). After Legs 0+1 the remaining checks are wanted canaries.
- **Dropping `TimelineView(.animation)` / redesigning the smoother / display-model rewrite**: unnecessary once
  the poisoner is dead; violates the "stabilization, not refactor" mandate; visual-risk for zero mechanism gain.

## 5. What does NOT change

- **Visuals**: pixel-identical — every transform moves computation, none changes math. Gate C7 is the m15-c
  capture-review idiom.
- **RT path**: untouched. Leg 0/1 are control-plane (main-actor graph/transport calls); Leg 2 is UI-plane.
  No allocation/locks added anywhere near the render thread.
- **Wire surface**: no new/changed commands or params; pins stay 123 cmds / 126 tools / catalog 55 / Explain 69.
  One additive engine-notice code (`clip-unplayable`, plus Leg 1's `engine-exception`) — notices carry no count
  pin; FEATURES row rider goes to m16-g.
- **Perf envelope**: snapshots are the same work moved a line earlier; the barrier is zero-cost until an
  exception; the play-time guard is O(clips) once per transport start.

## 6. Gates (C-numbered)

- **C1 (primary regression gate — the deterministic repro)**: the missing-media 2-track recipe (§1 table,
  scripted: scratchpad `m16a-twotrack.mjs`; commit a copy as `scripts/gates/m16a-poison-recipe.mjs` or recreate
  from §1 — the scratchpad is session-scoped) run **×10 iterations on one instance**: zero new `.ips`
  (diff before/after), zero wedges (every command answers; a `project.snapshot` liveness probe after each
  iteration), and after each play a `clip-unplayable`-family notice present in the snapshot (honesty proof that
  the guard fired rather than the path having gone silent). Pre-fix, this recipe kills the app on iteration ≤2,
  6/6 — the gate is meaningful.
- **C2**: audit B1 storm recipe ×10 (fresh `project.new` each round: 40×(track+clip+volume) wire-speed,
  16 limiters, play 12 s, stop): zero .ips, zero wedges.
- **C3**: soak ≥15 min alternating C1/C2 recipes with `project.new` cycles: zero .ips, zero wedges, wire alive
  at the end. (Roadmap-mandated.)
- **C4**: barrier unit tests (headless, no audio): an NSException raised inside `withObjCExceptionBarrier`
  converts to the typed error (name+reason preserved); no-exception path returns the value and propagates Swift
  errors unchanged.
- **C5**: disconnected-player guard test (headless): a `PlaybackGraph` clip node whose player is attached but
  never connected → `startAllPlayers` completes without raising, posts the notice (m13-e fallback idiom for the
  sink); negative control: connected players still start (existing playback suites stay green — they are the
  proof normal start is untouched).
- **C6**: source pin: a test (DAWAppKitTests, `#filePath`-anchored scan of `Sources/DAWApp`) asserting every
  `Canvas {`/`Canvas(` renderer opens `@Sendable` — the convention cannot silently erode. Plus: compile IS the
  capture-discipline test from then on.
- **C7**: every existing captureUI gate pixel-identical pre/post (vibe meter, timeline/arrange, mixer, piano
  roll, master strip). Any diff = stop, return to design.
- **C8**: RT-safety review point: no new render-thread surface (Legs 0/1 control-plane by construction — assert
  in review, not tests).
- **C9**: full baselines green: Swift 2286/270 + npm 106/106 pre-change; expected growth **+5–7 tests / +1–2
  suites** (C4 ×2, C5 ×2, C6 ×1, optional notice-coalesce ×1) → ~2291–2293. Wire/MCP/catalog/Explain pins
  unchanged.

## 7. Implementation order & routing

1. **Leg 0 + Leg 1** — `audio-dsp-engineer` (PlaybackGraph/AudioEngine + the new ObjC target; Package.swift
   target add). Land together; C1 flips from kill-to-survive here. Tests C4/C5.
2. **Leg 2** — `swift-app-engineer` (17 sites, mechanical per §4 table; C6 pin test; C7 captures). Independent
   of legs 0/1; can proceed in parallel, but gate C1/C2/C3 runs only after ALL legs land.
3. Gates C1–C3 (staging instance, fresh 176xx port, kill-by-pid, port-verified-closed, .ips-diff hygiene),
   then C7, then suites (C9).

Riders (not blockers):
- **R1 (orchestrator)**: update `docs/ARCHITECTURE.md` "Key future decisions" — settled: "ObjC exceptions must
  never cross the engine seam: all AVFAudio-touching control-plane entry points run under the
  ObjCExceptionGuard barrier; Canvas renderers are `@Sendable` value-capture by contract." (This note's author
  is write-restricted to this file; the doc edit rides the implementation change.)
- **R2 (docs-scribe, m16-g)**: FEATURES engine-notices row gains `clip-unplayable`/`engine-exception`; audit-m16
  F1 annotation corrected per §2.
- **R3 (optional, audio-dsp)**: 30-min lldb session with the C1 script + breakpoints on
  `-[AVAudioEngine disconnectNodeOutput:]`/`detachNode:` to name the exact disconnector inside reconcile —
  informative only; the guard is origin-agnostic.
  **RESOLVED 2026-07-13 (m16-h)**: mechanism named and fixed — no disconnector exists; players born on a ≥2-deep post-start subtree are permanently start-ineligible on a running engine (`docs/research/design-m16h-reconfig.md` §3; fix = deferred rebuild start + announce-class strip birth).
- **R4 (optional)**: Apple Feedback: (a) `AVAudioPlayerNode playAtTime:` NSException from a documented-legal
  call sequence; (b) Swift runtime: ObjC exception across a job leaks `ExecutorTrackingInfo` + thread name,
  wedging the MainActor. Attach `throwhunt.log` + .ips set.
- **R5 (backlog idea, from the wedge)**: a control-plane liveness watchdog — the ControlServer's NW queue can
  detect "router unresponsive N s" and log loudly (the wedge is otherwise indistinguishable from a busy app to
  an agent). File as an m16-e/f candidate line, not part of m16-a.

## 8. Bounded honesty — what is proven vs inferred

- Proven (instruction/register/live-probe exact): the check-crash mechanism (§3-A/B), the leaked-record wedge
  (§3-C), the thrower + reason (§3-D), fix-lever behavior (§3-E), determinism of the C1 recipe (6/6).
- Inferred (high confidence, not instruction-proven): the exception's *catcher* (AppKit/runloop top-level —
  consistent with the app surviving and no exception log); the storm-flavored crashes sharing the same throw
  (same corpse signature + same command; not separately caught in the act); WHY the player is disconnected on
  the second cycle (rider R3).
- The tree under test is the dirty working tree at `0ad2e51+` (binary UUID-matched to all six corpses).
