# m23-u — live MIDI thru is cut under a still-held note

**Design pass: `daw-architect`, 2026-07-29. Read-only; no source was edited.**
**Implementation route: `audio-dsp-engineer`.**
Every line number below is against the tree at the time of writing
(`Sources/DAWEngine/InstrumentSourceNode.swift` = 756 lines). Re-anchor by
symbol if the file has moved.

---

## 0. Filing amendments — read these before you code

The roadmap's **fix shape is correct** and I am not changing it. Two factual
claims around it are wrong, and one of them changes the severity of the item.

### A1. The masking claim is WRONG. This is not a cold-app corner case.

The filing (and `docs/ROADMAP.md` line 464, and the in-source comment at
`InstrumentSourceNode.swift:643-644`) says:

> `schedule == nil` holds only on a node where a schedule was NEVER published,
> and after any playback one stays published — so it needs a cold app, a track
> that has never played, and a note held longer than 8 s.

That is not what the graph does. `PlaybackGraph.stopAllPlayers()`
(`Sources/DAWEngine/PlaybackGraph.swift:3192`, doc comment `:3180-3191`) calls
`node.renderer.publish(nil)` + `requestFlush()` on **every** instrument node
(`:3215-3218`), and its own doc says:

> Instrument tracks: unpublish + flush is THE all-notes-off contract. Every
> stop, seek, tempo change, tracksDidChange restart, and configuration-change
> recovery already routes through here.

`AudioEngine.stopPlayback()` (`Sources/DAWEngine/AudioEngine.swift:763`) is one
of its callers. So **after the user presses Stop, `schedule == nil` is true
again on every instrument renderer**, and the silence fast-path at `:645` is
live once more.

And nothing republishes while stopped: `stopAllPlayers()` also clears
`midiRollContext` (`:3194`), and both remaining publish sites are gated on it —
`:2894` opens with `if let roll = midiRollContext` and `:3145` sits inside the
roll START that sets it (`:3142`). So `schedule == nil` persists for the whole
stopped period, not just the instant after Stop.

Real repro, no cold app required: arm an instrument track, press play, press
stop, hold a key for more than 8 s. The note dies under your finger. That is
the single most ordinary way a musician uses live thru — play a pad with the
transport stopped — so treat this as a live user-facing defect, not a corner.

**Action for the implementer:** correct the comment at `:641-644` in the same
patch. It is the sentence that convinced three passes in a row that this was
masked. Suggested replacement text is in §7.1, step 6.

### A2. Recovery: there is none that a user would find.

See §4.3. `stopPlayback()` early-returns when the transport is already stopped
(`AudioEngine.swift:763`, `guard currentAnchor != nil else { return }`), and so
does `seek` (`:790`). There is **no panic / all-notes-off wire verb** anywhere
in `Sources/DAWControl` (grepped: zero hits for `panic`, `allNotesOff`,
`notes.off`). The only user-reachable flush while stopped is disarm/re-arm.
This is out of scope for m23-u; a filing line is in §7.3.

### A3. What is right in the filing

The prescribed shape — `openLiveCount`, incremented on a note-on **that finds
`pitchToLiveID[p] == 0`**, decremented on a matched off, zeroed wherever
`pitchToLiveID` is cleared, added to 6d's re-arm — is correct, complete for the
key-held case, and the guard is load-bearing exactly as described. Build it.

---

## 1. Decision

Add one render-thread-only `Int` to `InstrumentRenderer`:

