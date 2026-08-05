# m23-bp — Note chase at continuation reschedules

**Status:** DESIGN (2026-08-02). Not implemented. Written by `daw-architect` for the
implementing agent; every file path is absolute-from-repo-root.
**Route:** `audio-dsp-engineer` (cycle A), `qa-test-engineer` + `audio-dsp-engineer` (cycle B).
**Amends:** the "MIDI schedule" and "MIDI CC / pitch bend / channel pressure" SETTLED entries
in `docs/ARCHITECTURE.md` (exact replacement text in §11 — the implementer applies it, this
document does not).

---

## 0. The decision, in one paragraph

`MIDIEventSchedule.buildEvents` gains an appended, defaulted `chaseHeldNotes: Bool = false`.
When true, a note whose onset is behind the schedule anchor but which is **still sounding at
the anchor** emits its note-on clamped to the anchor beat and its note-off at its true time.
Which builds pass true is decided by **one law with one home**: a new
`RescheduleCause` enum (`.relocation` / `.continuation`) threaded — **without a default, so the
compiler enumerates every site** — through `AudioEngine.restart` / `AudioEngine.startPlayers`
into `PlaybackGraph.scheduleAll`, whose single call of `cause.chasesHeldNotes` is the only
place the mapping exists. **Chase iff the resume beat is the position playback would have
reached anyway.** Six sites are continuations and chase; four are relocations and do not; the
loop-cycle unroll blocks and the offline renderer keep today's behavior byte-identically.

---

## 1. What was measured, and what the filing got wrong

### 1.1 Confirmed (re-derived independently of the parent's probe)

`Sources/DAWEngine/MIDISchedule.swift:147`

```swift
guard onBeat >= fromBeat else { continue }                 // no chase v0
```

drops **both** events of any note whose onset precedes `fromBeat`. The contract at `:85` says so
in words. `Tests/DAWEngineTests/HeldNoteProbeTests.swift` (the parent's temporary probe, present
in the working tree) measures a 128-beat note built with `fromBeat: 4` yielding 0 events against
a positive control of 2 at `fromBeat: 0`.

### 1.2 The other half of the mechanism — why the note goes silent rather than sticking

The drop alone would only mean "no new note-on". The voice that was *already* sounding is killed
separately, and that is what makes the defect permanent:

- `AudioEngine.restart` (`Sources/DAWEngine/AudioEngine.swift:2820`) calls
  `graph.stopAllPlayers()`, which at `Sources/DAWEngine/PlaybackGraph.swift:3260-3263` does
  `renderer.publish(nil)` for every instrument node and then `flushAllInstruments()` →
  `requestFlush()` → `instrument.reset()` at the top of the next render quantum. Every sounding
  voice is cut.
- `rebuildEngine` (`AudioEngine.swift:967`) is stronger still: the whole `PlaybackGraph` and every
  `InstrumentRenderer` is discarded and rebuilt, so voices die with the objects.

So the seam is: **voices cut → new schedule built with the no-chase guard → nothing re-sounds.**
Silence is permanent for the remaining life of that note. That is m23-bp.

### 1.3 CORRECTION 1 — the device flip does not reach `recoverEngine`

The roadmap entry (`docs/ROADMAP.md:530`) blames `recoverEngine` (`AudioEngine.swift:3176`).
m20-e established the flip reaches the **announce-class reconcile** at `AudioEngine.swift:892-894`
→ `rebuildEngine(reason: "announce-class reconcile")`, whose resume is
`startPlayers(... renderClockTrusted: false)` at `AudioEngine.swift:1102`. Implementers must not
re-derive from the filing's causal claim. (`recoverEngine`'s own resume at `:3204` *is* also a
chase site — it is simply not the one the flip takes.)

### 1.4 CORRECTION 2 — `:837` is `setTempo`, not a seek

The parent's table lists `:824, :837` together as "seek / locate via `restart`". `:824` is
`seek(_:)`. **`:837` is `setTempo(_:)`** (`AudioEngine.swift:828-841`): it takes
`let beats = derivedBeats()` and restarts at that same position. Playback is uninterrupted and the
transport does not move. It is a **continuation** and it chases. Dragging the tempo while playing
is a routine action; today it silences every held note.

### 1.5 CORRECTION 3 — the urgency is far higher than "device flip"

`:911` is reachable from an ordinary MIDI edit during playback, and this is not an inference:

- `PlaybackGraph.reconcile` returns `changed` from four signature comparisons
  (`PlaybackGraph.swift:1129-1132`), one of which is `newInstrumentSignature`.
- `InstrumentTrackKey.clips` is built at `PlaybackGraph.swift:962-965` as
  `MIDIClipKey(id:startBeat:lengthBeats:notes:)` — **`notes` is part of the key.** The code comment
  at `:948` says it outright: *"Note edits change the signature (reschedule via restart)"*.
- The audio-track `ClipKey` (`PlaybackGraph.swift:37-56`) likewise carries `startBeat`,
  `lengthBeats`, `url`, `startOffsetSeconds`, both fades, both fade curves, the three stretch
  fields and the gain envelope — so a clip move, trim, fade drag or stretch edit flips `changed`
  too.

**Therefore: adding, moving, deleting or resizing a single note in the piano roll while the
transport is rolling — or moving/trimming any audio clip — cuts every sounding voice on every
instrument track and never re-sounds the held ones.** So does a loop-bounds drag (`:2052`, reached
from `ProjectStore.setLoop` and five other store sites), and so does a tempo drag (`:837`).
m23-bp is not a device-flip edge case; the device flip is the rarest of its triggers.

### 1.6 What this design does NOT fix — m23-bq

m23-bq (transport position freezing up to ~6.5 s after a flip) is the **stale render-clock class**
documented at `AudioEngine.swift:2840-2852` — a just-bounced engine reports the previous render
session's `lastRenderTime`, and `derivedBeats`' `max()` clamp freezes the playhead for the length
of the stale delta. It has nothing to do with schedule content, and note chase cannot move it.
A gate that plays a chased note and observes the playhead moving must **not** be read as closing
m23-bq. Keep the items separate in the close-out.

---

## 2. The law: relocation vs continuation

> **A (re)schedule CHASES held notes iff its `fromBeat` is the position playback would have
> reached anyway. It does NOT chase when the beat was chosen — by the user, by the loop, or by a
> bounce range.**

This is deliberately a property of the **call site**, not of the beat value, because it is then
decidable by reading one line and provable by the compiler. Two supporting observations:

- Every continuation site derives its beat from `derivedBeats()` or from the resume tuple
  captured by `willMutateRoutingTopology` / `rebuildEngine`, both of which are
  `derivedBeats()` (`AudioEngine.swift:578-579`, `:972`).
- Every relocation site takes its beat from the transport intent (`transport.positionBeats`),
  from the record position, or from `loopStartBeat`.

### 2.1 Site classification (complete; all 11 reschedule entries in the tree)

