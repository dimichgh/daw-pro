# Design doc (m16-b): MIDI CC + pitch bend — clip-event controllers on the schedule path

**Status: DESIGN ONLY — no production code. Gates m16-b2 (model + schedule playback), m16-b3 (live thru + capture), m16-b4 (piano-roll CC strip).**
**Author: daw-architect, 2026-07-13.**
**Scope:** ROADMAP m16-b1 (docs/ROADMAP.md:253), seeded by audit-m16 §4/F9. Every claim about current behavior cites file:line read for this note. One staging probe was run (§7, port 17641, staging laws observed: fresh port, project.new normalize, kill by exact pid, port verified closed, .ips ledger unchanged at 24).
**Deviation law (the m15-b/m16-a rule): implementers who find this doc wrong in any load-bearing place STOP and return the deviation here — the doc is amended before the code diverges. Each phase's gate is this doc's C-conditions for that phase, verbatim.**

---

## 0. Verdict

**GO-WITH-CONDITIONS (C1–C20, §14).** The headline calls:

1. **CC/bend/pressure are CLIP-EVENT data on the schedule path** — `ScheduledMIDIEvent` kinds 2/3/4 in the reserved slots (`MIDISchedule.swift:6-7`), NOT `AutomationLane` (§1).
2. **Model**: `Clip.controllerLanes: [MIDIControllerLane]` — per-controller lanes of identity-free `{beat, value}` points, stepwise semantics, raw MIDI value domains, omit-when-empty Codable (the `gainEnvelope` precedent byte-for-byte, `Model.swift:566-568`) (§3).
3. **CHASE-AT-BUILD, settled YES**: every schedule block (head build at `fromBeat` AND every unrolled loop-cycle block) is prefixed with a chase snapshot — the latest value ≤ the block's start beat per lane, else a neutral default — delivered at the block's anchor frame, sorted after note-offs and before note-ons. One mechanism serves seek-chase, the gapless-loop wrap, prune self-containment, and the split seam. The note no-chase contract is untouched (§5).
4. **Decimation, measured**: per-event render-drain cost ≈ 1.1–1.8 µs (staging probe, §7); an 8192-event single-quantum burst measurably overruns the 10.67 ms budget (11.74 ms, `overrunCount 1`) — and is **already wire-reachable today with notes**, so the policy is: capture thins to ≥ 5 ms/lane spacing + duplicate-drop, the wire caps lanes at 16/clip and 16384 points/lane, and the schedule build coalesces same-frame points per lane. Real capture load (≤ 3.2 k events/s worst) sits three orders below the measured sustained-safe rate (§7).
5. **Wire**: two new verbs, `clip.setControllerLane` + `clip.removeControllerLane`, landing in b2 with counts moved in the same change: **123→125 commands, 126→128 MCP tools, catalog 55→56**. b3 and b4 are zero-wire-growth (§10).
6. **Loop-cycle capture slicing reuses the m15-b seconds-domain law verbatim**, plus cycle-boundary state injection (the state-stream cousin of the m15-b §5.3 modular stop-clamp) (§8).
7. **Built-in instruments honor pitch bend (±2 st) and sustain (CC64) in v1**; every other CC is safely ignored by built-ins (documented) and everything is forwarded to hosted AUs (§4.3).

Nothing in any phase requires full Xcode — all SPM; hosted-AU tests use in-process system AUv2 components (the m10-n precedent).

---

## 1. The boundary: clip events, NOT AutomationLane (the load-bearing decision, expanded from audit-m16 §4)

`AutomationTarget` (`Sources/DAWCore/Automation.swift:18-60`) is the **mixer/effect parameter plane**: volume, pan, sendLevel, effectParam. Its transport is `AutomationRenderer`/`AutomationSchedule` — per-strip breakpoint arrays evaluated **post-chain at the fader position** (`InstrumentSourceNode.swift:51-55`, :409-412), applied as per-sample gain/pan math on rendered audio, with quantum-endpoint fidelity (ARCHITECTURE.md:474). It shapes the strip's OUTPUT.

MIDI CC/bend/pressure target the **instrument's INPUT**: they are musical performance data that must arrive interleaved with note-ons and note-offs, sample-accurately, on the same delivery channel — a bend between two note-ons must reach the synth voice between those note-ons, not be smeared across a quantum as an output gain. The sample-accurate event channel already exists: the immutable `MIDIEventSchedule` published per instrument track (`MIDISchedule.swift:19-46`), whose 24-byte POD **explicitly reserves kinds 2+ for exactly this** ("CC / pitch bend / sustain arrive additively, post-v0", `MIDISchedule.swift:6-7`).

Conflating the two planes would fail four ways:

- **Wrong timing model.** Automation is quantum-endpoint-evaluated (≈ 10.7 ms chords at 512/48 kHz, ARCHITECTURE.md:474); CC must be event-ordered against notes at frame precision (the off-before-on discipline, `MIDISchedule.swift:79-82`).
- **Wrong addressee.** Automation lanes hang on `Track` and drive strip DSP we own; CC drives the instrument — for hosted AUs that is `scheduleMIDIEventBlock` bytes (`HostedAUInstrument.swift:62-67`, :126-145), a channel automation cannot reach at all.
- **Wrong lifecycle.** CC belongs to the CLIP: it moves with the clip, splits with the clip, records into takes, and comps with take lanes (`Takes.swift:14-48`). Automation is per-track and ignores clip geometry entirely.
- **Wrong editing surface.** CC is edited in the piano roll against notes (§9); automation is edited in the arrange `AutomationLaneEditor` (`Sources/DAWApp/Timeline/AutomationLaneEditor.swift`). The audit's phrasing stands: "a mod-wheel ramp on the wrong transport with the wrong timing guarantees" (audit-m16.md:94).

**Non-decision reaffirmed:** `AutomationLane`, `AutomationRenderer`, `AutomationSchedule`, and all `automation.*` verbs are untouched by every phase of this feature (§12, C1).

---

## 2. Ground truth today (evidence)