```swift
/// Open live-THRU voices — the thru analogue of `openAuditionCount`, and the
/// term 6d's re-arm needs so the tail cannot expire under a key the user is
/// still physically holding down (m23-u).
///
/// INVARIANT: `openLiveCount == #{ p : pitchToLiveID[p] != 0 }`. It is a
/// POPCOUNT OF THE PITCH MAP and nothing else. Maintained ONLY where the map
/// itself changes — the note-on branch (0 → id) and the MATCHED note-off
/// branch (id → 0) — and zeroed by every bulk clear of the map. Two branches
/// must NOT touch it: kind ≥ 2 (controllers never enter the map, m16-b3 §4.3
/// C11) and the orphan-off branch (nothing to pair with).
private(set) var openLiveCount = 0
```

maintained in exactly three places (`:557` note-on, `:558-560` matched off, the
two bulk clears via a new `clearLiveVoices()` helper), and added as one
disjunct to the 6d re-arm at `:628`:

```swift
if liveCount > 0 || openLiveCount > 0 || openAuditionCount > 0 {
```

`private(set)` (not `private`) mirrors `openAuditionCount` at `:133` and is
what makes the gate legs in §5 possible — every one of them reads it.

### Alternatives, and why they lose

**Alt A — ask the instrument (`var isIdle: Bool` on `InstrumentRendering`).**
The strongest alternative, and the only one that would also close the sustain
pedal residual (§7.2), because the instrument genuinely knows whether a voice
is ringing. It loses on three counts. (1) `AUAudioUnit` exposes no "voices
active" property, so for hosted AUs — the exact case the 8 s tail already
documents as a compromise (`:186-192`) — the answer would have to be
fabricated. (2) It moves a *host* gating decision into every instrument
implementation: a buggy `isIdle` in any third-party-facing adapter becomes a
silence bug in the host, which is the failure class we are here to remove.
(3) It adds a per-quantum virtual call on the render path for a question the
host can answer from state it already owns.

**Alt B — re-arm on "this node has ever seen a live event" / drop the fast
path for armed nodes.** Trivially correct for held notes and trivially wrong
overall: it is precisely the "render every idle instrument forever" outcome the
m23-d design rejected (`:190-192`). Every armed instrument track would render a
full instrument quantum forever on a stopped transport.

**Alt C — a much longer ceiling (10 min instead of 8 s).** Does not fix the
bug, it relocates it: organ and pad players hold notes for minutes, and the
report would come back as "my drone died after ten minutes". It also doubles
the state (a counter *and* a ceiling) while proving nothing.

**Alt D — a thru watchdog mirroring audition's heartbeat.** Rejected on a
structural fact: audition's watchdog works because the **main actor** is
obliged to tick every 500 ms while it holds a voice (`:143-158`,
`beatAuditionHeartbeat` at `:307-311`). Thru has no such producer. The CoreMIDI
receive thread wakes only on traffic, and a physically held key generates none
— MIDI Active Sensing (0xFE) is a system-realtime message and the parser is
message-type-2 only (`MIDIUMPParser.swift:32`, `guard (word >> 28) & 0xF == 0x2`),
so it never arrives. A watchdog without a heartbeat producer degrades to
exactly the timeout that IS the bug.

---

## 2. Q1 — the C11 interaction

### The dispatch, read at source

`InstrumentSourceNode.swift:544-571`, thru drain (6b), four mutually exclusive
branches per popped event:

| Lines | Branch | Touches `pitchToLiveID`? | Counter |
|---|---|---|---|
| `:546-553` | `kind >= controlChange` (2/3/4 = CC / bend / pressure) | **No** — mints a fresh ID only | **must not touch** |
| `:554-557` | `kind == noteOn` | **Writes** slot unconditionally | `+= 1` **iff slot was 0** |
| `:558-560` | note-off with `pitchToLiveID[p] != 0` | **Clears** slot | `-= 1` (unconditional here) |
| `:561-566` | orphan off (slot already 0) | **No** — mints a fresh ID | **must not touch** |

**Confirmed: the counter belongs in the note-on and matched-note-off branches
and nowhere else.** The C11 citation at `:546-551` is about the *pitch map*,
and the counter is defined as that map's popcount, so C11 governs the counter
by construction — not by analogy.

### What breaks if it leaks into the `kind >= 2` path

An **increment** there is catastrophic and silent. Controller traffic is dense:
a single pitch-bend gesture is hundreds of events per second, and CC64 pedal,
mod wheel, and channel pressure all land in this branch. Nothing ever
decrements them, because no off pairs with a controller. Within a second of
normal playing `openLiveCount` is in the hundreds, 6d re-arms unconditionally,
and the node renders its instrument every quantum for the life of the app.
Worse, the counter is no longer a popcount, so the C11 leg in §6.3 (T6) is
the only thing that can catch it — the audio is unaffected.

A **decrement** there is the mirror failure and is *worse than the original
bug*: `openLiveCount` goes negative, `openLiveCount > 0` is false forever, and
the re-arm is dead even for genuinely held keys. m23-u would ship green and fix
nothing.

The **orphan-off branch (`:561-566`) must also not decrement**: by definition
the slot was already 0, so the pitch was never counted. Decrementing there
underflows on the first stray off — and stray offs are ordinary (an off whose
on arrived before this renderer joined the fanout; see the `:120` two-omni-device
note).

### Any other branch that mutates `pitchToLiveID`?

**No.** Exhaustive grep of the whole tree for `pitchToLiveID` returns exactly
seven sites, all in this one file: `:121` (decl), `:234` (init fill), `:257`
(dealloc), `:361` and `:373` (bulk clears), `:557` (set), `:558-560`
(read + clear). There is no all-notes-off branch, no panic branch, no
sustain-pedal branch, and no kind the dispatch does not account for — the
parser emits only 0/1/2/3/4 (`MIDIUMPParser.swift:37-55`) and the dispatch's
four arms cover all five.

Three adjacent facts the implementer should know, none of which require counter
maintenance:

1. **Note-on velocity 0 is normalised to note-off at the parser**
   (`MIDIUMPParser.swift:38-43`). This is load-bearing for the counter: a
   controller using running status sends `9n pitch 00` as its release, and if
   that reached the renderer as a note-on the counter would never come back
   down. It does not. Do not add a velocity check in the renderer — it would be
   a second home for a rule that already has one.
2. **CC 120/123 (all-sound-off / all-notes-off) are not interpreted** by the
   renderer or by either built-in instrument — only CC64 is
   (`PolySynthInstrument.swift:386-396`). So no divergence exists today. If an
   instrument ever acts on CC123, the map would claim keys are open while the
   instrument has released them: the failure is *extra rendering*, never a
   silence bug. Acceptable; note it, do not pre-solve it.
3. **`instrument.reset()` on the `InstrumentRendering` protocol is called from
   exactly two places**, both in this file (`:360`, `:372`). The
   `auAudioUnit.reset()` calls in `AUHostRegistry.swift:220/224` are inside
   `releaseInstrument(forTrack:)`, a main-actor teardown whose caller already
   does `publish(nil)` + `requestFlush()` (`PlaybackGraph.swift:982-983`), so
   the map is cleared on that path anyway.

---

## 3. Q2 — the complete zeroing set

Every site that clears or resets the node's live state, from a whole-file read
plus a whole-tree grep:

| Line | Site | Clears | Needs `openLiveCount = 0`? |
|---|---|---|---|
| `:234` | `init` — `pitchToLiveID.initialize(repeating: 0, ...)` | map | No — the stored-property default `= 0` covers it |
| `:359-366` | **Step 1**, flush flag (`requestFlush` → `instrument.reset()`) | map `:361`, audition `:362`, tail `:365` | **YES** |
| `:371-376` | **Step 1b**, thru-ring `droppedFlag` → `instrument.reset()` | map `:373`, audition `:374`, tail `:375` | **YES** |
| `:382-384` | Step 1c, audition-ring overflow → latches `auditionCutAll` | nothing | No — audition only, never touches thru |
| `:518-519` | 6a watchdog cut | `pitchToAuditionID[p]`, `openAuditionCount` | No — audition only |
| `:583-588` | 6c defensive retrigger close | `openAuditionCount` | No — audition only |
| `:602-603` | 6c matched audition off | `pitchToAuditionID[p]`, `openAuditionCount` | No — audition only |
| `:743-747` | `clearAuditionVoices()` (called from `:362`, `:374`) | audition map, `openAuditionCount`, `auditionCutAll` | No — this is the **model to mirror** |
| `:560` | 6b matched thru off | one map slot | **YES — `-= 1`, not zero** |

So: **two bulk-zero sites, `:361` and `:373`.** The orchestrator's third site,
`:745`, is `openAuditionCount = 0` inside `clearAuditionVoices()` — the
audition counterpart, not a thru site. `liveCount` is a per-quantum local
(`:467`) and resets by construction.

### Make the missed-site failure unrepresentable

Do not add a bare `openLiveCount = 0` line at `:361` and `:373`. Add a helper
that mirrors `clearAuditionVoices()` exactly, and substitute it 1-for-1 for the
`pitchToLiveID.update(...)` line at both sites:

```swift
/// RENDER THREAD: forget every open live-THRU voice (m23-u). Called from the
/// reset paths ONLY, exactly where `clearAuditionVoices()` is called — the map
/// and its popcount must never be cleared apart, which is why they are cleared
/// through ONE function and never inline. Pointer fill, no allocation.
@inline(__always)
private func clearLiveVoices() {
    pitchToLiveID.update(repeating: 0, count: 128)
    openLiveCount = 0
}
```

This is the `ArrangeDropSnap` discipline: the map cannot be cleared without the
counter following, so a future third reset path cannot introduce a stuck
counter by omission. It is also a strict 1-for-1 line substitution — no
behaviour change, nothing for review to re-derive.

---

## 4. Q4 — RT-safety and what bounds the counter

*(Answered before Q3 because Q3's recommendation depends on it.)*

### 4.1 The render-thread checklist

- **No allocation.** One `Int` stored property. `clearLiveVoices()` is
  `UnsafeMutablePointer.update(repeating:count:)` (a `memset`-class fill, the
  identical call already at `:361`/`:744`) plus one integer store.
- **No locks, no atomics.** `openLiveCount` is render-thread-only state, same
  ownership class as `pitchToLiveID` and `openAuditionCount` — see the
  ownership block at `:13-15`. `private(set)` exposes it to tests, which drive
  `renderQuantum` synchronously on the calling thread; that is exactly how
  `openAuditionCount` is already read (`AuditionRenderTests.swift:129` etc.).
  Do **not** promote it to a `daw_atomic` — that would invent cross-thread
  sharing that does not exist.
- **No ObjC dispatch, no retain/release, no clock.** Nothing added touches
  Foundation, AVFAudio, or `mach_absolute_time`.
- **Cost.** One predictable-branch compare-and-increment per popped note event,
  one compare per quantum at `:628`. Below measurement noise.

### 4.2 Overflow / underflow — the prescribed defensive shape

**Use bare `+= 1` / `-= 1`. No clamp, no saturating arithmetic, no `assert`.**

Justification, not preference: the invariant `openLiveCount == #{p :
pitchToLiveID[p] != 0}` makes both hazards unrepresentable.

- **Upper bound is 128**, structurally: the increment fires only on a 0 → non-zero
  slot transition, and there are 128 slots. `Int` overflow is not reachable.
- **Underflow is not reachable**: the decrement at `:560` is inside
  `else if pitchToLiveID[p] != 0`, so the slot was counted and not yet
  discounted. An off with no matching on takes the orphan branch (`:561-566`)
  and touches nothing.
- A `max(0, ...)` clamp would be actively harmful: it converts a broken
  invariant into a silent behaviour change (the tail quietly stops re-arming)
  and removes the only signal a test could see. This mirrors the existing
  audition code, which uses bare `openAuditionCount -= 1` at `:519`, `:588`,
  `:603` under exactly the same non-zero-slot guard.
- A render-thread `assert` is rejected on its own terms: it compiles out in
  release (so it is not a production guard) and traps inside an audio callback
  in debug (so it turns a counting bug into a crash in the user's dev build).
  **Put the assertion in the test instead** — that is what `private(set)` is
  for, and §5 leg T9 does exactly that.

### 4.3 What bounds the counter when a note-off is genuinely lost

**Answer: option (a) — accept the unbounded hold as correct — with one honest
caveat and one filing.**

*In value*, the counter is bounded [0, 128] forever (§4.2). There is no numeric
hazard. What is unbounded is *time*: a key whose off never arrives leaves
`openLiveCount == 1` and the node rendering every quantum indefinitely.

That is the right behaviour, and this is the part worth being explicit about:
**the voice really is open inside the instrument.** The note is audibly stuck.
Rendering it is not a leak, it is the truth — and it is the signal the user
needs in order to do something about it. Today's 8 s cut *hides* a stuck note,
which is strictly worse: the DAW silently disagrees with its own MIDI state and
the user learns nothing. The cost of being honest is one instrument render per
quantum on that node — exactly what a playing track costs — and only on a node
with no published schedule.

**Reset paths that DO fire (cite these; I verified each):**

| Trigger | Path |
|---|---|
| Device unplugged / source goes offline | CoreMIDI notify block `MIDIInputManager.swift:191-196` → `setupChanged()` `:224` → vanished-source loop `:250-261`, `renderer.requestFlush()` on **every** fanout renderer |
| Track disarmed / track switch / removal / node rebuild | `AudioEngine.syncMIDIThruFanout` `:1077-1090`, `requestFlush()` on every renderer dropped from the fanout |
| Instrument changed, track deleted, graph teardown | `PlaybackGraph.swift:982-983`, `:2142-2149`, `:3336-3337` — `publish(nil)` + `requestFlush()` |
| Play, then stop (also seek / tempo change / restart) | `PlaybackGraph.stopAllPlayers()` `:3192`, `:3215-3218` |
| Project replaced | `AudioEngine.projectWillReplace()` `:1060-1068` |
| Thru-ring overflow | step 1b, `InstrumentSourceNode.swift:371-376` |

**The gap, stated plainly as a finding:** in the exact scenario m23-u
describes — transport stopped, device still connected and simply not sending
the off — **pressing Stop does nothing**. `AudioEngine.stopPlayback()` opens
with `guard currentAnchor != nil else { return }` (`:763`); with the transport
already stopped there is no anchor, so `stopAllPlayers()` is never reached.
`seek` has the same guard (`:790`). And there is no panic verb in the control
protocol (§0-A2). The user's only recoveries are: disarm and re-arm the track,
unplug the device, or press play and then stop. That is a real usability hole
that m23-u does not create and does not fix — filing in §7.3.

---

## 5. Q3 — the retrigger asymmetry (RECOMMEND, do NOT fix here)

### The asymmetry, confirmed

Audition closes a retrigger defensively at `:578-598`: a note-on for a pitch
whose `pitchToAuditionID[p] != 0` first emits the off for the old ID and
decrements the counter (`:583-589`), *then* opens the new voice. Thru's note-on
branch (`:554-557`) overwrites the slot with no such close, so the previous
ID is lost and no off can ever pair with it. The file already documents the
consequence at `:118-120` ("Same-pitch collision across two omni devices may
orphan one voice until flush — documented v0 limit").

Today the orphan is masked by the very bug we are fixing: the tail expires and
the node stops rendering, so the zombie voice is inaudible. After m23-u the
counter stays correct (§4.2 — the guard handles the retrigger exactly right)
but the orphan survives, and it can *re-awaken*: play a fourth note thirty
seconds later, the node starts rendering again, and the zombie is still in the
instrument's voice pool. That resurrection is pre-existing behaviour (it
happens today on any node whose tail lapsed), and m23-u neither creates nor
worsens it — but it stops being hidden.

### Recommendation: YES, thru should adopt the defensive close — as its own item

It changes **emitted MIDI**, not just gating: the instrument receives a
synthetic note-off it was never sent. That is a real semantic commitment and
it is why it cannot ride along on a counter fix.

*For:* the render side already refuses to trust the main actor on the audition
path for exactly this reason (`:579-582`), and hardware is a strictly less
trustworthy producer than our own main actor. A stacked, unkillable voice is
the worst failure mode in a MIDI host — it survives every subsequent off and
only a panic clears it.

*Against, and it is not trivial:* two devices in omni on different channels
legitimately share a pitch, and the renderer discards `channel` when it
translates to `ScheduledMIDIEvent` (`:567-569`). The synthetic off would cut a
note a second performer is still holding. That is a genuine musical regression
in a two-keyboard rig, and it is why this needs its own gate rather than a
line in this one.

On balance: adopt it. Single-controller rigs are the overwhelming majority, a
stuck voice is unrecoverable without a panic verb that does not exist, and the
same trade was already accepted for audition. But it is a separate cycle.

### Two findings that make it a separate cycle rather than a five-line edit

**(i) It is a CAPACITY change, not a local edit.** The scratch bounds assume
thru emits **one** event per popped event. A defensive close makes it **two**,
exactly as audition's `2 * audTake` accounts for (`:539`, rationale `:534-536`).
The follow-up must change:

- `:95` `liveScratchCapacity = 128 + thruRingCapacity + 2 * auditionRingCapacity`
  → `128 + 2 * thruRingCapacity + 2 * auditionRingCapacity` (768 → 1280 slots)
- `:539` `emitBound = liveCount + thruTake + 2 * audTake`
  → `liveCount + 2 * thruTake + 2 * audTake`

Getting this wrong is a render-thread buffer overrun — the identical class as
m23-d's AMENDMENT A1 (11 events into an 8-slot buffer). It also breaks an
existing test by construction: `LiveThruRenderTests.droppedFlagTriggersInstrumentReset`
(`:189-207`) pushes 513 same-pitch note-ons and asserts exactly 512 delivered
events (`:203`); with a defensive close that becomes 512 ons + 511 synthetic
offs = 1023.

**(ii) The guard and the defensive close are MUTUALLY EXCLUSIVE, and keeping
both silently reopens m23-u.** Audition's close decrements (`:588`) but leaves
`pitchToAuditionID[p]` non-zero until `:592` overwrites it. If thru grew a
close *and* kept the `== 0` guard on the increment, a retrigger would decrement
to 0 and then decline to increment (the slot is still non-zero) — the counter
would read 0 with a voice open, and the tail would expire under a held note.
**The original bug, restored, on the retrigger path only.** The follow-up must
*replace* the guard with a decrement in the close branch, mirroring `:583-594`
exactly.

### What m23-u must do so it does not foreclose the fix

1. **Say it in the source.** The comment on the guard (§7.1, step 2) must state
   that a defensive close replaces the guard and never joins it. This is the
   one place a future implementer will look.
2. **Do not pin the emitted event count for a thru retrigger.** No new test may
   assert "note-on, note-on, note-off delivered exactly 3 events" — the future
   fix makes it 4. Gate on `openLiveCount` and on idle/audio behaviour, both of
   which are **unchanged** by the future fix (guarded: 1 → 1 → 0; with a close:
   1 → close 0, open 1 → 0). Leg T4 in §6 is written to satisfy this.
3. **Do not touch `liveScratchCapacity` or `emitBound`.** m23-u adds no events.

---

## 6. Q5 — where the gate bites

### 6.1 The existing assertion turns red. Confirmed by reading it.

`Tests/DAWEngineTests/LiveThruRenderTests.swift:55-94`,
`liveEventsRenderAtOffsetZeroWithNoSchedule`:

- `:60-61` push note-ons for pitch 60 and 64. **No off is ever sent.**
- `:83-90` is a `KNOWN RESIDUAL DEFECT` comment naming this exact item.
- `:91-92` pulls `tailQuanta` = `8.0 * 48000 / 512` = **750** quanta.
- `:93` `#expect(harness.pull())` — expects `isSilence == true`.

