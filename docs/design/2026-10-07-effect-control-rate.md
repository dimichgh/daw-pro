# Effect control rate: what you hear live is what you bounce, at any buffer size (design and build plan)

**Date:** 2026-10-07 · **Author:** W8-M39DD (daw-architect lane, read-only) · **Status:** DESIGN. This lane built,
rendered and ran nothing. Tree: `e7e4d24` plus the uncommitted wave-8 tree, including the in-progress m39-w4-4 clock
(`Sources/DAWEngine/Modulation/ModulationSnapshotClock.swift`, untracked), read 2026-10-07 09:25 to 09:57 (clock-checked).

**Item:** `(m39-d)` (`docs/ROADMAP.md:5817-5851`). **Downstream:** `(m39-w4-4)` (`docs/ROADMAP.md:1388`) and
`docs/design/2026-10-07-loop-drum-depth.md` §4.2 and §4.3.

**Tags.** Every factual claim carries one tag:
- **[M] MEASURED**: a command ran in this lane and the output is quoted, with a positive control named for every count.
- **[M39D] MEASURED by W8-M39D**: I read the number in `$S/w8/M39D/REPORT.md` or `DIAGNOSIS.md`. I did not re-run it.
- **[R] READ**: I read the source at the cited `file:line`.
- **[I] INFERRED**: reasoning from what I read. Nobody has run it. It needs a gate before anyone relies on it.

`$S` = `/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/cc1b3823-79f0-4b80-950f-ca6f315857d1/scratchpad`.

---

## 0. Summary

- **Decision.** Effect parameters move on a fixed **512-frame control cell, counted from the roll start** (`r = 0` at
  the play or render start), in every path. Each cell's value (automation lane and modulation routes together) is
  evaluated **at the cell line** and stored **at the cell line**. A render call that contains a cell line is split
  there. A call that does not contain one tells each automated effect to **hold**. The ten effect kinds whose
  de-zipper ramp is as long as the render call ramp over **the cell** instead.
- **Why a bounce cannot change.** Every production bounce already pulls 512-frame blocks starting at `r = 0`
  (`OfflineRenderer.swift:553`) [R]. The cells are those blocks. A bounce never splits and never holds, so it runs
  today's code path. The one exception, the bounce's partial last block, is handled by giving the offline schedule
  its render end (§5.5). Byte gates verify this rather than relying on the argument (G1).
- **The finding that changes the brief's option 1.** Moving only the store onto a grid is not enough. Ten of 22
  built-in kinds ramp each new value over the render call's own length. At a 64-frame buffer, a renderer-only grid
  would make those ten rougher than today's live sound and rougher than the bounce (§3). So the grid (CR-1) and the
  cell-length ramp (CR-2) must merge together.
- **Build.** CR-0 measures first (goldens plus a split-invariance census). **CR-1 + CR-2 merge as one item.** CR-3
  (volume/pan lane chords on the grid) and CR-4 (instrument modulation stride on the roll) are optional and
  bounce-identical. CR-5 covers docs.
- **User question: none needed.** No saved song's bytes change. An optional follow-up question about a finer rate
  for new songs is drafted in §9.
- **m39-w4-4.** Its written gate is **already met**: "does not merge before m39-d's live block-size measurement is
  recorded", and W8-M39D recorded it. My **recommendation**, which is not a new gate: merge the unlock after the
  CR-1+CR-2 merge (§10).

---

## 1. What was measured, and what the harness could not see

**The measurement** [M39D]. AVAudioEngine manual rendering `.realtime`, paced 10 ms, `.gain` effect, LFO routed to
its gain. The reference is the 512-frame bounce.

| Block | Depth vs bounce 5/12/30 Hz (dB) | LFO timing vs bounce | Worst zipper (dBc; bounce −28.0/−19.2/−7.7) | Gate edges vs bounce | Verdict |
|---|---|---|---|---|---|
| 64 | −0.030/−0.151/−0.376 | −2.86/−2.98/−3.52 ms | −86.9/−71.6/−55.2 | −8.61…+0.37 ms | differs (timing), closer to ideal |
| 128 | −0.005/−0.020/+0.177 | −2.85/−2.91/−3.24 ms | −74.8/−59.2/−42.4 | −8.00…+0.01 ms | differs (timing), closer to ideal |
| 512 | 0 | 0 | identical | 0 | agrees (0 differing samples) |
| 1024 | −0.122/−0.722/−5.420 | +5.33 ms | −19.1/−9.7/+5.2 | 0…+10.67 ms | later and rougher; **30 Hz aliases to 16.875 Hz at +5.2 dBc** |

Control C2 [M39D]: `.realtime` at N frames is bit-identical to `OfflineRenderer(maximumFrameCount: N)`. **Block
size alone explains every difference.**

**The mechanism** [R]. `AutomationRenderer.storeEffectParams` (`Sources/DAWEngine/Automation/AutomationRenderer.swift:324-375`)
evaluates every effect-param track **once per render call, at the call start** (`renderStart` from `quantumStart`,
`:331`; the lane at `:354-355`; modulation at `:357-369`, position `originSample + renderStart`, `:341`). It
stores that value, and the effect holds it for the call's `frameCount`. The callers pass the render call's own
frames: `ChainHostAU.swift:316` (with `:245`), `InstrumentSourceNode.swift:923` and `:988`. No device property is on
the path (DIAGNOSIS Q1 [M39D]).

**What the harness could not see.** The harness rolled with `startAllPlayers(at: nil)`, which uses the `.offline`
position mode: `r = mSampleTime − epoch`, so every call starts on a multiple of N. C7 [M39D]: `.realtime` hands the
graph sample times and never a host time. Production live uses the other branch:
`r = round((mHostTime − anchorHostTime) · ticksToSeconds · rate)` (`AutomationRenderer.swift:408-414`) [R]. The
anchor is a future host time picked at play (`AudioEngine.swift` ~`:5838`/`:5866`, per DIAGNOSIS [M39D]). It is the
output's last render time plus a start lead (`AudioEngine.swift:5826`; lead `StartAnchorBudget.swift:92-97`) [R].
The lead is not a whole number of 512-frame calls: the 60 ms floor is 2 880 frames, which is 320 mod 512 [I,
arithmetic]. Two consequences:

1. **Today's production live at 512 is not byte-identical to the bounce either.** It samples at the same rate, but
   with the call boundaries shifted by some fixed `k` from the bounce's 512 grid [I]. "They agree only at 512" holds
   in the harness only. The grid fixes this phase as well.
2. **Production live cannot be bit-exact over a long roll, under any design.** The host-time position drifts from a
   sample count by the device clock's rate scalar. It is rounded per call, so it can step by ±1 between consecutive
   calls [I]. The production claim this design makes is: **the same value at the same roll position, up to
   host-clock drift.** The harness can be bit-exact, and the gates use it. The grid is also position-based, so it
   handles variable pull sizes (a sample-rate converter in the output unit, DIAGNOSIS "where the device enters"
   [M39D]) without special cases [I].

---

## 2. Census: what is block-rate, and where

