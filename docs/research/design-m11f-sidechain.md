# Design spike (m11-f/2): Sidechain routing

**Status: DESIGN ONLY — no code changes. Gates M12 implementation.**
**Author: daw-architect, 2026-07-11.**
**Scope:** the roadmap item text (docs/ROADMAP.md:197): *"sidechain routing — reconcile with the one-audio-input-per-strip render invariant."*

Every claim about current behavior cites file:line evidence read for this spike; web-sourced claims are marked **[web]**. Anything unverifiable is marked UNVERIFIED.

---

## 1. Decision (summary up front)

**Option A: a post-fader graph edge from the source strip's mixer into a second input bus on the destination strip's `ChainHostAU`, keyed effects (built-in compressor + gate first) reading the pulled key buffer through a new optional `KeyableEffectRendering` seam. One key source per strip in v1. Stem/bounce equivalence is preserved by extending `StemPlan.passTracks` with the existing silent-dummy-bus mechanism. Gated by ONE spike test: AVAudioEngine must connect a node to input bus 1 of an effect node — currently UNVERIFIED.**

Recommendation: **GO-WITH-CONDITIONS** (§9) — the spike test is condition zero; if it fails, the recommendation flips to NO-GO/park (§6, fallback analysis).

---

## 2. The one-audio-input-per-strip invariant, located and quoted

The invariant was named by the m10-q audit:

> docs/research/audit-m10q-pro-parity.md:85
> "The per-strip effects architecture (`EffectRendering` seam, `ChainHostAU`, M4-ii) is built around **one audio input per strip** — each strip's chain processes only that strip's own signal. There is no mechanism today for a second track's signal to reach another strip's compressor/gate as a key input."

Where it physically lives:

**(a) The strip sandwich is a single series path.**
> Sources/DAWEngine/PlaybackGraph.swift:84–92
> ```
> /// One audio track's strip (M4 ii sandwich):
> ///
> ///     clip players → sumMixer (SRC/sum only, unity, no tap)
> ///                  → chainHost (permanent insert point)
> ///                  → mixer (fader/pan/mute, meter tap, fan-out source)
> ```
(buses identical: PlaybackGraph.swift:123–133.)

**(b) `ChainHostAU` declares exactly one input bus** and pulls it in place:
> Sources/DAWEngine/Effects/ChainHostAU.swift:104–107
> ```
> private let inputBus: AUAudioUnitBus
> private let outputBus: AUAudioUnitBus
> private lazy var _inputBusses = AUAudioUnitBusArray(
>     audioUnit: self, busType: .input, busses: [inputBus])
> ```
> ChainHostAU.swift:174–176
> ```
> var pullFlags = AudioUnitRenderActionFlags()
> let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
> ```
(the literal `0` is the single input bus; ARCHITECTURE.md:421: "Its render block pulls input in place (output ABL handed to `pullInputBlock`) and walks the chain".)

**(c) The effect seam processes ONE in-place buffer:**
> Sources/DAWEngine/Effects/EffectRendering.swift:8–10, 20–21
> ```
> /// Effects process IN PLACE (no ping-pong buffers in the chain walk); an
> /// effect that needs a dry copy keeps an internal preallocated scratch. …
> /// Process exactly `frameCount` frames IN PLACE (non-interleaved Float32).
> func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int)
> ```
Hosted AUs also render main-bus-only: `HostedAUEffect.process` calls `renderBlock(…, 0, scratchABL, pullInput)` (HostedAUEffect.swift:171–172 — inputBusNumber literal `0`).