Under the fix, `openLiveCount == 2` for both pitches, so `:628` re-arms every
quantum, `liveTailRemaining` never reaches 0, `:645` is never taken, execution
reaches `instrument.render` at `:709` and `isSilence.pointee = false` at `:725`.
`pull()` returns `false`. **`:93` fails. That is the first red, and it is the
right one.**

(`EventCaptureInstrument.render` does `memset` the output to zeros
(`Sources/DAWEngine/Instruments/EventCaptureInstrument.swift:65-70`), so this
suite's buffers stay silent either way — only the `isSilence` flag moves. That
is precisely why this suite cannot see the audio class of the bug, and why T1
below needs a real synth.)

### 6.2 How that test must be amended — do NOT delete the property

The bounded-tail assertion at `:91-93` is the **only** test in the tree that an
idle node's tail terminates. Deleting it, or relaxing it, in the very cycle
that makes runaway newly reachable would be the worst possible trade.

**Amend by sending the note-offs first, then asserting the bound.** The exact
shape already exists in the tree — `AuditionRenderTests.swift:211-235` does
this for audition: send the off, assert the node keeps rendering (the release
must ring), then pull `tailQuanta` and assert silence returns. Mirror it:

```swift
// Ring drained, both notes still HELD: the node must keep rendering (m23-u).
#expect(!harness.pull())
// Held past the tail — the whole point of the item. Under the pre-m23-u code
// this quantum was SILENT and this suite documented that as a known defect.
for _ in 0..<(tailQuanta + 4) { #expect(!harness.pull()) }

// Release both, and only NOW is the tail bounded: an idle node cannot render
// forever. The release itself must still ring out (cutting here is a click).
harness.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
harness.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 64)
#expect(!harness.pull())
#expect(harness.renderer.openLiveCount == 0)
for _ in 0..<tailQuanta { _ = harness.pull() }
#expect(harness.pull())          // the bounded-tail property, preserved
```