| # | Site | What | Beat source | Cause | Chase |
|---|---|---|---|---|---|
| 1 | `AudioEngine.swift:789` | `startPlayback` — user pressed play | `transport.positionBeats` | `.transportStart` (**m23-cd**; was `.relocation`) | **yes** |
| 2 | `AudioEngine.swift:824` | `seek` | `transport.positionBeats` | `.relocation` | no |
| 3 | `AudioEngine.swift:837` | **`setTempo`** — tempo change while rolling | `derivedBeats()` | `.continuation` | **yes** |
| 4 | `AudioEngine.swift:911` | structural reconcile change while rolling (note edits, clip moves/trims/fades/stretch) | `derivedBeats()` | `.continuation` | **yes** |
| 5 | `AudioEngine.swift:925` | `resumeAfterRoutingRewire` belt-and-braces resume | captured `derivedBeats()` | `.continuation` | **yes** |
| 6 | `AudioEngine.swift:1102` | `rebuildEngine` resume — **the device-flip path** | captured `derivedBeats()` | `.continuation` | **yes** |
| 7 | `AudioEngine.swift:2052` | `loopChanged` — loop-bounds edit / disable while rolling | `derivedBeats()` | `.continuation` | **yes** |
| 8 | `AudioEngine.swift:2594` | record start (with count-in) | `transport.positionBeats` | `.relocation` | no |
| 9 | `AudioEngine.swift:3122` | loop-wrap **fallback** restart | `loopStartBeat` | `.relocation` | no |
| 10 | `AudioEngine.swift:3204` | `recoverEngine` resume (also reached by `watchdogRestart`, `:3261`) | `beat(forElapsedSeconds:)` from the live anchor | `.continuation` | **yes** |
| 11 | `OfflineRenderer.swift:353` | bounce / stem render | caller's `fromBeat` | `.relocation` (default) | no |

Six continuations, four relocations inside `AudioEngine.swift`, plus the offline renderer which
takes the default and is never touched. **AMENDED BY m23-cd (2026-08-04): row 1 is now
`.transportStart` and CHASES — six continuations, ONE transport start, three relocations. See
§2.4.**

### 2.4 AMENDMENT — m23-cd (2026-08-04): the play button chases

**This section is authoritative over row 1 of §2.1 and over §2's law as written.** Everything else
in this document stands unchanged.

**What the user reported**, verbatim: *"if I pause and then resume the sound stops coming for the
current quarter and only comes back as it moves to another quarter... it only loses sound on track
'Atmospheric Pad' which has very long bars."* That is site 1 working exactly as §2.1 specified it.
Pause is `ProjectStore.stop()` → `AudioEngine.stopPlayback()`, which cuts every voice and leaves
`transport.positionBeats` at the stop beat; resume is `ProjectStore.play()` →
`AudioEngine.startPlayback()` at that same beat, whose `.relocation` build dropped both events of
anything sounding. The track was not special: the contract is global, and a pad holding whole-bar
notes is simply the only place where the gap to the next onset is long enough to hear. Drums hide
it completely.

**The ruling**, verbatim (2026-08-04): *"for 1st one lets do what other DAWs do"* — chase held
notes on resume, matching Logic/Ableton/Cubase. **The phantom-attack counter-case (a note already
decaying when the transport stopped re-attacks at full velocity on the next play) was put to the
user BEFORE they ruled and they ruled anyway. It is an accepted cost, not an oversight, and must
not be re-litigated as a defect.**

**Why a THIRD CASE and not `.continuation`.** The §2 law — *chase iff `fromBeat` is the position
playback would have reached anyway* — is FALSE of a transport start: the beat was chosen. Two
concrete costs of mislabelling it:

1. `StartAnchorPolicySiteTests`' header states "A RELOCATION fixes the beat, so any instant will
   do (`.asSoonAsPractical`); A CONTINUATION cannot". `startPlayback` must keep
   `.asSoonAsPractical` (its beat IS fixed). Calling it a continuation makes that header false
   with **no test able to see it** — the exact "prose far from the code" failure `NoteChaseSiteTests`
   was written to prevent.
2. `docs/ARCHITECTURE.md` (m23-bs-3b note) already records that `cause` and anchor policy
   "correlate at today's five call sites **by coincidence, not by law**", and names the pending
   **chase-yes-with-a-chosen-beat** case. This is that case, so it gets its own name.

**The amended law, in one line:** a build chases held notes iff playback is CONTINUING (`fromBeat`
reached by wall time) **or** the user just pressed PLAY. It does not chase when the beat was chosen
by a machine that must reproduce a fresh seek — a locate while rolling, a record start, a loop-wrap
jump, an offline bounce.

**Deliberately NOT moved, and each is a real user-visible boundary:**

- **Site 2, `seek` while rolling.** After m23-cd, stop → click the ruler → play CHASES (it goes
  through site 1), while clicking the ruler WHILE PLAYING does not. Same user, same pad, same
  symptom, different gesture. The ruling covered the play button; this one is the user's to make
  and should be offered, not assumed.
- **Site 8, record start.** Chasing would re-attack held playback notes into the monitor mix at the
  moment a take begins. Out of the ruling.
- **Site 9, the loop-wrap fallback.** §2.2's two reasons are unchanged and still binding: cycle
  determinism, and "a once-only re-attack is worse than uniform absence".
- **Site 11, the offline bounce.** m23-bv, a DIFFERENT SURFACE with its own measured audio/MIDI
  asymmetry (0.354 vs 0.0 at identical geometry), still awaiting its own ruling. m23-cd is strong
  evidence for the same answer there and should be attached when it is re-put — but it is not a
  ruling on it, and nothing in this cycle changed a single rendered byte offline.

