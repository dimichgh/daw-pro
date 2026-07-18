# m19-k — Should the live graph follow the device rate at all?

**Date**: 2026-07-16 · **Author**: daw-architect · **Status**: DESIGN (no code changed)
**Filed from**: m19-j Task 3 (docs/ROADMAP.md:294–295). Rider included: the `Loudness.measure`
main-actor residual (m19-j close-out note).

---

## 0. Verdicts

| Question | Verdict | One line |
|---|---|---|
| **Big question** — live graph at PROJECT rate with explicit conversion at the output edge, instead of following the default device | **GO, probe-gated** | Both load-bearing SDK behaviors are *header-documented* (not folklore): AVAudioOutputNode converts a mismatched input-scope format, and connection formats persist across `AVAudioEngineConfigurationChange`. Given this repo's adverse priors on AVAudioEngine semantics, a Phase-0 live probe (§6) must pass before Phase 2 flips the rate; the probe has a designed fallback shape and explicit abort criteria. |
| **Rider** — `Loudness.measure` synchronous on the main actor post-render | **GO, unconditional** | `Loudness.measure` is a pure static function over a `Sendable` value type; every call site is already `async`; an explicit `Task.detached` hop (semantics-proof against SE-0338/SE-0461 executor drift) removes the last O(frames) main-actor stall of the m19-j wedge class with zero ordering changes. |

A GO here settles an ARCHITECTURE.md "Key future decisions" entry — **deliberately NOT written
in this item** (DESIGN-ONLY constraint: this file is the only artifact). The orchestrator should
add the SETTLED entry at close-out of the implementing item (§7 Phase 2), not before the probe
passes.

---

## 1. Scope and method

Question as filed (docs/ROADMAP.md:295): today the whole live graph's processing rate follows
`engine.outputNode.outputFormat(forBus: 0).sampleRate` — whatever the default output device is.
A Bluetooth headset entering mic mode drags the graph to 24 kHz: insert chains re-prepare
(limiter lookahead halves, PDC recomputes), hosted AUs hit the R7 synchronous renegotiation
(bounded main-actor stalls, bank-gated per m19-e/m19-j), and monitoring is band-limited while
the project and every offline render stay 48 kHz.

Method: I read every rate/format call site in `Sources/DAWEngine` (audit table, §2.3 — 28
sites/clusters), traced the actual rate-flip control flow (§2.2), then verified the SDK-level
claims against the macOS 26.5 SDK headers shipped with Xcode 26.6 (§3) — quoting the exact
header sentences, because this project has three documented cases of undocumented AVAudioEngine
semantics biting (m18-d process-global AudioToolbox state, m16-a raise-unwind TLS corruption,
m19-f past-anchor shifted-origin — the last resolved only by a live probe).

**Nothing in this design requires full Xcode** — no entitlements, AUv3 packaging, or signing
changes. The probe (§6) needs a loopback audio device (e.g. BlackHole) or a second physical
device whose nominal rate can be set; that is an environment dependency, not a toolchain one.

---

## 2. Current-state map

### 2.1 The one authority and its consumers

`PlaybackGraph.graphFormat()` (Sources/DAWEngine/PlaybackGraph.swift:1882–1889) is the single
definition of the live graph rate:

```swift
let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
let graphRate = outputRate > 0 ? outputRate : 48_000
```

`outputFormat(forBus: 0)` on the output node is the node's OUTPUT scope — the hardware format
live, the manual-rendering format offline (§3, Q4). So live, the graph rate is the default
output device's current nominal rate, re-read at every call. Offline, `OfflineRenderer`
constructs its own engine + `PlaybackGraph` and enables manual rendering at its own rate
(Sources/DAWEngine/OfflineRenderer.swift:223–224, :248, :435–440); production always uses the
48 kHz default (AudioEngine.swift:1252, :1297 — bare `OfflineRenderer()`).

### 2.2 What actually happens on a device-rate flip today (step by step)

Citing the m19-j diagnosis (ROADMAP.md:294) where it already proved the step; new steps below
are marked **[reasoned]** — derived from the code plus the documented format-persistence rule
(§3, Q3), not live-reproduced. The probe's P4 leg (§6) confirms them.

1. **Build-time coupling (proven, m19-j).** An engine *built* while a 24 kHz device is default
   builds every edge, chain, and AU at 24 kHz: `LimiterEffect.prepare` computes
   `delaySamples = round(0.005 × 24 000) = 120` (Sources/DAWEngine/Effects/LimiterEffect.swift:115),
   which is exactly the 240-vs-120 latency-pin failure m19-j root-caused. Offline renders pinned
   48 kHz throughout and were unaffected (m19-j: wire-gate mixdowns reported 48000 with AirPods
   connected).
2. **The flip event.** The device rate changes (BT headset enters mic mode, user switches
   devices). AVFoundation stops the engine and posts `AVAudioEngineConfigurationChange`
   (header quote in §3, Q3). Our observer (AudioEngine.swift:441–454) hops to the main actor →
   `handleConfigurationChange()` → `recoverEngine()` (AudioEngine.swift:2113–2115, :2126–2160).