with `tailQuanta` kept as computed at `:91`. The comment block at `:83-90`
becomes a record of the fix, not a standing defect. **The net effect is that
this test gets stronger: it now pins the counter's decrement path, which
nothing in the tree tests today.**

### 6.3 New suite: `Tests/DAWEngineTests/LiveThruSustainTests.swift`

New file, new suite (SwiftPM globs the directory — **no `Package.swift` edit**).
`@MainActor @Suite("Live thru sustain (m23-u)", .serialized)`, matching
`AuditionSustainTests.swift:20-22`.

**Harness:** copy the shape from `LiveControllerThruTests.swift:28-88` — it is
already generic over the instrument and already has a `PolySynth` factory. Two
required modifications:

- Use `polyHarness()`'s params verbatim (`LiveControllerThruTests.swift:84-88`):
  `sustain: 1.0`, `attack: 0.005`, `decay: 0.05`, `release: 0.05`. A sustain of
  1.0 gives a **perfectly flat** held voice, so "flat across the hold" needs no
  tolerance argument at all. Do not use `PolySynthParams()` defaults.
- `pull()` must return **both** `isSilence` and the buffer peak, and must
  **pre-dirty the buffer with `999` sentinels** before every pull, exactly as
  `AuditionSustainTests.swift:56-61, 73-74` does. That sentinel is what makes
  "silent" mean "actively wrote zeros" instead of "wrote nothing at all", and
  it is the single most transferable thing from that harness.

