# PRODUCTION DEFECT — live playback is ~9.4 dB quieter than the render, and unlimited

**Reported by the user 2026-08-04**, from a real session (an EDM/trance instrumental built by a
Codex agent team against `dist/DAWPro.app`). Verbatim: *"when played in app itself, was very
quiet … but when we exported the songs, everything sounded very good"*, and — the detail that
rules out a balance explanation — *"even kick and percussion were quiet comparing to the output
so I had to increase loudness on my headphones"*, and *"as if it was going before loudness
adjustment or so it seemed to me."*

**That last intuition is exactly right, and it is now measured.**

---

## ⭐⭐⭐ CYCLE 8 — **SOLVED.** THE RENDER PREPARED ITS AUs FROM THE MODEL; THE MODEL IS ONLY REFRESHED AT SAVE TIME

**This section supersedes EVERY section below, including cycle 7.** Fixed and verified 2026-08-04
(m23-bx-1). Three specific claims in cycle 7 were measured to be FALSE — they are listed at the end
of this section so nobody re-derives them.

### The mechanism

A hosted AU's live state lives in `AUHostRegistry`, **never in the model**. Nothing writes it back
as the user works: `au.setParam`'s own doc comment says the value *"persists via save-time
fullStateForDocument capture"*, and edits made in the vendor's own plugin window never touch the
model at all. Meanwhile `OfflineRenderer` builds its own registry and prepares each AU from the
`stateData` it is HANDED (`OfflineRenderer.prepareAudioUnits`) — and every render entry point handed
it the raw `tracks` array.

So `render.mixdown`, `render.bounce`, `render.stems` and `measureLoudness` all rendered the
last-LOADED-or-SAVED patch, while playback used the live one. **The export was a rendering of a
patch the user had never heard.**

### The proof — a three-way control, run before and after the fix

With a live Surge XT's `Global Volume` (addr 1336600346) driven from 0.72 to **0** via `au.setParam`,
rendering Bass alone over beats 256–277:

| render | before fix | after fix |
|---|---|---|
| **A** fresh open | −38.8 LUFS, peak −16.2 | −38.9, peak −16.2 |
| **B** render immediately after the live edit | **−39.0, peak −16.2 — UNCHANGED** | **−70.0, peak −50.6** |
| **C** `project.save` (captures live state) + reopen | −70.0, peak −50.6 | −70.0, peak −50.9 |

C is the control that makes B conclusive: the edit was real and the save could see it, so B's
unchanged render proves the renderer could not. After the fix **B equals C exactly**, and A is
unmoved — no regression on the fresh-open path.

Full mix, fixed build: **−22.3 LUFS** (unchanged), and LIVE playback of the same window measures
**−22.262** — export and playback now agree to **0.04 dB**.

### The fix

ONE home: `ProjectStore.tracksWithLiveAudioUnitState()` — the seam the SAVE path already used — now
feeds every offline render. What you hear is what you get, by construction. A track with no live
state (never prepared, still preparing) keeps the model's bytes, so the capture can never ERASE a
saved patch.

Second defect, also fixed: `AudioEngine.reportUnhostableInstrument` posts an `instrument-unavailable`
notice naming the track, at the exact instant `audioUnitProvider` starts answering nil. Silence is
no longer the only symptom.

### ⚠️ THREE CYCLE-7 CLAIMS THAT ARE FALSE — do not re-derive from them

1. **"Six tracks render silence via `SilentPlaceholderInstrument`."** NO. The six AU tracks render at
   **peak −15.1 dBFS** together (`iso-au6`), and `OfflineRenderer`'s own not-prepared warning printed
   **zero** lines to stderr. **Nothing ever reached the placeholder.** The placeholder story was
   inferred from reading `PlaybackGraph.swift:519`/`:523`, never measured.
2. **"Three instrument-less tracks fall back to PolySynth — audible."** NO. Two are `.audio` tracks
   with **zero clips**. The third, `Arrangement — D minor`, is an instrument track with **zero notes
   in the entire project** (its 9 clips are empty arrangement markers) and renders **peak −inf**.
   They contribute exactly nothing.
3. **"9.4 dB deficit; the −12.9 render is the correct one."** BACKWARDS. Deleting all six `stateData`
   blobs reproduces the −12.9 render to **0.1 dB overall and ≤0.4 dB in every band**:

   | render | I | low | mid | high |
   |---|---|---|---|---|
   | all `stateData` stripped (DEFAULT patches) | **−12.8** | −20.8 | −14.9 | −19.3 |
   | `drop1-offline` — the user's "good" export | **−12.9** | −21.2 | −15.0 | −19.2 |
   | saved state applied | −22.3 | −31.6 | −31.0 | −23.6 |

   So at export time the model's `stateData` was **not what the live AUs held**. ⚠️ *Why* is NOT
   established — their session was never observed — only the 0.1 dB match is measured. −22.3 is the
   honest sound of the patches actually saved. The fix makes the two AGREE; it does not and must not
   make the song louder.

### ⚠️ SCOPE — THE FIX IS A DELIBERATE NO-OP ON A FRESH OPEN

On a fresh open the live registry is prepared FROM the model's `stateData`, so the two already agree
and the capture changes nothing. MEASURED, identical to four figures across the fix: full mix
**−22.3 / low −31.6 / mid −31.0 / high −23.6** before AND after; Bass alone −38.8 → −38.9. **The
user's reopened project still plays and exports at −22.3.** What the fix removes is the DIVERGENCE.

### THE QUIET PATCHES ARE GENUINE — NOT A FAILED RESTORE

