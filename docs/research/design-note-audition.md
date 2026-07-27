# Design doc (m23-d): Note audition — hear the pitch while you drag it

**Status: DESIGN ONLY — no production code. Gates the m23-d implementation (audio-dsp-engineer).**
**Author: daw-architect, 2026-07-26.**
**Scope:** ROADMAP m23-d (`docs/ROADMAP.md:355`). Every claim about current behavior cites a `file:line` read for this note.
**Deviation law (the m15-b/m16-a/m16-b rule): an implementer who finds this doc wrong in any load-bearing place STOPS and returns the deviation here — the doc is amended before the code diverges. The gate is §13's C-conditions, verbatim.**

---

## 0. Verdict — and the scope correction

**GO (C1–C18, §13).** Nothing here needs full Xcode: all SPM, no entitlements, no AUv3 hosting change, no signing.

**The roadmap's framing is half right, and the half that is wrong makes this item much smaller than it reads.** m23-d says "Needs an engine seam to trigger a one-shot note outside the sequencer schedule, RT-safe and independent of transport state." That seam **already exists and already ships**: it is the M3 (vii) live-thru path.

- `LiveEventRing` (`Sources/DAWEngine/MIDIInput/LiveEventRing.swift`) is a lock-free, allocation-free SPSC ring of `LiveMIDIEvent`, slots allocated in `init`, drop-newest overflow with a `droppedFlag`.
- `InstrumentRenderer.renderQuantum` step 6 (`Sources/DAWEngine/InstrumentSourceNode.swift:301-337`) drains that ring into a preallocated `liveScratch`, mints live noteIDs with the top bit set (`:86-88`), and step 8 (`:377-404`) merges it with the scheduled slice under an explicit schedule-wins-ties rule.
- Step 7 (`:339-343`) takes the silence fast-path only when `schedule == nil && liveCount == 0`, which is exactly what makes live events sound **with the transport stopped** (`:22-26`).

So both halves of the m23-d gate — "audible one-shot with transport stopped AND during playback without disturbing scheduled notes" — are **already structurally supported by the existing merge**, and the merge is already proven by `Tests/DAWEngineTests/LiveThruRenderTests.swift`. What m23-d actually needs is not a new render mechanism; it is **a second PRODUCER for that mechanism**, and the four correctness problems a second producer creates.

The headline calls:

1. **D1 — a SECOND per-renderer SPSC ring (`auditionRing`, 64 slots), NOT a second producer on `thruRing`.** The main actor is its single producer; the render thread is its single consumer. The existing single-producer memory-order contract is preserved verbatim on both rings (§2).
2. **D2 — addressing is by renderer IDENTITY, held strongly on the main actor for the life of the audition**, mirroring `LiveEventFanout`'s "strong refs pin ring memory across renderer teardown" (`MIDIInputManager.swift:13-16`). The arm-scoped fanout is NOT the delivery vehicle (§3).
3. **D3 — audition gets its OWN 128-entry pitch→ID map.** Sharing `pitchToLiveID` with hardware thru is a real aliasing bug, not a theoretical one (§4).
4. **D4 — note-off is LAYERED: main-actor authority + a render-side WATCHDOG, not a fixed cap.** The main actor heartbeats every 500 ms while it believes something is held; the render side kills any audition voice that has gone 3 s without a heartbeat. A wedged main actor therefore cannot leave a stuck note, and a legitimately held key is never cut mid-hold (§5).
5. **D4.3 — the audition ring's overflow policy is NOT the thru ring's.** A set `auditionRing.droppedFlag` cuts **exactly the open audition voices** by synthesizing their note-offs; it **never** calls `instrument.reset()`. Reusing the thru ring's global all-notes-off would kill scheduled voices during playback — a direct violation of the m23-d gate (§5.3, **C7**).
6. **D5 — one command surface**: `PianoRollView` and the wire both converge on `ProjectStore.auditionPitches` / `ProjectStore.auditionNote` → `AuditionController` (DAWCore, headless-testable) → two new `AudioEngineControlling` methods with default no-op implementations (§6, §7).
7. **D6 — the view holds NO policy.** `PianoRollView` and `KeyboardSidebar` call one closure, `onAudition(pitches, velocity)`, with **set semantics** ("exactly these pitches should be sounding now"; `[]` = silence). The controller diffs; retrigger, velocity, voice cap, timers, and the defeat switch all live outside the view (§8).
8. **D7 — audition is refused while RECORDING** (§9), and is structurally incapable of reaching the capture ring or an offline bounce (§9, §10).
9. **The wire triple**: one additive verb `note.audition`. Pins move **allCommands 152 → 153, router cases 155 → 156, MCP tools 155 → 156, copilot catalog 65 → 66** (§11).

---

## 1. Ground truth today (evidence)

| Fact | Evidence |
|---|---|
| SPSC ring, drop-newest, `droppedFlag`, slots allocated in `init` / freed in `deinit` | `LiveEventRing.swift:4-18`, `:30-54`, `:56-69`, `:71-79` |
| Memory-order contract: producer writes slot then release-stores head; consumer acquire-loads head, reads slot, release-stores tail; "one thread per port ⇒ single producer for every ring" | `LiveEventRing.swift:9-13` |
| The receive-thread contract ("must NOT allocate, lock, retain/release, message ObjC, or touch any actor"; counter writes load→store "safe because this thread is the only writer") | `MIDIInputManager.swift:43-49`, `:117` |
| The ONLY producer today: `MIDIInputRTContext.deliver` on the CoreMIDI receive thread | `MIDIInputManager.swift:118-137` |
| Fanout is ARM-scoped — `syncMIDIThruFanout` filters `kind == .instrument && isArmed` | `AudioEngine.swift:1037-1051` |
| Fanout pins ring memory with strong renderer refs; publish + retire-bin ≥ 1 s | `MIDIInputManager.swift:13-26`, `:267-277` |
| Live drain, offset-0 delivery, live-ID minting, pitch-keyed on/off pairing, orphan-off handling | `InstrumentSourceNode.swift:301-337` |
| **The pitch-keyed map is documented as a KNOWN v0 limit**: "Same-pitch collision across two omni devices may orphan one voice until flush" | `InstrumentSourceNode.swift:89-92` |
| Flush + thru-overflow both answer with `instrument.reset()` + clearing `pitchToLiveID` | `InstrumentSourceNode.swift:210-222` |
| Silence fast-path requires `schedule == nil && liveCount == 0` (why thru works while stopped) | `InstrumentSourceNode.swift:339-343`, `:22-26` |
| Merge: all live keys equal `renderStart`, wire order kept, SCHEDULE wins ties (off-before-on) | `InstrumentSourceNode.swift:377-404` |
| Merge back-pressure: overflow leaves live events UNPOPPED — never dropped, never reordered | `InstrumentSourceNode.swift:301-307`, pinned by `LiveThruRenderTests.swift:136-165` |
| Scratch sizes: `thruRingCapacity = 512`, `defaultMergedCapacity = 4608`, both allocated in `init` | `InstrumentSourceNode.swift:63-70`, `:126-133` |
| Kinds: 0 = noteOn, 1 = noteOff, 2/3/4 = CC/bend/pressure; the ONE DATA RULE | `MIDISchedule.swift:14-25` |
| `LiveMIDIEvent` is a 16-byte POD with no noteID and no sampleTime | `LiveMIDIEvent.swift:3-16` |
| Renderer lookup by track id (nil for unknown/audio/bus/mid-rebuild) | `PlaybackGraph.swift:2004-2009` |
| Renderer + instrument built per instrument track; `instrument.prepare` runs on the main actor before any render | `PlaybackGraph.swift:1974-2002` |
| Hosted AUs render a SILENT PLACEHOLDER until an async prepare lands; readiness is `auRegistry.preparedInstrument(forTrack:)` | `AudioEngine.swift:464`, `:1106-1125` |
| Solo/mute audibility authority | `PlaybackGraph.swift:1425-1426`, `:1485` |
| Lazy hardware start: `prepare()` guards on `isRunning`, starts the AVAudioEngine, re-applies mixer params | `AudioEngine.swift:618-664`; call-site idiom `if !isRunning { try prepare() }` at `:2068-2076` |
| `OfflineRenderer` builds a **FRESH** `AVAudioEngine` + `PlaybackGraph` (hence fresh `InstrumentRenderer`s) | `OfflineRenderer.swift:32-40`, `:246`, `:464` |
| Protocol-extension default-implementation idiom for optional engine capability (so the ~6 test fakes compile unchanged) | `EngineProtocol.swift:737-763` |
| Piano roll is store-free: every side effect is an injected closure (`onCommit`, `onSeek`, `onDeleteTimeRange`, …) | `PianoRollView.swift:46-75`; wiring at `ContentView.swift:529-571` |
| Move gesture: `beginGesture` → `applyGesture` (`.move` branch mutates pitch) → `endGesture`; `.cancelled` exists for the m18-i external reseed | `PianoRollView.swift:948-1018` |
| `KeyboardSidebar` is a bare `Canvas` with NO gesture today | `KeyboardSidebar.swift:30-94` |
| Sticky UI flags live in `PanelLayoutStore` and are staged for gates through the app-level `debug.panelLayout` (debug tier, off `allCommands`/MCP) | `DAWProApp.swift:1397-1398`, `:1585-1592` |
| Wire pins, counted this session | `allCommands` = **152**, router `case "…"` = **155**, MCP `registerTool` names = **155**, `CopilotTool(` = **65** |

