# M29 — Out-of-process Audio Unit hosting: the decision, the measurement that gates it, and the legs

**⛔ DESIGN ONLY. No source or test file was modified while writing this.** Every
implementation step below is a proposal awaiting the user's explicit word. Nothing here
may be read as authorising code.

Seeded 2026-08-20 from a tester's report:

> *"A plugin segfault kills the whole app. Twice, identical stack. Autosave saved us both
> times, which is a genuine credit to them — but out-of-process AU hosting would mean it
> never mattered."*

**The credit is deserved and the mitigation stays.** M9 crash-b's autosave + recovery
sentinel (`Sources/DAWCore/AutosaveManager.swift`, `project.recoveryStatus`) worked both
times and is not replaced, weakened, or superseded by anything in this document. §7 states
exactly what it covers and what it cannot.

This design **absorbs and corrects ROADMAP m23-av-3** (`docs/ROADMAP.md:1189`) and its
probe (`docs/research/m23av-routeb-feasibility-probe.md`). §2.5 explains why one of that
probe's load-bearing claims is not established by the evidence it presents.

⚠️ **§15 and §16 were folded in on 2026-08-20 from new measured tester data that arrived
after the first draft. Both are INDEPENDENT of the out-of-process decision and neither
needs it. §15 in particular fixes a live defect that silently destroys the head of real
bounces and is recommended AHEAD of every other leg in this document (§9.1) — if the user
rules "no" on out-of-process entirely, §15 and §16 still ship.**

⛔⛔ **REVISED 2026-08-20, SECOND ROUND. An external tester measured the SHIPPED build
(`412cb33`) and FALSIFIED TWO OF THIS DOCUMENT'S OWN PREMISES.** Both lived in §15 and a
multi-day leg (R-2) was about to be built on them:
**(1)** *"where decode/parse dominates — 46 zones — warm and cold are the same number"*
(§15.1) — **false; it warms monotonically, and the retention mechanism is unidentified**;
**(2)** *"the sax bounce is byte-identical cold and warm"* (§15.5(c), §14) — **false; two
fully-warm renders leave a −3.07 dB residual, controlled.** Rejecting byte identity is
still right, but **the failure mode is inverted: it would never terminate, not terminate
early.** Corrections are made where the reasoning lives, with the old claim shown. Three
further changes fell out: **§1** gains a third crash report and two corrected fault
addresses (measured by re-parsing the `.ips` files, not by re-reading the draft); **§15.7**
records that the dropout is path-specific and tracks a double instantiation; **§15.8** files
warm-render non-reproducibility as a defect of its own. ⭐ **The strategic consequence is in
§15.7 and §3.1 G0: the dropout and the crash may be two symptoms of ONE decision — fresh AU
instances per render — and instance reuse should be costed before this milestone is
committed to.**

Related: `docs/research/design-m23av-prepare-status-offmain.md` (route (a), shipped),
`docs/research/design-vi-b-au-windows.md` (plugin windows — §10 Leg 7 depends on it),
`docs/research/design-m16a-canvas-crash.md` (the ObjC exception barrier — §4 A3 explains
why it cannot reach this crash class).

---

## 1. THE FINDING — the crash is on disk, and it is not a render-thread crash

The tester's crashes are `~/Library/Logs/DiagnosticReports/DAWApp-2026-08-20-153332.ips`,
`DAWApp-2026-08-20-154549.ips`, and — **added 2026-08-20, a THIRD report the first draft of
this section did not have** — `DAWApp-2026-08-20-204257.ips`. I read all three. They are
the report.

| | crash 1 | crash 2 | crash 3 |
|---|---|---|---|
| report | `…-153332.ips` | `…-154549.ips` | `…-204257.ips` |
| captured | 2026-08-20 15:33:29 −0700 | 2026-08-20 15:45:46 −0700 | 2026-08-20 20:42:53 −0700 |
| process launched | 13:45:24 | 15:39:18 | 20:14:26 |
| **age at crash** | **1 h 48 m** | **6 m 28 s** | **28 m 27 s** |
| signal | SIGSEGV / EXC_BAD_ACCESS | SIGSEGV / EXC_BAD_ACCESS | SIGSEGV / EXC_BAD_ACCESS |
| fault address | `0x656c706d6153223d` | `0x9f6` | `0xc0642da9f002a7f4` |
| faulting thread | 0, `com.apple.main-thread` | 0, `com.apple.main-thread` | 0, `com.apple.main-thread` |

⚠️ **CORRECTION TO THIS TABLE, MEASURED 2026-08-20 by re-parsing the `.ips` files rather
than re-reading the draft.** The first draft printed the two fault addresses **attributed to
the wrong reports**, and printed the text-shaped one **two bytes short**: it read *"crash 1
`0x9f6`, crash 2 `0x706d6153223d`"*. Both halves are wrong. `…-153332.ips` faults at
`0x656c706d6153223d`; `…-154549.ips` faults at `0x9f6`. The value `0x706d6153223d` never
appeared in any report — it is a truncation that this document invented. The correction is
not cosmetic; the full eight-byte width is the whole point of consequence 3 below.

The faulting stack is byte-for-byte identical, down to the image offsets — the tester's
"identical stack" is literally true:

```
0  DecentSampler   +0xf0534
1  DecentSampler   +0x67ba6c
2  DecentSampler   +0x67b6a4
3  DecentSampler   +0x67cc1c
4  CoreFoundation  __CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__ +28
5  CoreFoundation  __CFRunLoopDoSource0 +172
…
16 AppKit          -[NSApplication run] +368
21 DAWApp          DAWApp_main +36
```

The plugin is **DecentSampler 1.23.5**, `aumu Dsmp Dldy`, at
`~/Library/Audio/Plug-Ins/Components/DecentSampler.component` — a **classic AUv2
`.component`**, JUCE v8.0.12 (the process carries `JUCE v8.0.12: Timer`,
`JUCE v8.0.12: thumb cache`, `Sample Loading Thread`, `OnlineManager TaskRunner`, and
dozens of `WavePlayers` threads).

### 1.1 Five consequences, each of which changes the design

1. **It is not a render crash.** The faulting thread is thread 0, `com.apple.main-thread`,
   in all three reports, and the faulting stack is identical in all three.
   ⚠️ **PARTIAL CORRECTION, MEASURED 2026-08-20:** the first draft said flatly that
   *"at crash time `com.apple.audio.IOThread.client` (thread 51) was parked in
   `HALC_ProxyIOContext::IOWorkLoop()` — waiting, not rendering"*. That is true of crashes
   **1 and 2** and **false of crash 3**, where the audio IO thread was **deep inside a live
   render** — `HALC_ProxyIOContext::IOWorkLoop()` → `AUHALOutputUnit_ProvideOutputCallback`
   → six nested `AUAudioUnitV2Bridge_Renderer::renderInputProc` / `AudioUnitRender` levels
   → our own `DAWApp` frames. So in one of three crashes **the live graph was actively
   pulling hosted AUv2s while the main thread faulted inside the plugin**. The conclusion of
   this point survives (the fault is not *on* the render thread); the concurrency picture
   does not, and §1.2 now leans on the difference.
   Frame 4 of the faulting stack is `__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__`:
   this is JUCE's message-thread queue, delivered as a `CFRunLoopSource` **on our main run
   loop**, because the plugin's binary is mapped into our address space. *Out-of-process
   hosting fixes this crash — but not by isolating the render path.* It fixes it by never
   mapping the plugin into us at all, so that run-loop source is created in the helper
   process instead. That reframes the whole cost/benefit: we would be paying render-path
   IPC to buy protection against a **non-render** failure.

2. **No in-process mitigation can reach it.** `withObjCExceptionBarrier`
   (`Sources/DAWEngine/ObjCExceptionBarrier.swift`) catches `NSException`. This is
   SIGSEGV. A Mach exception handler that "recovered" would be resuming inside an address
   space we have just proven is corrupt — see point 3.

3. **Three fault addresses, all different, and one of them is a whole pointer's worth of
   text.** `0x656c706d6153223d` read little-endian is the byte sequence
   `=`, `"`, `S`, `a`, `m`, `p`, `l`, `e` — i.e. **`="Sample`**, a fragment of exactly the
   XML that DecentSampler's `.dspreset` files are made of, filling **all eight bytes** of
   the pointer. (The first draft printed six of those bytes and read it `="Samp`; corrected
   in the table above. Eight-of-eight is the stronger fact — this is not a pointer with a
   corrupted low half, it is a pointer that is *entirely* preset text.) `0x9f6` is a small
   integer. `0xc0642da9f002a7f4` decodes to no ASCII at all. A pointer whose bits are
   preset text is memory corruption or a use-after-free, not a null check somebody forgot.
   **Same code path, three different corruptions, only one of them text.**
   ⚠️ **INFERRED, not measured:** a *family* of related garbage would point at a
   data-driven over-read of one buffer; three *mutually unrelated* values arriving from one
   stack read instead as **a pointer dereferenced after the memory it names was freed and
   reused**, because the reuse contents differ every time. §1.2 builds on this and labels
   its confidence. Address-space separation is the only mitigation with a mechanism behind
   it under either reading.

4. **It is not an instantiation crash and not a startup crash.** 6 minutes, 28 minutes,
   and 108 minutes into three separate sessions. A pre-flight "validate the plugin in a
   sacrificial subprocess" scheme would have passed all three times (§4, A4).