### 2.1 Targets and sources

| # | What | How it is delivered today | Block-size dependent? | This design |
|---|---|---|---|---|
| 1 | **Effect params, automation lanes** | One value per call at the call start, held (`AutomationRenderer.swift:324-375`, `:354-355`). Callers: `ChainHostAU.swift:313-320` (every audio/bus/master strip), `InstrumentSourceNode.swift:921-925` (idle path) and `:985-990` (main path) [R] | **Yes: the sample-and-hold rate is the call rate** | CR-1, CR-2 |
| 2 | **Effect params, modulation routes** | Same function and evaluation point (`:357-369`) [R]. A param that is modulated but not automated becomes a synthetic track (`ModulationRules.swift:193-208`) [R], so lanes and routes share one store | **Yes** | CR-1, CR-2 |
| 3 | **The effect's own smoothing of a stored value** | Three classes, §2.2 | Class (a) **yes, even with a fixed store grid** | CR-2 |
| 4 | **`AutomationParamOverlay` revert rule** | A process call with no store since the last one reverts the effect to its knobs (`EffectRendering.swift:387-428`, `endQuantum` `:420-428`) [R] | It is why stores cannot simply be skipped between cell lines | CR-1 hold seam |
| 5 | Volume/pan **automation lanes** | Per-sample linear chord from the lane value at the call start to the value at the call end (`AutomationRenderer.swift:241-248`, `:260-266`; `laneChord` `:275-281`) [R] | Only inside a call that contains a breakpoint, where the chord cuts the corner over the call length [I]. Not sample-and-hold | CR-3, optional |
| 6 | Volume/pan **modulation routes** | Evaluated per sample (`ModulationStage.swift:123-151`) [R] | No, except through the follower (row 8) | none |
| 7 | **Instrument params** (our synths) | Modulation re-derived every 32 frames counted from **the call's frame 0** (`frame % 32 == 0`: `PolySynthInstrument.swift:436`, `DrumSynthInstrument.swift:388`) [R]. The drum machine latches at hit start (loop-drum-depth §4.3) | Only in phase. In a bounce and in the harness, calls start on multiples of 32, so the phases agree. In production live the stride can be shifted by up to 31 frames [I] | CR-4, optional |
| 8 | **Envelope-follower source** | The detector runs per sample but publishes its level **once per call, at the call end** (`ModulationStage.swift:75-112`; denormal flush `:103`) [R]. Effect stores read it one call late; volume/pan read the end-of-call level for the whole call (`AutomationRenderer.swift:221-224`) [R] | **Yes** (a block-rate source) | Residual R1 |
| 9 | **PolySynth oscillator drift** | Random walk stepped **once per render call** (`PolySynthInstrument.swift:402-417`, `:94`) [R] | **Yes**: at a 64-frame buffer it steps 8 times as often as in the bounce [I]. Outside the modulation layer, but it is a live-vs-bounce tone difference whenever drift > 0 | Residual R2 |
| 10 | Hosted-AU instruments' **controller lanes** (CC, bend) | AUSampler reads MIDI once per render call (`Sources/DAWCore/RenderBlockSize.swift:24-33`) [R]. AVAudioEngine owns that cadence, not us | **Yes** | Residual R3 |
| 11 | Hosted-AU **effects** | No parameter delivery path; modulation is refused (`ModulationPath.hostedRenderCall`, `Sources/DAWCore/Modulation.swift:477-478`; `ModulationRules.swift:212-222`) [R] | n/a | none |
| 12 | `sendLevel` lanes | "v0-deferred at the store" (`Sources/DAWCore/Automation.swift:23-25`) [R]; no render path | n/a | none |

### 2.2 How each built-in effect smooths a stored value (row 3)

- **(a) Call-span ramp: the ramp is as long as the render call.** `FlangerEffect.process` sets
  `let span = Double(minFrames)` and ramps every field from `previous` to `target` over it
  (`FlangerEffect.swift:308-314`) [R]. `DJFilterEffect` uses the same span, plus a 32-frame coefficient stride
  counted from the call's frame 0 (`DJFilterEffect.swift:379-409`) [R]. Grep census of the idiom
  (`let span = (Double|Float)(` · `/ span` · `/ Double(minFrames)` · `/ Double(frameCount)` and variants), per
  effect file [M]: **HallReverb 15, TapeDelay 10, Phaser 7, Flanger 7, TransientShaper 5, StereoWidth 5, RingMod 5,
  FreqShifter 5, Clipper 5, DJFilter 2**; 0 in the other 12 built-ins and in HostedAU. Positive control: Flanger's
  7 hits are the lines I read. ⚠️ A grep for an idiom can miss a kind that writes the span differently. **CR-0's
  census decides; this list is a starting point, not a verdict.**
- **(b) Its own time-constant ramp, carried across calls.** `GainEffect` retargets with a 240-frame linear ramp
  (`0.005 · sampleRate`) that persists across calls. It restarts on any retarget that is not already at steady
  state (`GainEffect.swift:152-163`) [R].
- **(c) No smoothing: a step.** `SaturatorEffect` ("a knob step has always been a step here",
  `SaturatorEffect.swift:111-113`) [R]. Whether the other 11 kinds are (b) or (c) was not read [I]. It does not
  matter to the design: class (b) and class (c) are exact under CR-1 as long as each gets one store per cell, and
  the hold seam guarantees that.

### 2.3 The offline side

- **Production offline renders use 512 and nothing else.** The only constructors are `OfflineRenderer()` at
  `AudioEngine.swift:3747` and `:3815` [M: grep `OfflineRenderer(` over `Sources/` = 2 hits]. No caller in `Sources/`
  passes `maximumFrameCount:` [M: grep `maximumFrameCount:` over `Sources/` excluding `OfflineRenderer.swift` = 0
  hits; positive control: the same pattern hits `OfflineRenderer.swift:132` itself]. The default is
  `RenderBlockSize.offlineFrames = 512` (`RenderBlockSize.swift:94`) [R].
- **The pull is `min(remaining, 512)` from `r = 0`** (`OfflineRenderer.swift:553`) [R]. `r = 0` sits at `fromBeat`:
  automation is armed and players start before the first pull (`:443-497`), and the epoch is the first pulled
  sample (`AutomationRenderer.swift:415-420`) [R]. So **every** production bounce, full or windowed, has its blocks
  on a 512 grid counted from its own start, and **only its last block is partial** [R].
- **Epoch caveat.** `r = 0` for a strip is its renderer's `offlineEpoch`, latched at its first `quantumStart` with a
  published schedule (`:416-418`) [R]. That is not literally "render sample 0". In production bounces the two
  coincide because schedules are armed before the first pull [R]. A strip first published mid-render on the same
  timeline would latch late. This behaviour already exists, this design does not change it, and nothing here
  depends on it.
- `originSample = round(seconds(0 → fromBeat) · rate)` (`PlaybackGraph.swift:2289-2294`) [R]. It is 0 for a render
  from beat 0.

### 2.4 The honesty layer already assumes 512