This distinction decides whether the fix helps or harms: capturing live state would BAKE IN a failed
restore. Settled by POSITIVE evidence rather than an absent log — of Bass's **512** parameters, **12
differ from Surge XT's defaults**, in a coherent hand-designed pattern:

| parameter | saved | Surge default |
|---|---|---|
| A Filter 1 Cutoff | 0.30 | 0.4846 |
| A Amp EG Sustain | 0.35 | 1.0000 |
| Global Volume | 0.72 | 0.9578 |
| A Width | 0.35 | 1.0000 |
| A Volume | 0.72 | 0.8909 |
| A Filter 1 Resonance | 0.14 | 0.0000 |

plus Amp EG decay/release, Osc 1 shape/sub-mix/unison-detune, pre-filter gain. **A silent fallback
would leave all 512 IDENTICAL.** Corroborating: **zero** stderr lines across three app instances —
no *"continuing stateless"*.

A darker filter plus a collapsed amp sustain, on exactly the six bass/pad/arp/lead tracks, is also
precisely the **−16 dB mid-band** signature the user described, while the untouched drum sound-banks
keep the highs.

⚠️ **"My mix is too quiet" is therefore a MIX-BALANCE question about the user's own project — theirs
to decide, not ours.** Their louder sound survives only in the WAVs already exported.

### Also refuted by measurement

- **The prepare race.** Waiting until `instrumentPrepares == 8` with `inFlight: []` and a 5 s margin
  still renders −22.3 — identical to rendering immediately. Not a race.
- **Progressive state degradation.** Three `save → open → save` generations render **−38.9 / −39.0 /
  −39.0**. The capture/restore round trip is audibly faithful. (The `stateData` BYTES differ each
  generation and the size drifts by 1 byte on two Surge tracks — benign serialization
  nondeterminism, not loss.)
- **The insert chain.** Setting Bass's `gain` insert from 4 to 1 moved the render by exactly
  **−12.0 dB** (−38.9 → −50.9). The built-in chain applies perfectly.

### Method laws paid for here

- **A single sample of an ASYNCHRONOUS quantity is not a measurement of it.** Cycle 7's headline
  (`instrumentPrepares: 0`) was read 0.2 s after open; the true value reaches 8 within ~2 s.
- **An isolation render plus a strip-one-input control beats any amount of call-chain reading.** Five
  cycles died on plausible stories derived from correct-looking code. What actually cracked it was
  rendering each source alone, then deleting one field and re-rendering.

---

---

## 0. ⭐ SUPERSEDING FINDING (2026-08-04, second cycle) — IT IS THE HOSTED AU INSTRUMENTS, AND `ready` DOES NOT MEAN AUDIBLE

Measured on a SECOND app instance (mine, port 17695, a COPY of the project, output routed to
BlackHole so nothing reached the user's speakers). Same 21 s window, all offline renders:

```
  full mix            −22.3 LUFS      ← equals the user's LIVE reading, −22.26
  drums only          −22.7 LUFS      (AU tracks excluded)
  AU instruments only −32.1 LUFS      peak −15.4 dBFS, RMS −34.9
  the GOOD export     −13.0 LUFS
```

⭐ **THE SIX HOSTED-AU TRACKS CONTRIBUTE 0.4 dB TO THE FULL MIX.** Excluding all of them costs
almost nothing, because together they sit **9.4 dB BELOW the drums alone**. In the good export the
full mix is −13.0 while drums alone are −22.7, so there the AU instruments must dominate — they
are roughly **19 dB louder in the session that produced the good render than in a reopened one**.

⭐ **AND THE USER'S LIVE PLAYBACK WAS, TO WITHIN 0.05 dB, A DRUMS-ONLY MIX** (live −22.26 vs
drums-only −22.7 / full-with-crippled-AU −22.3). Their verbatim report — *"kicks/drums/percussion
were loudest while the lead instruments were very quiet"* — was not an impression. It was the
measurement.

### What this overturns

- **§3's "the deficit is upstream of the master chain" was right but under-specified.** It is
  specifically the hosted-AU instrument sources.
- **§2's "AU instruments failing to load — RULED OUT" WAS WRONG, and the way it was wrong is the
  lesson.** `engine.auPrepareStats` reported all 8 slots `status: "ready"`, `inFlight: []`, and I
  treated that as proof the instruments were fine. **`ready` means the plug-in INSTANTIATED. It
  says nothing about whether it produces audio, or at what level.** The diagnostic I shipped three
  days earlier answered a question I mistook for a different one.
- The `1/√N` numerology in §3.3 is doubly dead: the ~9.4 dB is the drums-to-AU ratio, not a
  summing artifact, and it matched √8 by pure coincidence.

### The surviving hypothesis (NOT yet proven)

The plug-ins are Surge XT (×4) and Dexed (×2), and `AUHostRegistry.prepare` restores each one's
patch from `stateData`. **If `stateData` restore silently fails or is skipped, the plug-in plays
its DEFAULT init patch — loaded, `ready`, and far quieter than a designed trance lead.** A ~19 dB
deficit is the right order for that.

⚠️ **What this does NOT yet explain: the user's session NEVER reopened the project.** Their live
was crippled while their OFFLINE render of the same in-memory session was correct — so a
disk-restore path cannot be the whole story. Either the live and offline paths differ in how they
hand `stateData` to the instrument, or there are two faults. **Do not collapse these two
observations into one cause without measuring.**

### ⚠️ CYCLE 3: THE `stateData` HYPOTHESIS IS IN TROUBLE — TWO OBSERVATIONS CONTRADICT

**Measured, not assumed:**