**The m22-g `audition` hits in `AudioEngine.swift` are the REFERENCE A/B lane and are unrelated to this item** (`AudioEngine.swift:652`, `:963`, `:1785-1913`). No name in this design may collide with them; hence every symbol here is scoped to notes (`setAuditionPitches`, `auditionRing`, `note.audition`), never bare `audition`.

---

## 2. D1 — The seam: a second per-renderer SPSC ring

### 2.1 The decision

Add to `InstrumentRenderer` (`Sources/DAWEngine/InstrumentSourceNode.swift`):

```swift
/// Audition ring (SPSC): producer = the MAIN ACTOR, consumer = this
/// renderer's quantum. 64 slots ≈ 1 KiB, allocated here in init. Kept
/// SEPARATE from `thruRing` because `LiveEventRing`'s correctness argument
/// is single-producer (LiveEventRing.swift:9-13) — the CoreMIDI receive
/// thread owns `thruRing`'s head and the main actor owns this one's; neither
/// thread ever touches the other's ring. Notes only (kinds 0/1).
let auditionRing: LiveEventRing
static let auditionRingCapacity = 64
```

**Memory-order contract (normative — `LiveEventRing.swift:9-13` is amended to read):**

> Memory-order contract (existing CAtomics suffice): the producer writes the
> slot, then release-stores head; the consumer acquire-loads head, reads the
> slot, then release-stores tail. **Every ring has exactly ONE producer and ONE
> consumer for its whole lifetime, and which thread plays each role is fixed at
> the ring's construction site:** thru rings are produced by the CoreMIDI
> receive thread (one thread per port) and consumed by the render thread; the
> capture ring is produced by the receive thread and consumed by the main
> actor; **audition rings are produced by the MAIN ACTOR and consumed by the
> render thread.** No ring is ever produced by two threads, and the main actor
> never pushes to a thru ring.

No new CAtomics primitive is required — `push`/`pop` are used verbatim. `push` from the main actor is trivially legal: it takes no lock, so it cannot block the render thread, and it allocates nothing.

### 2.2 Why the two strongest alternatives lose

**Alternative A — make `LiveEventRing` MPSC.** Two producers on the existing `push` is a *bug*, not a nuance: `push` does a plain load of head, writes `slots[h & mask]`, then stores `h &+ 1`. Two producers interleaved write the same slot and publish one head increment — a lost event, or (worse) a torn event if the two writes interleave field-wise. Making it correct means CAS on head plus per-slot sequence numbers (Vyukov), because a reserved-but-unwritten slot must not become visible to the consumer. That is a new correctness argument, a new CAtomics primitive (`compare_exchange`), and it lands on **the hot path shared with the CoreMIDI receive thread and the render thread** — the two paths in this codebase we least want to re-prove. It buys nothing: the audition producer needs no ordering relationship with hardware MIDI. **Loses on risk-for-zero-benefit.**

**Alternative B — route audition through CoreMIDI (a virtual source + `MIDIReceived`), so the receive thread stays the single producer.** Three fatal problems: (i) it lands in `deliver`, which pushes to the **capture ring** — audition notes would be RECORDED into takes, a fabricated performance (§9); (ii) `deliver` fans out to the **armed** fanout only, which is precisely the addressing this feature must not use (§3); (iii) it makes the whole feature depend on a live CoreMIDI server, so it is untestable on a sandboxed runner where `MIDIInputManager.start()` returns false (`MIDIInputManager.swift:181-184`) — and the m23-d gate must run in CI. **Loses on correctness, addressing, and testability.**

**Also rejected: one GLOBAL audition ring with a `trackID` in the event.** The render thread would have to compare a UUID per event to decide whether the event is its own — 16 bytes of compare per event on the render thread, plus a fanout question at drain time. Per-renderer rings make the addressing *structural*: an event in this ring is, by construction, for this instrument.

### 2.3 Capacity, and why 64

One drag tick pushes at most `2 × maxVoices = 16` events (offs for the leaving pitches + ons for the arriving ones), and the ring drains every quantum (~10.7 ms at 512/48 kHz). 64 slots is four full tick-changes of head-room. The realistic path to overflow is a **stopped or wedged render thread**, which §5.3 handles by cutting audition voices only — never by resetting the instrument.

---

## 3. D2 — Addressing: identity, not arm state

`LiveEventFanout` holds only armed instrument tracks' renderers (`AudioEngine.swift:1037-1040`). Audition must sound on the track being edited **whether or not it is armed**, so the fanout is not the vehicle. Delivery is:

```
ProjectStore.auditionPitches(trackID:pitches:velocity:)      [main actor]
  → AuditionController.set(...)                              [main actor, DAWCore, policy]
    → engine.setAuditionPitches(trackID:pitches:velocity:)   [AudioEngineControlling]
      → AudioEngine: graph.instrumentRenderer(forTrack:)     [PlaybackGraph.swift:2007]
        → renderer.auditionRing.push(LiveMIDIEvent…)         [lock-free, no allocation]
        → daw_atomic_u32_store(renderer.auditionHeartbeat, n &+ 1)
```

`AudioEngine` keeps one entry per track with an audition in flight:

```swift
/// Tracks with audition voices in flight. The renderer reference is STRONG
/// on purpose (the `LiveEventFanout` precedent, MIDIInputManager.swift:13-16):
/// it pins this ring's memory across a node teardown, so a note-off pushed
/// after the strip was rebuilt can never touch freed memory. Entries are
/// dropped when the last voice closes, so nothing is pinned at rest.
private var auditionVoices: [UUID: (renderer: InstrumentRenderer, pitches: Set<UInt8>)] = [:]
```

**The off follows the on.** The off is pushed to the SAME `InstrumentRenderer` object that received the on — not to whatever `instrumentRenderer(forTrack:)` returns at off time. That is what makes the teardown and rebuild cases safe:

| Event mid-audition | Behavior |
|---|---|
| Node rebuilt (instrument change, `invalidateInstrumentNode`) | The lookup returns a DIFFERENT object. The engine pushes offs to the remembered (old) renderer, drops it, and re-triggers the held set on the new one. The old renderer's instrument dies with the node; its ring is pinned by our strong ref until we release it, so the push is memory-safe even if nothing ever drains it. Audible result: a ≤ 500 ms gap, then the held note sounds again on the new instrument. |
| Whole-engine rebuild (`needsEngineRebuild`, m13-a) | Same as above, via the identity check on the next heartbeat. |
| Track removed / kind changed to audio | Lookup returns nil → engine pushes offs to the remembered renderer, drops the entry, returns `.noRenderer`. |
| Track muted or solo-excluded | Events are delivered anyway (the strip is the mute authority — `PlaybackGraph.swift:1425-1485`); the outcome reports `.inaudibleMuted` so the wire can teach. Nothing is special-cased on the render thread. |
| Hosted AU still preparing | Events are delivered to the silent placeholder; outcome `.inaudibleNotReady` (readiness read from `auRegistry.preparedInstrument(forTrack:)`, `AudioEngine.swift:1121`). |
| AVAudioEngine not running (cold app, never played) | `setAuditionPitches` does `if !isRunning { try? prepare() }` — the `AudioEngine.swift:2068-2076` idiom — and returns `.inaudibleEngineStopped` if the start failed (`prepare()` already posted the notice). **This leg is required for the gate's "transport stopped" half on a cold app.** |

**Observation, out of scope:** `syncMIDIThruFanout` (`AudioEngine.swift:1037`) does NOT start the engine, so hardware MIDI thru on a never-started engine is silent too. That is a pre-existing gap; this design does not change thru. Note it, do not fix it here.

---

## 4. D3 — `pitchToLiveID` aliasing: audition gets its own ID space

### 4.1 The trap is real

`InstrumentSourceNode.swift:322-325` keys the open-note map by **pitch alone**. The comment at `:89-92` already concedes the limit for two omni MIDI devices. Adding audition to the same map makes it reachable in an ordinary single-device session:

> Hardware holds C4 (thru note-on → `pitchToLiveID[60] = A`). The user drags a note onto C4 (audition note-on → `pitchToLiveID[60] = B`, **A is orphaned**). The user releases the drag (audition off → takes B, clears the slot). The hardware key is released (thru off → slot is 0 → the "orphan off" branch mints a fresh ID no voice holds, `:326-331`). **Voice A sustains until the next flush** — a stuck note, from an ordinary two-handed gesture.

### 4.2 The decision

Audition gets a parallel map, allocated in `init` beside `pitchToLiveID`:

```swift
/// pitch → the open AUDITION note-on's ID (0 = none). Deliberately NOT
/// `pitchToLiveID`: two live sources sharing one pitch-keyed map orphan each
/// other's voices (an audition on C4 while hardware holds C4 steals the
/// hardware note's ID). Render-thread-only; cleared by every reset path.
private let pitchToAuditionID: UnsafeMutablePointer<UInt64>
/// pitch → `renderedFrames` when that audition voice opened (the watchdog
/// domain, §5). Meaningful only where `pitchToAuditionID` is non-zero.
private let auditionOpenedAt: UnsafeMutablePointer<UInt64>
/// Open audition voices — the early-out for the per-quantum watchdog scan.
private var openAuditionCount = 0
```

**Cost: 2 KiB per instrument track** (2 × 128 × 8 bytes), allocated once in `init`, zero render-thread cost while `openAuditionCount == 0`.

`nextLiveNoteID` is **shared** by both drains — one monotonic counter with the top bit set keeps every live ID unique and distinguishable from schedule IDs, exactly as today (`:86-88`). Audition IDs must NOT come from a second counter: two counters can mint the same value.

Both maps and `openAuditionCount` are cleared by **every** `instrument.reset()` path (`:210-222`), because `reset()` kills every voice.

---

## 5. D4 — Note-off lifetime: main-actor authority, render-side watchdog

### 5.1 The three shapes, unified

| Shape | Natural release | Lifetime |
|---|---|---|
| Vertical drag | drag end / pitch change | held while dragging (Logic behavior) |
| Keyboard-sidebar key press | mouse up / slide to another key | held while pressed — **can legitimately exceed 5 s** |
| Wire `note.audition` | none — an agent has no mouse-up | `durationMs`, main-actor timed |

All three are expressed as ONE state: **"the set of pitches that should be sounding on track T right now."** Drag and key-press are held-while-active; the wire one-shot is the same held state with a scheduled release. There is no second mechanism.

### 5.2 The decision: a watchdog, not a cap

A fixed render-side cap ("kill any audition voice older than 5 s") is the obvious backstop and it is **wrong** for the sidebar: a user holding a key to hear a pad evolve would have the note cut mid-hold, and that ships as a bug report. A main-actor timer alone is also wrong: if the main actor wedges — and this codebase has a documented main-actor-wedge class (the AU-hosting wedge; `debug.mainActorWedge` exists at `DAWProApp.swift:1411`) — the note sticks forever, which is the failure users hate most here.

**Take both, and make the render side a LIVENESS watchdog rather than a duration cap:**

- The main actor bumps a per-renderer heartbeat counter on **every** `setAuditionPitches` call, including calls whose pitch set is unchanged.
- `AuditionController` runs a 500 ms repeating task **only while it believes something is held**, re-calling `setAuditionPitches` with the unchanged set (idempotent: no events pushed, heartbeat bumped).
- The render side refreshes every open audition voice's `auditionOpenedAt` whenever the heartbeat changes, and synthesizes a note-off for any voice that has gone `auditionWatchdogFrames` (**3 s**, precomputed in `init` as `UInt64(sampleRate * 3)`) without one.

Consequences, all desirable:

- A wedged, crashed, or descheduled main actor kills every audition voice within 3 s. **A stuck note is structurally impossible while the render thread runs.**
- A legitimately held key is never cut: the heartbeat arrives 6× per watchdog window.
- No render-thread timer and no clock syscall — the time base is `renderedFrames`, a render-local counter incremented once per quantum (§6.0).
- The controller additionally enforces a **30 s hard hold ceiling** on the main actor (a lost mouse-up with the button physically stuck still terminates), and stops everything on app resign-active.

```swift
/// Audition liveness heartbeat. The MAIN ACTOR is the single writer (plain
/// load→store, the `MIDIInputRTContext` counter idiom); the render thread
/// only compares it against its own last-seen value. A CHANGE means "the
/// main actor still holds these voices" and refreshes their watchdog
/// deadlines. Silence on this counter for `auditionWatchdogFrames` is the
/// ONLY thing the render side needs in order to conclude that the main actor
/// is gone.
let auditionHeartbeat: UnsafeMutablePointer<daw_atomic_u32>

/// Frames of heartbeat silence after which an open audition voice is cut
/// (the watchdog window, 3 s). Precomputed in init — the render path never
/// does sampleRate math and never calls a clock. FLOORED at 1 s of frames
/// so a renderer constructed at a degenerate rate cannot end up with a
/// zero-frame watchdog that kills every audition voice on the quantum it
/// opens (the `performanceRateHz` guard idiom, InstrumentSourceNode.swift:115):
///     auditionWatchdogFrames = UInt64(max(sampleRate, 1) * 3)
private let auditionWatchdogFrames: UInt64
```

**Authority:** this renderer-side constant is the ONE that decides when a voice dies. `AuditionController.watchdogSeconds` (§7.2) is a documentation/derivation copy used only to keep the heartbeat interval comfortably under it — it is never compared against anything, so the two cannot drift into a bug. If they ever must agree numerically, move the number to DAWCore and have `InstrumentRenderer.init` derive from it; do NOT maintain two authorities (the reason mute/solo is computed engine-side in §7.1).

### 5.3 Overflow policy: audition does NOT reset the instrument (C7)

`InstrumentSourceNode.swift:219-222` answers a set `thruRing.droppedFlag` with a global `instrument.reset()`. That is right for hardware thru (no per-voice bookkeeping exists there, and "stuck is worse than cut" — m16-b3 §4.3/§8.3, C15). **It is wrong for audition:** an audition-ring overflow during playback would all-notes-off every SCHEDULED voice, which is exactly what the m23-d gate forbids ("during playback without disturbing scheduled notes").

Audition already has per-voice bookkeeping (`pitchToAuditionID`), so it can cut precisely:

> **Normative:** a set `auditionRing.droppedFlag` synthesizes a note-off for **every open AUDITION voice and nothing else**. It never calls `instrument.reset()`, never touches `pitchToLiveID`, and never touches the schedule. The main actor's held set is deliberately NOT resynchronized — the result is a cut, never a stick.

Corollary for the implementer: **do not reach for `requestFlush()` in the overflow path.** `requestFlush()` (a global all-notes-off) stays correct for engine shutdown, project boundary, and `stopAllAudition()` — the places where nothing scheduled is sounding.

---

## 6. D5 — The render-quantum change, exactly

All of this lands in `InstrumentRenderer.renderQuantum` (`InstrumentSourceNode.swift:200-426`). **The scheduled-MIDI path, the graph shape, the epoch math, the slice math, the merge rule, and the chain/PDC/automation stages are untouched.**

### 6.0 New step 0 — the monotonic render clock

```swift
// 0. Monotonic render clock (the audition watchdog's ONLY time base, §5.2).
//    Incremented once per quantum BEFORE every early return — the invalid-
//    host-time bail (step 4), the silence fast-path (step 7), and the normal
//    exit — so a stopped transport, a silent strip, and a HAL hiccup all
//    still advance it. Never reset. Frames, wrapping at UInt64 (≈ 12 million
//    years at 48 kHz); every comparison uses wrapping subtraction.
renderedFrames &+= UInt64(frameCount)
```

### 6.1 Steps 1 / 1b — clear the audition state on every reset

Both existing reset paths (`flushFlag`, `thruRing.droppedFlag`) must additionally do:

```swift
pitchToAuditionID.update(repeating: 0, count: 128)
openAuditionCount = 0
```

`reset()` kills every voice, so leaving audition IDs behind would orphan the map.

### 6.2 New step 1c — consume the audition drop flag

```swift
// 1c. AUDITION-ring overflow. The dropped push may have been a note-OFF, so
//     every open AUDITION voice is cut in step 6a — and ONLY those. Unlike
//     1b this NEVER calls instrument.reset(): the audition ring shares this
//     renderer with the sequencer, and a global all-notes-off would kill
//     scheduled notes the user is listening to (§5.3, C7).
if daw_atomic_u32_exchange(auditionRing.droppedFlag, 0) == 1 { auditionCutAll = true }
```