`ModulationPath.perQuantum` says "one per render block (512 frames → 93.75 Hz)" (`Modulation.swift:471-497`) [R].
The capability text computes its ceilings from `RenderBlockSize.offlineFrames` (`ModulationRules.swift:212-222`)
[R]. Today that number is true for the bounce and false for live at any buffer other than an aligned 512. After this
design it is true at every buffer size [I]. Only the doc wording changes (CR-5).

---

## 3. The finding that reshapes option 1

The brief's option 1 put the grid in the renderer alone. Under that version, kinds of class (b) and (c) become exact.
**The ten class-(a) kinds do not.** At a 64-frame buffer, a renderer-only grid stores once per cell. The effect then
ramps from the old value to the new one over **the first 64-frame call** and sits flat for the next 448 frames: a
staircase with slightly rounded corners. The bounce instead ramps in a straight line across the whole 512-frame cell.
Today's live at 64 re-stores every 64 frames with a 64-frame ramp, which is close to continuous. So the renderer-only
version would be **rougher than today's live and rougher than the bounce** for ten shipped kinds at small buffers [I;
CR-0 measures how much]. Shipping it alone would be a live regression.

The fix is local to each of those kinds. **A ramp's length is decided when the ramp starts.** Under automation it is
the cell length; otherwise it is the call length, as today. Progress carries across calls. At a 512 bounce the cell
length *is* the call length, so the arithmetic is the same expression, run the same number of times (§5.4). That is
CR-2, and it is why CR-1 and CR-2 are one merge.

---

## 4. Options

| | Saved songs (bounce bytes) | Live | Extra render-call splits per second | Where the split happens | Needs the user's word? |
|---|---|---|---|---|---|
| **4.0 Today** | n/a | One value per call. Differs from the bounce at every buffer except an aligned 512 (§1) [M39D, I] | 0 | none | n/a |
| **4.1 Roll-anchored 512 cells + hold + cell-length ramps (RECOMMENDED)** | **Unchanged by construction**; verified by G1 | Same values at the same roll positions as a bounce from the same start, at every buffer (bit-exact in the harness, up to host drift in production) | ≤ fs/512 = **93.75/s at 48 kHz**, only on strips with effect tracks, **including the default 512 device** | `AutomationRenderer.renderChain`, both hosts | No |
| 4.2 Song-anchored 512 cells | Full bounces from beat 0 unchanged; **windowed renders change** | Control phase matches a full bounce, but effect state never can | same as 4.1 | same | Arguably (windowed bytes) |
| 4.3 Finer fixed grid (64 or 32) everywhere | **Every saved song with an effect lane or route changes** | Smoother than today everywhere; equals the bounce | **750/s (64) or 1 500/s (32), in the bounce as well** | same, plus the offline walk | **Yes** (tone change) |
| 4.4 Per-sample or per-stride evaluation inside every effect | **Every saved song with an effect lane or route changes** | Equals the bounce by construction; no 93.75 Hz zipper | No splits; evaluator plus derive per stride inside 22 kinds | inside each kind | **Yes** |

### 4.1 Roll-anchored 512-frame control cells (recommended)

- **Saved songs.** Every production bounce is byte-identical by construction. Its pulls are the cells (§2.3).
  The partial last block is a partial cell with no cell line inside it: one store at its start, as today. Its
  class-(a) ramp is capped at the render end, so the span equals today's call span (§5.5). **G1 verifies this; it
  is not taken on trust.** No new persisted field exists, so no decode default is involved.
- **Live.** Values are evaluated at the same roll positions as in a bounce from the same start and stored at the
  same positions. Above 512 frames a call is split so the effects see 512-frame walks. Below 512, a call is split
  only when a cell line falls **strictly inside** it. In the aligned harness that never happens: calls start on
  multiples of N, and 512 is a multiple of 64, 128 and 256. So G2 at 64/128/256 exercises **only the hold path**,
  and **G2's only sub-512 split case is N = 480**; G3's unaligned cases cover the rest. In production (offset `k`,
  §1) one call in every 512/N is split. Live at 64/128 takes on the bounce's timing (about 2.9 to 3.5 ms later than today's live) and the
  bounce's zipper (−28.0/−19.2/−7.7 dBc at 5/12/30 Hz on `.gain`) [M39D]. That is slightly worse than today's live,
  and it is **exactly what the export has always sounded like**. Live at 1024 loses its +5.33 ms lag, its −5.4 dB
  depth loss at 30 Hz, and the 30 Hz → 16.875 Hz alias [M39D].
- **RT cost.**
  - **Splits.** Each cell line strictly inside a call adds one chain walk: at most fs/512 extra walks per second
    (93.75 at 48 kHz, 86.1 at 44.1 kHz, 187.5 at 96 kHz) [I, arithmetic].
  - **Only strips that have at least one effect-param track** pay anything. Every other strip runs today's code path.
  - **⚠️ The default device pays too.** In production the 512-frame calls sit `k` frames off the roll grid (§1), so
    a strip with effect tracks splits **every** call at 48 kHz/512.
    - **Where `k` comes from.** The anchor is `earliest = renderTime.hostTime + leadHostTicks + countInHostTicks`,
      where `renderTime` is the output's `lastRenderTime` (`AudioEngine.swift:5810-5827`) [R]. The lead is
      `max(0.06, 0.02 + 0.008 · players)` seconds (`StartAnchorBudget.swift:51`, `:92-97`) [R].
    - **The floor case.** At 48 kHz the 60 ms floor is 2 880 frames, and 2 880 mod 512 = **320**. If
      `lastRenderTime` marks a call boundary, then `k = 320` before any count-in [I, arithmetic]. In general `k` is
      not 0.
    - **Pinning it.** CR-0 item 4 measures it, optionally.
  - **Cost of one extra walk.** The chain's per-unit prologue: three atomic loads, the bypass observe and the tap
    check (`EffectChainProcessor.swift:413-459`) [R]. Plus each kind's once-per-call work; the largest is hallReverb
    at 24 `pow` + 2 `exp` + 1 sin/cos (`EffectRendering.swift:112-114`) [R]. Estimated at a few microseconds per
    walk, about 0.1 to 0.3 % of one core at worst [I; G6 measures].
  - **Saving below 512.** Today every call evaluates and stores every track. Under the grid, only one call per cell
    does; the rest only hold, which is a flag write. Net CPU should **drop** at small buffers [I].
  - **Optional, flagged and not designed:** choosing the roll anchor so `k ≡ 0 (mod 512)` would make the default
    path split-free (`Sources/DAWEngine/StartAnchorBudget.swift`, the anchor near `AudioEngine.swift:5838`).
- **Split location.** One home: a new `AutomationRenderer.renderChain(…)`. It replaces the store-then-walk pairs at
  `ChainHostAU.swift:313-320`, `InstrumentSourceNode.swift:921-925` and `:985-990`. `OfflineRenderer` changes in one
  place only: it passes its render length (§5.5).