3. **Restart without rebuild.** `recoverEngine()` derives the beat from the host clock, stops
   players, `engine.prepare()` + `engine.start()` on the SAME engine object, restores mixer
   params, and resumes via `startPlayers` (AudioEngine.swift:2140–2151). It never reconnects an
   edge. Per the documented rule — "The nodes remain attached and connected with previously set
   formats" (§3, Q3) — every explicitly-formatted edge keeps the OLD build rate. **[reasoned]**
4. **Rate incoherence window.** `recoverEngine` calls `graph.applyParameters(tracks:)`
   (AudioEngine.swift:2150), which reads `chainRate = graphFormat().sampleRate`
   (PlaybackGraph.swift:1355) — the output SCOPE, i.e. the NEW device rate — and re-prepares
   every strip chain and the master chain at it (PlaybackGraph.swift:1375, :1487). The streams
   feeding those chains still flow at the OLD edge rate. Limiter lookahead, PDC targets
   (PlaybackGraph.swift:1125–1281), and automation schedule frame math
   (PlaybackGraph.swift:1579, :1586) now disagree with the actual buffer rate until the next
   full rebuild. **[reasoned — a latent correctness hazard in today's design, worse than the
   filed symptom; today's "follow the device" is only coherent through a whole-engine rebuild.**]
5. **AU re-prepare storm.** The next `tracksDidChange` re-keys hosted AUs at the new rate:
   `syncAudioUnitInstruments` / `syncAudioUnitEffects` read
   `engine.outputNode.outputFormat(forBus: 0).sampleRate` (AudioEngine.swift:965–966, :1016–1017)
   into `AUHostRegistry.prepareKey(track:sampleRate:)` — a changed key releases and re-prepares
   the instrument (AudioEngine.swift:992–1003). Any instrument prepared at the registry rate but
   handed to a node at a different `graphFormat()` rate takes the R7 synchronous main-actor
   renegotiation: `deallocateRenderResources` → `setFormat` → `allocateRenderResources` → bank
   re-load (Sources/DAWEngine/AudioUnits/HostedAUInstrument.swift:121–162, bank-gated per
   m19-j/m18-d; the re-load path AUHostRegistry.swift:698–732). Bounded, logged — but a real
   main-actor stall per hosted AU per flip, and for DLS/SF2 banks a full bank re-load.
6. **Monitoring band-limit.** With a 24 kHz device, output is band-limited to 12 kHz. This is a
   DEVICE property — no graph-rate policy can fix it (community-documented AirPods HFP behavior;
   §9). The proposal does not claim to.
7. **Metronome.** Click buffers rebuild whenever the attach-time rate changed
   (Sources/DAWEngine/Metronome.swift:99–115) — a small but real per-flip reallocation.

### 2.3 The call-site audit

Every site in `Sources/` that reads a device-coupled rate/format, what it assumes, what breaks
(or doesn't) under project-rate, and the migration action. Three classes:

**Class A — reads that must become PROJECT-RATE** (today: device-coupled via
`graphFormat()`/direct output-node reads):

| # | Site | Assumes today | Under project-rate | Action |
|---|---|---|---|---|
| A1 | PlaybackGraph.swift:1882–1889 `graphFormat()` | graph rate == output-node output-scope rate; 48 k fallback for unconfigured | Becomes the injected session rate | **The** change: replace the query with an injected `graphRate` (init parameter; §7 Phase 1) |
| A2 | PlaybackGraph.swift:690 (bus mixer → mainMixer edge format) | edge at graph rate | same, now project rate | none beyond A1 |
| A3 | PlaybackGraph.swift:971–981 (send-gain / fan-out edge format) | same | same | none beyond A1 |
| A4 | PlaybackGraph.swift:1355, :1375, :1487 (chain sync rate — limiter lookahead / PDC domain) | DSP prepared at live device rate; recomputes on flip (and incoherently, §2.2 step 4) | Constant 48 k — lookahead 240 samples, PDC device-invariant by construction | none beyond A1; the m19-j sensitivity class dies here |
| A5 | PlaybackGraph.swift:1579, :1586 (automation schedule sampleRate) | automation frame math at device rate | device-invariant | none beyond A1 |
| A6 | PlaybackGraph.swift:1696–1703 (master sandwich edges; :1703 is chainHost→outputNode) | both edges at graph rate == device rate | :1701 stays project rate; **:1703 becomes the ONE conversion edge** — output node converts (§3, Q2) | code identical; semantics change; probe-gated |
| A7 | PlaybackGraph.swift:1752–1758 (strip sandwich edges) | edges at graph rate | same, project rate | none beyond A1 |
| A8 | PlaybackGraph.swift:1787–1795 (instrument `prepare(sampleRate:)`, `InstrumentRenderer` rate, source-node format) | instruments prepared at device rate; R7 fires when registry rate ≠ node rate | Always project rate; registry and node rates equal by construction → **R7 unreachable for rate reasons** | none beyond A1 |
| A9 | PlaybackGraph.swift:1910–1914 (per-track meter tap format) | tap at graph rate | project rate | none beyond A1 |
| A10 | PlaybackGraph.swift:1307–1313 `graphSampleRateForTesting` | m19-j seam: tests derive latency pins from the LIVE rate | Returns the injected rate (constant 48 k live) — the m19-j-derived assertions keep holding, now trivially | doc-comment update only |
| A11 | AudioEngine.swift:965–966 (AU instrument prepareKey rate) | registry keys at device rate → re-prepare storm on flip | keys at project rate, stable across flips | read the graph's injected rate (or the same constant) |
| A12 | AudioEngine.swift:1016–1017 (AU effect prepareKey rate) | same | same | same |
| A13 | Metronome.swift:99–115 (attach format + click buffer rate; :309–310 click sample math) | reads outputNode directly; rebuilds buffers on rate change | project rate; buffers built once, never rebuilt on flips | take the format from the engine/graph instead of querying outputNode |
| A14 | AudioEngine.swift:2229–2237 (test tone: mainMixer format, buffer, player edge) | mainMixer output format == graph rate | follows automatically (buffers must match node format — AVAudioPlayerNode.h buffer rule, §3 Q5 — and they do by construction) | none |
| A15 | AudioEngine.swift:2282–2291 (master meter tap + `MasterMixAnalyzer(sampleRate:)`) | analysis at device rate (a 24 k device K-weights at 24 k) | analysis at project rate — device-invariant LUFS/analysis (an improvement) | none |
| A16 | AudioEngine.swift:2361–2365 (debug master capture format) | capture at graph rate | project rate — C5-class gates keep sample-level evidence in the project domain | none |

**Class B — reads that must STAY device-coupled** (they are about the device, not the graph):

| # | Site | Why it stays |
|---|---|---|
| B1 | AudioEngine.swift:1848–1849, :1879–1893, :1909 (`startPlayers`: `hardwareRate` + `outputNode.lastRenderTime` → `PlaybackAnchor(anchorSampleTime:outputSampleRate:)`) | The output node's sample clock is in DEVICE frames; the anchor pairs `lastRenderTime.sampleTime` with the device rate consistently. Under project-rate this pairing is unchanged — host-time anchors (`play(at:)`, m19-f anchor-lead law) are rate-neutral. **Assumption to probe (P2)**: `lastRenderTime.sampleTime` remains hardware-domain when the input scope runs a different rate. |
| B2 | AudioEngine.swift:1982–1993 (`elapsedSeconds`: render-clock read against `anchor.outputSampleRate`) | Same clock-domain pairing as B1. |
| B3 | InputCapture.swift:39, :98 (input-node native format) | Documented hard constraint: "When rendering from an audio device, the input node does not support format conversion" (AVAudioIONode.h, §3 Q6). The capture edge MUST follow the device. Already isolated on its own engine (ARCHITECTURE.md input-capture SETTLED entry). |
| B4 | RecordingWriter (device-rate takes: RecordingWriter.swift:104–125) | Takes are written at capture-device rate; playback SRC-converts file→graph via the player's documented file-segment conversion (§3, Q5). Unchanged. Note the standing policy: takes on disk are device-rate, not project-rate (§5, cost table). |
| B5 | InputDevices.swift:160 (`kAudioDevicePropertyNominalSampleRate` read) | Device inventory/info — inherently device-scoped. (Also proves the CoreAudio property plumbing exists for the §7 "set device rate" refinement.) |

**Class C — rate-neutral / file-domain / defensive (no action; listed to close the audit):**

| # | Site | Note |
|---|---|---|
| C1 | PlaybackGraph.swift:2083–2118, :2299, :2496, :2645 (clip schedule math at `clip.file.processingFormat.sampleRate`) | Clip segments are scheduled in FILE frames; `AVAudioPlayerNode` converts file→node rate (documented, §3 Q5). Already exercised today by 44.1 k imports on 48 k devices. Device-invariant under project-rate. |
| C2 | ClipFadeBake.swift:100, :198, :300, :337 | Bakes at file rate — file-domain, untouched. |
| C3 | OfflineRenderer.swift:94–98, :241–244 | Pins its own rate; production default 48 k == project rate → live/offline DSP parity becomes exact (§4). |
| C4 | Effects/ChainHostAU.swift:193–204 | 48 k default bus format pre-negotiation; the engine renegotiates via `setFormat` at connect. Fine at any injected rate. |
| C5 | AudioUnits/HostedAUInstrument.swift:121–162 (R7 renegotiation) | Becomes unreachable for rate reasons (A8). KEEP defensively — it also guards channel-count/config drift. |
| C6 | EnginePerformance.swift:140–146 + InstrumentSourceNode.swift:115, :433 (render budget = frames / graph rate) | Internally consistent at any single graph rate; with the output-node converter the upstream pull sizes change but frames/rate still measures seconds of audio. |
| C7 | MIDISchedule.swift:151, :154, :172, :195 + InstrumentSourceNode.swift:272 (event frame math at schedule rate) | Inherits graph rate at build; becomes device-invariant (24 k quantization of MIDI event frames dies). |

**Audit size: 28 sites/clusters (16 A + 5 B + 7 C).** This audit is independent of (and wider
than) the 12-site test-side sweep recorded in the m19-j agent report; that sweep covered test
expectations, this one covers the engine.

---

## 3. SDK ground truth — documented vs folklore

All header quotes below were read today from the macOS 26.5 SDK
(`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`,
Xcode 26.6). Line references are to the SDK header files.

**Q1 — Does `connect(_:to:format:)` set formats or convert?** Documented: it sets. "If non-nil,
the format of the source node's output bus is set to this format. In all cases, the format of
the destination node's input bus is set to match that of the source node's output bus"
(AVAudioEngine.h :217–221). The engine does NOT document any general auto-converter insertion
between arbitrary nodes. Conversion capability is a property of specific NODES (Q2). The
community belief "AVAudioEngine auto-inserts converters anywhere" is **folklore** — do not rely
on it.

**Q2 — Can the output edge run at a non-hardware rate?** **Documented, twice**:

- AVAudioIONode.h :270–271 (AVAudioOutputNode): "The format of the input scope is initially the
  same as that of the output, but you may set it to a different format, **in which case the node
  will convert**."
- AVAudioEngine.h :485–492 (`mainMixerNode`): "If the client has never explicitly set the
  connection format between the mainMixerNode and the outputNode, the engine will always
  set/update the format to track the format of the outputNode on (re)start, even after an
  AVAudioEngineConfigurationChangeNotification. **Otherwise, it's the client's responsibility to
  set/update this connection format** … You may however make the connection explicitly with a
  different format."

So the exact proposal shape — an explicit project-rate format on the edge into `outputNode` —
is an Apple-documented configuration, and explicitly-set formats are documented NOT to be
auto-retracked after a device change (which is precisely the invariance we want).

**Q3 — What does a configuration change do to the graph?** Documented (AVAudioEngine.h
:885–891, `AVAudioEngineConfigurationChangeNotification`): "When the engine's I/O unit observes
a change to the audio input or output hardware's channel count or sample rate, the engine stops
itself … **The nodes remain attached and connected with previously set formats.** However, the
app must reestablish connections if the connection formats need to change (e.g. in an input
node chain, connections must follow the hardware sample rate, while in an output only chain,
**the output node supports rate conversion**)." That last clause is the strongest possible
grounding for the proposal: Apple's own config-change guidance names output-node rate
conversion as the reason an output-only chain does NOT need reconnection after a rate flip.

**Q4 — Manual rendering.** Documented (AVAudioEngine.h :445–448): "In manual rendering mode,
the output format of the output node will determine the render format of the engine" — which is
why `graphFormat()` resolves the offline rate today and why offline paths are unaffected by
device rates (m19-j evidence agrees).

**Q5 — Player and mixer conversion.** Documented: AVAudioPlayerNode.h :95–100 — "when playing
file segments, the node will sample rate convert if necessary … When playing buffers, there is
an implicit assumption that the buffers are at the same sample rate as the node's output
format." AVAudioMixerNode.h :18–19 — "The mixer accepts input at any sample rate and efficiently
combines sample rate conversions." (The mixer clause also covers the `masterSandwichEnabled ==
false` spike-graph shape, where the implicit mainMixer→output wiring auto-tracks the device and
the mixer's INPUTS convert from project rate.)

**Q6 — The capture edge.** Documented (AVAudioIONode.h :175–177, AVAudioInputNode): "When
rendering from an audio device, the input node does not support format conversion. Hence the
format of the output scope must be same as that of the input, as well as the formats for all the
nodes connected in the input node chain." The capture edge genuinely MUST follow the device —
class B3/B4 stays.

**What remains UNDOCUMENTED (probe targets, §6):**

- U1. The output-node converter's **quality and added latency**. "Will convert" says nothing
  about algorithm, group delay, or priming behavior.
- U2. Whether `outputNode.lastRenderTime.sampleTime` stays in the **hardware sample domain**
  when the input scope runs a different rate (B1/B2 pairing).
- U3. `play(at: hostTime)` **start alignment through the converter** — the m19-f anchor-lead
  law was probe-pinned at same-rate only.
- U4. Channel-count conversion at the output node under degraded BT modes (the header says
  "convert" for "a different format", unqualified — but a 2ch→1ch aggregate flip is exactly the
  kind of case where documented generality has failed this project before).
- U5. The §2.2 step-3/4 persistence-and-incoherence account of TODAY's flip behavior —
  reasoned from Q3, not live-reproduced.

---

## 4. The proposal (decision shape)

**Decision: the live graph runs at PROJECT rate — 48 000 Hz in v1, one engine-level constant —
end to end, from every source node through `mainMixerNode` and the master chain host. The single
device-facing edge, `masterChainHost → outputNode` (PlaybackGraph.swift:1703), carries the
explicit project-rate format; the output node performs the conversion to whatever the device
runs (documented, §3 Q2/Q3). The rate stops being a live query and becomes an injected
construction parameter of `PlaybackGraph`.**

Consequences, by construction:

- **Device-invariant DSP.** Limiter lookahead = 240 samples always; PDC targets, automation
  frame math, MIDI schedule frames, meter/LUFS analysis — all constant across any device
  (kills the entire m19-j sensitivity class, and the §2.2-step-4 incoherence window with it).
- **No AU re-prepare storms.** Prepare keys embed a constant rate; a device flip changes no key;
  R7 renegotiation becomes unreachable for rate reasons (kept defensively). The per-flip
  main-actor stalls and DLS bank re-loads die.
- **Exact live/offline parity.** Offline already renders at 48 k (§2.3 C3); live DSP state now
  matches it bit-for-bit in configuration. "What you hear is what you export," up to the
  device's own physical bandwidth.
- **Rate-flip handling collapses.** `recoverEngine()`'s restart-without-reconnect becomes
  CORRECT rather than accidentally tolerable: formats persist (documented), the output node
  converts at the new device rate, nothing upstream notices. No rebuild required for a pure
  rate flip. (Device *identity* changes and channel-count changes keep today's behavior.)
- **What it does NOT fix (honesty):** monitoring through a 24 kHz device is still band-limited
  to 12 kHz — that is the device, not the graph. Also the AirPods degradation trigger itself
  (mic-permission aggregate-device creation) is an OS behavior outside our control (§9,
  community source).

**Project rate = constant 48 k in v1.** There is no per-project sample-rate field today
(`ProjectDocument` has none; grep-verified), and every production offline path is hardcoded
48 k. A future `project.sampleRate` (44.1/48/88.2/96 k) is additive: the injection parameter is
already threaded, offline takes the same value, and the ARCHITECTURE.md project-format rules
(additive optional fields need no schema bump) cover persistence. That future field — not
device-following — is the correct answer to "I want a 96 k session" (see §5, hybrid).

---

## 5. Alternatives compared

**(a) Status quo + targeted hardening** — keep following the device; extend the m19-j Task-1
direction (derive every expectation and DSP parameter from the live rate, everywhere, forever).
*Why it loses:* the sensitivity class survives by design — every future rate-dependent feature
(new effects with lookahead, groove/quantize frame math, analysis) must re-derive; AU re-prepare
storms and R7 stalls remain user-visible on every BT transition; live≠offline DSP configuration
remains; and the §2.2-step-4 incoherence window (chains re-prepared at the new rate while edges
stream the old one) still needs a fix, which — because the documented fix is either "reconnect
everything" or "let the output node convert" — ends up building half of proposal (c) anyway,
while keeping all of (a)'s costs.

**(b) Hybrid — follow the device for sane rates (44.1/48/88.2/96 k), refuse degraded rates
(24 k/16 k BT mic mode) with project-rate + output conversion only then.** *Why it loses:* it
requires BOTH machineries — the full follow-the-device re-prepare path AND the conversion edge
AND a policy table deciding "sane" — and keeps re-prepare storms for the common 44.1↔48 device
swap. The test matrix doubles (every latency/PDC/automation gate at both policies). Its one real
advantage — a 96 k interface mixes at 96 k with >24 kHz program bandwidth — conflates device
rate with project rate; the pro answer is the future project-rate SETTING (§4), which composes
with (c) and not with (b). Note the pro-DAW norm is actually a third thing: Logic-class DAWs SET
the device's nominal rate to the project rate and convert only when the device can't comply —
that refinement layers cleanly on (c) as a follow-up (§7, Phase 3+) using the
`kAudioDevicePropertyNominalSampleRate` write (the read already exists, InputDevices.swift:160).

**(c) Project-rate always (chosen)** — one machinery, one conversion edge, documented SDK
behavior, invariance by construction. Costs, stated honestly:

| Cost | Assessment |
|---|---|
| One SRC stage on the live path | Stereo, one edge, inside the output node. CPU negligible against per-strip DSP. Quality/latency undocumented → probe U1/P3; abort threshold in §6. Offline renders NEVER cross it (manual rendering at project rate — §3 Q4), so deliverables are converter-free by construction. |
| Monitoring latency + a converter group delay | Additive ms-scale at worst; monitoring latency is already uncompensated (PDC is graph-internal). Measured by P3. |
| 96 k interfaces monitor a 48 k program | Identical bandwidth to today's EXPORTS (always 48 k). Today's live-96k/offline-48k split is itself a parity bug in the other direction. Future project-rate field resolves properly. |
| Capture edge still device-rate | Unavoidable (documented, §3 Q6) and already isolated (separate engine, host-time alignment). Takes recorded on a 96 k interface play through the documented file→node conversion (§3 Q5) — full fidelity preserved on disk, band-limited only in the 48 k mix. |
| Buffers scheduled on players must match node format | Already true (documented, §3 Q5); all our buffer producers (metronome clicks, test tone, fade-bake CAFs at file rate via segment path) follow the graph/file rule today. |
| Risk: undocumented converter behavior at the output edge | The load-bearing residual. Handled by the Phase-0 probe with a designed fallback shape (explicit `AVAudioMixerNode` SRC stage before the output node — mixer-input SRC is independently documented, §3 Q5) and NO-GO abort criteria (§6). |

---

## 6. Failure modes and the Phase-0 probe (design only — DO NOT build in this item)

**Probe idiom**: the m19-f past-anchor probe — a standalone Swift script (scratchpad, never
shipped, run with plain `swift` under CLT), against live hardware, N≥5 runs per leg, printing
measured numbers; the design doc records pass thresholds up front so the probe can't be
goal-post-moved.

**Environment**: a loopback device (BlackHole 2ch recommended) set as default output, with its
nominal rate settable via `kAudioDevicePropertyNominalSampleRate` writes from the probe itself;
a capture `AVAudioEngine` on the BlackHole input side records what the device "played".
AirPods-class BT hardware as an optional extra leg when present (not gateable — availability is
environmental, as m19-j learned when the AirPods vanished mid-item).

**Topology under test**: `AVAudioPlayerNode → mainMixerNode → (ChainHostAU-shaped passthrough
AVAudioUnitEffect) → outputNode`, all edges explicit 48 k stereo — the production shape of
PlaybackGraph.swift:1701–1703 in miniature. Control topology: same, all edges at the device
rate.

| Leg | Question (maps to §3 U-items) | Measure | Pass |
|---|---|---|---|
| P1 | U1-correctness: does the output edge at 48 k over a 44.1 k device convert (not resample-by-relabeling, not throw)? | Engine starts; render a 997 Hz project-rate sine; FFT the BlackHole capture | peak at 997 Hz ± 1 Hz; no exception; no silence |
| P2 | U2+U3: clock domains + anchored starts through the converter | `play(at: hostTime anchor)`; measure onset in the capture vs anchor; separately, regress `outputNode.lastRenderTime.sampleTime` against wall time | onset error ≤ 1 device quantum + a constant (converter prime) that is STABLE across 5 runs; sampleTime slope == device rate (proves B1/B2 pairing) |
| P3 | U1-latency: converter-added latency | onset delta test-vs-control topologies; `outputNode.presentationLatency` before/after | added latency ≤ 15 ms (monitoring feel); RECORD the number either way |
| P4 | U5 + Q3: live rate flip with formats persisting | flip BlackHole nominal 44.1→48→96 k mid-play; on each `AVAudioEngineConfigurationChange`, restart WITHOUT reconnecting (the `recoverEngine` shape); re-run P1's pitch check; read back the output edge's input-scope format | audio resumes at correct pitch each flip; input scope still reports 48 k; no exception |
| P5 (opportunistic) | U4: channel-count flip | if a mono/aggregate device can be staged: same as P4 across 2ch→1ch | resumes without exception (any pass/fail here informs whether channel flips keep the rebuild path) |

**Abort ladder**: P1 or P2 fails → re-run both against the fallback shape
(`masterChainHost → srcMixer(AVAudioMixerNode, output at device rate) → outputNode`; mixer-input
SRC is documented independently, §3 Q5, and the srcMixer would exist ONLY when device ≠ project
rate so offline and same-rate-live topologies stay byte-identical). Fallback also fails → the
big question flips to **NO-GO**, falling back to alternative (b) hybrid with these probe results
attached as the evidence. P3 over threshold → GO stands but the §7 Phase 3+ device-rate-setting
refinement is promoted from optional to required (converter engaged only on can't-comply
devices).

**Failure modes beyond the probe's reach, and their guards:**

- F1 *Same-rate regression*: at 48 k device == project rate, the topology and all formats are
  byte-identical to today — no converter engages. Guard: existing C8 SHA gates + full suites
  must pass UNCHANGED in Phase 1/2 (§7).
- F2 *Anchor law interaction*: `startPlayers`' anchor-lead scaling (m19-f R2′,
  AudioEngine.swift:1866–1875) is host-time based and rate-neutral; P2 confirms the one crossing
  point. Restart-on-flip keeps the SAME code path (`recoverEngine → startPlayers`).
- F3 *Watchdog interplay*: rate flips no longer change DSP state, so the flip path does LESS
  main-actor work than today; the m18-b wedge monitor thresholds are unaffected.
- F4 *Spike graphs / masterSandwichEnabled == false*: implicit mainMixer→output auto-tracks the
  device (documented, §3 Q2) and the MIXER converts its project-rate inputs (documented, §3
  Q5) — covered without extra code.
- F5 *Third-party AUs that misbehave at 48 k?* They already run 48 k in every offline render;
  this makes live match. No new exposure.

---

## 7. Migration plan (phased; each phase independently gated)

**Phase 0 — the probe** (§6). Roadmap item: "m19-k-p0: output-edge SRC probe (design §6 of this
doc)". Route: audio-dsp-engineer. Gate: all legs' numbers recorded; P1/P2 pass on primary or
fallback shape. No repo changes (scratchpad script only; results pasted into the roadmap
record).

**Phase 1 — inject the rate (zero behavior change).**
- `Sources/DAWEngine/PlaybackGraph.swift`: add `private let graphRate: Double` set at init;
  `graphFormat()` (:1882) returns the injected rate; delete the outputNode query and the 0-guard.
- `Sources/DAWEngine/OfflineRenderer.swift` (:223–224, :435–436): pass its `sampleRate` in.
- `Sources/DAWEngine/AudioEngine.swift`: pass the CURRENT device rate at engine/graph
  construction (init and `rebuildEngine`) — build-time semantics, identical to today's behavior
  everywhere except the §2.2-step-4 incoherence window, which this ALREADY fixes (a mid-life
  flip no longer half-updates chain rates; coherence until rebuild).
- `Metronome.attach` (:99) and the AU prepare-key sites (AudioEngine.swift:965, :1016) read the
  same injected value (a small accessor on `PlaybackGraph` or a stored `AudioEngine` property).
- Tests: full suite green UNCHANGED (2700+/300-class), C8 SHA gates unchanged,
  `graphSampleRateForTesting` still reports the live value (== device at build, so the m19-j
  derived pins still hold on any device). Gate additionally: zero behavior diff at a 48 k device
  (forced-recompile suite + npm 13/13 integration).

**Phase 2 — flip the injection to project rate.**
- `AudioEngine`: `public static let projectSampleRate: Double = 48_000` (doc-commented as the
  v1 constant, future `project.sampleRate` seam); live graphs inject it. Offline unchanged
  (already 48 k).
- No edge-construction code changes — PlaybackGraph.swift:1703 becomes the conversion edge by
  virtue of the injected format.
- `recoverEngine()` unchanged (documented format persistence, §3 Q3, probe-confirmed P4).
- Tests/gates: (i) full suites at a 48 k device — must be byte-identical (no converter engaged);
  (ii) the **live invariance gate** (orchestrator-style, BlackHole staged at 44.1 k as default
  output): `graphSampleRateForTesting == 48_000`, limiter latency pins read 240, `auDesired`
  keys unchanged across a staged rate flip, debug master capture pitch-correct, wire-liveness
  probe clean during the flip (the m19b-orch/orch-wire-liveness.mjs shape); (iii) npm
  integration 13/13.
- THIS phase's close-out writes the ARCHITECTURE.md "Key future decisions" SETTLED entry
  (graph-rate law: project-rate live graph, conversion at the output edge, capture edge
  device-rate, anchor math device-domain) and updates the `graphSampleRateForTesting` doc
  comment (PlaybackGraph.swift:1307–1312) whose current text hard-codes the follow-the-device
  story.

**Phase 3 — flip-path proof + storm-death regression.**
- A live orchestrator gate flipping BlackHole nominal rate mid-play: playback resumes, meters
  flow, ZERO AU re-prepares (assert via registry seam / stderr absence of the
  HostedAUInstrument.swift:156 renegotiation line), zero wedge-log growth.
- Keep the FXPack1 24 k formula leg (it tests `LimiterEffect.prepare` at an injected 24 k —
  still valid for any future non-48 k session rate) and the m19-j rate-derived assertions
  (now constant-valued live; they become the invariance pins).

**Phase 3+ (optional refinements, separate items, NOT prerequisites):**
- Set the output device's nominal rate to the project rate when the device supports it
  (`kAudioDevicePropertyNominalSampleRate` write; Logic-class behavior) so the converter engages
  only on can't-comply devices. Needs a politeness policy (shared default device).
- `project.sampleRate` as an additive ProjectDocument field + wire/MCP surface, once a real
  user need appears (96 k sessions).

**Explicitly requires full Xcode: nothing in any phase.**

---

## 8. Rider — `Loudness.measure` off the main actor (m19-j residual)

### 8.1 Grounding

`Loudness.measure(_:)` (Sources/DAWCore/Loudness.swift:139) is pure, synchronous, O(frames) —
per-sample K-weighting IIRs plus 4× polyphase true-peak over the whole buffer — and today runs
ON the main actor immediately after each cooperative render, at six call sites:

| Call site | Context | What follows the call |
|---|---|---|
| ProjectStore+Render.swift:40 | `measureLoudness` | nothing — result returned |
| ProjectStore+Render.swift:84 | `renderBounce` input measure | gain decision (locals only) |
| ProjectStore+Render.swift:106 | `renderBounce` output re-measure (after `applyGain` :104) | file write :113 |
| ProjectStore+Render.swift:194 | `renderStems` per-stem measure | file write :196 (same pass) |
| ProjectStore+Render.swift:221 | `renderStems` mixdown measure | file write :222 |
| ProjectStore+Bounce.swift:117 | `bounceTrackInPlace` | file write :125, then `performEdit` :144 |

m19-j fixed the RENDER loop's main-actor occupancy (cooperative quanta + yields) but left
measurement synchronous — for a long program this is the same wedge class (m18-b monitor,
2.5 s threshold) at a smaller magnitude. I did not measure the wall time (disclosure §10); the
structure alone qualifies it: unbounded in program length, on the main actor.

`RenderedAudio` (Sources/DAWCore/RenderedAudio.swift:7) is a `Sendable` value type —
`[[Float]]` + rate — so the hop is legal by construction.

### 8.2 Design

One helper in DAWCore (keeps DAWCore dependency-free; pure Swift concurrency):

```swift
// Sources/DAWCore/Loudness.swift
extension Loudness {
    /// `measure(_:)` off the caller's actor: identical result (pure function,
    /// determinism test-pinned), but the O(frames) work runs on the global
    /// concurrent executor so a long program never wedges the main actor
    /// (the m19-j residual). Explicit Task.detached — NOT a nonisolated async
    /// function — so the executor is pinned regardless of SE-0338 vs SE-0461
    /// (NonisolatedNonsendingByDefault) language-mode semantics.
    public static func measureDetached(_ audio: RenderedAudio) async -> LoudnessMeasurement {
        await Task.detached(priority: .userInitiated) { measure(audio) }.value
    }
}
```

All six call sites become `await Loudness.measureDetached(audio)` — every enclosing function is
already `async throws`, and every caller consumes the result strictly before its next statement,
so ordering is unchanged by construction; only the executor of the measurement changes.

**Ordering guarantees the callers actually need (verified by reading each):**

- *Sequential dependency everywhere*: each site uses the measurement immediately (gain math,
  report fields). The await preserves this trivially. **No pipelining** — do NOT overlap a
  stem's measure with the next stem's render: it would break the one-stem-alive memory contract
  (ProjectStore+Render.swift:203–204).
- *Main-actor reentrancy*: each new suspension point lets wire commands interleave. In
  `renderBounce`/`measureLoudness`, all post-await code touches only locals + the captured
  `engine` reference — no store state re-read → no new hazard. In `renderStems`, the loop
  already awaits `renderOffline` per pass and re-reads `tracks` at :187 — the mid-export
  mutation window PRE-EXISTS; the measure-await widens it without adding a new class (the
  descriptor list, window, and PDC targets are snapshotted up front, so passes stay mutually
  consistent). In `bounceTrackInPlace`, the `performEdit` body re-resolves indices fresh
  (:145–:148) — already await-tolerant.
- *CoW note (renderBounce only)*: `audio` is a `var` mutated by `applyGain` (:104) after the
  input measure. The detached task's capture is released at task completion, which `.value`
  awaits — but if any release straggles, `applyGain` pays a one-time CoW copy (~230 MB transient
  for a 10-min stereo program — same order as the render's own working set). Acceptable;
  implementer should keep the closure capture minimal (`[audio]`, no self) as shown.

**Deliberately OUT of this rider (disclose, file separately):** `applyGain`
(ProjectStore+Render.swift:104) and `engine.writeAudioFile` (:113, :196, :222,
ProjectStore+Bounce.swift:125) remain synchronous main-actor O(frames)/disk work — the same
wedge class, smaller constants. A follow-up item can ride the identical detached-hop pattern
(`RenderedAudio` in, value out) once measured to matter.

### 8.3 Tests / gates

- Unit: `measureDetached` result `==` `measure` on the same buffer (the existing determinism
  pin makes this exact equality, not tolerance).
- Liveness: re-run the m19-j orchestrator gate shape (`m19b-orch/orch-wire-liveness.mjs`) with
  a LONG program over the wire — post-rider, the probe-latency ceiling must hold through the
  measurement tail, not just the render (pre-rider, the tail contains the measure stall).
- Full suites + npm integration unchanged.

Roadmap item: "m19-k-r: Loudness.measure detached hop (design §8)". Route:
audio-dsp-engineer or swift-app-engineer; small.

---

## 9. Sources

**SDK headers (primary; quoted verbatim in §3)** — macOS 26.5 SDK, Xcode 26.6, paths under
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AVFAudio.framework/Versions/A/Headers/`:
- `AVAudioEngine.h` — connect semantics (:217–221), mainMixerNode explicit-format + config-change
  responsibility (:485–492), manual-rendering render format (:445–448),
  `AVAudioEngineConfigurationChangeNotification` incl. "the output node supports rate
  conversion" (:885–891).
- `AVAudioIONode.h` — output-node input-scope conversion (:265–271), input-node no-conversion  (:175–177).
- `AVAudioMixerNode.h` — mixer input SRC (:18–19).
- `AVAudioPlayerNode.h` — file-segment SRC, buffer same-rate assumption (:90–100).

**Apple online docs (mirror the header text)**:
- https://developer.apple.com/documentation/avfaudio/avaudioengine/mainmixernode
- https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification

**Community sources (marked as such; anecdotal weight only)**:
- C. Liscio, "More on AVAudioEngine + AirPods" (2021),
  https://supermegaultragroovy.com/2021/01/28/more-on-avaudioengine-airpods/ — the
  mic-permission aggregate-device mechanism that drags AirPods into degraded duplex mode on
  macOS; grounds §2.2 step 6 and the "the trigger is OS-side" honesty note. (Rates cited there,
  48 k/16 k, differ from the 24 k m19-j measured on current OS/AirPods — the MECHANISM is the
  relevant part, not the constants.)
- Apple Developer Forums threads 88144, 663126 (sample-rate conversion in AVAudioEngine) —
  community patterns; used only as evidence that mismatched-rate TAPS (not connections) are a
  known crash class, which this design never creates (all taps use the tapped node's own
  format: PlaybackGraph.swift:1914, AudioEngine.swift:2291, :2365).

**In-repo evidence**:
- docs/ROADMAP.md:294 (m19-j: root cause, cooperative render, R7/bank gates, residual filing),
  :295 (m19-k filing), :283 (m18-d law), :301 (m19-e prepare-gate closure).
- docs/ARCHITECTURE.md:151–214 (sequencer clock SETTLED; anchor-lead law m19-f R2′;
  schedule-gated starts R1), :217 (m16-h start-era law), :218 (gapless loop / restart
  primitive), :219–227 (input capture SETTLED).
- Source anchors as cited inline throughout §2 (all read today at HEAD 31a46aa).

---

## 10. Disclosures (what was NOT verified)

1. **§2.2 steps 3–4 (format persistence + rate-incoherence window on a mid-session flip) are
   reasoned from the documented Q3 rule plus code reading — not live-reproduced.** Probe leg P4
   doubles as their confirmation. m19-j's live evidence covers only the build-time coupling
   (step 1).
2. **Output-node converter quality/latency (U1) and clock-domain behavior (U2/U3) are
   undocumented** — that is exactly why the GO is probe-gated (§6) rather than unconditional.
3. **`Loudness.measure` wall time was not measured** (§8.1). The rider's GO rests on the
   structural argument (unbounded O(frames) on the main actor, same class m19-j just fixed for
   the render loop); the liveness gate in §8.3 measures it as a side effect.
4. **Test-file line anchors** for the m19-j latency pins (MasterChainRenderTests :249/:263/:264,
   EngineRebuildTests :193–:217) are cited from the roadmap record, not re-read here (Tests/ was
   outside this item's read focus; all Sources/ anchors were read directly).
5. The m19-j agent report's 12-site test-sweep list was not available to me; the §2.3 audit is
   an independent engine-side sweep and may overlap it only partially.
6. Task-object capture-release timing in §8.2's CoW note is a Swift-runtime detail I could not
   pin from documentation; the note states the worst case honestly.