(`auditionCutAll` is a render-thread-only `Bool`.)

### 6.3 Step 6 becomes 6a / 6b / 6c

**6a runs FIRST, and that ordering is load-bearing.** If the watchdog's off were appended after the audition drain, a same-pitch retrigger arriving in the same quantum would have already overwritten `pitchToAuditionID[p]`, and the watchdog off would carry the NEW voice's ID — killing the note the user just triggered. This is the §4 aliasing bug in miniature.

```swift
var liveCount = 0

// 6a. Audition watchdog + overflow cut. Emits note-offs into liveScratch at
//     renderStart. Runs BEFORE both drains so an expiring voice's off
//     precedes a same-pitch retrigger arriving this quantum (off-before-on
//     at a shared frame — the step-8 rule, applied within the live block).
if openAuditionCount > 0 {
    let beat = daw_atomic_u32_load(auditionHeartbeat)
    if beat != lastAuditionHeartbeat {
        lastAuditionHeartbeat = beat
        for p in 0..<128 where pitchToAuditionID[p] != 0 { auditionOpenedAt[p] = renderedFrames }
    }
    for p in 0..<128 where pitchToAuditionID[p] != 0 {
        guard auditionCutAll
            || renderedFrames &- auditionOpenedAt[p] >= auditionWatchdogFrames else { continue }
        liveScratch[liveCount] = ScheduledMIDIEvent(
            sampleTime: renderStart, noteID: pitchToAuditionID[p],
            kind: ScheduledMIDIEvent.noteOff, pitch: UInt8(p), velocity: 0)
        liveCount += 1
        pitchToAuditionID[p] = 0
        openAuditionCount -= 1
    }
}
auditionCutAll = false      // consumed even when nothing was open
```

```swift
// 6b/6c. Drain BOTH rings. The m16-b3 back-pressure rule is unchanged in
//        spirit: if the merged total would overflow mergedScratch, leave
//        BOTH rings untouched for the next quantum — never dropped, never
//        reordered. The watchdog offs from 6a are already in liveScratch and
//        are never deferred (a deferred off is a stuck note).
let thruTake = min(thruRing.count, Self.thruRingCapacity)
let audTake  = min(auditionRing.count, Self.auditionRingCapacity)
let emitBound = liveCount + thruTake + 2 * audTake
if thruTake + audTake > 0,
   emitBound <= Self.liveScratchCapacity,          // SCRATCH bound — structural
   slice.count + emitBound <= mergedCapacity {     // MERGE bound — the m16-b3 rule
    // 6b: the EXISTING thru drain body, verbatim — pitchToLiveID, unchanged.
    // 6c: the audition drain (below).
}
```