- **Test.** G2: the M39D harness at N ∈ {64, 128, 256, 480, 1024, 2048} against the 512 bounce, 0 differing
  samples. A cheaper twin compares `OfflineRenderer(maximumFrameCount: N)` against the default, which C2 makes
  equivalent [M39D].

### 4.2 Song-anchored 512 cells: the brief's "position since song start"

Cell lines would sit at multiples of 512 of the project-absolute `p = originSample + r`.
- **Saved songs.** Bounces from beat 0 are unchanged (`originSample = 0`). **Every windowed render** whose
  `originSample` is not a multiple of 512, and that has effect lanes or routes, **changes bytes** [I]: a region
  bounce, a `render` with `fromBeat`, anything that starts mid-song.
- **Live.** The control phase matches a full bounce when play starts mid-song. The audio still cannot match it,
  because effect state at the play position (reverb tails, delay lines, compressor envelopes, held voices) depends
  on what played before. Live-from-X against bounce-from-0 is never bit-exact under any grid [I]. After a loop wrap
  the roll position keeps counting (loop-drum-depth §4.1 [R there]), so the cells drift off the song unless they
  read the w4-4 clock [I].
- **Why it loses.** It changes windowed bytes to buy a phase alignment that the effects' own state cannot use, and
  it needs the loop clock to stay correct. If song-locked quantisation of synced effect edges is ever wanted, it can
  be added later as a variant of 4.1's machinery.

### 4.3 A finer fixed grid (64 or 32 frames) in every path

- **Saved songs.** Every saved project with an effect lane or route bounces different bytes. The cell is no longer
  the pull. That is a **tone change to saved songs**, which needs the user's word. The shape would be "new songs
  only", with a stored per-project value that decodes to 512 when absent, plus a decode-default fixture (a byte
  gate over renders cannot see a `Codable` decode default; gate-laws §2026-09-20i).
- **Live.** Smoother than today at every buffer, and equal to the bounce.
- **RT.** fs/64 = 750 extra walks per second (fs/32 = 1 500), **in the bounce as well as live**: 8 to 16 times
  4.1's per-walk prologue. hallReverb alone would make about 750 × 27 ≈ 20 000 libm calls per second at 64 [I]. CR-2's
  per-kind work is still needed.
- **Why it loses.** Live-equals-bounce does not require it, and it costs a tone change. It is the natural
  **follow-up** if a listening check shows the 93.75 Hz zipper matters on fast modulation. 4.1's machinery is
  exactly what it would reuse with a smaller `G`, so 4.1 is not a dead end. §9 drafts that question.

### 4.4 Per-sample or per-stride evaluation inside each effect

- **What.** Each built-in kind gets the modulation snapshot and a lane cursor and evaluates its own params on a
  stride, re-deriving inside `process`.
- **Saved songs.** Every project with effect lanes or routes changes bytes [I].
- **Cost.** All 22 kinds' parameter paths are rebuilt. The overlay contract and rule 6.0.6 ("effect params arrive
  as ONE SCALAR PER QUANTUM", e.g. `FlangerEffect.swift:63`) are replaced. A derive runs per stride: about
  27 libm calls per 32 frames for hallReverb, ≈ 40 000 per second [I]. The evaluator has to reach into the effects.
  It reopens, at a larger scope, the m39-e P3 decision that priced and **declined** a `(start, end)` ramp migration
  (`AutomationRenderer.swift:333-338`) [R]. It needs 22 DSP reviews of shipped kinds.
- **Why it loses.** It has the widest blast radius and is a tone change, for a goal that 4.1 meets without one.

### 4.5 Why the two strongest alternatives lose

- **4.3 (finer grid)** is the only option that also improves the bounce. That is exactly why it cannot be the fix
  for m39-d: it changes every saved song that uses effect automation, so it needs a ruling. The question m39-d asks
  (does live equal bounce?) is answered without one. Keep it as a follow-up behind a listening page.
- **4.2 (song-anchored)** fixes a mismatch that cannot be closed anyway (effect state from before the play
  position), and pays for that with byte changes to windowed renders and a dependency on the loop clock. 4.1
  matches every render that *can* match bit-for-bit, which is a render that starts where playback started.

---

## 5. The design (4.1) in detail

### 5.1 The cell

- **`G = RenderBlockSize.controlFrames`**: new, in `Sources/DAWCore/RenderBlockSize.swift`, defined as `offlineFrames`
  (512). A test pins `controlFrames == offlineFrames`. If someone changes the bounce block size, the cell moves with
  it, and the byte gates catch the change either way.
- Roll sample `r` is exactly what `quantumStart` returns today (`AutomationRenderer.swift:405-422`) [R].
  **Cell index** `c = floorDiv(r, G)`, using floor division because live calls before the anchor have `r < 0` [I].
  **Cell line** `g = c · G`.

### 5.2 The rule for one render call `[r, r + n)` on a strip with effect tracks

```swift
// AutomationRenderer, render thread. One home for "effect params, then the chain walk".
// Called by ChainHostAU (:313-320) and InstrumentSourceNode (:921-925, :985-990) in place of
// `storeEffectParams` + `chain.process`.
func renderChain(chain:, bufferList:, frameCount n:, key:, timestamp:) {
    // No published schedule, no effect tracks, no placeable position (live with no host time),
    // or no chain snapshot: TODAY'S PATH, VERBATIM (storeEffectParams + one walk).
    ...
    var a = 0
    while a < n {                                    // `while`, never a Range (the -Onone malloc law)
        let pos   = r &+ Int64(a)
        let cell  = floorDiv(pos, G)
        let b     = min(n, Int((cell &+ 1) &* G &- r))   // the next cell line, or the call end
        if cell != lastCell {                        // ENTER: exactly once per cell
            lastCell = cell
            let cellEnd = min((cell &+ 1) &* G, renderEndFrame ?? .max)    // §5.5
            // per unit with a track: beginControlCell(frames: Int(cellEnd &- pos))       (CR-2)
            // per track: value = lane(at: cell·G) ⊕ modulation(atSample: originSample &+ cell·G)
            //            unit.storeAutomatedParam(slot:, value:)            (today's loop, new position)
        } else {                                     // HOLD
            // per unit with a track: if !unit.holdAutomatedParams() { re-enter: same as above }
        }
        walk(chain, frames: a..<b, key:, continuation: a > 0)   // §5.6
        a = b
    }
}
```

- **Evaluate at the cell line, not at the segment start.** If the entry is late (a host-time step, or a generation
  change mid-cell), the value stored is still the one the bounce stored for that cell.
- **`lastCell` is a de-duplication guard, not a phase accumulator.** Values still come from the position alone, so
  the no-accumulator law (`ModulationEvaluator.swift:57-64`, via DIAGNOSIS [M39D]) stands. `adoptGeneration`
  (`AutomationRenderer.swift:388-398`) [R] resets it along with the cursors, so a republish forces one entry.
- **Why it keeps state rather than testing `pos % G == 0`.** Production `r` is not contiguous (§1). With a
  stateless test, a cell line that falls in a one-sample gap between two calls would never be entered. The effect
  would then hold the previous cell's value for a whole extra cell. Plant P7 proves the state is load-bearing.