**KNOWN CONSEQUENCE UNDER A LIVE LOOP, and the §2.2 tension it creates.** `.transportStart` goes
through the head-build path, which chases; the appended loop-cycle blocks do not (§3.4, unchanged).
So pressing play at bar 6 of a loop over bars 5–9, with a pad spanning bars 1–9, now sounds the pad
from bar 6 to the loop end and then leaves it silent on every subsequent wrap — a once-only
re-attack, which is exactly the outcome §2.2 argues AGAINST for the loop-wrap fallback ("a
once-only re-attack is worse than uniform absence"). Three things resolve the apparent
contradiction, and §2.4 is authoritative where they touch: (1) the shape is not new — it already
ships for `.continuation`, so any note edit while looping produces it today; (2) §2.2's argument is
about a build the machine performs on the user's behalf mid-flight, where uniformity is the whole
point, whereas m23-cd is about the user's own deliberate press of PLAY, which the ruling covers
unconditionally; (3) fixing it properly means making cycle blocks chase, which §2.2 rejects for
independent reasons (deterministic cycles, doubled attacks on the still-ringing head voice).
MEASURED, not assumed: `NoteChaseGraphTests` G-L2 reads the head build admitting a straddling pad
exactly once (`ons [60: [0]]`) while the in-loop marker fires once per cycle — that is the shape
`.transportStart` inherits verbatim, which is why no near-duplicate loop leg was written for it.

**Verification (m23-cd):** `Tests/DAWEngineTests/ResumeChaseTests.swift` renders the gesture itself
offline — play → PAUSE (`stopAllPlayers`, which flushes every voice) → silence → resume at the stop
beat — and reads the cause its chase arm uses out of `AudioEngine.swift` source, so a reverted site
reddens an AUDIBLE measurement rather than only a source pin. Measured 2026-08-04, 48 kHz/120 BPM,
one 64-beat pad note resumed at beat 2: **held-note RMS 0.0644 with `.transportStart` vs exactly
0.0 with `.relocation`**, with three controls in the same run (pre-pause audible in both arms at
0.0642; the pause window exactly 0.0 in both, so the sound after the resume cannot be a leftover
ring; a marker note whose onset is AFTER the resume beat audible in both arms). Round-tripped
through a real 388 096-byte wav and re-measured off disk at the same 0.0644.

### 2.2 Where I differ from the parent's provisional split

- **`:837` moves from LOCATE to CONTINUATION** (§1.4). This is a correction, not a preference.
- **`:3122` (the loop-wrap fallback) is a RELOCATION and must NOT chase** — the parent asked what
  it actually is. It is a genuine, reachable fallback, not dead code: it fires when a loop is
  enabled mid-play (the current schedule is linear) or when playback started at/past the loop end
  (`startPlayers` only builds a `loopWindow` when `beats < loopEndBeat`,
  `AudioEngine.swift:2866-2876`). The transport **jumps** from `>= loopEndBeat` back to
  `loopStartBeat`, so the beat is chosen, not reached. Two further reasons it must not chase:
  1. **Determinism of cycles.** The post-fallback state must be identical to "seek to loop start
     and play with the loop enabled", because every subsequent (gapless) cycle reproduces exactly
     that state. Chasing here would make the first wrap audibly different from every later wrap.
  2. **A once-only re-attack is worse than uniform absence.** A pad straddling the loop start is
     silent in every gapless cycle (cycle blocks do not chase — §3.4). Chasing at the fallback
     would re-attack it exactly once and never again.
- Everything else in the parent's table stands.

### 2.3 Known-limit note on site 6

`:1102` also serves the project-boundary rebuild (`projectWillReplace` → `needsEngineRebuild` →
`rebuildEngine`). If the transport were rolling across a project replacement, chase would read the
**new** project's clips — but so does the resume's own schedule build, so this introduces no new
failure mode. Filed here rather than special-cased.

One more reachable-while-recording note: `:911` fires from `tracksDidChange` during a take.
Chased notes are SCHEDULED PLAYBACK, not capture, so take content is unaffected — but the monitor
mix re-attacks held playback notes at the seam. Expected, not a defect; recorded here so a
reviewer does not meet it as a surprise.

---

## 3. Exact semantics of a chased note

### 3.1 The rule

For each note of each MIDI clip, with `onBeat = clip.startBeat + note.startBeat` and
`offBeat = clip.startBeat + min(note.endBeat, clip.lengthBeats)` (both unchanged):

1. `note.startBeat < clip.lengthBeats` — unchanged, first, before anything else.
2. If `onBeat >= fromBeat`: unchanged in every respect (this is the whole existing path).
3. If `onBeat < fromBeat`:
   - **not chasing** → `continue` (the v0 rule verbatim);
   - **chasing** and `offBeat <= fromBeat` → `continue` (the note had already ended — §3.2a);
   - **chasing** and `offBeat > fromBeat` → the note is **admitted with its onset clamped to
     `fromBeat` in the BEAT domain**.
4. The loop-window test `if let onsetEndBeat, onBeat >= onsetEndBeat { continue }` keeps reading
   the **original** `onBeat`, never the clamped value (§3.3).
5. Frames are computed by the existing absolute-integral expression with the clamped onset beat.
6. A chased note whose off frame is not strictly after its on frame is **dropped** rather than
   rescued by the defensive `max(on + 1, …)` clamp (§3.2b). Un-chased notes keep the clamp
   byte-identically.
7. Velocity, pitch and noteID allocation are unchanged. The chased note consumes exactly one
   noteID from the same running counter, in the same clip/note iteration order.

**Clamp in the beat domain, not the frame domain.** `onsetBeat = fromBeat` feeds the existing
`tempoMap.seconds(from: fromBeat, to: onsetBeat)`, which is exactly 0, so the on frame is
`Int64((offsetSeconds * sampleRate).rounded())` — *the same expression* as `anchorFrame` on
`MIDISchedule.swift:172`, which the controller chase prefix already uses. No new rounding path
exists, and the chased onset is correct by construction for a non-zero `offsetSeconds` even though
production never combines the two (§3.4). Frame-domain clamping (`max(0, on)`) would have been a
second, subtly different placement rule for the same concept.

**Do the `offBeat > fromBeat` test in the beat domain, before any `tempoMap.seconds` call.**
Resuming at beat 500 of a long song must not start paying map integrals for every note in the past.

### 3.2 The two drop cases, answered

**(a) A note whose off is also at or before `fromBeat` stays dropped.** The test is strict
(`offBeat > fromBeat`), so a note ending *exactly* at the resume beat is dropped — which is the
musically correct answer: it had finished.

**(b) The sliver case is new, and is answered by dropping, not by the existing clamp.** Because
`fromBeat` can land anywhere inside a note, a chased note can have an arbitrarily small remaining
tail — including one that rounds to zero frames. Today that class cannot occur
(`MIDINote.minLengthBeats` at the 400 BPM cap is >= 7 frames at 48 kHz, which is what the `:82-84`
comment means), so the `max(on + 1, …)` clamp is pure defense. With chase it becomes reachable,
and if the clamp were left to handle it the build would emit a 1-frame note-on/note-off pair —
an attack transient with no note behind it, i.e. a click. So: **chased notes require
`offRaw > on`; otherwise they are dropped.** This is a frame-domain test, deterministic, with no
magic constant.

*Rejected: a millisecond/`chaseMinTailFrames` threshold.* Any value is arbitrary, it would have to
be justified per instrument (a pad and a drum sample disagree), and the probability of landing
inside the last few milliseconds of a note is ~0.25% for a 4-beat note at 120 BPM. If a sliver
click is ever measured as a real complaint, adding a threshold is additive and local. Filed as a
known limit, not hidden.

### 3.3 Interaction with `onsetEndBeat` (the loop window)

**Head build under a live loop.** `startPlayers` only constructs a `loopWindow` when
`beats < loopEndBeat` (`AudioEngine.swift:2866-2867`), so in any windowed head build
`fromBeat < onsetEndBeat`. A chased note has `onBeat < fromBeat < onsetEndBeat`, so the window test
on the **original** onset admits it unconditionally. Reading the *clamped* onset would also pass,
but only accidentally; pinning the original is what makes the rule stable if the window ever moves.

**The chased note's off may land past `onsetEndBeat`.** That is already the documented straddle
behavior — `MIDISchedule.swift:96-97`: *"a note's OFF may land past it (tails ring through the
seam)"*. A chased pad therefore rings from the resume point to its natural end, possibly across
several loop cycles, and is not re-attacked per cycle. That is exactly what a note starting inside
the loop and extending past its end already does, so the loop path gains no new shape.

**Prune interaction (§8.6 containment).** A chased on sits at the earliest frame of the head build
(`anchorFrame`), so `mergeSorted` places it below everything appended by `extendLoopMIDI` — the
C2 append-only law is untouched. When the retained window later advances past it, the on is pruned
while its off (at a much later frame) survives; the render side re-seeks **by value**, so a
delivered-then-pruned on is invisible to it. Same as any other delivered on: no new hazard.

### 3.4 Loop-cycle blocks must NOT chase — and get that for free

`extendLoopMIDI` (`PlaybackGraph.swift:2892-2899`) builds each cycle with
`fromBeat: state.loop.startBeat`. It **must keep the default `chaseHeldNotes: false`**, and the
implementer must not "improve" it:

- The design law it serves is that every cycle block reproduces the state a fresh
  seek-to-loop-start would produce (`MIDISchedule.swift:118-122`; the §8.6 prune self-containment
  argument depends on it).
- A seek to loop start is a **relocation**. Chasing there would re-attack every note straddling
  the loop start on **every** cycle, on top of the head build's still-ringing voice — a doubled,
  repeating attack.