- **`stateData` IS saved.** `project.json` carries real patch blobs: Surge XT 56 831 / 58 491 /
  56 828 / 58 491 B, Dexed 7 642 / 7 627 B. (`soundBank` tracks correctly have none — LAW L3.)
- **The restore code is present and correctly ordered on BOTH paths** — instrument
  (`AUHostRegistry.swift:774`) and effect (`:605`): `maxFrames → format → state → allocate`, with
  decode failures logged rather than swallowed.

**And here is the contradiction that must be resolved before anyone "fixes" state restore:**

`OfflineRenderer` builds its **OWN** `AUHostRegistry` (`OfflineRenderer.swift:79`) and re-prepares
every instrument from the model's `stateData`. So an offline render NEVER uses the live plug-in
instances — it always reconstructs from `stateData`.

```
                       live instances        offline (fresh, from stateData)
  user's session       −22.3  BAD            −12.9  GOOD
  my reopened session  (not measured)        −22.3  BAD
```

- In the **user's** session, the path that restores from `stateData` produced the GOOD render.
  That is positive evidence that `stateData` restore WORKS.
- In **my** session, the same reconstruct-from-`stateData` path produced the BAD render.

**Both cannot be explained by "stateData restore is broken."** Either the two sessions' saved
state differs in some way not visible in the file I diffed, or something else (not the instrument
state) is the variable. ⚠️ **DO NOT open a fix on state restore on the strength of the −19 dB
number alone — the offline path in the user's own session is a counter-example.**

### Next measurement

**The one that discriminates:** in a single freshly-opened instance, render the SAME AU track
twice — once via `render.mixdown` (fresh registry from `stateData`) and once by capturing the LIVE
output of that track solo. Same instance, same second. If they differ, the live and offline
instrument paths genuinely diverge; if they agree (both quiet), the saved state is the variable
and the user's session held something the file does not.

⚠️ **Budget note for whoever takes this: three cycles have now each produced a confident cause
that the next cycle refuted** (master chain inert → upstream sum → AU state restore). Every
refutation came from ONE cheap measurement that was skipped the cycle before. **Measure the
discriminator FIRST, before writing any explanation.**

### ⚠️ CYCLE 4 — I INVALIDATED MY OWN INSTRUMENT, AND FOUND A SECOND DEFECT

The discriminator was run and **produced no usable live number, for a reason that matters more
than the number would have.**

**① MY INSTANCE WAS NEVER RENDERING AUDIO.** With `output.setDevice → BlackHole2ch_UID`:

```
engine.watchdogStatus:  engineRunning true, state "ok", lastHeartbeat 0, restartCount 12
                        (a second instance reached restartCount 36)
mixer.liveLoudness:     secondsAnalyzed 0
```

**`lastHeartbeat: 0` with `engineRunning: true` means ZERO render callbacks have ever occurred.**
The watchdog was declaring stalls and restart-looping the whole time.

⚠️ **THEREFORE EVERY "live" NUMBER TAKEN ON MY OWN INSTANCE IS VOID.** They were never
measurements. What survives untouched:
- **The user's live −22.26 LUFS IS VALID** — their app was on `BuiltInSpeakerDevice` and the meter
  reported `secondsAnalyzed: 20.6`. **Check `secondsAnalyzed` before believing a loudness reading;
  a meter that saw no audio reports absence, and absence is not zero.**
- **Every OFFLINE render is valid** — `render.mixdown` uses manual rendering and needs no device,
  which is exactly why those numbers were reproducible while the live ones were not.

**② A SECOND DEFECT, worth its own item: selecting BlackHole 2ch leaves the engine claiming to run
while producing no callbacks, and the watchdog restart-loops** (12 and 36 restarts across two
instances). BlackHole is a legitimate, installed, 48 kHz 2-ch device and `output.setDevice` (m20-j)
reported it `isSelected: true`. Whether this is BlackHole-specific or affects any virtual/loopback
device is NOT established. Filed as **m23-bx-2**.

**③ The main actor wedged transiently during playback of a Surge XT track** — `mixer.liveLoudness`
returned the m23-av wedge intercept verbatim: *"main actor has been unresponsive for 4.5 s — the
app UI is wedged"*. It recovered. This is the [[daw-pro-au-hosting-wedge]] symptom reproducing on
a path that is NOT `track_set_instrument`, and it is the first time that wedge has been caught by
the diagnostic built for it.

**What the next cycle must do differently:** the live half of the discriminator needs a REAL output
device (built-in speakers), because that is the only configuration measured to actually render.
That makes sound, so it needs the user's agreement on timing — it is not a thing to do unattended
at 4 am.

### ⭐⭐ CYCLE 5 — THE REPRODUCTION. OPENING THIS PROJECT WEDGES THE MAIN ACTOR FOR MINUTES

**This supersedes m23-bx-2 (which is REFUTED — see below) and explains every anomaly across four
test instances.**

```
transport.play          => "main actor has been unresponsive for 116.2 s — the app UI is wedged"
engine.auPrepareStats   => {"inFlight":[],
                            "mainActor":{"responsive":false,"wedgedForSeconds":252.924}}
engine.watchdogStatus   => {"mainActor":{"responsive":false,"wedgedForSeconds":252.925}}
```

**REPRODUCTION, on demand:** launch `dist/DAWPro.app` (either directly or via LaunchServices),
`project.open` a project holding **6 hosted AU instruments (4× Surge XT + 2× Dexed)**, and the main
actor wedges for **250+ seconds**. Not a hang at `track_set_instrument` — a hang at PROJECT OPEN.

