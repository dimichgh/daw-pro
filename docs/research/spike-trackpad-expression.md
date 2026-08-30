# Spike: trackpad expression — Force Touch pressure and multitouch as a performance controller

Author: research-analyst. Date: 2026-08-30. Status: research only, no code touched.

Prompted by the project owner's idea: use the trackpad the way a whammy bar modulates a struck
guitar note, applied to continuously modulating a *sustained* note (sax breath dynamics
especially), and more generally explore the trackpad's pressure and surface area as an instrument
— clicks, varying pressure, position, multi-point contact.

---

## 0. Summary and recommendation

**The trackpad can do real, publicly-supported continuous expression — but two things the idea
sketch assumes turn out not to hold, and both change the shape of what to build.**

1. **Reading the trackpad's raw surface (multiple simultaneous finger positions) and reading
   pressure are, on public API, mutually exclusive.** `NSTouch` — the API that reports finger
   *positions*, including several at once — carries no force/pressure field at all (confirmed
   against Apple's own property listing, §1.2). Pressure (`NSEvent.pressure`/`stage`) is only ever
   delivered attached to the *one* physical contact currently driving a mouse click. So "clicking
   in different places at the same time, each with its own pressure" (the owner's own phrasing) is
   not buildable on the API Apple documents; you get many positions with no force, or one
   position's force with no others.
2. **DAW Pro already shipped the right shape of control for this.** `BreathPadView` /
   `BreathPadModel` (commits `89fb239`, `82dacac`, `412cb33`) is already "a circle you drag" whose
   angle and radius stream a live effort value into the sampler through
   `pad.previewEffort`/`pad_preview_effort`. Force Touch pressure is a **third axis that drops
   into an existing, working, zero-permission control** — not a new input surface. That is by far
   the cheapest, lowest-risk version of this idea, and it needs no solution to the trackpad's hard
   problem at all, because a mouse-down already legitimately owns the pointer (§2.3).
3. **The genuinely hard version — reading the trackpad as its own surface, independent of the
   pointer, for real multitouch — is solvable on public API but is a capture-mode feature with
   real failure modes** (a strandable system cursor; system gestures that can eject the user from
   the app mid-performance). It should be scoped and shipped separately, not bundled with (2).
4. **One assumption in the brief does not hold and is corrected here, not papered over**: the
   pad's *existing* live-stream endpoint (`pad.previewEffort`) is explicitly preview-only —
   its own description says "nothing is written to any clip, nothing is recorded" (Commands.swift
   ~5445, server.ts ~2293). `MIDICaptureSession` really does ingest `controlChange`/`pitchBend`/
   `channelPressure` automatically (MIDICaptureSession.swift:164–172; §6.1), but only for events
   that reach it through a live **performance** path (the way Musical Typing's notes do, via
   `LiveNoteSink` → `ProjectStore.playLiveNotes`). Trackpad pressure streamed through today's pad
   endpoint would **not** be captured into a take without a new, parallel seam for continuous
   controllers. See §6.2 — this is the single most load-bearing correction in this document.

**Recommendation: ship Option 1 (§5) first** — pressure added to the existing breath pad, driving
the same effort/CC pipeline P1–P6 already built, wired through a *new* live-performance seam
(§6.2) so it actually gets recorded. Treat true multitouch (Option 4) as a distinct, later,
separately-scoped idea.

---

## 1. What can a macOS app actually read from a Force Touch trackpad?

The calling agent already confirmed the hardware: `ioreg -c AppleMultitouchDevice` on this machine
reports `"ForceSupported" = Yes`, and `defaults read com.apple.AppleMultitouchTrackpad` shows
`ForceSuppressed = 0`, `ActuateDetents = 1`. That is a shell-level/`ioreg` measurement, not
something an app can query at runtime through a documented API — see §1.5 for why that distinction
matters for the wire surface.

### 1.1 Pressure: `NSEvent.pressure` / `.stage` / `.stageTransition`

Confirmed directly from Apple's own `NSEvent.h` header (public SDK, doc comments quoted verbatim;
fetched via the `phracker/MacOSX-SDKs` mirror of Apple's shipped headers since
`developer.apple.com`'s DocC pages did not return readable content to automated fetches — see the
"could not verify" list at the end):

```
/* -pressure is valid for all mouse down/up/drag events, and is also valid for
NSEventTypeTabletPoint events on 10.4 or later and NSEventTypePressure on 10.10.3 or later */

/* stage: valid for NSEventTypePressure events. Pressure gesture events go through multiple
stages. */

/* stageTransition: valid for NSEventTypePressure events. Positive stageTransition describes
approaching the next stage of the pressure gesture. Negative stageTransition describes approaching
release of the current stage. */
```