- **In a bounce** every call is exactly one cell: `a = 0`, `b = n`, `cell ≠ lastCell`. So: one entry, one unsplit
  walk on the original buffer list, the value evaluated at `cell · G = renderStart`. **These are today's inputs in
  today's order** [I; G1].
- **A strip with no effect tracks** never reaches the loop, live or offline. It has no split, no hold and no cell
  state.

### 5.3 The hold seam (CR-1)

`AutomationParamOverlay` reverts an effect to its knobs whenever a process call had no store
(`EffectRendering.swift:414-428`) [R]. Under the grid, most calls below 512 have no store. They need to say "the
automated values still stand" without re-storing. Re-storing is not idempotent: `GainEffect` restarts its 240-frame
ramp on a same-value retarget mid-ramp (`GainEffect.swift:158-161`) [R], which would bend its trajectory away from
the bounce.

- **`EffectRendering.holdAutomatedParams() -> Bool`: a REQUIREMENT with NO default implementation.**
  `storeAutomatedParam` does have a default no-op (`EffectRendering.swift:357-362`) [R]. If `hold` had one too, any
  kind that forgot to implement it would revert to its knobs on 7 of every 8 calls at a 64-frame buffer: a
  93.75 Hz chatter that fails silently. The compiler is the cheapest guard against that.
- **Conformers** [M: grep of `(class|struct) … : … EffectRendering`]. 24 in `Sources/`: the 22 built-ins, each of
  which embeds the overlay (23 files match `AutomationParamOverlay<`, the definition included), plus
  `PassthroughEffect` (`EffectFactory.swift:8`) and `HostedAUEffect` (`HostedAUEffect.swift:20`). 3 in `Tests/`
  (`EffectChainRenderTests.swift:22`, `:41`, `:57`).
- **Built-in body, two lines:** `adoptPendingParams(); return overlay.hold()`. The adoption has to come first so
  that a knob publish waiting in the slot is seen now, as it would be at a store (`GainEffect.swift:137-145`) [R].
  Passthrough and HostedAU return `true` explicitly. The test doubles get explicit bodies.
- **`AutomationParamOverlay.hold() -> Bool`.** It returns `false` when a main-actor publish was adopted after the last
  store, because `rebase` wipes `effective` (`:409-412`) [R]. The renderer then re-enters the cell, so a knob turn
  on an automated effect costs one call, as it does today, rather than the rest of the cell. Otherwise it sets
  `storedThisQuantum = true` and returns `true`. New field: `rebasedSinceStore`, set in `rebase` and cleared in
  `beginStore`.

### 5.4 Cell-length ramps (CR-2)

- **`EffectRendering.beginControlCell(frames: Int)`: also REQUIRED, no default.** The renderer calls it at cell
  entry, before the stores, on every unit that has a track.
- **The ten class-(a) kinds** set `pendingRampFrames = frames`. The next ramp to start uses that as its span and
  carries progress across calls (frames left, plus the per-field deltas) until it ends.
  - **⚠️ At the ramp end, CR-2 does literally what that kind does at its call end today.** If the kind snaps
    `previous = target`, CR-2 snaps. If it keeps the accumulated value, CR-2 keeps it. Do not "tidy" one into the
    other: the two differ by floating-point rounding, which moves bounce bytes, and G1 would go red. Each kind's
    current choice was not read here [I], so the implementer reads it per kind.
  - A ramp that starts with no pending cell (a knob publish or a lane-vanish revert) uses the call length, as
    today.
- **Class (b) and (c) kinds** implement it as an explicit no-op with a one-line reason ("own 240-frame ramp" or
  "steps by design").
- **Arithmetic identity is the whole point.** In a 512 bounce the span is 512, which equals today's `minFrames`. The
  deltas and the per-sample accumulation must therefore be **the same expressions in the same order**; only the loop
  bounds and the carry change. G1 checks this bit for bit.
- **DJFilter's 32-frame coefficient stride** is counted from the call's frame 0 today (`DJFilterEffect.swift:393`)
  [R]. Under CR-2 it counts from the ramp start and carries across calls, so a 64-frame call picks the stride up
  where the last one left it [I].

### 5.5 The render end (CR-2)

A bounce's last block is partial (`OfflineRenderer.swift:553`) [R]. Today a class-(a) kind ramps over that short
call. With a cell-length ramp it would aim at 512 and stop partway, which would change the last ≤ 511 frames of every
bounce whose class-(a) effect moved at its final cell. So the offline schedule carries its length:

- `AutomationSchedule` gains `renderEndFrame: Int64?`: `nil` live, set offline.
- It is plumbed through `PlaybackGraph.armOfflineAutomation(fromBeat:tempoMap:renderFrames:)`
  (`PlaybackGraph.swift:2508-2512`) [R] from `OfflineRenderer` (`:443`; the total is
  `round(durationSeconds · sampleRate)`, `:509`) [R].
- `cellEnd = min((c + 1) · G, renderEndFrame)`, so the final partial cell's ramp span equals today's call span.
- Plant P5 proves this line is load-bearing.
- Any other offline arming (tests, the M39D harness) leaves the value `nil`, and its cells are uncapped. G2 therefore
  compares whole cells, or uses render lengths that are multiples of 512, unless it arms with a length.

### 5.6 The split, kept real-time safe

- **Views.** `AutomationRenderer` owns two preallocated `AudioBufferList` views, one for the main buffers and one
  for the key. Each holds up to 8 buffers and is allocated in `init` on the main actor, freed in `deinit` (the
  `effectCursors` pattern). A segment sets `mNumberBuffers`, `mData = base + a · 4` and
  `mDataByteSize = (b − a) · 4` per channel. That is pointer arithmetic only: **no allocation, no lock, no ObjC,
  no actor** [I by construction; G5 measures allocations].
- **Fallback.** If there are more channels than the view holds, the call walks unsplit with one store at entry
  (today's behaviour). It never crashes.
- **Continuation walks.** The chain walk gains `continuation: Bool`. A continuation segment **skips reset
  consumption** (`daw_atomic_u32_exchange(unit.resetFlag, 0)`, `EffectChainProcessor.swift:422-427`) [R], because
  a double-armed flush has to reach the *next* call, not the second half of this one. It also **skips
  `observeBypass`** (`:432-433`) [R]. Both keep exactly their per-call semantics.
- **What is already split-safe** [R]. The bypass crossfade's progress is per sample (`fadePosition + frame`,
  `:278`). The spectrum tap is a contiguous ring (`InsertSpectrumTap.write`, `InsertSpectrumTap.swift:210-242`).
- **Hosted-AU inserts** on a split strip receive two shorter render calls. `HostedAUEffect` advances its own sample
  time by the frames rendered (`HostedAUEffect.swift:190`) [R], so the timestamps stay contiguous [I].
- **Order inside a call is unchanged:** pull input and key, then the master's pre-chain volume, then
  [enter or hold, then walk the segment] repeated, then PDC compensation over the whole call, then volume/pan over
  the whole call (`ChainHostAU.swift:264-332`) [R].

