# Spike: live looping — stacking layers in real time (the Kiffness workflow)

Author: research-analyst. Date: 2026-08-30. Status: research only, no code touched.

Prompted by the project owner: *"also record chords on the fly, put them into loop and assign
to the buttons on trackpad (show assignment on the screen) and then allows to switch instrument
and play another sequence of matching chords or beats and so on... according to what we can
present virtually and build."* Filed on the roadmap as `docs/ROADMAP.md` item **m23-db**, which
already carries a dense pre-brief from the orchestrator (the "take-comping vs layer-keeping"
distinction, the velocity insight, the linear/session-view fork) — this document is the delegated
research leg that item calls for, not a fresh framing of the problem.

---

## 0. Summary and recommendation

**Live looping is a real, well-documented performance discipline with three independent lineages
that converge on the same handful of UX rules — and DAW Pro can deliver most of what the owner
described without a Session View, because half of the "assign to a trackpad button" ask is
already a live-write in this engine and only half needs a genuinely new primitive.**

1. **The Kiffness's exact tool chain is not verifiable from public sources, and I am not going to
   assert one.** What *is* verifiable: his own channel titles several of his most-viewed cat
   remixes "**Live Looping** ... Remix" (§1) — so "live looping" is not this document's
   interpretation of his genre, it is his own word for it. The mechanics of *how* that genre works
   are fully documented by the three canonical systems in §2, independent of which one he
   personally runs.
2. **The three canonical models — Boss's hardware loop stations, Ableton Live's Session View +
   Looper device, and Loopy Pro — independently arrived at the same handful of rules**: loop
   length is set once by an early pass (or fixed in advance) and everything after locks to it;
   launches quantize to a musical grid, never to the millisecond of the button press; undoing the
   last layer is a first-class, one-gesture operation; and state is communicated by light/color,
   not text, because a performer's eyes are on their hands or their instrument (§2, §3). That
   convergence across three unrelated engineering teams is the strongest evidence in this document
   — it means these are not one brand's taste, they are load-bearing requirements of the genre.