**Frame math** (48 kHz, 512-frame quanta): `liveTailFrames` = 8.0 × 48000 =
384 000 = **exactly 750 quanta**. Never hardcode 750 — derive it as
`Int(InstrumentRenderer.liveTailSeconds * rate) / 512`, the way both existing
suites do.

---

#### T1 — a held thru note sustains past `liveTailSeconds`, on a REAL instrument, asserting AUDIO

The headline leg. Push `noteOn(60, vel 100)`, pull **12 s** of quanta, never
send an off. Derive the hold the same way as `tailQuanta` —
`let holdQuanta = tailQuanta * 3 / 2` (1125 at 512/48k) — so the two cannot
drift if the quantum size ever changes.

- `peaks[0] > 0.01` — it speaks at all.
- **The discriminating window is strictly AFTER the tail: assert every peak in
  `[tailQuanta + 50, holdQuanta)` is `> 0.01`, and that `max/min < 1.05` over that
  window.** Do **not** copy `AuditionSustainTests.swift:106`'s middle-two-quartiles
  formula: quartiles of a 12 s hold are quanta 281–843, which *straddle* the
  750-quantum boundary, so a partial cut could still read as "mostly flat".
  Under today's code every peak in the specified window is exactly `0.0`;
  under the fix, with `sustain: 1.0`, they are flat to within float noise.
  Red/green with no threshold to argue about.
- `renderer.openLiveCount == 1` throughout.
- No second onset: no `i` where `peaks[i] > peaks[i-1] * 2.5`
  (`AuditionSustainTests.swift:139-145`).

#### T2 — release, and the tail is bounded

From T1's state, push `noteOff(60)`. Assert `openLiveCount == 0` after the next
pull, that the node is still non-silent on that quantum (the release must ring
— cutting it is a click), and that at `tailQuanta + 4` quanta later `pull()`
reports `isSilence == true` **and** peak `== 0`. This is the anti-runaway leg.

#### T3 — an idle node is silent from its FIRST quantum

Verbatim the shape of `AuditionSustainTests.swift:155-161`: a fresh renderer,
nothing pushed, `for _ in 0..<20 { #expect(pull().peak == 0) }` plus
`isSilence == true` on every one, and `openLiveCount == 0`. This is the
anti-regression leg for the fast path's whole purpose — the `= 0` stored-property
default and the zero-init contract at `:176-178`.

#### T4 — THE MUTATION LEG: the guard is load-bearing

Run this exactly:

```
push noteOn(60);  pull → #expect(openLiveCount == 1)
push noteOn(60);  pull → #expect(openLiveCount == 1)   // ← THE GUARD
push noteOff(60); pull → #expect(openLiveCount == 0)
for _ in 0..<(tailQuanta + 4) { _ = pull() }
let last = pull()
#expect(last.isSilence)                                // ← never idles if unguarded
#expect(last.peak == 0)
```