5. **It is not the Surge XT wedge, and the two must not be blurred.** A wedge is a hang;
   this is a segfault. `docs/research/m23av-routeb-feasibility-probe.md` §3 recorded that
   the wedge **did not reproduce** on a warm system. m23-av-3's roadmap line runs the two
   together. This design keeps them apart: out-of-process addresses a segfault directly, a
   *render* hang only via `kAudioUnitErr_RenderTimeout`, and a hung *instantiate* not at
   all (that is `DeadlineRace`'s job and it already ships).

### 1.2 What I could not attribute — and the hypothesis that now leads

Nothing of ours is on the *faulting* stack in any of the three reports. That is consistent
with the plugin's own asynchronous work (its online browser / thumbnail cache / timer)
faulting on its own; it is **also** consistent with a use-after-free seeded earlier by our
teardown ordering (`AUHostRegistry.releaseInstrument` disposes on the main actor; a queued
JUCE message for that instance would then fire against freed memory). The faulting stack
alone cannot distinguish these.

**⭐ UPDATED 2026-08-20 — the leading hypothesis has changed, and it now points at us.**
All three crashes happened **during heavy offline-render activity** (tester's report). The
candidate mechanism is **our own per-render instantiate/teardown racing the plugin's
`CFRunLoopSource` deferred work**: every bounce builds fresh AU instances and disposes them
(§15.1), the disposal runs on the main actor, and frame 4 of every one of these faulting
stacks is a main-run-loop `source0` callback — precisely the queue on which a disposed JUCE
instance's still-pending messages would fire.

Provenance, stated exactly, because this is a third theory and the first two did not
survive:

- **MEASURED** (by re-parsing the three `.ips` files on 2026-08-20): the thread inventories
  differ across the crashes and they differ *by multiples*. `WavePlayers` threads number
  **54 / 36 / 18** — exactly 3×18, 2×18, 1×18. DecentSampler's other per-instance threads
  appear **in duplicate** in crash 1 (2× `Sample Loading Thread`,
  2× `JUCE v8.0.12: thumb cache`, 2× `OnlineManager TaskRunner`), while the process-global
  `JUCE v8.0.12: Timer` appears **once** in all three.
- **MEASURED:** in crash 3 the live audio graph was mid-render through six nested hosted
  AUv2 bridges while the main thread faulted inside the plugin (consequence 1 above). In
  crashes 1 and 2 the IO thread was parked. Concurrent live render is therefore **not
  necessary** for the crash — but it was present once.
- **INFERRED, NOT VERIFIED:** that the thread multiples mean **three, two, and one**
  concurrent DecentSampler instances alive at fault time. The thread-per-instance mapping
  is undocumented and I did not verify it, and the two instruments **disagree**: the
  auxiliary threads run 2 / 2 / 1 where `WavePlayers` runs 3 / 2 / 1. That disagreement is
  the signal, not a rounding error. **Do not quote 3 / 2 / 1 as a fact.**
- **UNVERIFIED — the race itself.** There is **no controlled repro**. This defect has
  already refuted **two** prior theories: the prepare-timeout hypothesis, retracted in
  §15.1, and the reading that it is purely the plugin's own async work, which the
  render-activity correlation now strains without refuting. A third theory arriving without
  a repro has earned exactly as much scepticism as the two before it.

§10 Leg 0-E is still the discriminator, and it now has a **cheap instrument attached**:
count per-instance JUCE threads (`WavePlayers`, `Sample Loading Thread`) across an
open/close cycle on the `releaseInstrument` pattern and see whether the count returns to
baseline. §11 F12 carries the candidate cheap mitigation if it turns out to be ours.
⚠️ **A non-reproduction attributes nothing** — that is the weakest evidence there is, and
the close-out must record it as inconclusive rather than as the plugin's fault confirmed.
**§15.7 is where this hypothesis meets the bounce defect: they may be one design decision
wearing two symptoms.**

---

## 2. WHAT APPLE ACTUALLY GIVES US

Verified 2026-08-20 against **primary sources**: the SDK headers shipped with the Xcode
26.6 installed on this machine
(`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/AudioToolbox.framework/Headers/`),
plus Apple's public developer documentation. Header quotes are verbatim.

### 2.1 The instantiation options — and the sentence that matters most

`AudioComponent.h:217-244`:

> **@enum AudioComponentInstantiationOptions** — Options controlling component
> instantiation.
> Most component instances are loaded into the calling process.
> A version 3 audio unit, however, can be loaded into a separate extension service
> process, and this is the default behavior for these components. To be able to load one
> in-process requires that the developer package the audio unit in a bundle separate from
> the application extension…
> A macOS host may request in-process loading of such audio units using
> `kAudioComponentInstantiation_LoadInProcess`.
> **These options are just requests to the implementation. It may fail and fall back to
> the default.**
> `kAudioComponentInstantiation_LoadOutOfProcess` — *Attempt* to load the component into a
> separate extension process.
> `kAudioComponentInstantiation_LoadInProcess` — *Attempt* to load the component into the
> current process. Only available on macOS.

Values: `LoadOutOfProcess = 1` (macOS 10.11+), `LoadInProcess = 2` (macOS 10.11+, iOS
unavailable), `LoadedRemotely = 1u<<31` (**`API_UNAVAILABLE(macos)`** — not for us).

Two things to take from this: the verb is **"attempt"**, and the failure mode is a
**silent fallback with no error**.

### 2.2 The verification instrument — `isLoadedInProcess`

`AUAudioUnit.h:931-947`, `API_AVAILABLE(macos(10.15))`:

> If the AUAudioUnit is instantiated with `kAudioComponentInstantiation_LoadInProcess`,
> but the audio unit is not packaged properly to support loading in-process, the system
> will silently fall back to loading the audio unit out-of-process.
> This property can be used to determine whether the instantiation succeeded as intended…
> **The presence of an extension process is not sufficient indication that the audio unit
> failed to load in-process, since the framework might launch the audio unit extension
> process to fulfill auxiliary functionality.** If the audio unit is loaded in-process
> then rendering is done in the host process. Other operations that are not essential to
> rendering audio, might be done in the audio unit's extension process.

**This is the single most important paragraph in the document.** It says, in Apple's own
words, that a helper process existing tells you nothing about where rendering happens, and
it names the one property that does.

### 2.3 The crash-detection surface — which we do not use today

- `kAudioComponentInstanceInvalidationNotification` (`AUComponent.h:1128-1167`,
  macOS 10.11+): *"Notification generated when the connection to an audio unit extension
  process is invalidated… This notification can happen for several reasons, for instance
  the connection being invalidated or the process abnormally ending."* Register on
  `NSNotificationCenter.default` with `object:` = a specific `AUAudioUnit` or `nil` for
  all. `userInfo` carries `@"audioUnit"`, `@"Service PID"`, `@"Host PID"`,
  `@"Executable Path"`, `@"Descriptions"`.
- `kAudioComponentErr_InstanceInvalidated = -66749` (`AUComponent.h:785,831`): *"The
  component instance's implementation is not available, most likely because the process
  that published it is no longer running."*
- `kAudioUnitErr_RenderTimeout = -66745`: *"The audio unit did not satisfy the render
  request in time."*
- `kAudioComponentErr_InstanceTimedOut = -66754`.

**Measured, positive-controlled 2026-08-20: none of these four symbols appears anywhere
in `Sources/` or `Tests/`.** Seven spellings were grepped individually
(`InstanceInvalidation`, `InstanceInvalidated`, `66749`, `RenderTimeout`, `66745`,
`InstanceTimedOut`, `66754`), each read by its **own exit status** — all seven exit 1, zero
lines — against a positive control in the same command shape (`renderErrorSlot` → exit 0,
15 lines). Today a disconnected out-of-process AU would render silence forever with nothing
said. That hole exists **now**, for Apple's own v3 `ausp` units, independent of anything
this design decides.

### 2.4 What Apple documents for AUv2 — and what it does not

Apple's *Migrating Your Audio Unit Host to the AUv3 API*:

> A key difference between the two audio unit API versions is that **AUv2 audio units are
> loaded into the host's process**, whereas AUv3 audio units are loaded out-of-process by
> default. **In macOS only, if supported by the AUv3 audio unit, you can request loading
> it in-process** by passing the `loadInProcess` option…

Apple documents exactly one direction: AUv3 → in-process. **There is no Apple documentation
that an AUv2 can be loaded out-of-process.** Apple additionally states
(`AudioComponent.h:203-207`) that `kAudioComponentFlag_CanLoadInProcess` *"is always true
for V2 audio units"*. So the AUv2-out-of-process route, if it exists, is **undocumented
behaviour we would be depending on in the shipped render path**. That is a real risk and
it is priced into §3's decision as a per-component opt-in rather than a global default.

⚠️ **Measured disagreement with the header, worth recording:** reading `componentFlags`
off `AVAudioUnitComponent.audioComponentDescription` returns `canLoadInProcess = false`
for **all 75 components on this machine**, including every AUv2, while `isV3` and
`sandboxSafe` *are* carried correctly through the same field. Do not gate anything on
`canLoadInProcess` read by that route — it reads 0 for everything (n=75, 2026-08-20).

### 2.5 ⚠️ THE CORRECTION — m23-av-3's enabling fact is not established by its evidence

`docs/research/m23av-routeb-feasibility-probe.md` §2 is titled **"THE ENABLING FACT — macOS
bridges a classic AUv2 out-of-process"** and rests entirely on this observation:

```
  before any probe                      8      com.apple.audio.SandboxHelper.xpc
  during a [.loadOutOfProcess] hold     9   ← +1, a helper spawned
  during a [.loadInProcess]    hold     8   ← none
```

Apple's `isLoadedInProcess` documentation (§2.2) says that inference is invalid: *"The
presence of an extension process is not sufficient indication that the audio unit failed
to load in-process, since the framework might launch the audio unit extension process to
fulfill auxiliary functionality."*

**The claim may still be true. The evidence does not establish it.** The probe measured a
mechanism and concluded a cause. `isLoadedInProcess == false` is the observation that
would settle it, it costs one line, and nobody has run it. Until it is run:

- **ROADMAP.md:1189 (m23-av-3) overstates its case** and should be amended: its
  ⭐ "measured, not assumed" claim is a measurement of helper-process count, not of render
  locality.
- No leg of this design that depends on AUv2-out-of-process may start.

This correction is not a criticism of that probe — it caught a much bigger error (that
out-of-process could only ever help AUv3), it was right to overturn it, and its instantiate
timings are good data. It reached for the instrument that was to hand. The right instrument
was one property away.

### 2.6 The installed population — re-measured 2026-08-20, and it changed

Enumerated via `AVAudioUnitComponentManager` (no instantiation): **75 components, 11
non-Apple, ZERO flagged `isV3`.**

| name | type | sub | mfr | isV3 | sandboxSafe |
|---|---|---|---|---|---|
| EchoJay | aufx | EcJy | Ecjy | no | no |
| Reaktor 6 MFX | aumf | NiR6 | -NI- | no | no |
| Reaktor 6 MIDIFX | aumi | NiR6 | -NI- | no | no |
| Dexed | aumu | Dexd | DGSB | no | no |
| **DecentSampler** | aumu | Dsmp | Dldy | **no** | **yes** |
| Splice INSTRUMENT | aumu | Inst | Splc | no | no |
| Kontakt 8 | aumu | NiK8 | -NI- | no | no |
| Reaktor 6 | aumu | NiR6 | -NI- | no | no |
| **Surge XT** | aumu | SgXT | VmbA | **no** | **yes** |
| Attracktive | aumu | TSAt | TSCP | no | no |
| TyrellN6 | aumu | tYn6 | UHfX | no | no |

The only `isV3` units on the machine remain Apple's five `ausp` speech synthesizers.

Two facts fall out:

- **"AUv3-only" covers zero of the user's plugins.** Measured twice, 16 days apart
  (73/9/zero on 2026-08-04; 75/11/zero on 2026-08-20). That kills alternative A1 outright
  (§4).
- **`sandboxSafe` is declared by 2 of 11** — DecentSampler and Surge XT, both JUCE builds
  that also declare `factoryFunction`. If out-of-process viability tracks `sandboxSafe`,
  best-case AUv2 coverage is 2/11 and Kontakt 8 (the heaviest, most crash-prone class) is
  not in it. **Unverified — a Leg 0 measurement**, and one more reason the mode is
  per-component.

Note also that the population is not static: DecentSampler — **the plugin that crashed** —
was not installed when the 2026-08-04 probe ran. Any conclusion of the form "this machine
has no X" carries a date.

### 2.7 What out-of-process silently does **not** protect against

1. **A request that quietly fell back.** No error is returned. `isLoadedInProcess` is the
   only check (§2.1, §2.2).
2. **A hang.** A render hang becomes `kAudioUnitErr_RenderTimeout` (bounded — by an
   interval that appears in no header). A hung *instantiate* still hangs; that is
   `DeadlineRace`'s job and it already ships. A hung plugin **UI** still hangs ViewBridge.
3. **Damage already done to your project data** before the crash. Nothing protects that;
   that is autosave's department (§7).
4. **The plugin's own live state.** A dead helper takes it with it (§7.3).
5. **Apple's 23 built-in effects**, which were measured good on 2026-08-13 (all enumerate,
   1–6 ms load, full parameter trees). Moving them out of process would pay cost for zero
   benefit. They stay in-process, permanently (§3, §11 F8).

---

## 3. THE DECISION

**Yes — DAW Pro should host third-party Audio Units out of process, as a per-component
hosting mode, defaulting off and flipping to on per component only on evidence. Apple's
built-in components are pinned in-process permanently and never participate.**

Stated as the four rulings an implementing agent needs:

- **R1.** Hosting locality becomes an explicit, persisted, per-component **preference**
  (`inProcess` | `outOfProcess` | `auto`), not a hardcoded `isV3` branch. It is an
  application preference, **not project data** — a project must open identically on a
  machine with different plugin trust.
- **R2.** The current `isV3`-gated, `catch`-fallback shape at
  `AUHostRegistry.swift:577-588` (effects) and `:748-759` (instruments) is **replaced by a
  single shared function** returning `AudioComponentInstantiationOptions`, called from both
  sites. Two call sites that must agree, and today do only by copy-paste, become one
  authority. The `catch`-shaped fallback is deleted: a hang does not throw.
- **R3.** After instantiation the host **verifies locality with `isLoadedInProcess` and
  publishes the answer**. A request that fell back is reported, never assumed to have
  taken. (This is the project's own "A SETTER'S RETURN IS NOT PROOF IT TOOK", applied to a
  request that Apple explicitly documents as best-effort.)
- **R4.** Apple-manufactured components (`componentManufacturer == 'appl'`) are **never**
  instantiated with `.loadOutOfProcess`, regardless of preference. Enforced by a test, not
  by convention.

### 3.1 The gate — this decision is conditional, and here is exactly on what

R1–R4 are the shape. Whether the shape gets a *default* depends on Leg 0 (§10), which must
produce, for DecentSampler specifically (the plugin that actually crashed):

| gate | measurement | if it fails |
|---|---|---|
| **G0** ⭐ | **ADDED 2026-08-20. Cost AU-instance reuse across renders first.** §15.7 measured that the bounce dropout is **path-specific** and tracks a **double instantiation**, and §1.2 now suspects the crash of being our own instantiate/teardown racing the plugin's deferred work. If both are symptoms of *fresh AU instances per render*, then reusing an instance addresses both — for a fraction of this milestone's cost. | **This gate fails by not being run.** If nobody costs instance reuse, Legs 3–7 may buy, at weeks of RT-risky work, something a lifecycle change buys in days. Not a measurement gate: a **costing** gate, and it precedes G1 in time. |
| **G1** | `isLoadedInProcess == false` after `[.loadOutOfProcess]` | The AUv2 route does not exist. Legs 3–7 are cancelled; Legs 1 + 2 still ship and still deliver. Reopen only if the user's plugin set gains a real AUv3. |
| **G2** | Kill the helper mid-render → host survives; `renderBlock` returns −66749 (or −66745); the invalidation notification fires | Out-of-process is decoration. Abandon; Leg 1 still ships. |
| **G3** | Per-quantum `renderBlock` p99 ≤ 15 % of the 512-frame budget (10.67 ms @ 48 kHz), max ≤ 50 %, zero `RenderTimeout` in 10 min — **thresholds PROPOSED, not measured (§6.1); the first real distribution may move them** | Ship as opt-in only, with an explicit "this plugin may glitch under load" warning; never default it on. |
| **G4** | An out-of-process AU survives a faster-than-realtime `OfflineRenderer` pull without dropouts. ⚠️ **WIDENED 2026-08-20: name the verbs.** The dropout is path-specific (§15.7) — `render_mixdown` was correct from the first cold call while `render_stems` and `track_bounce_in_place` both dropped — so G4 run against `render_mixdown` alone can pass while the two broken paths stay broken. G4 must be run against **all three verbs**, cold and warm, and report all three. | Out-of-process is disabled for bounces; the offline path re-instantiates in-process. **Non-negotiable — see §11 F11.** |

**"Measure first" is not a deferral of the decision.** The decision is made: per-component
opt-in, verified locality, built-ins never. What Leg 0 decides is whether the feature has a
default, and for which plugins.

---

## 4. THE TWO STRONGEST ALTERNATIVES, AND WHY THEY LOSE

**A1 — AUv3-only (Apple's supported path).** Adopt out-of-process only where Apple
documents it: `isV3` components, which are out-of-process by default anyway. Zero
undocumented behaviour, zero risk.
**Why it loses: measured zero coverage.** Not one of the 11 third-party units installed
here is `isV3` — measured 2026-08-04 (9 units) and again 2026-08-20 (11 units). It would
not have prevented either crash, and it would not prevent the next one. It is the *safe*
answer and it is worth nothing. This is the strongest alternative on principle and the
weakest on evidence, and the evidence is not close.

**A2 — Isolate only the plugin UI, keep render in-process.** Intuitively the best trade:
the risky, sprawling, vendor-written code is the GUI; the render is a tight loop. Pay no
render-path IPC at all.
**Why it loses, three ways, any one sufficient:**
(i) **The API does not exist.** An `AUAudioUnit`'s view is vended by
`requestViewController` on the instance; whichever process owns the instance owns the view.
Apple provides no split. Building our own would mean an XPC service that hosts a second
copy of the plugin purely for its UI — two instances, two states, a synchronisation problem
with no correct answer.
(ii) **The measured crash was not in the view.** Frame 4 is a `CFRunLoopSource0` callback —
JUCE's message queue, which is installed when the plugin is constructed and fires whether
or not any window is open. Both crashes had a `JUCE: Timer` thread and an
`OnlineManager TaskRunner` running. UI isolation would have caught neither.
(iii) **It is the most expensive option.** A signed helper app, ViewBridge plumbing, an app
bundle, and a remote-view path that `docs/research/design-vi-b-au-windows.md:434` already
records as un-screenshottable. Most cost, least coverage.

**A3 — In-process hardening: extend the ObjC exception barrier, or catch SIGSEGV.**
`withObjCExceptionBarrier` already converts an `NSException` into a teaching error.
**Why it loses:** the fault is SIGSEGV from a corrupted pointer, not an `NSException` —
`@try/@catch` cannot see it. A Mach exception handler that swallowed it would resume
execution in an address space we have just proven contains a text fragment where a pointer
should be. The barrier's own doc comment already accepts leaked frames as the price of not
poisoning the main actor; swallowing a segfault is that trade an order of magnitude worse.
Crashing and recovering from autosave is *more* honest than continuing in a corrupt heap.

**A4 — Sacrificial pre-flight validation.** Load each plugin in a throwaway subprocess at
scan time; blacklist the ones that crash.
**Why it loses:** the crashes happened at 6 minutes and 108 minutes of use. A pre-flight
would have passed, twice, and then handed the user a green light.

**A5 — Do nothing; autosave already covers it.**
**Why it loses:** autosave protects the *file*, not the *session* (§7.2). It cannot save a
take in progress, a bounce in progress, or an hour of flow state. The tester's own wording
concedes the mitigation works and asks for the failure not to matter.

⚠️ **ONE CANDIDATE IS DELIBERATELY NOT IN THIS SECTION.** *Reuse AU instances across
renders instead of building fresh ones* was added 2026-08-20 and it does **not** lose —
which is why it is not listed here among alternatives that do. It is a **precondition** on
the whole milestone rather than a competitor to it, so it lives in §3.1 as **G0**, with the
measurement behind it in **§15.7**. A reader scanning this section for "everything else was
considered and rejected" would otherwise conclude wrongly.

---

## 5. THE INVARIANT COLLISION — stated plainly, not buried

> *The render thread never allocates, locks, or blocks.*
> (`CLAUDE.md`; `docs/ARCHITECTURE.md` §RT-safety invariants; `docs/research/audit-rt-safety.md`.)

**Out-of-process hosting makes the render thread synchronously wait on another process, by
construction.** That is a blocking wait. There is no way to phrase it that makes it not
one. This section exists so that no close-out can claim the invariant was unaffected.

### 5.1 Why it is nevertheless admissible

1. The wait is **bounded and reports failure** rather than deadlocking:
   `kAudioUnitErr_RenderTimeout` exists precisely because the system enforces a deadline on
   it, and `kAudioComponentErr_InstanceInvalidated` covers the dead-peer case.
2. It is **Apple's own hosting model** for every AUv3, which every macOS DAW that hosts
   AUv3 already ships. We would not be inventing a risk; we would be joining one.
3. **Our failure lane already exists and is already correct** (§5.2).

The invariant is therefore amended, not broken, and the amendment must be written down:
*the render thread never allocates, locks, or blocks — except for a bounded, system-enforced
wait on an explicitly opted-in out-of-process plugin, whose timeout is a normal
non-`noErr` return handled by the existing silence lane.* If the user rules yes, that
sentence goes into `docs/ARCHITECTURE.md` §RT-safety invariants, verbatim, in the same
change as the code.

### 5.2 The asset — the failure lane is already built

`HostedAUInstrument.render()` step 4 (`HostedAUInstrument.swift:247-253`) and
`HostedAUEffect.process()` step 4 (`HostedAUEffect.swift:178-181`) already do exactly the
right thing with any non-`noErr` status: **exact silence** (instrument) or **dry
passthrough** (effect), an atomic breadcrumb into `renderErrorSlot`, no logging, no
trapping, no allocation. `−66749` and `−66745` land there for free, today, with zero
render-path edits. This materially lowers the cost of the whole change and it should be
said out loud in the close-out.

### 5.3 What actually breaks — four concrete items

The documented contract ("`render()` and `reset()` may touch ONLY the two block `let`s …
plus preallocated memory") stays **textually true**. What changes is the **cost model
behind it**, and in three places that is not a detail:

- **B1 — `scheduleMIDI` becomes a potential round trip, once per event.**
  `HostedAUInstrument.render()` calls `scheduleMIDI` in a loop, once per `ScheduledMIDIEvent`,
  with no batching (`HostedAUInstrument.swift:188-221`). In-process that is a block call.
  Out-of-process it may be a message. **The M28 breath pad emits continuous CC11**, and
  m28-bug moved the offline block to 512 frames; a dense controller stream can mean dozens
  of calls per quantum. **This is the largest RT risk in the design and it is specific to
  this codebase** — a host that only sends note on/off would never see it. Leg 0-C
  measurement 3 exists for exactly this.
- **B2 — `HostedAUEffect.pullInput` is a callback *into* us, *from* the plugin, during
  its render.** Out-of-process that is a nested crossing per quantum per effect — the worst
  shape in the design. It may well be that Apple's bridge pushes input alongside the render
  request and never calls back; we do not know, and it is measurable (Leg 0-C
  measurement 2).
- **B3 — `HostedAUEffect.reset()` calls `auAudioUnit.reset()` on the render thread.** This
  is the single sanctioned ObjC message on the render path, justified in its doc comment
  as "fires only at reset edges, never per quantum". That justification was written for an
  in-process ObjC dispatch. **For an out-of-process instance it is an unbounded IPC round
  trip on the render thread at a transport edge — i.e. exactly at a moment the user is
  listening for.** It must be re-derived or moved. Proposed resolution: for out-of-process
  instances only, `reset()` sets an atomic flag consumed on the main actor, and the render
  path relies on the MIDI-message reset sequence the instrument path already uses. Decide
  it in Leg 3; do not let it ride.
- **B4 — `latency` and PDC.** `HostedAUEffect` captures `au.latency` at prepare
  (`:63`, `:136`). If the bridge adds buffering, the reported figure may not describe the
  bridged path. m25-n already suspects PDC for AU inserts is broken and its measuring leg
  returned silence. Rider, not a blocker — but the close-out must not claim PDC is
  unaffected.

Unchanged and fine: `hostSampleTime`'s monotonic timeline; the `shadowABL` /
buffer-substitution copy-back (out-of-process AUs write into memory the proxy owns, which
is precisely the substitution case step 5 already handles); every preallocation.

### 5.4 DAWCore stays clean

Nothing in this design puts CoreAudio, AudioToolbox, or process management into DAWCore.
The hosting preference is a pure `Codable`/`Sendable` value type; every `AudioComponent*`
call stays in DAWEngine behind `AudioEngineControlling`. If any leg finds itself importing
`AudioToolbox` into DAWCore, that leg is wrong.

---

## 6. REAL-TIME COST — what is known, and the honest answer

**What is known** (`m23av-routeb-feasibility-probe.md` §2, 2026-08-04 — *prepare*-time, not
render-time):

| phase | Surge XT in-proc | Surge XT out-of-proc | Kontakt 8 out-of-proc |
|---|---|---|---|
| instantiate | 0.073 s | 0.212–0.227 s | 1.118 s |
| `setFormat` | 0.000008 s | 0.00019–0.00022 s | 0.00018 s |
| `allocateRenderResources` | 0.00009 s | 0.042–0.044 s | 0.040 s |

Those are one-time costs on the main actor, already inside `DeadlineRace`, and against a
10 s production wall they are noise. **They say nothing about the render path.**

**The honest answer: the per-quantum cost has never been measured here, and no trustworthy
public number exists.** I searched; the Apple forums and the one real-world host change I
found (Mixxx PR #16106, which switched to `LoadOutOfProcess` for exactly this crash-isolation
reason) report **no** latency or CPU data at all — Mixxx's own follow-up issue was about
*init* time, not render. Do not let any implementing agent quote a number for this from
memory or from a forum. Measure it.

### 6.1 What to measure (Leg 0-C, and again as a shipped gate in Leg 4)

Budget to spend against: **512 frames @ 48 kHz = 10.67 ms**
(`RenderBlockSize.offlineFrames = 512`, `Sources/DAWCore/RenderBlockSize.swift:73` — m28-bug
moved it down from 4096; use the same figure for the live path so one number governs).

1. **Per-quantum `renderBlock` wall time, full distribution** — p50 / p95 / p99 / max over
   ≥ 60 s of continuous render. In-process vs out-of-process, same plugin, same block size.
   **The tail is the whole question; a mean is worthless here.**
2. **The same for a `HostedAUEffect`**, to price the `pullInput` nested crossing (B2).
3. **The same with a breath-pad-shaped CC stream** (CC11 at ~5 ms intervals, plus notes) to
   price `scheduleMIDI` per event (B1). Compare against the same stream with CC stripped —
   the delta *is* the per-event IPC cost.
4. **`kAudioUnitErr_RenderTimeout` count** over the run. Non-zero is a failure, not a
   statistic.
5. **Serial cost**: four out-of-process inserts on one track, since the chain walks them in
   series inside one quantum.
6. **Post-mortem cost**: after killing the helper, the per-callback time for the next 200
   quanta. If a dead plugin costs a full render timeout every quantum, one dead plugin is a
   **graph-wide** dropout, not a per-track one (§11 F2).

**Instrument:** extend the existing preallocated-atomic-cell pattern in
`Sources/DAWEngine/EnginePerformance.swift` (it already keeps `renderTimeNs`,
`overrunCount`, a lock-free `bump`, and `snapshotAndReset`). Add per-instance cells and a
coarse log-bucket histogram. **Do not invent a new mechanism and do not log on the render
thread.**

**Proposed accept/reject (a proposal, not a measurement — label it as such wherever it is
quoted):** admissible for realtime if p99 ≤ 15 % of budget (1.6 ms), max ≤ 50 % (5.3 ms),
and zero `RenderTimeout` over 10 minutes.

---

## 7. WHAT SURVIVES A CRASH, AND WHAT DOES NOT

### 7.1 Today, in-process (what the tester experienced)

The app disappears mid-sentence. On relaunch the `session.lock` sentinel written at the
previous launch is still present → a crash is inferred → `project.recoveryStatus.available
== true`, carrying `savedAt`, `sourcePath`, `editCount` from `manifest.json`, and the
launch sheet offers recovery. **This worked both times. It is shipped, effective, and
untouched by this design.**

### 7.2 What autosave covers — and the five things it cannot

Covers: the project document as of the last autosave tick, including each hosted AU's
captured `fullStateForDocument`, with an honest manifest so the offer can describe itself.

Cannot cover:
1. **Edits since the last tick.**
2. **Session state that is not document state** — transport position, armed tracks, solo/mute
   scratch, open windows, the copilot conversation's live context.
3. **An in-progress recording's un-flushed tail.** A take being captured when the process
   dies is damaged or gone.
4. **Undo history.** Recovery starts you at a state with no way back past it.
5. **The interruption itself.** A live take is ruined; a running bounce is aborted; the
   user's attention is spent. This is the one the tester is actually asking about, and it
   is the one no autosave can ever address. *Autosave protects the file. It does not
   protect the session.*

### 7.3 With out-of-process, on a plugin crash

The helper dies; **DAWApp lives**. Concretely:

- `renderBlock` returns `−66749` → step 4 writes **exact silence** for that instrument (or
  **dry passthrough** for that effect) and stores the status atomically. **Everything else
  keeps playing.** Transport does not stop. Other tracks are unaffected. A running bounce
  continues (with that track silent — see §11 F11 for why that may be worse, not better,
  and why G4 exists).
- `kAudioComponentInstanceInvalidationNotification` fires with `Service PID`,
  `Host PID`, `Executable Path`, and the component `Descriptions`.
- The user sees, in the design language's voice, something like:
  *"DecentSampler stopped responding and was disconnected. This track is silent until you
  reload it. Settings from your last save were kept; changes made since then are lost.
  [Reload plugin]"*

**What is still lost, and the design must not pretend otherwise:** the plugin instance's
live state. `fullStateForDocument` on a dead instance returns nil — there is nothing to
ask. The honest recovery is to re-instantiate from `config.stateData`, the state we last
persisted, which is **exactly what `AUHostRegistry.performPrepare` already does** from
`PrepareKey.stateData`. Reload therefore reuses the shipped prepare path and needs no new
machinery.

So the accurate one-line summary for the close-out: **out-of-process converts "you lose the
app and everything since the last autosave" into "you lose one plugin's unsaved knob
moves".** That is a large improvement and it is not "it never mattered".

### 7.4 The reload policy — settled here, because getting it wrong is worse than not shipping

- **No automatic reload on the first crash.** A crash-looping plugin plus auto-reload is an
  infinite loop that renders the app unusable in a *new* way.
- **One-click reload**, offered in the notice and available on the wire.
- **Trip to `SilentPlaceholderInstrument` after the second invalidation of the same
  component within 60 s**, and say so. `SilentPlaceholderInstrument`
  (`Sources/DAWEngine/AudioUnits/SilentPlaceholderInstrument.swift`) already exists and
  already renders exact zeros — this is a status transition, not new render code.
- The trip is also the mitigation for §11 F2 (a dead peer costing a render timeout every
  quantum).

---

## 8. THE PREPARE-WALL BLIND SPOT — folded in, but independent

This is a related robustness hole in the same subsystem, and it is a cheap independent win.

**The facts.** `AUHostRegistry.productionPrepareTimeout = 10 s` (`:279`);
`testPrepareTimeout = 60 s` (`:313`); `defaultPrepareTimeout` branches on
`TestEnvironment.isRunningTests` (`:323-324`). GM/DLS bank prepare has measured 17.3–26.9 s
inside the test harness (m23-at, n=8), re-measured at 30.994 s worst-of-5 and 49.311 s under
ordinary machine load (m23-aw).

**The hole is not the constant — do not touch the constant.** `AUPrepareTimeoutPolicyTests`
pins both values and `scripts/gates/m23aw-prepare-headroom.mjs` independently fails on the
same edit; m23-at and m23-aw both forbid raising it, and they are right to.

The hole is that **the 10 s branch is unreachable from any test process**, so the
production wall's *consequences* have never been executed by a test: the
`.failed("Audio Unit preparation timed out after … — component may be stalled")`
publication (`:638-640` effects, mirrored for instruments), the ledger disarm, the fallback
to `SilentPlaceholderInstrument`, and the (absent) user-facing message. A whole failure
path ships untested, and the harness structurally cannot reach it.

⚠️ **And it is reachable in production.** The 17–31 s figures are harness-load figures, not
user figures — but this user's machine also runs an ~80 GB ACE-Step sidecar and Kontakt 8.
A loaded real session is not obviously safer than a loaded test run. Today, a legitimate GM
bank prepare that crosses 10 s on a busy machine produces **a silent track and no
explanation**.

**The fix is a test, not a source change** (§10 Leg 2), which also makes it the one leg that
is completely safe to land while other agents hold `Sources/DAWEngine/`.

---

## 9. STAGING — legs that land and deliver independently

| leg | what it delivers | cost | needs Leg 0? | touches `Sources/`? |
|---|---|---|---|---|
| **−1** | **The discriminator.** Is the crash OURS (teardown-ordering UAF) rather than the plugin's? The only measurement that can make this whole milestone unnecessary. | **~2 h** | — | no (probe only) |
| **0** | **The spike.** Locality, kill-survival, per-quantum cost, offline survival, `sandboxSafe` correlation. No shipped change. | ~1 day | — | no (probe only) |
| **1** | **Plugin-death legibility.** Observe the invalidation notification; map −66749/−66745 to a named, user-readable notice; stop rendering silent-and-mute. | 1–2 days | **no** | yes (small, additive) |
| **2** | **The production prepare wall becomes test-reachable.** | ~2 h | no | **no** |
| **3** | **Hosting mode plumbing.** Per-component preference, one shared options function, `isLoadedInProcess` verification, wire + MCP. No default change. | 2–3 days | **yes (G1)** | yes |
| **4** | **Render-path cost gate.** Per-instance RT telemetry + the accept/reject numbers as a gate script. | 2 days | yes | yes |
| **5** | **Default flip, per component, evidence-gated.** | 1 day | yes (G1–G4) | yes |
| **6** | **Reload + crash-loop policy** (§7.4). | 1–2 days | yes | yes |
| **7** | **Plugin UI across the boundary.** Live-gate-only, human eyes required. | ? | yes | yes |
| **R** | **Render readiness (§15).** `renderingOffline` before allocate, + a discardable pre-roll. **Fixes a live user-reported bounce defect and is INDEPENDENT of the whole out-of-process question.** ✅ **R-1 SHIPPED (`412cb33`) and MEASURED NOT TO CURE IT** — DecentSampler ignores the flag. ⛔ **R-2 is therefore REQUIRED, not optional.** | ~~~4 h~~ R-1 done; 2–3 d for R-2 | **no** | yes |
| **G0** | ⚠️ **A COSTING GATE, NOT A LEG — there is no "Leg G0" in §10; it lives in §3.1 with the other gates.** **Cost AU-instance reuse across renders (§15.7, §3.1).** The bounce dropout tracks instantiation count across verbs and the crash's leading hypothesis is our own per-render instantiate/teardown — one lifecycle change may address both. **Fails by not being run.** | ~1 d to cost | **no** | no (costing only) |
| **B** | **Pitch-bend range (§16).** Emit RPN 0 so a hosted AU is not silently stuck at ±2 semitones. Independent. | ~1 d | **no** | yes |

### 9.1 The cheapest useful first leg

**Leg 1 — plugin-death legibility.** It is the cheapest leg that ships user-visible value
against the reported problem, and its value is **completely independent of whether
out-of-process is ever adopted**: an Apple `ausp` v3 unit is out-of-process *today*, and if
its connection dropped right now the app would render silence forever and say nothing.
Leg 1 closes a live hole, changes **zero** render-thread bytes (it consumes breadcrumbs the
render path already writes), and builds the exact user-facing surface Legs 5–6 need later.
If the user rules "no" on the whole milestone, Leg 1 is still worth doing.

**Leg 2 is cheaper still** (~2 h, no `Sources/` change) but it addresses a different hole.
Do both first, in either order; they cannot conflict.

**Recommended order, REVISED 2026-08-20 now that R-1 has shipped and failed to cure:
~~R-1~~ → G0 → R-2 → −1 → 2 → 1 → 0 → (gate G1–G4) → 3 → 4 → 5 → 6 → 7**, with **B**
droppable in anywhere.

⚠️⚠️ **THE ORIGINAL "R-1 GOES FIRST" RULING WAS RIGHT AND IS NOW SPENT.** R-1 shipped in
`412cb33`; the tester verified the wiring rather than assuming it; **DecentSampler does not
honour the flag and the bounces still drop** (§15.5 status block). The reasoning that put
it first is unchanged and now transfers to **R-2**: it is a *live, measured, user-reported*
defect that silently destroys the head of real bounces, and it is a hard prerequisite of
Leg 5 (§11 F11). Legs −1 through 7 all concern a crash that autosave already survives; R
concerns audio the user has already lost, in files they may have shipped. **Fix the thing
that silently corrupts output before the thing that loudly stops the app.**

⭐ **G0 GOES AHEAD OF R-2, AND IT IS A DAY.** §15.7 measured that the dropout is
path-specific and tracks a double instantiation, and §1.2's leading crash hypothesis is the
same lifecycle. If reusing an AU instance across renders addresses both, R-2's 2–3 days of
pre-roll machinery — and possibly Legs 3–7 — are the wrong purchase. This is the same
argument that puts Leg −1 ahead of Legs 2 and 1, applied one level up. ⛔ **Cost it against
BOTH criteria in §15.5, never against "did the dropout go away".**

⚠️ **Leg −1 runs FIRST, ahead of everything, and it is two hours.** It is the only step
that can make Legs 3–7 unnecessary: if the identical stack reproduces on the
`releaseInstrument` open/close pattern, the crash is a teardown-ordering use-after-free in
OUR lifecycle, and the mitigation is a deferred release on the m18-d `dlsBankQueue`
precedent — days instead of weeks (§11 F12). Spending 2.5 days on Legs 2 and 1 before
taking that reading would be spending the milestone before checking whether it is needed.
⚠️ **A non-reproduction attributes nothing** — absence of evidence from a hand-built probe
is the weakest result there is, and it must be recorded as inconclusive, never as "the
plugin's fault, confirmed".

Then Leg 2 because it is two hours and blocks nothing. Leg 1 before Leg 0 because Leg 0's
kill test is far easier to interpret once the notification path is wired and observable.

### 9.2 The partial answer worth taking seriously

The task asked whether a partial answer captures most of the benefit for a fraction of the
cost. **It does, and it is Legs 1 + 2 + 6 — the *legibility and recovery* half — not the
AUv3-only or UI-only halves.** Those two are dead (§4 A1, A2). But:

- Legs 1 + 6 turn every plugin failure we *can* detect into a named, recoverable event
  instead of silence, at ~3 days and no render-path risk.
- Leg 2 closes a shipped untested failure path in two hours.
- Legs 3–5, which cost the most and carry all the RT risk, buy exactly one additional
  thing: **surviving the segfault at all**. That is the thing the tester asked for, and it
  is worth buying — but it should be bought last, with G1–G4 in hand, and the user should
  know that ~40 % of the perceived benefit lands in the first three days.

---

## 10. IMPLEMENTATION PLAN

### Leg 0 — the spike (no shipped change)

Extend `scripts/probes/auprobe.swift` (already has `--instantiate in|out <subtype>`; keep
the one-instantiation-per-process discipline — a wedging plugin poisons the process it
loads into):

1. **`--locality <subtype>`** — instantiate with `[.loadOutOfProcess]`, print
   `au.isLoadedInProcess`. **This is G1 and it is the whole reason the spike exists.** Run
   for `Dsmp` (DecentSampler), `SgXT` (Surge XT), `NiK8` (Kontakt 8), `Dexd`, `tYn6`, and
   one Apple v3 `ausp` as a **positive control** (it must report out-of-process, or the
   instrument itself is not working).
2. **`--killtest <subtype>`** — instantiate out-of-process, allocate, run a 512-frame
   render loop on a background thread, register for
   `kAudioComponentInstanceInvalidationNotification`, then kill the helper and record:
   does the probe survive; what status does `renderBlock` return; does the notification
   fire and with what `Service PID` / `Executable Path`; and the per-callback time for the
   next 200 quanta (§6.1 measurement 6).
   ⚠️ **Standing-constraint discipline, non-negotiable:** snapshot the process list
   *before* instantiation, snapshot again *after*, and kill **only** a PID that appears in
   the difference and whose executable path is an Apple audio helper. **Never `pkill`,
   never `pgrep` by pattern, never a PID serving port 17600.** The user's live app is on
   this machine while this runs.
3. **`--rendercost <subtype> [--cc]`** — §6.1 measurements 1–3 and 5, printing the full
   distribution, not a mean.
4. **`--offline <subtype>`** — pull faster than realtime for 60 s of audio and count
   dropouts / `RenderTimeout`. **This is G4** and it is the measurement that can turn this
   feature from a fix into a regression (§11 F11).
5. **The teardown discriminator for §1.2** — instantiate DecentSampler in-process, open and
   close it repeatedly on the pattern `releaseInstrument` uses, and see whether the identical
   stack reproduces. A reproduction attributes the crash to teardown ordering and unlocks
   F12's cheap mitigation; a non-reproduction attributes nothing (absence of evidence), and
   the doc must say so.

**Output:** a measured addendum at `docs/research/m29-leg0-measurements.md`, in the shape
of `m23av-routeb-feasibility-probe.md`, stating G1–G4 pass/fail explicitly.
**Gate:** none — it is the gate.

### Leg 1 — plugin-death legibility (cheapest useful leg)

Files:
- **New** `Sources/DAWEngine/AudioUnits/AUInstanceInvalidationMonitor.swift` — registers
  once for `kAudioComponentInstanceInvalidationNotification` (`object: nil`). The
  notification arrives on an arbitrary thread; capture **only** `ObjectIdentifier` of
  `note.object`, plus the `Service PID` / `Executable Path` / `Descriptions` strings, into
  a `Sendable` struct, then hop to the main actor. **Never message the `AUAudioUnit` off
  the main actor** — that is the same rule `HostedAUInstrument`'s contract states, and
  `ObjectIdentifier` capture obeys it (no ObjC message is sent).
- `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift` — own the monitor; on a main-actor
  hop, match the identifier against `instruments[*].auAudioUnit` / `effects[*].auAudioUnit`,
  publish `status[id] = .failed("<Name> was disconnected — the plugin stopped responding")`,
  and post an engine notice.
- `Sources/DAWEngine/AudioEngine.swift` — route through the existing
  `engineNoticeHandler` (`:607`) with a **new code string** `plugin-disconnected`.
  `EngineNoticeEvent` (`Sources/DAWCore/EngineProtocol.swift:199`) is string-coded and
  coalescing, so this is **purely additive**: no enum change, no wire-count change, no MCP
  change.
- OSStatus → text: extend the reason mapping so `−66749` and `−66745` read as
  *"the plugin's process stopped responding"* and *"the plugin did not answer in time"*
  rather than a bare number. Consume the existing `lastRenderError` breadcrumbs
  (`HostedAUInstrument.swift:113-117`, `HostedAUEffect.swift:105-109`) from the main-actor
  poll that already exists.

**Render path: zero bytes changed.** Everything here consumes what step 4 already writes.

Tests — **new** `Tests/DAWEngineTests/AUInstanceInvalidationTests.swift`:
- Prepare a real `AUDelay` / `DLSMusicDevice` (both already used headless in this suite),
  hand-post `kAudioComponentInstanceInvalidationNotification` with that object, assert the
  status transition and the notice.
- **Negative control:** post the same notification with an unrelated object; assert nothing
  changes. (Without this the test passes for a monitor that fires on everything.)
- OSStatus mapping test for `−66749` / `−66745`, including that an unmapped status still
  produces readable text.
- A test that the notice code is `plugin-disconnected` and coalesces (the ring's contract).

### Leg 2 — the production prepare wall becomes test-reachable (**zero `Sources/` change**)

**New** `Tests/DAWEngineTests/AUPrepareProductionWallTests.swift`. Both `prepare` and
`prepareEffect` already accept an explicit `timeout:`, and `instantiator` is already a test
seam (`AUHostRegistry.swift:258-263`) — every seam this needs exists.

- **The consequence chain, cheap:** with a stub `instantiator` that never returns and an
  explicit short budget, assert (a) `status[id] == .failed(…)` containing "timed out",
  (b) the ledger disarmed, (c) `preparedInstrument(forTrack:)` is nil so the engine uses
  `SilentPlaceholderInstrument`, (d) `engine.auPrepareStats` reports `overdue == true`
  while in flight and the entry is gone after. This exercises the **path**.
- **The shipped number, executed rather than compared — one test:** the same stub with
  `timeout: AUHostRegistry.productionPrepareTimeout`. It costs ~10 s of wall time; own that
  cost, put it in its own serialized suite, and say in the doc comment why it is not
  parameterised down (the existing pin *compares* the constant; nothing *runs* it).
- **Anti-vacuity:** assert that an explicitly passed `timeout:` is honoured and not
  silently replaced by `defaultPrepareTimeout` — otherwise every assertion above is about
  the 60 s test value wearing a 10 s label.
- Do **not** modify `productionPrepareTimeout` or `testPrepareTimeout`. Two gates forbid it
  and they are correct.

Second, separable half (needs `Sources/` — schedule after the concurrent agents finish):
a timed-out prepare should raise the same `plugin-disconnected`-family notice Leg 1 builds,
so the user learns why a track is silent. Fold into Leg 1's surface; do not build a second.

### Leg 3 — hosting mode plumbing (gated on G1)

- **New** `Sources/DAWCore/AUHostingPreferences.swift` — pure `Codable`/`Sendable`:
  `enum AUHostingMode { case inProcess, outOfProcess, auto }` keyed by
  `AudioUnitComponentID`. **Application preference, persisted under `AppDirectories`,
  never project data** (a project must open identically on a machine with different plugin
  trust). No AudioToolbox import.
- `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift` — **delete both copies** of the
  `isV3`/`catch` branch (`:577-588`, `:748-759`) and replace with **one** shared
  `static func instantiationOptions(component:isV3:mode:) -> AudioComponentInstantiationOptions`
  called from both sites. R2. The `catch`-shaped fallback goes: a hang does not throw, and
  `DeadlineRace` already owns the hang.
- **R3 verification:** immediately after instantiation, read `isLoadedInProcess` and record
  it on the prepare outcome. If the mode demanded isolation and the system fell back,
  publish that fact — never assume the request took.
- **R4 enforcement:** `'appl'` components are pinned in-process. A test asserts that
  `instantiationOptions` never returns `.loadOutOfProcess` for an Apple manufacturer,
  whatever the preference says.
- **B3 resolution** (§5.3): decide `HostedAUEffect.reset()` here, in this leg, with the
  Leg 0 numbers in hand.
- **Wire (additive only, per the standing rule):** `au.setHostingMode {component, mode}`,
  `au.hostingModes {}` → `[{component, mode, effective, loadedInProcess?}]`. MCP mirror
  `au_set_hosting_mode`, `au_hosting_modes`. `allCommands` **186 → 188**; MCP tools
  **191 → 193**; the plugin mirror must move in lockstep. ⚠️ **The wire-count pin is 19
  lines across 18 files, three spell it `all.count ==`, and `ReferenceCommandTests` pins it
  as an *offset* (`dropLast(27)` as of the m28-knob measurement) that contains no digit any value-grep can find — a
  literal sweep structurally cannot find them all. Only a full `ReferenceCommandTests` run
  verifies this.** Update `docs/ARCHITECTURE.md` §"Wire surface — CURRENT TOTALS" with its
  own stated method.
- Tests: `Tests/DAWCoreTests/AUHostingPreferencesTests.swift` (pure, round-trip, unknown
  component tolerance); `Tests/DAWEngineTests/AUHostingModeTests.swift` (one function, both
  call sites, Apple pin, fallback reporting); `Tests/DAWControlTests/AUHostingModeCommandTests.swift`.

### Leg 4 — render-path cost gate (gated on G1, G3)

- `Sources/DAWEngine/EnginePerformance.swift` — per-instance cells + a coarse log-bucket
  histogram, same preallocated-atomic discipline, no render-thread logging.
- Surface additively on the existing engine-stats payload; new gate script
  `scripts/gates/m29-oop-render-cost.mjs` asserting §6.1's accept/reject over a scripted
  scenario, with a **campaign-validity check** (the m23-aw precedent: a run that was too
  quiet to be informative must report inconclusive, not green).

### Leg 5 — default flip, per component (gated on G1–G4)

`auto` resolves to out-of-process **only** for components with recorded evidence
(G1 + G2 pass, G3 within budget). Everything else, and every Apple component, resolves
in-process. The evidence table lives with the preference and is refreshed by re-running
Leg 0's probe modes.

**EXIT CRITERIA — all four, and the last one is not optional:**
1. G1 (`isLoadedInProcess == false`) recorded per component being flipped.
2. G2 (kill test) recorded per component being flipped.
3. G4 (`OfflineRenderer` survives a faster-than-realtime pull) green.
4. ⛔ **The silent-head bounce defect (§15) is RE-RUN with the flipped component,
   in-process and out-of-process.** It lives in exactly the path this leg changes, and
   §15.6 argues out-of-process may make it WORSE. **Leg R is a hard prerequisite of
   Leg 5.**
   ⚠️ **REWRITTEN 2026-08-20 — as originally drafted this criterion was unexecutable.**
   It quoted the cold/warm signature as ~~"24 s vs 8.4 s"~~ and asked for "the two bounces
   compared", i.e. an identity comparison. Both premises are dead: the warming signature is
   now the five-run series in §15.1 (**31.974 → 15.001 → 15.001 → 9.869 → 9.869 s**, correct
   onset 9.868 s), and **two renders never null to identity at all** (§15.8, −3.07 dB
   floor), so an identity comparison can only ever report "different". The executable form:
   - **per verb, all three** — `render_mixdown`, `render_stems`, `track_bounce_in_place`;
     the defect is path-specific (§15.7) and a mixdown-only run passes vacuously;
   - **cold** — run 1 in a **fresh process**, with no warming renders ahead of it, onset
     recorded against 9.868 s. This measurement is **single-shot per process**; the second
     attempt is not a cold measurement and will look better for free (§15.5);
   - **warm** — and compared as a **residual against the −3.07 dB floor**, not as identity.
     Out-of-process must not make reproducibility worse either.

   A leg that cannot produce that matrix does not ship.

### Leg 6 — reload + crash-loop policy

Implements §7.4. Wire: `au.reloadInstance {trackId, effectId?}` (additive; +1 command,
+1 MCP tool). The reload path is the existing `prepare` path with the persisted
`config.stateData`; the crash-loop trip is a status transition to the existing
`SilentPlaceholderInstrument`.

### Leg 7 — plugin UI across the boundary (only if Leg 5 ships)

`requestViewController` on an out-of-process instance returns a remote view controller over
ViewBridge. Two recorded facts bound this leg:
- `docs/research/m23av-routeb-feasibility-probe.md` §4 — a **CLI probe cannot test it**
  (ViewBridge asserts `'invoked too early to return meaningful value'` without an
  `NSApplication`). It was a probe artifact, not an AU limitation.
- `docs/research/design-vi-b-au-windows.md:434` — an out-of-process AUv3 remote view
  **rasterizes blank** through `cacheDisplay`, so `debug.captureUI` cannot assert it;
  `plugin.listOpenUIs` stays the functional assertion.

Therefore Leg 7 is **live-gate-only and human-eyes-only**, run from a bundle cut by
`scripts/bundle.sh`. It is also where the reported crash's own code path lives, so it is
the leg most likely to surprise us.

---

## 11. FAILURE MODES

| # | failure | detection | mitigation |
|---|---|---|---|
| F1 | The `.loadOutOfProcess` request silently falls back; we believe we are isolated and are not. | `isLoadedInProcess` (R3). | Report it; never infer locality from a helper-process count (§2.5). |
| F2 | **A dead peer costs a full render timeout every quantum → one dead plugin becomes a graph-wide dropout.** | Leg 0-B measures the 200 quanta after the kill. | Trip to `SilentPlaceholderInstrument` on invalidation (§7.4). **The most important failure mode here.** |
| F3 | `scheduleMIDI` IPC amplification under the breath pad's dense CC (B1). | Leg 0-C measurement 3 (with/without CC). | Batch events per quantum, or exclude dense-CC instruments from `auto`. |
| F4 | `pullInput` nested round trip per effect per quantum (B2). | Leg 0-C measurement 2. | Effects default in-process even if instruments do not. |
| F5 | `HostedAUEffect.reset()`'s sanctioned ObjC message becomes IPC on the render thread at a transport edge (B3). | Code reading + Leg 0 timing at reset edges. | Atomic flag consumed on the main actor for out-of-process instances; decide in Leg 3. |
| F6 | Crash loop: reload → crash → reload. | Second invalidation of the same component within 60 s. | §7.4 trip; no auto-reload. |
| F7 | Plugin state lost on crash. | Inherent. | §7.3 — reload from persisted `stateData`, and say plainly what was lost. |
| F8 | Two hosting modes = two code paths = a bug that reproduces in only one. | — | One shared options function, both call sites (R2); test both modes; Apple pinned (R4). |
| F9 | A preference outliving its plugin (uninstalled, updated, renamed). | — | Key by (type, subType, manufacturer); tolerate misses silently; never fail a prepare because a preference is stale. |
| F10 | Reported `latency` no longer describes the bridged path → PDC drift (B4). | m25-n's suspicion is already open. | Rider; the close-out must not claim PDC is unaffected. |
| F11 | **Offline render regression.** `OfflineRenderer` pulls faster than realtime; an out-of-process AU with a render deadline may not keep up → dropouts or `RenderTimeout` **in bounces**. | **G4**, Leg 0-D. | If G4 fails, the offline path re-instantiates in-process. ⛔ **THE OPEN BOUNCE BUG IS NOW CHARACTERISED AND IT IS NOT "the first clip is dropped" — it is "the head of the bounce is silent, by 0.001–22.1 s depending on how many renders ran before it, and on some verbs the whole stem" (§15.1).** ⛔ **AND IT IS PATH-SPECIFIC (§15.7): G4 run against `render_mixdown` alone passes while `render_stems` and `track_bounce_in_place` stay broken — name the verb.** Out-of-process **makes this harder, not easier** (§15.6): the fix depends on letting the AU BLOCK at render time, and a blocking render across an XPC boundary is what `kAudioUnitErr_RenderTimeout` exists to kill. **Leg R-1 shipped and did NOT cure it; R-2 must land, and be re-verified out-of-process, before any default flip.** |
| F12 | The crash is ours (per-render instantiate/teardown racing the plugin's deferred main-run-loop work), not the plugin's, and out-of-process merely relocates it. ⭐ **UPGRADED 2026-08-20 from "a possibility" to THE LEADING HYPOTHESIS** (§1.2): three crashes, all during heavy offline-render activity, all faulting in a main-run-loop `source0` callback, with per-instance JUCE thread counts appearing in multiples. **UNVERIFIED — no controlled repro, and two prior theories on this defect have already been refuted.** | Leg 0-E reproduction attempt, now with a cheap instrument: count per-instance JUCE threads across an open/close cycle. | If reproduced: drain the main run loop before `AudioComponentInstanceDispose` — the m18-d `dlsBankQueue` hand-off is the precedent for a deferred-release policy — or stop building fresh instances per render at all (**G0**, §15.7), which would address the bounce defect in the same change. Far cheaper than Legs 3–7. **Check this before spending the milestone.** |
| F13 | The undocumented AUv2-out-of-process behaviour changes in a macOS update and silently reverts to in-process. | R3's `isLoadedInProcess` check runs on every prepare, so a regression is visible rather than assumed. | Per-component opt-in means the blast radius is one plugin; the reported locality is on the wire. |
| F14 | **Bounces are not reproducible even when correct** — two fully-warm renders of the same material differ by −3.07 dB peak (§15.8). A change can cure the dropout and worsen this, and a dropout-only pass condition cannot see it. | Warm-vs-warm null, controlled against a self-null. | **Cost every render-path change against BOTH criteria in §15.5.** Cause unchased; unreset plugin state between offline renders would fit. |

---

## 12. FULL XCODE, ENTITLEMENTS, SIGNING — flagged explicitly

- **Legs 0–6: none.** No entitlement, no code signing, no app bundle, no AUv3 packaging.
  `.loadOutOfProcess` requires nothing special of an unsandboxed host; the helper is
  Apple's own. In-process AU registration from bare SPM is already proven
  (`docs/ARCHITECTURE.md:421`), and everything here rides the same path.
- **Leg 7 (plugin UI over the boundary): needs a bundle** (`scripts/bundle.sh`, on the
  user's ask) because ViewBridge requires a real `NSApplication` — that is why the CLI
  probe could not test it. This is a *bundle* requirement, not strictly a *full Xcode*
  requirement. It is nonetheless **live-gate-only and human-eyes-only**; no automated gate
  in this tree can see it.
- **Future packaging note, not a blocker now:** if DAW Pro is ever sandboxed for
  distribution, AU hosting acquires entitlement questions (temporary-exception audio-unit
  hosting) that do not apply today. Record it; do not solve it here.
- ✅ **Xcode 26.6 is installed** (SDK `MacOSX26.5.sdk` present and read for this document).
  Any item still filed "blocked: needs full Xcode" in this area should be re-triaged before
  that blocker is quoted again.

---

## 13. WHAT I COULD NOT DETERMINE WITHOUT MEASUREMENT

Stated as an explicit list, because every one of these is a place a close-out could
overclaim:

1. **Whether `[.loadOutOfProcess]` actually moves an AUv2's *render* out of our process.**
   Apple documents only the opposite direction (§2.4). The prior probe's evidence does not
   establish it (§2.5). **This is G1 and everything expensive depends on it.**
2. **Any per-quantum IPC cost.** No measurement exists in this tree, and the one real-world
   host change I found publishes none (§6).
3. **Whether `scheduleMIDI` and `pullInput` cross the process boundary per call or are
   batched.** Undocumented. B1 and B2 are the two largest RT unknowns.
4. **The render-timeout interval.** `kAudioUnitErr_RenderTimeout` exists; its value appears
   in no header I read.
5. **Whether the DecentSampler crash is triggered by our own AU lifecycle.** Nothing of
   ours is on any *faulting* stack — which does not exonerate an earlier use-after-free.
   ⭐ **This is now the LEADING hypothesis rather than one of two** (§1.2, F12): all three
   crashes occurred during heavy offline-render activity, and §15.7 measured that the
   render paths instantiate and discard plugin instances per render. **Still unproven — no
   controlled repro, and this defect has already refuted two prior theories.**
6. **Whether an out-of-process AU survives faster-than-realtime offline pulls** (G4, F11).
7. **Whether the Surge XT wedge is real at all.** It did not reproduce warm on 2026-08-04
   and has not been retried cold. The standing "prefer GM sound banks" rule rests on it and
   is **not** verified — and must not be deleted on one warm-system negative either.
8. **Whether `sandboxSafe` predicts out-of-process viability.** 2 of 11 declare it, and the
   two that do are the two JUCE builds. Suggestive, unverified.
9. **Whether the plugin UI works across the boundary at all** (Leg 7). Only a human, in a
   bundled app, can answer this.
10. ✅ **ANSWERED 2026-08-20, and the answer is NO.** *"Whether `renderingOffline` alone
    fixes the silent-head defect"* (§15) is settled: R-1 shipped in `412cb33`, the wiring
    was verified by the tester rather than assumed, and **DecentSampler does not honour the
    flag** — Apple's *"an audio unit **may** respond"* took its other branch. The bounces
    still drop. R-2 is therefore required, not contingent. What remains open in its place:
    **(10a)** the retention mechanism that makes renders warm across fresh AU instances
    (§15.1 — measured, unexplained); **(10b)** whether the double instantiation on
    `render_stems`/`track_bounce_in_place` is *causal* for the dropout or merely correlated
    (§15.7 — the correlation is across the only three verbs there are; the experiment is
    cheap and unrun); **(10c)** why two fully-warm renders differ by −3.07 dB (§15.8).
11. **Whether an out-of-process AU is permitted to block at render time at all** (§15.6).
    `renderingOffline` asks the AU to block; the remote-render deadline behind
    `kAudioUnitErr_RenderTimeout` may forbid it. These two mechanisms may be in direct
    conflict and nothing in Apple's documentation reconciles them.
12. **Whether any hosted plugin here honours RPN 0** (§16). There is no readback in MIDI;
    the only instrument is a rendered pitch measurement.

---

## 14. `docs/ARCHITECTURE.md` — "Key future decisions" entry, DRAFTED BUT NOT APPLIED

This decision is **not settled** — it needs the user's word. The entry below is written and
ready; apply it only when they rule, with the ruling folded in.

> - **Out-of-process AU hosting (M29) — OPEN, DESIGNED, GATED ON ONE MEASUREMENT.** A
> third-party AUv2 (DecentSampler 1.23.5) segfaulted DAW Pro twice on 2026-08-20 with an
> identical stack — **on the main thread, in a `CFRunLoopSource0` callback (JUCE's message
> queue), not on the render thread**; the audio IO thread was parked. Autosave + the
> `session.lock` recovery sentinel caught both, and that mitigation stands unchanged. The
> designed answer is a **per-component hosting mode** (`inProcess`/`outOfProcess`/`auto`),
> **one shared options function replacing the duplicated `isV3` branch** at
> `AUHostRegistry.swift:577-588`/`:748-759`, **locality verified with
> `AUAudioUnit.isLoadedInProcess`** rather than assumed, and **Apple-manufactured
> components pinned in-process forever** (their 23 built-in effects are measured good;
> isolation would cost and buy nothing). The alternatives that lose: **AUv3-only** — zero
> coverage, measured twice (73/9/zero on 2026-08-04; 75/11/zero on 2026-08-20; not one
> third-party unit installed is `isV3`); **UI-only isolation** — no Apple API splits render
> and view across processes for one instance, and the measured crash was not in the view.
> ⚠️ **The gate: `docs/research/m23av-routeb-feasibility-probe.md` §2's "macOS bridges a
> classic AUv2 out-of-process" is NOT established by its evidence.** It rests on a
> `SandboxHelper.xpc` count going 8→9, and `AUAudioUnit.h:931-947` says in as many words
> that *"the presence of an extension process is not sufficient indication"*. One
> `isLoadedInProcess` read settles it and nobody has taken it. ⚠️ **This change makes the
> render thread synchronously wait on another process** — the RT invariant is amended, not
> preserved; the amendment and its bounded-wait justification are
> `docs/research/design-m29-oop-au-hosting.md` §5. The failure lane already exists: both
> hosted adapters' step 4 turn any non-`noErr` status into exact silence / dry passthrough
> with an atomic breadcrumb, so `−66749` and `−66745` are handled today with zero
> render-path edits. ⛔ **AND A CHEAPER CANDIDATE MUST BE COSTED FIRST (G0, added
> 2026-08-20): the crash and the silent-bounce-head defect below may be two symptoms of ONE
> decision — fresh AU instances per render.** Three crashes, all during heavy offline-render
> activity, all faulting in a main-run-loop `source0` callback; and the bounce dropout is
> path-specific, hitting exactly the two verbs that instantiate the plugin twice. Reusing an
> AU instance across renders would be days of lifecycle work against weeks of RT-risky IPC
> work, and needs no amendment to the render-thread invariant at all. **Unproven — no
> controlled repro, and two prior theories on this crash have already been refuted** — but
> it is cheap to cost and it is not costed. Design + legs:
> `docs/research/design-m29-oop-au-hosting.md` (§15.7 for G0). Supersedes ROADMAP m23-av-3.

**Second entry, INDEPENDENT of the ruling above — this one is a defect finding, not a
proposal, and it should be added whether or not out-of-process is ever approved.**

⚠⚠ **REWRITTEN 2026-08-20. The first draft of this block embedded TWO claims that were
subsequently FALSIFIED BY MEASUREMENT** — *"the same bounce with samples warm was dead for
8.4 s … repeats at equal warmth were byte-identical"* and *"a byte-identity convergence
criterion … would declare convergence having warmed nothing"*. **The wording is replaced
rather than annotated, deliberately.** This block exists to be pasted into
`docs/ARCHITECTURE.md` verbatim by whoever the user's ruling reaches; a struck-through
premise inside a paste-me block gets pasted anyway. The falsified wording and what killed
it are preserved where the reasoning lives — §15.1 and §15.5(c).

> - **Offline renders never told hosted AUs they were offline — and telling them turned out
> not to be enough (M29 Leg R, FOUND 2026-08-20).** A 296 s bounce of a sax on a 46-zone
> hosted SFZ came back **silent until 25.25 s**. Cause: `prepareAudioUnits` awaits
> `allocateRenderResources()`, whose contract (`AUAudioUnit.h:426-434`) says **nothing about
> content** — a sampler that loads zones lazily on background threads is not finished when
> it returns, and `OfflineRenderer` then pulls **faster than realtime**, so a loader needing
> seconds of WALL time eats tens of seconds of TIMELINE. A realtime sampler whose data is
> not ready is *right* to emit silence. ⭐ Apple has a property for exactly this and this host
> had never set it: **`AUAudioUnit.renderingOffline`** (`:1024-1035`) — *"allowing itself to
> block at render time if data being generated on secondary work threads is not ready in
> time. (Normally, in a realtime thread, this data would have to be dropped.)"* — set BEFORE
> `allocateRenderResources`, on the OFFLINE registry only (setting it live would invite a
> plugin to block the render thread). ✅⛔ **Leg R-1 SHIPPED it in `412cb33`
> (`AUHostRegistry.rendersOffline`, an immutable `let`, applied before allocate in both
> prepare bodies) and it MEASURED NOT TO CURE THE DEFECT: DecentSampler does not honour the
> flag**, which Apple's *"may"* expressly permits. ⚠️ **The AU API defines no general "my
> samples are loaded" signal — and no reliable way to reset a third-party AU between renders
> either.** `renderResourcesAllocated` is true the instant allocate returns; `reset()` is a
> DSP-state call with no contract about loaded content. ⛔ **Three things measured AFTER R-1
> shipped, each of which changes what comes next: (1) IT WARMS.** The same 46-zone sax
> converged monotonically across five renders in one session (22.1 s of lost audio → 0.001 s;
> correct onset 9.868 s) **even though `OfflineRenderer` builds fresh AU instances per
> render** — so something survives an AU instance's lifetime and **the mechanism is not
> identified** (a process-global sample cache keyed by path would fit; unverified).
> **(2) IT IS PATH-SPECIFIC.** `render_stems` and `track_bounce_in_place` drop;
> `render_mixdown` was correct from the first cold call of the session — and the two failing
> verbs are exactly the two that build a **throwaway `OfflineRenderer`** via
> `offlineCompensationTargets` (`AudioEngine.swift:2322`) before the real one (`:2277`),
> instantiating every hosted plugin twice and discarding the warmed first instance.
> **(3) BOUNCES ARE NOT REPRODUCIBLE.** Two fully-warm renders with identical correct onsets
> differ by **−3.07 dB** peak (controlled: a self-null gives −inf). ⭐⭐ **STRATEGIC
> CONSEQUENCE: this defect and the plugin segfault above may be two symptoms of ONE design
> decision — fresh AU instances per render — and reusing an instance across renders should
> be COSTED BEFORE the out-of-process milestone is committed to.** ⚠️ **Cost any fix against
> BOTH "run 1 lands correct COLD, with no warming renders ahead of it" AND "warm-vs-warm
> nulls better than −3.07 dB"** — a change can cure the dropout while worsening
> reproducibility, and a dropout-only criterion cannot see that. A **discardable full
> pre-roll** (render the timeline once, throw the audio away, render for real) remains the
> standing proposal, chosen over a head-window convergence scheme because it has **no
> termination question**. ⛔ A byte-identity convergence criterion was drafted and REJECTED —
> **and note the reason, which an earlier draft of this entry stated backwards: successive
> renders are NEVER byte-identical, so such a criterion would NEVER TERMINATE**, not
> terminate early. And a *silent* pre-roll cannot work at all, since lazy loads are triggered
> by note-ons: **the output is discarded, not the input.** ⚠️⚠️ **This pulls AGAINST
> out-of-process hosting**, whose render deadline (`kAudioUnitErr_RenderTimeout`) is
> precisely what forbids a blocking render; if the two cannot be reconciled the answer is
> **out-of-process live, in-process offline** — the registries are already separate.
> Detail: `docs/research/design-m29-oop-au-hosting.md` §15.

**Third entry, also independent:**

> - **Hosted AUs were stuck at ±2 semitones because this host never sent RPN 0 (M29 Leg B,
> FOUND 2026-08-20).** `HostedAUInstrument.render()` emits `0xE0 LSB MSB` and nothing else;
> Registered Parameter Number 0 (pitch-bend sensitivity) — the only standard way a MIDI host
> negotiates bend range — is transmitted by no code path, so every hosted plugin ran at its
> own default. Not a plugin limitation, a hosting gap. ⚠️ **The real harm is a silent SCALE
> error, not a range cap:** the M28 breath contour computes deflection against an assumed
> range (`BreathContour.bendRangeSemitones`, default 2), so a mismatch makes every
> expressive bend wrong by the ratio and reads as "the plugin's vibrato is too shallow".
> Fix: emit `CC101/CC100 = 0`, `CC6`/`CC38`, then the **RPN-null tail** (`CC101/CC100 = 127`)
> through the existing `scheduleMIDI` block — and **re-send after every `reset()`**, which
> sends CC 121 (reset all controllers) and clears registered-parameter state, so a
> set-once range is silently lost at the first transport stop. **MIDI offers no readback**:
> the wire reports the REQUESTED range, never a confirmed one. Detail:
> `docs/research/design-m29-oop-au-hosting.md` §16.

---

## 15. THE SILENT HEAD OF A BOUNCE — lazy sample loading and render-start readiness

**Folded in 2026-08-20 from new measured tester data that arrived after this document was
first drafted. It supersedes the earlier "the first clip is dropped" characterisation
everywhere, including §11 F11.**

### 15.1 The measurement

**Round one — 2026-08-20, on the pre-Leg-R-1 build.** Two of these six rows did not
survive round two and are struck in place rather than deleted:

| observation | measured |
|---|---|
| 296 s `track_bounce_in_place`, sax on a hosted AU (46-zone SFZ) | silent until **25.25 s (beat 32)** — intro pickup and four bars gone |
| ⛔ ~~the identical bounce repeated, **samples already cached**~~ | ⛔ ~~truncated at **exactly 25.25 s again**~~ — **FALSIFIED.** It warms. Sole support for the cache-insensitivity claim struck below. |
| a smaller test track, cold | **24 s** dead |
| the same track, warm | **8.4 s** dead |
| ⛔ ~~renders 2 and 3 at equal warmth~~ | ⛔ ~~**byte-identical**~~ — **FALSIFIED by a controlled null.** Sole support for §15.5(c)'s rejection argument, which is rewritten there. |
| scaling | the dead span grows with **the number of distinct sample zones the part touches** |

**Round two — 2026-08-20, measured by an external tester against the SHIPPED build
(commit `412cb33`, the running `dist/DAWPro.app`), with Leg R-1 already in it and verified
wired.** Their method anchors every detector against both a known-clean and a
known-defective control and reports numbers against them; where a control was not run they
label the finding untested.

Repeated renders of the same 46-zone sax, **within one session**. The correct first-note
onset is **9.868 s**:

| render | first non-silent sample | audio lost |
|---|---|---|
| a 35 s stem | **never** — silent throughout | ≥ 25 s |
| run 1 | 31.974 s | 22.1 s |
| run 2 | 15.001 s | 5.1 s |
| run 3 | 15.001 s | 5.1 s |
| run 4 | 9.869 s | 0.001 s |
| run 5 | 9.869 s | 0.001 s |

**It warms, monotonically, and it converges on correct.** And two *fully warm* renders —
runs 4 and 5, both landing on the correct onset — **do not null against each other**: the
residual peaks at **−3.07 dB**. That null is controlled: a file nulled against itself gives
**−inf**. The second fact is a distinct defect with its own identity and is recorded as one
in **§15.8**.

The tester's own reading — *"the render appears to re-prepare the plugin each time"* — is
**correct, and it is in our code**: `OfflineRenderer` keeps **its own registry** and
instantiates **fresh AU instances per render**
(`Sources/DAWEngine/OfflineRenderer.swift:119-135`, whose doc comment says so in as many
words: *"the bank loads AGAIN into this renderer's own registry: fresh AU instances per
render"*). ⛔ **The inference originally drawn from that — *"every bounce therefore re-loads
every sample, every time"* — DOES NOT FOLLOW and is struck.** Round two shows the loading
cost falling to nothing across five renders in one process. The code fact stands; the
conclusion about what it costs does not. See the falsification below.

⚠️ **A retraction is recorded here on purpose:** the coordinator earlier told the user this
defect was timing-independent and withdrew a prepare-timeout-shaped hypothesis. **That
retraction was wrong** and the data above is why: cold 24 s ≠ warm 8.4 s is a *timing*
signature. Byte-identical repeats at *equal warmth* are what made it look deterministic —
determinism at fixed cache state is not timing-independence. This is the same shape as
this project's standing law that a mechanism is not a cause; recorded so nobody
re-derives the retraction from the byte-identical half of the evidence alone.

⚠️ **AND THAT HALF OF THE EVIDENCE IS NOW GONE TOO.** Round two shows the repeats were
never byte-identical (−3.07 dB residual, controlled). So the retraction was not merely
wrong about *timing-independence* — the determinism it was reasoning from **did not
exist**. ⚠️ **Round one's comparison method is not recorded anywhere in this document**, so
how it reached "byte-identical" cannot be reconstructed — an onset match read as a file
match is one possibility among several and is INFERRED, not established. A future reader
should take the whole retraction as withdrawn, not just its conclusion.

⛔⛔ **THE RECONCILIATION THIS SUBSECTION WAS BUILT AROUND HAS BEEN FALSIFIED. THE FALSIFIED
REASONING IS PRINTED HERE RATHER THAN DELETED, BECAUSE A SILENTLY-PATCHED PREMISE GETS
RE-DERIVED.**

**What this subsection used to say.** Round one's two cases appeared to disagree about
cache sensitivity — small track **24 s cold → 8.4 s warm** (cache-sensitive); sax, 46 zones,
**25.25 s cold → 25.25 s warm, exactly** (cache-INSENSITIVE) — and the reconciliation
offered was *one mechanism with two bottlenecks*, resting on this sentence:

> ⛔ *"Where decode/parse dominates — 46 zones — warm and cold are the same number. Where
> disk I/O dominates — the smaller track — warming it cuts the time by two thirds."*

⛔ **FALSIFIED by round two.** The same 46-zone sax warmed across five renders in one
session, monotonically, from 22.1 s of lost audio to 0.001 s. Cache-insensitivity was never
a property of the sax part; it was a property of one pair of observations.

⭐ **AND THE ARGUMENT UNDERNEATH IT WAS NEVER A MEASUREMENT — IT WAS AN ARGUMENT FROM CODE
STRUCTURE**, which is why no appeal to build differences rescues it. The claim was that
`OfflineRenderer` builds **fresh AU instances per render**, so every bounce re-parses and
re-decodes the program from scratch *whatever the OS file cache holds*, so the sax case
**cannot** warm. Round two says it does. Leg R-1 does not create cross-render retention,
and the falsified claim was not "it happened not to warm" but "it is structurally unable
to". A structural impossibility that is observed to happen is refuted outright.

⚠️⚠️ **THE RETENTION MECHANISM IS NOT IDENTIFIED. THIS DOCUMENT DOES NOT HAVE ONE AND WILL
NOT INVENT ONE.** What is actually established, by provenance:

- **MEASURED:** successive renders in one process get monotonically better and converge on
  the correct onset.
- **MEASURED, in our code:** `OfflineRenderer` really does keep **its own registry** and
  instantiate **fresh AU instances per render**
  (`Sources/DAWEngine/OfflineRenderer.swift:119-135`, whose doc comment says so in as many
  words: *"the bank loads AGAIN into this renderer's own registry: fresh AU instances per
  render"*). Both facts hold at once, and together they say plainly that **something
  survives an AU instance's lifetime.** What, is not known.
- **UNVERIFIED CANDIDATE, offered only so the next investigator has somewhere to aim a
  probe:** the plugin may hold **process-global cached state keyed by sample path**,
  independent of instance lifetime. A static or singleton sample cache is an ordinary thing
  for a sampler to own, and it would survive instance disposal exactly as observed. **There
  is no evidence for this beyond its fitting the shape.** It was not tested. The OS file
  cache is not excluded either — the structural argument that ruled it out is the one just
  falsified, so it is back on the table with nothing said for or against it. Do not promote
  this candidate to a mechanism by repeating it.
- **UNRESOLVED:** round one's *"25.25 s cold, 25.25 s warm, exactly"* is still unexplained.
  INFERRED, and it is the most that should be claimed: round two's plateau structure
  (15.001 s twice, then 9.869 s twice) shows that **two consecutive renders landing on an
  identical onset is a normal intermediate state of warming, not evidence of
  cache-insensitivity.** Round one may simply have sampled a plateau.

**What survives all of it — and the section's own conclusion does survive.** The defect is
"the loader is still working while the render clock runs". Every number in both rounds is
consistent with that, and it is what `renderingOffline` (§15.3) and a pre-roll (§15.5) each
address. What does *not* survive is any claim about *which* bottleneck dominates *where*,
and any design that depends on knowing.

⚠️ **THE FALSIFIABLE READING IS STILL UNTAKEN, AND IT IS NOW OWED BY LEG R-2.** The original
text asked Leg R-1 to instrument the wall time between `allocateRenderResources` returning
and the first non-silent output sample, cold and warm, for both parts. **R-1 shipped
without taking it.** That reading is now worth more, not less: it is the cheapest
instrument that could identify the retention mechanism above, and §15.5's pre-roll design
depends on the answer.

### 15.2 The mechanism, and why it is a hosting-design question

`prepareAudioUnits` awaits `allocateRenderResources()`. Apple's contract for that call
(`AUAudioUnit.h:426-434`) is *"Allocate resources required to render. Hosts must call this
before beginning to render"* — **it says nothing about content.** A sampler that loads
zones lazily on first note-on, on background work threads, is not finished when it
returns, and it has no obligation to be.

Then the offline graph pulls **faster than realtime**. The plugin's loader runs in **wall**
time while the render consumes **timeline** time far faster, so a loader that needs a few
seconds of wall time eats tens of seconds of timeline — and in a realtime context the
correct behaviour for a sampler whose data is not ready is **to output silence rather than
miss the deadline**. It is doing exactly what a well-written realtime sampler should do.
**We never told it this was not a realtime context.**

### 15.3 ⭐ THE FINDING — Apple has a property for precisely this, and this host had never set it (⚠️ IT DOES NOW)

`AUAudioUnit.h:1024-1035`, verbatim:

> **`@property renderingOffline`** — Communicates to an audio unit that it is rendering
> offline.
> A host should set this property when using an audio unit in a context where there are no
> realtime deadlines, **before asking the unit to allocate render resources**. An audio
> unit may respond by using a more expensive signal processing algorithm, **or allowing
> itself to block at render time if data being generated on secondary work threads is not
> ready in time. (Normally, in a realtime thread, this data would have to be dropped.)**
> Bridged to the v2 property `kAudioUnitProperty_OfflineRender`.

That parenthesis is a description of the reported defect, written by Apple, years in
advance.

⛔⛔ **THE MEASURED ZERO BELOW IS A PRE-R-1 MEASUREMENT AND IS NO LONGER TRUE OF THIS TREE.
IT IS THE MOST QUOTABLE PARAGRAPH IN §15 AND WOULD BE QUOTED WRONG.** R-1 shipped in
`412cb33`; the property **is** set today. Re-grepped 2026-08-20, post-R-1: the spellings now
return matches in `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift`,
`Sources/DAWEngine/OfflineRenderer.swift`, `Sources/DAWEngine/AudioUnits/HostedAUInstrument.swift`,
`Sources/DAWEngine/Effects/HostedAUEffect.swift` and
`Tests/DAWEngineTests/OfflineRenderReadinessTests.swift`. **What is preserved below is the
FINDING as it stood when this defect was diagnosed** — that the host had never set the
property — because that is the fact the design turns on. ⚠️ **Setting it did not fix the
defect** (§15.5 status block). Do not read this paragraph as current state.

> **Measured, positive-controlled 2026-08-20, BEFORE Leg R-1: this property is never set
> anywhere in the tree.** Grepped across `Sources/` and `Tests/`, each spelling read by its
> **own** exit status: `renderingOffline` → exit 1 / 0 lines; `isRenderingOffline` → exit
> 1 / 0 lines; `kAudioUnitProperty_OfflineRender` → exit 1 / 0 lines. Positive control
> `maximumFramesToRender` → exit 0 / 11 lines.
> ⚠️ **Stated honestly because it would otherwise be a false zero:** a bare `OfflineRender`
> substring returns **244 lines** — every one of them our own `OfflineRenderer` *class*
> name, bar two test-function names (`everyOfflineRenderCarriesLiveState`,
> `headlessOfflineRenderCounts`), verified by filtering `OfflineRenderer` out and reading
> what survived. None is the AU property. Grep the property spellings, not the word.

Note the ordering requirement: **before** `allocateRenderResources`. That lands it inside
the registry's existing restore-order contract, which before R-1 read
maxFrames → format → state → allocate.

✅ **AS SHIPPED, AND IT IS NOT THE ORDER THIS SECTION PROPOSED.** R-1 sets the flag
**before the state restore**, not after it —
**maxFrames → format → `renderingOffline` → state → allocate** — at
`Sources/DAWEngine/AudioUnits/AUHostRegistry.swift:699` (effects) and **`:879`**
(instruments), through the shared
`applyOfflineRenderFlag(to:rendersOffline:)` (**`:330-341`**). The deviation is deliberate
and argued in the code: `fullStateForDocument =` is itself what kicks off a plugin's
secondary-thread sample loading, so telling the unit it is offline *first* can only widen
the window in which the flag matters. Both orders satisfy Apple's only stated requirement.
**Line references measured 2026-08-20; the pre-R-1 refs this section used to carry
(`:590-621` effects, `:761-800` instruments) have drifted with R-1's own edits and must not
be re-quoted.**

### 15.4 What the AU API does and does not give us as a start gate

Enumerated from `AUAudioUnit.h` on this machine, not from memory:

| candidate | what it actually is | usable as a readiness gate? |
|---|---|---|
| `renderResourcesAllocated` (`:446-449`) | *"returns YES if the unit has render resources allocated"* — a mirror of the call we already awaited | **No.** It is true the instant `allocateRenderResources` returns, with zero samples loaded. |
| `allocateRenderResourcesAndReturnError` (`:426-434`) | the call itself | **No** — already awaited; that is the whole problem. |
| **`renderingOffline`** (`:1024-1035`) | tells the AU there is no deadline, so it **may block instead of dropping** | **The one real lever — and MEASURED INSUFFICIENT.** Not a *signal* but a *request*, and Apple's word is "may". R-1 shipped it; **DecentSampler declines** (§15.5), so the lever exists and this plugin is not attached to it. |
| `allParameterValues` (`:588`) | a KVO pseudo-property for parameter-tree change coalescing | **No.** Parameter readiness, not content readiness. |
| `isLoadedInProcess` (`:931-947`) | where the unit is hosted | **No** — locality, unrelated. |
| `parameterTree`, `fullState` | present at allocate | **No.** A plugin's parameters are ready long before its samples. |
| `kAudioComponentInstanceInvalidationNotification` | the peer died | **No** — a failure signal, not a readiness one. |
| `AUAudioUnit` KVO/notification for load state | **does not exist** | — |

**Conclusion: there is no general "my samples are loaded" signal in the AU API, and this
is not an oversight in our host — Apple does not define one.** Any host that renders
faster than realtime has to solve it structurally. `renderingOffline` is the mechanism
Apple provides *instead* of a signal: it does not tell you when the AU is ready, it is
*supposed* to make the AU's not-being-ready stop mattering.

⛔ **RIDER, MEASURED 2026-08-20 — that last clause was an over-claim and R-1 falsified it.**
`renderingOffline` makes not-being-ready stop mattering **only for a plugin that honours
it**, and the plugin in the defect report does not. There is therefore **no API-level answer
at all** here: Apple defines no load-state signal (this subsection), no reliable reset
(§15.5), and the one lever is advisory. The remaining answers are all structural — a
pre-roll (§15.5) or not building fresh instances per render (§15.7). ⚠️ **And the same wall
runs in both directions:** a host can neither ask "are you loaded?" nor say "become
unloaded", which is why §15.8's warm-render non-determinism is hard to attack directly.

### 15.5 THE DECISION — two legs, cheap one first

> ✅ **STATUS UPDATE 2026-08-20 — LEG R-1 IS SHIPPED AND IT DID NOT CURE THE DEFECT.**
> It landed in commit `412cb33` as `AUHostRegistry.rendersOffline` (a `public let`, not the
> proposed `var` — immutability makes "the live registry never sets it" unforgettable
> rather than merely conventional), applied through
> `AUHostRegistry.applyOfflineRenderFlag(to:rendersOffline:)` before `allocateRenderResources`
> in both prepare bodies, with `Tests/DAWEngineTests/OfflineRenderReadinessTests.swift`
> pinning it. **The tester verified the wiring themselves rather than assuming it**, and it
> is correct. DecentSampler simply does not honour the flag — which is exactly what Apple's
> *"may"* permits, and exactly what our own comment at
> `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift:299-308` predicted, naming Leg R-2's
> discardable pre-roll as the answer for the residue.
> ⛔ **CONSEQUENCE: LEG R-2 IS NO LONGER OPTIONAL. It is the only remaining proposal
> against a live, measured defect that destroys the head of real bounces.** Everything
> below that reads as "R-1 first, R-2 if needed" should be read as "R-2, now".

**Leg R-1 (~4 h) — set `renderingOffline` on the offline registry's instances, before
allocate. ✅ SHIPPED; see the status block above for what it bought and what it did not.**

- `AUHostRegistry` gains one stored flag (proposed `var rendersOffline = false`), set by
  `OfflineRenderer` on **its own** registry instance. The live registry never sets it, and
  a test must pin that: **`renderingOffline` on a live instance would invite a plugin to
  block the render thread, which is the exact opposite of everything §5 argues for.** This
  is the sharpest knife in the document; it is safe only because the offline renderer
  already owns a separate registry.
- Set it in **both** prepare bodies, in the restore order above, from the one place that
  already governs that order.
- Wire/MCP: none. This is a correctness fix to an existing verb, not a new capability.
- **Tests** (`Tests/DAWEngineTests/OfflineRenderReadinessTests.swift`, new):
  1. Site test — the offline registry sets the property and the live registry does not.
  2. Order test — it is set **before** `allocateRenderResources` (assert via an
     instrumented stub AU that records the call order; a property set *after* allocate is
     a silent no-op and would pass any naive "is it set" check).
  3. ⭐ **The load-bearing gate — an INSTRUMENTED STUB AU, not a real cold plugin.**
     A stub `AUAudioUnit` that withholds output (emits zeros) for its first K render calls
     **unless `renderingOffline` was set before allocate**, and emits signal otherwise.
     Assert the bounce head is non-silent with the flag and silent without it.
     ⚠️ **The obvious gate — "bounce a real lazy-loading plugin, cold, assert non-silence" —
     was drafted here first and is REJECTED.** ⛔ **ITS ORIGINAL SECOND REASON WAS
     FALSIFIED and is struck:** ~~"per §15.1 the sax case may not be cache-sensitive at
     all"~~ — round two shows it *is*, monotonically. The rejection stands anyway, and the
     replacement reason is **stronger** than the one it replaces: a real-plugin gate is not
     merely irreproducible, it is **order-dependent and monotonically self-defeating**. The
     first run in a session sees 22.1 s of lost audio; the fourth sees 0.001 s. The same
     assertion therefore passes or fails on **how many renders ran before it**, which no
     test in this tree controls, and it drifts green as a suite grows. That gate can pass
     vacuously, which is the exact failure this project has a named law about. The stub is
     deterministic, headless, and tests **the host's behaviour** rather than a plugin's
     accumulated cache state.
  4. Negative control — the same gate must FAIL with the flag forced off, or it proves
     nothing.
  5. A real-plugin cold bounce stays valuable as an **observation, explicitly NON-GATING**,
     recorded with its numbers in the close-out. It is evidence about the world; the stub is
     the assertion about us.

**Leg R-2 (2–3 d) — the discardable pre-roll, for plugins that ignore the property.
⛔ NO LONGER CONDITIONAL: R-1 shipped, DecentSampler ignores the flag, and this is now the
only standing proposal against a live defect.**

Apple's word is *"may"*, and we now know of one plugin that took the *"may not"* branch. A
plugin that ignores `renderingOffline` still drops, so the general answer is a pre-roll —
and the tester proposed exactly this. One correction to their wording, and it matters:
**a *silent* pre-roll does not work.** Lazy loads are triggered by note-ons, so the pre-roll
must play the real notes; what is discarded is the **output**, not the input.

⛔⛔ **HOW R-2 MUST BE COSTED — a methodological correction from the tester, recorded here
because it changes the pass condition and would otherwise be discovered after the work is
built.**

**Do NOT cost a fix as "does the dropout go away."** Fresh instantiation is not buying
determinism today: two fully-warm renders already fail to null at **−3.07 dB** (§15.8). A
change could remove the dropout and **worsen reproducibility at the same time**, and that
is a bad trade nobody would notice under a dropout-only criterion. Cost R-2 — and any
AU-instance-reuse work, §15.7 — against **both**:

- **(a) COLD CORRECTNESS.** Run 1 lands at **9.869 s**, with **no warming renders ahead of
  it**.
- **(b) WARM DETERMINISM.** Warm-vs-warm nulls **better than −3.07 dB**.

⚠️ **CRITERION (a) IS SINGLE-SHOT PER SESSION STATE, AND THIS IS THE TRAP.** The warming
series means any earlier render in the same process invalidates it, and the plateau
structure (31.974 → 15.001 → 15.001 → 9.869 → 9.869) means a **second** attempt passes for
free at a partial value and a **fourth** passes outright for reasons that have nothing to
do with the fix. An implementing agent who runs this gate in a loop will watch it go green
and ship. **Run (a) once, first, in a fresh process, and record the process's render count
alongside the number.** This is the same vacuous-gate shape the stub-AU decision above
already turns on.

⚠️ **AND THERE IS NO RELIABLE WAY TO RESET A THIRD-PARTY AU BETWEEN RENDERS.** Shapes (a)
and (c) below both say *"then reset"*. `AUAudioUnit.reset()` is a DSP-state reset with no
contract about loaded content or internal caches, and there is no API that says "return to
the state you were in at allocate". This is **the same wall §15.4 hit** looking for a
load-state signal, in the opposite direction: Apple defines neither "am I loaded" nor
"become unloaded". Whatever R-2 ships must state what its reset step actually guarantees,
which today is *nothing verifiable*. §15.8's −3.07 dB residual is consistent with exactly
this — unreset plugin state carried between offline renders — and is the reason criterion
(b) exists.

Three shapes, and the recommendation:

- **(a) ⭐ FULL DISCARDED PASS, then reset, then render for real — RECOMMENDED.** Warms
  exactly the zones the part touches, in exactly the order the part touches them. Cost:
  ~2× render wall time. **Its whole virtue is that it has no termination question** — it
  runs once, over a known finite timeline, and stops. Dumb, robust, and correct on both
  datapoints in §15.1 regardless of which bottleneck dominates.
- **(b) Zone-touch warm-up** — schedule every distinct (pitch, velocity) the part uses with
  immediate note-offs into a throwaway buffer. Much cheaper. **Risk:** a plugin may key its
  loading on round-robin index or velocity layer, so pitch coverage is not zone coverage.
  An optimisation of (a), never a replacement.
- **(c) Head-window convergence pre-roll — an OPTIMISATION of (a), not a replacement, and
  its stop condition is the whole difficulty.** Render only the head window (proposal: the
  first 30 s of timeline, discarded), repeat, stop when it has converged, then reset and
  render for real. Cost is bounded by the head window and a hard pass cap rather than by
  the full 296 s.
  ⛔ **A BYTE-IDENTITY STOP CONDITION IS WRONG AND AN EARLIER DRAFT OF THIS SECTION
  PROPOSED ONE. The retraction is recorded rather than edited away.** The first half of the
  original argument stands: those were **separate render sessions with separate AU
  instances**, and the pre-roll converges across **passes within one session on one live
  instance** — cross-session determinism is not evidence about the within-session property.

  ⛔⛔ **THE SECOND HALF WAS FALSIFIED, AND ITS FAILURE MODE IS THE EXACT OPPOSITE OF WHAT
  THIS DOCUMENT CLAIMED. THE INVERSION IS THE POINT; READ IT BEFORE DESIGNING THE
  REPLACEMENT.** The struck argument was:

  > ⛔ *"And it fails on the very datapoint that motivated this section: the sax bounce is
  > byte-identical cold and warm at 25.25 s, so a byte-identity test would declare
  > convergence after pass 2 having warmed nothing — the criterion is satisfied by a defect
  > that is merely deterministic."*

  **That datapoint is false. The sax bounce is NEVER byte-identical** — two *fully warm*
  renders, runs 4 and 5, both landing on the correct 9.869 s onset, leave a **−3.07 dB**
  peak residual against each other (controlled: self-null gives −inf; §15.1, §15.8).

  ⭐ **So the criterion does not terminate EARLY. It NEVER TERMINATES.** Successive renders
  never become byte-identical, so a byte-identity stop condition runs to its pass cap on
  every bounce, every time — a 2× cost becomes an N× cost, and "convergence not reached"
  becomes the permanent answer. **A reader who remembers only "we rejected byte-identity
  because it stops too early" will build the replacement backwards**, guarding against
  premature termination when the real hazard is non-termination.

  **The conclusion is unchanged and is if anything firmer: do not use byte identity.** A
  usable stop condition must be measured on a quantity that **moves when loading completes
  and then stops moving even though the samples do not**: head-window **energy** (or the
  first-non-silent-sample index) rising and then stabilising across passes, **to a
  tolerance**, never to equality — with **non-silence at the head as a precondition**, so
  "stable at zero" can never read as converged, and with a **hard pass cap that reports
  `converged: false`** rather than looping. That is the shape to build if (c) is built at
  all. Note that the −3.07 dB residual sets a floor on any tolerance chosen: a threshold
  tighter than the plugin's own run-to-run noise is another way to never terminate.

Whichever ships, it must be **observable**: the bounce result should carry how many
pre-roll passes ran and whether convergence was reached. A silent 2× render-time increase
that nobody can see is a support ticket in waiting.

### 15.6 ⚠️ HOW OUT-OF-PROCESS CHANGES THIS ANSWER — it makes it HARDER

This is the coordinator's direct question and the answer is not comfortable.

`renderingOffline` works by inviting the AU to **block at render time**. Out-of-process
hosting puts an XPC boundary in the render path with a system-enforced deadline behind it —
that is what `kAudioUnitErr_RenderTimeout` (−66745) *is* (§2.3). **The fix for the
silent-head defect and the mechanism of out-of-process hosting pull in opposite
directions**, and nothing in Apple's documentation reconciles them:

- If the remote render deadline is not relaxed for an offline-flagged unit, a blocking
  load becomes a `RenderTimeout` — which our step-4 lane turns into **exact silence**. The
  same dead head, arriving through a different door, and now with a plausible-looking error
  code that would send the next investigator somewhere else entirely.
- If it *is* relaxed, out-of-process is fine here, and it may even be better (the blocking
  happens in the helper's thread, not ours).

**Nobody in this tree knows which.** Consequences, and they are binding:

1. **Leg R must land before Leg 5**, so the in-process baseline is fixed and correct
   first. Fixing a bounce defect and flipping a hosting default in the same cycle would
   make an ambiguous result uninterpretable. ⚠️ **UPDATED 2026-08-20: R-1 has landed and
   the baseline is still NOT correct** — it did not cure the defect (§15.5). The
   prerequisite therefore transfers to **R-2** (or to whatever G0 costing replaces it,
   §15.7). "R-1 shipped" is not "the baseline is fixed", and a close-out must not read it
   that way.
2. **G4 (§3.1) is widened**: it must be measured **with `renderingOffline` set and a
   lazy-loading plugin**, cold and warm, not merely "does a faster-than-realtime pull
   survive".
3. If out-of-process cannot support a blocking offline render, the resolution is
   **hosting locality that differs between the live and offline paths** — out-of-process
   live (crash isolation, where it is worth the cost) and in-process offline (blocking
   loads, where isolation buys much less because a bounce is repeatable and a lost bounce
   is not a lost take). The registries are **already separate**, so this costs almost
   nothing structurally. Record it as the fallback rather than discovering it late.

### 15.7 ⭐⭐ THE DROPOUT IS PATH-SPECIFIC, AND THE PATHS DIFFER BY ONE INSTANTIATION

**Added 2026-08-20. This is the finding that puts a cheaper answer in front of the whole
milestone, and §3.1's G0 exists because of it.**

**MEASURED (tester, shipped build `412cb33`):** the defect does not affect every render
verb. `render_stems` and `track_bounce_in_place` **both drop audio**. `render_mixdown` was
**correct from the very first cold call of the session** — no warming, no pre-roll, no
flag beyond what R-1 already sets.

**MEASURED (in our code, line references re-verified 2026-08-20 rather than quoted from
memory):** the working path instantiates the hosted plugin **once**; the two failing paths
instantiate it **twice and throw the first one away**.

| verb | route | hosted-AU instantiations |
|---|---|---|
| `render_mixdown` | `ProjectStore.renderMixdown` (`Sources/DAWCore/ProjectStore.swift:6373`) → `AudioEngine.renderMixdown` (`Sources/DAWEngine/AudioEngine.swift:2229`) → `renderOffline(forcedCompensationTargets: nil)` (`:2253`) → **one** `OfflineRenderer()` (`:2277`) | **1** |
| `render_stems` | `Sources/DAWCore/ProjectStore+Render.swift:281` calls `engine.offlineCompensationTargets` **first**, then one `renderOffline` per stem descriptor | **1 throwaway + N** |
| `track_bounce_in_place` | `Sources/DAWCore/ProjectStore+Bounce.swift:107` calls `engine.offlineCompensationTargets` **first**, then `renderOffline` | **1 throwaway + 1** |

The throwaway is `AudioEngine.offlineCompensationTargets`
(`Sources/DAWEngine/AudioEngine.swift:2317-2325`): it builds an `OfflineRenderer()` at
**`:2322`**, calls `prepareAudioUnits` on it — a full instantiate-and-allocate of every
hosted plugin in the session — reads a compensation plan out of it, and **discards it**,
before the real renderer is constructed at `:2277`.

⚠️ **The negative half of that claim is positive-controlled.** Grepping
`offlineCompensationTargets` across `Sources/` and `Tests/` returns the two production call
sites above, two `EngineProtocol` declarations, and five test sites — and **not**
`ProjectStore.swift`. The pattern demonstrably finds things, so its silence on the mixdown
path is an absence rather than a broken probe.

**⚠️ PROVENANCE — the causal step is INFERRED, and one thing about it does not fit.** That
the two double-instantiating verbs are exactly the two that drop is a strong correlation
across the only three verbs there are. But a throwaway that *prepares* a plugin should
naively **help** a later render, not hurt it — and §15.1 has just established that
something warms across instances. The candidate resolution is that
`prepareAudioUnits` allocates but **never renders**, so it triggers no note-on-driven lazy
loads at all; whatever it costs, it costs in instance churn rather than buying warmth. That
is a guess. **Nobody has run the discriminating experiment**, which is cheap: make the two
failing verbs reuse one renderer (or take the plan off the real one) and re-measure.
⛔ Re-measure against **both** §15.5 criteria, not just the dropout — that is the whole
point of the costing rule recorded there.

**⭐⭐ THE STRATEGIC CONSEQUENCE, STATED PLAINLY.** The silent bounce head (§15) and the
app-killing segfault (§1) may be **two symptoms of one design decision: fresh AU instances
per render.** The dropout tracks instantiation count across verbs. The crash's leading
hypothesis (§1.2) is our per-render instantiate/teardown racing the plugin's own deferred
main-run-loop work, and the crash reports carry per-instance JUCE thread counts in
multiples. **Reusing an AU instance across renders may address both, and it is far cheaper
than the out-of-process milestone this document proposes** — days of lifecycle work against
weeks of RT-risky IPC work, with no amendment to the render-thread invariant (§5) required.

⛔ **That option deserves costing BEFORE this milestone is committed to.** It is **G0** in
§3.1, and it is the one gate that fails by nobody running it. It is not a rival design in
§4 — §4 lists alternatives that lose, and this one does not lose; it may make Legs 3–7
unnecessary the same way Leg −1 might (§9.1). Note also that instance reuse cuts **against**
this document's own §5.4/§15.5 comfort that the offline registry is disposable: a reused
instance carries state between renders, which is exactly the hazard §15.8 has already
measured. It is cheaper, not free.

### 15.8 ⛔ OPEN FINDING — two fully-warm renders of the same material do not null

**Its own defect, not a footnote to the dropout. Filed 2026-08-20; cause not chased.**

**MEASURED:** two stem renders of a hosted AU with **identical, correct** first-note onsets
(runs 4 and 5 of §15.1, both at 9.869 s) differ by a **−3.07 dB peak residual** when nulled
against each other. The method is controlled: nulling a file against **itself** gives
**−inf**, so the instrument can report a true null and did not.

**Why this matters independently of the silent head:** a bounce is supposed to be
reproducible. Two identical requests against an unchanged session produce audibly different
files, at a residual far too large to be dither or rounding. Every gate in this tree that
compares one render against another — stem-sum partitions, WYSIWYG bounce comparisons, the
Leg 5 exit criteria — is measuring on top of this, and none of them knew.

**Provenance:**
- **MEASURED:** the residual and the control.
- **UNVERIFIED, would fit:** unreset plugin state carried between offline renders. §15.5
  records that there is no reliable way to reset a third-party AU, which is what makes this
  candidate plausible and also what makes it hard to test directly.
- **NOT ESTABLISHED:** whether this is specific to DecentSampler, to hosted AUv2s, to
  samplers with background loaders, or general to any hosted plugin. One render of a
  hosted **Apple** unit, twice, would narrow it in minutes and has not been done.
- **NOT ESTABLISHED:** whether R-1 caused it, was innocent of it, or masked it. Round one
  reported byte-identical repeats on the pre-R-1 build; round two contradicts that on the
  post-R-1 build — but round one's comparison method is not recorded and may never have
  been a null (§15.1). **Do not assume R-1 introduced this.**

**It bounds every design in §15.5.** Any convergence criterion, any "the fix worked"
comparison, and any regression gate built on bounce-vs-bounce identity has a **−3.07 dB
noise floor** under it until this is chased.

---

## 16. PITCH BEND ON HOSTED AUs IS STUCK AT ±2 SEMITONES

### 16.1 The finding, confirmed in code

**Measured, positive-controlled 2026-08-20: this host never transmits RPN.**
`HostedAUInstrument.render()` emits `0xE0 LSB MSB` and nothing else
(`HostedAUInstrument.swift:207-211`); the byte translation there is exhaustive over
`ScheduledMIDIEvent` kinds, and none of them is an RPN. A `RPN` grep over `Sources/`
returns **exactly one line** — a doc comment in `BreathContour.swift:432` — and
`CC 101` / `controller.*101` return zero (exit 1). So the concept is documented in DAWCore
and reaches the wire nowhere. Registered Parameter Number 0 — *pitch bend
sensitivity*, the only standard way a MIDI host negotiates bend range — is never sent by
any code path. So every hosted AU runs at **whatever its own default is**, which for
AUSampler/DLSMusicDevice and for the overwhelming majority of plugins is **±2 semitones**.
The tester's report is not a plugin limitation; it is a hosting gap.

Corroborating in-tree: the built-ins hardcode the same assumption
(`SamplerInstrument.swift:308`, `PolySynthInstrument.swift:96`, both
`bendRangeSemitones = 2.0`), and `BreathContour`'s option
(`Sources/DAWCore/BreathContour.swift:295-304, 432-433`) already carries a
`bendRangeSemitones` whose own comment names *"the range any MIDI instrument advertises via
RPN 0"* — the concept is modelled in DAWCore and simply never reaches the wire.

⚠️ **The consequence is worse than a range limit: it is a silent scale error.** The M28
breath contour computes bend deflection against an assumed range. If the plugin's real
range differs, every expressive bend is wrong by the ratio — and it will read as "the
plugin's vibrato is too shallow", not as a units bug.

### 16.2 The fix — Leg B (~1 d)

Emit the standard RPN 0 sequence through the existing `scheduleMIDI` block (no new render
mechanism, no new AU API):

```
CC 101 = 0      (RPN MSB)
CC 100 = 0      (RPN LSB — selects pitch-bend sensitivity)
CC 6   = semitones
CC 38  = cents
CC 101 = 127, CC 100 = 127   (RPN null — close the parameter)
```

The RPN-null tail is **not optional**: leaving the parameter selected means a later CC 6
from a controller lane silently rewrites the bend range instead of doing what it says.

Four requirements the implementer must not lose:

1. **Re-send after every reset.** `HostedAUInstrument.reset()` sends **CC 121, reset all
   controllers** (`:281-282`), which on a spec-compliant device clears registered-parameter
   state. A range set once at prepare and never re-sent is **silently lost at the first
   transport stop** — and would look exactly like a plugin that ignores RPN.
2. **Feed the same number to `BreathContour.bendRangeSemitones`**, so our contour math and
   the plugin's interpretation cannot disagree. One value, one source.
3. **Honesty: there is no readback.** MIDI gives no way to ask what took. Many plugins
   ignore RPN 0 and expose range as their own parameter instead. The wire must therefore
   report the *requested* range, never a confirmed one, and the wording must say
   "requested". The only real instrument is a rendered pitch measurement — worth one probe
   (bend to full scale, measure f₂/f₁), and worth pairing with the already-open unrun
   question about whether the stock `gs_instruments.dls` sax honours CC 1 vibrato: **one
   render settles both**.
4. **RT cost, ties to §5.3 B1:** this adds 6 `scheduleMIDI` calls per reset edge. In-process
   that is nothing. **Out-of-process, if each is a round trip, it is 6 more crossings at
   exactly a transport edge** — fold it into the Leg 0-C measurement rather than discovering
   it later.

Wire (additive): extend `track.setInstrument` with an optional `bendRangeSemitones`
(default 2, clamped 0.01…48 to match `BreathContour`'s existing clamp) rather than adding a
verb — **no new command, no wire-count move**, which is the cheapest correct shape here.
⚠️ **It does move a SCHEMA, and this tree's own law applies: "a mirror in sync by tool NAME
can still be stale in tool SCHEMA."** Because no count changes, every count-based check
stays green while the MCP mirror silently lacks the parameter — the worst shape there is.
Regenerate with `npm run bundle:plugin` and diff the mirror **by schema text** for
`bendRangeSemitones`, with a negative control (a string known absent must return nothing),
exactly as the P2/P3 breath-pad measurements did. Tests: byte-exact pinning of the emitted sequence via the
existing `scheduleMIDIOverride` test seam (`HostedAUInstrument.swift:76-79` — built for
exactly this), including the RPN-null tail and the re-send after `reset()`; plus a
DAWCore test that the descriptor's value is the one `BreathContour` consumes.

---

## 17. SOURCES

**Primary (read on this machine, 2026-08-20):**
- `…/MacOSX26.5.sdk/…/AudioToolbox.framework/Headers/AudioComponent.h:177-244`
  (`AudioComponentFlags`, `AudioComponentInstantiationOptions`), `:497-515`
  (`AudioComponentInstantiate`).
- `…/AudioToolbox.framework/Headers/AUAudioUnit.h:931-947` (`isLoadedInProcess`),
  **`:1024-1035` (`renderingOffline` — the §15 finding)**, `:426-434`
  (`allocateRenderResourcesAndReturnError`), `:446-449` (`renderResourcesAllocated`),
  `:588` (`allParameterValues` KVO pseudo-property).
- `…/AudioToolbox.framework/Headers/AudioUnitProperties.h:445, :924`
  (`kAudioUnitProperty_OfflineRender = 37` — the v2 bridge of `renderingOffline`).
- `…/AudioToolbox.framework/Headers/AUComponent.h:778-836` (`kAudioComponentErr_InstanceInvalidated`,
  `kAudioUnitErr_RenderTimeout`, `kAudioComponentErr_InstanceTimedOut`), `:1128-1167`
  (`kAudioComponentInstanceInvalidationNotification`).
- `~/Library/Logs/DiagnosticReports/DAWApp-2026-08-20-153332.ips` and
  `DAWApp-2026-08-20-154549.ips`.
- `~/Library/Audio/Plug-Ins/Components/DecentSampler.component/Contents/Info.plist`.
- `AVAudioUnitComponentManager` enumeration, 75 components (2026-08-20).

**Apple documentation:**
- [Migrating Your Audio Unit Host to the AUv3 API](https://developer.apple.com/documentation/audiotoolbox/migrating-your-audio-unit-host-to-the-auv3-api)
- [Hosting Audio Unit Extensions Using the AUv2 API](https://developer.apple.com/documentation/audiotoolbox/hosting-audio-unit-extensions-using-the-auv2-api)
- [AudioComponentInstantiationOptions](https://developer.apple.com/documentation/audiotoolbox/audiocomponentinstantiationoptions)
  (the per-constant abstracts are empty on the web; the SDK header is the usable source)

**Real-world prior art:**
- [Mixxx PR #16106 — "Fix AudioUnit startup crash by loading out-of-process (macOS)"](https://github.com/mixxxdj/mixxx/pull/16106)
  — switched to `AudioComponentInstantiate` + `kAudioComponentInstantiation_LoadOutOfProcess`
  for crash isolation ("The XPC service dies, not Mixxx"); **publishes no latency or CPU
  data**, and its follow-up performance issue was about *init* time.

**In-tree:**
- `docs/research/m23av-routeb-feasibility-probe.md` (corrected here, §2.5)
- `docs/research/design-m23av-prepare-status-offmain.md`, `docs/research/design-vi-b-au-windows.md`,
  `docs/research/design-m16a-canvas-crash.md`
- `Sources/DAWEngine/AudioUnits/{AUHostRegistry,HostedAUInstrument,AUPrepareLedger,AUViewProbe,SilentPlaceholderInstrument}.swift`,
  `Sources/DAWEngine/Effects/HostedAUEffect.swift`,
  `Sources/DAWEngine/{EnginePerformance,ObjCExceptionBarrier}.swift`,
  `Sources/DAWCore/{EngineProtocol,AutosaveManager}.swift`