**Why every earlier "measurement" on my instances was garbage:** the app was wedged, so
`transport.play` never took effect — hence callbacks +0, frames +0, meter `secondsAnalyzed: 0`, and
the watchdog restart-looping (restartCount 1→4→12→36). ⚠️ **I read those symptoms as an audio
defect twice** (first "BlackHole breaks the engine", then "the engine never renders on any
device"). Both were the SAME wedge wearing different clothes.

⚠️ **m23-bx-2 IS REFUTED — DO NOT IMPLEMENT IT.** "Selecting BlackHole leaves the engine dead" was
wrong: the DEFAULT device behaved identically (callbacks +0, restarts 1→4). BlackHole is
exonerated; the filing was pattern-matching on one variable I happened to have changed.

### ⭐ THE FINDING THAT MATTERS MOST: `inFlight: []` DURING A 253 s WEDGE

`engine.auPrepareStats` ANSWERED while the main actor was wedged — the m23-av work doing exactly
its job, and the first time that diagnostic has paid off on a real wedge. And what it reports is
the diagnosis:

**NO AU PREPARE IS IN FLIGHT.** The wedge is therefore NOT inside a `DeadlineRace`-guarded prepare,
so m23-at's off-main deadline cannot fire on it and m23-av's ledger cannot name it. **This is
exactly the residual hole filed as m23-av-2:** `AVAudioUnitComponentManager.components(matching:)`
at `AUHostRegistry.swift:697` runs ON THE MAIN ACTOR, BEFORE the race, inside NO deadline — so a
stalling component scan wedges the app with no record armed and a confident-empty `inFlight`.

**m23-av-2 is no longer a theoretical residual. It is the reproducing failure.** Its priority
should rise accordingly: it is the difference between a wedge the app can name and one it cannot.

⚠️ Not yet established: that `components(matching:)` IS the wedging frame. `inFlight: []` proves
only that it is not a guarded prepare. **Attach a sampler / `sample <pid>` during the wedge and
read the actual stack before fixing anything** — this document has now produced four confident
causes and refuted three of them, every time by skipping exactly that kind of direct observation.

### Relation to the user's original report — STILL NOT PROVEN THE SAME BUG

The user's app was NOT wedged when measured (`mainActor.responsive: true`, meter analysed 20.6 s of
real audio). So this reproduction is not automatically their fault. What it plausibly explains is
the AU tracks being ~19 dB down: **if a wedge or a stalled component scan leaves hosted instruments
partially initialised, they can be `ready` and still not sound right.** Plausible, unproven.

### ⚠️ CYCLE 6 — THE STACK SAYS THE MAIN THREAD WAS **IDLE**. "REPRODUCTION ON DEMAND" IS WITHDRAWN.

⚠️ **FIRST, A CORRECTION TO THIS VERY SECTION:** I wrote "I sampled a wedging instance". **I never
verified that.** The 252.9 s reading came from pid 51354; the `sample` was taken on pid 52063, a
DIFFERENT instance that reported `responsive: true` throughout. **A healthy app looking healthy
refutes nothing.** The stack below is real but it is evidence about the wrong process.

The hot spine of the Main Thread, 7296 samples:

```
7294  NSApplicationMain → -[NSApplication run] → nextEventMatchingMask: → _DPSNextEvent
7292  ReceiveNextEventCommon → RunCurrentEventLoopInMode
6056  __CFRunLoopServiceMachPort → mach_msg → mach_msg2_trap        ← BLOCKED, IDLE, WAITING
```

**83 % of samples are parked in `mach_msg2_trap` inside the ordinary AppKit event loop.** That is a
healthy idle app. **The main thread was NOT burning CPU and was NOT stuck in AU code — there is no
Surge XT, no `components(matching:)`, no `AudioComponent*` frame anywhere on it.**

And a FRESH instance this cycle never wedged at all: `mainActor.responsive: true`, all 8 slots
`ready`, `restartCount: 0`, `state: "idle"`.

⚠️ **THEREFORE CYCLE 5's "opening this project wedges the main actor for 250+ s, reproducible on
demand" IS WITHDRAWN.** What is true: a wedge was REPORTED (116 s, then 253 s) on two instances and
not on others; it is INTERMITTENT, and when sampled the main thread was idle.

**Two readings remain open, and they need opposite fixes:**

1. **The wedge is real but not CPU-bound** — main-actor jobs enqueued and never serviced (a modal
   or tracking run-loop mode that does not drain the main queue would do this; a fresh instance with
   no user present is exactly where a permission/recovery dialog appears). The thread would look
   idle, as observed.
2. **`MainActorLivenessMonitor` FALSE-POSITIVES** — reporting a wedge that is not happening. ⚠️ **If
   so this is a defect in my own m18-b/m23-av work with a nasty consequence: `ControlServer`'s wedge
   intercept then REFUSES legitimate commands.** `transport.play` was rejected in this very cycle,
   which is why nothing rendered, callbacks stayed at 0, and the meter read 0 — i.e. **the false
   wedge report, not any audio bug, produced the "engine never renders" symptom I filed as m23-bx-2.**

**Discriminator (cheap, do it first):** during a reported wedge, enqueue a trivial `@MainActor` job
and time it. If it runs promptly, the monitor is lying (reading 2). If it never runs while the
thread sits in `mach_msg`, main-queue servicing is blocked (reading 1). **Do not fix either until
this one number exists.**

## ⚠️⚠️ CYCLE 8 — CYCLE 7's MECHANISM IS **WITHDRAWN**. I READ THE LEDGER 0.2 s TOO EARLY.

Cycle 7 concluded "`project.open` prepares ZERO hosted AU instruments" and I reported it as
established. **It is false.** The reading was real; the inference was not. Prepares are ASYNC and
I sampled the ledger immediately after open. Timed probe, fresh instance:

```
open -> "ok" in 0.2s
t=+0s:  instPrep=0  fxPrep=0  inFlight=0  tracks=0
t=+5s:  instPrep=8  fxPrep=0  inFlight=0  tracks=8   <-- all eight prepared
t=+15s: instPrep=8  tracks=8
t=+60s: instPrep=8  tracks=8      (stable; mainActor responsive, engineRunning=false)
```

**All 8 hosted instruments prepare successfully within ~5 s.** So `SilentPlaceholderInstrument` is
NOT the standing state, main-actor starvation is NOT the cause (my hypothesis — withdrawn), and
`instrumentPrepares: 0` was a snapshot of a 5-second window, not a permanent condition.

⚠️ **THIS IS THE SIXTH CONFIDENT CAUSE IN EIGHT CYCLES AND THE SECOND I REPORTED TO THE USER BEFORE
IT WAS SOUND.** The one measurement that would have caught it — read the ledger TWICE, seconds
apart — costs nothing. **A single sample of an asynchronous quantity is not a measurement of it.**

### ⚠️ AND A FRAMING ERROR THAT OUTLIVED SEVEN CYCLES, INCLUDING THIS DOCUMENT'S TITLE

`drop1-offline` (−12.9, correct) and `repro-offline`/`restore-check` (−22.3, broken) were **BOTH
produced by `render.mixdown`** — both offline, same code path. **There is no live-vs-offline split
in this data.** The real axis is **long-settled session vs freshly-opened session**. This file is
named for a split its own measurements no longer show.

### What still stands, unrefuted

- `project.open` returns `"ok"` in **0.2 s — long before the AUs it needs exist.**
- Fresh-open render: **−22.3 LUFS**, mid (200–2k) **−34**. User's settled session: **−12.9**, mid
  **−17.7**. Deficit **9.4 dB**, concentrated **−16 dB in the mid band**.
- Two independent fresh-open runs agree to **0.03 dB in every band** — deterministic, not flake.
- The user's exports are correct and mutually consistent; their live playback measured −22.26.
- The silent fallback is real and is a defect on its own terms: `PlaybackGraph.swift:519`/`:523`
  resolve `audioUnitProvider(track) ?? SilentPlaceholderInstrument()` — *"Pending/failed/missing →
  silence"* — never logged, never surfaced, never retried. **During those ~5 s a track IS silent**,
  and nothing anywhere says so.

### The two live branches — one test separates them

Every broken render was taken INSIDE the ~5 s prepare window.

1. **RACE.** Open → wait for `instrumentPrepares == 8` and `inFlight == []` → render. If that
   yields ≈ −12.9, the defect is that open reports success and render/playback proceed before
   hosted instruments are ready, with nothing to wait on.
2. **BAD RESTORE.** If it still yields ≈ −22.3, the prepared AUs are producing the wrong sound —
   suspect `stateData` restore falling back to a DEFAULT patch (the restore path logs
   *"continuing stateless"* to **stderr**; `open -na` discards stderr, which is why five cycles of
   logs were empty). On-disk `stateData` is present and large: 75776 / 77988 / 75772 / 10192 /
   10172 / 77988 bytes.

Delegated to `audio-dsp-engineer` with instructions to settle this by measurement before writing
any fix.

## (SUPERSEDED) CYCLE 7 — the zero-prepare reading and what it actually showed

**This section supersedes every cause proposed above.** It is the first one carried by direct
instrumentation plus a deterministic reproduction rather than by inference.

### The measurement

Launched `dist/DAWPro.app/Contents/MacOS/DAWApp` **directly** (not via `open -na`, which discards
stderr — that is why five cycles of logs were empty), on port 17695, and opened the project copy:

```
open:         "ok"
prepareStats: {"instrumentPrepares":0, "effectPrepares":0, "inFlight":[], "tracks":[],
               "mainActor":{"responsive":true}}
stderr:       0 lines
```

**`instrumentPrepares: 0` and `tracks: []` after a SUCCESSFUL open.** stderr is empty not because
restore succeeded but because **restore never ran** — there was nothing to restore into.

### Why that silences six tracks

The saved project holds 11 tracks:

| kind | tracks | resolves to |
|---|---|---|
| `soundBank` | Kick & Main Drums (vol 0.38), Percussion & Tops (0.8) | hosted AUSampler — **audible** |
| `audioUnit` | Bass, Rolling Bass Layer, Atmospheric Pad, Lead Synth (**Surge XT**), Hypnotic Arp, Pluck Motif (**Dexed**) — faders 0.75–1.0, `stateData` 10–78 KB each | `audioUnitProvider(track) ?? SilentPlaceholderInstrument()` → **SILENT** |
| absent | Arrangement, Risers & FX, Impacts & Textures | `?? .default` → built-in PolySynth — **audible** |

With no prepare, `audioUnitProvider` returns nil and `PlaybackGraph.swift:519`/`:523` wire the six
loudest tracks — every bass, pad, arp, pluck and lead in the song — to silence. **Never logged,
never surfaced, never retried** (`SilentPlaceholderInstrument` has exactly three references in all
of `Sources/`: the type and those two call sites).

### Deterministic reproduction, and the corrected arithmetic

| render | I | low | mid | high |
|---|---|---|---|---|
| `drop1-offline` — user's live session, via MCP on 17600 | **−12.9** | −22.5 | **−17.7** | −25.0 |
| `repro-offline` — fresh open, run 1 | **−22.3** | −31.91 | −33.99 | −29.85 |
| `restore-check` — fresh open, run 2 | **−22.3** | −31.91 | −33.96 | −29.85 |
| `drums-only` | −22.7 | −32.3 | −35.9 | −30.0 |