**Places that ASSUME the invariant** (each gets a §5 treatment):
- **PDC** models a strip as one linear chain with one input: `PDCStripInput.chainLatencyAll/Active` sums a single series chain (Sources/DAWCore/LatencyCompensation.swift:34–46); the compensation ring sits "post-chain, pre-fader — aligns this strip's output (and every send tap downstream)" (ChainHostAU.swift:51–56, 192–195). Nothing models a *second* arrival time into a strip.
- **Stem passes** partition strictly by routing/send edges: `StemPlan.passTracks` selects contributors by `outputBusID == stem.id || sends.contains { $0.destinationBusID == stem.id }` (Sources/DAWCore/StemPlan.swift:176–178). A sidechain edge is invisible to it → a solo'd pass would render the keyed compressor WITHOUT its key signal, changing its gain reduction → **Σ stems ≠ mixdown**, breaking the normative invariant "Σ stems ≡ the mixdown, null residual peak ≤ 1e-4" (StemPlan.swift:93–96) and with it m11-e's bounce byte-equivalence (ROADMAP m11-e: bounce vs `render.stems` "**BYTE-IDENTICAL** (SHA-256 …)").
- **Offline render** builds the identical graph via `graph.reconcile(tracks:)` (Sources/DAWEngine/OfflineRenderer.swift:185) — whatever edge shape we add must form identically there or offline/live parity dies.
- **Routing reconcile** knows only output + send edges: `RoutingKey { outputBusID, sends }` (PlaybackGraph.swift:108–121) drives the one fan-out connect `engine.connect(mixer, to: points, fromBus: 0, format:)` (PlaybackGraph.swift:686–690).

---

## 3. Hosting reality survey (how sidechain inputs actually work on macOS)