- **`pressure: Float`, range 0.0...1.0.** Confirmed by the WWDC 2015 "Adopting New Trackpad
  Features" transcript ("pressure range: 0 to 1, representing the pressure of the current stage")
  and independently by a developer blog on receiving Force Touch events
  ([Eternal Storms Software](https://blog.eternalstorms.at/2015/10/24/how-to-receive-force-touch-events-from-an-nstableview/)).
  A secondary source suggested values could exceed 1.0; tracing it, that claim comes from an
  unrelated JavaScript/WebKit polyfill package's internal 1–3 scale, not from `NSEvent` itself —
  I am not carrying that claim forward. Treat pressure as 0...1.
- **`stage: Int`, values 0/1/2** — 0 before contact, 1 at click level, 2 at "force click" level —
  delivered on `NSEventType.pressure` events, which reach a view's
  `pressureChange(with:)` override (or `NSGestureRecognizer.pressureChange(with:)`).
- **When it's delivered**: attached to ordinary mouse down/drag/up events *and* to dedicated
  pressure-change events, all tied to the one physical contact that is driving the click. It does
  **not** arrive independent of a click.

### 1.2 `NSPressureConfiguration` / `NSEvent.PressureBehavior` — this decides the *feel*, and it matters for music

`NSPressureConfiguration` is attached to an `NSView` or `NSGestureRecognizer` **before** `mouseDown`
so "the system will go ahead and set up the trackpad before mouse down even occurs" (WWDC 2015
session 217,
[transcript](https://asciiwwdc.com/2015/sessions/217)). The full case list, quoted verbatim from
Apple's own header comments (`NSEvent.h`, same source as §1.1):

| Case | Stages | Actuation (haptic click) | Doc comment |
|---|---|---|---|
| `.primaryClick` | 1 | mouseDown, mouseUp | "Variable pressure with a **small** dynamic range after mouseDown." |
| `.primaryGeneric` | 1 | mouseDown, mouseUp | "Variable pressure with a **large** dynamic range after mouseDown suitable for **drawing and general pressure use**." |
| `.primaryAccelerator` | 1 | mouseDown, mouseUp | "Variable pressure after mouseDown suitable for **controlling speed**. Used by `NSAcceleratorButton`." |
| `.primaryDeepClick` (**system default**) | 2 | mouseDown, mouseUp, **1→2, 2→1** | "Toggle between stages 1 and 2 until drag or mouse up (e.g. Force Click)." Stage 2 disabled once dragging starts. |
| `.primaryDeepDrag` | 2 | mouseDown, mouseUp, **1→2, 2→1** | "Toggle between stages 1 and 2 until mouse up (e.g. Force Click)." Stage 2 stays live through a drag. |

**This is a real, concrete finding, not a footnote**: the system default (`.primaryDeepClick`) is
a **2-stage, actuated** behavior — crossing into stage 2 fires the Force Click haptic "thunk."
That is exactly wrong for a continuous musical gesture: a physical click transient firing mid-note
because the player leaned in a little harder would read as a mixing artifact, not an expressive
gesture. **`.primaryGeneric`** — one stage, no actuation, full 0...1 dynamic range, and explicitly
called out by Apple as the one to use for drawing — is the correct configuration for any
DAW Pro control that maps pressure to a continuous parameter. This is a one-line, low-risk,
citable design decision.

### 1.3 Multitouch position: `NSTouch`

Confirmed from Apple's own DocC JSON (a genuine fetch of Apple's own generated documentation
data, unlike the HTML pages that returned only a title — see the "could not verify" list):

| Property | Type | Meaning |
|---|---|---|
| `identity` | `NSCopying & NSObjectProtocol` | Stable identifier for one physical touch across its whole `began → moved → ended` lifetime — this is how you track "finger 2" frame to frame. |
| `phase` | `NSTouch.Phase` | The touch's current phase. |
| `normalizedPosition` | `NSPoint` | Position on the device surface, normalized 0...1 in both axes. |
| `type` | `NSTouch.TouchType` | Direct vs. indirect (see §1.4). |
| `device` | `Any?` | The originating digitizer — distinguishes multiple simultaneous devices. |
| `deviceSize` | `NSSize` | The physical surface size, in points. |
| `isResting` | `Bool` | True for a touch present but not actively driving anything (see `wantsRestingTouches`, §1.4). |
| `location(in:)` / `previousLocation(in:)` | `NSPoint` | Convenience: the touch mapped into a given view's coordinate space. |

**`NSTouch` has no pressure/force field.** That is the load-bearing negative result of this whole
research spike: I fetched Apple's own property listing for the type, and force/pressure is simply
absent from it. Combined with §1.1 (pressure only ever arrives attached to a mouse-down/drag), the
conclusion is structural, not an oversight in my search: **on documented public API, you can have
several simultaneous finger positions (via `NSTouch`), or you can have one finger's force (via
`NSEvent.pressure`, tied to the click), but not several fingers' force at once.** Any design that
assumes per-finger pressure — a Seaboard/Continuum-style surface, or "clicking in different places
with different pressure" as literally described — is not buildable this way.

Also directly relevant, and it explains a mechanic used in §2: Apple's own documentation states
**"the first touch latches to the view under the cursor; additional touches on the same device
latch to the same view."** Touch routing follows wherever the pointer is currently hovering — a
fact that matters for the capture-mode design in §2.3.

### 1.4 Getting `NSTouch` events at all: `allowedTouchTypes`

Confirmed from Apple's own `NSView.h` header comment (same SDK-mirror method as §1.1/§1.2):

> `allowedTouchTypes` "Defaults to `NSTouchTypeDirect` if linked on or after 10_12, 0 otherwise."

On any current build target that default is effectively **"receives no touches at all."** A view
must explicitly opt in with `.indirect` (trackpad touches are indirect — they are not on a
display) to receive anything, by setting `view.allowedTouchTypes = [.indirect]` and overriding the
`NSResponder` methods `touchesBegan(with:)`, `touchesMoved(with:)`, `touchesEnded(with:)`,
`touchesCancelled(with:)`. Additionally, `wantsRestingTouches = true` is required to be told about
a touch that's present but not moving — otherwise "by default, these touches are not delivered and
are not included in the event's set of touches" (same header). This exact pattern —
`allowedTouchTypes = [.indirect]` + `wantsRestingTouches = true` + the four responder overrides —
is also what a real, working open-source demo uses
([shaunlebron/macos-trackpad-demo](https://github.com/shaunlebron/macos-trackpad-demo)), which
cross-checks the header text against actual shipped code. Within those overrides (or off any
event directly), individual touches are pulled out with `NSEvent.touches(matching:in:)` — e.g.
`event.touches(matching: .touching, in: self)` — which is the exact call the same demo project's
`touchesBegan` handler uses to read the current set.

### 1.5 Resolution and update rate — not documented; here is what's actually knowable

**Apple does not publish a resolution or update-rate spec for `NSTouch`/pressure delivery** in any
source I could reach. What exists is anecdotal and inconsistent: MacBook Pro forum reports put
built-in trackpad touch sensing anywhere from 60 Hz to 130 Hz depending on model generation, and
one report states macOS 26.2 now **downsamples mouse event delivery to match the display's
refresh rate** — which on this M5 Max's ProMotion display would put a plausible ceiling near
120 Hz, but that is inference from a general mouse-event-rate forum thread, not a `NSTouch`- or
pressure-specific citation, and I am flagging it as such rather than stating it as fact.

**This uncertainty turns out not to matter for the recommended design.** DAW Pro's own shipped
code already settles the practical question by construction, independent of hardware polling
rate:
- `pad.previewEffort` (the endpoint Option 1 would feed) is **already rate-capped at 30 Hz** and
  filters unchanged values (Commands.swift, `pad.previewEffort` doc comment: "the 30 Hz rate cap
  or the unchanged-value filter coalesced this call away").
- `BreathContour`'s own expression grid samples at a default 20 ms spacing (50 Hz), and the
  sampler smooths the result with a ~12 ms time constant (`SamplerInstrument
  .expressionSmoothingSeconds`).

Both are well below even the most pessimistic anecdotal trackpad figure (60 Hz). Whatever the true
hardware rate is, the app's own pipeline is the bottleneck, by design, and it was already tuned by
ear for a smooth curve. §7 (actionable takeaways) proposes a five-minute empirical check on this
machine rather than resting on either the anecdotes or this argument alone.

### 1.6 Private API: `MultitouchSupport.framework` — named for completeness, excluded by the brief's own constraint

`/System/Library/PrivateFrameworks/MultitouchSupport.framework` is a real, long-reverse-engineered
private framework (dating to the 2008 "MultiClutch" project) that exposes raw firmware-level
contact data — including a true pressure field per touch, which is exactly the "many fingers, each
with pressure" capability public API lacks. Several current open-source wrappers exist (e.g.
[Kyome22/OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport),
[KrishKrosh/OpenMultitouchSupport](https://github.com/KrishKrosh/OpenMultitouchSupport)). One
developer's own account of building
[TrackWeight](https://notes.krishkrosh.com/notes/TrackWeight) (a trackpad-as-scale app) explains
exactly why they reached for it: the public API "only provide[s] normalized 0-1 values after the
click threshold," which is true to §1.1 above. It is undocumented, has no API stability guarantee
across OS versions, and — confirmed via search — is incompatible with the sandboxing the Mac App
Store requires. **Given this project's explicit "public API only" constraint, this framework is
out of scope, full stop.** It is named here only so a future reader knows it was considered and
why it was rejected, not because it's a live option.

---

## 2. The central question: pointer ownership

**The trackpad never stops being the system pointing device just because your app is also reading
`NSTouch`.** There is no public flag that says "this physical trackpad contact should move a
finger in my view instead of the cursor." `NSTouch` delivery is *additive*: the same physical
single-finger drag that the OS turns into ordinary pointer movement also, if your view opted in,
arrives as an `NSTouch` stream. Both happen at once, from the same finger.

That means there are exactly two workable patterns, and DAW Pro should use each for a different
purpose. This is the most valuable finding in this document because it resolves the question the
brief called the design's real blocker.

### 2.1 Pattern A — own the pointer on purpose (click-anchored). No capture mode needed.

If a gesture *starts* with a literal click on an on-screen control, there is no problem to solve:
the click already puts the pointer exactly where you want it, and the drag position **and**
`NSEvent.pressure`/`.stage` from that same physical contact both arrive at your view for free,
through completely ordinary AppKit/SwiftUI event handling. **DAW Pro already ships exactly this
pattern.** `KnobControl` uses `DragGesture(minimumDistance: 0)` ("so a plain CLICK is a complete
gesture" per its own comment), and `BreathPadView` reads angle/radius from a drag the same way.
Adding pressure here is adding a third axis to a mechanism that is already proven, already
shipping, and needs zero permissions, zero capture/release lifecycle, and zero new risk. This is
Option 1 in §5.

### 2.2 Pattern B — explicit capture, for reading the pad as its own surface

When an app genuinely wants the trackpad's raw surface *independent* of where the pointer happens
to be — reading a second or third finger, or reading position before any click has occurred — it
needs to deliberately neutralize the shared pointer. This is a documented, working, **public**-API
pattern; the clearest confirmation is a real open-source demo
([macos-trackpad-demo](https://github.com/shaunlebron/macos-trackpad-demo)) that does exactly this:

1. `allowedTouchTypes = [.indirect]` + `wantsRestingTouches = true` + the four `touches…` responder
   overrides (§1.4) — reads finger positions.
2. **Separately**, decouple the displayed cursor from physical trackpad motion:
   - `CGAssociateMouseAndMouseCursorPosition(0)` — a public Core Graphics/Quartz Event Services
     call (confirmed to have a live Apple Developer Documentation page,
     [`CGAssociateMouseAndMouseCursorPosition(_:)`](https://developer.apple.com/documentation/coregraphics/1454486-cgassociatemouseandmousecursorpo);
     I could not confirm a deprecation status one way or the other beyond "the doc page currently
     resolves" — see the could-not-verify list). Games use exactly this call to implement mouse
     look/camera-lock.
   - `CGDisplayHideCursor(CGMainDisplayID())` — hides the now-meaningless cursor.
   - `CGWarpMouseCursorPosition(_:)` — repositions the (invisible, decoupled) cursor, e.g. back
     over the capture view, without generating a movement event.
3. Re-associate (`CGAssociateMouseAndMouseCursorPosition(1)`) and show the cursor again on exit,
   reliably — including on focus loss, app deactivation, or a crash-adjacent path, or the user's
   pointer is left broken system-wide after using a DAW plugin, which is a severe failure mode for
   a non-technical user.

**Why step 2 is necessary, not cargo-culted**: per §1.3, Apple's own documentation says touch
routing latches to "the view under the cursor." If the cursor drifts off your capture view during
the performance (which it otherwise will, per Pattern A/B both being live at once), touches stop
routing to you. Warping the (hidden) cursor and pinning it over the capture view is what keeps
touch delivery locked to that view. This is a derivation from a stated Apple mechanic, not a
guess.

**A second hazard, not covered by cursor decoupling at all**: three- and four-finger trackpad
swipes (Mission Control, Spaces) are handled by WindowServer *before* your app sees anything, and
there is no public API to suppress them. A user genuinely playing with three fingers in a capture
mode can eject themselves out of the app mid-performance. I could not find this stated in any
Apple document — I am flagging it as everyday, universally observable trackpad behavior on this
kind of machine, not a cited fact, and it belongs in the cost column of any option that reads more
than two simultaneous touches (§5, Option 4).

**Scope**: both the touch stream and the cursor-decoupling APIs are inherently foreground/local —
they operate on your own app's windows and the shared cursor only while your app is frontmost.
Confirmed directly relevant: a real, unresolved Apple Developer Forums thread
([thread 759439](https://developer.apple.com/forums/thread/759439)) shows a developer who got the
in-window pattern above working but hit a wall trying to go **further** — listening at the OS
level, beyond the current window. That thread is unanswered. It's good evidence of exactly where
the line between "known-tractable" and "genuinely unresolved" sits: **DAW Pro should not attempt
anything beyond foreground, own-window capture.** That's a real constraint, but it's also not a
loss — a performance instrument only needs to work while the app is frontmost anyway.

### 2.3 Permissions: neither pattern needs a system prompt, if scoped this way

Confirmed via search of Apple's own event-monitoring documentation and independent sources: macOS
distinguishes **local** monitors (`NSEvent.addLocalMonitorForEvents`, and ordinary responder-chain
delivery like `touchesBegan`/`mouseDown`/`pressureChange` on your own views) from **global**
monitors (`NSEvent.addGlobalMonitorForEvents`, or a `CGEventTap` on events bound for other apps).
**Input Monitoring (TCC `kTCCServiceListenEvent`) and Accessibility trust are required only for
the global case** — watching input meant for windows that are not yours. Reading events sent to
your own window, and controlling your own app's cursor association while frontmost, are ordinary,
unprivileged operations.

**This is good news for shippability**: as long as the design stays "our own window, while we are
frontmost" — which §2.2's own forum evidence says is the tractable boundary anyway — **no
permission dialog is needed at all.** That matters specifically because the target user is
non-technical; a Force Touch trackpad instrument that never has to explain "please grant Input
Monitoring" to someone who has never seen that screen is a real usability win, and it falls out of
scoping the feature correctly rather than needing separate design work.

---

## 3. How established expression controllers map gesture to sound

### 3.1 MPE — MIDI Polyphonic Expression

Ratified as an official MIDI 1.0 extension by the MIDI Manufacturers Association, January 2018
([MIDI.org announcement](https://midi.org/midi-polyphonic-expression-mpe-specification-adopted),
[full spec PDF](https://d30pueezughrda.cloudfront.net/campaigns/mpe/mpespec.pdf)). The mechanism:
every sounding note gets **its own MIDI channel** (a "Member Channel"), so per-note Pitch Bend and
Control Change messages address one note instead of the whole instrument. A "Master Channel"
carries zone-wide configuration. Three continuous per-note dimensions travel this way:

| Dimension | Message | Spec detail |
|---|---|---|
| Pitch | Pitch Bend | Member-channel default sensitivity **±48 semitones** (vs. the Master channel's ±2), settable via RPN 0 — much wider than a fixed-pitch instrument's bend range, because on an MPE surface pitch bend *is* the primary continuous gesture. |
| Pressure | Channel Pressure (aftertouch) | Per-note "how hard is it being held/pressed" after the initial strike. |
| Timbre | CC74 | Generic "brightness"/timbre axis. (DAW Pro's own `MIDIControllerRouting.describe(_:)` already labels CC74 "brightness" — this is a pre-existing point of alignment with MPE's own vocabulary, not something introduced by this spike.) |

### 3.2 ROLI Seaboard — "5D Touch"

Confirmed via [ROLI's own support documentation](https://support.roli.com/support/solutions/articles/36000019157-what-is-5d-touch-):

| Gesture | Physical motion | MIDI destination |
|---|---|---|
| Strike | Force of initial contact | Note-on velocity |
| Glide | Left/right movement on a keywave | Per-note pitch bend |
| Slide | Up/down movement on a keywave | CC74 |
| Press | Sustained pressure after the strike | Aftertouch/channel pressure |
| Lift | Force of release | Note-off (release) velocity |

### 3.3 LinnStrument and Haken Continuum — grid and continuous-surface controllers

Both map a physical **X / Y / Z** onto **pitch / timbre / loudness**, which is the same
three-dimension shape MPE standardizes at the protocol level:

- **[LinnStrument](https://www.rogerlinndesign.com/support/support-developers-how-to-add-mpe)**: a
  grid of pressure-sensing pads, X = pitch (rows tuned in fourths for consistent fingering across
  the whole surface), Y = timbre (per-row), Z = pressure → loudness.
- **Haken Continuum**: a continuous fretless strip. X = pitch, at extremely fine resolution
  (~0.1 cent, per [mim.be](https://www.mim.be/en/collection-piece/continuum-fingerboard)), Y =
  timbre, Z = pressure → volume. The Continuum predates MPE and is one of the instruments MPE's
  three-axis model was generalized from.

### 3.4 Breath controllers, as physical hardware

The Yamaha **BC3(A)** was the reference hardware breath controller (DIN-MIDI, now discontinued).
Its modern continuation is **TEControl's USB MIDI Breath Controller**, and its newer **BBC2**
variant, which adds bite-force and head-tilt/nod as additional independent streams
([tecontrol.se](https://www.tecontrol.se/products/usb-midi-breath-controller)). Both are a
mouthpiece pressure sensor feeding a **fully configurable** MIDI output — CC, pitch bend, or
aftertouch, whichever the target instrument expects. There is no single hard-wired CC; CC2 (the
MIDI 1.0 spec's own assigned name for controller #2, "Breath Controller") is the conventional
default, but real-world practice routes it wherever the receiving instrument actually listens
(confirmed independently by a KVR Audio forum thread and a MIDI.org community post on exactly
"CC2 vs CC11": *"an instrument tends to be set up to use such a controller as 'expression'... so
you can map CC2 to CC11"*).

### 3.5 For a sax specifically: why breath, and not pitch

This is answered two ways, and they agree — one from this repo's own prior measurement, one
independent:

- **DAW Pro's own measurement** (`docs/research/measure-gm-sax-cc.md`, cited from
  `design-breath-pad.md`): the stock GM/DLS sax's CC11 is measured as *exactly* a gain (square-law
  loudness, −104 dB residual on a single-scalar fit), and the instrument's own internal vibrato is
  driven by CC1, not by our pitch-bend lane.
- **Independent, industry-wide confirmation**: Sample Modeling / Audio Modeling's SWAM
  saxophones — widely regarded as the reference physically-modeled sax instruments — document
  their primary controllers as *"Pitchwheel, CC11 (or CC7, or CC2) for the dynamics, CC1 (modwheel)
  for vibrato intensity, and CC19 for vibrato rate"* (confirmed via VI-Control community threads
  and Sound on Sound's review). This is the same shape as our own measurement, arrived at
  independently by the instrument-modeling community.

**Why breath/dynamics and not pitch bend**: a saxophone's pitch is set by fingering — a discrete,
keyed mechanism. The only continuously-variable physical input available to a player *during* a
held note is breath pressure (embouchure contributes a secondary, much smaller pitch effect). That
one physical variable simultaneously drives loudness, brightness/timbre, and a very slight
sharpening under pressure — which is exactly the three things `BreathContour`'s own model already
generates from a single CC11 contour (loudness + optionally a filter sweep) plus a small correlated
pitch micro-sharpening layered *on top of*, not instead of, the breath curve. The physical
mechanism and DAW Pro's existing offline model already agree; a trackpad Z-axis should drive the
same parameter, not invent a new one.

---

## 4. The whammy analogue, per instrument family

A guitar's tremolo arm mechanically detunes the string after it's struck — pitch bend really is
the physically honest mechanism there. It is not the honest mechanism everywhere else:

| Family | Real mechanism | Honest DAW Pro mapping | Buildable today? |
|---|---|---|---|
| **Plucked string** (electric guitar) | Whammy bar physically changes string tension → pitch, after the pluck | Pitch bend | **Yes, today.** `SamplerParams.bendRangeSemitones` is a real, settable, per-instrument field (default 2.0 = GM/MPE-master convention), gated by `SamplerBendRangeVoiceModeTests.swift` (just added — byte-identical-at-default, and a measured "bend range 12 moves exactly one octave" frequency test). A trackpad gesture driving raw 14-bit pitch bend against this range is a direct, no-new-engine-work fit. |
| **Wind instrument** (sax etc.) | Breath pressure → loudness + brightness + slight sharpening. Pitch is fingering-quantized. | CC11 (± CC1/CC2 once `expressionModDepth` is set) via `BreathContour`/`EffortField`, **not** a large pitch bend | **Yes, today, on the built-in `.sampler`** (loudness AND brightness, since `expressionFilterDepth` wires a real filter). **Loudness-only, measured, on `.soundBank`/hosted-AU** — `MIDIControllerRouting.expressionMovesBrightness` and `design-breath-pad.md` explicitly forbid promising brightness there; that's where the actual GM/DLS sax and any hosted sax VST live. |
| **Bowed string** (violin/cello) | Bow pressure + bow speed → dynamics/timbre; vibrato is a separate, periodic finger-oscillation technique, not a transient bend | Physically analogous to breath (a continuous energy-input control), so the *shape* of `BreathContour`'s approach transfers | **No dedicated model exists in this tree.** `BreathContour`'s own doc comments only ever discuss wind physiology (attack settle, vibrato-arrives-late, breath-pressure sharpening). Reusing it for a bowed patch would be a relabeling, not a verified physical fit — flagged here as a real gap, not silently assumed solved. |

So: two of the three families the owner asked about are honestly buildable today on the existing
engine with no new DSP; the third (bowed strings) is a real, named gap for a future roadmap item,
not something to paper over by reusing the wind model under a new name.

---

## 5. Four options, differing on one axis: how much of the trackpad we claim, and when

| | **1. Pressure on the existing pad** | **2. Bigger dedicated XY+pressure pad** | **3. System gestures as macro knobs** | **4. True multitouch capture** |
|---|---|---|---|---|
| **What it claims** | One click's worth of contact, on the existing `BreathPadView`/knob controls | One click's worth of contact, on a new large dedicated panel | Nothing exclusively — opportunistic 2-finger pinch/rotate, coexists with normal pointer use anywhere | The whole trackpad surface, exclusively, for the duration of a mode |
| **Gesture → parameter** | `NSEvent.pressure` (via `.primaryGeneric`, §1.2) becomes a 3rd axis alongside the pad's existing angle (pattern)/radius (depth) → feeds `EffortField`/`BreathContour` | Click position (X/Y across a big surface) → 2 assignable CCs, pressure → a 3rd | `NSMagnificationGestureRecognizer`/`NSRotationGestureRecognizer` (or SwiftUI `MagnifyGesture`/`RotateGesture`) → coarse macro parameters (e.g. pinch = filter cutoff) on whichever panel has focus | Enter a dedicated "Trackpad Instrument" mode; each simultaneous `NSTouch` (by `identity`) → one voice/note; pointer decoupled per §2.2 |
| **Pointer ownership** | Solved by construction (§2.1) — the click already owns it | Solved by construction (§2.1) | Solved by construction — multi-finger gestures are, by long-standing convention, not interpreted as the single-finger "point" gesture that drives the cursor (this is universal, everyday trackpad behavior; I found no Apple document stating it as a formal contract, so it's flagged as observed rather than cited) | The hard case: needs full capture-mode lifecycle (§2.2) — cursor decouple/hide/warp, reliable re-association on every exit path, and no defense at all against 3/4-finger system gestures ejecting the user mid-performance |
| **New permission needed** | None | None | None | None, as long as it stays foreground-only (§2.3) — but the failure modes are worse if it doesn't |
| **Per-touch pressure available?** | Yes (it's the only touch) | Yes (it's the only touch) | No (gesture recognizers report the aggregate transform, not per-finger anything) | **No** — `NSTouch` has no pressure field at all (§1.3). Position-only, for however many fingers are down. |
| **Relative cost** | Smallest. One `NSViewRepresentable`/pressure bridge (SwiftUI has no native pressure API); reuses `EffortField`/`pad.previewEffort` plumbing entirely. | Small–medium. New panel, new per-axis CC-assignment UI; same event-handling primitives as (1). | Smallest of all if scoped narrowly; cheap to add alongside (1). | Largest. New capture-mode state machine, new per-touch note-routing model, real user-facing risk if cursor re-association ever fails. |
| **Answers the sax-breath ask?** | Yes — directly, and it's the physically correct mapping (§3.5). | Yes, plus gives room for a second assignable axis. | No — coarse, discrete-ish, not "how hard am I blowing." | Yes, and goes further (per-note control), but cannot carry pressure per note (the mutual-exclusivity finding), so it cannot actually do the sax-breath case *better* than (1) — only differently (many simultaneous notes, none individually dynamic). |

**Recommendation: Option 1, then optionally Option 2, with Option 3 as a near-free addition
alongside either.** Option 4 should be tracked as a separate, later, distinctly-scoped idea — not
because it's a bad idea, but because it is qualitatively riskier (a strandable system cursor is a
real, severe failure mode for a non-technical user) and, per the mutual-exclusivity finding, it
does not even deliver a *better* answer to the sax-breath case that motivated the whole spike — it
delivers a *different* capability (many simultaneous discrete-pressure-less notes), which is a
genuinely separate feature with its own justification, not a strict upgrade of (1).

---

## 6. What ships first

The owner is not a trained musician and has no MIDI hardware. The lowest-learning, most-musical
option is the one that requires learning **nothing new**: press harder on a control they already
have and already understand (the breath pad shipped in the last few commits), and the sound gets
louder and brighter, exactly like blowing harder does in reality. That is Option 1.

### 6.1 What's genuinely new vs. what already exists

**Already exists, confirmed by reading the current tree, and reusable as-is:**
- The pad's angle/radius → effort pipeline: `BreathPadModel`, `EffortField`, `BreathContour`,
  `applyEffortShape` / `applyBreathContour`.
- The live-preview wire command and MCP tool for streaming a value while a gesture is open:
  `pad.previewEffort` (Commands.swift) / `pad_preview_effort` (server.ts) — gesture-scoped
  (`begin`/`move`/`end`), already rate-capped at 30 Hz, already tested per this project's
  "every capability ships a command + tool + test" law.
- Automatic capture of performed MIDI: `MIDICaptureSession.ingestController` really does ingest
  `controlChange`/`pitchBend`/`channelPressure` (MIDICaptureSession.swift:164–172) into controller
  lanes during an armed take — **but only for events that reach it through a live-performance
  path**, the way Musical Typing's notes do: `LiveNoteSink` (protocol) →
  `LivePlayNoteSink.setHeldPitches` → `ProjectStore.playLiveNotes`, which is "deliberately NOT
  refused while recording" (`LiveNoteSink.swift`'s own comment) specifically so its edges reach
  the capture session.

**Genuinely new:**
- Reading `NSEvent.pressure` from the pad's existing click/drag and configuring it with
  `.primaryGeneric` (§1.2) — an AppKit-level bridge, since SwiftUI has no native pressure API
  (likely an `NSViewRepresentable` wrapping the pad's hit-testing area).
- A pure, deterministic mapping function, `pressure (Float, 0...1) -> effort (Double, 0...1)` (or
  directly to a CC value) — this is the one part of "read trackpad pressure" that is actually
  unit-testable without hardware, and per this project's law it needs its own test in `DAWCore`.
- **A continuous-controller sibling of `LiveNoteSink`.** This is the correction from §0.4, restated
  concretely: `pad.previewEffort` is audition-only by explicit design ("nothing is written to any
  clip, nothing is recorded"). If the goal is "the owner blows into the pad while playing, and it's
  in the take afterward" — which is what the brief assumes — that requires a **new** seam,
  shaped like `LiveNoteSink` but for a continuous controller stream, that feeds
  `MIDICaptureSession`'s existing controller ingestion the way `playLiveNotes` feeds its note
  ingestion. Without it, pressure-driven expression is preview-only, same as the pad is today.
- A UX/design decision (not a research question, and not answered here): does pressure
  **replace** "distance dragged from center" as the depth/radius signal (arguably more physically
  honest — real breath pressure isn't drag distance), or does it become an independent third
  axis alongside the existing angle/radius? Recommend routing this to `daw-architect` or
  `ui-design-engineer` alongside the implementation work, not deciding it here.
- Graceful degradation, not a hardware query: there is no verified public API for "does this Mac
  have a Force Touch trackpad" callable from inside a running app (the `ioreg`/`defaults read`
  checks the calling agent already ran are shell-level, not an app-facing API, and I found no
  documented equivalent). The design should not promise one. If any wire/MCP surface reports
  capability at all, it should report **observed** capability — "a `.pressure` event was seen
  this session" — and default the Z-axis to a neutral/no-op value otherwise, so an external mouse
  or an older trackpad degrades silently rather than erroring.

### 6.2 Why this correction matters enough to repeat

The brief states as established fact: "anything performed will be recorded automatically because
the capture session already ingests CC/bend/pressure." The capture-session half of that is true
and confirmed (MIDICaptureSession.swift:164–172). The "automatically" half is not, for the specific
endpoint that already exists for this kind of gesture — `pad.previewEffort`'s own in-repo
documentation is explicit that it is a preview, not a record, and deliberately so (so that live
playback, replay, and an offline bounce keep agreeing sample-for-sample while someone is just
auditioning a shape). Building Option 1 without the new performance-path seam in §6.1 would ship a
feature that sounds correct while being played and then **silently is not in the bounce** — which
is exactly the class of defect this project's own history flags repeatedly (a control that returns
a plausible answer while doing something other than what it appears to do). This is worth a
dedicated roadmap item on its own, ahead of or alongside the pressure-reading UI work.

---

## 7. Actionable takeaways

1. **(Do first, small)** Add `NSEvent.pressure`, configured via `.primaryGeneric`
   (`NSPressureConfiguration`), as a third axis on `BreathPadView`'s existing click/drag surface.
   Route: `swift-app-engineer`/`ui-design-engineer` (SwiftUI has no native pressure API — needs an
   `NSViewRepresentable` bridge over the pad's hit area).
2. **(Do first, small, blocks §6.1's recording claim from being true)** Build a continuous-
   controller sibling of `LiveNoteSink`/`playLiveNotes` so a live-performed pressure/CC stream
   actually reaches `MIDICaptureSession`'s existing controller-lane ingestion. `ingestController`
   (MIDICaptureSession.swift:164–172) is already wired to capture live `controlChange`/
   `pitchBend`/`channelPressure` events during an armed take — that is what the class is for — but
   nothing in the app today *produces* a live controller event into that path: there is no MIDI
   hardware, and `pad.previewEffort` deliberately bypasses the take (§6.2). The gap is a missing
   producer, not a missing consumer. Route: `mcp-integration-engineer` for the wire/MCP surface,
   `daw-architect`/`audio-dsp-engineer` if it touches the render-thread live path the way
   `playLiveNotes` does.
3. **(Test, small)** A pure `DAWCore` function mapping pressure (0...1) to effort/CC, deterministic
   and hardware-independent — the one part of this feature that CI can actually gate.
4. **(Design decision, not research)** Resolve whether pressure replaces drag-distance as the
   pad's depth/radius signal or adds a genuinely independent third axis. Needs the owner's or
   `daw-architect`'s call.
5. **(Cheap, complementary, can ship alongside #1)** Two-finger pinch/rotate as coarse macro-knob
   gestures (`NSMagnificationGestureRecognizer`/`NSRotationGestureRecognizer` or SwiftUI
   `MagnifyGesture`/`RotateGesture`) layered onto existing panels. Does not answer the sax-breath
   ask by itself but is near-zero marginal cost given §5's finding that multi-finger gestures
   don't fight the pointer.
6. **(Defer — separate milestone, not a bundle with #1/#2)** True multitouch "trackpad as
   instrument" (Option 4, §5): capture-mode lifecycle with cursor decouple/hide/warp, no defense
   against 3/4-finger system gestures ejecting the user, and — the load-bearing constraint — no
   per-touch pressure available on public API, so it cannot make the sax case more expressive than
   Option 1, only different (many simultaneous, individually static-pressure notes).
7. **(Empirical, ~10 minutes, not a research task)** On this exact machine, log real
   `pressureChange(with:)`/`touchesMoved(with:)` timestamp deltas to get a measured update rate,
   rather than resting on the anecdotal 60–130 Hz range in §1.5. Low priority given §1.5's
   arithmetic argument that the app's own 30 Hz/50 Hz internal rates are already the bottleneck.
8. **Do not build** a public "this Mac has Force Touch" capability-query command — no verified
   API for it exists. If capability is ever surfaced on the wire/MCP surface, report *observed*
   capability only ("a pressure event was seen this session"), matching the existing project
   convention of naming routes that work rather than refusing based on an assumption
   (`MIDIControllerRouting`'s whole design is exactly this pattern).
9. **Whammy-bar-for-guitar** (§4) is separately, immediately buildable with existing engine
   capability (`SamplerParams.bendRangeSemitones`) and needs no new DSP — worth a small roadmap
   item on its own regardless of what happens with the trackpad, if a plucked-string patch is ever
   prioritized.
10. **Bowed-string expression** (§4) is a named gap: `BreathContour` is wind-physiology-specific by
    its own doc comments, and reusing it for a bowed patch under a new name would be an unverified
    assumption, not a measured fit. Flag for future research if bowed strings become a priority.

---

## Could not verify — stated explicitly rather than guessed

- **`developer.apple.com`'s HTML documentation pages** (`NSTouch`, `allowedTouchTypes`,
  `NSPressureConfiguration`, `CGAssociateMouseAndMouseCursorPosition`) returned only page titles to
  automated fetches — they appear to be client-rendered and did not yield readable body content
  this way. Where I needed the underlying facts, I went to Apple's own DocC JSON data endpoint
  (worked for `NSTouch`) or Apple's own shipped SDK header comments via a public GitHub mirror of
  the SDK (`phracker/MacOSX-SDKs`) for `NSEvent.PressureBehavior` and `allowedTouchTypes`'
  default — both are Apple's own text, just accessed indirectly. I was not able to independently
  re-verify these against `developer.apple.com` directly in this session.
- **`CGAssociateMouseAndMouseCursorPosition`'s deprecation status** — confirmed only that a live
  documentation page currently exists for it and that a real, current open-source project uses it
  successfully. I did not find an explicit "still supported / not deprecated on macOS 15/16"
  statement from Apple.
- **Exact trackpad touch/pressure update rate** — no Apple-published number found anywhere. §1.5's
  60–130 Hz range is anecdotal (Apple Discussions / MacRumors forum posts), not a spec.
- **Whether multi-finger gestures never drive the pointer** (§2.2, §5) — stated as observed,
  everyday trackpad behavior; I found no Apple document formalizing it as a contract an app can
  rely on indefinitely.
- **Descriptions of `.primaryClick`/`.primaryAccelerator` beyond their header doc-comments** — the
  WWDC transcript covered `.primaryGeneric` in prose detail but referred listeners to "the header
  file" for the rest; I have the header comments (§1.2 table) but no worked example of each in
  practice.