**Under the mutation** (delete `if pitchToLiveID[p] == 0` and increment
unconditionally): step 2 reads 2, step 3 reads 1, `:628` re-arms forever, and
the final two expectations fail. Three independent reds.

Deliberately **not** asserted: how many events the instrument received. §5's
future defensive close changes that from 3 to 4 while leaving every assertion
above unchanged.

**Manual mutation procedure — run it, record the numbers in the close record:**
1. Edit `InstrumentSourceNode.swift`, remove the `== 0` condition only.
2. `./scripts/test.sh --filter LiveThruSustainTests` — check the *printed*
   test count, `--filter` is a substring match and can run more or fewer cases
   than you asked for.
3. Copy the failure lines verbatim into the close record.
4. **Restore by re-typing the line.** `git checkout` / `restore` / `stash` /
   `clean` are FORBIDDEN in this tree.
5. Re-run: green.

The permanent test is the guard; the manual run is the proof the test can
reject as well as accept. Ship both — a passing check that was never shown able
to fail is the failure mode this project has paid for twice.

#### T5 — orphan off does not underflow

Fresh renderer. Push `noteOff(60)` with no preceding on. Pull.
`openLiveCount == 0` (not −1). Then `tailQuanta + 4` quanta → silent. Under a
decrement leaked into the orphan branch (`:561-566`), the counter goes to −1,
`> 0` is false, and this leg still passes on idleness — so assert the counter
value explicitly; that is the only thing that catches it.

#### T6 — the C11 leg: controller traffic must not count

Two parts, both required:

- **Alone:** push 200 events across `controlChange` / `pitchBend` /
  `channelPressure`, with `data1 == 60` on some of them (the map-collision
  hazard `LiveControllerThruTests.swift:140-162` already pins for IDs). Pull.
  `openLiveCount == 0`. Then `tailQuanta + 4` quanta → `isSilence == true`.
- **Under a held note:** `noteOn(60)`, then 100 bends, pull →
  `openLiveCount == 1`, not 101.

This is the direct gate on §2. An increment leaked into `:546-553` fails both.

**Stimulus constraint (hard):** **no leg may include CC64.** See §7.2 — a
pedal-down changes what "correct" means for every idleness assertion here, and
a leg that asserts "released note → idle within 8 s" *with the pedal held*
would be pinning the pedal bug as intended behaviour, forcing the follow-up
item to revert a green test.

#### T7 — both zeroing sites

- **Flush:** `noteOn(60)`, pull, `openLiveCount == 1`, `renderer.requestFlush()`,
  pull → `openLiveCount == 0`, then `tailQuanta + 4` → silent.
- **Drop flag:** push `thruRingCapacity + 1` note-ons on pitch 60 (the shape at
  `LiveThruRenderTests.swift:194-198`), pull. Step 1b resets and clears, then
  512 same-pitch ons drain → **`openLiveCount == 1`** (the guard again — 512
  unguarded). Push `noteOff(60)`, pull → 0, then tail → silent.

#### T8 — no allocation on the render thread

Follow the m23-d precedent: a **one-off probe, not left in the suite** —
`malloc_zone_statistics` `blocks_in_use` delta across ~10 000 quanta with a
note held (so the re-arm path and `instrument.render` run every quantum), 3+
runs, delta must be **0**. Put the script in the session scratchpad and report
the number in the close record. The structural argument stands alongside it:
the only new state is one `Int` stored property; `clearLiveVoices()` is a
pointer fill plus an integer store; no Swift collection, no ObjC, no lock, no
clock is added anywhere on the path.

#### T9 — OPTIONAL: the popcount invariant, directly

If (and only if) the implementer wants it, add an internal test seam beside
`mergedCapacity`'s precedent (`:206`, "an internal test seam"):

```swift
/// TEST SEAM — never called from the render path. The popcount `openLiveCount`
/// is defined to equal; a test that drives adversarial traffic asserts them
/// equal after every quantum.
var openLiveKeyCount: Int { (0..<128).count { pitchToLiveID[$0] != 0 } }
```

then drive a deterministic pseudo-random sequence (a seeded LCG — **no
`Foundation` randomness**, tests must be reproducible) of ons/offs/orphan
offs/controllers across all 128 pitches, asserting `openLiveCount ==
openLiveKeyCount` after every quantum, ending with an all-off sweep that must
return the counter to 0 and the node to the fast path.

**Marked optional deliberately.** T1–T8 are the required gate; do not make a
fuzz leg load-bearing for the close.

### 6.4 Existing tests reviewed for breakage

Search actually run (not an assertion — this is the evidence):
`grep -rn "thruRing" /Users/dsemenov/Views/daw-pro/Tests/`, four hits outside
the two thru suites, each then checked for the ONE conjunction that predicts a
red — *pushes a note-on with no matching off* **and** *later asserts
`isSilence == true` or peak `== 0`*. Only `LiveThruRenderTests:93` satisfies
both. Full result:

| Test | Effect of the fix |
|---|---|
| `LiveThruRenderTests.liveEventsRenderAtOffsetZeroWithNoSchedule:55-94` | **RED at `:93`** — amend per §6.2 |
| `LiveThruRenderTests.scheduleOffPrecedesLiveOnAtSameFrame:96` | Unaffected — schedule published, fast path unreachable |
| `LiveThruRenderTests.liveNoteOffCarriesItsOnsNoteID:125` | Unaffected — counter returns to 0, no silence assertion |
| `LiveThruRenderTests.liveNoteIDsHaveTopBitSet:144` | Unaffected — no silence assertion |
| `LiveThruRenderTests.mergeOverflowLeavesLiveEventsQueuedNotDropped:158` | Unaffected — on+off pair, no silence assertion |
| `LiveThruRenderTests.droppedFlagTriggersInstrumentReset:189` | Unaffected — asserts event counts only |
| `LiveControllerThruTests` (all) | Unaffected — no idleness assertions; C15 publishes an empty schedule (`:172-173`) so the fast path never fires |
| `AuditionRenderTests.thruOverflowStillResetsAndClearsAuditionVoices:363-381` | Unaffected — pushes 513 thru ons (pitch 61) but asserts only reset/audition counts, never idleness. With the fix `openLiveCount == 1` there, harmlessly |
| `AuditionRenderTests.liveScratchCapacityDerivesFromEmitBounds:96-108` | Unaffected — m23-u changes no capacity. **The §7.3-1 follow-up WILL break it** (it pins `liveScratchCapacity == 768` and the derivation formula) |
| `AuditionEngineTests:49` | Unaffected — asserts `thruRing.count == 0` only |
| `AuditionRenderTests` (rest), `AuditionSustainTests` | Unaffected — `openLiveCount` stays 0 on every audition-only path |
| `IdlePlayerSkipTests`, `MIDIRenderTests` | Unaffected — neither appears in the `thruRing` grep, so neither can open a live voice |