3. **The architectural question splits into two questions that have different answers, and
   conflating them is the trap.** *"Fire or silence a layer that's already recorded"* is close to
   free in this engine, because mute/volume/pan are already live writes that do not touch the
   scheduling signature (`PlaybackGraph.ClipKey`'s own doc comment, verified — §4.1). *"Choose
   between two alternative loops for the same slot and switch between them on demand"* — the
   second half of the owner's sentence, "play **another** sequence of matching chords" — needs a
   real clip-launch primitive that measurably does not exist today (§4.2–§4.4).
4. **Clip launching does not need velocity, confirmed independently across all three canonical
   models, not merely asserted** (§5) — which means the 9-box trackpad grid's documented inability
   to sense per-pad pressure (`docs/research/spike-trackpad-expression.md`) is irrelevant to this
   feature. What the grid needs instead is **state**, not force: a live-updating visual language
   (empty / armed / recording / playing / queued / muted) mirrored on screen, which is exactly the
   owner's own "show assignment on the screen" requirement.
5. **Recommendation: build the linear route first, but build its capture path as the shared
   substrate rather than a dead end** (§6, Option B). The engine work Phase 1 actually needs —
   landing a new clip during uninterrupted playback, and finishing a take without stopping the
   transport — is *the same primitive* a future launch-primitive route would need. Sequencing
   linear-first does not throw that work away; it just doesn't build scenes yet. What the linear
   route permanently forecloses is narrow and specific: **pre-recording two alternatives and
   choosing between them live** — everything else in the owner's ask is reachable.

---

## 1. The Kiffness's actual setup

**I could not verify a specific DAW, controller-for-looping, or hardware loop pedal for David
Scott ("The Kiffness"), and I am stating that plainly rather than guessing** — per this project's
own standing rule after a near-miss on a different research spike, a confident wrong gear list
here would misdirect the whole design.

### What is verified, and how

| Claim | Source | Confidence |
|---|---|---|
| He self-labels multiple of his most-viewed remixes as "**Live Looping**" in the video title itself | His own YouTube channel: *"The Kiffness X Big Billy (**Live Looping** Talking Cat Remix)"* ([youtube.com/watch?v=T0P6MC8Ris8](https://www.youtube.com/watch?v=T0P6MC8Ris8)); *"Alugalug Cat X The Kiffness (Soulful Singing Cat **Live Looping** Remix)"* ([youtube.com/watch?v=kG2JvYSqGR4](https://www.youtube.com/watch?v=kG2JvYSqGR4)) | **High** — this is his channel's own chosen word, not a third party's description. This is the load-bearing fact this document rests on for "he does live looping," and it's why §2's generic model is the right thing to design against even without his exact rig. |
| Uses Akai gear generally | [louderthanwar.com](https://louderthanwar.com/the-kiffness-quirky-edm-genius-and-new-global-internet-sensation/), independent music journalism: *"his arsenal of AKAI samplers and various acoustic instruments"* | Medium — a real outlet, but a passing description, not a gear-rundown piece. |
| Specifically an Akai MPK mini 3 (compact pad/key MIDI controller) and AKG K361 BT headphones | [Audiosure](https://www.facebook.com/Audiosure/posts/we-often-see-the-kiffness-using-akai-professional-and-akg-gear-in-his-videos-and/10157718626822190/) — a South African audio-gear retailer's own promotional post | **Low-medium** — flagging explicitly: this reads as retailer/distributor promotional copy (plausibly a sponsorship or stocking relationship), not an interview with Scott himself. I'm including it because it's a specific, checkable claim, not because I trust it as much as the other rows. |
| Uses Melodyne Assistant, Native Instruments Massive, iZotope Ozone, Massey Tapehead, QuikQuak UpStereo, YMCK Magical 8bit | His own blog, [thekiffness.com, "6 Kiff Plugins"](https://www.thekiffness.com/2012/6-kiff-plugins-that-i-always-use-for-making-music) | **Historical only — the URL itself dates this post to 2012.** These are plugins usable inside any DAW; the post never names the host DAW. Fourteen years old, and I am not carrying it forward as "his current stack." |

### What I explicitly could not verify

- **Which DAW he uses** (Ableton Live, Logic Pro, FL Studio, Maschine, or something else) — no
  source I found states this.
- **Whether he uses a hardware loop pedal** (Boss RC-series or otherwise) or builds loops entirely
  in software.
- **Whether the on-camera "live looping" performance is one continuous unedited take**, or
  recorded in passes and edited together for the final video — this matters for design (a
  performer-facing tool has different UX pressure if a mistake can be cut in post vs. must be
  undone live), and I have no evidence either way.
- I found a YouTube playlist titled "Launchpad Performance" in search results but could not
  confirm it belongs to his channel — I am **not** citing it, on the same "unconfirmed ownership,
  don't assert it" basis.
- **I did not watch video content directly.** Every WebFetch attempt against a YouTube watch page
  in this session returned only the page's footer/legal boilerplate, not the description or
  transcript. Nothing in this document is a first-hand account of what happens frame-by-frame in
  any specific Kiffness video; every claim here is sourced to text (titles, articles, official
  manuals) as cited.

### Why this gap does not stall the design

The step-by-step workflow shape — sample or play a hook, loop it, layer bass then percussion then
harmony underneath while the first layer keeps playing, extend into a full arrangement — is not
something unique to his channel; it is the entire genre his own titles name. That shape is fully
and independently documented by the three systems built specifically to do it, covered next, and
building against *those* specifications is safer than reverse-engineering one artist's unconfirmed
rig.

---

## 2. The canonical live-looping models, compared

Three independent lineages, three different engineering teams, one converged vocabulary.

### 2.1 Hardware loop stations — Boss RC-505 / RC-505 mkII / RC-600

Read directly from Roland/Boss's own manual (RC-505 owner's manual, via
[ManualsLib](https://www.manualslib.com/manual/1638740/Boss-Rc-505.html?page=16), and the current
[RC-600 product page](https://www.boss.info/us/products/rc-600/)):

- **Loop length**: two modes, named in the manual. **AUTO** — *"the length of the first-recorded
  phrase will be the loop length"* — every subsequent track syncs to whatever the performer played
  first. **Manual** — the performer *"specifies the number of measures that will be looped"* in
  advance, and every track locks to that regardless of what's played. This is a direct, sourced
  answer to the "press-to-end vs fixed bars" question in §3.1.
- **Quantized launch, named "Loop Quantize"**: *"With tracks for which Loop Sync is 'ON,' ...
  your timing will be corrected (Loop Quantize) based on the tempo and time signature of the
  rhythm, even if the timing at which you press a button is slightly inaccurate."* The device
  corrects the performer's timing to the grid, not the other way around — this is the load-bearing
  design decision behind §3.2.
- **Track behavior**: RC-505 has multiple tracks that can play **MULTI** (simultaneously) or
  **SINGLE** (only the lowest-numbered SINGLE track of a group plays) — an explicit, hardware-level
  precedent for "these boxes are mutually exclusive, these boxes stack."
- **Undo**: *"undo/redo function allows you to undo/redo recording or the most recent
  overdubbing for the specified track."* One gesture, one layer.
- **RC-600 (six simultaneous stereo tracks, ~1.5 hr per track)** adds: **"Mark Back, which lets
  you instantly jump back to a previous loop state that you've flagged"** — a save-point *beyond*
  simple undo; **"three different overdub modes including one for replacing sound mid-loop"** —
  overdub and replace are named as siblings, not opposites requiring separate machinery; a
  **"Bounce In function for capturing multiple tracks into one"** — consolidating layers, directly
  relevant to how a finished live-looped piece would ever get exported/bounced; and, most directly
  relevant to the owner's own "buttons on trackpad" phrasing — **"nine freely assignable
  footswitches" organized into "three pedal modes."** A shipping commercial loop station's own
  physical control surface is a 3×3-shaped, mode-switchable grid of assignable triggers. This is
  the closest verified real-world precedent to the owner's own proposal, and it comes from
  hardware, not software.
- **What the performer presses**: physically, a footswitch — hands-free by design, because a
  looping performer's hands are usually occupied by an instrument.

### 2.2 Ableton Live: Session View, the Looper device, and Launchpad

From Ableton's own reference manual
([Launching Clips, v12](https://www.ableton.com/en/live-manual/12/launching-clips/); v11 mirror:
[live-manual/11/launching-clips](https://www.ableton.com/en/live-manual/11/launching-clips/)) and
[Sound On Sound's "Live Looping"](https://www.soundonsound.com/techniques/live-looping) technique
article:

- **Loop length**: for a clip recorded fresh into an empty Session slot, length is set by when the
  performer stops recording (of the two automated-fetch attempts I made against Ableton's own
  "Recording New Clips" page, the summarizer surfaced the *pattern-overdub* case — *"the new clip
  will default to a loop length of one bar"* under Global Quantization — but not the general
  free-record case in enough detail to quote verbatim; flagging that gap rather than papering over
  it). The **Looper device** (an audio effect, distinct from Session View clip slots) uses a
  "Set & Follow" tempo mode: *"if Live isn't already playing, recording would be referenced
  against the song's tempo... and the loop length would be determined by how long you recorded"* —
  i.e., press-to-end, but tempo-aware from the first press.
- **Quantized launch**: Global Quantization is a Control Bar setting (adjustable via
  Cmd/Ctrl+6…9, 0) that every clip launch obeys unless individually overridden to "None." Four
  **Launch Modes** govern what a press *means*, not just *when* it lands: **Trigger** (down starts,
  up ignored), **Gate** (down starts, up stops — momentary), **Toggle** (down starts, stops on
  next down), **Repeat** (retriggers at the clip's own quantization rate while held). **Legato
  Mode** is the specific mechanic for "switch to a different sequence without losing your place":
  *"When a clip in Legato Mode is launched, it takes over the play position from whatever clip was
  played in that track before"* — swapping bass loop A for bass loop B mid-bar continues from the
  same relative position rather than restarting, which is exactly the mechanic the owner's "switch
  instrument and play another sequence" ask needs.
- **Overdub / undo**: the Looper *"automatically switches to Overdub mode, and proceeds to record
  and layer up each pass"* after the first. Control is a single multipurpose button with layered
  gestures — the Sound On Sound piece is explicit: *"a quick double tap means Stop. In Play,
  holding the button for two seconds means Undo... which removes anything you recorded since you
  last entered Overdub mode."* One control, three meanings by gesture shape (tap / double-tap /
  hold) — not three controls.
- **Visual state without looking away**: widely and consistently documented across Ableton
  tutorials and forum knowledge (I could not extract the exact passage from Ableton's own Session
  View manual page via automated fetch — the same "client-rendered page, fetch returns only a
  summary" limitation the sibling trackpad-expression spike hit against developer.apple.com,
  flagged rather than papered over): clip slots pulse **green** while playing, pulse **red** while
  recording, and **flash** while queued-to-launch-on-the-next-quantize-boundary — a color/motion
  language, not text, readable in peripheral vision. **Novation's Launchpad** hardware controllers
  ([product page](https://www.ableton.com/en/products/controllers/launchpad/)) mirror this exact
  state set back in physical RGB LEDs under each pad specifically so a performer never has to look
  at the laptop screen.
- **What the performer presses**: a mouse click on a clip slot (studio use), or a hardware grid
  controller pad — Launchpad Mini/X/Pro — in "Session mode," which mirrors the on-screen grid 1:1.

### 2.3 Software loopers: Loopy Pro

From [Loopy Pro's own wiki](https://wiki.loopypro.com/Overdub) and manual
([loopypro.com/manual](https://loopypro.com/manual/)):

- **Loop length**: **Length Quantization** *"ensures that loop lengths are constrained to
  multiples or subdivisions of a bar"* — a tempo-locked-by-default posture, with an explicit
  **Count In / Count Out** quantization setting per clip.
- **Overdub vs. replace, unified as one parameter**: this is Loopy Pro's most interesting design
  choice and worth calling out on its own. **Overdub Feedback / Decay** is a single 0–100% control:
  at 100% (default) new material layers on top of the old; at 0% new material *"will completely
  replace the old audio"*; values between are a gradual decay/crossfade. Overdub and replace are
  not two separate modes requiring separate UI — they are two ends of one dial. **This is a pattern
  worth borrowing regardless of which option DAW Pro builds** (§6).
- **Undo of the last layer, named "Peel"**: *"Peel to remove the most recent overdub layer.
  Replace to re-place the most recently peeled layer,"* and the wiki is explicit that a performer
  can *"successively perform multiple peels"* — a multi-level undo stack scoped specifically to
  overdub passes, independent of any other undo history.
- **What the performer presses**: touchscreen taps and gestures — a **two-fingered tap on an
  existing clip** starts overdubbing while the loop keeps playing, distinguishing "start a new
  clip" from "layer onto this one" by *gesture shape*, not by a mode switch.

### 2.4 Comparison table

| | **Boss RC-505 / RC-600 (hardware)** | **Ableton Session View + Looper** | **Loopy Pro** |
|---|---|---|---|
| **How loop length is decided** | AUTO (first phrase sets it) or Manual (fixed bar count set in advance) | Free record (press-to-end, tempo-referenced) or fixed-length pattern-overdub (1 bar default) | Length Quantization: constrained to bar multiples/subdivisions by default |
| **How layering works** | Overdub is the default record-again behavior per track; RC-600 adds 3 overdub modes incl. mid-loop replace | Looper auto-enters Overdub after first pass; Session View layering = separate clips on separate tracks played together | Overdub Feedback/Decay dial: 100% = pure layer, 0% = pure replace, continuous between |
| **How launch is quantized** | Loop Quantize corrects button-press timing to tempo/time-signature grid | Global Quantization (Control Bar setting, per-clip override); 4 Launch Modes (Trigger/Gate/Toggle/Repeat) | Count In/Out quantization, configurable per clip |
| **Switching without losing place** | MULTI vs SINGLE track-group playback modes | Legato Mode — new clip inherits old clip's play position | Not separately verified in the sources read |
| **Undo of last layer** | Dedicated Undo/Redo (RC-600 adds Mark Back save-points) | Looper's Undo = "remove since last Overdub entry" | Peel/Replace, explicitly multi-level |
| **What the performer presses** | Footswitch(es) — RC-600: 9 assignable, in 3 banks | Mouse click, or a Launchpad grid pad in Session mode | Touchscreen tap / two-finger tap / gesture |
| **State feedback while playing** | Physical LEDs per track | Clip slot color/pulse language, mirrored on Launchpad LEDs | Touchscreen clip color/animation |

### 2.5 The convergent pattern

Three teams (Roland/Boss — hardware DSP engineers; Ableton — a DAW company; Loopy Pro — an
independent iOS developer), none building on each other's code, arrived at the same shape:

1. Loop length is decided **once, early**, and everything after inherits it.
2. Launch **always** quantizes to a musical grid — never to raw button-press timing.
3. Overdub is the *default* action of "record again"; replace is a variant of the same gesture,
   not a different one.
4. Undo is scoped to **one layer**, is a single, fast, low-effort gesture, and is separate from any
   general-purpose undo history.
5. State is communicated by **light/color**, not text, because the performer's eyes and hands are
   busy.

That convergence, not any one product's manual, is what §3 is built on.

---

## 3. The UX rules that make live looping work

### 3.1 How the first loop's length gets set

Three real options, all verified in §2, each with a real tradeoff:

- **Press-to-end** (Ableton free record, RC-505 AUTO): most flexible, zero setup — but for a
  non-musician with no metronome sense, an unquantized end point can land the loop boundary
  anywhere, and everything layered after inherits that off-grid length forever.
- **Fixed bars, chosen in advance** (RC-505 Manual mode, Loopy Pro's default Length Quantization):
  most forgiving for a beginner — you cannot pick a bad length, because you never picked a length
  at all, only a bar count. Costs a small amount of up-front decision ("how many bars").
  **This is the right default for DAW Pro's owner specifically** — no MIDI hardware, not a trained
  musician, exactly the profile the RC-505's own "beginner-safe" AUTO/Manual split was designed
  for, and DAW Pro already has the tempo grid this needs (`TempoMap`).
- **Tempo-locked from a project's existing markers**: since DAW Pro's projects already carry a
  `macro_song_skeleton` with key/tempo/section data (referenced in the roadmap's Playbox item,
  m23-da), the first loop's length could default to "one section's length" rather than an
  arbitrary bar count — a DAW Pro-specific refinement none of the three canonical products can
  offer, because none of them have a song-structure model to read from.

**Recommendation: fixed bars by default, editable**, not press-to-end — for this specific owner.

### 3.2 Quantized launch — why it is non-negotiable

Every canonical model enforces it (RC-505's Loop Quantize, Ableton's Global Quantization, Loopy
Pro's Count In/Out). The reason is arithmetic, not taste: a loop is, definitionally, a segment that
repeats forever. If a new layer starts even a few milliseconds off the existing loop's cycle
boundary, that offset does not average out — it **compounds every single repeat**, and after
enough cycles the new layer has audibly drifted out of the pocket relative to everything already
playing. A DAW's normal one-shot recording has no such failure mode (a clip a few ms late is just
a clip a few ms late); a *looping* recording's off-grid error is amplified by every future
repetition. This is why "wait for the bar line" cannot be an optional nicety here the way it might
be elsewhere in the app.

### 3.3 Overdub vs. replace

Loopy Pro's single Feedback/Decay dial (§2.3) is the cleanest solution found in this research and
is worth adopting as a design pattern regardless of which build option DAW Pro chooses: rather than
"overdub mode" and "replace mode" as two switches a beginner has to understand and remember to
flip, one control whose two ends are the two behaviors removes a decision entirely. RC-600's
"three overdub modes including replace" is the more conventional (multi-mode-switch) alternative,
included for completeness but not recommended over Loopy Pro's shape.

### 3.4 Undo of the last layer — the single most-used control

Every one of the three models gives this its own dedicated, low-effort gesture, separate from any
general undo history (RC-505/600 Undo/Redo + Mark Back; Ableton Looper's hold-2-seconds; Loopy
Pro's Peel, explicitly multi-level). The reasoning, stated plainly by the Sound On Sound piece and
implicit in all three: **a live performance has no "pause and reconsider."** A bad layer has to be
removable in the same amount of time it took to notice it was bad, without stopping the loop that's
still playing everything else.

**DAW Pro's own architecture already has an advantage here that none of the three canonical
products do**, and it's worth stating plainly: on the linear route (§4), each recorded layer is an
ordinary `Clip`, and this project already has a real `UndoJournal` with named, coalesced edit
groups (seen throughout `ProjectStore.swift`, e.g. `performEdit("Record Take N")`). "Undo the last
layer" on that route is not new machinery to build — it is the existing undo stack, and it is
*better* than tape-style hardware undo because it is not scoped to "since you last entered
overdub," it is a real, inspectable history the performer could in principle step arbitrarily far
back through. The thing DAW Pro does *not* have yet is the fast, low-effort, **hands-on-the-grid**
gesture to trigger it without reaching for ⌘Z or a menu — that's a UI question, not an engine one.

### 3.5 Count-in

None of the three canonical products treat this as optional, and DAW Pro already has direct,
measured evidence for why it matters: the ROADMAP's own m23-ct close record states that in
Musical Typing, **"a note played in the first ~70–300 ms after `transport.record` is DROPPED, by
design"** because the take's `PlaybackAnchor` is scheduled slightly ahead of `startTake`, and the
fix "needs a transport-clock read this strip specifically does not have." That is precisely the
count-in problem every hardware looper solves with a lit/audible pre-roll: **a performer who starts
playing the instant they arm record loses the first notes, with no visible cause.** For a
non-musician stacking loop layers, hitting the same wall on layer 3 of 6 would be far more
confusing than on a single ordinary take, because the loop is *already playing* everything else —
a dropped downbeat on the new layer will sound wrong against a loop that didn't wait for it. This
makes a count-in a harder requirement for live looping than it was for Musical Typing alone, and
the existing gap is a real, named blocker worth closing before or alongside this feature, not
after.

### 3.6 Knowing what's armed/recording/playing without looking away from your hands

The convergent answer across every product in §2 is **color and motion, not text**: playing pulses
one color, recording pulses another, queued-to-launch flashes, and — per Loopy Pro's and Ableton's
own vocabulary in §2 — the *shape* of a gesture (tap vs. double-tap vs. hold; single-finger vs.
two-finger) carries meaning the way a footswitch's *number of taps* does on hardware. This maps
directly onto the owner's own requirement, "show assignment on the screen," and onto §5's finding
that the 9-box trackpad grid needs *state*, not force.

---

## 4. The architectural question, answered honestly

### 4.1 The ask splits into two questions with different costs — this is the load-bearing finding of this section

Re-reading the owner's sentence carefully: *"put them into loop and assign to the buttons on
trackpad ... and then allows to switch instrument and play another sequence of matching chords."*
That is actually two different capabilities wearing one sentence:

- **(a) "Fire or silence a layer that already exists."** Once a chord loop is recorded onto a
  track, turning it on or off (so a button on the grid toggles whether that layer is currently
  contributing to the mix) is, by this engine's own design, **close to free**. Verified directly:
  `PlaybackGraph.ClipKey`'s own doc comment states outright that *"Parameter fields (volume, pan,
  mute, solo, name — and clip GAIN...) are deliberately NOT part of the signature — changing them
  must never trigger a stop-reschedule-resume"* (`Sources/DAWEngine/PlaybackGraph.swift:28-31`).
  Muting/unmuting a track (or, with a small addition, an individual clip) is a live write that
  does not touch scheduling at all. Add "wait for the next bar line" and this is a **quantized
  mute toggle** — new, but small, and it needs no session view, no new playback model, and no
  restart risk.
- **(b) "Choose between two alternative recorded sequences for the same slot, live."** This is
  what "play **another** sequence of matching chords" actually asks for — not "turn this one on,"
  but "which of several pre-recorded options is currently sounding here." That needs a real
  clip-launch primitive: something has to decide, at the moment of the button press, which of N
  candidate clips is the one currently scheduled for that track/slot. **This does not exist in
  DAW Pro today in any form** — confirmed by the measurements below.

Conflating (a) and (b) is the trap the roadmap's own m23-db entry already warns about ("anyone who
reads 'we already have loop recording' as 'this is nearly done' will build the wrong feature") —
and it cuts the other way too: reading the *whole* ask as needing a launch primitive, when half of
it is already a live write, would overbuild.

### 4.2 What is measured, directly, about the linear route's real cost

Three things I verified by reading the code, not by inference from documentation:

1. **A structural clip change rides the same "stop-reschedule-resume" restart seam mute/volume
   deliberately avoid.** `ClipKey` and `MIDIClipKey` are the literal signature `PlaybackGraph` diffs
   against per track (`track.clips.map { ClipKey(...) }`, `PlaybackGraph.swift:798`); the doc
   comments state plainly that fades, offsets, and (for MIDI) *any note edit* — *"the WHOLE notes
   array is in the key... any note edit flips the signature and reschedules through the existing
   `tracksDidChange` restart"* (`PlaybackGraph.swift:200-203`) — ride this restart. **A brand-new
   clip landing on a track is, by the same logic, a signature change** (the clip array gains an
   entry), so it rides the identical seam. What I did **not** verify is whether that reschedule is
   audibly seamless for the *other*, already-playing layers, or causes even a brief interruption —
   the doc comment's own word for the mechanism is *"stop-reschedule-resume,"* which is concerning
   language for "the loop must never stop." **This is the single most important thing an
   implementing agent must measure before writing any UI against it** — not assume either way.
2. **Recording a new take today is coupled to stopping the whole transport, at least at the one
   call site I found.** `ProjectStore`'s general stop path shows `wasRecording` handling with the
   comment *"stopRecording halts playback internally AND finalizes the take — calling
   stopPlayback here would tear the transport down twice"* (`ProjectStore.swift:728-740`) — i.e.,
   ending a take and stopping playback are one action there. If that is the *only* way a take ever
   finishes, then "finish recording layer 3, keep the loop rolling, arm layer 4" cannot work
   without new plumbing — the transport would stop between every layer, which is exactly the "the
   music never stops" law every canonical model in §2 depends on.
3. **But there is a real, already-built precedent for the opposite** — capturing audio into a take
   for a *bounded window without stopping playback* — and it's punch recording, not loop recording.
   `startTakeBody` computes the punch-out point as a **host-time-scheduled end** on the capture
   writer's accept window: *"the endHost = anchor.anchorHostTime + ...seconds(from: positionBeats,
   to: transport.punchOutBeat)"*, then `writer.setAcceptWindow(reference:start:end:)`
   (`AudioEngine.swift:3480-3497`). That is a capture cutoff computed and scheduled *in advance*,
   independent of any user pressing stop. **I did not trace far enough to confirm whether the
   take's `completion`/`finishTake` callback fires automatically when that window closes while
   `transport.isPlaying` stays `true`**, or whether it still requires an explicit stop call
   downstream — flagging this explicitly as the first thing to verify, because if it already works,
   most of point 2's blocker may already be solved by a mechanism nobody built for this purpose.
4. **The loop-record path has a trap that would waste real time if triggered by accident.**
   `ProjectStore.record()`'s own doc comment: *"With a loop enabled, record ALWAYS loop-records...
   or refuses — never a silent linear roll"* and *"lane per loop pass — newest lane comped"*
   (`ProjectStore.swift:942-946, 962-965`). This is `LoopTakeWindow`'s comping-takes mechanism
   (§ established in the prompt) — if Phase 1 capture uses `transport.setLoop` + `record()` for a
   one-cycle layer and the performer doesn't explicitly end the take before the transport wraps a
   second time, the **same** track starts comping alternate takes of *one* part rather than landing
   a second independent layer. A take that stops before reaching cycle 2 *"degrades to EXACTLY the
   linear landing"* (`ProjectStore.swift:1225-1226`) — so the safe design is: capture exactly one
   pass, auto-finish before the wrap, never let a layer-take see a second loop cycle. This is a
   real, specific constraint on Phase 1's capture logic, not a hypothetical.
5. **One positive precedent for "loops don't have to restart everything to keep going":** loop
   *playback* (not recording) already has a non-disruptive wrap path — `AudioEngine`'s
   all-notes-off/flush contract explicitly carves out an exception: *"A LOOP WRAP does NOT route
   through here any more (m14-a L-1): the wrap is pre-queued cycles on rolling [players]"*
   (`PlaybackGraph.swift:3258-3259`). The engine already knows how to keep a loop's *existing*
   content playing smoothly across the cycle boundary without a hard stop. The open question is
   narrower than "can loops play smoothly" (yes, solved) — it's "can a *new* clip join an
   already-looping, already-playing project without disturbing what's already sounding" (not yet
   measured).

### 4.3 The linear route

**What it is**: a loop region set on the timeline (reusing `transport.setLoop`); the performer arms
a track (`track.setArm`, confirmed as the real command name, `Commands.swift:380`), records one
pass, the transport keeps looping, they arm a *different* track and record the next layer on top.
Each layer is an ordinary `Clip` on an ordinary `Track`. Switching "which sequence plays" means
literally recording over or replacing what's on a track — there is no alternate held in reserve to
flip to instantly.

**What it delivers**: the *stacking* half of the Kiffness workflow, faithfully — this is
genuinely how loop-based songs get built, per every source in §2. Combined with §4.1(a)'s
near-free quantized mute, a performer can also drop layers in and out live once they exist.

**What it cannot do, named specifically, per the owner's own words**: "play another sequence of
matching chords" *on demand, live, choosing between pre-recorded options* — the (b) case from
§4.1. On the linear route, if you want a different bass loop, you have to stop using the current
one and record a new one over it (destroying the old one) or onto a new track (using up a track
slot per alternative, with no way to switch between them faster than muting one and unmuting
another — which is (a), not (b), and can't offer "the next chord section" reacting to a live
choice). It looks like the Kiffness workflow for as long as a performance is purely additive; it
stops looking like it the moment the ask is "give me a different option for this same part."

### 4.4 The Session View route — sizing

**What would have to change, concretely, starting from what's measured today:**

- **A clip-launch primitive independent of `startBeat`.** `PlaybackGraph.ClipKey` includes
  `startBeat` as part of its schedule-affecting identity (`PlaybackGraph.swift:37-39`) — clip
  playback is *derived from* timeline position by construction. A launchable clip needs to be
  playable starting *now*, at whatever beat the transport happens to be at, which is a genuinely
  different scheduling question than "where on the timeline does this sit."
  Confirmed zero-file measurements from the roadmap's own audit (re-verified by me via the same
  grep pattern): `sessionView`, `sceneLaunch`, `clipLaunch`, `launchClip` = 0 files each.
- **A concept of "slot"** (which track/lane a set of alternative clips belongs to) that is
  independent of a single `Clip`'s timeline placement — this is a new `DAWCore` model type, not a
  view-layer add.
- **Launch quantization as a first-class scheduling concept** — deciding "the next bar line," then
  holding a launch request until it arrives, is new transport/engine logic; nothing in the current
  transport model queues an *intent* against a future beat boundary the way Ableton's Global
  Quantization or Boss's Loop Quantize do.
- **Overdub, as a concept distinct from take-comping**, per the prompt's own framing —
  `LoopTakeWindow` exists and does the *opposite* thing (multiple attempts at the same part,
  compete for "best take"), and reusing it under a new name would ship the wrong feature.

**This is a real, multi-week architectural addition** touching `DAWCore` (new model types),
`DAWEngine`/`PlaybackGraph` (a genuinely new scheduling primitive sitting beside, not replacing,
timeline-position scheduling), the control protocol, and the MCP surface — sized **Large**, in this
project's own vocabulary, and squarely a `daw-architect` design question before any implementation
agent touches it.

### 4.5 Verdict

**Build the linear route first (§4.3), but build its capture path so it produces the primitive
§4.2 already shows is required regardless: a clip that can land during uninterrupted playback,
and a take that can finish without stopping the transport.** That work is not a detour from the
Session View route — it is a strict subset of what the Session View route also needs, so
sequencing linear-first does not throw work away. What it *does* forecloses, honestly: the
Session View route's actual novel piece — an alternates-per-slot launch primitive that lets a
performer choose between pre-recorded options live — is not delivered by the linear route at any
scale, and no amount of polish on top of it produces that capability. If "switch to a different
matching sequence, live" turns out to be the feature the owner actually wants most (rather than
"build up one arrangement, layer by layer"), that is §4.4's work, not an extension of §4.3's.

---

## 5. Does clip launching need velocity?

**No — confirmed, not merely assumed, across all three independent canonical models:**

- **Boss RC-505/RC-600**: the physical control is a footswitch. A footswitch reports on/off; it
  has no force-sensing element in any Boss documentation I found. The *number and pattern* of
  presses (tap vs. hold vs. double-tap) carries meaning, not how hard the stomp was.
- **Loopy Pro**: touch gestures are distinguished by **shape** — one-finger tap vs. two-finger tap
  vs. hold — not by force. Nothing in the wiki pages read describes a pressure-sensitive dimension
  to any looper gesture.
- **Ableton + Launchpad**: this is the one case with a genuine nuance, and it's worth stating
  precisely rather than flattening it. Launchpad X and Pro *do* ship velocity- and
  pressure/aftertouch-sensitive pads (confirmed via Novation's own product pages) — **but that
  sensitivity is spent on Note mode** (playing an instrument chromatically), one of the controller's
  several distinct modes. Session mode — the clip-launch grid — is a boolean press per the
  documented Launch Modes (Trigger/Gate/Toggle/Repeat, §2.2), none of which reference press force.
  Separately, Ableton does have an optional, **off-by-default** "Velocity" setting in a clip's
  Launch Settings that can scale playback volume when a clip is triggered by an actual MIDI note
  carrying real velocity data (e.g., a keyboard mapped to fire clips) — I found this via search
  synthesis and was not able to independently re-confirm the exact manual passage in this session,
  so treat it as **probable but not directly verified by me**. Even taking it at face value: it is
  an optional bonus for one specific trigger method, absent entirely from the footswitch and
  touchscreen models, and is not how a Launchpad's own Session-mode pad press behaves. **It does
  not change the finding**: the launch *decision* — which clip starts, when — is velocity-
  independent everywhere this was checked.

**This confirms, independently, the same conclusion the roadmap's own m23-db entry already
reached from the owner's side of the conversation** ("clip launching does not need velocity, so
the 9-box grid's documented weakness vanishes in exactly this use") — worth stating as confirmed
rather than merely asserted, since the brief specifically asked this be checked rather than
assumed.

**What the grid needs instead, per §3.6 and the owner's own "show assignment on the screen"**:
**state**, mirrored live, per box:

| State | Meaning | Visual language used by the canonical models (§2) |
|---|---|---|
| Empty | Nothing assigned to this slot | Dim/unlit |
| Armed | Assigned, will record on next press | Dim red (Ableton convention) |
| Recording | Currently capturing this layer | Pulsing red |
| Playing | This layer is currently sounding | Pulsing green |
| Queued | Requested, waiting for the next quantize boundary | Flashing (fast blink) — **this state matters more here than anywhere else**, because §3.2 established that launch is *always* quantized, and a press that visibly does nothing until the bar line would read as a failed or ignored press and invite the performer to press again, double-firing. The queued state is the UI's answer to "I pressed it, it's working, wait for it." |
| Muted | Assigned and has content, deliberately silenced | Dim, distinct hue from empty |

This is a small, concrete design requirement that connects §3's UX rules directly to the owner's
own stated requirement, and it should be scoped alongside whichever build option ships (§6) rather
than treated as a nice-to-have layered on after.

---

## 6. A concrete proposal for DAW Pro

Four options differing on one axis: **how much of the timeline model gets abandoned.**

| | **A. Pure linear** | **B. Linear + quantized layer mute** | **C. Linear + minimal launch primitive** | **D. Full session grid** |
|---|---|---|---|---|
| **What the performer does** | Arm a track, record a loop pass, arm the next track, repeat. Grid buttons **navigate/select** tracks — a shortcut into existing arm/record, nothing more. | Same, plus: once a layer exists, grid buttons **toggle it audible**, quantized to the bar. This is RC-505's MULTI-track behavior, reimplemented as mute rather than as separate playback slots. | Same as B, plus: a track can hold 2–3 **alternative** pre-recorded clips for one slot, and a grid button switches which one is currently sounding, quantized, Legato-style (continues position rather than restarting). | Full Ableton-style: any track × any scene, clip slots fully decoupled from timeline position, Follow Actions, the works. |
| **What we build** | UI wiring only: grid ↔ existing `track.setArm`/`transport.record` commands. **No new engine work beyond what §4.2 already flags as a shared need** (a take that can finish without stopping the transport, per §4.2 point 2/3). | A's engine work, plus: a new **quantized mute** primitive — hold a mute-toggle intent until the next bar line, then apply it as the existing live-write (`ClipKey`'s doc comment already says mute doesn't touch scheduling, §4.1) — small, and grid state per §5's table. | B's work, plus: the **alternates-per-slot + launch** primitive from §4.4 — new `DAWCore` model type, new engine scheduling path independent of `startBeat`. This is the point where the project stops being purely-linear. | Everything in §4.4, at full scope: scenes, Follow Actions, cross-track scene launch. |
| **Cost (this project's sizing vocabulary)** | **S** | **S–M** | **L** | **XL** |
| **Forecloses** | "Switch between alternatives live" (§4.1(b)) — permanently, on this option alone. | Same as A — muting an existing layer is not choosing between two different ones. | Nothing named in this document — this is the smallest option that actually satisfies the owner's full sentence. | Nothing — but at a cost this milestone has not earned yet (no session-view need has been validated by use, per this project's own M32 pattern of "measure before building the large version"). |
| **Answers the owner's ask** | Half — the "stack layers" half, not the "switch to another sequence" half. | Half, better — adds live on/off control per layer, closer to a real performance instrument, still not "alternatives." | **Fully**, at the scale of "one slot, a few named alternatives" rather than Ableton's unlimited scenes — matches what a 9-box grid can physically represent anyway. | Fully, at a scale the 9-box grid cannot represent 1:1 without paging/banking (RC-600's own answer to this: 3 banks of 9). |

### Recommendation

**Ship Option B first, with its capture path built to already satisfy §4.2's shared requirement**
(a layer that can be recorded and finalized without stopping the transport) **— that is the
genuinely shippable Phase 1.** It delivers the owner's "record chords on the fly, put them into a
loop, assign to buttons, show assignment on screen" almost verbatim: record a layer, it lands on a
grid button, the button's light shows its state, pressing it live-mutes/unmutes on the beat. It
does **not** yet deliver "play another sequence" — that's honestly Option C, and this document's
recommendation is to **build B, use it, and let real use (per this project's own established
"listening feedback" pattern — ship options, let the owner's reaction be the next spec) decide
whether C's added cost is worth it**, rather than committing to C's larger build before anyone has
played with B.

### Wire / MCP surface (every capability needs a command + tool + test, per this project's law)

For **Option B**, concretely, using the existing `domain.verb` naming convention seen throughout
`Commands.swift`:

| New/extended surface | Purpose |
|---|---|
| `loop.captureLayer` (control command) + matching MCP tool | Arm a track, record exactly one loop cycle, auto-finish without stopping the transport — the Phase-1 capture primitive from §4.2. Needs a `DAWEngine`-level change (or a confirmed reuse of the punch accept-window mechanism, §4.2 point 3) before this can be a thin wrapper. |
| `clip.setMutedQuantized` (or an extension of the existing mute path with a `quantize: Bool` field) + MCP tool | The quantized-mute toggle from Option B — holds a mute-intent until the next bar line rather than applying immediately. |
| `grid.assign` / `grid.query` (new small command family) + MCP tool | Associates a track/clip with one of the 9 trackpad boxes, and reports the state table from §5 (empty/armed/recording/playing/queued/muted) for the app to render — this is the wire-level answer to "show assignment on the screen," and it needs to be **queryable**, not just settable, so an agent (or a rebuilt UI) can always ask "what's on box 4 right now." |
| Tests | `DAWCore` unit tests for the quantize-to-next-bar arithmetic (pure, deterministic, per this project's testing law — same shape as the trackpad spike's recommended pressure-mapping test); an engine-level test proving a captured layer lands as an ordinary, undo-visible `Clip` without a transport stop; a live/staging probe (per this project's `debug.*` pattern) proving grid state matches actual playback state, not merely the last command sent — this project's own history (§ "check the record, not the echo") makes an un-cross-checked status report a known failure shape here. |

Option C would additionally need a `scene`/`slot`-shaped command family (`slot.launchClip` or
similar) once §4.4's model type exists — deliberately not specified further here, since it depends
on a `daw-architect` design pass this document is not positioned to substitute for.

---

## 7. Actionable takeaways

1. **(Measure first, blocks Option B's scoping — route: `daw-architect`/`audio-dsp-engineer`, a
   measurement task not a build)** Resolve the two open engine questions named in §4.2 and the
   Could-not-verify list before committing to Option B's design: (i) does `finishTake`'s
   completion fire, ending a take, while `transport.isPlaying` stays `true` — trace the punch
   accept-window path (`AudioEngine.swift:3480-3497`) all the way through; (ii) is landing a new
   clip during active playback (the `tracksDidChange` restart seam, `PlaybackGraph.swift:28-31,
   200-203`) audibly seamless for the other, already-playing layers, or does it produce a click or
   gap. Both are empirical questions this document could not answer by reading alone.
2. **(Phase 1, shippable, per §6's recommendation)** Build Option B: quantized layer mute on top
   of the existing arm/record path, plus the capture primitive from #1. Concretely:
   `loop.captureLayer`, `clip.setMutedQuantized` (or a `quantize` field on the existing mute path),
   and `grid.assign`/`grid.query` — each with a control command, an MCP tool, and a test, per this
   project's standing law. Route: `daw-architect` for the primitive from #1, then
   `mcp-integration-engineer` for the wire/MCP surface, `swift-app-engineer`/`ui-design-engineer`
   for the grid UI.
3. **(Shared prerequisite, not specific to live looping but sharper here)** Close the count-in gap
   named in m23-ct — the measured 70–300 ms note-drop after `transport.record` — before or
   alongside Phase 1. §3.5 argues this is a *harder* requirement for live looping than for Musical
   Typing alone: a dropped downbeat on layer 3 sounds wrong against a loop that already committed
   to a tempo, in a way a single ordinary take's dropped note does not.
4. **(Direct UI-spec input for the roadmap's m23-cz Mode B grid, so it isn't designed twice)** Use
   the six-state table in §5 (empty / armed / recording / playing / queued / muted) as the grid's
   visual-state contract, with the **queued** state treated as load-bearing, not optional — §3.2's
   quantized-launch rule makes an unacknowledged queued press read as a failure and invites a
   double-fire.
5. **(Design pattern worth adopting whenever overdub-vs-replace ships, independent of which option
   is chosen)** Loopy Pro's single Feedback/Decay dial (§2.3, §3.3) — one continuous control
   spanning pure-overdub to pure-replace — is simpler for a non-musician than two separate modes
   and is worth the small design detour to build it this way from the start.
6. **(Deliberately deferred, not rejected)** Option C (the alternates-per-slot launch primitive) —
   per this project's own "ship options, the owner's pick is the spec" pattern, do not commit to
   C's Large-sized build until Option B has actually been used and the owner has said whether
   "switch to a different sequence live" is a gap they feel in practice.

---

## Could not verify — stated explicitly rather than guessed

- **The Kiffness's DAW, controller, or whether he uses a hardware loop pedal.** No source found.
  See §1.
- **Whether his "live looping" videos are single unedited takes or edited from multiple passes.**
  No source found.
- **The exact wording of Ableton's manual on free-record loop-length determination and on the
  Session View clip-slot color/state language.** Both pages returned only partial or summarized
  content to automated fetch in this session (the same "client-rendered page" limitation the
  sibling trackpad-expression spike documented against developer.apple.com); the color/state
  claims are carried forward from consistent secondary-source synthesis, not a direct manual quote.
- **Whether Ableton's clip-launch "Velocity" Launch Setting is accurately described** — found via
  search synthesis, not independently re-confirmed against the primary manual page in this
  session. Treated as probable, flagged as unconfirmed, in §5.
- **Whether `finishTake`'s completion callback can fire, ending a take, while `transport.isPlaying`
  stays `true`** — I traced the punch-recording accept-window mechanism
  (`AudioEngine.swift:3480-3497`) far enough to see it schedules a capture cutoff independent of a
  stop button press, but not far enough to confirm the completion path doesn't still require an
  explicit stop call downstream. This is the single most important open question for whoever scopes
  Option B's `loop.captureLayer` primitive — see §4.2 point 3.
- **Whether landing a new clip during active playback (the `tracksDidChange` restart seam) is
  audibly seamless for the other, already-playing layers, or causes a brief interruption.** I
  confirmed the seam exists and that a new clip's presence is schedule-affecting by the code's own
  definition; I did not confirm what the reschedule sounds like. See §4.2 point 1 — flagged as the
  first thing to measure, not assume, before Option B's UI is built against it.