- **AUv3**: an effect exposes additional entries in `inputBusses` (`AUAudioUnitBusArray`); the host pulls each bus via the render block's `pullInputBlock` with the bus index parameter. **[web]** Apple Developer Forums confirm the convention: "Logic typically uses Input bus 0 as the AU input and the next input bus as a sidechain input" and that hosts should enable all input busses ([v3 Audio Units and Sidechain, Apple Developer Forums](https://developer.apple.com/forums/thread/50979); [au_multi_bus, Audiobus wiki](https://wiki.audiob.us/doku.php?id=au_multi_bus)).
- **AUv2**: additional input **elements** (busses) declared via `kAudioUnitProperty_ElementCount` on the input scope; the host feeds element 1 with `kAudioUnitProperty_MakeConnection` or a render callback. **[web]** Apple's Audio Unit Programming Guide: "Additional buses are helpful if you are building an audio unit that contains a primary audio data path as well as a sidechain path" ([The Audio Unit, Apple archive](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitProgrammingGuide/TheAudioUnit/TheAudioUnit.html); [Audio Unit v2 C API](https://developer.apple.com/documentation/audiotoolbox/audio-unit-v2-c-api)).
- **Apple's own dynamics AUs** (`AUDynamicsProcessor` etc.): no sidechain input bus is documented on the macOS system units; Logic's sidechain is host-level routing into its own plugins ([Compressor side chain parameters in Logic Pro, Apple Support](https://support.apple.com/guide/logicpro/compressor-side-chain-parameters-lgce0b2501de/mac)) **[web]**. UNVERIFIED whether any system AU on this machine reports >1 input element — irrelevant to v1, which keys only our built-ins.
- **DAW conventions for the tap point** **[web]**: Ableton Live offers Pre FX / Post FX / Post Mixer, default **Post FX** ([Routing and I/O, Ableton manual](https://www.ableton.com/en/manual/routing-and-i-o/)); Logic feeds sidechains from sends whose default is **post-pan** ([Pre/Post-fader explained, whylogicprorules.com](https://whylogicprorules.com/pre-fader-post-pan-explained/); [Sidechain Compression in Logic, alijamieson.co.uk](https://alijamieson.co.uk/2017/09/18/sidechain-compression-logic/)).
- **Our own graph host**: AVAudioEngine exposes `connect(_:to:fromBus:toBus:format:)` and connection-point fan-out (used at PlaybackGraph.swift:686–690). Whether it honors `toBus: 1` on an `AVAudioUnitEffect` whose AU declares two input busses is **UNVERIFIED — this is the gating spike** (§9 phase S-0). Precedent for de-risking exactly this way: the in-process `registerSubclass` + synchronous `AVAudioUnitEffect(audioComponentDescription:)` path was "proven working from the bare-SPM/CLT process by the gating spike test" before M4-ii was built on it (ARCHITECTURE.md:421).

---

## 4. Design options evaluated

### Option A (RECOMMENDED): post-fader tap = a real graph edge into `ChainHostAU` input bus 1

Source strip's `mixer` (the existing fan-out source, PlaybackGraph.swift:88) gains one more `AVAudioConnectionPoint` → destination strip's `chainHost`, `toBus: 1`. `ChainHostAU` declares a second input bus + preallocated key scratch (its existing `Scratch` discipline, ChainHostAU.swift:62–86); its render block pulls bus 0 in place as today, then — iff a key is connected (atomic flag, the `bypassFlag` pattern) — pulls bus 1 into the key scratch and hands it to the chain walk. `EffectChainProcessor.process` gains an optional key ABL parameter; effects opt in via:

```swift
protocol KeyableEffectRendering: EffectRendering {   // DAWEngine/Effects
    /// key == nil ⇒ self-keyed (today's behavior, bit-exact).
    func process(buffers: …, key: UnsafeMutableAudioBufferListPointer?, frameCount: Int)
}
```

v1 consumers: `CompressorEffect` + `GateEffect` (their peak detectors read the key buffer instead of the main buffer; gain still applies to the main buffer — a ~10-line change each given both already separate detector from gain stages, per the ARCHITECTURE.md:421 descriptions "instant-attack/5 ms-decay peak detector → … gain signal" / "the compressor's 5 ms-decay linked peak detector").

- **Cycles**: impossible to wire silently — but must be *rejected*, not discovered by AVAudioEngine. New pure DAWCore validation: directed graph over {track→outputBus, track→sendBus, keySource→destStrip} edges; reject `sidechainWouldCreateCycle` naming the path (e.g. A outputs into bus B while B's chain is keyed by A → B→A + A→B = cycle). Buses can't feed buses today (two-level topology, LatencyCompensation.swift:22–23), so the check is tiny and exhaustively testable.
- **Scheduling order**: a graph edge means AVAudioEngine pulls the key source *before* the destination strip renders — **same-quantum, deterministic, live and offline**. This is the decisive property (see Option B′ for why taps lose it).
- **PDC alignment, quantified**: the key is tapped post-fader, i.e. downstream of the source's compensation ring — "upstream of the strip mixer's fan-out, so the dry feed and every send tap are aligned by the SAME delay" (ChainHostAU.swift:53–55). The PDC planner already treats any post-chain tap as a send: "`hasSends` is true when the track has at least one send (pre- or post-fader — both tap downstream of the chain, so they are identical for latency)" (LatencyCompensation.swift:27–29) — so v1 marks a key-tapped source `hasSends: true`, padding it to stage T deterministically. Residual skew at the keyed effect: the key arrives aligned to T; the main signal at chain slot k has accumulated only ℓ_before = Σ active latencies of earlier effects in that strip's chain. **Skew = T − ℓ_before samples (key late when positive).** Typical sessions: T = 0 (all built-ins except the limiter report 0 latency; limiter = 240 samples @48 kHz, ARCHITECTURE.md:421) ⇒ skew 0. Worst realistic single-limiter case: 240 samples = **5 ms** key-late — audible only for the tightest EDM pumping; hosted-AU chains can push it higher (AUPeakLimiter 96 @48k; ring cap 16 384 = 341 ms is the theoretical bound, LatencyCompensation.swift:91–92). v1 policy: **report, don't hide** — the exact `PDCStripPlan.skewSamples` precedent ("One delay per strip cannot satisfy both constraints; reported, not hidden", LatencyCompensation.swift:78–82): surface `sidechainSkewSamples` on the PDC report + snapshot. Phase 2 (flagged, optional): the keyed effect reports `latencySamples += max(0, T − ℓ_before)` and delays its MAIN input by the same amount (preallocated ring, the CompensationDelay pattern) — exact alignment, absorbed by the normal PDC recompute; deferred because it couples chain latency to global topology and v1's typical skew is 0.
- **Offline render + stems + bounce equivalence**: offline builds the same edge via the same reconcile (OfflineRenderer.swift:185) — parity free. Stems: extend `StemPlan.passTracks` so every pass *whose tracks host a keyed effect* also includes the key-source track **routed to the silent dummy bus** — the mechanism already exists verbatim for send-only contributors: "its direct out rewritten to a fresh SILENT DUMMY BUS … The dummy exists because a source track's direct out must keep running (post-fader sends tap the strip output) yet must not reach master" (StemPlan.swift:146–153). The key source's signal then exists to key the compressor but adds nothing to the stem's audio ⇒ each stem renders with the SAME gain-reduction curve as in the mixdown ⇒ **Σ stems ≡ mixdown survives**, and m11-e bounce (which reuses `StemPlan` + the same window/PDC forcing, Sources/DAWCore/ProjectStore+Bounce.swift) stays byte-identical to its stem — both re-gated (§9). Note the `.track` stem arm currently returns `[T with sends = []]` (StemPlan.swift:159–164); it grows the same key-source+dummy inclusion. Full-session forced PDC is already the rule for stems ("requires every pass to run under the FULL-SESSION PDC plan", StemPlan.swift:94–96) — key alignment is therefore identical across passes.
- **RT-safety**: new render-thread work = ONE extra `pullInputBlock(bus 1)` call into a preallocated scratch + pointer-passing to the walk. No allocation, no locks, no ObjC beyond the sanctioned pull-block call class; key-connected state is a `daw_atomic_u32` (the documented scalar-flag shape, ARCHITECTURE.md:42). Ring/scratch (de)allocation only in `allocateRenderResources` (the existing `Scratch`/`CompensationDelayState` window, ChainHostAU.swift:126–141). **No new RT exceptions needed.**
- **Live rewire**: a key set/clear is a routing mutation → rides `RoutingKey` (extended with `sidechainEdges`) → `willMutateRoutingTopology` quiesce-stop-rewire-resume (AudioEngine.swift:267–280, the settled M4-i discipline). Cost: the documented stop/resume bounce on live key changes — same as adding a send mid-play. Acceptable; precedented.
- **Undo/wire complexity**: one model field + one command + one reconcile-key extension (§7). Small.

### Option B: bus-based (key source must be a bus)

The key selector only offers existing buses; a "key off the kick" workflow requires routing the kick through a bus first (or adding a send to a new bus). Evaluation: identical engine mechanics to A (the edge just starts at `busNodes[id].mixer`) — so it saves *nothing* in the engine — while adding real user friction versus every reference DAW (Logic/Live key off any track/bus **[web]**, §3). Its one advantage — fewer possible cycle shapes — is not worth it: the cycle validator is required anyway (a bus-keyed-by-track cycle exists in B too: track A → bus B while A's comp keyed by B). **Loses.** (v1 of A *includes* buses as legal sources for free.)

### Option B′ (sub-option of A, rejected): tap-based key (render tap / ring buffer instead of a graph edge)

Install a tap or ring-buffer copy at the source and have the keyed effect read it. Rejected on determinism: with no graph edge, pull order between source and destination strips is unconstrained, so the key lags 0–1 quantum nondeterministically — live it's inaudible jitter, but **offline it makes bounces non-reproducible**, violating the byte-identical bounce/stem property that m11-e just proved and this project treats as normative. Also AVFoundation taps are Tier-2 (tap/queue side) and explicitly "can't feed the graph" (ARCHITECTURE.md:421 rejected-alternatives note: "tap/source-node pumps (taps can't feed the graph; cross-node pulls are unsupported)"). **Loses.**

### Option C: reject-for-now

Defensible — this is the most invasive non-tempo item (audit ranked it #8 with exactly this warning, audit-m10q-pro-parity.md:209). But the audit also calls it "arguably the most-requested single 'missing knob' for dance/pop genres" (audit-m10q-pro-parity.md:209), the blast radius under Option A is genuinely small (one AU bus, one seam extension, two effects, one plan transform), and the stem/PDC reconciliations reduce to existing mechanisms. **Loses to A — provided the S-0 spike passes.** If S-0 fails, C is the outcome (park with the spike evidence, the m10-p precedent).

---

## 5. Reconciling the invariant (the item's core ask), stated as the new contract

The invariant is **narrowed, not discarded**:

> One MAIN audio input per strip (unchanged: sandwich, in-place walk, meters, sends, fader).
> A strip MAY additionally receive at most ONE key (sidechain) input in v1, which:
> (1) enters only through `ChainHostAU` input bus 1, pulled same-quantum via a real graph edge;
> (2) never sums into the strip's audio path — it is analysis-only for keyed effects;
> (3) is tapped POST-FADER at the source strip's mixer (Live "Post Mixer" semantics — muting/pulling the source fader kills the pumping; chosen over Live's Post-FX default because the post-fader point is the strip's ONLY existing fan-out point (PlaybackGraph.swift:88 "fan-out source"), it is PDC-aligned by construction (§4-A), and it matches Logic's post-pan send default **[web]** — one new connection point, zero new taps or nodes);
> (4) participates in routing reconcile, cycle validation, PDC planning (source: `hasSends`-class), and stem-pass construction (silent-dummy inclusion).

## 6. Failure modes

1. **S-0 spike fails** (AVAudioEngine won't connect `toBus: 1` on an effect node, or UpdateGraphAfterReconfig misbehaves with a partially-connected second bus — the M9 crash-a family, docs/research/fix-teardown-crash.md, makes AVFoundation graph-list state a proven hazard). → All graph-edge variants die; B′ is rejected on determinism; **outcome: NO-GO/park** with the spike test checked in as evidence. No partial fallback is worth shipping.
2. **Render block regression**: pulling a disconnected bus 1 must not error the whole strip — the guard is the atomic key-connected flag; a pull error on bus 1 degrades to self-keyed (dry-key), never fails the main path (mirrors HostedAUEffect's "passing DRY on render error", ARCHITECTURE.md:421). Pinned by test.
3. **Stem-pass drift**: someone adds a keyed effect and forgets the pass transform → silent Σ-stems break. Mitigation: the null-test gate (§9 S-3) runs WITH an active sidechain; `StemPlanTests` gain keyed fixtures; `passTracks` derives key sources from the SAME model field the engine reads (single source of truth).
4. **Cycle validator gap** → AVAudioEngine cycle = undefined behavior/crash at reconcile. Mitigation: validation at the store BEFORE the edit commits (field-named error), exhaustive small-graph tests incl. the A⇄B shape; reconcile additionally treats an unexpected wiring failure as the existing announce/rewire error class.
5. **Teardown**: removing a key source track must sever the edge under the retire discipline (`retireNode` only; pending-detach bin rules, ARCHITECTURE.md:52). The edge lives in the source's fan-out (severed wholesale by `engine.disconnectNodeOutput(mixer)` at rewire, PlaybackGraph.swift:656), and ProjectStore must clear dangling `sidechainSourceTrackID`s inside the track-removal edit (the dangling-send precedent, PlaybackGraph.swift:630–632).
6. **Mono/stereo format mismatch** on bus 1: all strips run the shared graph format today (`graphFormat()`, PlaybackGraph.swift:668); key bus adopts the same format at reconcile. Low risk; format-negotiation failure degrades to self-keyed + stderr, never silent wrong audio.
7. **Hosted-AU keying oversold**: v1 does NOT wire third-party AUs' own sidechain busses. `fx.setSidechain` on a hosted AU returns `sidechainUnsupportedEffect` with teaching text. (Phase H, later: enable the AU's bus 1 via `inputBusses[1].isEnabled` + a second pull path in `HostedAUEffect` — same adapter, second stash; **flag: untestable for out-of-process AUv3 on this machine** — no AUv3 installed, the vi-b residual, ROADMAP "Blocked"/vi-b note. No full-Xcode requirement for the v1 scope; in-process registration is proven from bare SPM, ARCHITECTURE.md:421.)

## 7. Wire surface + model sketch

Model (DAWCore): `Effect.sidechainSourceTrackID: UUID?` — additive, omit-when-nil Codable (the `startOffsetSeconds` omission precedent, Model.swift:202–207); legal only on `kind ∈ {compressor, gate}` in v1 (validated at the store).

Command (116→117): 
```
fx.setSidechain {trackId, effectId, sourceTrackId | null}
→ {effect: <Effect JSON incl. sidechainSourceTrackId>, skewSamples}
```
Errors (field-named, teaching): `sidechainUnsupportedEffect` (names the two supported kinds + the hosted-AU deferral), `sidechainWouldCreateCycle` (names the path), `sidechainOneSourcePerStrip` (v1 bus budget; points at the offending effect), `trackNotFound`/`effectNotFound` as usual. `null` clears. ONE `performEdit("Set Sidechain")` (no coalescing — discrete). Snapshot: effect objects carry the additive field; PDC report gains `sidechainSkewSamples` per keyed strip.
MCP (119→120): `fx_set_sidechain`, mechanical name rule, description teaching the kick→pad workflow ("add a compressor to the pad track, then key it from the kick: fx_set_sidechain {trackId: pad, effectId: comp, sourceTrackId: kick}"). Copilot catalog: added (safe, undoable). UI (sketch only): a "KEY" source picker row on compressor/gate effect cards (both densities; Pro-only if density review says so), Explain entry `.sidechain`; `debug.*` staging for captures. Every piece follows the house vertical: store method + wire command + MCP tool + tests + captures.

## 8. Risks, ranked

1. **AVAudioEngine multi-input-bus effect connection is unproven** (S-0). The entire design stands or falls here; history says AVFoundation graph edges hide sharp corners (M4-i silent leg; M9 crash-a stale-pointer teardown). → spike FIRST, nothing else starts.
2. **Σ-stems/bounce equivalence regression** if pass construction and engine read different key-source truths → single model field + mandatory keyed null-test gate (≤ 1e-4 residual) + keyed bounce byte-gate.
3. **PDC key skew misunderstood as a bug** (key late by T − ℓ_before in latency-heavy sessions) → reported number on the wire from day one; phase-2 exact-alignment path sketched (§4-A) if beta users hit it.
4. **Cycle/dangling-reference crashes at reconcile** → store-side validation + dangling-clear inside the removal edit + rewire-quiesce discipline already covering the mutation class.
5. **Scope creep toward hosted-AU sidechain** (needs per-AU bus discovery, enable-before-allocate pitfalls — the "inputBusses[0] is DISABLED by default" class, ARCHITECTURE.md:421) → explicitly phased out of v1 with a teaching error.

## 9. Phased M12 implementation plan

**S-0 — the gating spike (engine test, ~half a day).**
File: `Tests/DAWEngineTests/SidechainBusSpikeTests.swift` (kept, like the ChainHostAU registration spike). ChainHostAU variant (test-local subclass or a flagged second bus) exposing `inputBusses = [main, key]`; offline engine: player A → bus 0, player B → `connect(_:to:fromBus:0 toBus:1 format:)`; render block asserts bus-1 pull delivers B's samples same-quantum; then disconnect/reconnect + stop/start cycle survival (M9 crash-a discipline). PASS ⇒ proceed; FAIL ⇒ park item + record evidence here.
**S-1 — DAWCore (pure, headless).**
Files: `Model.swift` (Effect field), `ProjectStore` (`setSidechain` method: validation incl. cycle check + kind check + one-per-strip, performEdit, dangling-clear on track removal), `LatencyCompensation.swift` (key-tap ⇒ `hasSends`-class input; report field), `StemPlan.swift` (key-source inclusion via dummy bus, both `.track` and `.bus` arms).
Tests: cycle validator exhaustive small graphs; StemPlan keyed fixtures (key source included, routed to dummy, sends filtered); PDC plan with keyed strips; Codable round-trip incl. omit-when-nil.
**S-2 — DAWEngine.**
Files: `ChainHostAU.swift` (second bus + key scratch + atomic connected flag + guarded bus-1 pull), `EffectChainProcessor.swift` (key ABL threading), `EffectRendering.swift` (`KeyableEffectRendering`), `CompressorEffect.swift`/`GateEffect.swift` (detector reads key when present; bit-exact self-keyed when absent — pinned), `PlaybackGraph.swift` (`RoutingKey` + fan-out connection point + reconcile + teardown), `AudioEngine`/`OfflineRenderer` pass-through.
Tests/gate: offline determinism (two renders byte-identical); keyed-compressor offline test with an analytic expectation (kick impulses on A, sustained tone on B ⇒ gain dips at kick onsets within 1 quantum; dip depth matches ratio math); self-keyed null test bit-exact vs today; live staging: add key mid-play (expect the documented rewire bounce, then pumping audible in B's meters — the M4-i E2E shape).
**S-3 — equivalence gates (mandatory, block the milestone).**
Re-run the m11-d/m11-e machinery WITH an active sidechain: (a) `render.stems includeMixdown` null check Σ stems ≡ mixdown ≤ 1e-4 residual; (b) `track.bounceInPlace` of the keyed track byte-identical (SHA-256) to its single-track `render.stems`; (c) `render.measureLoudness` before/after honesty on the bounce.
**S-4 — wire + MCP + UI + docs.**
Files: `Commands.swift` (+1 → 117), `mcp-server/src/server.ts` (+1 → 120) + audit/integration count pins, CopilotCatalog, effect-card KEY picker + Explain + captures, ARCHITECTURE.md: narrow the invariant per §5 AND add the settled entry to "Key future decisions" (deferred from this docs-only spike), CHANGELOG/FEATURES.
Tests/gate: audit-tools bijection; wire gate driving the full kick→pad workflow over WebSocket incl. all four error shapes verbatim; pixel-reviewed captures.
**Deferred (recorded, not scheduled): phase H** — hosted-AU key wiring (HostedAUEffect second stash + bus enable; AUv3 out-of-process leg untestable on this machine); **phase 2 PDC** — exact key alignment via keyed-effect reported latency (§4-A).

## 10. Recommendation

**GO-WITH-CONDITIONS.** Conditions:
1. **S-0 spike passes before any other file is touched.** A failure converts this to NO-GO/park with the spike test retained as evidence.
2. v1 scope frozen: built-in compressor/gate only, one key source per strip, post-fader tap, skew reported not corrected.
3. The S-3 stem/bounce equivalence gates are release-blocking — a keyed session must satisfy Σ stems ≡ mixdown ≤ 1e-4 and bounce-vs-stem byte-identity, or the feature does not ship.
4. Self-keyed path pinned bit-exact against today (the null-case discipline).
5. No new RT-safety exceptions; any deviation returns here for amendment.

No full-Xcode requirement for the v1 scope (in-process AU subclassing + SPM proven, ARCHITECTURE.md:421). The only environment limitation is the deferred phase H's out-of-process AUv3 leg (no AUv3 on this machine — the vi-b residual).

### Web sources
- https://developer.apple.com/forums/thread/50979 (Logic's bus-0-main / next-bus-sidechain convention, host must enable busses)
- https://wiki.audiob.us/doku.php?id=au_multi_bus (AUv3 multi-bus hosting notes)
- https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitProgrammingGuide/TheAudioUnit/TheAudioUnit.html (v2 additional busses for sidechain paths)
- https://developer.apple.com/documentation/audiotoolbox/audio-unit-v2-c-api (kAudioUnitProperty_MakeConnection / ElementCount)
- https://support.apple.com/guide/logicpro/compressor-side-chain-parameters-lgce0b2501de/mac (Logic side-chain UX)
- https://www.ableton.com/en/manual/routing-and-i-o/ (Live tap points Pre FX / Post FX / Post Mixer)
- https://whylogicprorules.com/pre-fader-post-pan-explained/ (Logic send default post-pan)