---

## 7. Implementation plan

### 7.1 Steps, in order

**File: `Sources/DAWEngine/InstrumentSourceNode.swift` (the only source file).**

1. **Declare the counter** immediately after `pitchToLiveID` (`:121`), before
   `pitchToAuditionID` (`:128`) — grouped with the map it counts. Use the
   verbatim declaration and doc comment from §1, `private(set) var`.
2. **Guard the increment** in the note-on branch (`:554-557`). Hoist
   `let p = Int(event.pitch & 0x7F)`, then:
   ```swift
   } else if event.kind == ScheduledMIDIEvent.noteOn {
       id = nextLiveNoteID
       nextLiveNoteID &+= 1
       let p = Int(event.pitch & 0x7F)
       // GUARD IS LOAD-BEARING (m23-u). The slot is overwritten
       // UNCONDITIONALLY on the next line, so a retrigger of an already-open
       // pitch — real hardware does this, and so does any source that drops an
       // off — would increment twice and decrement once on the single matching
       // off. `openLiveCount` would never return to zero and 6d would re-arm
       // the tail FOREVER: this node renders its instrument every quantum for
       // the life of the app. A silence bug traded for permanent wakefulness.
       // Do NOT simplify this to an unconditional increment.
       //
       // If a defensive retrigger CLOSE is ever added here (the audition path
       // has one at 6c), this guard must be REPLACED by a decrement inside
       // that close, never kept alongside it: the close would decrement while
       // the slot is still non-zero, this guard would then decline to
       // increment, and the counter would read 0 with a voice open — m23-u,
       // restored, on the retrigger path.
       if pitchToLiveID[p] == 0 { openLiveCount += 1 }
       pitchToLiveID[p] = id
   }
   ```
3. **Decrement in the matched-off branch** (`:558-560`), one line after the slot
   is cleared: `openLiveCount -= 1   // slot was non-zero ⇒ counted; cannot underflow`.
   **Touch neither `:546-553` (kind ≥ 2) nor `:561-566` (orphan off).**
4. **Add `clearLiveVoices()`** (§3) beside `clearAuditionVoices()` at `:743-747`,
   and substitute it for the `pitchToLiveID.update(repeating: 0, count: 128)`
   line at **`:361`** and **`:373`**.
5. **Add the disjunct at `:628`**: `if liveCount > 0 || openLiveCount > 0 || openAuditionCount > 0 {`.
   Extend the comment at `:624-627` to say the thru term is what keeps a
   physically-held key alive, and that `openLiveCount` counts *keys*, not
   *voices* (the pedal caveat, §7.2).
6. **Correct the stale comments.** At `:641-644`, the sentence
   *"`schedule == nil` is only true before a schedule has ever been published,
   which is exactly audition's headline case — cold app, transport stopped"* is
   false; `PlaybackGraph.stopAllPlayers()` (`:3192`, `:3215-3218`) unpublishes on
   every stop/seek/tempo change, so the fast path is live on any stopped
   transport. Replace with something like:
   > `schedule == nil` holds whenever the transport is stopped — every stop,
   > seek, and tempo change routes through `PlaybackGraph.stopAllPlayers()`,
   > which unpublishes and flushes — as well as before a schedule was ever
   > published. So this fast path is the ordinary stopped-transport path, not a
   > cold-app corner: everything holding sound must be represented in the
   > condition above.

   Also refresh `:118-120` (the `pitchToLiveID` doc) to name the counter as its
   popcount.
7. **Tests**: amend `LiveThruRenderTests.swift:78-93` per §6.2; add
   `Tests/DAWEngineTests/LiveThruSustainTests.swift` with T1–T8 per §6.3.
8. **Mutation run** (§6.3 T4) and **allocation probe** (§6.3 T8); record both
   numbers verbatim.

### 7.2 Residual this fix does NOT close — the sustain pedal

`openLiveCount` counts **keys held**, not **voices sounding**. With CC64 down,
a key can be released — `pitchToLiveID[p]` cleared, `openLiveCount` back to 0 —
while the voice sustains: both built-ins defer the note-off under the pedal
(`PolySynthInstrument.swift:377`, `:386-396`; `SamplerInstrument.swift:60`,
`:190`). So a pedal-sustained note with no further traffic is still cut at 8 s
after m23-u lands.

This is not speculation. `LiveControllerThruTests.swift:169-173` already
documents it in its own words and works around it:

> An (empty) published schedule keeps the node rendering every quantum — a
> stopped idle node with an empty ring early-returns silence and would never
> sound the pedal-held voice between drains.

**Kept out of m23-u on purpose.** The fix is a `pedalDown` latch set in the
`kind >= 2` branch — the one branch whose inviolability is m23-u's entire risk
story. Folding a latch into it in the same cycle is exactly how C11 gets broken
by accident. Filed separately in §7.3 with the shape.

### 7.3 For the orchestrator — edits I did not make (this pass is read-only)

**`docs/ARCHITECTURE.md` → "Key future decisions"**, one entry:

> **Live-thru voice tracking (m23-u, settled 2026-07-29).** The render side
> tracks open thru voices with `InstrumentRenderer.openLiveCount`, defined as
> the popcount of `pitchToLiveID`, maintained only where that map changes and
> zeroed through `clearLiveVoices()`. The idle fast-path re-arms while anything
> is held. Rejected: querying the instrument (`isIdle`) — `AUAudioUnit` cannot
> answer it and it moves a host gating decision into every instrument; a thru
> heartbeat watchdog — no producer is obliged to tick while a key is physically
> down. Known limits, filed not hidden: the counter tracks KEYS, so a
> CC64-sustained voice is still cut at `liveTailSeconds`; a lost note-off holds
> the node awake until a flush, which is correct (the voice really is stuck)
> but has no user-reachable panic verb.

**Three roadmap filings** (`docs/ROADMAP.md`, M23 block, ids the orchestrator
assigns):

1. *Thru retrigger orphans a voice — adopt audition's defensive close.* A thru
   note-on for a still-open pitch overwrites `pitchToLiveID[p]`
   (`InstrumentSourceNode.swift:554-557`), orphaning the previous voice with no
   off that can ever pair with it; audition already closes defensively
   (`:578-598`). **Not a local edit:** the close emits a second event per popped
   event, so `liveScratchCapacity` (`:95`) needs `2 * thruRingCapacity` and
   `emitBound` (`:539`) needs `2 * thruTake`, or the render thread overruns
   `liveScratch` (the m23-d A1 class); and m23-u's `== 0` increment guard must
   be **replaced** by a decrement in the close, never kept alongside it, or the
   counter undercounts and m23-u regresses on the retrigger path.
   `LiveThruRenderTests.droppedFlagTriggersInstrumentReset:203` changes from 512
   to 1023 delivered events, and
   `AuditionRenderTests.liveScratchCapacityDerivesFromEmitBounds:96-108` must be
   updated in the same patch — it pins both `liveScratchCapacity == 768` and the
   derivation formula, deliberately, so the capacity cannot drift silently. Trade to weigh in the gate: two omni devices
   sharing a pitch legitimately stack, and `channel` is dropped at `:567-569`.
   Route: `daw-architect` → `audio-dsp-engineer`.
2. *A CC64-sustained thru voice is still cut at 8 s (m23-u's residual).*
   `openLiveCount` counts keys, not voices; both built-ins defer note-off under
   the pedal (`PolySynthInstrument.swift:386-396`). Already documented in-source
   at `LiveControllerThruTests.swift:169-173`, which publishes an empty schedule
   to work around it. Fix shape: a render-side `pedalDown` latch set in the
   `kind >= 2` branch on `pitch == 64` (`velocity >= 64`), cleared on pedal-up
   and in `clearLiveVoices()`, added as a disjunct at `:628`. Deliberately kept
   out of m23-u because it edits the C11-governed branch. GATE: pedal down,
   note on, note off, hold >8 s on a real `PolySynthInstrument` asserting audio.
3. *No panic / all-notes-off verb exists.* `AudioEngine.stopPlayback()` early-returns
   when already stopped (`:763`), so pressing Stop cannot clear a stuck thru
   note; `Sources/DAWControl` has no `panic`/`allNotesOff` command. The engine
   primitive already exists (`InstrumentRenderer.requestFlush()`, `:283-286`) —
   this is a wire triple (command + MCP tool + test) plus a transport-bar
   control, not engine work. Standard in every DAW.

### 7.4 Full-Xcode requirements

**None.** m23-u is pure SwiftPM: one source file in `DAWEngine`, two test files,
no manifest change (SwiftPM globs `Tests/DAWEngineTests/`). No entitlements, no
AUv3, no code signing, no bundle rebuild is *required* to verify it — every leg
runs headless under `./scripts/test.sh`. Note for the close record: `dist/DAWPro.app`
is already stale relative to the tree, and m23-u adds **no wire verb**, so the
161-vs-163 command gap does not widen; the app the user launches will still cut
held thru notes until they rebuild.

---

## 8. Failure modes, ranked

| # | Failure | Cause | Caught by |
|---|---|---|---|
| 1 | **Permanent wakefulness** — node renders its instrument every quantum forever | increment without the `== 0` guard, or an increment leaked into `kind >= 2` | T4, T6, T7-drop |
| 2 | **The fix does nothing** — counter negative, `> 0` never true | decrement leaked into the orphan-off branch (`:561-566`) or into `kind >= 2` | T5 (asserts the value, not just idleness), T1 |
| 3 | **Stuck counter after a reset** | a bulk clear that does not zero the counter | prevented structurally by `clearLiveVoices()`; T7 |
| 4 | **Regression: an idle node is no longer silent from quantum 1** | counter not zero-initialised, or the disjunct written as a truthiness bug | T3 |
| 5 | **Buffer overrun on the render thread** | only reachable if someone adds a second emitted event per pop — i.e. the §7.3-1 follow-up done wrong | not reachable in m23-u; capacity note in the filing |
| 6 | Held note still cut (fix incomplete) | the disjunct added at the wrong place — before the drains rather than at `:628` | T1 |

---

## 9. Verification checklist for the close record

- [ ] `LiveThruRenderTests:93` observed RED **before** the amendment (paste the line)
- [ ] T1 window peaks: `0.0` before the fix, flat after (paste min/max)
- [ ] T4 mutation run: failures pasted verbatim; line restored **by retyping**, not by git
- [ ] `malloc_zone_statistics` delta `0` across ≥3 runs of ~10 000 held-note quanta
- [ ] Full `./scripts/test.sh`: grep `^✘`, not `error:`; baseline is 4307 tests / 437 suites, expect +8…12 tests / +1 suite
- [ ] 0 build warnings (use `rtk proxy` when a gate reads build OUTPUT)
- [ ] Wire pins UNCHANGED: allCommands 163 / MCP 166 / catalog 69 — m23-u adds no verb
- [ ] Port 17600 never touched; no app instance started by this cycle