Two independent fresh-open runs agree to **0.03 dB in every band**. The deficit is **9.4 dB**, and
it is concentrated in the **mid band (−16 dB)** — exactly where bass, pads, arps and leads live.

⚠️ **A LABEL ERROR CORRECTED.** I had called a −32.1 LUFS render "AU-only" and reasoned from it
that the AU tracks were rendering. They were not: that file is the **three instrument-less tracks
falling back to the built-in PolySynth**. The power sum (drums −22.7 ⊕ residual −32.1 = −22.23)
still holds and still matches the user's live −22.26 — but it says *"drums plus the default-synth
residue"*, not *"drums plus working AUs"*. **The arithmetic was right; the name on one term was
wrong, and the wrong name nearly retired the correct hypothesis.**

### Why the export was fine

`OfflineRenderer` builds its **OWN** `AUHostRegistry` (`OfflineRenderer.swift:298`, `:492`) and
prepares each AU from `stateData` inside the render. It never depends on the live graph's registry.
So the export path prepares the AUs the live path never prepared — which is precisely the user's
report: **"the exported song sounded very good; in-app playback was quiet with only drums."**

### Status

- **ESTABLISHED:** after `project.open`, hosted AU instruments are never prepared; the six AU
  tracks render silent; the reopened mix is 9.4 dB down. Reproduced twice, instrumented directly.
- **STRONGLY SUPPORTED, not yet instrumented:** the same absence in the user's *never-closed*
  session. Their live playback measured **−22.26**, matching the zero-AU render **−22.3** to
  0.04 dB, while their export from that same session was −12.9. Confirming it means reading
  `engine.auPrepareStats` on their running app, which is theirs to allow.
- **Filed as m23-bx-1.** The fix must also address the silent fallback itself: a track whose
  instrument cannot be prepared must SAY SO, not play silence.

### ⭐ THE BREADCRUMB LOG — GROUND TRUTH, AND IT WAS THERE THE WHOLE TIME

`~/Library/Logs/DAWPro/main-actor-wedge.log` is written **off-main**, one line per wedge, by design
(m18-b). It does not depend on the control port, on my probes, or on the main actor being alive. I
had never read it. Today, local time = UTC−7:

```
12:00:33Z WEDGED for 3.0 s → RECOVERED after 4.6 s
12:18:43Z WEDGED for 3.0 s → RECOVERED after 4.9 s
12:20:28Z WEDGED for 3.1 s → RECOVERED after 4.9 s
12:35:39Z WEDGED for 3.1 s → (no RECOVERED line — that instance was killed still wedged)
```

**Six wedges today; every one that recovered did so in 3.7–4.9 s.** There is no 116 s or 253 s
breadcrumb anywhere. So the multi-minute readings correspond to the single never-recovered instance,
and the routine case is a ~4 s blip.

⚠️ **THAT ROUTINE CASE HAS A CONSEQUENCE I HAD NOT CONNECTED.** `ControlServer.wedgeIntercept`
(`ControlServer.swift:168-197`) answers **every non-watchdog command with `.failure`** whenever the
snapshot says wedged — threshold **2.5 s**. So each of those ordinary ~4 s blips is a window in
which `transport.play` is REFUSED. **This is a plausible mechanism for "the engine never renders"
that requires no audio bug at all**, and it fires on a threshold the app crosses six times a day.

### ⭐ THE HYPOTHESIS THAT FITS EVERY MEASUREMENT — A SILENT AU FALLBACK

`PlaybackGraph.swift:519` / `:523`, and its own comment:

```swift
case .audioUnit: return self.audioUnitProvider(track) ?? SilentPlaceholderInstrument()
// Pending/failed/missing → silence.
case .soundBank: return self.audioUnitProvider(track) ?? SilentPlaceholderInstrument()
```

**If the AU is not ready at the instant the strip is built, the track is wired to SILENCE — and this
is never logged, never surfaced, and never retried by itself.** `grep` finds exactly three
references to `SilentPlaceholderInstrument` in the whole of `Sources/`: the type, and these two
call sites. No diagnostic anywhere.

Now match it against everything measured:

| Evidence | Silent-fallback prediction | Observed |
|---|---|---|
| User's LIVE playback | drums only; AU tracks silent | **−22.26 LUFS ≈ drums-only −22.7** ✓ |
| User's EXPORT | full mix — `OfflineRenderer` builds its **OWN** registry (`:298`, `:492`) and re-prepares from `stateData` | **−12.9 LUFS, sounds correct** ✓ |
| "even kick and percussion were quiet" | whole mix ~10 dB below the export they were comparing to | had to raise headphone volume ✓ |
| No error, no warning | fallback is silent by construction | user saw nothing ✓ |

**This is the first hypothesis in six cycles that predicts the live/export split rather than being
patched onto it**, and it explains the one number that has survived everything: live ≈ drums-only.

⚠️ **It is NOT yet established.** `engine.auPrepareStats` reported all 8 tracks `ready` — but the
ledger records *prepare* outcomes, not *what instrument object the strip actually holds*. Those are
different facts, and the whole hypothesis turns on the difference. **The discriminator is to ask the
live graph what it is actually rendering, not to ask the ledger what it prepared.**

### What survives all six cycles, unrefuted

- The user's live playback measured **−22.26 LUFS with `secondsAnalyzed: 20.6`** — a real
  measurement, on real hardware, equal to a **drums-only** mix within 0.05 dB.