> **AMENDMENT A1 (implementer, m23-d P1, 2026-07-26 — the §0 deviation law applied).**
> The 6a/6b split above bounds the DRAINS and leaves the WATCHDOG unbounded, and
> that is a render-thread heap overrun, not a nit. 6a raises `liveCount`
> unconditionally; step 8 then writes `slice.count + liveCount` entries into
> `mergedScratch`, whose size is the caller-supplied `mergedCapacity`. Today the
> step-6 guard is the ONLY thing that keeps that write in bounds (when
> `liveCount == 0` step 8 passes `slice` through without copying, so a large
> slice is safe; when `liveCount > 0` the guard has already proven the sum fits).
> Moving an unconditional emitter in front of that guard breaks the invariant.
>
> **Measured, not argued:** `Harness(mergedCapacity: 8)` + 3 open audition voices
> + an 8-event schedule slice + a set `auditionRing.droppedFlag` delivered
> **11 events out of an 8-slot buffer** — 72 bytes past a 192-byte allocation on
> the render thread (`AuditionRenderTests`, "the watchdog's offs never overrun a
> small merged scratch"). Note the direction: §6.3 worried about a caller passing
> a LARGE `mergedCapacity` (overrunning `liveScratch`) and missed the mirror case,
> a SMALL one (overrunning `mergedScratch`).
>
> **The fix is local and costs no memory** — the capacity table in §6.4 stands
> unchanged. The live block gets ONE bound computed before 6a, and 6a honors it:
>
> ```swift
> // `liveScratch` always bounds the block; when a schedule slice is present the
> // MERGE destination bounds it too (step 8 writes slice.count + liveCount there;
> // with an empty slice the block is handed over in place and mergedCapacity is
> // irrelevant).
> let liveBlockBound = slice.isEmpty
>     ? Self.liveScratchCapacity
>     : min(Self.liveScratchCapacity, max(0, mergedCapacity - slice.count))
> ```
>
> …and in 6a's scan, `guard liveCount < liveBlockBound else { auditionCutDeferred = true; break }`.
>
> **Deferral is safe HERE AND ONLY HERE, and §6.3's "a deferred off is a stuck
> note" does not apply to it:** 6a does not clear `pitchToAuditionID[p]` until the
> off is actually written, so the next quantum re-evaluates the identical
> condition and emits it then — one quantum late, never lost. The latched
> overflow flag survives the same way (`auditionCutAll = auditionCutAll &&
> auditionCutDeferred`), or an overflow cut that hit the bound would be silently
> dropped. The alternatives were truncating the schedule slice (drops scheduled
> events) or growing `mergedScratch` by `liveScratchCapacity` (still unsound: a
> slice can exceed any fixed headroom, since `slice.count` has no bound at all).

> **AMENDMENT A2 (implementer, m23-d follow-up, 2026-07-26 — the §0 deviation law
> applied a second time, this one found by the ORCHESTRATOR's negative control,
> not by me).**
> This design specifies which EVENTS reach the instrument and never states that a
> held audition must keep the instrument RENDERING. It implicitly assumes the two
> are the same thing. They are not, and the gap made the feature's headline case —
> transport stopped, cold app — not work at all.
>
> **The defect.** `InstrumentSourceNode` step 7's silence fast-path returns BEFORE
> step 9's `instrument.render(...)`:
>
> ```swift
> if schedule == nil, liveCount == 0 { /* zero-fill, chain/PDC, return */ }
> ```
>
> An instrument holding an OPEN voice is therefore skipped on every quantum that
> carries no events. One cause, both observed symptoms: the audition sounded for
> exactly ONE quantum and then went silent (the smooth multi-second decay a meter
> shows afterwards is `mixer.masterAnalysis` peak-HOLD ballistics, not the synth),
> and the note-OFF — being an event — made `liveCount == 1`, so the fast path was
> skipped and the still-open voice rendered at full level for one more quantum:
> **the note sounded a second time when it was told to stop.**
>
> **Why every test in §13 missed it.** They drive `EventCaptureInstrument`, which
> records events and writes no audio, so it structurally cannot observe a skipped
> render. C8/C9 bump the heartbeat by hand and prove the render side HONORS a
> heartbeat, not that the live path SUSTAINS a voice. And the C18 staging gate
> asserted the bus rises off the floor, reaches a musical level, then collapses
> and is still falling — **a note that never held satisfies all four**.
>
> **The fix** is a frame COUNTDOWN, not a deadline on `renderedFrames` (wrap-free
> by construction, and zero-initialised means a node that never sounded takes the
> fast path from its first quantum). Armed AFTER both drains — the quantum that
> OPENS a voice must arm it, so `openAuditionCount` has to reflect 6c's work
> already:
>
> ```swift
> // 6d.
> if liveCount > 0 || openAuditionCount > 0 {
>     liveTailRemaining = liveTailFrames
> } else if liveTailRemaining > 0 {
>     let elapsed = UInt64(frameCount)
>     liveTailRemaining = liveTailRemaining > elapsed ? liveTailRemaining - elapsed : 0
> }
> // 7.
> if schedule == nil, liveCount == 0, liveTailRemaining == 0 { … }
> ```
>
> …plus `liveTailRemaining = 0` on the two paths that call `instrument.reset()`
> (steps 1 and 1b), where silence until the next noteOn is contracted. Cost on the
> hot path: one `UInt64` and one comparison. No allocation, no lock, no clock.
>
> **`liveTailSeconds = 8.0` is DERIVED, not chosen.** Both built-in instruments
> clamp release to `releaseRange.upperBound == 8` (the sampler's per-zone
> `envRelease` is clamped to the same range) and both release ramps subtract a
> fixed fraction of the level captured at noteOff, so each reaches EXACTLY zero
> there — the tail cannot chop a built-in voice. A hosted AU ringing longer than
> 8 s past its last note-off is truncated: documented, and preferable to rendering
> every idle instrument forever. The tail exists at all so that closing the last
> voice does not cut its release dead, which would be an audible click.
>
> **SCOPE — the thru path has the IDENTICAL hole and this amendment does NOT close
> it.** Live MIDI thru tracks no open-voice count the way audition tracks
> `openAuditionCount`, so the tail expires under a still-held thru note. The tail
> mitigates (one quantum → `liveTailSeconds`) without fixing. It is masked in
> practice because `schedule == nil` holds only on a node where a schedule was
> NEVER published, and after any playback one stays published — which is why m3-vii
> shipped without a report, and why audition hit it first: audition's whole point
> is the cold, stopped, never-played case. Closing it needs an `openLiveCount`
> maintained across 6b's note-on / matched-off / orphan-off branches, which the
> m16-b3 §4.3 C11 pairing rules govern. Filed for `daw-architect`, out of scope
> here.
>
> **Gate consequence, worth carrying to any future DSP work here:** the two
> assertions that catch this class are **"the level is FLAT across the middle of
> the hold"** and **"exactly one onset occurs"**. Both were verified to FAIL on the
> pre-fix build before being trusted on the fixed one (spread 25.75 dB; 2 onsets,
> the second at t=3069 ms tracking `durationMs` exactly). The old release check
> still PASSED there — proof it never had discriminating power. Its `-40 dB`
> threshold was itself an artifact of the bug and is now derived from the flatness
> tolerance instead.

**BOTH bounds are required, and the first one is the one that is easy to lose.** Today the scratch bound is *structural*: `liveScratch` is sized `thruRingCapacity` and the take is `min(queued, thruRingCapacity)`, so it cannot be exceeded no matter what `mergedCapacity` is (`InstrumentSourceNode.swift:307-308`). Adding a second source and a watchdog replaces that structural property with an arithmetic one — and `mergedCapacity` is a caller-supplied `init` parameter (the `LiveThruRenderTests.swift:141` seam), so a caller passing a LARGE `mergedCapacity` would let `liveCount` run past the fixed 768-entry `liveScratch` and corrupt render-thread memory. The first comparison is against a compile-time constant (the optimizer folds it); the second is the existing back-pressure rule verbatim. **C3 asserts the scratch bound specifically, with both a small and a large `mergedCapacity`.**

The `2 *` on `audTake` is not padding: one popped audition note-on can emit **two** events when it retriggers a still-open pitch (the implicit off, then the on). Getting this bound wrong overruns `liveScratch` — memory corruption on the render thread.

**6c, the audition drain:**

```swift
var audDrained = 0
while audDrained < audTake, let event = auditionRing.pop() {
    audDrained += 1
    let p = Int(event.pitch & 0x7F)
    if event.kind == ScheduledMIDIEvent.noteOn {
        // Defensive retrigger: a still-open pitch is closed FIRST, so a voice
        // is replaced, never stacked (the main actor normally sends the off
        // itself; this is the render side refusing to trust it).
        if pitchToAuditionID[p] != 0 {
            liveScratch[liveCount] = ScheduledMIDIEvent(
                sampleTime: renderStart, noteID: pitchToAuditionID[p],
                kind: ScheduledMIDIEvent.noteOff, pitch: event.pitch, velocity: 0)
            liveCount += 1
            openAuditionCount -= 1
        }
        let id = nextLiveNoteID; nextLiveNoteID &+= 1   // ONE shared counter (§4.2)
        pitchToAuditionID[p] = id
        auditionOpenedAt[p] = renderedFrames
        openAuditionCount += 1
        liveScratch[liveCount] = ScheduledMIDIEvent(
            sampleTime: renderStart, noteID: id, kind: event.kind,
            pitch: event.pitch, velocity: event.velocity)
        liveCount += 1
    } else if event.kind == ScheduledMIDIEvent.noteOff, pitchToAuditionID[p] != 0 {
        let id = pitchToAuditionID[p]
        pitchToAuditionID[p] = 0
        openAuditionCount -= 1
        liveScratch[liveCount] = ScheduledMIDIEvent(
            sampleTime: renderStart, noteID: id, kind: event.kind,
            pitch: event.pitch, velocity: 0)
        liveCount += 1
    } else {
        // Orphan off (its on was cut by the watchdog / a reset), or a kind
        // audition never produces (2/3/4 — a producer bug). Mint an ID no
        // voice holds and NEVER touch the pitch map (the m16-b3 §4.3 C11
        // rule): well-behaved instruments no-op it.
        let id = nextLiveNoteID; nextLiveNoteID &+= 1
        liveScratch[liveCount] = ScheduledMIDIEvent(
            sampleTime: renderStart, noteID: id, kind: event.kind,
            pitch: event.pitch, velocity: event.velocity)
        liveCount += 1
    }
}
```

### 6.4 Capacity math (all allocated in `init`; nothing sized at render time)

```swift
static let thruRingCapacity = 512                       // unchanged
static let auditionRingCapacity = 64                    // new (power of two — required)
/// 6a emits ≤ one off per open audition voice (bounded by the 128-pitch
/// domain); 6b emits one event per pop; 6c emits up to TWO per pop.
static let liveScratchCapacity = 128 + thruRingCapacity + 2 * auditionRingCapacity   // 768
static let defaultMergedCapacity = liveScratchCapacity + 4_096                       // 4_864
```

`liveScratch` grows from 512 to 768 entries (768 × 24 B = 18 KiB); `mergedScratch` from 4608 to 4864 (117 KiB). Per instrument track the whole feature adds ≈ **1 KiB (ring) + 2 KiB (maps) + 6 KiB (scratch growth) + 4 B (heartbeat) ≈ 9 KiB**, all in `init`, all freed in `deinit`.

**`mergedCapacity` stays an `init` parameter** — `LiveThruRenderTests` uses it as a seam (`LiveThruRenderTests.swift:141`), and the audition suite needs the same seam.

### 6.5 Steps 7 and 8 need no change

Step 7's guard is `schedule == nil, liveCount == 0`. Watchdog offs land in `liveScratch` and raise `liveCount`, so a quantum that only kills an audition voice correctly falls through to `instrument.render` instead of returning silence. Step 8's merge is source-agnostic: everything in `liveScratch` keys at `renderStart` in array order, and the schedule still wins ties.

---

## 7. D5 (cont.) — The engine seam and the main-actor policy home

### 7.1 `AudioEngineControlling` additions (`Sources/DAWCore/EngineProtocol.swift`)

Two methods, both with default implementations in the extension at `:737`, so every existing fake (`FakeRenderEngine`, `FakePerformanceEngine`, `FakeAudioAnalysisEngine`, `FakeLiveLoudnessEngine`, `BareEngine`, `FakeEngine`) compiles unchanged:

```swift
/// Sounds EXACTLY `pitches` on `trackID`'s instrument RIGHT NOW, outside the
/// sequencer schedule and independent of transport state (m23-d). Set
/// semantics and idempotent: pitches already sounding are left alone, pitches
/// no longer in the set are released, and an EMPTY set silences the track's
/// audition entirely. Every call — including one whose set is unchanged — is
/// also a LIVENESS HEARTBEAT: the render side kills any audition voice that
/// goes 3 s without one, so a caller holding a note must keep calling
/// (`AuditionController` does this every 500 ms). Never throws; the outcome
/// reports why nothing will be heard when that is the case.
@discardableResult
func setAuditionPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8) -> AuditionOutcome

/// Releases every audition voice on every track and requests an all-notes-off
/// on each renderer that held one. Called at engine shutdown, project
/// boundary, and app resign-active — the paths where the main actor is about
/// to stop being able to send note-offs.
func stopAllAudition()
```

```swift
// in extension AudioEngineControlling (EngineProtocol.swift:737)
/// Note audition is optional capability (m23-d, the `masterEffectsChanged`
/// precedent): fakes and headless engines have no instrument renderers, so the
/// default reports `.unsupported` and existing conformers compile unchanged.
public func setAuditionPitches(trackID: UUID, pitches: [UInt8],
                               velocity: UInt8) -> AuditionOutcome { .unsupported }
public func stopAllAudition() {}
```

```swift
/// Why an audition did or did not reach the speakers (m23-d). REPORTING, not
/// policy: the events are delivered in every `inaudible*` case — the strip is
/// simply silent for a reason the caller can act on. Only `noRenderer` and
/// `unsupported` mean nothing was delivered.
public enum AuditionOutcome: String, Sendable, Equatable, Codable {
    case sounded
    case inaudibleMuted          // muted, or excluded by an active solo
    case inaudibleNotReady       // hosted AU still preparing — silent placeholder
    case inaudibleEngineStopped  // the audio engine is not running and would not start
    case noRenderer              // no live renderer (mid-rebuild gap); nothing delivered
    case unsupported             // engine has no audition support (fakes, headless)
}
```

**Audibility is computed ENGINE-side**, from `lastTracks` plus the same solo predicate the graph applies (`PlaybackGraph.swift:1425-1426`, `:1485`) and `auRegistry.preparedInstrument(forTrack:)` (`AudioEngine.swift:1121`). Do **not** re-derive mute/solo in DAWCore: a second copy of that predicate will drift.

### 7.2 `AuditionController` (new file `Sources/DAWCore/Audition.swift`)

`@MainActor public final class AuditionController` — headless, UI-free, engine-free (it holds the store's `weak` engine reference or is handed it per call) and the single home of every policy knob:

```swift
public static let maxVoices = 8                       // simultaneous audition pitches
public static let heartbeatInterval = Duration.milliseconds(500)
public static let watchdogSeconds = 3.0               // NOT authoritative — see §5.2
public static let maxHoldSeconds = 30.0               // main-actor hard ceiling
public static let defaultVelocity: UInt8 = 100
public static let defaultDurationMs = 500
public static let durationRangeMs = 10...5_000
```

State: the current held `(trackID, pitches, velocity)`, the heartbeat `Task`, the one-shot release `Task`, and the hold-start instant. API:

- `set(trackID:pitches:velocity:) -> AuditionOutcome` — the set-semantics entry. Diffs against the held state; a **different track** first silences the old one; starts/stops the heartbeat task; enforces `maxVoices` (keep the lowest N, ascending — the bass is the pitch a musician anchors on) and the 30 s ceiling.
- `oneShot(trackID:pitches:velocity:durationMs:) -> AuditionOutcome` — `set(...)` then a release task after `durationMs`. A second `oneShot` on the same track cancels the first's release task (last call wins), so two overlapping wire calls cannot leave a voice unreleased.
- `stopAll()` — cancels both tasks, calls `engine.stopAllAudition()`, clears state. Idempotent.

**`ProjectStore` owns one `AuditionController`** and exposes the two public entry points the UI and the wire share (§11.1). This is the one-command-surface invariant: the piano roll's drag and `note.audition` execute the *same* code below `ProjectStore`.

**`stopAll()` call sites (non-negotiable, C12):** engine `shutdown()`, `projectWillReplace()` / project open / project new, app resign-active, and the piano roll's `onDisappear`.

---

## 8. D6 — UI seams

### 8.1 One closure, set semantics, zero policy in the view

`PianoRollView` gains exactly one input, defaulted so previews stay one-liners:

```swift
/// Sounds EXACTLY these pitches on the clip's track right now — SET
/// semantics, so an empty array is "stop". Called on every gesture tick; the
/// controller below diffs, so this view neither throttles nor decides when to
/// retrigger. `velocity` is the anchor note's own velocity, so a drag sounds
/// as the note will actually sound. Store-free closure (the `onCommit`/
/// `onSeek` precedent) — the view stays previewable.
var onAudition: (_ pitches: [Int], _ velocity: Int) -> Void = { _, _ in }
```

Call sites in `PianoRollView.swift`:

| Site | Call |
|---|---|
| `applyGesture`, `.move` branch (`:987-991`), after `model.moveSelection` | `onAudition(selectedPitches, anchorVelocity)` |
| `endGesture` (`:1000-1018`), **every** branch including `.cancelled` | `onAudition([], 0)` |
| the view's `.onDisappear` | `onAudition([], 0)` |

`selectedPitches` = the distinct pitches of `model.draft` filtered by `model.selection`, ascending. `anchorVelocity` = the velocity of the lowest selected note. **Firing on every tick is intended**: the controller's diff makes a no-change tick free, and it removes the last drop of policy from the view.

**The first `applyGesture` fires with `deltaPitch == 0`**, so pressing a note sounds it at its current pitch before any movement. That is Logic's behavior and it is intended — not a defect.

### 8.2 `KeyboardSidebar` key press

`KeyboardSidebar` gains the same closure input and a `DragGesture(minimumDistance: 0)` over the `Canvas` (which needs `.contentShape(Rectangle())` to hit-test — a `Canvas` has no default hit shape):

- `onChanged` → map `value.location.y` through the inverse of the pitch↔y affine (`PianoRollModel.y(forPitch:)`, reproduced inline per the m16-a `@Sendable` Canvas contract at `KeyboardSidebar.swift:32-35`) → `onAudition([pitch], 100)`. Sliding across keys glissandos for free, because the controller diffs.
- `onEnded` → `onAudition([], 0)`.

**Scroll is not harmed**: trackpad/wheel scrolling is not a `DragGesture`, so the vertical `ScrollView` still scrolls over the gutter. Only click-drag-to-scroll inside the 54 pt gutter is consumed, and macOS has no such idiom.

### 8.3 `ContentView` wiring and the defeat switch

```swift
onAudition: { pitches, velocity in
    guard model.panelLayout.auditionEnabled else { return }
    guard let trackID = trackID(ofClip: clip.id) else { return }
    _ = try? store.auditionPitches(trackID: trackID, pitches: pitches, velocity: velocity)
}
```

`ContentView` already locates a clip's track by iteration (`ContentView.swift:1063-1067`); add the sibling that returns the track id.

**The defeat switch is `PanelLayoutStore.auditionEnabled` (default true), persisted like `followPlayhead` and staged for gates through the existing app-level `debug.panelLayout {auditionEnabled}` (`DAWProApp.swift:1397`, `:1575-1583`) — debug tier only, ZERO wire growth** (the m23-c2 precedent verbatim: view-chrome preferences do not become agent capabilities).

**The wire deliberately IGNORES this preference.** An agent calling `note.audition` is making an explicit request to hear something; the UI preference means "don't sound notes while I edit", not "never make sound". Say so in the catalog entry.

### 8.4 Explicitly out of scope for v1 (additive later, one line each)

Audition on note ADD (double-click), on click-select, on velocity-lane drag, and on paste. Same closure, same controller; kept out so the gate stays about the mechanism.

---

## 9. D7 — Recording, the capture ring, and punch

**Audition can never be recorded.** Capture is fed by `MIDIInputRTContext.captureRing`, pushed only by `deliver` on the CoreMIDI receive thread (`MIDIInputManager.swift:130`) and drained into `MIDICaptureSession` at ~30 Hz (`:283-291`). The audition ring is per-renderer and is not reachable from `deliver`. **There is no punch, take-slicing, or loop-cycle interaction to design** — the two paths do not touch.

**Audition is nevertheless REFUSED while the transport is recording**: `ProjectStore` throws `ProjectError.transportBusy("cannot audition while recording — stop the take first")`; the UI's `try?` swallows it and stays silent. Rationale: anything a user hears during a take is reasonably assumed to be *in* the take, and both honest alternatives are worse — sounding it without capturing it is a lie, and pushing it into the capture ring would fabricate performance data the user never played. This is **policy, not mechanism**: one `guard` in `ProjectStore`, relaxable additively if the beta asks.

Count-in, loop-record cycles, and comping need no changes.

---

## 10. Offline render isolation (verified, C13)

`OfflineRenderer` constructs a **fresh `AVAudioEngine` and a fresh `PlaybackGraph`** per render (`OfflineRenderer.swift:246`, `:464`), so its `InstrumentRenderer`s — and therefore their audition rings and pitch maps — are new and empty by construction. **A held audition can never be baked into a bounce, a stems export, a loudness measurement, or a clip-fix render.** The gate proves this rather than assuming it (C13).

---

## 11. The wire triple (additive only)

### 11.1 `ProjectStore` surface (the one command surface)

```swift
/// Sets the pitches auditioning on `trackID` (set semantics; [] = stop). The
/// piano roll's drag and keyboard gutter call this; so does the wire.
@discardableResult
public func auditionPitches(trackID: UUID, pitches: [Int], velocity: Int) throws -> AuditionOutcome

/// One-shot audition that releases itself after `durationMs` — the wire's
/// entry (an agent has no mouse-up). Returns IMMEDIATELY; it never blocks the
/// control connection for the duration.
@discardableResult
public func auditionNote(trackID: UUID, pitches: [Int], velocity: Int,
                         durationMs: Int) throws -> AuditionResult
```

### 11.2 Command: `note.audition`

New namespace `note.` (the roadmap's name; `midi.` today means hardware I/O and `instrument.` means plugin discovery, so neither fits). One-verb namespaces already exist on this wire (`midi.listInputs`).

**Params** (`rejectUnknownKeys` with a teaching hint — the `input.setDevice` idiom at `Commands.swift:3074`):

| Key | Type | Required | Rule |
|---|---|---|---|
| `trackId` | string (uuid) | yes | must name an **instrument** track |
| `pitches` | array of int | yes | 1…8 entries, each 0…127, de-duplicated |
| `velocity` | int | no (100) | 1…127 |
| `durationMs` | int | no (500) | 10…5000 |

There is deliberately **no `pitch` singular alias** — two spellings of one concept doubles the teaching burden in the catalog and the unknown-key hint.

**Response:**

```json
{ "trackId": "…", "pitches": [60, 64, 67], "velocity": 100,
  "durationMs": 500, "audible": true }
```

`"audible": false` carries a `"reason"`: `"trackMuted"` | `"soloExcluded"` | `"instrumentNotReady"` | `"engineStopped"` | `"engineRebuilding"`.

**Throws (teaching errors, all before anything is pushed):** unknown `trackId`; not an instrument track (name the track, suggest `project.overview`); `pitches` missing / empty / > 8 / out of range; `velocity` or `durationMs` out of range; `transportBusy` while recording; `engineUnavailable`.

**No `note.auditionStop` verb.** The auto-release plus the render-side watchdog makes it unnecessary, and a second verb is a second thing to keep honest.

### 11.3 MCP tool + catalog

`mcp-server/src/server.ts`: `server.registerTool("note_audition", …)` following the `midi_list_inputs` shape (`server.ts:1376-1396`) → `bridge.send("note.audition", {trackId, pitches, velocity, durationMs})`. Zod: `pitches` as `z.array(z.number().int().min(0).max(127)).min(1).max(8)`.

`Sources/DAWControl/CopilotCatalog.swift`: one `CopilotTool` entry. The description must teach: it sounds notes **now**, outside the timeline; it does not edit the clip; it works stopped or playing without disturbing playback; `audible:false` + `reason` is a real answer, not an error; and it ignores the user's UI audition preference on purpose.

### 11.4 Pins (verify under the wire-check law: SHA-256 `Commands.swift` + `server.ts` at delegation, `shasum -c` at close-out)

| Pin | Before | After |
|---|---|---|
| `allCommands` entries | 152 | **153** |
| Router `case "…"` | 155 | **156** |
| MCP `registerTool` names | 155 | **156** |
| `CopilotTool(` entries | 65 | **66** |

---

## 12. Failure modes — the paranoid table

| # | Failure | Answer | Proven by |
|---|---|---|---|
| F1 | Two producers corrupt a ring slot | Separate rings; one producer each, fixed at construction (§2.1) | C1 |
| F2 | Hardware C4 + audition C4 orphan each other | Separate pitch→ID maps (§4) | C6 |
| F3 | Ring overflow drops a note-off → stuck audition voice | The drop flag cuts every open audition voice (§5.3) | C7 |
| F4 | Audition overflow all-notes-offs the SCHEDULE | `instrument.reset()` is never called from the audition path (§5.3) | C7 |
| F5 | Main actor wedges / crashes mid-hold | 3 s liveness watchdog on the render thread (§5.2) | C8 |
| F6 | Held key legitimately longer than the watchdog | 500 ms heartbeat refreshes deadlines (§5.2) | C9 |
| F7 | Lost mouse-up (window resign, gesture eaten) | `endGesture` covers `.cancelled`; `.onDisappear`; resign-active `stopAll()`; 30 s main-actor ceiling | C12 |
| F8 | Engine stops with a voice open → phantom note on restart | `stopAllAudition()` at shutdown pushes offs AND `requestFlush()`; the next quantum after any restart resets | C12 |
| F9 | Node / engine rebuild mid-hold | The off follows the on via the remembered renderer; the identity check re-triggers on the new one (§3) | C5 |
| F10 | Clip switch mid-drag (`.id(clip.id)` recreates the view; m18-i swallows the gesture as `.cancelled`) | `.cancelled` sends `[]`; `.onDisappear` sends `[]` | C12 |
| F11 | Project close / new mid-audition | `projectWillReplace` → `stopAll()` | C12 |
| F12 | Audition leaks into a bounce / stems / loudness render | Offline builds fresh renderers (§10) | C13 |
| F13 | Audition recorded into a take | Structurally unreachable from the capture ring; also refused while recording (§9) | C14 |
| F14 | Same-pitch retrigger kills the new voice | The watchdog runs BEFORE the drain; the drain closes an open pitch before reopening it (§6.3) | C4 |
| F15 | `liveScratch` overrun (the `2 × audTake` bound) | The capacity constant derives from the emit bounds (§6.4) | C3 |
| F16 | Two overlapping wire one-shots leave a voice open | The second cancels the first's release task; last call wins (§7.2) | C11 |
| F17 | Agent asks for a 10-minute audition | `durationMs` clamped to 10…5000 by the wire; the watchdog is a floor under that | C10 |

---

## 13. GATE — what the implementer must prove (C1–C18)

**Suites**: extend `Tests/DAWEngineTests/LiveThruRenderTests.swift`'s harness idiom into a new `Tests/DAWEngineTests/AuditionRenderTests.swift` (direct `renderQuantum` calls against `EventCaptureInstrument` — no engine, no hardware, no CoreMIDI), plus `Tests/DAWCoreTests/AuditionControllerTests.swift` (headless policy) and `Tests/DAWControlTests/AuditionCommandTests.swift` (wire). Baselines must advance from **3402/365 Swift + 207/207 npm, 0 warnings**.

| C | Condition |
|---|---|
| **C1** | `thruRing` is never pushed from the main actor and `auditionRing` is never pushed from the receive thread. Enforced by construction plus the amended `LiveEventRing` doc comment; asserted by inspection in review. |
| **C2** | The scheduled-MIDI path is untouched: `GaplessLoopMIDITests`, `MIDIRenderTests`, `MIDISchedulerTests`, `MIDIControllerScheduleTests`, `LiveThruRenderTests`, `LiveControllerThruTests` all pass **unmodified** (except `LiveThruRenderTests`' capacity constants, if its harness pins them). |
| **C3** | Capacity: `liveScratchCapacity == 128 + thruRingCapacity + 2 * auditionRingCapacity`; a test fills the audition ring with 64 retriggering note-ons and asserts no overrun and the exact event count. |
| **C4** | **Audible one-shot with the transport STOPPED**: no schedule published, push an audition note-on, one quantum → the event fires at `firedAtFrame == 0` and `isSilence == false`. |
| **C5** | **During playback without disturbing scheduled notes**: with a live schedule, an audition on/off pair interleaves at `renderStart` and **every scheduled event still fires exactly once with its own noteID**; no `wasReset` appears in the capture. |
| **C6** | **Aliasing**: thru note-on C4 → audition note-on C4 → audition note-off C4 → thru note-off C4 yields FOUR events whose offs carry their OWN ons' IDs (`off_thru.noteID == on_thru.noteID`, `off_aud.noteID == on_aud.noteID`, and the two on-IDs differ). **This test fails on today's code — it is the §4 regression pin.** |
| **C7** | **Overflow isolation**: overflow the audition ring (65 pushes) with a schedule playing → the capture shows note-offs for the open AUDITION voices **and no `wasReset`**, and the scheduled voices keep sounding. Separately: overflow the THRU ring and confirm `reset()` still fires (the m16-b3 contract is unchanged). |
| **C8** | **Watchdog**: open an audition voice, then pull quanta with NO heartbeat bump for > 3 s of frames → a synthesized note-off with that voice's ID appears exactly once and `openAuditionCount` returns to 0. |
| **C9** | **Heartbeat**: the same scenario WITH a heartbeat bump every ~500 ms *of frames* for 10 s *of frames* → **no** synthesized off; then stop bumping → the off arrives within 3 s of frames. **Drive this with a quantum loop (~938 pulls at 512/48 kHz), never `Task.sleep`** — a wall-clock gate reintroduces exactly the load-sensitivity that makes `EQCurveEditorModelTests:753` flaky. |
| **C10** | Wire clamps: `durationMs` outside 10…5000, `velocity` outside 1…127, `pitches` empty / > 8 / out of range, an unknown key, a non-instrument track, an unknown track, and recording each throw a teaching error; none of them push an event. |
| **C11** | Two overlapping `note.audition` calls on the same track+pitch leave **zero** open voices once the later duration elapses. |
| **C12** | Stuck-note sweep — after each of `stopAllAudition()`, engine `shutdown()`, `projectWillReplace()`, gesture `.cancelled`, and `.onDisappear`: the controller's held set is empty and the renderer received offs (or a flush). |
| **C13** | **Offline isolation**: hold an audition, then run an offline render of the same project → the rendered buffer is bit-identical to the same render with no audition held. |
| **C14** | **Capture isolation**: hold an audition through a MIDI-only take → the finished `MIDIRecordingResult` contains zero audition notes. |
| **C15** | **No allocation on the render thread** — argued structurally, not by "the suite passes" (§13.1). |
| **C16** | Wire pins land exactly 153 / 156 / 156 / 66, verified by re-running §1's counting commands, with the delegation-time SHA of `Commands.swift` + `server.ts` checked by `shasum -c`. |
| **C17** | UI: with `auditionEnabled` false a drag pushes nothing; with it true a drag pushes; the wire verb works in both states. |
| **C18** | A staging gate (port 17695, staging laws) proves the END-TO-END path — `note.audition` on a real instrument track with the transport stopped, and again while playing — by asserting a **non-zero master level while the transport is stopped**, not by asserting that the command returned ok. |

**C18 is written this way on purpose (the m23-c1/m23-c2 GATE LAW, generalized):** a command that returns ok proves the wire, never the sound. And COMPUTE the fixture before writing the sampling loop rather than discovering it by trial: the audition must outlive the sampling window, so `durationMs` must exceed `pollInterval × samples` — with the default 500 ms and a ~33 ms meter tick, a 5-sample loop is already marginal. Pick `durationMs = 3000` and sample 10 times at 100 ms, or the gate will pass or fail on scheduling luck rather than on audio.

### 13.1 The no-allocation argument (C15) — structural, line by line

The implementer must be able to point at each of these:

1. `auditionRing` slots: allocated in `LiveEventRing.init` (`LiveEventRing.swift:35-39`), which runs from `InstrumentRenderer.init` on the main actor. Capacity is a power of two (64) — `precondition` at `:31`.
2. `pitchToAuditionID`, `auditionOpenedAt`: `.allocate(capacity: 128)` in `InstrumentRenderer.init`, `.deallocate()` in `deinit`.
3. `auditionHeartbeat`: `.allocate(capacity: 1)` in `init`, `.deallocate()` in `deinit`.
4. `liveScratch` / `mergedScratch`: sized from compile-time constants in `init`; the drains' write index is bounded by §6.4's arithmetic, so no growth path exists.
5. `renderedFrames`, `lastAuditionHeartbeat`, `openAuditionCount`, `auditionCutAll`: stored properties of a class, mutated in place — no boxing, no `Array`.
6. The 6a scan is a fixed `0..<128` integer loop over `UnsafeMutablePointer` — no `Sequence` abstraction that could box, no `Array` bridging.
7. Every event constructed on the render thread is a `ScheduledMIDIEvent` **struct** POD written into preallocated memory — no ARC traffic (nothing in the audition path is a class reference except the ring, reached through a stored property on `self`).
8. `daw_atomic_u32_load/store/exchange` are the only synchronization: no new primitive, no lock, no `os_unfair_lock`, no ObjC message, no actor hop.
9. The main-actor side (`push`, heartbeat store) allocates nothing either, so audition cannot cause a UI stall — though the main actor is permitted to allocate.

Recommended empirical backstop (not a substitute for the argument): run the audition suite under an allocation-counting scheme or a temporary `malloc` interposer in a scratch build and confirm zero allocations across 10 000 audition quanta. Record in the ORCH note whether this was run.

---

## 14. Implementation order — riskiest decision first

| Phase | Work | Why here |
|---|---|---|
| **P1** | `InstrumentRenderer`: `auditionRing`, both maps, heartbeat, `renderedFrames`, steps 0 / 1c / 6a / 6b / 6c, capacity constants. `AuditionRenderTests` for C3–C9. **No app, no wire, no protocol.** | This is the whole risk. It is testable in isolation with the existing `LiveThruRenderTests` harness idiom, and it either holds or it doesn't — find that out before anything depends on it. |
| **P2** | `AudioEngineControlling` additions + defaults; `AudioEngine.setAuditionPitches` / `stopAllAudition` (renderer identity, diff, heartbeat, engine start, audibility); `stopAll` call sites (shutdown, `projectWillReplace`). | Second-riskiest: renderer lifetime across a rebuild. |
| **P3** | `AuditionController` (DAWCore) + `ProjectStore.auditionPitches` / `auditionNote`; `AuditionControllerTests`. | Pure policy, headless. |
| **P4** | Wire triple: `note.audition` + MCP tool + catalog + `AuditionCommandTests`; pins re-counted (C16). | Now the copilot can drive the gate. |
| **P5** | UI: `PianoRollView.onAudition`, `KeyboardSidebar` gesture, `ContentView` wiring, `PanelLayoutStore.auditionEnabled` + the `debug.panelLayout` key. | Last, because P4 gives an agent-drivable path that proves the engine before any pixels move. |
| **P6** | Staging gate (C18), CHANGELOG, ROADMAP tick, `docs/ARCHITECTURE.md` (§15), memory patch. | Close-out. |

**Deviation checkpoints:** if P1's C6 or C7 cannot be made to pass without touching the scheduled path, STOP and amend this doc (§0 deviation law). If `auRegistry.preparedInstrument(forTrack:)` turns out not to be reachable synchronously from `setAuditionPitches`, report `.sounded` and file `inaudibleNotReady` as a follow-on rather than inventing new bookkeeping.

---

## 15. `docs/ARCHITECTURE.md` — the settled decision (implementer applies at close-out)

This design pass is read-only, so the ARCHITECTURE.md edit belongs to the **implementer, at m23-d close-out**. Add to the live-MIDI section, and retire any "Key future decisions" line about a note-trigger seam:

> **Note audition (m23-d).** The live-event path has TWO producers, one ring each: hardware thru is produced by the CoreMIDI receive thread into `InstrumentRenderer.thruRing`; note audition (piano-roll drag, keyboard gutter, `note.audition`) is produced by the MAIN ACTOR into `InstrumentRenderer.auditionRing`. Every `LiveEventRing` has exactly one producer and one consumer, fixed at its construction site — that is what keeps the SPSC correctness argument intact with a second source. The two sources keep separate pitch→noteID maps (a shared map orphans voices when both sound the same pitch) and separate overflow policies: a thru-ring drop is answered with a global `instrument.reset()`, an audition-ring drop cuts **only** the open audition voices, because audition shares the renderer with the sequencer and must never all-notes-off scheduled playback. Audition note-off is layered: the main actor is the authority (drag end / key up / `durationMs`) and heartbeats every 500 ms while it believes something is held; the render thread runs a 3 s liveness watchdog on that heartbeat, so a wedged main actor cannot leave a stuck note and a legitimately held key is never cut. Policy (voice cap, retrigger, defeat switch, refuse-while-recording) lives in `AuditionController` (DAWCore); the render side holds mechanism only. See `docs/research/design-note-audition.md`.

---

## 16. Open questions the implementer must resolve empirically (do not guess)

1. **Does `prepare()` called from `setAuditionPitches` produce an audible FIRST note on a cold app**, or does the freshly started engine need a quantum or two before the source node is pulled? If the first audition after a cold start is silent, the fix belongs in the controller (retry the note-on once on the next heartbeat), never on the render thread. Measure it; do not pre-build the retry.
2. **`inaudibleNotReady` reachability** — confirm `auRegistry.preparedInstrument(forTrack:)` is callable from `setAuditionPitches` without an `await` (it is main-actor state, but `prepare` is async). If it forces a suspension, report `.sounded` and file the readiness reason as a follow-on.
3. **`KeyboardSidebar` gesture vs. the enclosing `ScrollView`** — verify empirically that wheel/trackpad scrolling over the gutter still scrolls the roll with the `DragGesture` installed. If SwiftUI surprises here, fall back to `.simultaneousGesture` with a small `minimumDistance` and accept that a slow gutter drag may not glissando.
4. **The 8-voice cap's selection rule** ("keep the lowest 8, ascending") is a guess about what a musician wants from a > 8-note drag. If the beta disagrees it is one line in `AuditionController`.
5. **Whether the drag should sustain or blip.** This design SUSTAINS (held while dragging, Logic-style) because it needs no extra timer and it is the same mechanism as the key press. If it drones unpleasantly on pad patches in practice, the additive fix is a controller-side max-sustain for the *drag* shape only — never a render-side change.

---

## 17. What this design deliberately does NOT do

- No change to `LiveMIDIEvent`'s 16-byte POD, to `ScheduledMIDIEvent`, to the schedule build, or to the graph shape.
- No new CAtomics primitive, no MPSC ring, no CoreMIDI virtual endpoint.
- No audition of CC / bend / pressure (kinds 2/3/4) — notes only; the drain treats any other kind as a producer bug and passes it through without touching the pitch map.
- No per-track audition device/channel selection, and no audition through a bus or through an instrument other than the track's own.
- No `note.auditionStop` verb, no second `note.*` verb, no MCP tool beyond the one.
- No change to hardware MIDI thru's arm-scoped fanout, its overflow policy, or its known same-pitch-across-two-devices limit.