So the head build may chase; cycle blocks never do. Because `scheduleAll` maps the cause and
`extendLoopMIDI` does not, this falls out of the defaulted parameter with no extra logic — but it
must be pinned by a test (§9, G-L2), because it is the one place where "just thread it everywhere"
silently produces a musical disaster.

### 3.5 The sort key and the off-before-on tie rule still hold

Rank is `off(0) < cc/bend/pressure(1) < on(2)`, then pitch, then noteID
(`MIDISchedule.swift:279-295`). Chased notes are ordinary note-ons at rank 2. Checks:

- **Nothing can collide destructively at `anchorFrame`.** Within one build every note-off is at
  `>= on + 1`, and every on is at `>= anchorFrame`, so no off can share `anchorFrame` with an on
  from the same build. The tie rule that matters — back-to-back same-pitch notes delivering
  `off(A)` before `on(B)` at a shared frame — is untouched, because chase moves a note's **on**
  only, never its off.
- **The controller chase prefix still lands before every chased note-on** (rank 1 < rank 2 at the
  shared `anchorFrame`), so a chased sustain pedal, bend or CC is in effect before a chased note
  re-attacks. This is the behavior the m16-b design already asked for; chase inherits it for free.
- **Chased ons among themselves** are totally ordered by (pitch, noteID) at the shared frame.
  Deterministic given the clips array.
- **A chased note and a fresh note of the same pitch starting exactly at `fromBeat`** both sound,
  as two voices with distinct noteIDs. This is the model's own "same-pitch overlaps are legal"
  rule, and every built-in instrument pairs offs by noteID
  (`PolySynthInstrument.swift:373`, `SamplerInstrument.swift:731`, `TestToneInstrument.swift:121`),
  so both close correctly. Accepted, documented, not special-cased.

### 3.6 Should note chase follow the controller-lane chase's shape?

Read `MIDISchedule.swift:167-225`. Where the shapes **can** agree, they should, and do:

- inject at `anchorFrame`, computed by the identical expression;
- rank ordering as above;
- IDs from the same running counter, canonical order for determinism.

Where they **cannot** agree, and why the difference is intrinsic rather than sloppy:

| Controller chase | Note chase |
|---|---|
| Collapses to **one** value per lane type ("latest point below `fromBeat`") | Must admit **every** note sounding at the anchor — polyphony is not a step function; a "latest note wins" collapse would silence a chord |
| Emits a **point** event | Emits a **pair** (on at the anchor, off at its true frame) |
| Always injected, in every block including cycle blocks | Injected only in continuation head builds (§3.4) |
| Reads a step function, so it is exact | **Re-attacks**, so it is an approximation (§4) |

The last row is the m16-b sentence *"a chased note is a musical lie, a chased controller is just
reading the step function"* — which stays true. m23-bp's claim is narrower: at a **continuation**
seam the alternative to the small lie is permanent silence, which is a bigger one.

---

## 4. The audible trade-off, and every cheaper option

A chased note **re-attacks**: a slow-attack pad restarts its envelope instead of continuing, and a
sampler restarts the sample from frame 0. Better than permanent silence; not free; not the same as
true continuation. Stated plainly here so it is never implicit.

**Option C — true voice continuation (preserve DSP voice state across the reschedule). REJECTED,
permanently.** It requires exporting and re-importing per-voice envelope/oscillator/sample-position
state across a schedule swap. For `:1102` (the reported bug) the renderer objects themselves are
discarded, so there is nothing to preserve. For hosted AUs there is no public voice-state surface
at all. It is out of scope now and out of reach later.

**Option C' — keep the `timelineID` stable across a continuation restart so the render side
re-seeks instead of resetting (the m14-b gapless mechanism). REJECTED.** The re-seek is only valid
against an **unchanged anchor**: `MIDISchedule.swift:43-51` and
`InstrumentSourceNode.swift:445-465` both make the identical-anchor assumption explicit. Every
restart mints a fresh `startLeadSeconds` anchor, and a device flip genuinely changes the render
session. Re-seeking against a moved anchor mis-places every pending event.

**Option D — skip the flush at non-bounce continuity sites and emit ONLY the note-OFF for
straddling notes (no re-attack at all). REJECTED, but it is the one option that would have avoided
re-attack, so here is exactly why it loses:**

1. It cannot fix the reported bug. `:1102` rebuilds the graph; the renderers holding the voices are
   gone before any schedule is published.
2. **Note-offs pair by `noteID`, and the IDs are re-minted per build.** All three built-in
   instruments match `voices[index].noteID == event.noteID`. The old voice's ID came from the old
   build's counter; the new build starts from `noteIDBase` (0 for a head build). An off with a
   fresh ID matches nothing, so the voice **sticks forever** — strictly worse than silence.
   Carrying old IDs forward would require the main actor to know what the render thread had
   actually *delivered*, and `deliveredThrough` is render-side state by design.
3. Hosted AUs receive offs as MIDI bytes keyed by pitch, so the ID scheme diverges between
   built-ins and hosts — one more way for the two halves to disagree silently.

Chase computes the same information from the **model**, on the main actor, with no render-side
state export and no ID continuity requirement, and it covers the rebuild case. It wins on every
axis except re-attack.

**Conclusion: there is no cheaper option that avoids re-attack. Re-attack is the price, and it is
worth paying.**

---

## 5. Real-time safety

- `buildEvents` runs **only** from `PlaybackGraph.scheduleAll` (`:2561`) and
  `extendLoopMIDI` (`:2892`), both `@MainActor` schedule-time paths. `scheduleAll`'s own comment
  (`PlaybackGraph.swift:2546-2548`) states it: *"Pure math on the main actor — microseconds, never
  render-thread work."* Confirmed.
- The change adds **zero** render-thread work: no new event kind, no new branch in
  `renderQuantum`, no change to the cursor, the slice loop, the watermark or `lowerBound`.
- Event-count growth is bounded by the number of notes sounding at the anchor (i.e. by polyphony),
  ×2 events. Allocation happens in the same existing main-actor `events` array and the same
  `MIDIEventSchedule.init` copy.
- The publish/flush ordering is safe by the existing anchor lead: `stopAllPlayers` sets the flush
  flag, `startPlayers` publishes the new schedule with an anchor `startLeadSeconds` (>= 60 ms) in
  the future, and the render side consumes the flush at the **top** of a quantum before processing
  any events. Even in the pathological case where one quantum sees both the flush and the new
  schedule, `reset()` runs first and the chased on is still in the future
  (`renderStart` is negative during the lead-in). No new race.

---

## 6. Blast radius — every caller, enumerated

### 6.1 `MIDIEventSchedule.buildEvents` — 2 production callers, 35 test call sites

(35 MEASURED with `grep -rc 'MIDIEventSchedule.buildEvents(' Tests/DAWEngineTests/*.swift`:
MIDIControllerScheduleTests 17, MIDISchedulerTests 8, GaplessLoopMIDITests 4,
TempoMapPhaseBTests 2, TempoMapPhaseCEngineTests 2, HeldNoteProbeTests 2.)

The m14-b convention holds: **append the new parameter LAST** (after `noteIDBase`), defaulted, so
every existing labelled call remains valid and bit-identical (`false` reproduces today's control
flow exactly — see §7 step 1 for why the restructured loop is output-identical).

Production:
- `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/PlaybackGraph.swift:2561` — head build. **Gains
  `chaseHeldNotes: cause.chasesHeldNotes`.** The only behavior change in the tree.
- `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/PlaybackGraph.swift:2892` — `extendLoopMIDI`
  cycle block. **Must stay on the default** (§3.4). Add a one-line comment saying why, so a future
  reader does not "fix" the inconsistency.