- In a freshly-opened instance the six hosted-AU tracks render **−32.1 LUFS against drums-only
  −22.7**, i.e. they contribute **0.4 dB** to the full mix. Offline renders need no audio device and
  reproduced every time.
- The user's renders are correct and mutually consistent (−12.9 / −13.0 / −13.1 LUFS).

Everything else in this document has been proposed and withdrawn at least once.

### Superseded next-measurement note (kept for provenance)

Render one AU track alone with a KNOWN-loud patch set live via `au.setParam`, then reopen and
re-render. If the level drops, `stateData` restore is the fault. Also compare
`AUHostRegistry.prepare`'s restore call between the live and offline paths.

---

## 1. The measurement

Project: `/Users/dsemenov/Documents/edm-trance-by-codex-sol-max.dawproj`, 138 BPM, 11 tracks.
Master chain: `compressor` (ratio 1.5, threshold −18 dB, makeup 0.5 dB) → `limiter`
(**ceiling −1.6 dB**, release 120 ms). Master volume 1.0097.

Same **21 s of the same music** (Drop 1, from beat 256 = 111.3 s), same project state, same
running app:

| | LIVE (`mixer.liveLoudness`) | OFFLINE (`render.mixdown`) | user's "Rebalanced" export | user's earlier export |
|---|---|---|---|---|
| project state | current | current | current | PRE-rebalance |
| Integrated | **−22.26 LUFS** | **−12.9 LUFS** | −13.0 LUFS | −13.1 LUFS |
| True peak | −2.70 dBTP | **−1.600 dBFS** | −1.6205 dB | −1.1 dBTP |
| RMS L/R | — | −15.21 / −16.72 | −15.37 / −16.87 | −15.41 / −16.28 |
| Crest factor | **24.1 dB** | ~13.6–15.1 dB | — | ~13.2–14.8 dB |

⭐ **THE CONTROL THAT MAKES THIS AIRTIGHT (user-supplied, 2026-08-04): there are TWO exports.**
`… - AU Mix.wav` (01:35) predates the agent's rebalance; `… - Rebalanced AU Mix.wav` (01:58)
matches the saved project (02:01) and therefore matches the state measured live. **My own offline
render of the current state reproduces the Rebalanced export to within ~0.15 dB on every channel**
(−12.9 vs −13.0 LUFS, −1.600 vs −1.6205 peak, RMS within 0.16 dB). So the live-vs-offline
comparison is same-state throughout and the ~9.4 dB deficit is not a state-drift artifact.

⚠️ **AND THE REBALANCE BARELY MOVED THE OUTPUT: −14.1 → −14.0 LUFS full-program (0.1 dB).** What
it actually changed was LRA, 4.2 → 3.1 LU. The user's agent was asked to fix a loudness problem
that does not exist in the render, and its edit correspondingly did almost nothing to loudness —
it just compressed the program's dynamic range. **Both exports were, and remain, fine.**

**≈ 9.4 dB quieter live**, and **≈ 10 dB more crest** — the live signal is peaky and unlimited
while both renders are dense and limited.

⭐ **THE CLINCHING NUMBER: the offline render peaks at exactly `-1.600000` dB — the limiter's
configured `ceilingDb` to three decimals.** The limiter is provably doing its job offline. Live
peaks at −2.70 dBTP with a 24 dB crest, which is what an unlimited mix looks like.

The user's two independent renders agree with each other (−12.9 / −13.1) and disagree with live,
so this is a **live-path defect, not a render defect**.

## 2. What was RULED OUT, each by measurement

- **AU instruments failing to load.** `engine.auPrepareStats`: all **8** instrument slots
  `status: "ready"`, `inFlight: []`, `mainActor.responsive: true`. The plug-ins are live.
- **CPU starvation / real-time overload.** `engine.performanceStats`: **`overrunCount: 0`**,
  `averageLoad` 0.0116, `recentLoad` 0.0189, peak callback 6.07 ms against a 10.67 ms budget
  (512 frames @ 48 kHz). The engine is ~1–2 % loaded and has never missed a deadline.
- **Sample-rate conversion (the M20 suspicion).** Output device is `BuiltInSpeakerDevice` at
  **48 000 Hz**, graph at **48 000 Hz**, nothing pinned. No conversion is occurring.
- **Project/app state drift.** `project.overview` matches `project.json` field-for-field
  (Kick 0.38, Perc 0.8, Bass 0.8, Rolling 0.75, Pad 0.75, Arp 0.95, Pluck 0.85, Lead 1.0,
  master 1.0097). Nothing was edited between the export and the live listen.
- **A balance/mix problem.** The deficit is uniform — the user reports the drums are quiet too.

## 3. ⚠️ THE MASTER CHAIN IS **NOT** THE CAUSE — the discriminator flipped it

The discriminator in §3.1 was run, and it **refuted the obvious conclusion this document was
originally written around.** During live playback of Drop 1, both master dynamics report:

```
compressor  thresholdDb -18   gainReductionDb 0
limiter     ceilingDb  -1.6   gainReductionDb 0   latencySamples 240   (= 5 ms @ 48 k, real)
```

`gainReductionDb` is held-peak with a −20 dB/s release specifically so a poll cannot miss a brief
clamp — so 0 during the loudest section is real.

**But 0 is exactly what a CORRECTLY WORKING chain reports on this input.** Live peak is
**−2.70 dBTP, below the limiter's −1.6 dB ceiling**, and live loudness is **−22.3 LUFS, below the
compressor's −18 dB threshold**. Neither unit has anything to do. The chain is inert *because its
input is already ~9 dB too quiet* — it is a SYMPTOM, not the cause.