### 5.7 How this meets m39-w4-4's clock

A synced step source routed to an effect param is evaluated at the cell line like any other source. The clock
indexes roll sample `n = p − originSample` (`ModulationEvaluator.swift:106`, `ModulationSnapshotClock.swift:68-70`)
[R], and `c · G` is a roll sample, so nothing in the clock changes. Effect step edges land on the next cell line,
at most 10.7 ms late, **identically live and in a bounce from the same start** [I]. Instrument targets keep their
per-frame and hit-start latching.

### 5.8 Failure modes and their guards

| # | Failure | Guard |
|---|---|---|
| F1 | A kind forgets `hold` and chatters at small buffers | No default implementation (compile error); G4 runtime check over every kind |
| F2 | Non-contiguous host-time `r` skips or repeats a cell | `lastCell` state; G3 with jitter; plant P7 |
| F3 | A continuation walk consumes a reset or re-observes bypass | The `continuation` flag; reset-mid-roll test at 1024; plant P6 |
| F4 | More channels than the view holds | Unsplit fallback, never a crash; covered in G3 |
| F5 | A kind that is not split-invariant even at static params | CR-0's G0 lists it. Its live/bounce gap lies outside this item and is filed, not hidden; its G2 becomes a tolerance with the measured number |
| F6 | CR-2's rewritten ramp drifts one ULP from today's | G1 byte gate, full and windowed |
| F7 | An offline path arms without its render length | G1's partial-last-block fixture; plant P5 |
| F8 | A strip with no effect tracks starts splitting | The guard returns before the loop; G1 fixtures without effect lanes; G6 counter is 0 |
| F9 | A generation changes mid-cell | Forced entry storing the **cell-line** value; G3 |
| F10 | Negative `r` before the anchor | `floorDiv`; G3 case |
| F11 | A knob turn mid-cell on an automated effect | `hold → false` re-enters; G3 case |
| F12 | A hosted AU sees variable call sizes | Already legal (≤ `maximumFramesToRender`); contiguous sample time (§5.6) |

---

## 6. Build items, gates and plants

**Merge rule: CR-1 and CR-2 land as ONE merge (§3).** CR-0 runs first, on today's tree, before any code changes.
CR-3 and CR-4 are optional, independent and bounce-identical. No wire or MCP change is involved: this is
engine-internal, adds no new user-facing capability, and adds no persisted field.

### CR-0 — measure before building (S; `qa-test-engineer`, with `audio-dsp-engineer` reading the spans)

1. **Goldens.** Capture the G1 byte hashes on **today's** tree, before any code changes (fixture set under G1).
2. **G0, a split-invariance census.** For each of the 22 built-in kinds: a fixed input, static non-default params, no
   automation and no routes, rendered with `OfflineRenderer(maximumFrameCount: N)` for N ∈ {64, 128, 480, 512, 1024},
   then compared with N = 512 as differing-sample counts per kind.
   - **Positive control:** on today's tree, an automated `.gain` at 64 against 512 **must** report a difference
     (M39D measured one), so a census of zeros means "invariant", not "the comparison is blind".
   - A kind that differs here **at static params** differs live from bounce for reasons this item does not touch.
     File it separately, and set its G2 threshold to the measured number.
3. **Span census by reading.** Confirm or extend the ten class-(a) kinds from §2.2, file by file, including any the
   idiom grep missed.
4. **Optional: measure `k`, the default device's offset from the roll grid** (§4.1). This is the one inferred number
   that moves the RT-cost section.
   - **Method.** Log `r mod 512` for the first few `quantumStart` calls of a live roll, through a test hook.
   - **Prediction:** 320 with the 60 ms floor lead and no count-in.
   - **⚠️ It needs a real output device**, so it runs under the device rules: a test process or the staging port
     only, never the user's live app on 17600, and never a change to device selection.
   - **If `k` is 0 after all,** the default path is split-free and the alignment idea in §4.1 is moot.

New file: `Tests/DAWEngineTests/ControlGridInvarianceTests.swift`. The census is env-gated (`CR0_CENSUS=1`) and its
results become pinned assertions in CR-1/CR-2.

### CR-1 — the grid, the split, the hold seam (M; `audio-dsp-engineer`, opus)

- `Sources/DAWCore/RenderBlockSize.swift`: `public static let controlFrames = offlineFrames`.
- `Sources/DAWEngine/Automation/AutomationRenderer.swift`:
  - `lastCell` state, reset in `adoptGeneration` (`:388-398`).
  - `renderChain(chain:bufferList:frameCount:key:timestamp:)` (§5.2).
  - The two preallocated views (§5.6).
  - The `storeEffectParams` loop (`:343-374`) is factored into "evaluate every track at roll sample X and store". The
    entry path calls it with `X = c · G`. The fallback (no position) keeps today's behaviour.
- `Sources/DAWEngine/Effects/EffectRendering.swift`: the `holdAutomatedParams() -> Bool` requirement, with **no
  default**; `AutomationParamOverlay.hold()` and `rebasedSinceStore`.
- Every conformer:
  - the 22 built-in `*Effect.swift` files (`adoptPendingParams(); return overlay.hold()`);
  - `EffectFactory.swift` (`PassthroughEffect`) and `HostedAUEffect.swift`, which return `true`;
  - the three test doubles in `Tests/DAWEngineTests/EffectChainRenderTests.swift`.
- `Sources/DAWEngine/Effects/EffectChainProcessor.swift`: `process(bufferList:frameCount:key:continuation:)`.
  Continuation walks skip reset consumption and `observeBypass`.
- Call sites: `ChainHostAU.swift:313-320`, `InstrumentSourceNode.swift:921-925` and `:985-990` call `renderChain`.
- New file: `Tests/DAWEngineTests/ControlGridTests.swift` (G3, G4, G5).

### CR-2 — cell-length ramps and the render end (M; `audio-dsp-engineer`, opus)

- `EffectRendering.swift`: the `beginControlCell(frames:)` requirement, with **no default**.
- The ten class-(a) kinds (plus any CR-0 adds) get a carried ramp (§5.4). The other twelve, Passthrough and HostedAU
  get explicit no-ops with a one-line reason.
- The render end (§5.5):
  - `Sources/DAWEngine/Automation/AutomationSchedule.swift`: `renderEndFrame: Int64?`.
  - `PlaybackGraph.swift:2508`: `armOfflineAutomation(fromBeat:tempoMap:renderFrames:)`.
  - `OfflineRenderer.swift:443`: passes `Int((durationSeconds * sampleRate).rounded())`, the same expression as
    `:509`.
- ⚠️ **Coordinate with the in-flight m39-w4-4 lane.** Its clock is uncommitted in the same file
  (`PlaybackGraph.swift` ~`:2296-2374`, plus `ModulationSnapshot*.swift` and `ModulationEvaluator.swift`).
  - The `PlaybackGraph` edit here (`armOfflineAutomation`, `:2508`) is a few lines away from it. Whichever lane
    lands second rebases.
  - **CR-1 and CR-2 do not touch** `ModulationSnapshot.swift`, `ModulationSnapshotBuilder.swift`,
    `ModulationSnapshotClock.swift` or `ModulationEvaluator.swift`, so the two lanes can be scheduled in parallel.