Tests (all keep the default; none should need editing):
- `Tests/DAWEngineTests/MIDISchedulerTests.swift:24, 40, 59, 67, 73, 84, 106, 123`
- `Tests/DAWEngineTests/MIDIControllerScheduleTests.swift:122, 152, 175, 197, 217, 247, 249, 271,
  273, 280, 313, 318, 353, 368, 395, 470, 481`
- `Tests/DAWEngineTests/GaplessLoopMIDITests.swift:473, 476, 496, 499`
- `Tests/DAWEngineTests/TempoMapPhaseBTests.swift:36, 66`
- `Tests/DAWEngineTests/TempoMapPhaseCEngineTests.swift:33, 64`
- `Tests/DAWEngineTests/HeldNoteProbeTests.swift:22, 26` — **the parent's temporary probe. Delete
  this file** as part of the cycle; its content is superseded by G2/G3 in §9.

**The load-bearing regression anchor: `Tests/DAWEngineTests/MIDIControllerScheduleTests.swift:58`**
holds a *verbatim frozen copy* of the pre-m16-b2 note-only builder, compared byte-for-byte against
the live one (condition C1b). **Do not touch it.** It is the strongest available proof that the
default path did not move, and it must stay green without modification. If it goes red, the
restructuring in §7 step 1 changed output — revert and re-derive, do not update the frozen copy.

Non-callers that merely *reference* the contract in prose and must have their comments checked for
staleness (no code change):
- `Sources/DAWEngine/Automation/AutomationSchedule.swift:127`
- `Sources/DAWAppKit/PianoRollModel.swift:215`
- `Tests/DAWEngineTests/PolySynthTests.swift:54`

### 6.2 `PlaybackGraph.scheduleAll` — 2 production callers, 29 test call sites

Append `cause: RescheduleCause = .relocation` LAST (after `loop:`). Every one of the 31 call sites
stays valid; the 29 test sites and `OfflineRenderer.swift:353` keep today's behavior by the default.

- `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/AudioEngine.swift:2877` — passes the cause
  `startPlayers` received.
- `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/OfflineRenderer.swift:353` — **unchanged, takes
  the default.** A bounce is a relocation. This also protects the offline SHA byte-identity gates
  (`StemNullTests`, `DeliveryFormatRenderTests`, the C8 renders), which must not move.

### 6.3 `AudioEngine.restart` / `AudioEngine.startPlayers` — the compiler becomes the enumeration

Both gain `cause: RescheduleCause` **with NO default**, appended last. This is deliberate and is
the answer to "did I miss a call site": adding a future reschedule path will not compile until its
author states the cause. The parameter is on private methods, so this is an internal-only signature
change — no live command semantics move, no wire surface changes, no MCP tool changes, and
`allCommands` / MCP / catalog counts are unchanged by this cycle.

### 6.4 Nothing else

No DAWCore change. No DAWControl change. No `mcp-server/` change. No `ProjectStore` change. No
model/persistence change. No new wire command (see §12 for why a debug seam was considered and
deferred).

---

## 7. Implementation plan

### Step 1 — `Sources/DAWEngine/MIDISchedule.swift`

Append the parameter and restructure the per-note guard. Target shape:

```swift
static func buildEvents(clips: [Clip], fromBeat: Double, tempoMap: TempoMap,
                        sampleRate: Double,
                        onsetEndBeat: Double? = nil,
                        offsetSeconds: Double = 0,
                        noteIDBase: UInt64 = 0,
                        chaseHeldNotes: Bool = false)
    -> (events: [ScheduledMIDIEvent], nextNoteID: UInt64) {
```

and inside the note loop:

```swift
for note in clip.notes ?? [] {
    guard note.startBeat < clip.lengthBeats else { continue }  // [0, clipLen)
    let onBeat = clip.startBeat + note.startBeat
    let offBeat = clip.startBeat + min(note.endBeat, clip.lengthBeats)
    // m23-bp. NOT chasing is the v0 rule verbatim: an onset behind the
    // anchor drops BOTH events. Chasing (continuation resumes only) admits
    // a note that is still SOUNDING at the anchor and clamps its onset to
    // `fromBeat` — the BEAT domain, so the frame lands on the block's own
    // anchorFrame by the same expression the controller chase prefix uses.
    var onsetBeat = onBeat
    let chased = onBeat < fromBeat
    if chased {
        guard chaseHeldNotes, offBeat > fromBeat else { continue }
        onsetBeat = fromBeat
    }
    // The loop window reads the ORIGINAL onset: a chased note's true onset
    // is < fromBeat <= onsetEndBeat, so it is never windowed out here.
    if let onsetEndBeat, onBeat >= onsetEndBeat { continue }
    let on = Int64(((offsetSeconds
        + tempoMap.seconds(from: fromBeat, to: onsetBeat)) * sampleRate).rounded())
    let offRaw = Int64(((offsetSeconds
        + tempoMap.seconds(from: fromBeat, to: offBeat)) * sampleRate).rounded())
    // A chased note with no whole frame of tail left is DROPPED, never
    // rescued by the defensive clamp below: a 1-frame re-attack is a click,
    // not a note. Un-chased notes keep the clamp byte-identically.
    if chased, offRaw <= on { continue }
    let off = max(on + 1, offRaw)
    // …unchanged from here (id, pitch, the two appends)…
}
```

Output-identity argument for `chaseHeldNotes == false` (this is what C1b will verify):
`offBeat` is hoisted above the guards, which is pure `Double` arithmetic with no side effects and
no new `tempoMap` call for dropped notes; `chased` is exactly the old `!(onBeat >= fromBeat)`, and
with `chaseHeldNotes == false` the `guard` fails identically; `on`/`off` reduce to the previous
expressions because `onsetBeat == onBeat`; the `chased, offRaw <= on` test is unreachable. Same
events, same order, same IDs.

Also rewrite the contract bullet at `:85-86`. Replacement text:

```
///  · NOTE CHASE (m23-bp): OFF BY DEFAULT — the onset must also be >= fromBeat,
///    else BOTH events are dropped (a note sounding across the start point does
///    not sound). `chaseHeldNotes: true` — passed ONLY by a CONTINUATION
///    reschedule (RescheduleCause; never a relocation, never a loop-cycle block)
///    — instead admits a note whose onset is behind the anchor while its off is
///    strictly ahead of it, with the ONSET CLAMPED to fromBeat (so its frame is
///    the block's anchorFrame) and the off at its true time. The note RE-ATTACKS;
///    true voice continuation is out of reach (design-m23bp §4). A chased note
///    with no whole frame of tail left is dropped rather than clamped to 1 frame.
```

### Step 2 — new file `Sources/DAWEngine/RescheduleCause.swift`

The ONE home for the mapping (registry law — one definition, no second computation):

```swift
/// WHY a (re)schedule is happening — THE discriminator for note chase (m23-bp).
///
/// `.continuation`: `fromBeat` is the position playback would have reached
/// anyway (derivedBeats / a captured resume tuple). Playback was never stopped
/// from the user's point of view, so a held note going permanently silent is a
/// defect, not a policy.
/// `.relocation`: the beat was CHOSEN — a transport start, a seek, a record
/// start, a loop-wrap jump, a bounce range. The v0 no-chase rule stands.
enum RescheduleCause {
    case relocation
    case continuation

    /// THE mapping. It exists exactly once in the tree; every consumer reads
    /// this property rather than switching on the case itself.
    var chasesHeldNotes: Bool { self == .continuation }
}
```