- **Schedule**: `ScheduledMIDIEvent{sampleTime: Int64, noteID: UInt64, kind: UInt8, pitch: UInt8, velocity: UInt8}` — 24-byte POD, kinds 0/1 note-on/off, 2+ reserved (`MIDISchedule.swift:8-17`). `buildEvents` is pure main-actor math with the beat-domain no-chase guard for notes (`:111`), the m14-b loop-unroll params (`onsetEndBeat`, `offsetSeconds`, `noteIDBase`, `:95-99`), the canonical sort (`orderedBefore`, off-before-on, `:137-144`), the append-only merge (`:154-176`), and the watermark re-seek `lowerBound` (`:181-190`).
- **Drain**: `InstrumentRenderer.renderQuantum` slices `[cursor, windowEnd)` and hands the slice to `instrument.render` — the slice/merge machinery is **kind-agnostic already** (`InstrumentSourceNode.swift:284-297`, :367-398). The live-thru drain PAIRS by pitch (kinds 0/1 only, `:305-327`) — the one render-side site that must learn kind ≥ 2. The flush family answers `flushFlag`/ring-overflow with `instrument.reset()` (`:210-220`).
- **AU delivery**: `HostedAUInstrument.render` translates each event to 3 MIDI bytes and calls the captured `scheduleMIDIEventBlock` at the in-quantum offset before `renderBlock` (`HostedAUInstrument.swift:126-145`); `reset()` already sends CC 123 + CC 120 (`:189-201`). The event path for CC to AUs **exists** — it is a byte-translation extension.
- **Built-ins**: `PolySynthInstrument.apply` and `SamplerInstrument.apply` are `if on … else if off` — **unknown kinds fall through safely by construction** (`PolySynthInstrument.swift:324-350`, `SamplerInstrument.swift:380-419`). Neither has bend or sustain state today.
- **Loop unroll**: head build windows note-ons at the loop end and stashes `midiNoteIDBase[trackID] = pendingEvents.count / 2` (`PlaybackGraph.swift:2114-2124`); `extendLoopMIDI` appends per-cycle blocks at absolute second-domain integrals and advances the base by `block.count / 2` (`:2410-2444`). **The `/2` arithmetic assumes every event is half of an on/off pair — CC events break it** (§6, C5).
- **Live input**: `MIDIUMPParser.parse` accepts MT-2 note-on/off only; status 0xB/0xD/0xE return nil and are dropped (`MIDIUMPParser.swift:24-40`; the multi-word walker at :46-53 keys on the message-TYPE nibble, not status — no trap there). `LiveMIDIEvent` is a 16-byte POD (`LiveMIDIEvent.swift:7-14`); rings are drop-newest SPSC with `droppedFlag → reset()` (`LiveEventRing.swift:15-18`); the receive thread fans one accepted event to every armed thru ring + the 4096-slot capture ring (`MIDIInputManager.swift:115-131`, :69), drained ~30 Hz on the main actor (`:283-301`).
- **Capture**: `MIDICaptureSession` pairs notes channel-agnostically on the frozen linear map, drops pre-anchor ons (count-in trim), clamps open notes at `finish(atBeat:)` (`MIDICaptureSession.swift:44-79`). Loop-cycle takes slice the LINEAR capture in the seconds domain at `k·L` per the m15-b law (design-m15b-loop-record.md §4; `TakeResult.stopBeats`, `EngineProtocol.swift:137-153`).
- **Model**: `MIDINote` is note-only; `Clip.notes: [MIDINote]?` with notes-wins mutual exclusion (`Model.swift:103-176`, :237-238, :364-366); Clip Codable is the omit-when-default discipline with `gainEnvelope` written only when non-empty (`:509-572`, :566-568). `isMIDI ⇔ notes != nil` (`:313`).
- **Clip geometry ops**: `splitClip` partitions notes and pins an interpolated gain-envelope boundary point at the seam (`ProjectStore.swift:2822-2842`, :2849-2854 — **the exact precedent for lane windowing**); `trimClip` shifts/drops/truncates notes (`:2890-2908`); `duplicateClip` (`:3061`); take comping windows MIDI via `windowNotes` (`Takes.swift:200`, :297).
- **Wire**: `clip.addMIDI`/`clip.setNotes` with `parseNotes` (4096-note cap) (`Commands.swift:186-187`, :1163-1194, :3216-3271). Pins today: **123 commands** (counted this session), 126 MCP tools, catalog 55.
- **Settled contracts this design must compose with**: sequencer clock + note no-chase v0 (ARCHITECTURE.md:135-170 — "CC/pitch-bend/sustain … all additive later"); gapless loop unroll, timelineID/watermark, restart primitive (ARCHITECTURE.md:172); m16-a exception armor + @Sendable Canvas law (ARCHITECTURE.md:171).

---

## 3. D1 — Model: per-controller lanes of identity-free points on Clip

```swift
// DAWCore/Model.swift (new, adjacent to MIDINote)

/// Which controller stream a lane carries. Flat Codable {type, controller?}
/// — the AutomationTarget discriminator precedent (Automation.swift:29-72):
/// a String raw discriminator so an unknown type is a hard decode error.
public enum MIDIControllerType: Hashable, Sendable, Codable {
    case cc(controller: Int)   // 0...127 (1 = mod, 11 = expression, 64 = sustain…)
    case pitchBend             // value 0...16383, center 8192
    case channelPressure       // value 0...127
}

/// One controller point: clip-relative beat + RAW MIDI value. Deliberately
/// NO id and NO curve: points are identity-free value data (the
/// AutomationPoint precedent, ARCHITECTURE.md:474) with STEPWISE semantics —
/// a CC message holds until the next one; a ramp is a dense run of points
/// (which is exactly what capture produces). Clamps through init.
public struct MIDIControllerPoint: Codable, Sendable, Equatable {
    public var beat: Double    // >= 0, clip-relative
    public var value: Int      // clamped to the owning lane's type range
}

/// One controller lane; AT MOST ONE lane per type per clip (store-enforced,
/// the automation at-most-one-per-target rule). No lane UUID: the type IS the
/// identity — one identity per thing (the audit F8d note-id lesson applied
/// by construction: nothing to re-mint on duplicate).
public struct MIDIControllerLane: Codable, Sendable, Equatable {
    public var type: MIDIControllerType
    public var points: [MIDIControllerPoint]   // canonically ordered
}
```