### CR-3 — optional: volume/pan lane chords on the grid (S; `audio-dsp-engineer`)

- **What changes.** `AutomationRenderer.apply` (`:241-266`, `laneChord` `:275-281`) and the modulated stage's base
  (`ModulationStage.applyVolume`/`applyPan`, `:123-151` and following) chord per **cell**: from the lane at `g` to
  the lane at `min(g + G, renderEnd)`, with step = Δ / cell length and value = start + step · (pos − g).
- **Why the bounce cannot move.** The argument is the one in §4.1: cells equal pulls, and the last partial cell is
  capped.
- **What it buys.** G2 then holds for projects with volume/pan lanes as well. Without CR-3, those projects differ only
  inside a call that contains a lane breakpoint, by a chord over at most 512 frames [I].

### CR-4 — optional: instrument modulation stride on the roll (XS; `audio-dsp-engineer`)

- **The change.** `frame % 32 == 0` becomes `floorMod(renderStart + frame, 32) == 0` at
  `PolySynthInstrument.swift:436` and `DrumSynthInstrument.swift:388`.
- **First call after adoption.** It must still derive at frame 0 when the instrument has no valid modulated
  coefficients yet, which the implementer verifies.
- **Why the bounce cannot move.** In a bounce `renderStart ≡ 0 (mod 512)`, so both expressions select the same
  frames [I].

### CR-5 — docs (XS; `docs-scribe`, as each item lands). See §11.

### Gates

- **G0 — static split-invariance census** (CR-0, above).
- **G1 — bounce invariance, a byte gate with hashes captured in CR-0 before any code.**
  - **Fixtures, for each of the 22 kinds:** one effect automation lane whose breakpoints sit off the 512 grid, and
    an LFO route (5 Hz) plus a step-gate route on another param of the same effect. Each is rendered three ways:
    - **(a)** from beat 0, with a length that is **not** a multiple of 512, so a partial last block exists and the
      last cell moves;
    - **(b)** windowed from `fromBeat = 3.37`, so `originSample mod 512 ≠ 0`;
    - **(c)** with no effect lanes at all on the strip (F8).
  - **Also:** (d) every existing render byte-gate fixture in the suite.
  - **Pass:** all identical after CR-1 + CR-2.
  - **Plants:** P1 (`G = 256`) turns (a) and (b) red, which proves the fixtures exercise the grid. P5 (render end
    dropped) turns (a) red, only for class-(a) kinds and only in the last block.
- **G2 — live equals bounce, device-free.**
  - **Main check:** the M39D harness (`Tests/DAWEngineTests/LiveBlockSizeModulationTests.swift`, `.realtime`,
    `startAllPlayers(at: nil)`) at N ∈ {64, 128, 256, 480, 1024, 2048} against `OfflineRenderer()` at 512 must show
    **0 differing samples over whole cells** for every kind that passed G0. A kind that failed G0 uses its measured
    tolerance.
  - **Cheaper twin:** `OfflineRenderer(maximumFrameCount: N)` against the default must show 0 differences,
    including the partial last block (both runs are capped). C2 [M39D] makes the twin equivalent.
  - **Analysis re-run:** the M39D table must read "agrees" in every row.
  - **Plant:** P3 (split disabled) turns 480/1024/2048 red.