### Step 3 — `Sources/DAWEngine/PlaybackGraph.swift`

- `func scheduleAll(fromBeat:tempoMap:loop:cause: RescheduleCause = .relocation)`.
- At `:2561`, pass `chaseHeldNotes: cause.chasesHeldNotes`. **This is the only call of
  `chasesHeldNotes` in the tree.**
- At `:2892` (`extendLoopMIDI`), add a comment: cycle blocks NEVER chase — each block must
  reproduce a fresh seek-to-loop-start (the §8.6 self-containment law), and chasing would
  re-attack straddling notes on every cycle on top of the still-ringing head voice.

### Step 4 — `Sources/DAWEngine/AudioEngine.swift`

- `private func restart(fromBeat:tempoMap:cause: RescheduleCause)` — no default; forwards to
  `startPlayers`.
- `private func startPlayers(fromBeat:tempoMap:countInBars:renderClockTrusted:cause: RescheduleCause)`
  — no default; forwards to `graph.scheduleAll(..., cause: cause)` at `:2877`.
- Apply the ten causes from the §2.1 table. Each call site gets a short trailing comment naming the
  reason (`// continuation: the tempo changed, the position did not`).

### Step 5 — docs

- `docs/ARCHITECTURE.md`: apply §11 of this document.
- `docs/ROADMAP.md`: tick m23-bp with the close record; keep m23-bq and m23-br OPEN and say in the
  record that this cycle does not touch them (§1.6).
- `CHANGELOG.md`: user-facing line — "held notes now keep sounding across tempo changes, edits
  during playback, loop-bounds edits and audio-device changes (they re-attack rather than
  continuing; a seek or a fresh play still does not sound a note you started inside)".

### Step 6 — delete `Tests/DAWEngineTests/HeldNoteProbeTests.swift`

Temporary orchestrator probe; superseded by G2/G3.

---

## 8. Failure modes to design against (the checklist a reviewer should run)

| # | Failure | Guard |
|---|---|---|
| F1 | Chase leaks into loop-cycle blocks → every cycle re-attacks straddling notes on top of the ringing head voice | `extendLoopMIDI` keeps the default; pinned by G-L2 |
| F2 | Chase leaks into relocation sites → pressing play sounds notes you started inside (a v0 policy reversal nobody asked for) | required `cause` parameter + the §9 source pin |
| F3 | A site is silently mis-wired (or two sites swapped) → the fix does nothing, or fires where it must not, while every headless test stays green | §9 layer 3(a) **ordered-sequence** pin (a count pin cannot see a swap) + the 3(c) mutants; **this is the likeliest way this cycle fails** |
| F4 | Sliver re-attack click | `chased, offRaw <= on` drop (G4) |
| F5 | Off-before-on tie broken at the anchor frame | chase moves only the ON; G5/G6 |
| F6 | Controller chase prefix lands after the chased note-on | rank 1 < rank 2, unchanged; G7 |
| F7 | Offline renders move → SHA gates red | `OfflineRenderer` takes the default; C1b + the stem/delivery SHA suites re-run |
| F8 | noteID double-booking across appended cycle blocks | chase consumes IDs from the same counter and `scheduleAll` still stages `build.nextNoteID`; G9 + the existing C5 suites |
| F9 | Someone "fixes" the C1b frozen copy to make it pass | §6.1 warning; the frozen copy is the oracle, not the subject |
| F10 | The cycle is reported as closing m23-bq | §1.6 |

---

## 9. Test strategy

Three layers. **Only layer 3 can catch F3**, which is the failure this cycle is most likely to
have. Every layer runs RED first: write the assertion, watch it fail against the unmodified tree
(layers 1–2) or against a mutated cause (layer 3), then make it pass. An unmutated green here is
worth very little — the m20-d lesson applies directly.

Run with `./scripts/test.sh` (never bare `swift test`), **backgrounded** for a full run
(~90 s), and grep the output for `^✘` — the script exits 0 on a failed run.

### Layer 1 — pure build math. New file `Tests/DAWEngineTests/NoteChaseScheduleTests.swift`

48 kHz, 120 BPM ⇒ 1 beat = 24 000 frames. Frame values are EXACT (`==`), per house style.

- **G1 (null case).** For a corpus of clips, `buildEvents(...)` and
  `buildEvents(..., chaseHeldNotes: false)` produce identical arrays, and the existing
  `fromBeatSuppressesEarlierOnsets` expectations still hold verbatim.
- **G2 (the fix).** clip `[0, 128)`, one note p60 v100 `[0, 128)`, `fromBeat: 4`,
  `chaseHeldNotes: true` → exactly 2 events; `on.sampleTime == 0`, `kind == 0`, `pitch == 60`,
  `velocity == 100`; `off.sampleTime == 2_976_000` (124 beats), `kind == 1`; shared noteID.
  Same call with chase off → 0 events (the arm the parent measured).
- **G3 (already ended).** clip `[0, 8)`, note `[0, 4)`, `fromBeat: 4`, chase on → 0 events
  (boundary equality drops). Note `[0, 4.5)` → 2 events (positive twin).
- **G4 (sliver).** clip `[0, 8)`, note `[0, 4 + 1e-6)`, `fromBeat: 4`, chase on → 0 events
  (`offRaw` rounds to 0). Note `[0, 4 + 1e-4)` → 2 events with `off.sampleTime == 2`
  (0.0001 × 0.5 × 48 000 = 2.4 → 2), proving the drop is the rounding rule and not a blanket
  short-note ban.
- **G5 (same-pitch coexistence).** chased p60 `[0, 128)` + fresh p60 at exactly beat 4 → 4 events,
  both ons at frame 0, distinct noteIDs, ons ordered by noteID, each off pairing its own on.
- **G6 (tie rule).** A chased note whose off lands exactly on a later same-pitch note's on frame →
  the off precedes the on in array order.
- **G7 (controller order).** Add a CC lane with a point below `fromBeat`; chase on → the CC event
  is at index 0 (frame 0, rank 1) and the chased note-on follows at the same frame.
- **G8 (loop window).** `onsetEndBeat` set above `fromBeat`, chase on → the chased note is admitted
  and its off is allowed past `onsetEndBeat`.
- **G9 (anchor identity).** `offsetSeconds: 1.0`, chase on → the chased on is at exactly
  `48_000` — the same value `anchorFrame` computes. (Production never combines these; the test
  pins the expression, not a shipping path.)
- **G10 (C1b).** `Tests/DAWEngineTests/MIDIControllerScheduleTests.swift` runs unmodified and green.

### Layer 2 — graph level, offline. New file `Tests/DAWEngineTests/NoteChaseGraphTests.swift`

Use the `L2GraphRig` idiom from `Tests/DAWEngineTests/GaplessLoopMIDITests.swift:46-80` (manual
rendering `AVAudioEngine` + the real `PlaybackGraph`).

- **G-L1 (audibility, both arms in one test so a broken rig cannot pass as a finding).** A real
  `PolySynthInstrument` track, one 64-beat note from beat 0.
  `scheduleAll(fromBeat: 8, cause: .continuation)` → `startAllPlayers(at: nil)` → render ~0.5 s →
  RMS above a clear threshold. The `.relocation` control on the identical rig renders silence
  (RMS ≈ 0). Assert both.