- **Clip field**: `public var controllerLanes: [MIDIControllerLane] = []` — non-optional with `[]` default, encoded **only when non-empty**, decoded with `decodeIfPresent ?? []` — byte-for-byte the `gainEnvelope` mechanism (`Model.swift:539`, :566-568). Legacy projects and audio clips never grow the key (C1). Invariant: non-empty `controllerLanes` requires `isMIDI` (init forces `[]` when `notes == nil`, the notes-wins cousin of `Model.swift:364-366`). A CC-only clip is legal as `notes: []` + lanes.
- **Canonicalization** (the `MIDINote.canonicallyOrdered` cousin, `Model.swift:139-145`): points sorted by beat, **equal-beat last-wins dedupe**, values clamped by type range, beats floored at 0; lanes sorted by a stable type key (cc ascending by controller, then pitchBend, then channelPressure); duplicate-type lanes merge last-wins. All construction routes through the clamping path (the MIDINote/Codable discipline, `Model.swift:96-102`).
- **Value domains are raw MIDI**: cc/pressure `0...127`, bend `0...16383` (center 8192). Rationale: the schedule path emits MIDI bytes; a normalized float would round-trip lossily and obscure teaching copy ("64 = pedal down"). The wire error copy names the bend center (§10).
- **Channel scope v1: single-channel, matching notes exactly.** `ScheduledMIDIEvent` has no channel field (`MIDISchedule.swift:8-14`), `HostedAUInstrument` emits status on channel 0 (`HostedAUInstrument.swift:136-142`), capture pairing is channel-agnostic (`MIDICaptureSession.swift:16-17`), `LiveMIDIEvent.channel` is "captured, unused v0" (`LiveMIDIEvent.swift:13`). Lanes carry no channel; capture merges channels. Additive later exactly like everything else in this POD family. **Poly (per-note) aftertouch is deferred v1** — it is per-note data, a different model shape (UMP MT-2 status 0xA); documented in the MCP tool description.

---

## 4. D2 — Schedule + drain: kinds 2/3/4, one data-byte rule, per-quantum delivery

### 4.1 Event encoding

```swift
// MIDISchedule.swift — ScheduledMIDIEvent gains:
static let controlChange: UInt8   = 2  // pitch = controller#, velocity = value
static let pitchBend: UInt8       = 3  // pitch = LSB (low 7), velocity = MSB (high 7)
static let channelPressure: UInt8 = 4  // pitch = value, velocity = 0
```

**THE ONE RULE: `pitch` ≡ MIDI data1, `velocity` ≡ MIDI data2, for every kind.** Notes already conform (data1 = key, data2 = velocity); CC is (controller, value); bend is (LSB, MSB) in wire order; pressure is a 2-byte message (data1 only). No POD size change — 24 bytes stays 24 bytes, and every existing consumer that switches on kinds 0/1 falls through safely (measured by reading: `PolySynthInstrument.swift:324-350`, `SamplerInstrument.swift:380-419`, `TestToneInstrument`, `EventCaptureInstrument` record-everything).

**Sort order**: `orderedBefore` rank becomes off = 0, **kinds 2/3/4 = 1**, on = 2 (`MIDISchedule.swift:137-144`). At a shared frame: old notes end, controller state settles, new notes start — the chase composition rule (§5) and the sustain-release-before-retrigger rule in one stroke. For note-only schedules the RELATIVE order of off vs on is unchanged, so existing schedules sort byte-identically (C1b). Final tiebreak stays `noteID`; CC events consume IDs from the same running counter (uniqueness = sort determinism).

### 4.2 Build

`buildEvents` (`MIDISchedule.swift:95-132`) grows, with **zero new parameters**:

1. **Lane events**: for each clip's lane point with clip-relative beat ∈ [0, clipLength) — the note-onset rule verbatim (`:109`) — emit one event at the absolute-integral frame (`round((offsetSeconds + seconds(fromBeat→beat)) · rate)`, the `:114-118` discipline). Onset window `[fromBeat, onsetEndBeat)` applies exactly as for note-ons (`:111-112`); CC events are instantaneous, so there is no off-side straddle case.
2. **Per-lane same-frame coalescing**: after frame rounding, consecutive same-lane events landing on one frame collapse to the last (store canonicalization already dedupes equal BEATS; this closes the sub-frame-spacing rounding case). Bounds worst-case density at 1 event/lane/frame (C6).
3. **Chase prefix** (§5): injected at the block's own `fromBeat`, frame `round(offsetSeconds · rate)`.
4. **Signature fix**: `buildEvents` returns `(events: [ScheduledMIDIEvent], nextNoteID: UInt64)` (or takes `inout` — implementer's choice, pinned by test). **Both `count / 2` sites die**: `PlaybackGraph.swift:2122` and `:2413-2414/:2429` switch to the returned counter. This is a REAL bug-in-waiting: with mixed kinds, `count / 2` double-books noteIDs across appended cycle blocks — C5 pins uniqueness.

### 4.3 Delivery

- **`InstrumentRenderer.renderQuantum`: no change in b2.** Slice, merge, watermark, timelineID re-seek are kind-agnostic (`InstrumentSourceNode.swift:238-297`). b3 touches exactly one site: the live-drain pitch-pairing loop (`:305-327`) gains `kind >= 2 → id = nextLiveNoteID++` with **no pitch-map touch** (C11).
- **`HostedAUInstrument.render`** (`:133-145`): kind 2 → `0xB0, data1, data2` (3 bytes); kind 3 → `0xE0, LSB, MSB` (3 bytes); kind 4 → `0xD0, value` (**length 2** — channel pressure is a two-byte message; the preallocated 3-byte `midiBytes` buffer suffices, `:70`). Same FIFO-at-equal-offset guarantee the off-before-on rule already relies on (`:131-132`).
- **Built-ins, v1-honest scope**: `PolySynthInstrument` and `SamplerInstrument` implement **pitch bend** (render-thread bend state → frequency/playback-rate factor `2^(bendSemitones/12)`, fixed ±2 st range — the GM default; recompute per applied event, preallocated state only) and **sustain CC64** (pedal ≥ 64: note-offs mark the voice sustained instead of releasing; pedal < 64: release all sustained voices — one per-voice flag + one pedal bool, zero allocation). All other CCs and channel pressure: safely ignored by built-ins, **documented in the MCP tool description** ("built-in instruments honor bend and sustain; other CCs affect Audio Unit instruments"). Sustain is non-negotiable for v1 — it is THE keyboardist controller, and capturing it without honoring it on thru would ship a broken feel.
- **`reset()` neutralizes controller state** (the flush family, `InstrumentSourceNode.swift:210-220`): built-ins clear bend to center and pedal to up alongside the voice wipe (`PolySynthInstrument.swift:204-208` cousin); `HostedAUInstrument.reset()` (`:194-201`) adds bend-center (`0xE0 00 40`), CC64 0, and CC121 (reset-all-controllers) after the existing CC123/CC120. Stale-state defense-in-depth behind chase (§5); no offline-render impact — the flush family never fires inside a render window (C1c holds by construction).

**C4 (RT safety)**: every addition is preallocated state + integer math on the render thread; the schedule stays an immutable preallocated buffer; no new allocation, locks, ObjC dispatch, or retain/release on any drain path. The audit-rt-safety review idiom applies to the b2 diff.

---

## 5. D3 — CHASE: chase-at-build, settled YES (the hardest call)

**Decision: chase.** Every schedule block begins with a **chase snapshot**: for each lane type present in ANY of the track's MIDI clips (`buildEvents` already receives them all — `node.clips`, `PlaybackGraph.swift:2116-2117`), emit one synthetic event at the block's anchor frame carrying the **latest point value with absolute beat ≤ the block's fromBeat** (scanned across all clips — a clip wholly before the start point still contributes state), else the **neutral default**: bend 8192, channelPressure 0, CC from a small table `{7: 100, 10: 64, 11: 127, else 0}` (GM/RP-015-informed; the table is a named constant with a doc comment). Injection is **skipped** when the lane has a literal event at that exact frame (last-wins dedupe would fight determinism gates otherwise). Chase events sort at rank 1 — after offs, before ons — so a chased sustain catches, and a chased bend applies, before the first note sounds.

**Why chase wins over honest no-chase:**

1. **Stuck sustain is catastrophic, not teachable.** A take recorded with pedal, then a seek past the last CC64 event: no-chase leaves the pedal down on the instrument — every note rings forever. Unlike a stuck mod wheel (a timbre surprise), this is unusable output on the most common controller. A teaching surface cannot fix audio.
2. **The stale state is not even the CLIP's state — it is leftover from the previous roll.** After stop, `reset()` today does not touch CC/bend on AUs (`HostedAUInstrument.swift:194-201` sends only 123/120), so without chase the controller state at play is whatever the LAST session of playback (or live fiddling) left behind — non-deterministic playback, which violates the offline==live pin by construction.
3. **It is nearly free on this architecture.** The scan is main-actor build-time math over data `buildEvents` already holds (per lane: one binary search over canonically-ordered points per clip). Zero render-side machinery — chase events are ordinary schedule entries.
4. **Industry-consistent** (Logic/Cubase/Live all chase controllers at locate), so agent and user expectations match.
5. **One mechanism, four problems**: seek restart (the restart primitive rebuilds from `fromBeat` — chase rides in), the loop wrap (§6), prune self-containment (§6), and the split seam (§11) all reduce to "a block re-establishes state at its own start".

**Why the notes contract stays no-chase**: a note is an interval — chasing it means synthesizing a partial note (wrong attack, wrong length), a musical lie. A controller is a step function — chasing it is just reading the function. The two contracts are different because the data is different. `MIDISchedule.swift:111` survives verbatim (C1b).

**The live-state line**: chase covers exactly the lane types present in the track's clips. It deliberately does NOT reset the other 100+ controllers at every restart — a keyboardist holding the mod wheel while pressing play must not have it yanked to zero. Scheduled state is deterministic; live state belongs to the performer.

**Measurement note**: the roadmap invited measuring a stuck bend on the built-in synth. Not run — the built-in synth has no bend support yet (nothing to measure, §2), and grounds 1–4 are structural. The call does not hang on audibility.

---

## 6. D4 — Gapless-loop composition: cycle blocks are self-contained

CC events unroll exactly like note-ons: `extendLoopMIDI`'s per-cycle `buildEvents(fromBeat: loop.startBeat, onsetEndBeat: loop.endBeat, offsetSeconds: k-th integral, …)` (`PlaybackGraph.swift:2415-2431`) emits each cycle's lane events at absolute-integral frames, merged append-only against the same `timelineID` — the watermark re-seek machinery needs zero changes (`InstrumentSourceNode.swift:238-248`).

**The bend-across-the-wrap question** (the m15-b §5.3 modular-clamp cousin): a bend that ends cycle k away from its loop-start value would otherwise leak stale state into cycle k+1 until that lane's first literal event. Answer: §5's chase prefix fires **per cycle block** with zero extra design — each block's `fromBeat` IS `loop.startBeat`, so every cycle opens with the state a fresh seek-to-loop-start would produce. Consequences, all desirable:

- Every cycle sounds identical (deterministic loop audition — the whole point of a loop).
- **Prune self-containment**: m14-d prunes delivered history below the sounding cycle (ARCHITECTURE.md:172); with per-block chase, a pruned prefix can never strand controller state — the automation "blocks are self-contained" law now holds for MIDI state too.
- The head build (starting mid-loop at `startBeats`) chases at `startBeats`; appended cycles chase at `loop.startBeat` — both fall out of the same code path with no flags (§4.2).

Note tails still ring through the seam (offs past `onsetEndBeat`, `PlaybackGraph.swift:2106-2113`) — untouched. A bend affecting a straddling tail voice will step to the loop-start value at the wrap frame; this is the honest v1 semantic (Logic behaves the same), noted in the MCP description.

**C5** pins: mixed-kind noteID uniqueness across ≥ 3 unrolled cycles (the `count / 2` fix, §4.2); delivered CC sequence of cycle k+1 == a fresh seek-to-loop-start build modulo the cycle's frame offset; `GaplessLoopSpikeTests` stays green.

---

## 7. D5 — Decimation: the measured bound and the three-layer policy

**Probe (run for this doc, 2026-07-13):** staging build post-m16-a, port 17641, default built-in PolySynth, 512-frame quanta @ 48 kHz (render budget 10.67 ms), `engine.performanceStats` read-then-reset windows, warm-up pass before each measured window (the debug.masterCapture warm-up law generalized). Script: scratchpad `probe-cc-density.mjs`. Results:

| scenario | events (approx) | peakCallbackNs | averageLoad | overruns |
|---|---|---|---|---|
| baseline, 16 notes spread | 32 over 4 s | 2.60 ms | 0.078 | 0 |
| 512 notes @ one frame | ~1024 in 1 quantum | 4.41 ms | 0.075 | 0 |
| 4096 notes @ one frame | ~8192 in 1 quantum | **11.74 ms** | 0.073 | **1** |
| 4096 notes over 4 beats | ~2048 events/s sustained | 3.01 ms | 0.099 | 0 |

**Findings:** marginal drain cost ≈ **1.1–1.8 µs/event** (PolySynth `apply` — includes voice allocation; a CC value store is cheaper, so this is the conservative bound). A single-quantum burst of ~8192 events **overruns the budget** (one overrun, immediate recovery, no watchdog trip, no .ips — and this burst is wire-reachable TODAY via 4096 same-beat notes, a pre-existing pathology CC must merely not worsen). ~1024 events/quantum costs ~1.8 ms (≈ 17% of budget) — safe. Sustained ~2048 events/s costs ~2% of budget — three orders of headroom over real controller traffic. Hosted-AU `scheduleMIDIEventBlock` per-event cost was not probed (needs an AU instrument on the staging track); **b2 rider**: spot-measure one Apple AU under the dense-512 scenario and record the number in the cycle report — the caps below already assume the conservative envelope.

**Policy (three layers, all falsifiable):**

1. **Capture thinning (b3, at the 30 Hz main-actor ingest)**: per lane, drop consecutive duplicate values (MIDI-lossless — repeated CC bytes are semantically idempotent), enforce **≥ 5 ms spacing** between stored points (≈ 200 Hz/lane), with the **final value of a suppressed run always emitted at its own timestamp** (a fast gesture's endpoint is never lost). 16 lanes × 200 Hz = 3.2 k events/s worst — measured-safe by 30×.
2. **Wire caps (b2)**: ≤ **16 lanes per clip**, ≤ **16384 points per lane** (teaching errors, §10). 16384 — not the notes' 4096 — so a thinned 200 Hz capture of an ~80 s continuous gesture still round-trips through `clip.setControllerLane` (the UI==wire==capture symmetry law; capture applies the same 16384 cap with second-stage spacing widening in the rare overflow). Notes keep 4096 untouched.
3. **Build coalescing (b2)**: same-frame per-lane last-wins (§4.2) — worst case 1 event/lane/frame regardless of input pathology.

**C6** pins: the coalescing unit; an adversarial caps-saturated clip plays live with overrun behavior no worse than the pre-existing 4096-note pathology (≤ 1 overrun, no watchdog trip, wire alive); the capture-thinning law unit (duplicate-drop, spacing, final-value).

**Honesty note (snapshot weight)**: a capture-landed dense lane (≤ 16384 points ≈ 160 KB JSON) rides `project.snapshot` via the Clip Codable pass-through. Accepted v1 — dense lanes only exist after long continuous-controller takes; documented in the MCP snapshot description (b3).

---

## 8. D6 — Capture + live thru (b3)

1. **Parser** (`MIDIUMPParser.swift:24-40`): MT-2 cases for status 0xB (CC → kind 2, data1 = controller, data2 = value), 0xE (bend → kind 3, data1 = LSB, data2 = MSB), 0xD (pressure → kind 4, data1 = value). `LiveNote`/`LiveMIDIEvent` PODs keep their shape — fields carry data1/data2 under the §4.1 rule (doc comments updated). Note vectors byte-identical (C10).
2. **Thru**: the receive-thread fanout needs zero changes (`MIDIInputManager.swift:115-131` is kind-blind once the parser accepts). The one render-side edit: live-drain kind ≥ 2 bypasses the pitch-pairing map (§4.3). Live CC sounds within ≤ 1 quantum, playing or stopped (the M3-vii law, `InstrumentSourceNode.swift:22-26`).
3. **Ring overflow honesty**: unchanged machinery — `droppedFlag → instrument.reset()` (`InstrumentSourceNode.swift:215-220`) now also neutralizes pedal/bend (§4.3), so a dropped pedal-up can no more stick than a dropped note-off (C15).
4. **Capture session** (`MIDICaptureSession`): kind ≥ 2 ingest accumulates per-lane point arrays through the same frozen-map beat math (`:83-88`), applying the §7 thinning at ingest. **Pre-anchor events set a per-lane pending-initial value** instead of being dropped: at the anchor, each pending lane materializes a point at clip-relative beat 0 — the count-in pedal case done right (the note path drops pre-anchor ons, `:47-49`, because a partial note is a lie; a controller VALUE at take start is the truth). `finish` needs no clamp for lanes (points are instantaneous).
5. **Loop-cycle slicing — the m15-b law reused verbatim + the state-injection cousin**: each point maps `e = seconds(anchor → anchor + beat)`, cycle `k = ⌊e/L⌋`, within-cycle beat = `beat(from: loopStart, elapsedSeconds: e − k·L)` (design-m15b §4 MIDI paragraph, byte-for-byte). **Plus**: every cycle k ≥ 1 lane opens with an injected beat-0 point carrying the linear stream's value at elapsed `k·L` — without it, a pedal held across the cycle boundary would vanish from lane k+1 (the state-stream cousin of the m15-b §5.3 modular stop-clamp bug; same shared pure helper as the §5 chase scan). `MIDIRecordingResult` gains `controllerLanes: [MIDIControllerLane]` (additive, default `[]`, `EngineProtocol.swift:118`); the loop MIDI lander and `windowNotes`-based comping (`Takes.swift:200`, :297) gain the lane-window sibling (§11's `windowedControllerLanes`).
6. **Trap notes for the implementer** (from the m15-b gate laws): CoreMIDI virtual sources are system-global — the e2e uses a **sentinel controller (CC 87)** with a distinctive value ramp, the CC cousin of the sentinel-pitch-113 law; `ProjectStore.engine` is weak — don't destructure fakes to `_`; the record anchor lands ~60 ms post-response.

---

## 9. D7 — UI: the controller strip (b4)

**Shape**: a **collapsible controller strip directly under the velocity lane** in the piano roll (`Sources/DAWApp/PianoRoll/` — PianoRollView + KeyboardSidebar + VelocityLane today; VelocityLane is 66 pt, `VelocityLane.swift:14`). Strip height 72 pt. A chip row selects the visible lane: one chip per existing lane (labels "Bend", "Mod (CC 1)", "Sustain (CC 64)", "CC n" — beginner-readable, DESIGN-LANGUAGE rule 6) plus a "+" menu (Bend, Mod, Expression, Sustain, Pressure, "Other CC…" numeric entry). One lane visible at a time (the Logic shape; multi-lane stacking deferred).

**Rendering**: stepped value line (hold-until-next — the §3 semantics drawn honestly, never interpolated slopes) with point handles; bend draws against a center guideline at mid-height. Dense capture data renders as the stepped line without per-point handles above a density threshold (handles appear on zoom — v1: handles hidden when > 4 points/px). Pencil drag inserts points at pointer ticks with duplicate-value drop; drag-existing-point edits value/beat; selection-free v1 (points are identity-free — a drag targets the nearest point, the VelocityLane nearest-stem idiom, `VelocityLane.swift:20-25`).

**Densities, decided honestly**: **Pro density = the full editable strip. Simple density = a passive header chip** ("2 controller lanes") in the piano-roll header when lanes exist — data is never hidden (honesty), but controller EDITING is a pro surface (the m15-c master-lane Pro-only precedent). The chip is not a button in v1.

**Architecture**: headless `ControllerStripModel` in `Sources/DAWAppKit/` (the PianoRollModel discipline, `PianoRollModel.swift:47-59`): value↔y per type (127-domain and 16383-domain), beat↔x reusing the affine `x = beat · pixelsPerBeat`, hit/pencil/drag ops mutating a lane draft, whole-lane `buildSubmission()` committed on gesture END through `ProjectStore.setClipControllerLane` — one undo per gesture, the `clip.setNotes` submit contract (`PianoRollModel.swift:49-52`, C17). **Every new Canvas obeys the m16-a law**: `@Sendable` renderer, value captures computed before the closure, `nonisolated` drawing helpers (the static-helper inference trap is load-bearing, ARCHITECTURE.md:171), and the verbatim CANVAS CONTRACT comment (`ClipMIDIMap.swift:27-28` idiom).

**Arrange mini-map** (the roadmap's ClipMIDIMap/MIDIMapGeometry extension): `MIDIMapGeometry` gains `controllerTrace(_:clipLengthBeats:height:) -> Path`-shaped pure geometry — a faint stepped polyline across the bottom 20% of the clip block from the clip's FIRST lane (by canonical order), drawn by `ClipMIDIMap` at 0.35 × the note-pill opacity. Headless-tested like `noteRects` (`MIDIMapGeometry.swift:80-91`). Clips without lanes render pixel-identically (C19).

---

## 10. D8 — Wire + MCP surface

**Two new verbs, both landing in b2, counts moved in the SAME change (the standing law): 123→125 commands, 126→128 tools, catalog 55→56.** b3 and b4 are zero-wire-growth (capture rides `transport.record` unchanged; the strip commits through the same store call the wire uses).

- **`clip.setControllerLane`** `{clipId, type: "cc"|"pitchBend"|"channelPressure", controller (required iff type=="cc", integer 0-127), points: [{beat, value}] (non-empty, ≤ 16384)}` → creates or replaces the clip's lane of that type; response = the updated clip encoding. `rejectUnknownKeys` from day one (the m16-e util exists). Undo key `clip.controllerLane:<clipId>:<typeKey>` (gesture coalescing, the automation.points precedent). Teaching errors, verbatim-pinned (C7): non-MIDI clip → existing `notAMIDIClip` family; `type=="cc"` without `controller` → "'controller' is required when type is \"cc\" — an integer 0-127 (1 = mod wheel, 64 = sustain)"; bend range → "points[i].value must be 0-16383 for pitchBend (8192 = center)"; cc/pressure range → "points[i].value must be 0-127"; empty points → "'points' must be non-empty — use clip.removeControllerLane to delete a lane"; > 16384 → the cap error naming the count; > 16 lanes → "clip already has 16 controller lanes — remove one first".
- **`clip.removeControllerLane`** `{clipId, type, controller?}` → removes; unknown lane → teaching error LISTING the clip's existing lanes (the m13-c listing idiom).
- **Read-back**: `Clip`'s Codable pass-through puts `controllerLanes` in every clip encoding — `project.snapshot`, `clip.addMIDI`/`clip.setNotes` responses — automatically and additively (the takeGroups precedent, design-m15b §6). No new read verb.
- **MCP** (`mcp-server/src/`): `clip_set_controller_lane` + `clip_remove_controller_lane`, **flat zod schema — no unions** (the m15-c prose-sentinel law): `type` enum string + optional `controller` number, constraint prose in the description. Descriptions teach: stepwise semantics ("two points = a step, not a ramp; ramps are dense point runs"), bend center 8192, built-ins honor bend + sustain only (§4.3), chase behavior ("controller values chase at play/seek"), quantize/humanize move notes only (§11), poly-aftertouch deferred. `transport_record`/`project.snapshot` descriptions gain the capture riders in b3 (dense-lane weight note, §7).
- **Catalog** (`CopilotCatalog.swift`): one new row ("Controller lanes — mod wheel, sustain, pitch bend on MIDI clips"), 55→56.

---

## 11. Clip-op composition (found during the read — this section prevents silent data loss)

`Clip` reconstruction sites rebuild clips field-by-field (`splitClip`, `ProjectStore.swift:2861-2880`); a forgotten `controllerLanes:` argument silently drops lanes. Policy table (all v1, all in C8's op matrix):

| op | lane behavior |
|---|---|
| `clip.split` | window both halves via **`Clip.windowedControllerLanes(delta:newLength:)`** — the `windowedGainEnvelope` sibling (`ProjectStore.swift:2849-2854`) with STEP semantics: right half gets an injected beat-0 point carrying the value in effect at the split beat (the §5 chase scan reused); left half keeps points < split verbatim (state holds, no end point needed) |
| `clip.trim` | same windowing helper, delta = start shift; a lane whose only points precede the window keeps a single injected boundary point |
| `clip.duplicate` | lanes copy verbatim — points are identity-free (§3), so the F8d note-id copy question cannot arise |
| `clip.setNotes` | **preserves lanes** (replaces notes only) — pinned, the likeliest silent-drop site |
| quantize / humanize / groove / transpose | notes only; lanes untouched (documented in tool descriptions — matches Logic's default) |
| `arrange.insertBars` / `deleteBars` | clips translate whole; clip-relative lanes ride free (pinned in the matrix anyway) |
| take comping (`windowNotes`, `Takes.swift:297`) | gains the `windowedControllerLanes` sibling so a comp window carries honest lane state |
| `clip.setStretch` / ClipFix | audio-only paths — unreachable for laned clips by the §3 invariant |

The shared pure helper (`windowedControllerLanes` + the lane-state-at-beat scan) lives in DAWCore next to `windowedGainEnvelope` and is reused by split, trim, take windowing, capture slicing (§8.5), and the schedule chase (§5) — **one definition of "the value in effect at beat B"** across the whole tree.

---

## 12. What does NOT change (era pins)

- **AutomationLane plane**: zero diff in `Automation.swift`, `AutomationSchedule.swift`, `AutomationRenderer.swift`, all `automation.*` verbs (grep-pinned in C1).
- **Note scheduling**: note-only `buildEvents` output byte-equal (C1b); the note NO-CHASE guard survives verbatim (`MIDISchedule.swift:111`); `orderedBefore` note-relative order unchanged; the 4096-note wire cap untouched.
- **Renders**: projects without controller lanes render byte-identical — existing era SHA fixtures (C1c).
- **`transport.record` wire shape**: zero growth in b3 (loop state + arm state decide, the m15-b zero-flag law).
- **Graph shape**: zero new nodes, zero reconcile-signature changes; `InstrumentRenderer` POD layout unchanged (24-byte event).
- **m14 loop laws**: timelineID/watermark/prune machinery untouched (`GaplessLoopSpikeTests` green, C5).
- **Wire pins move ONLY in b2** (125/128/56, one change); b3/b4 zero-growth (Explain copy, if any, moves its pin in b4's own change).

**On landing b2, add the ARCHITECTURE.md "Key future decisions" entry** ("MIDI CC/pitch bend: SETTLED (m16-b, 2026-07-…)") summarizing §§1, 3, 4, 5, 6, 7 — the sequencer-clock entry's "CC/pitch-bend/sustain … additive later" clause (ARCHITECTURE.md:166-167) gets a pointer, not a rewrite.

---

## 13. Alternatives considered + failure modes

**Alternatives (strongest two per major call):**

- **CC as AutomationLane** — loses on all four §1 axes (timing model, addressee, lifecycle, editing surface). Strongest counter-argument is UI reuse of `AutomationLaneEditor`, and it fails anyway: that editor is arrange-plane, per-track, beat-absolute — the piano roll needs clip-relative editing against notes.
- **Honest no-chase v1 with teaching surface** — loses to §5 grounds 1–2 (stuck sustain is unusable output; without chase, playback state depends on the PREVIOUS roll — non-deterministic, breaking offline==live). Kept as the documented fallback ONLY if C3/C5 prove unimplementable (they won't — the machinery is a build-time scan).
- **Breakpoints + curves, densified at build** (the automation shape) — loses: capture produces literal events (two representations fight), densification inflates unrolled cycle blocks, and what plays would no longer be what is stored. Literal stepwise points win; a future curve field is additive.
- **Per-point UUIDs** (the MIDINote shape) — loses: identity buys selection semantics the strip does not need (nearest-point targeting suffices), costs ~36 bytes/point on dense captured lanes, and creates the F8d duplicate-identity trap. AutomationPoint precedent wins.
- **A separate CC schedule/second atomic slot per renderer** — loses: two cursors, two watermarks, two merge disciplines to keep coherent with off-before-on ordering across channels; the kind 2+ slots exist precisely so ONE schedule carries ordered mixed events.

**Failure modes:**

1. **`count / 2` noteID double-booking under loop unroll** (`PlaybackGraph.swift:2122`, :2413-2429) — closed by the explicit next-ID return (§4.2), pinned C5.
2. **Silent lane loss through a Clip reconstruction site** — closed by the §11 helper + C8 op matrix (`clip.setNotes` is the likeliest offender).
3. **Stale controller state after stop/seek/wrap/prune** — closed twice: chase (§5) + reset neutralization (§4.3), pinned C3/C5.
4. **Same-frame ordering inversions** (chased sustain after the note-on it should catch) — closed by the rank-1 sort slot (§4.1), pinned C3.
5. **Dense-burst budget overrun** — bounded by the three-layer §7 policy; the residual adversarial case is no worse than today's wire-reachable 4096-note burst (measured), pinned C6.
6. **Capture ring overflow dropping a pedal-up** — closed by reset-neutralization on `droppedFlag` (§8.3), pinned C15.
7. **Snapshot weight from dense captured lanes** — bounded (≤ 16384 points/lane ≈ 160 KB), documented; revisit only on real agent pain (a paging read verb is the additive escape hatch).
8. **AU per-event scheduleMIDI cost unmeasured** — b2 rider measurement (§7); caps already conservative.

---

## 14. Phased landing plan, routing, and C-conditions

### Phase b2 — model + schedule playback
**Route: swift-app-engineer** (DAWCore model + store ops + §11 helper + wire/MCP/catalog) **then audio-dsp-engineer** (MIDISchedule kinds/sort/build/chase, PlaybackGraph base fix, instruments, reset). Files: `Sources/DAWCore/Model.swift`, `ProjectStore.swift` (+ a `ProjectStore+ControllerLanes.swift` if it runs long), `Sources/DAWEngine/MIDISchedule.swift`, `PlaybackGraph.swift` (:2114-2124, :2410-2444), `Instruments/PolySynthInstrument.swift`, `Instruments/SamplerInstrument.swift`, `AudioUnits/HostedAUInstrument.swift`, `Sources/DAWControl/Commands.swift`, `mcp-server/src/`, tests in `Tests/DAWCoreTests` + `Tests/DAWEngineTests` + `Tests/DAWControlTests` + npm.

- **C1 — null era**: (a) a legacy project (fixture without lanes) encodes byte-identical JSON (no `controllerLanes` key); (b) note-only `buildEvents` output arrays byte-equal pre/post (A/B unit); (c) existing offline-render era SHA fixtures byte-identical; (d) untouched clip-verb responses byte-identical.
- **C2 — offline==live CC timing pin**: one schedule with a bend ramp + CC + notes delivered through `renderQuantum` in `.offline` and synthetic-timestamp `.live` harnesses → identical (frame, kind, data1, data2) sequences, `==` (the m12-b event-timestamp idiom).
- **C3 — chase**: unit matrix — seek mid-ramp / past-all-points / before-first-point → chase events at the block anchor frame with the correct latest-≤ value or neutral default (bend 8192, CC64 0, CC11 127); rank strictly after same-frame offs and before same-frame ons; same-frame literal suppresses injection; chased CC64=127 lands before the first on.
- **C4 — RT safety**: zero new allocation/locks/ObjC on any render path (diff review, the audit-rt-safety idiom); channel-pressure message length 2 pinned; unknown-kind fall-through negative test on every built-in.
- **C5 — loop**: mixed-kind noteID uniqueness across ≥ 3 unrolled cycles; cycle k+1's delivered CC block == a fresh seek-to-loop-start build modulo frame offset (self-containment); `GaplessLoopSpikeTests` green.
- **C6 — decimation bound**: same-frame per-lane coalescing unit; caps-saturated adversarial clip live: ≤ 1 overrun, no watchdog trip, wire alive (the §7 envelope); the AU spot-measure rider recorded in the cycle report.
- **C7 — wire**: both verbs + teaching errors verbatim-pinned; counts 125/128/56 in the SAME change; snapshot lane round-trip `==`; `rejectUnknownKeys` on both; npm suite re-pinned.
- **C8 — clip-op matrix**: split (seam value == chase value at the seam), trim, duplicate, setNotes-preserves-lanes, quantize/humanize/groove untouched-lanes, insertBars/deleteBars translation — all against a laned fixture.
- **C9 — built-ins**: PolySynth + Sampler bend factor == `2^(bend/12 semitones)` (pinned analytically on rendered period/FFT peak within tolerance); sustain defers offs until pedal-up; `reset()` neutralizes bend/pedal; HostedAU reset byte sequence (123, 120, 121, bend-center, CC64 0) pinned via a captured schedule block.

### Phase b3 — live thru + capture
**Route: audio-dsp-engineer.** Files: `Sources/DAWEngine/MIDIInput/MIDIUMPParser.swift`, `MIDICaptureSession.swift`, `InstrumentSourceNode.swift` (:305-327 only), `AudioEngine.swift` (take plumbing), `Sources/DAWCore/EngineProtocol.swift` (additive `MIDIRecordingResult.controllerLanes`), `ProjectStore+Takes.swift` (lane lander + windowing), `scripts/e2e-midi-cc.swift` (new, the e2e-midi-record idiom).

- **C10 — parser**: UMP vectors for 0xB/0xE/0xD incl. bend LSB/MSB reassembly; note vectors byte-identical (era).
- **C11 — thru**: live CC reaches the sounding instrument ≤ 1 quantum (headless harness + live e2e); kind ≥ 2 bypasses the pitch map (unit: interleaved CC never corrupts an open note pairing).
- **C12 — capture**: ingest thinning law (duplicate-drop, ≥ 5 ms spacing, final-value-always); pre-anchor latch → beat-0 point (count-in pedal fixture); `MIDIRecordingResult.controllerLanes` additive and nil-safe for fake engines (the weak-`ProjectStore.engine` trap).
- **C13 — loop slicing**: ≥ 3-cycle loop take with CC → per-cycle lanes at the seconds-domain integrals (tolerance ≤ 1e-9 beats, the m15-b G1 idiom); cycle-boundary injected points == the linear stream's value at `k·L`; note-only takes byte-identical (the m15-b G3 cousin — the era gate for this phase).
- **C14 — e2e**: virtual-CoreMIDI end-to-end (sentinel CC 87, distinctive ramp — the sentinel-pitch-113 cousin): thru sounds, recording lands lanes visible in `project.snapshot`, loop take lands per-cycle lanes; staging laws (fresh 176xx port, project.new, exact-pid kill, port closed, .ips accounted).
- **C15 — overflow honesty**: ring-overflow `droppedFlag` → reset neutralizes pedal/bend (unit).

### Phase b4 — piano-roll controller strip
**Route: swift-app-engineer, with ui-design-engineer on the strip's visual pass.** Files: `Sources/DAWAppKit/ControllerStripModel.swift` (new), `MIDIMapGeometry.swift`, `Sources/DAWApp/PianoRoll/ControllerLane.swift` (new), `PianoRollView.swift`, `Sources/DAWApp/Timeline/ClipMIDIMap.swift`, Explain copy if the piano-roll section is touched.

- **C16 — headless model**: value↔y both domains, hit/pencil/drag ops, submission array `==` expected, 16384-cap enforcement at submit.
- **C17 — UI==wire equivalence**: a strip gesture commit produces store state identical to the equivalent `clip.setControllerLane` call (the m11-a idiom).
- **C18 — densities**: Pro editable strip; Simple passive header chip; both captured.
- **C19 — captures pixel-reviewed**: ≥ 3 (bend lane with center guideline; dense captured CC lane, handles suppressed; arrange mini-map trace) — and laneless clips pixel-identical to today; every new Canvas `@Sendable` value-capture with the CANVAS CONTRACT comment and `nonisolated` helpers (the m16-a source-pin test extends to the new sites).
- **C20 — pins**: zero wire growth; Explain pin moves in this change iff copy is added; suites + npm green.

### Ordering and fallback
b2 → b3 → b4, strictly; each phase gates on its C-set plus the full existing suites. If C3/C5 fail in implementation, the documented fallback is honest no-chase v1 (teaching surface in the MCP descriptions) — but the failure must return HERE first (the deviation law), because chase is the settled call.