- **G3 — the host-time path, white-box with a spy.**
  - **Setup:** drive `renderChain` with synthetic `AudioTimeStamp`s (`.hostTimeValid`, a `.live(anchorHostTime:)`
    schedule) and a spy `EffectRendering` that logs store, hold, `beginControlCell` and process frame counts.
  - **Cases:** contiguous calls at 64, 480 and 1024; a +1-sample gap across a line; a −1 overlap at a line; negative
    `r` before the anchor; a generation change mid-cell; a pending knob publish mid-cell (`hold → false` → exactly
    one re-store); more channels than the view holds.
  - **Pass:**
    - exactly one entry per cell, never zero;
    - stored values equal the lane and modulation at `c · G`;
    - a hold on every other call;
    - continuation walks never consume a reset.
  - **Plants:** P4 (evaluate at the segment start instead of the cell line) and P7 (stateless `pos % G == 0`) turn
    the gap case red. P6 (a continuation consumes a reset) turns red.
  - ⚠️ **G3 tests the stage only (the m39-e lesson: "a hand-published snapshot tests the stage, not the
    publication").** The real publication path is covered by G1 and G2, which go through `OfflineRenderer` and the
    graph.
- **G4 — every kind holds.**
  - **Check:** for each of the 22 built-ins, offline at 64 against 512, with a lane holding a constant value that
    differs from the knob for several cells, and then with a stepping lane: bit-identical.
  - **Plant:** P2 (one kind's `holdAutomatedParams` body returns without calling `overlay.hold()`) turns G4 red at
    64. The missing-implementation case is a compile error by construction.
- **G5 — RT allocation.** Extend the existing absolute-zero allocation-gate pattern (the one the
  `EffectChainProcessor.swift:402-412` comment cites in `InsertSpectrumChainTests`) to `renderChain` with splits at
  64, 480 and 1024 and with hold paths. Pass: **0** malloc events.
- **G6 — cost.**
  - **Counter:** a render-thread integer counter of extra walks, surfaced through a test hook. It must be
    ≤ (cell lines strictly inside calls), and 0 on strips without effect tracks.
  - **Timing:** CPU via `EnginePerformance` before and after, at 64, at an offset 512 and at 1024, for a 10-insert
    automated strip. This is reported, not asserted (timing noise).
- **G7 — the suite.**
  - `./scripts/test.sh`, the full suite, with no new failures beyond the known list.
  - A clean-build warning count (`--scratch-path`, per the baselines law) with no new warnings.
  - Measured on a quiet machine.

---

## 7. Residuals: filed, not built here

- **R1 — the follower publishes once per call** (row 8).
  - **Effect targets.** Under CR-1, an effect target reads the level from the end of the previous call. In a bounce
    that is the frame before the cell line. Live at 64, when the entry falls mid-call, it is up to 63 frames earlier
    [I].
  - **Volume/pan.** They use the end-of-call level for the whole call.
  - **Sketch of a fix:** run the detector per segment (walk → PDC → detect → store → walk), so the store at `g`
    reads the level at `g − 1`.
  - Route `audio-dsp-engineer`. Small; not a gate.
- **R2 — PolySynth drift steps once per render call** (`PolySynthInstrument.swift:402-417`) [R].
  - **The difference.** At a 64-frame buffer the walk moves 8 times as often as in the bounce [I]. That is a
    live-vs-bounce **tone** difference on any patch with drift.
  - **The fix.** Step the walk at roll-grid lines inside the per-frame loop. It is bounce-identical by the CR-4
    argument.
  - **To file as `(m39-d-drift)`**, route `audio-dsp-engineer`. Recommended next after CR-1/2.
- **R3 — hosted-AU controller lanes (CC, bend)** are sampled-and-held at AVAudioEngine's call to the AU
  (`RenderBlockSize.swift:24-33`) [R].
  - **Why the cell split cannot reach it.** We do not split that call.
  - **A sketch to evaluate, not a decision:** floor-quantise controller events (never notes) to the cell grid when
    the schedule is built. In a bounce AUSampler already applies them at the block start, so that could be
    bounce-identical [I], but it needs a measurement on AUSampler first.
  - Until then, the capability text's "93.75 Hz" is true for the bounce and for an aligned 512 device only.
- **R4 — production host-clock drift** (§1). Nothing to build. It is stated so that nobody writes a production
  bit-exactness test that cannot pass.

---

## 8. What changes for the user

- **Saved songs:** nothing. Every export is byte-identical (G1).
- **At the usual 512-sample audio buffer:** effect automation and LFOs sound the same as now, and line up exactly
  with the export instead of being offset by a few milliseconds.
- **At small buffers (64/128, used for low-latency recording):** effect automation and LFOs now sound exactly like
  the export. On very fast wobbles that is very slightly steppier and about 3 ms later than before, which is how the
  export always sounded.
- **At large buffers (1024 and up):** no more late, rough or **wrong-speed** (aliased) effect wobbles while
  monitoring. The 30 Hz → 16.9 Hz alias measured by M39D is gone.

---

## 9. User question

**None is needed for this item.** No saved song's bytes change, and live becoming equal to the export is m39-d's own
mandate ("If it diverges, the modulation layer needs a block-size-independent control rate", `ROADMAP.md:5826-5827`
[R]).

**Optional follow-up, drafted but not recommended to ask yet.** Ask only after CR-1+CR-2 land **and** after a
listening page has shown the four choices are audibly different. Per the audibility rule, a demo must be checked
before anyone ships it. The axis is one thing: how often an effect updates when something moves it, for new songs
only.

> **How smoothly should effects move in NEW songs?** When automation or an LFO moves an effect (say, a filter
> sweeping up and down fast), the app updates that effect a fixed number of times per second. More updates make
> very fast wobbles sound smoother, but they also change how a song exports, so this would only apply to songs you
> start from now on. Your saved songs keep exporting exactly as they do today. Listen to the four clips of the same
> fast wobble and pick the one you like:
> - **(a) 94 times a second**: what every song uses today.
> - **(b) 188 times a second**
> - **(c) 375 times a second**
> - **(d) 750 times a second**: smoothest; the export takes a little longer.

If the user ever picks (b) to (d), that is option 4.3 with a stored per-project value (absent decodes to 512), a
decode-default fixture, and `G` read from the project rather than from a constant. CR-1's machinery is reused
unchanged.

---

## 10. Can m39-w4-4's unlock merge?

- **The written gate is already met.** `ROADMAP.md:1388` says the unlock "does not merge before m39-d's live
  block-size measurement is **recorded**". W8-M39D recorded it (`$S/w8/M39D/REPORT.md`, test
  `Tests/DAWEngineTests/LiveBlockSizeModulationTests.swift`). **I am not adding a gate.**
- **My recommendation, which is not a rule: merge the unlock after the CR-1+CR-2 merge.**
  - **Why.** The measurement found exactly the divergence m39-d was filed to catch. Today, a synced step source
    routed to an effect param would put its edges up to **8.6 ms early** at 64 and up to **10.7 ms late** at 1024
    compared with the bounce (gate edges, [M39D]). At 1024 an edge can land up to 21.3 ms after its step boundary
    live, against at most 10.7 ms in the bounce [I, one value per 1024-frame call]. After CR-1+CR-2 the two are
    identical at every buffer (G2).
  - **What it does not affect.** The unlock's instrument targets (drum per-step sound) are block-size independent
    either way (loop-drum-depth §4.3 [R there]).
  - **If the unlock merges first.** That is a legitimate call. The honest state until CR-1+CR-2 land is that synced
    effect edges differ between live and bounce by the M39D numbers. **No per-target refusal**: loop-drum-depth
    §4.3 declines to invent one, and I agree.
- **Plainly: yes.** The unlock can merge after CR-1+CR-2 land. Nothing in CR-3/CR-4 or the residuals gates it.

---

## 11. Owed edits (this lane could write only this document)

- **`docs/ARCHITECTURE.md` "Key future decisions" (`:416`)**, a new entry:

  > **Effect-parameter control rate (m39-d): a 512-frame control cell counted from the roll start, in every path
  > (SETTLED 2026-10-07 by design; NOT YET SHIPPED. Reasoning, census and gates:
  > `docs/design/2026-10-07-effect-control-rate.md`).**
  > - **What the cell rule is.** Effect params (lanes and routes) are evaluated and stored at each cell line. A
  >   render call that contains a line is split there; a call that does not holds
  >   (`EffectRendering.holdAutomatedParams`, required, with no default). Effects that de-zipper over the call
  >   length ramp over the cell instead (`beginControlCell`).
  > - **Why no bounce moves.** A production bounce already pulls 512-frame blocks from the roll start, so the cells
  >   are its blocks. The offline schedule carries its render end so the partial last block keeps today's span.
  > - **Lost:** a finer grid (64/32), which is a tone change to every saved song with effect automation and needs
  >   the user's word, so it is held as a follow-up; a song-anchored grid, which changes windowed renders to align
  >   a phase that effect state cannot use; per-sample evaluation inside each effect, the widest change and a tone
  >   change.
  > - **Production live** equals the bounce up to host-clock drift. The device-free harness is bit-exact.
- **`Sources/DAWCore/RenderBlockSize.swift`** (type doc, `:51-80`). The "design argument" paragraph becomes true at
  every buffer for effect params. The "what remains unmeasured" paragraph becomes: measured by W8-M39D, fixed by
  CR-1/2, with R1 to R3 still open.
- **`Sources/DAWCore/Modulation.swift:475-486`** (`ModulationPath.perQuantum` doc): "one per 512-frame control cell,
  at every device buffer size".
- **`AutomationRenderer.swift:310-323`** (`storeEffectParams` doc) and **`EffectRendering.swift:381-395`** (overlay
  per-quantum contract): add hold and `beginControlCell`.
- **`TempoSync.swift:28-31`**: no edit from this item. The w4-4 phrase is owed by w4-4.
- **`docs/ROADMAP.md`:**
  - `(m39-d)`: tick it when CR-1+CR-2 land, with the G1/G2 numbers;
  - file `(m39-d-drift)` (R2), the follower (R1) and hosted-AU CC (R3) as rows;
  - `(m39-w4-4)`: note "written gate met by W8-M39D; recommended order: after the CR-1+CR-2 merge".
- **`CHANGELOG.md`**: a user-facing line in §8's words, when it ships.
- **Optional wording:** the capability text that quotes "93.75 Hz" (`ModulationRules.swift:212-222`, `EffortField`)
  can add "at any audio buffer size" for built-in effects once CR-1+CR-2 land.