- **G-L2 (cycle blocks stay unchased) — the F1 guard.** A track whose note starts before the loop
  start and rings through it; `scheduleAll(fromBeat:cause: .continuation, loop:)` then
  `topUpLoopCycles` for >= 3 cycles. Assert the head build contains exactly ONE on for that note
  (at frame 0) and that no appended cycle block adds another. Compare the appended blocks'
  event count against the same run with `.relocation` — **the appended blocks must be identical**.
- **G-L3 (offline unmoved).** Re-run the existing offline SHA suites (`StemNullTests`,
  `DeliveryFormatRenderTests`, the GaplessLoopMIDITests C8 render). No new test; a required
  green.

### Layer 3 — site level. New file `Tests/DAWEngineTests/NoteChaseSiteTests.swift`

**(a) Source pin — assert the ORDERED SEQUENCE, never the counts (always runs, no hardware).**
Read `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/AudioEngine.swift`, scan for
`cause: .relocation` / `cause: .continuation` **in file order**, and compare the resulting array
against this exact sequence:

```
[.relocation,    // :789  startPlayback
 .relocation,    // :824  seek
 .continuation,  // :837  setTempo
 .continuation,  // :911  reconcile structural change during playback
 .continuation,  // :925  routing-rewire resume
 .continuation,  // :1102 rebuildEngine resume  (the device-flip path)
 .continuation,  // :2052 loopChanged — bounds edit / disable
 .relocation,    // :2594 record start
 .relocation,    // :3122 loop-wrap fallback
 .continuation]  // :3204 recoverEngine
```

**A COUNT PIN IS NOT SUFFICIENT AND MUST NOT BE SUBSTITUTED.** Swapping `:824` (seek) to
`.continuation` and `:837` (setTempo) to `.relocation` leaves the totals at 6/4 — the pin would
pass, the bug would ship, and every headless test would stay green. Those two sites are precisely
the pair the original filing conflated (§1.4), so this is the likeliest single mistake in the
cycle. The ordered sequence is strictly stronger at the same cost and it makes the 3(c) mutants
meaningful for every site rather than only for additions and removals.

This is the house "compile-enforced + source-pinned" idiom (the Canvas `@Sendable` law uses it).
Two notes for the implementer: the pattern must match only the CALL SITES — the enum declaration
lives in a different file (`RescheduleCause.swift`), and the trailing per-site comments specified
in §7 step 4 are prose (`// continuation: the tempo changed, the position did not`), so they
cannot collide with a `cause: .` match. Put the §2.1 table in the test's doc comment.

**(b) Live-smoke site legs (the `liveSmoke` idiom — `try engine.prepare()` inside a `do/catch`
that `return`s with a labeled gap on a machine with no output device).** Template:
`Tests/DAWEngineTests/EngineWatchdogTests.swift:296-343` already does exactly this shape with an
instrument track and a 64-beat held note.

For each leg: start playback of a 64-beat held note on an **instrument track with a built-in
instrument** (`.testTone` or PolySynth), let it roll ~250 ms, trigger the site, then read
`engine.graph.instrumentRenderer(forTrack:)?.currentSchedule` (`graph` is `private(set) var`, so
`@testable` reaches it; `currentSchedule` is the documented main-actor borrow seam) and assert a
`kind == 0` event at `sampleTime == 0` with the held note's pitch and velocity. Negative control
per leg: the same run with a note that has already ENDED → no such event.

| Leg | Trigger | Site |
|---|---|---|
| S1 | `engine.setTempo(transport)` with a changed BPM | `:837` |
| S2 | `engine.tracksDidChange(tracks)` with one note edited | `:911` |
| S3 | `engine.loopChanged(transport)` after a bounds change | `:2052` |
| S4 | `try engine.watchdogRestart()` | `:3204` |
| S5 | an announce-class change while rolling (bus add / `projectWillReplace()` + `tracksDidChange`) | `:1102` |

**(c) Mutants (record the numbers in the close-out).** For each of S1–S5 and the source pin, flip
that one site to `.relocation` and confirm the leg reddens; revert and confirm the suite returns
byte-identically green. A leg that stays green under its own mutant is not a leg.

### Layer 4 — live gate (cycle B; see §10)

**A RED-BASELINE GATE ALREADY EXISTS IN THE WORKING TREE — ADOPT IT, DO NOT WRITE A SECOND ONE.**
`/Users/dsemenov/Views/daw-pro/scripts/gates/m23bp-held-note.mjs` (434 lines, untracked) already
reproduces the defect live against a **structural change during rolling playback** — i.e. site
`:911`, which §1.5 identifies as the most common trigger, not the device flip. Its header states
that it is EXPECTED RED on the current tree and that its redness IS the reproduction; it carries a
positive-control leg (`A2 LEG 2` — the note is audible BEFORE the change), the
EXPECTED-RED leg (`A2 LEG 2/3` — the note must still be audible after), and the
system-default-unmoved safety leg inherited from the m20-j discipline. That is an independent live
confirmation of §1.5, and it is the gate cycle A should be graded against.

Required of cycle B, therefore:
1. Run `m23bp-held-note.mjs` **before** the fix and record the red legs verbatim (the RED baseline
   already exists by construction — do not skip recording it).
2. Run it after the fix. **Every leg must be green**, and the "EXPECTED RED" labels in its header
   must be updated to reflect that the fix landed — its own header forbids waving a leftover red
   leg through as "expected".
3. Add the **device-flip** fixture, which that gate does not cover, either as a second scenario in
   the same file or as a sustained-note fixture inside the existing
   `scripts/gates/m20e-flip-path.mjs`. Shape: one instrument track, ONE 64-beat note, start
   playback, flip the output device, poll master metering for sustained energy after the flip.

Mandatory constraints for whoever writes it:
- **Staging port 17695 only. Port 17600 is the user's live app and is never touched.**
- **Use a BUILT-IN instrument, never a hosted AU.** A fresh `rebuildEngine` re-pulls instruments
  through `auRegistry.preparedInstrument(forTrack:)`; a not-yet-prepared AU eats the chased
  note-on and the gate goes red for a reason that has nothing to do with chase (that is m23-at /
  m23-av / m23-br territory). Say so in the gate's header.
- **RED baseline first**: run it against the pre-fix behavior (or with site 6 mutated to
  `.relocation`) and record the red counts before recording the green ones.
- `clip.addMIDI` takes `atBeat` and **rejects** `startBeat`; `project.new` takes only
  `discardChanges`.

---

## 10. Scope call — two cycles, and the line between them

**The semantics are one cycle; re-verifying every continuation site live is another.** Confirming
the parent's own phrasing.

**Cycle A — m23-bp-1, "chase semantics + wiring"** (`audio-dsp-engineer`)
Steps 1–6 of §7; layers 1, 2 and 3(a) of §9; the F3 mutant on the source pin. Deliverable: the
default path is provably unmoved (C1b + offline SHAs), the chase semantics are pinned frame-exact,
and the site table is source-pinned. This is a comfortable single cycle.

**Cycle B — m23-bp-2, "live site verification"** (`qa-test-engineer`, reviewed by
`audio-dsp-engineer`)
Layer 3(b)+(c) and layer 4 — **starting from the existing `scripts/gates/m23bp-held-note.mjs`,
whose current redness is the RED baseline this cycle must turn green.** This is a separate cycle
because each leg needs a real output device,
each needs its own mutant run, and S5/the device flip additionally need a second output device
(BlackHole 2ch is live on this machine; resolve it by **UID**, never by device ID). Splitting also
keeps cycle A from being blocked by hardware availability.

