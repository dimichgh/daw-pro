# m23-av route (b) — out-of-process AU hosting: measured feasibility

**Date:** 2026-08-04. **Method:** standalone Swift probe (`scripts/probes/auprobe.swift`),
each instantiation in its OWN process because a wedging plug-in poisons the process it
loads into. Machine: this laptop, Xcode 26.6, macOS 26. **No repo source was modified.**

> ⚠️ **THIS DOCUMENT OVERTURNS A CAUTION I GAVE BEFORE MEASURING.** I had reasoned that
> out-of-process hosting only helps AUv3 app extensions and therefore could not help
> Surge XT (a classic AUv2 `.component`). **That reasoning was wrong.** macOS bridges
> classic AUv2s out-of-process, and it is measured below.

---

## 1. The installed population — every third-party unit here is AUv2

`AVAudioUnitComponentManager` reports 73 units. Filtered to third-party plus anything v3:

```
name                  type  sub   mfr   isV3  packaging
Attracktive           aumu  TSAt  TSCP  no    .component
Dexed                 aumu  Dexd  DGSB  no    .component
EchoJay               aufx  EcJy  Ecjy  no    .component
Kontakt 8             aumu  NiK8  -NI-  no    .component
Reaktor 6             aumu  NiR6  -NI-  no    .component
Reaktor 6 MFX         aumf  NiR6  -NI-  no    .component
Reaktor 6 MIDIFX      aumi  NiR6  -NI-  no    .component
Splice INSTRUMENT     aumu  Inst  Splc  no    .component
Surge XT              aumu  SgXT  VmbA  no    .component
KonaSynthesizer       ausp  kona  appl  YES   APPEX
MacinTalkAUSP         ausp  mctk  appl  YES   APPEX
MauiAUSP              ausp  crnc  appl  YES   APPEX
SiriAUSP              ausp  axsr  appl  YES   APPEX
WardaSynthesizer      ausp  wrda  appl  YES   APPEX
```

**Not one third-party unit is `isV3`.** The only v3/app-extension units are Apple's own
speech synthesizers. Surge XT declares `factoryFunction` + `sandboxSafe: true` in its
`Info.plist`, which is suggestive of the v3 API but the system does **not** set
`AudioComponentFlags.isV3AudioUnit` for it.

### Consequence for the shipped code

`Sources/DAWEngine/AudioUnits/AUHostRegistry.swift:577-588` (and the instrument mirror at
`:748-759`) branches on exactly that flag:

```swift
if isV3 {
    do    { au = try await instantiator(componentDescription, [.loadInProcess]) }
    catch { au = try await instantiator(componentDescription, [.loadOutOfProcess]) }
} else {
    au = try await instantiator(componentDescription, [])   // ← every third-party plug-in lands here
}
```

So the `.loadOutOfProcess` retry is **unreachable for every plug-in this user owns**, and
it is additionally only a *failure* fallback — a plug-in that HANGS rather than THROWS
never reaches it even when it is reachable.

---

## 2. THE ENABLING FACT — macOS bridges a classic AUv2 out-of-process

Controlled observation, `com.apple.audio.SandboxHelper.xpc` process count:

```
  before any probe                          8
  during a [.loadOutOfProcess] hold         9   ← +1, a helper spawned
  during a [.loadInProcess]    hold         8   ← none
```

`.loadOutOfProcess` on Surge XT (an AUv2) **succeeds and genuinely lands in another
process.** This is the fact the whole route rests on and it was previously assumed false.

### Cost — small

```
  phase                        Surge XT in-proc   Surge XT out-of-proc   Kontakt 8 out-of-proc
  instantiate                     0.073 s              0.212–0.227 s          1.118 s
  outputBusses[0].setFormat       0.000008 s           0.00019–0.00022 s      0.00018 s
  allocateRenderResources         0.00009 s            0.042–0.044 s          0.040 s
```

~0.15–0.35 s of extra instantiation latency for Surge XT. Against a wedge measured in
MINUTES, that is not a trade-off worth deliberating.

---

## 3. ⚠️ THE WEDGE DID NOT REPRODUCE

The full in-process path — instantiate → setFormat → allocateRenderResources →
requestViewController — completed in **~0.18 s total**:

```
  instantiate                 0.0732 s
  setFormat                   0.000008 s
  allocateRenderResources     0.00009 s
  requestViewController       0.1109 s
```

[[daw-pro-au-hosting-wedge]] records `track_set_instrument` with Surge XT wedging the main
actor for MINUTES. **That does not reproduce on the bare AU API path on a warm system.**
Candidate explanations, none established:

1. **Cold start.** A first-ever instantiation may scan a patch library; the probe ran warm.
2. **The app's own path, not the AU's.** `AUHostRegistry.swift:697`
   `AVAudioUnitComponentManager.components(matching:)` runs on the MAIN ACTOR inside no
   deadline — this is the already-filed **m23-av-2**, and it is upstream of everything
   measured here.
3. **Already mitigated** by m23-at / m23-au / m23-av's deadline work.

**Do not treat the standing "prefer GM sound banks" avoidance rule as verified.** It rests
on behaviour that this probe could not reproduce; it also must not be deleted on one
warm-system negative. It needs a cold-start reproduction attempt.

---

## 4. What the probe CANNOT settle — the plug-in UI over XPC

`requestViewController` on an out-of-process AUv2 aborts in the probe:

```
CAUI_fetchRemoteAUv2ViewController → -[NSViewController view] → NSInternalInconsistencyException
  'invoked too early to return meaningful value' in +[NSServiceViewController currentAppIsViewService]
```

**This is a PROBE ARTIFACT, not an AU limitation** — ViewBridge asserts because a
command-line tool has no initialised `NSApplication`. It is stated here rather than
suppressed because it means exactly one thing: **the remote-view path can only be
validated inside the real app.** That is also precisely where the reported wedge lives, so
it is the one risk that must be retired before changing the default.

(Two earlier probe crashes were also mine, not the system's: `FileHandle.standardOutput
.synchronizeFile()` throws on a pipe. **A probe defect and a finding look identical in the
log — check the frame that actually threw.**)

---

## 5. Recommendation

The change is far smaller than the "milestone requiring full Xcode, an app bundle and
hosting entitlements" the roadmap assumed — none of that is needed; the capability is
present today and the code already has both call paths.

1. **Relax the `isV3` gate** so third-party AUv2s can be loaded out-of-process, at both
   sites (`:577-588` instrument, `:748-759` effect — they must stay in lockstep).
2. **Prefer out-of-process, fall back in-process** — inverting today's order. A hang, not
   a throw, is the failure being defended against, so a *catch*-based fallback is the wrong
   shape; the fallback must be driven by the existing `DeadlineRace`.
3. **Validate the remote view inside the real app before flipping any default** (§4).
   Until then the change belongs behind a switch, not in the default path.
4. **Attempt a cold-start reproduction** of the original wedge (§3) so the change can be
   measured against the thing it is supposed to fix, rather than assumed to fix it.

Filed as **m23-av-3**.