Offline, the same project peaks at **exactly −1.600 dB**, which means the limiter DID engage —
so the offline signal arriving at the master was hot enough to hit the ceiling.

⭐ **THEREFORE THE DEFICIT IS UPSTREAM OF THE MASTER CHAIN: the summed per-track signal reaching
`mainMixerNode` is ~9 dB quieter in live playback than in the offline render of the same project.**
The master chain then faithfully passes the quiet mix through, and the missing limiting is a
second-order consequence.

⚠️ **METHOD NOTE, worth more than the finding: "master FX not applied live" fit every number in
§1 and was WRONG.** A ~9 dB loss plus ~10 dB excess crest plus an offline peak pinned to the
limiter ceiling is fully explained by *either* an inert limiter *or* a quiet input, and only the
gain-reduction reading separates them. This was one call away from a confidently wrong root cause
and a fix in the wrong module.

## 3.1 The discriminator (already run — kept for the next person)

## 3.2 Where the surviving suspicion lives

The question is now: **why is the live per-track sum ~9 dB quieter than the offline one, for the
same tracks at the same volumes?**

A ~9.4 dB uniform deficit is a linear factor of ~0.34 — suspiciously close to a single global
gain applied on one path and not the other. Candidates, none yet tested:

- **The instrument source nodes themselves.** All 8 slots are `ready`, but "loaded" is not
  "rendering at the same level". Both paths build a `PlaybackGraph`, so a per-node gain or
  velocity/scale difference would have to come from how each path drives it.
- **`mixMonitorGate`** (`PlaybackGraph:434`, `outputVolume = open ? 1 : 0`) sits between the
  master chain and the output in the live topology (`:416`) and has no offline counterpart. It is
  documented as binary, so it should not attenuate — VERIFY rather than assume.
- **Mixer summing.** Live sums through `AVAudioMixerNode`s in real time; offline sums the same
  graph under `enableManualRenderingMode`. Any implicit per-input scaling that differs between
  the two modes lands exactly here.
- **Per-track insert chains.** Every quiet track has a `gain` effect first in its chain. If those
  gain stages apply offline and not live, the deficit would be uniform across tracks and would
  look precisely like this. **This is the cheapest thing to check next** — read
  `gainReductionDb`-adjacent state, or A/B one track's `gain` params live.

### 3.3 Refuted this cycle (do not re-raise without new evidence)

- **"The render normalizes to −14 LUFS."** Tempting: BOTH user exports land at −14.1 / −14.0 LUFS
  full-program, which is the fingerprint of a −14 streaming target. **REFUTED BY CODE:**
  `OfflineRenderer.swift` contains no `lufsTarget` / `truePeakCeiling` / normalization of any kind
  (grep-zero), and `render.mixdown` accepts no loudness-target parameter. The render is honest;
  the divergence is real.
- **"1/√N summing normalization."** The deficit (9.36 dB) is beguilingly close to 20·log₁₀(√8) =
  9.03 dB and 20·log₁₀(√9) = 9.54 dB with 8–9 sounding tracks. **There is NO `sqrt`, no per-input
  normalization, and no 1/N term anywhere in `PlaybackGraph` (grep-zero).** This is NUMEROLOGY
  until a measurement varies N and watches the deficit move. Recorded so the next reader does not
  mistake an arithmetic coincidence for a lead.

### 3.4 ⭐ The strongest structural candidate: the live-only monitor lane

`PlaybackGraph:408-445` documents a post-chain pair that **exists ONLY in a live graph**:

```
    masterChainHost ─► mixMonitorGate ─┐
                       (outputVolume    ├─► monitorSum ─► outputNode
                        1=mix, 0=ref)   │   (unity sum)
    referencePlayer ─► referenceGain ───┘
                       (level-match gain)
```

Its own doc comment: *"`OfflineRenderer` builds its own graphs and never touches it, so NO
reference node ever exists in an offline render."* **This is the only stage in the signal path
that is present live and absent offline — exactly the shape the measurement demands.**

Caveats, stated so this is not over-sold: it is gated by `referenceLaneEnabled` (default false),
`mixMonitorGate.outputVolume` is documented as binary 1/0, and this project has no references
(`project.json` has no such key). So the lane *should* be absent here. **Check it anyway — it is
the only structural asymmetry found, and "should" is what this whole investigation has been
demolishing.**

**NEXT MEASUREMENT (do this before touching code):** render ONE track solo offline and compare it
to that same track's live level, to establish whether the deficit is per-track or only appears in
the sum. That single number decides between "every source is quiet" and "the summing/output stage
is quiet", which are different bugs in different files.

## 4. Why it matters more than its dB

A DAW whose monitoring does not match its bounce cannot be mixed in. Every level decision the
user (or an agent) makes while listening is made against a signal the render will not reproduce
— which is precisely what happened here: the user asked their agent to "fix" a balance that was
never wrong, and the agent complied. **The bug does not just sound wrong; it induces wrong
edits, and it made an AI agent confidently agree with a false premise.**

## 5. Not yet checked

- Whether `mixMonitorGate` (`PlaybackGraph:434`, `outputVolume = open ? 1 : 0`) is involved.
- Whether master **automation** (`masterAutomation`) has the same live/offline asymmetry.
- Whether per-track insert chains are also inert live — the balance matched, which suggests
  they are fine, but nothing here proves it. **Track FX are the same `EffectChainState` machinery,
  so a shared root cause would explain both; this must be measured, not assumed.**
- Whether this reproduces on a project created fresh in-app vs one opened from disk.

Filed as **m23-bx-1**. Route: `audio-dsp-engineer`, with `daw-architect` review.