**Do not merge them.** If cycle A ships alone, the roadmap entry stays OPEN with the layer-3(b)
gap named explicitly — a fix whose wiring is only source-pinned is a fix whose wiring is only
source-pinned, and saying so is cheaper than discovering it later.

**Explicitly out of scope, filed rather than hidden:**
- **m23-bq** (§1.6) — different root cause, not touched.
- **Partial-range offline bounces.** `OfflineRenderer.swift:353` renders a range with no chase, so
  bouncing `[8, 16)` of a pad that starts at beat 4 silently omits the pad. That is *consistent*
  with the relocation rule and with what you hear when you locate to beat 8 and press play, and
  changing it would move the offline SHA gates. Worth filing as its own item ("should a partial
  bounce chase?") — it is a policy question with a user, not a defect.
- **A user-facing "chase MIDI notes" preference at relocation sites.** Logic and Live both offer
  one. With `RescheduleCause` in place it becomes a one-line change at sites 1/2/8 plus the usual
  control-command + MCP-tool + test triple. **This is the main argument for the enum over a bare
  `Bool`**: the bool would have to be re-derived at each site, and the "one home" mapping would
  have nowhere to live.

---

## 11. `docs/ARCHITECTURE.md` edits (apply at close-out, verbatim)

This design **amends a SETTLED law**. A design that silently contradicts one is worse than one
that rewrites it, so the exact text is given here.

### 11.1 `docs/ARCHITECTURE.md:309` — the MIDI-schedule SETTLED entry

Find: `SETTLED entry below; per-note channel and note chase remain additive).`
Replace with:

```
  SETTLED entry below; NOTE CHASE landed in m23-bp as a per-build opt-in — see the
  note-chase SETTLED entry under "Key future decisions"; per-note channel remains additive).
```

### 11.2 `docs/ARCHITECTURE.md:314` — the MIDI CC SETTLED entry

Find: `notes stay NO-chase — a chased note is a musical lie, a chased controller is just reading the step function)`
Replace with:

```
notes stay NO-chase at every RELOCATION build AND in every loop-cycle block — a chased note is a
musical lie, a chased controller is just reading the step function; m23-bp added the single
exception, a CONTINUATION resume, where the alternative to the small lie is permanent silence)
```

### 11.3 New entry under "Key future decisions" (`docs/ARCHITECTURE.md:163`)

```
- **Note chase: SETTLED (m23-bp, <close date>).** A schedule build CHASES held notes iff its
`fromBeat` is the position playback would have reached anyway. The discriminator is a call-site
property, `RescheduleCause` (`Sources/DAWEngine/RescheduleCause.swift`), threaded WITHOUT A DEFAULT
through `AudioEngine.restart`/`startPlayers` — so the compiler, not a comment, enumerates the
sites — into `PlaybackGraph.scheduleAll`, whose single read of `cause.chasesHeldNotes` is the ONE
home of the mapping. `.continuation` (tempo change, structural reconcile during playback, the
routing-rewire and `rebuildEngine` resumes, loop-bounds edits, `recoverEngine`) chases;
`.relocation` (transport start, seek, record start, the loop-wrap fallback, every offline bounce)
does not, and neither does any loop-cycle unroll block — each block must still reproduce a fresh
seek-to-loop-start (the §8.6 prune self-containment law), and chasing there would re-attack
straddling notes every cycle on top of the still-ringing head voice. Semantics: onset clamps to
`fromBeat` in the BEAT domain (so its frame is the block's own `anchorFrame`, the same expression
the m16-b controller chase prefix uses), off keeps its true time, pitch/velocity/noteID unchanged;
a note whose off is at or before `fromBeat` stays dropped, and a chased note with no whole frame of
tail left is dropped rather than rescued by the defensive `max(on+1, …)` clamp — a 1-frame
re-attack is a click, not a note. WHY IT MATTERS MORE THAN THE FILING SUGGESTED: `MIDIClipKey`
carries `notes`, so ANY piano-roll edit during playback reaches the `:911` restart, whose
`stopAllPlayers` flushes every voice — held notes died on every edit-while-playing, not just on a
device flip. **Rejected: true voice continuation** (no public voice-state surface on hosted AUs,
and `rebuildEngine` discards the renderers outright — out of reach, not merely out of scope);
**re-using the m14-b `timelineID` re-seek** (it is only valid against an UNCHANGED anchor, and every
restart mints a new one); **flush-skipping plus offs-only re-pairing**, the one design that would
have avoided re-attack (all three built-in instruments pair offs BY noteID, and IDs are re-minted
per build, so a fresh off matches nothing and the voice sticks forever — strictly worse than
silence — and it cannot cover the rebuild case at all). **Accepted cost, stated not implied:** a
chased note RE-ATTACKS; a slow-attack pad restarts its envelope. **Known limits, filed not hidden:**
a chased note with a few-millisecond tail still re-attacks (no threshold; any value would be
arbitrary); partial-range offline bounces keep the relocation rule, so bouncing a range that starts
inside a pad omits the pad. Design: docs/research/design-m23bp-note-chase.md.
```

---

## 12. Things deliberately NOT built

- **No new wire command / MCP tool.** Nothing here is a user-facing capability; it is a correction
  to an existing one, reachable through the commands that already exist
  (`transport.setTempo`, `clip.*`, `transport.setLoop`, the device-flip path). `allCommands`, the
  MCP tool count and the Copilot catalog are unchanged by this cycle — do not report new numbers.
- **No debug seam for the published schedule.** It was considered (it would make layer 3(b) read a
  number instead of an event array) and rejected for this cycle for the same reason m23-br was
  filed rather than folded into m20-e: new wire surface needs the full control-command + MCP-tool +
  test triple and does not belong inside a defect fix. If m23-br lands first, layer 3(b) can be
  re-expressed against it.
- **Nothing requiring full Xcode.** No entitlements, no AUv3, no signing, no bundling. This cycle
  is pure SwiftPM: `swift build` + `./scripts/test.sh`. Cycle B's live gate needs the **running
  app** on the staging port (and a second output device), which is the usual staging-gate
  requirement, not an Xcode one. `dist/DAWPro.app` is stale (161 commands vs the tree's 168) — a
  gate must run against a freshly built staging instance, and rebuilding the user's bundle is the
  user's call.

## 13. Definition of done (cycle A)

1. `swift build` clean; a FORCED rebuild reports 0 warnings (an incremental build cannot reprint
   warnings from untouched modules — do not inherit a "0 warnings" claim).
2. Full suite green: `./scripts/test.sh` backgrounded, `^✘` count zero, and the printed
   test/suite totals recorded. **RE-MEASURE the pre-cycle totals on the actual working tree
   before starting — do NOT inherit 4467 / 453.** That figure is the m20-e close on a different
   tree; this tree carries the parent's uncommitted `HeldNoteProbeTests.swift` (+1 test, +1 suite),
   which this cycle deletes while adding three suites. An inherited baseline yields either a false
   alarm or a false all-clear.
3. `MIDIControllerScheduleTests` (C1b frozen copy) green **without modification**.
4. Offline SHA suites green — the offline renders did not move.
5. Every G1–G10 and G-L1/G-L2 leg was seen RED before it was seen green.
6. The source pin (6 / 4) reddens under a single-site mutant and returns green on revert.
7. `docs/ARCHITECTURE.md` §11 applied; `docs/ROADMAP.md` m23-bp ticked with the close record naming
   the layer-3(b) gap if cycle B has not run; `CHANGELOG.md` updated.
8. The close record states explicitly that m23-bq is untouched.
