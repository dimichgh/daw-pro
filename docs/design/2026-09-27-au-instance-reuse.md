# AU instance reuse across offline renders: the costing (sax defects ③ ④ ⑤)

**Lane W7-AUR (daw-architect), 2026-09-27. DESIGN AND COSTING ONLY.** No source, test, or
other doc file was modified while writing this. No build, no test run, no AU was
instantiated, no render was made. Nothing here authorises code; implementing any item
below follows the normal orchestrator routing, and commits happen only on the user's word.
This document answers gate **G0** of `docs/research/design-m29-oop-au-hosting.md` §3.1
("cost AU-instance reuse across renders first").

## How to read the evidence in this document

| tag | meaning |
|---|---|
| **[R file:line]** | Read by me in this tree on 2026-09-27. |
| **[R-web URL]** | Read on a public web page on 2026-09-27. A vendor's release note is the vendor's **claim**, not our measurement. |
| **[M who, when]** | Measured, by the named party, at the named time. "Tester" = the sax-composition tester (external loop); "orchestrator" = the main session; "me" = this lane, 2026-09-27. |
| **[A]** | Assumed, inferred, or estimated. Every cost figure is [A]. Every mechanism that has not been observed directly is [A]. |

**Line numbers drift, and already did once.** W7-ME2 (m39-e-2) owns
`Sources/DAWEngine/OfflineRenderer.swift`, the offline entry points of
`Sources/DAWEngine/AudioEngine.swift`, `Sources/DAWCore/EngineProtocol.swift`,
`Sources/DAWCore/ProjectStore+Render.swift` and `Sources/DAWCore/ProjectStore+Bounce.swift`
while this is written [R `$S/w7/common.md` lane table, row W7-ME2]. Its edits landed at
09:30 PDT, between my first reads and publication, and shifted many cited lines, by up to 55;
other lanes were still writing to some of these files during the re-check.
**Every file:line below was re-verified against the tree at 2026-09-27 10:00 PDT** [M me: a
scripted expected-text check of each cited line]. That check also found three off-by-one
citations of mine in files that had not changed, and one continuation citation whose file
could only be read from its position; all four are corrected. The file versions the numbers
refer to are pinned in §14.1 by line count and `git hash-object`: these are uncommitted
working copies, so there is no commit to cite. Where a file no longer matches its pin,
re-resolve by the symbol each citation names, never by the number.

**Two premises of the M29 design were falsified by measurement, and nothing below rests on
either** [M tester 2026-08-20; recorded in M29 §15.1 and §15.5(c)]:

1. "Where decode/parse dominates (46 zones), warm and cold are the same number." False: the
   46-zone sax warmed 31.974 s → 15.001 s → 9.869 s across renders in one process.
   Something survives a fresh AU instance's lifetime; what, is not known.
2. "The sax bounce is byte-identical cold and warm." False: two fully-warm renders differ by
   a −3.07 dB peak residual (self-null gives −inf). Byte identity is still the wrong stop
   condition, but because it would **never** terminate, not because it would terminate early.

---

## 0. Summary

**The decision.** Reuse hosted AU instances across offline renders through a **dedicated
offline pool that the engine owns**. It is never the live instance. It is staged
cheapest-first so that each stage is also the experiment that decides whether the next one
is needed:

- **AUR-1 (about a day).** The PDC plan that `render.stems` and `track.bounceInPlace` build
  first **never reads a hosted instrument's latency** [R `PlaybackGraph.swift:1830-1836`,
  the `PDCStripInput` assembly]. Yet it instantiates every hosted instrument in the session
  and throws them away [R `AudioEngine.swift:3710-3718`, `offlineCompensationTargets`].
  Stop preparing instruments in the plan. This removes the sax's double instantiation, the
  one code difference between the two failing verbs and the working one. It carries no
  reuse semantics at all, so it is the cleanest possible test of the throwaway hypothesis.
- **AUR-2 (3–4 days).** An engine-owned offline pool with three policies (`fresh` = today,
  `request` = one set of instances per export, `session`), a FIFO lease, garbage
  collection by track presence, no memoized failures, an explicit reset contract, and
  observability. It ships with `request` as the default.
- **AUR-3 (about a day).** Quiesced disposal: dealloc and reset, then a grace period before
  the last reference drops, for both pool and live releases.
- **AUR-4 and AUR-5 (conditional).** A warm pass on the pooled instance (R-2 reframed) and a
  pace-cap diagnostic. Build them only if AUR-1 does not fix ③ cold.

**Verdict per defect:**

| defect | does reuse fix it? | how we will know |
|---|---|---|
| **③ stems/bounce drop cold, mixdown fine** | **Probably yes for stems and bounce, if the throwaway is causal (M1).** AUR-1 removes it outright. A confound nobody has recorded before is **unexcluded**: the failing verbs render one track, and so render faster in wall-clock time than a whole-session mixdown (M2). Under M2, reuse fixes only renders after the first, and the cold criterion needs AUR-4 or AUR-5. | Pre-registered: after AUR-1, a **cold `track_bounce_in_place` in a fresh process lands at 9.869 s** ⇒ M1. It still drops ⇒ M2. Tester gate G-SAX (§7.2). The zero-code E0 run (§7.3) decides between them on today's build. |
| **④ freed-memory crash** | **Unknown; at best partly.** Reuse cuts our instantiate and dispose churn (per stems export from roughly 2× to 1× the session's hosted AUs, and to about 0 per export under `session`), and AUR-3 targets the "message queued for a disposed instance" class. It cannot contain a crash that is the plugin's own. **New:** the vendor's notes list crash fixes from 1.30.0 to 1.32.0 [R-web]. One is "the periodic update check crashed almost every launch for anyone running an older build"; another covers crashes "while a preset was still loading its samples". **This Mac runs 1.29.0 [M me]**, older than all of them. | No pass condition can prove a fix for an intermittent crash. The mechanism signals are: E1, a per-render thread census; an upgrade A/B. Only M29 contains a crash whatever its cause. |
| **⑤ warm renders do not null (−3.07 dB)** | **No, by any mechanism that can be named.** ⑤ was measured on **fresh** instances, so per-instance state was already fresh. Reuse can make it **worse**: it carries round-robin position, voice state and LFO phase between renders. | Pass for reuse: reuse-vs-reuse residual ≤ fresh-vs-fresh residual ("not worse"). To actually fix ⑤, run the zero-code E2: disk streaming vs the plugin's **RAM mode** (a documented engine setting [R-web 1.32.0]), and check the preset's round-robin/random settings. Then AUR-5 pacing. |

**Cost.** The unconditional core (AUR-1, AUR-2, the wire leg, AUR-3) is **about 5–7
engineering days [A]**, with no RT-invariant amendment, no entitlement, no full Xcode.
Adding the conditional items makes it about 8–11 days [A]. M29 out-of-process is **2–3+
weeks [A]**, amends the render-thread invariant [R M29 §5], and needs the user's word. It
still wins on one thing only: **containing** ④ whatever its cause. Recommendation: do
AUR-0 (zero code) and AUR-1 now, then AUR-2 and AUR-3, and decide M29 on the evidence.

**Three questions for the user** (§12): update DecentSampler to 1.33.2, after one baseline
round on the installed version; allow one agent to load DecentSampler in the separate test
copy of the app for a thread count; hold M29 until this evidence lands. Each has a default.

---

## 1. Inputs: what was measured, and by whom

### 1.1 The tester's and the orchestrator's measurements

| fact | provenance |
|---|---|
| 46-zone sax on DecentSampler, within one session: a 35 s stem silent throughout; run 1 first sound at **31.974 s**; runs 2–3 at **15.001 s**; runs 4–5 at **9.869 s**; the correct onset is **9.868 s**. It warms monotonically. | [M tester 2026-08-20, shipped build `412cb33`, R-1 wiring verified by them; M29 §15.1 table] |
| `render_stems` and `track_bounce_in_place` drop; **`render_mixdown` was correct from the first cold call** of the session. | [M tester 2026-08-20; M29 §15.7] |
| Two fully-warm renders (runs 4 and 5, both onsets correct) differ by a **−3.07 dB** peak residual; a self-null gives −inf. | [M tester 2026-08-20; M29 §15.8] |
| **The DecentSampler build behind the three rows above was not recorded.** M29 names a version only for the crashes (1.23.5 at `design-m29-oop-au-hosting.md:92`, `:1092`). That the tester's renders ran on 1.23.5 too is an inference from the same-day crash reports on this machine and from the installed copy's 2026-08-30 write date (M-a). So every comparison in this document is made **within one plugin build**, and the 2026-08-20 numbers motivate the gates without being their baseline (§7.2). | [A; R `design-m29-oop-au-hosting.md`, where `1.23.5` occurs only at `:92` and `:1092`] |
| DecentSampler **accepts** `kAudioUnitProperty_OfflineRender` (writable, set 0, read back 1), instantiates in ~59 ms and disposes in ~47 ms, with no wedge. **Accepting is not honouring:** it still drops. | [M R-1 agent 2026-08-20; memory `daw-pro-sax-defects.md` ③ close record] |
| A GM sound-bank bounce, flag off vs flag on: **0 of 96 000 samples differ.** Two separate **fresh-instance** renders of AUSampler are byte-identical. This is the "Apple unit rendered twice" discriminator M29 §15.8 asked for, obtained in passing. | [M R-1 agent 2026-08-20; the assertion is `OfflineRenderReadinessTests.swift:528-572`] |
| Three crashes (2026-08-20 15:33:29, 15:45:46, 20:42:53): SIGSEGV on thread 0, `com.apple.main-thread`, four DecentSampler 1.23.5 frames then `__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__`. The fault addresses were `0x656c706d6153223d` (`="Sample`), `0x9f6`, and `0xc0642da9f002a7f4`. | [M orchestrator 2026-08-20, re-parsing the `.ips`; M29 §1 table and stack] |
| In crash 3 the live graph was mid-render through six nested hosted AUv2 bridges; in crashes 1 and 2 the IO thread was parked. | [M orchestrator 2026-08-20; M29 §1.1 point 1] |
| `WavePlayers` thread counts 54 / 36 / 18 across the three reports. The 3 / 2 / 1 instance reading is **not** a fact (the auxiliary threads run 2 / 2 / 1). | [M orchestrator 2026-08-20; M29 §1.2] |
| A fourth crash on the user's machine, 2026-08-30 02:19:06, after a 28-minute Musical Typing session: `KERN_INVALID_ADDRESS at 0x8`, main thread, **seven** DecentSampler frames then the same source0 callout, zero DAWApp frames above the run loop. **Whether any offline render ran in that session is unknown.** | [M orchestrator 2026-08-30; memory `daw-pro-sax-defects.md` "REPRODUCED ON THE USER'S OWN MACHINE"] |
| Surge XT `track_set_instrument` wedged the main actor for ~3.5 min (2026-07-20); it did not reproduce warm on 2026-08-04 (instantiate 0.0732 s). | [M orchestrator; memory `daw-pro-au-hosting-wedge.md`] |
| A second GM bank load in one test costs **28.7 s** under full-suite parallel load, against 0.12 s isolated. The gate reuses one offline renderer across two renders **on purpose** for that reason. | [M, recorded in `FirstClipDropProbeTests.swift:193-203`] |

### 1.2 Measured by me today (W7-AUR, 2026-09-27)

- **M-a.** DecentSampler is installed at `/Library/Audio/Plug-Ins/Components/DecentSampler.component`,
  `CFBundleShortVersionString` **1.29.0**, component `aumu/Dsmp/Dldy`, `sandboxSafe` true,
  directory mtime 2026-08-30 09:53. `~/Library/Audio/Plug-Ins/Components/`, the path M29
  §1 and the memory cite, holds only Dexed, Surge XT and TyrellN6. **The crashing 1.23.5
  copy is gone, and the installed build is not the one that crashed.** (Method: `plutil
  -extract` on the bundle's `Info.plist`; `ls -la` of both directories.)
- **M-b.** `~/Library/Logs/DecentSampler/` holds two logs dated 2026-09-24. Each is a
  123-byte header reading "Decent Sampler 1.29.0", with no load timing.
- **M-c.** `~/Library/Logs/DiagnosticReports/` and its `Retired/` hold **zero** DAWApp
  reports (positive control: 57 `harness-*` reports in the same listing). **None of the
  four crash reports can be re-read.** Everything about ④'s stacks rests on the 2026-08-20
  and 2026-08-30 readings.
- **M-d.** `OfflineRenderer.swift` contains no `releaseInstrument`, `releaseEffect`,
  `deinit` or `deallocateRenderResources` (grep exit 1; control: `prepareAudioUnits`, 6
  hits). `AUHostRegistry.swift` has no `deinit` (exit 1; control: `HostedAUInstrument.swift:105`).
  **Offline AU instances are disposed by ARC when the renderer dies, without the
  dealloc/reset/`onRelease` sequence the live release path runs** (§2.4).
- **M-e.** No `musicalContextBlock` or `transportStateBlock` anywhere in `Sources/` (0
  lines; control: `scheduleMIDIEventBlock`, 3 in `HostedAUInstrument.swift`). Hosted AUs get
  no tempo or transport. A plugin's tempo-synced LFO free-runs on its own clock.
- **M-f.** The Σ-stems / bounce / render suites (`StemNullTests`,
  `OfflineBufferRenderTests`, `MasteredMixdownStemsTests`, `BounceInPlaceTests`,
  `RenderExclusionRenderTests`) contain **zero** hosted instruments. Pattern:
  `kind: \.soundBank|kind: \.audioUnit|subType: "samp"|subType: "dely"`; control: 6 hits in
  `OfflineRenderReadinessTests`. **The invariant Σ stems ≡ mixdown has never been checked
  with a hosted AU**, and reuse reaches it (T9).
- **M-g.** RPN 0 (bend range) is not emitted anywhere; only a comment mentions it
  (`BreathContour.swift:445`; control: `bendRangeSemitones`, 11 hits in `Model.swift`).
- **M-h.** Nothing serialises offline renders in DAWCore, DAWEngine or DAWControl (control:
  `renderCompletedCount` found). Concurrent offline renders are possible today.
- **M-i.** Production construction census: `OfflineRenderer(` ×2 (`AudioEngine.swift:3668`
  `renderOffline`, `:3715` `offlineCompensationTargets`). `AUHostRegistry(` ×2
  (`AudioEngine.swift:32`, live; `OfflineRenderer.swift:148`, offline).
  `offlineCompensationTargets` has 2 production callers (`ProjectStore+Render.swift:290`,
  `ProjectStore+Bounce.swift:107`).
- **M-j.** I downloaded the vendor's versions page raw (HTTP 200, 1,446,004 bytes, kept at
  `$S/w7/AUR/ds-versions.html`). Version strings 1.23.5 through 1.33.0 are each present
  (17×); 1.34.0 is absent (0×, negative control); the latest listed is **1.33.2
  (2026-09-24)**. **A first summarised fetch of the same page reported nothing after 1.29.0.
  That was a summariser's omission, not an absence, and the raw page is the evidence.**

### 1.3 The vendor's release notes [R-web https://store.decentsamples.com/downloads/decent-sampler/versions, fetched 2026-09-27]

Verbatim, and every line is a claim:

| version, date | note | why it matters here |
|---|---|---|
| 1.30.0, 2026-08-31 | "Two crash fixes. A corrupted sample library database could take the whole host down on load … And the periodic update check crashed almost every launch for anyone running an older build — the very people it was supposed to be notifying." | A periodic, main-thread-plausible, plugin-own crash. At the tester's crashes (2026-08-20), 1.23.5 was already "an older build" (1.24.0 shipped 2026-08-12). A competing ④ hypothesis (§5.2). |
| 1.30.1, 2026-09-04 | "Fixed two crashing bugs" | Unspecified. |
| 1.31.0, 2026-09-08 | "Fixed several crashes, including one when a project saved by an older version is reopened (0000445) and two that could happen while a preset was still loading its samples (0000448, 0000449)." "Fixed the plug-in hanging the host when it is removed …" "Fixed round robins not advancing on legato samples (0000218)." "Log files now include messages from background work." | Load-time crashes are exactly the window our per-render instantiation reopens on every render, and the throwaway closes an instance inside it (§2.4). There is a removal-time defect class. Round-robin position is per-instance state that reuse would carry (K1). |
| 1.32.0, 2026-09-09 | "This release is mostly about things that happen while a preset is loading." "Fixed a crash when opening a project with the engine set to RAM mode … the cause was in the sample loading itself and applied everywhere." "Switching between RAM and disk streaming …" "If our servers are slow to respond, the store no longer holds up closing a project or removing the plugin." "The log file now always records which preset was loaded and whether any sample failed to load." | There is a **RAM mode vs disk-streaming** engine setting (E2 for ⑤). Teardown was coupled to network work (the `OnlineManager TaskRunner` thread seen in the crash reports). Newer logs are a free loader readout. |
| 1.33.0, 2026-09-22 | "SFZ import handles … random round robins …" | Presets can be deliberately random, and ⑤ may be by design. |
| 1.33.2, 2026-09-24 | maintenance release, "no changes to features, sound or sample library compatibility" | Latest. |
| older | 1.6.6 (2022-10-11) "crash when closed and relaunched in rapid succession"; 1.8.0 (2023-02-25) "intermittent crashes when the plug-in was unloaded in Ableton Live"; 1.13.8 (2025-08-24) "crashes the version checker …"; 1.13.9 (2025-08-26) "Crash when loading/reloading/unloading a preset after a 1st loading of a preset"; 1.17.1 (2026-03-22) "go silent, crash, or produce bursts of noise when in disk streaming mode" | This plugin's own history shows repeated defects at exactly the lifecycle transitions that fresh-per-render instantiation multiplies, and timing-sensitive disk streaming. |

What the notes do **not** say: which host, format (AU vs VST3) or OS each fix applies to, and
what the failing stack was. None of them is attributable to our crash reports [A].

---

## 2. The current lifecycle, read from source

### 2.1 Census method (reproducible; every negative is positive-controlled)

1. Offline renderer constructions: `grep -rn -E 'OfflineRenderer\(' Sources/`. Result: 2
   (`AudioEngine.swift:3668`, `:3715`).
2. Registry constructions: `grep -rn -E 'AUHostRegistry\(' Sources/`. Result: live
   `AudioEngine.swift:32`, offline `OfflineRenderer.swift:148`, plus a doc mention at
   `AUHostRegistry.swift:293`.
3. Plan callers: `grep -rn offlineCompensationTargets Sources/`. Result: 2 production callers
   (`ProjectStore+Render.swift:290`, `ProjectStore+Bounce.swift:107`), the protocol
   requirement (`EngineProtocol.swift:957`), and its default (`:2198`).
4. Render callers: `grep -rn -E 'renderOffline\(' Sources/`. Result: 19 hits: 9 store
   call sites, 3 forwards, 6 declarations, and AVAudioEngine's own pull
   (`OfflineRenderer.swift:527`). The forwards are `AudioEngine.swift:3604` (`renderMixdown`),
   `AudioEngine.swift:3625` (the legacy overload into the master-modulation one, m39-e-2),
   and `EngineProtocol.swift:2258` (a protocol default that forwards when no
   master-modulation route is enabled and throws otherwise). The hosted-AU-capable store
   sites are `ProjectStore+Render.swift:32` (measure), `:120` (bounce), `:304`/`:335`/`:368`
   (stems: pass, mixdown sibling, mastered sibling), `ProjectStore+Bounce.swift:115` and
   `ProjectStore+TimbreLiveness.swift:138`, plus `render.mixdown` through
   `AudioEngine.swift:3604`. `ProjectStore+ClipFix.swift:139` and
   `ProjectStore+ClipVoiceConversion.swift:246` render synthetic audio-only tracks and never
   host an AU.
5. Teardown: grep `releaseInstrument|releaseEffect|deinit|deallocateRenderResources` in
   `OfflineRenderer.swift` (exit 1) and `deinit` in `AUHostRegistry.swift` (exit 1), with
   the controls listed in M-d.
6. Live registry sites: `grep -n 'auRegistry\.' Sources/DAWEngine/AudioEngine.swift`
   (the prepare/release sync at `AudioEngine.swift:2686-2743`, `:2789-2840`).

### 2.2 One hosted instrument through one offline render, step by step

Assume a `.audioUnit` instrument with restored `stateData`, the tester's shape: DecentSampler
with a preset.

| # | step | where | thread / actor |
|---|---|---|---|
| 0 | The store captures the **live** instance's `fullStateForDocument` into a local track copy. It runs once per request (stems: once for the whole set). | `ProjectStore.tracksWithLiveAudioUnitState` [R `ProjectStore.swift:8189-8216`]; stems capture [R `ProjectStore+Render.swift:287`]; bounce-in-place [R `ProjectStore+Bounce.swift:106`] | main actor |
| 1 | A new `OfflineRenderer` builds a **new** `AUHostRegistry(rendersOffline: true)`. | [R `AudioEngine.swift:3668`, `OfflineRenderer.swift:131-149`] | main |
| 2 | `prepareAudioUnits` walks **every** track: hosted instruments, then hosted inserts (maxFrames = 512). | [R `OfflineRenderer.swift:159-175`] | main |
| 3 | A per-track prepare chain, idempotent per `PrepareKey` (component, rate, **stateData**, bank address). | [R `AUHostRegistry.swift:460-474`, key `:55-60`, guard `:786`] | main |
| 4 | Instantiate (in a `DeadlineRace`, 10 s production wall). | [R `:850-861`, `:355`] | a Task on main; the deadline runs off-main |
| 5 | `maximumFramesToRender = 8192`, then set the output format at 48 kHz. | [R `:863-869`] | main |
| 6 | **`isRenderingOffline = true`**, set before the state restore (Leg R-1). | [R `:882`, `:330-341`] | main |
| 7 | **`fullStateForDocument =` restored.** Per the code's own note, this is what starts a plugin's secondary-thread sample loading. | [R `:878-881`, `:889-903`] | main |
| 8 | `allocateRenderResources` (DLS family: on `dlsBankQueue`). | [R `:917-922`] | main or the bank queue |
| 9 | (`.soundBank` only) the bank loads synchronously on `dlsBankQueue` and is **awaited**, so a GM bank is resident before rendering. | [R `:936-944`] | bank queue, awaited |
| 10 | Wrap in `HostedAUInstrument`, capturing `renderBlock` and `scheduleMIDI`; publish `.ready`. | [R `:945-963`, `HostedAUInstrument.swift:85-103`] | main |
| 11 | `beginSession`: a new `AVAudioEngine` in `.offline` manual mode, a new `PlaybackGraph`, the providers point at this registry, reconcile, start, schedule, start players. | [R `OfflineRenderer.swift:280-483`] | main |
| 12 | `addInstrumentNode` gets the adapter from the provider; `prepare(sampleRate:)` is a no-op at the same rate. | [R `PlaybackGraph.swift:2884-2894`, `HostedAUInstrument.swift:135-136`] | main |
| 13 | The pull loop: one 512-frame quantum, then `await Task.yield()`, repeated. **The offline "render thread" is the main thread.** The adapter's timeline `hostSampleTime` starts at 0 and never resets. | [R `OfflineRenderer.swift:244-274`, `:525-544`; `HostedAUInstrument.swift:59-66`] | main, cooperative |
| 14 | `finish()` stops the engine. | [R `OfflineRenderer.swift:547-550`] | main |
| 15 | `renderOffline` returns and the renderer, graph, registry and adapter lose their last references. **ARC disposes the AU with no `deallocateRenderResources`, no `reset`, no `onRelease`.** | [M-d; `HostedAUInstrument.swift:105-119`] | main (DLS: bank queue) |

### 2.3 Instantiations per verb, today

`H` = hosted AUs (instruments plus inserts) in the whole session; `h(p)` = hosted AUs in
pass `p`'s track subset.

| verb | route | hosted-AU instantiations per call |
|---|---|---|
| `render.mixdown` | `ProjectStore.renderMixdown` [R `ProjectStore.swift:7700-7743`] → `AudioEngine.renderMixdown` [R `AudioEngine.swift:3590-3614`] → `renderOffline(forced: nil)` | **H** (excluded tracks are muted copies and still prepared [R `ProjectStore+Render.swift:77-86`, doc]) |
| `render.bounce`, `render.measureLoudness` | [R `ProjectStore+Render.swift:96-150`, `:23-52`] | **H** |
| `render.stems` | plan [R `ProjectStore+Render.swift:290`] + one pass per stem [R `:304-315`] + optional mixdown [R `:335-343`] + optional mastered [R `:368-376`] | **H (plan, thrown away) + Σ h(p) + H + H**: at least 2H, up to 4H+ |
| `track.bounceInPlace` | plan [R `ProjectStore+Bounce.swift:107`] + one pass [R `:115-124`] | **H (plan, thrown away) + h(pass)**. Bouncing one track instantiates **every** hosted AU in the project once more for a plan that is then discarded. |
| `instrument.probeLiveness` | [R `ProjectStore+TimbreLiveness.swift:82-151`] | 1 (the probe track's effects are stripped) |
| AI clip fix, voice conversion | synthetic audio-only tracks | 0 |

**What the plan actually reads.** `compensationPlanTargets` reconciles a graph and runs one
parameter pass [R `OfflineRenderer.swift:561-587`]. The PDC input is assembled only from
each strip's **insert-effect chain latency** (`chainLatencyAll`, `chainLatencyActive`,
`sidechainKey`) [R `PlaybackGraph.swift:1803-1836`]. No instrument latency enters it.
The hosted **instrument** half of the throwaway is therefore pure cost. It exists only
because `prepareAudioUnits` prepares both kinds [R `OfflineRenderer.swift:159-175`]. The
comment "their hosted latency is part of the plan" [R `AudioEngine.swift:3711-3714`] is
true of hosted **inserts** only. This is what makes AUR-1 possible (§3.1).

### 2.4 Teardown: offline and live differ

- **Live** `releaseInstrument` [R `AUHostRegistry.swift:497-519`] clears bookkeeping, counts
  the release, fires `onRelease` (plugin windows close against a live AU), then
  `deallocateRenderResources()` + `reset()`. The DLS family does this on `dlsBankQueue`, and
  the final release lands there too. `releaseEffect` mirrors it [R `:587-599`].
- **Offline**: no release path is ever called [M-d]. The instance dies by ARC at renderer
  death. The **throwaway** dies when `offlineCompensationTargets` returns, moments after
  its state was restored and its resources allocated, with only the plan's graph build in
  between (unmeasured) [R `AudioEngine.swift:3715-3717`], i.e. **while a lazy loader started by step 7 is typically
  still running** [A: unmeasured for DecentSampler]. The real renderer's instances die when
  `renderOffline` returns [R `:3668`].
- Why it matters [A]: disposal happens inside the same main-actor job that just restored and
  allocated. Any work the plugin has queued on the main run loop for that instance then fires
  after dispose, unless the plugin cancels it in its destructor. This is the H-ours
  mechanism of M29 §1.2. The vendor's 1.31.0 fix for "two [crashes] that could happen while
  a preset was still loading its samples" [R-web] names this very window as one that
  crashed. It is not evidence that ours did.

### 2.5 What "fresh instances per render" buys, and what it does not

| property | fresh today | evidence |
|---|---|---|
| Apple units render deterministically | **yes** | GM 0/96 000 differ [M R-1 agent] |
| DecentSampler renders deterministically | **no** | ⑤ −3.07 dB on fresh instances [M tester] |
| Leg R-1's safety (the offline flag never reaches live) | comes from **separateness**, not freshness: `rendersOffline` is an init-time `let` on a registry the live graph never reads | [R `AUHostRegistry.swift:288-316`]. The comment at `:294-297` says the flag is safe "ONLY because `OfflineRenderer` owns a SEPARATE registry with fresh AU instances per render", folding the two properties together. A pool keeps separateness. |
| Two concurrent offline renders cannot interfere | yes, **by construction**: each owns its own engine, graph and registry | [R `OfflineRenderer.swift:235-238`]. With a pool this must become a **lease** (§3.4). |
| WYSIWYG patch | yes: the live state is captured per request | [R `ProjectStore.swift:8154-8189`]. The pool keeps it: a `stateData` change changes the `PrepareKey` and forces a re-prepare [R `AUHostRegistry.swift:786`, `:806-807`]. |
| Cost | instantiate + restore + allocate on the main actor, per render, per hosted AU | 28.7 s vs 0.12 s for a second GM load under suite load [M, `FirstClipDropProbeTests.swift:193-196`] |

### 2.6 Concurrency today

- `AudioEngine`, `OfflineRenderer`, `AUHostRegistry` and the `AudioEngineControlling`
  protocol are all `@MainActor` [R `AudioEngine.swift:19-20`, `OfflineRenderer.swift:42-43`,
  `AUHostRegistry.swift:37-38`, `EngineProtocol.swift:689-690`].
- Offline pulls run on the **main thread** (manual rendering inside `pullNextQuantum`) and
  yield every 512-frame quantum [R `OfflineRenderer.swift:265-270`, `:525-544`;
  `RenderBlockSize.swift:94`]. Between quanta the main run loop turns, so a plugin's
  main-thread messages (JUCE's queue arrives as a `CFRunLoopSource0` [R M29 §1.1]) are
  delivered **during** offline renders [A].
- Nothing serialises offline renders [M-h]. Another command can start a second render while
  one yields.
- The wedge intercept reads only the **live** registry's in-flight ledger
  (`auPrepareInFlight()` [R `AudioEngine.swift:3763-3775`]). Each transient offline
  registry has its own `prepareLedger` [R `AUHostRegistry.swift:121-129`], and nothing reads
  it. **A wedge inside an offline prepare reports "nothing in flight" today.** This blind
  spot predates this design, and a pool closes it (§3.4).

---

## 3. The decision

### 3.1 AUR-1: the plan stops instantiating instruments (the smallest discriminating change)

**Change.** `AudioEngine.offlineCompensationTargets` prepares hosted **insert effects only**.
Hosted instrument tracks reconcile against the silent placeholder in the planning graph.
That changes no target, because the plan reads no instrument latency (§2.3) [R
`PlaybackGraph.swift:1803-1836`]. Implementation: split
`OfflineRenderer.prepareAudioUnits(tracks:)` [R `OfflineRenderer.swift:159-175`] into
instrument and effect halves, or give it an `includeInstruments:` parameter that defaults
to `true`, and call the effects-only form from the plan. A hosted instrument that skipped
prepare renders the silent placeholder [R `OfflineRenderer.swift:363-368`]; the implementer
confirms that the planning graph's placeholder wiring logs nothing. The "not prepared"
warnings live in `beginSession` [R `:374-388`], which the plan never runs.

**What it does to the defect's code path.** `track.bounceInPlace` then instantiates the
sax **exactly once**, the same as `render.mixdown`. `render.stems` instantiates it once per
pass that contains it, never twice back to back. This is the discriminating experiment M29
§15.7 asked for ("make the two failing verbs reuse one renderer (or take the plan off the
real one) and re-measure"), in its smallest form. It has **no reuse semantics**, so no
state carries anywhere and there is no reset contract to trust.

**What it costs.** About 0.5–1 day with gates [A]. There is no wire change and no new
concept. It also saves main-actor time and memory on every stems export and every
bounce-in-place (one fewer instantiation per hosted instrument in the session).

**Gates.** T1 and T2 (§7.1), plus the existing suites staying byte-identical. That follows
by construction: identical plan targets mean identical forced targets, hence identical
bytes for every deterministic unit.

**Doc edits in the same change.** `EngineProtocol.swift:950-957` ("a planning pass prepares
the session's AUs (hosted latency)") and `AudioEngine.swift:3711-3714` become "prepares the
session's hosted **insert effects**".

### 3.2 AUR-2: the offline pool

**Which instance.** A dedicated offline instance per hosted slot: the track id for an
instrument, the effect id for an insert. The owner is a new engine-level `OfflineAUPool`
(`Sources/DAWEngine/AudioUnits/OfflineAUPool.swift`). It holds **one**
`AUHostRegistry(rendersOffline: true, retriesFailedPrepares: true)` for the engine's
lifetime. It is **never** the live instance; §4 A says why.

**Key.** The registry's existing `PrepareKey` (component, rate, `stateData`, bank address)
[R `AUHostRegistry.swift:55-60`], unchanged. A key change re-prepares lazily at the next
render through the existing guard [R `:786`, `:806-807`]. The pool never compares keys
anywhere else (§3.5).

**Policies.** Their wire spellings are in parentheses.

| policy | lifetime of an offline instance | what it buys | what it costs |
|---|---|---|---|
| `fresh` (`"fresh"`) | one render: **exactly today's code path**, with `OfflineRenderer` building its own registry | the A/B control and the kill switch | today's churn |
| `request` (`"request"`), **default at ship** | one top-level store operation (a *batch*); drained, quiesced, at batch end | removes all churn **within** an export (plan + passes + siblings share instances); nothing carries **between** exports; no memory held between exports | still one instantiation per hosted slot per export |
| `session` (`"session"`) | until GC, idle eviction, memory pressure, or a project boundary | warm repeat bounces; about zero instantiate/dispose per export | an offline copy of each hosted instrument stays in memory (GB-scale for large libraries [A]); state carries between exports |

**The batch scope** (needed only for `request`). Two protocol requirements, **additive**,
with default no-op implementations in `extension AudioEngineControlling` [R
`EngineProtocol.swift:1731`]:
`func beginOfflineRenderBatch() -> Int` and `func endOfflineRenderBatch(_ token: Int)`.
Every top-level store render op wraps itself as
`let batch = engine.beginOfflineRenderBatch(); defer { engine.endOfflineRenderBatch(batch) }`.
The wrapped ops are `renderMixdown` (`ProjectStore.swift`, under the shared-file rule),
`measureLoudness`, `renderBounce`, `renderStems`, `bounceTrackInPlace` and
`probeInstrumentLiveness`. Depth is counted, and the drain happens when depth returns to
zero. **A render outside any batch is its own batch** (drained after the call), so
correctness never depends on a caller remembering to wrap; only the reuse benefit does.
`defer` works because both calls are synchronous on the main actor.

**Engine wiring.**
- `AudioEngine` gains `let offlineAUPool = OfflineAUPool()`, next to `let auRegistry` [R
  `AudioEngine.swift:32`].
- `renderOffline` [R `:3637-3708`, the master-modulation overload, which the legacy one
  forwards to]: under `fresh`, today's code. Otherwise:
  1. acquire a lease (`defer` release);
  2. build `OfflineRenderer(… auRegistry: lease.registry)` (a new internal init; the public
     convenience init keeps building its own registry, see §3.10);
  3. `await prepareAudioUnits` (an idempotent ensure);
  4. apply the **reset contract** to dirty instances (§3.3);
  5. (AUR-4) the warm pass;
  6. `renderCooperatively`;
  7. mark the used instances dirty and record the controller lanes they received.
- `offlineCompensationTargets` [R `:3710-3718`]: lease, then an effects-only prepare
  **into the pool**, then the plan. The instances are kept and **not** marked dirty, since
  a plan does not render.
- `tracksDidChangeBody` [R `:1357-1365`]: presence-only GC (§3.5).
- `auPrepareInFlight()` [R `:3773-3774`]: union of both ledgers (§3.4).
- `auPrepareStats()` [R `:3759-3761`]: an additive `offline` block (§3.8).

### 3.3 The reset contract, and what ⑤ implies for it

**CLEAN or DIRTY.** An instance is **clean** if it was just instantiated, or only served a
plan. It is **dirty** once any render has pulled it since its last reset. **A clean
instance gets no reset step at all**, so its first render makes exactly today's call
sequence (§3.10). At lease checkout, every dirty instance the coming render will use gets
the following, on the main actor, with no render in flight (the lease guarantees that):

- **R1, MIDI panic.** `HostedAUInstrument.reset()`: CC 123, CC 120, CC 121, bend centre, CC
  64 = 0 [R `HostedAUInstrument.swift:299-325`]. This is a **new call site**. Today it runs
  only on the pulling thread at a flush or a ring overflow [R
  `InstrumentSourceNode.swift:481-498`]. It is legal from the main actor because it touches
  only the captured `scheduleMIDI` block and preallocated bytes [R
  `HostedAUInstrument.swift:12-16`], and only while nothing else pulls the instance, which
  the lease guarantees. T4's negative control is what proves the events are consumed before
  the next render's audio.
- **R1b, controller neutralisation.** For every MIDI controller lane type the instance
  received in its **previous** render, schedule that type's `neutralDefault` [R
  `Model.swift:308-318`: bend 8192, pressure 0, CC 7 = 100, CC 10 = 64, CC 11 = 127, else 0].
  CC 121 does not reset CC 7 or CC 10 by convention (MIDI RP-015) [A]. The next render's
  chase prefix re-establishes only the lane types **its** clips carry [R
  `MIDISchedule.swift:118-135`]. Without R1b, a CC 7 lane in export 1 silently changes
  export 2's level.
- **R2, `AUAudioUnit.reset()`** (`AudioUnitReset`) on the main actor. The live release path
  already makes this call [R `AUHostRegistry.swift:516-517`]; for inserts, via
  `HostedAUEffect.reset()` [R `HostedAUEffect.swift:211-215`].
- **R3, a fixed flush.** Render **exactly K** silent quanta through the adapter, with no
  events, into preallocated scratch, and discard them. K = 8 × 512 frames (about 85 ms) is
  proposed [A]. Record the flush's peak as the instance's `resetLeakDb`. K is fixed rather
  than "until silent" so the flush adds no run-to-run variation of its own. The flush also
  consumes R1/R1b's scheduled MIDI before the real render starts. For Apple units, T4
  asserts the flush output is exactly zero. For a third-party plugin, `resetLeakDb` is a
  per-instance **measurement of whether its reset resets** (K3).
- **R4, timeline.** `hostSampleTime` is **not** rebased. This keeps the documented rule
  "never reset — resetting it makes some AUs drop state" [R
  `HostedAUInstrument.swift:59-62`; `HostedAUEffect.swift:44-46`]. Consequence: a reused
  instance's render starts at a non-zero sample time. T4 measures whether that matters for
  Apple units; if it does, the finding is recorded and this rule is revisited, never
  silently loosened.
- **R5, NOT in the contract: deallocate/reallocate.** It drops AUSampler's loaded bank (T6,
  measured) [R `AUHostRegistry.swift:1086-1090`]. For a third-party sampler it would likely
  re-trigger loading and defeat the purpose [A].
- **R6, patch state is not reset; it is re-keyed.** A `stateData` change is a new
  `PrepareKey`, hence a new instance. The contract never has to "restore" a patch.

**What the contract cannot guarantee**, and must never claim: loaded content and caches,
round-robin position, random seeds, streaming buffers, free-running LFO phase (hosted AUs
get no musical context [M-e]), or anything else internal. M29 §15.5's "there is no reliable
way to reset a third-party AU between renders" stands [R M29 §15.5]. `resetLeakDb` detects
the audible part of a broken reset. Nothing detects the inaudible part.

**What ⑤ implies for "reset".** ⑤ was measured on **fresh** instances, so for DecentSampler
"fresh" is **not** a deterministic reference. "Reset means equivalent to a fresh instance"
is therefore not a target that exists for this plugin. The contract's acceptance is
operational:
- (i) **byte-exact for Apple units**, where fresh *is* deterministic (0/96 000);
- (ii) **not worse than fresh-vs-fresh** for a third-party plugin, measured in the same
  session on the same program (G-SAX criterion b′).

### 3.4 Ownership, threads, actors

- **All pool state is `@MainActor`**, like the registry and the renderer. There are no
  locks and no new atomics.
- **The offline render thread is the main thread** (§2.6). Pooled instances are never
  reachable from the live IO thread, because the live graph's providers read only
  `auRegistry` [R `AudioEngine.swift:941-948`]. **The render-thread invariant is untouched.**
  No live render-path code changes, no allocation or lock or wait is added to any live
  callback, and the live registry still cannot set `rendersOffline` [R
  `AUHostRegistry.swift:309-316`].
- **The lease.** A FIFO lease with one holder, on the main actor. It is acquired by
  `renderOffline` and `offlineCompensationTargets` and released in `defer`. It is needed
  because the cooperative loop yields (§2.6): today two interleaved renders are isolated
  **by construction** [R `OfflineRenderer.swift:235-238`]; with a pool they are isolated
  **by the lease**, and that doc comment changes in the same edit. No offline render
  triggers another (`renderOffline` awaits only stretch renders, prepares and its own pull loop [R
  `AudioEngine.swift:3644-3708`]), so a single FIFO lease cannot deadlock [A: re-check
  whenever a caller is added]. Accepted cost: a long stems export delays a short
  `render.measureLoudness` issued during it.
- **Main-actor occupancy.** Reuse **removes** per-render instantiate + restore + allocate
  (compare 28.7 s vs 0.12 s for a GM reload under suite load [M]). R3 adds K quanta per
  dirty checkout, and AUR-4 adds one discarded pass on first use. Both are bounded, and both
  are counted in `engine.performanceStats` like any offline pull [R
  `AudioEngine.swift:3669-3671`].
- **The wedge ledger.** Union the pool registry's `prepareLedger.snapshot()` into
  `auPrepareInFlight()`. It is legal `nonisolated`: `offlineAUPool` and its `registry` are
  `let`s, and `prepareLedger` is a `nonisolated let` [R `AUHostRegistry.swift:121-129`],
  the existing pattern at `AudioEngine.swift:3768-3774`. Tag entries additively
  (`registry: "offline"`). This closes the pre-existing blind spot in §2.6: a Surge-XT-style
  wedge inside an offline prepare becomes visible to `engine.auPrepareStats` during the
  wedge.
- **Swift 6.** The protocol additions are synchronous `@MainActor` requirements with default
  implementations, so every existing conformer compiles unchanged (the W7-ME2 rule for
  `EngineProtocol.swift`).

### 3.5 Lifetime: GC, failures, memory, boundaries

- **GC is by presence only, never by key.** In `tracksDidChangeBody`, release a pooled slot
  whose track id is no longer a hosted-instrument track in the session, or whose effect id
  is no longer a hosted insert. **Never compare `PrepareKey`s there.** The live sync keys
  from the **model's** `stateData` [R `AudioEngine.swift:2713-2716`]; the pool's keys come
  from **live-captured** bytes [R `ProjectStore.swift:8189-8216`], and the two routinely
  differ [R `:8164-8170`]. Copying the live sync's "release on `needsPrepare`" pattern [R
  `AudioEngine.swift:2716-2719`] into the pool would release every pooled `.audioUnit`
  instance on every model edit, silently defeating reuse. T7 pins this.
- **A render never releases anything.** Renders pass **subsets**: stem passes [R
  `StemPlan.swift:273-315`]; the liveness probe strips effects [R
  `ProjectStore+TimbreLiveness.swift:121-126`]. GC authority is the session, never the
  render's track list.
- **Failures are not memoized in the pool.** The registry writes `attempted[id] = key`
  before the outcome [R `AUHostRegistry.swift:807`] and never retries an unchanged failed
  key [R `:521-530`]. That is deliberate and right for live ("no retry storms"). In a pool
  it would turn one transient 10 s timeout [R `:355`] into a track that bounces silent for
  the rest of the session. So the registry gains an init flag `retriesFailedPrepares`
  (default `false`; the pool passes `true`) that clears `attempted[id]` after a non-ready
  outcome. T8 pins both behaviours, including that **live is unchanged**.
- **Memory.** `request` holds nothing beyond one export. That is today's transient offline
  copy, held for a whole export instead of one pass. `session` needs: idle eviction (10 min
  proposed [A]); a drain on `DispatchSource.makeMemoryPressureSource` warnings; a drain at
  project boundaries (a `tracksDidChange` carrying a new session releases every absent id).
  Stats expose instance count and age.
- **Expected start-of-session re-key (not a defect).** Until the live prepare is ready,
  `tracksWithLiveAudioUnitState` keeps the model's bytes; once it is ready it returns live
  bytes [R `ProjectStore.swift:8184-8188`]. So the first two renders of a session may key
  differently and re-instantiate once.
- **State-byte stability (K8).** If a plugin's `fullStateForDocument` returns different bytes
  on two reads with no edit, `session` degrades to per-export re-instantiation for that
  plugin. That is today's behaviour, not a regression. Probe P-STATE (§7.3) measures it. A
  digest-normalised state push onto a live instance is **deferred** until the probe shows
  it is needed.

### 3.6 AUR-3: quiesced disposal

**Today.** Offline disposal is ARC-at-renderer-death, with no dealloc or reset (§2.4). Live
disposal is dealloc + reset, then an immediate ARC release (DLS: on the bank queue).

**Proposed, for the pool and the live registry alike.**
1. Remove from the table (the existing bookkeeping).
2. `deallocateRenderResources()` + `reset()` (the existing sequence [R
   `AUHostRegistry.swift:510-518`]).
3. Hold the adapter in a **graveyard** until at least two main-run-loop turns **and** at
   least 500 ms have passed [A: proposal], so the plugin's already-queued main-thread work
   runs against a live object.
4. Drop it. The DLS family keeps its `deinit` hand-off to `dlsBankQueue` [R
   `HostedAUInstrument.swift:105-119`]; the graveyard only delays when the hand-off happens.

**Where the last release runs (Swift 6).** A `deinit` runs wherever the last strong
reference is released, so the graveyard must never be the thing that moves it off the main
actor. The graveyard is a main-actor-isolated array, one per registry (pool and live alike).
The grace timer is a main-actor `Task` that captures only `[weak self]` and a generation
number, **never an adapter**, and it drops entries by removing them from that array. No
`Task.detached`, GCD block or other escaping closure may hold an adapter: any of them could
make its own release the last one, on an arbitrary thread. Once the renderer and graph have
let go (both are main-actor objects), the graveyard is the last holder. So the final
release of a `HostedAUInstrument` or `HostedAUEffect`, and its `deinit` with the DLS hand-off
[R `HostedAUInstrument.swift:105-119`], happen on the main actor as they do today. Holding
the reference longer on the main actor can only make a last release from another thread
less likely. That includes the render thread, where a free would break the RT invariant [A:
whether any live render-block capture can outlive its node today is not re-checked here; the
AUR-3 reviewer checks it]. T11 pins the main-thread release (§7.1).

**What it can and cannot fix.** Work queued **before** disposal and delivered within the
grace period stops being a use-after-free. Work posted **after** disposal by threads the
plugin failed to join is not helped by any grace period. Only never disposing (a pool with
`session`) or never mapping the plugin (M29) reaches that.

**The cost that pulls the other way.** The graveyard **raises peak concurrent instances**
(live + graveyard + the next export's new one). Crash 1's thread multiples are the only
instance-count evidence and point toward *more* instances being worse [R M29 §1.2, "do not
quote 3/2/1 as fact"]. E1 records **peak during drain**, not only steady state.

### 3.7 AUR-4 (warm pass) and AUR-5 (pace cap): conditional

**AUR-4, R-2 reframed onto the pooled instance.** Build it only if G-SAX shows ③ cold still
failing after AUR-1/AUR-2 (the M2 or M3 branch).
- On the **first lease of a new instance generation** (instantiated, or re-keyed), for a
  **third-party instrument** (manufacturer ≠ `appl`), render a **full discarded pass** over
  the same timeline and notes, then apply the reset contract, then render for real.
- This is M29 §15.5 shape (a): it has no termination question. A silent pre-roll cannot
  work, because lazy loads follow note-ons [R M29 §15.5].
- Apple units never get it. Their loads are awaited inside prepare (`.soundBank` [R
  `AUHostRegistry.swift:936-944`]), and the first-clip triage could not reproduce a drop
  across 17 conditions [R `FirstClipDropProbeTests.swift:116-121`].
- R-2 always *was* instance reuse at the smallest scope ("pre-roll, reset, render" on one
  instance), and the pool is what makes it cheap: under `session` it runs **once per
  instance generation**, not once per export.
- The result reports `warmPasses` and whether the head converged. The convergence reading
  is the first-non-silent index of each note in the head window, never byte identity [R M29
  §15.5(c)].
- Its known limit: a plugin whose loader is started by the state restore (not by note-ons)
  and needs more wall time than one discarded pass gives still drops. That branch needs
  AUR-5.

**AUR-5, a pace cap on the cooperative loop.** Build it only for diagnosis until evidence
says otherwise.
- An internal seam, `offlinePaceFactor k`, makes the loop sleep so that wall time is at
  least timeline time ÷ k. With k = 1 this is a "realtime bounce".
- As a **diagnostic** it discriminates M2 (render speed) for ③ and streaming timing for ⑤:
  if ⑤'s residual collapses at k ≤ 1, the cause is timing.
- As a **product option** it is what DAWs offer for plugins that misbehave offline. It costs
  wall time equal to the song's length, so it is **the user's decision**, raised only with
  evidence (§12, not asked now).

### 3.8 Observability and the wire (additive only)

- **`engine.setOfflineAUReuse {policy: "fresh" | "request" | "session"}`** returns
  `{policy, previous}`. MCP mirror: `engine_set_offline_au_reuse`. This is **+1 command**.
  Re-measure the count with `node scripts/gates/doc-count-drift.mjs` (256 at W7-WIRE2 per
  `docs/ARCHITECTURE.md:61`; it will have moved). It goes through whichever lane holds the
  wire token (`common.md`: "If yours needs a NEW wire command and you are not W7-WIRE, STOP
  and say so"). The tester's A/B needs it; so does the "every feature is agent-controllable"
  invariant.
- **`engine.auPrepareStats` gains an optional `offline` block**: policy, lease holder, pooled
  instruments and effects (the existing `TrackEntry`/`EffectEntry` shapes), prepare/release
  counters, graveyard size, and per-instance `resetLeakDb`. It is a **new sibling type** in
  `Model.swift` beside `EngineAUPrepareStats` [R `Model.swift:3926`]: a struct cannot hold an
  optional of itself. No new read verb.
- **Every render result** (mixdown, bounce, stems, bounce-in-place, measure, liveness) gains
  an optional `auInstances {policy, created, reused, resets, warmPasses, resetLeakDbMax}`. It
  is read at batch end through an additive protocol read with a default of nil. This is how
  the tester sees **which path ran for each file**; M29 §15.5 already asks that a pre-roll be
  observable.

### 3.9 The live graph

The pool never shares an instance with live, so "an AU cannot render live and offline at
once" is satisfied **by construction**, as it is today. Two things change in character under
`session`, not in kind:
- a live instance and an offline copy of the same plugin coexist **continuously** instead of
  only during a render (K7);
- a plugin that implemented `renderingOffline` as **process-global** state would bleed the
  flag into its live instance for the whole session instead of for one render (K6).

Both exposures exist today. Crash 3 shows live and offline instances rendering concurrently
[R M29 §1.1]. Neither blocks `request`, the shipping default.

### 3.10 Containment: why existing bytes do not move

1. Tests that construct `OfflineRenderer(...)` directly never reach the pool. That covers
   the R-1 gates [R `OfflineRenderReadinessTests.swift:198-220`], the first-clip gate [R
   `FirstClipDropProbeTests.swift:157`], and most engine render tests. The public
   convenience init keeps building its own registry.
2. Engine-path renders with **no hosted AU** never touch the pool; that includes every
   Σ-stems and bounce suite (M-f).
3. A **single-render request** under `request` uses a **clean** instance with no reset step.
   Its call sequence is identical to today's, so its bytes are identical.
4. Only multi-render requests (the stems siblings, for instance) and `session` exercise a
   dirty instance. T4 and T9 gate exactly those.

AUR-1 changes only which calls the **plan** makes. T2 pins its targets, and identical
targets give identical rendered bytes.

---

## 4. The two strongest alternatives, and why they lose

### A. Reuse the LIVE instance for offline renders

Its appeal: zero offline instantiations, zero extra memory, always warm (the user has been
playing it), and WYSIWYG state for free. It loses on three counts, any one of them enough:

1. **It regresses Leg R-1 for every plugin that honours it.** `renderingOffline` must be set
   **before** allocate [R `AUHostRegistry.swift:318-320`, citing `AUAudioUnit.h:1024-1035`]
   and must **never** be set on a live instance, because it invites the plugin to block the
   render thread [R `:288-297`]. Toggling it for a bounce needs a deallocate/reallocate,
   which drops AUSampler's loaded bank [R `:1086-1090`]. So live reuse means bouncing
   **without** the flag, and every honouring plugin would start dropping heads again.
   (AUSampler accepts the property [M R-1 agent 2026-08-20].)
2. **Exclusivity breaks a shipped promise.** The live IO thread pulls the instrument node
   even while the transport is stopped [R `InstrumentSourceNode.swift:508-510`]. An offline
   pull of the same AU needs a render-thread handoff: an atomic owner flag checked every
   quantum, with silence while offline owns it. So a bounce would silence the track live,
   which breaks "bouncing is safe whether or not playback is running" [R
   `AudioEngine.swift:3664-3667`].
3. **It disturbs the user's instrument.** The bounce would leave its voices, round-robin
   position and controller state in the instance the user is playing. The measured cause of
   ⑤ is not per-instance state (§5.3), so live reuse buys nothing for ⑤ in exchange.

What it would have bought, zero churn, `session` gets nearly all of, with none of 1–3.

### B. M29 out-of-process hosting as the fix for these three defects

- **③: it makes things harder.** The fix direction for a lazily-loading plugin is to let it
  **block** offline. An XPC render has a system deadline (`kAudioUnitErr_RenderTimeout`), so
  a blocking load becomes a timeout, which the adapter turns into exact silence: "the same
  dead head, arriving through a different door" [R M29 §15.6].
- **⑤: not addressed.**
- **④: the only design that contains the crash whatever its cause.** The helper dies, the
  host lives, and one plugin's unsaved knob moves are what is lost [R M29 §7.3]. That is why
  it is **sequenced after the evidence, not rejected**.
- **Cost:** weeks [A]. The render-thread invariant must be **amended** [R M29 §5]. Its
  enabling fact (G1: `isLoadedInProcess == false` for an AUv2 asked to load out of process)
  is **still unmeasured** [R M29 §2.5, §3.1]. It needs the user's word.

### Considered, and folded in rather than rejected

- **R-2 pre-roll on fresh instances** (M29 §15.5): it *is* instance reuse at the smallest
  scope, and it becomes AUR-4 on the pool, where it runs once per instance generation
  instead of once per export.
- **Realtime pacing:** kept as the AUR-5 diagnostic, and a possible user option later.
- **An eager offline copy** (instantiate the offline instance when the live one becomes
  ready, so even the first export is warm): the only thing that could meet ③'s cold
  criterion without a pre-roll. It is **deferred**, because it holds a second copy of every
  hosted instrument all session (GB-scale for large libraries [A]). Revisit only if AUR-4
  is too slow.

---

## 5. Per-defect verdicts

### 5.1 ③: the cold head drop on `render_stems` / `track_bounce_in_place`

**Mechanism candidates.** The first is what the code shows; the rest are [A].
- **In code [R]:** the failing verbs call `offlineCompensationTargets` first [R
  `ProjectStore+Render.swift:290`; `ProjectStore+Bounce.swift:107`]. That instantiates
  **every** hosted AU in the session in a throwaway renderer and disposes it mid-load (§2.4).
  The working verb does not.
- **M1:** the throwaway itself interferes with the real instance's load, through contention
  on a shared loader or cache, a teardown that cancels shared work, or anything similar.
- **M2 (a confound, newly flagged here):** the failing verbs render a **one-track subset**
  (the sax stem is `[sax]` plus key sources [R `StemPlan.swift:276-287`]), while the
  mixdown renders the **whole session**. A subset pulls faster, so less wall time passes
  per timeline second, and a loader that needs *W* seconds of wall time loses more timeline
  in the faster render. M2 predicts the observed path split with **no causal role for the
  throwaway at all**. Nobody has excluded it.
- **M3:** main-run-loop starvation. The plugin's load completion may need main-thread
  delivery (JUCE's message queue), and the render occupies the main thread between yields.

**What reuse does.** AUR-1 (and AUR-2 at request scope) removes the double instantiation,
**so it fixes ③ for stems and bounce if M1 holds.** Under M2 or M3, the **first** render of
a fresh instance still races whatever the verb. Reuse then fixes only later renders (under
`session`), and the cold criterion needs AUR-4 or AUR-5.

**What reuse cannot fix.** A plugin that ignores `renderingOffline` and loads on its own
threads, on its **first render after instantiation**, on any verb. That includes a
small-session mixdown under M2. That residue is exactly what M29 §15.5's Leg R-2 was for.
AUR-4 is R-2, moved onto the pool.

**Pre-registered predictions.** The G-SAX runs (§7.2) are each: one verb, a **fresh
process**, the **first render** of the session, with render count, DecentSampler version,
engine mode (RAM or disk) and `sudo purge` state all recorded.

| after AUR-1 | M1 predicts | M2 predicts |
|---|---|---|
| `track_bounce_in_place` cold | first sound at **9.869 s** (±1 quantum) | still drops |
| E0 on **today's** build: a copy of the project reduced to the sax track alone, cold `render_mixdown` | correct | **drops** |

`render_stems` is **not** discriminating. Its sax pass follows other passes, so the sax
instance gets extra wall time either way. Record it; do not adjudicate on it.

**Pass condition for closing ③** (M29 §15.5, unchanged). Criterion (a): run 1 lands at
**9.869 s cold** for **both** `render_stems` and `track_bounce_in_place`, with no warming
render ahead of it. It is single-shot per process: a second attempt passes for free and
must not be counted [R M29 §15.5]. Criterion (b′) must hold at the same time (§5.3).

**A free instrument, if the tester updates the plugin.** From 1.31.0 and 1.32.0 its log
records background work and "which preset was loaded and whether any sample failed to load"
[R-web]. That may show the loader's wall time directly [A: whether it carries timestamps is
unknown]. The 1.29.0 logs here are headers only [M-b].

### 5.2 ④: the freed-memory crash

**Two live hypotheses; neither is proven; they are not exclusive.**
- **H-ours** [R M29 §1.2, §11 F12]: our per-render instantiate/dispose churn races the
  plugin's deferred main-run-loop work. Supporting: all three tester crashes came during
  heavy offline rendering, and the faulting frame is a main-run-loop `source0` callout.
- **H-vendor** [R-web]: the plugin's own defects, fixed from 1.30.0 to 1.32.0. They include a
  "periodic update check [that] crashed almost every launch for anyone running an older
  build" (a periodic, main-thread-plausible, plugin-own event), "two [crashes] that could
  happen while a preset was still loading its samples", and a hang on removal. Supporting:
  the user's 2026-08-30 crash happened in a live Musical Typing session with no known offline
  render.
- **The overlap:** our churn **multiplies** the plugin's exposure to its own load-time and
  unload-time defects. Every render reloads the preset, and the throwaway disposes an
  instance mid-load. So even if H-vendor is right, reuse reduces how often the window opens.

**What weakens every reading.**
- The `.ips` files are gone [M-c].
- The 2026-08-30 crash's signature differs: `0x8` against garbage addresses, and seven plugin
  frames against four [memory; M29 §1].
- The installed plugin (1.29.0) is not the build that crashed (1.23.5), and predates every
  relevant vendor fix [M-a; R-web].
- A vendor note is a claim with no stack attached.

**What reuse does.**
- Exposure to our churn per stems export falls from at least 2H (up to 4H+) instantiations
  and disposals to **H** under `request`, and to **about 0** under `session` (§2.3).
- Bounce-in-place falls from H + h to H under `request`. The plan's effects-only prepare
  after AUR-1 removes the instrument part of that H.
- AUR-3 removes the "message queued before dispose" window.
- **None of this contains a crash that is the plugin's own.** Only M29 contains that.

**Evidence, not a pass condition** (nothing tester-runnable can prove a fix for an
intermittent crash):
1. **The upgrade** (U1, the user's action, right after the 1.29.0 baseline round of §7.2):
   if crashes stop on 1.33.2 with today's lifecycle, H-vendor gains and ④ stops being ours
   to fix.
2. **E1 thread census:** DecentSampler's per-instance threads (`WavePlayers`, `Sample Loading
   Thread`, `OnlineManager TaskRunner`) sampled after each of N offline renders under `fresh`
   and under the pool, recording **peak during drain**. Counts that grow with N under `fresh`
   are the leak H-ours needs. **Flat counts under `fresh` weaken H-ours; they do not confirm
   H-vendor.**
3. **Crash rate A/B** over N renders per arm (1.29.0 vs 1.33.2, crossed with `fresh` vs
   pool). The 1.29.0 arm can only be collected before U1. **A non-reproduction attributes nothing** [R M29 §9.1].

### 5.3 ⑤: two warm renders do not null (−3.07 dB)

**Reuse does not fix it, by any mechanism that can be named.**
- ⑤ was measured on **fresh** instances, so per-instance state was already fresh.
- The residual must come from process-global plugin state, timing-dependent asynchronous work
  (loading or disk streaming against a faster-than-realtime pull), or deliberate randomness
  [A].
- The vendor's notes make both of the last two concrete [R-web]: DecentSampler has a **RAM vs
  disk-streaming** engine setting (1.32.0), a history of disk-streaming glitches ("go silent,
  crash, or produce bursts of noise", 1.17.1), and presets with **random round robins**
  (1.33.0).
- The −3.07 dB **peak** residual is far larger than DSP noise. It fits different sample
  choices or timing shifts [A].

**Reuse can make it worse.** Round-robin position advances per note and lives in the
instance (1.31.0 fixed it "not advancing on legato samples" [R-web]). With a sequential
round-robin preset, fresh instances all start at the same position and reused ones do not.
So reuse could **introduce** non-determinism that fresh instances do not have [A]. The
reset contract cannot reach it (§3.3).

**Pass condition for reuse, (b′) "not worse":** a reuse-vs-reuse warm residual **≤** the
fresh-vs-fresh warm residual, both measured in the same session, on the same program, with
the same plugin version. The −3.07 dB floor is the tester's fresh-vs-fresh reading on an
unrecorded build, presumably 1.23.5 [A, §1.1]; it must be re-measured on the version under
test, never carried over.

**What would actually fix ⑤** (none of it is reuse):
- **E2, zero code:** switch the preset's engine to **RAM mode** and re-run the warm null. If
  the residual collapses, disk-streaming timing is the cause, and the product answer is
  pacing (AUR-5) or advice to use RAM mode.
- Check the preset for random round robins or randomising modulators. If they are present,
  ⑤ is **by design**. It then becomes a documented property of that preset, and every
  bounce-vs-bounce gate needs a plugin-specific tolerance.
- **AUR-5** at k ≤ 1: if the residual collapses, the cause is timing.

---

## 6. Risks and failure modes

| # | risk | detection | mitigation |
|---|---|---|---|
| K1 | **State carries between renders.** This is the inverse of ⑤: round-robin position, voices, tails, controller state and LFO phase survive into the next render. | T4 byte gate (Apple units); G-SAX (b′); `resetLeakDb` | Reset contract R1–R3; dirty-only resets; `request` as the default; the `fresh` kill switch per session |
| K2 | **Memory.** Offline copies held all session (GB-scale libraries under `session`) | pool stats; memory-pressure source | `request` default; idle eviction; pressure drain; boundary drain |
| K3 | **A plugin whose reset does not reset** (ignores `AudioUnitReset` or CC 120) | `resetLeakDb` per instance, a real measurement | Report it; `fresh` for that session; never silently loosen T4 |
| K4 | **The AU hosting wedge** (Surge XT, minutes on the main actor) | the wedge ledger, now including offline prepares (§3.4, T10) | The pool **removes** instantiations; `DeadlineRace` is unchanged; failures are not memoized (T8), so one timeout does not silence a track for the session |
| K5 | **Lease starvation or deadlock** | T6; watchdog | FIFO; `defer` release; no nested renders exist today [R `AudioEngine.swift:3644-3708`]; a new caller that renders inside a render must be reviewed |
| K6 | **A plugin that implements `renderingOffline` as process-global state** bleeds the flag into its live instance | live render overruns rise while a pooled copy exists (`engine.performanceStats`) | `request` default (bounded to an export, as today for a render); `fresh` |
| K7 | **Continuous coexistence** of a live and an offline instance of one plugin (`session`), if ④ turns out to depend on instance count | E1 (peak instance and thread counts) | Flip to `session` only on E1 evidence |
| K8 | **Unstable state bytes** make `session` re-instantiate every export | the `created` counter in `auInstances` | Accept it (no regression); P-STATE decides whether a normalised state push is worth building |
| K9 | **The timeline is not rebased** (R4), so a reused render starts at a non-zero sample time | T4 (Apple) | Keep the documented "never reset" rule; record, do not loosen |
| K10 | **Doc and contract drift.** Five comments state "fresh AU instances per render" as fact: `EngineProtocol.swift:932-935`; `AudioEngine.swift:3664-3667` and `:3757-3758`; `OfflineRenderer.swift:75-99` and `:151-158`; `AUHostRegistry.swift:294-297` (the R-1 safety argument, which really rests on separateness); `OfflineRenderer.swift:235-238` (isolation by construction). | review | Edit all of them in the same change as AUR-2 |
| K11 | **GC by key** (the live-sync pattern copied) releases pooled instances on every model edit, silently | T7 | GC by presence only (§3.5) |
| K12 | **The quiesce graveyard** raises peak concurrent instances | E1 peak during drain | Short grace; count it in stats |
| K13 | **The tester's cold gate passes for free** on a second attempt | render count recorded per run | Single-shot per fresh process [R M29 §15.5] |
| K14 | **Future RPN 0 (M29 Leg B)**: CC 121 in R1 clears registered-parameter state, so a set-once bend range would be lost at the first reused render | a test on the Leg B change | Leg B must re-send RPN after every reset, including R1 [R M29 §16]. Not shipped yet [M-g]. |

---

## 7. Test plan

### 7.1 Headless: no third-party plugin

**Constraints.**
- `@MainActor` suites are capped at 394, and 393 are in use [R `$S/w7/common.md`;
  `MainActorOccupancySiteTests.swift:1451`]. Every new main-actor test is therefore an
  **extension** of an existing suite, in its own new file: `AUHostingTests` [R
  `AUHostingTests.swift:12-14`], `SoundBankHostingTests` [R `SoundBankHostingTests.swift:15-17`],
  `StemNullTests` [R `StemNullTests.swift:16-17`]. That is the `FirstClipDropProbeTests`
  precedent. Only nonisolated logic (such as a batch-depth counter) may get a new suite.
- Run with `./scripts/test.sh --filter …`, never bare `swift test`.
- **Tools already in the tree:**
  - the `instantiator` seam [R `AUHostRegistry.swift:258-263`];
  - the R-1 stub pattern, an `AUAudioUnit` subclass that wears AUSampler's identity so the
    component manager matches it [R `OfflineRenderReadinessTests.swift:76-124`, `:166-175`];
  - the GM sound bank [R `:528-572`];
  - AUDelay [R `:177-181`];
  - latency-bearing Apple inserts (`lmtr`, `dcmp`, `mcmp`, `nutp`) [R
    `PDCHostedAURenderTests.swift:44-55`];
  - a store over a real `AudioEngine` [R `StemNullTests.swift:28-33`].

**Every test states its negative control. A test whose control cannot go red proves
nothing.**

| test | item | asserts | negative control (must go RED) |
|---|---|---|---|
| **T1** | AUR-1 | Through `AudioEngine.offlineCompensationTargets`, a session with a stub hosted instrument and an AUDelay insert instantiates **0** instruments and ≥ 1 effect. | Legacy plan path (instruments prepared): 1 instrument instantiation. |
| **T2** | AUR-1 | Plan **parity**: targets identical to the legacy plan for a session with a GM instrument track, a latent Apple insert (AUPeakLimiter `lmtr`, from `latentCandidates` [R
`PDCHostedAURenderTests.swift:66-74`]; assert its reported latency > 0 first, the anti-vacuity
step) on another track, a sidechain key source, and a bus. | Skip the **effect** prepare: targets differ. This proves the gate can see hosted-insert latency at all. |
| **T3** | AUR-2 | `renderStems` (several passes, `includeMixdown`, `includeMasteredMixdown`) and `bounceTrackInPlace`, through the store: each hosted slot is instantiated **once per request** under `request`, and a second export under `session` instantiates **0**. | `fresh`: today's count (≥ 2H). |
| **T4** | AUR-2 | **The load-bearing leg.** GM sax (program 66) with an AUDelay insert; a note released just before the render's end, so render A **ends with a sounding tail**. Render B on the **reused** instances equals render A and equals a `fresh` render **byte for byte**. R3's flush output is exactly 0. Repeat with `.audioUnit` AUSampler carrying restored `stateData` (the tester's shape; capture recipe at `FirstClipDropProbeTests.swift:422-451`). | Disable R1–R3 through a seam: B's head carries A's tail. **Without this control the reset contract is unproven.** |
| **T5** | AUR-2 | Render A has a CC 7 lane (value 20); render B has none. B equals `fresh`. | Skip R1b: B is quieter. |
| **T6** | AUR-2 | Two concurrent cooperative renders on one hosted track: a stub records a lease generation per pull, and the two never interleave. | Lease disabled: interleaving detected. |
| **T7** | AUR-2 | GC by presence: stem-pass subsets and a liveness probe with its effects stripped release nothing. A `tracksDidChange` carrying the **model's stale** `stateData` for a pooled `.audioUnit` track leaves its instantiation count at **1**. Removing the track releases it (+1 release). | Plant key-comparing GC: the count reaches 2. |
| **T8** | AUR-2 | A stub instantiator that fails once, then succeeds: the pool's second render **sounds**. The **live** registry still does not retry an unchanged failed key. | Pool with memoisation: the second render is silent. |
| **T9** | AUR-2 | **Σ stems ≡ mixdown, null ≤ 1e-4, with hosted AUs**, the first time this invariant is checked with one (M-f): a GM instrument track plus a track carrying an AUDelay insert, under `request`. | Reset disabled, with a program ending in a sustained note: residual > 1e-4. |
| **T10** | AUR-2 | A stub instantiator that never returns, inside an **offline** prepare: `engine.auPrepareInFlight()` lists it (`registry: "offline"`). | Today's path (`fresh`): not listed. This documents the pre-existing blind spot. |
| **T11** | AUR-3 | A "hostile" stub AU whose allocate and state-set post deferred work to the main run loop. The work looks the instance up **by id** in a global live-instance table (a detector, never a real use-after-free) and counts **stale deliveries**. The count is 0 under quiesce. It also asserts that the stub AU's own `deinit` runs on the main thread, i.e. that the adapter's last release happened there. | Immediate dispose: > 0. Releasing a graveyard entry from a detached task through a test seam: the stub's `deinit` runs off the main thread. |
| **T12** | AUR-4 | A stub that **ignores** the offline flag and withholds output for its first N quanta **over its whole lifetime**. A fresh first render has a silent head (the control reproduces the defect's shape); the pool's second render sounds from frame 0; a first render with a warm pass sounds; an Apple unit never gets a warm pass. | Warm pass disabled: the first render's head is silent. |
| **T13** | AUR-5 | Wall time ≥ timeline ÷ k; Apple-unit bytes identical at any k. | k ignored: wall time below the bound. |
| **T14** | AUR-2w | Control tests for `engine.setOfflineAUReuse` (rejects unknown keys and unknown policies); the MCP test; `node scripts/gates/doc-count-drift.mjs` exits 0 at +1. | An unknown policy string must be refused, not defaulted. |

The R-1 wiring test `productionRegistriesCarryTheRightFlag` [R
`OfflineRenderReadinessTests.swift:304-305`] gains an arm: the pool's registry renders
offline; the live one still does not.

### 7.2 G-SAX: the one gate that needs the tester's plugin and 46-zone preset

Run by the tester on a bundle rebuilt after each item. The swap of `dist/DAWPro.app`
happens on the user's word, per standing practice.

- **Matrix:** verbs {`render_mixdown`, `render_stems`, `track_bounce_in_place`} × policies
  {`fresh`, `request`, and later `session`}.
- **Cold:** a fresh process, the first render of the session. **Warm:** renders 2–5 in the
  same process.
- **Recorded every time:** the first-non-silent onset against 9.868 s; the process render
  count; DecentSampler version; engine mode (RAM or disk streaming); whether `sudo purge`
  ran; the result's `auInstances` block.
- **Same-build rule.** Every before-and-after comparison, including pass (a)'s "today drops
  cold, the item does not", runs on **one** DecentSampler build, recorded in each run's
  output. The 2026-08-20 figures (31.974 s cold, −3.07 dB) come from an unrecorded build,
  presumably 1.23.5 [A, §1.1]. They motivate this gate; they are not its baseline. The first
  matrix is therefore a **`fresh` baseline on today's build with the installed 1.29.0**,
  before U1 (§7.3). If ③ does not reproduce there, AUR-1's effect on ③ cannot be measured
  with this plugin, and that is reported as such, never booked as a pass.
- **Pass (a):** cold `render_stems` **and** cold `track_bounce_in_place` land at **9.869 s**.
- **Pass (b′):** the reuse-vs-reuse warm residual is ≤ the fresh-vs-fresh warm residual,
  same session, same version.
- **The predictions of §5.1 are read off this matrix. Nothing is concluded from a second
  cold attempt in one process.**

### 7.3 Zero-code probes (AUR-0), runnable before any code

| id | who | what | answers |
|---|---|---|---|
| **U1** | **the user**, after the 1.29.0 baseline round (E0, E2, and G-SAX's `fresh` column) | Update DecentSampler on this Mac to 1.33.2. It lives in `/Library/…/Components`, which needs admin rights; agents never install plugins. | Every later ④ measurement is then about a current build. H-vendor gets tested for free. Repeating the baseline round on 1.33.2 shows whether the update alone changes ③ or ⑤. |
| **E0** | tester, today's build | Reduce a copy of the sax project to the sax track alone. In a fresh process, run cold `render_mixdown`; in another fresh process, cold `track_bounce_in_place`; record the onsets. | M1 vs M2 for ③ before a line of code (§5.1) |
| **E1** | qa-test-engineer on **staging 17695 only**, under `staging.lock`, killed pidfile-exact; **needs Q2** | A probe that loads DecentSampler on a hosted track, then samples the app's thread names (`ps -M -p <pid>` or equivalent) after each of 20 offline renders and **during** drains. Report `WavePlayers`, `Sample Loading Thread` and `OnlineManager TaskRunner` counts per render, plus the peak. | H-ours needs counts that grow with renders; flat counts weaken it. |
| **E2** | tester | Warm-vs-warm null in **RAM mode** vs disk-streaming mode, and report the preset's round-robin/random settings. | Streaming timing vs by-design randomness for ⑤ |
| **P-STATE** | the AUR-2 implementer, with Q2 | Two `fullStateForDocument` reads of one DecentSampler instance with no edit in between: are the bytes identical? | Whether `session` can reuse DecentSampler across exports at all (K8) |

---

## 8. Staged delivery

| item | what | route (model) | weight [A] | depends on | gate | files |
|---|---|---|---|---|---|---|
| **AUR-0** | E0, E2 and G-SAX's `fresh` baseline on the installed 1.29.0 now; then U1 and the same round on 1.33.2; E1 and P-STATE after Q2. Every run records the plugin version. | user; tester via orchestrator; qa-test-engineer (sonnet) | U1 5 min; E0 and E2 ~30 min each; E1 ~2 h | Q1, Q2 | results recorded | none, except E1's probe: a NEW file under `scripts/probes/` |
| **AUR-1** | the plan prepares hosted inserts only (§3.1) | audio-dsp-engineer (opus) | **0.5–1 d** | W7-ME2 releases the ME token | T1, T2; full suite green; 0 new warnings | `OfflineRenderer.swift`, `AudioEngine.swift`, `EngineProtocol.swift` (doc), new test extension file |
| **AUR-2** | the offline pool (§3.2–§3.5, §3.8 engine side), default `request` | audio-dsp-engineer (opus) builds; daw-architect (opus) reviews RT and actor use | **3–4 d** | AUR-1 | T3–T10; full suite | NEW `AudioUnits/OfflineAUPool.swift`; `AUHostRegistry.swift` (`retriesFailedPrepares`); `OfflineRenderer.swift` (internal init); `AudioEngine.swift`; `EngineProtocol.swift` (2 additive requirements, doc edits); `ProjectStore+Render.swift`, `+Bounce.swift`, `+TimbreLiveness.swift`, and `ProjectStore.swift` (batch wraps; shared-file rule); `Model.swift` (stats and `auInstances` types; **SD2 holds `Model.swift` now**, so sequence after it or hand the orchestrator a patch) |
| **AUR-2w** | the wire verb, MCP tool, and additive payload fields (§3.8) | mcp-integration-engineer (sonnet), holding the wire token | **0.5–1 d** | AUR-2 | T14; count gate | `Commands.swift`, `mcp-server/src/server.ts`, tests, the docs the count gate scores |
| **AUR-3** | quiesced disposal, pool and live (§3.6) | audio-dsp-engineer (opus) | **~1 d** | AUR-2 for the pool half; the live half is independent | T11 | `AUHostRegistry.swift` |
| **AUR-4** | the warm pass (§3.7) | audio-dsp-engineer (opus) | ~2 d | **only if** G-SAX (a) fails after AUR-1/AUR-2 | T12; G-SAX (a) | `OfflineAUPool.swift`, `AudioEngine.swift` |
| **AUR-5** | the pace-cap seam (diagnostic) | audio-dsp-engineer (opus) | 0.5–1 d | **only if** E0/E2 are inconclusive | T13 | `OfflineRenderer.swift` |
| **AUR-6** | flip the default to `session` | orchestrator | 0.25 d | G-SAX (b′), E1, eviction shipped | G-SAX | `AudioEngine.swift` |
| **AUR-7** | docs: the ARCHITECTURE entry (§11), ROADMAP ticks, CHANGELOG, M29 §3.1 G0 marked costed | docs-scribe (haiku) | 0.25 d per item | each item | none | docs only |

**Every item's gate also includes** (not repeated per row): the full suite green through
`./scripts/test.sh`; 0 new warnings in `Sources/` (read from the build log); and **0 new
`@MainActor` suites**, so the `<= 394` cap [R `MainActorOccupancySiteTests.swift:1451`] does
not move (§7.1). If a new main-actor suite is ever unavoidable, the cap is raised only with a
measured occupancy figure in the same change, never an asserted one; the project has
already recorded three unbacked bumps [R memory index, M39 bullet]. AUR-2w's count gate is
`node scripts/gates/doc-count-drift.mjs` exiting 0 with the wire and MCP counts each **+1**
over the baselines it prints on the day (256 wire commands at W7-WIRE2 [R
`docs/ARCHITECTURE.md:61`]; both move as other lanes land).

**Totals [A].** The unconditional core (AUR-1, AUR-2, AUR-2w, AUR-3) is **5–7 engineering
days**. With AUR-4, AUR-5 and AUR-6 it is **8–11 days**. Tester time is about 2 h per G-SAX
round.

**Sequencing.**
- AUR-0 needs no tree edit and starts now.
- AUR-1 and AUR-2 touch the files W7-ME2 holds, so they start after ME2 closes and re-resolve
  every cite by symbol.
- AUR-2w goes through the wire token.
- AUR-3's live half touches only `AUHostRegistry.swift` (no lane holds it in `common.md`;
  the orchestrator assigns it).
- G-SAX runs after AUR-1 (the M1/M2 split) and again after AUR-2 (b′).

**Full Xcode, entitlements, AUv3, signing: none, for any item.** Everything is SPM plus Apple
units already hosted headless in this suite. The G-SAX runs use a bundle from
`scripts/bundle.sh`; that is a bundle requirement, not a full-Xcode one, and the swap needs
the user's word by standing practice. **A user-facing "realtime bounce" option (AUR-5 as a
product) would need the user's decision**, because it makes a bounce last as long as the
song.

---

## 9. Against M29 out-of-process hosting

| | reuse (this design) | M29 out-of-process |
|---|---|---|
| ③ | Fixes stems and bounce under M1 (AUR-1 alone). Under M2/M3 it needs AUR-4 or AUR-5. | Does not fix it. **Harder:** the render deadline fights a blocking offline load [R M29 §15.6]. |
| ④ | Cuts our churn from ≥ 2H to H (`request`) or about 0 (`session`) per export; AUR-3 closes the queued-before-dispose window. **Contains nothing.** | **Contains the crash whatever its cause**: the helper dies and the app lives [R M29 §7.3]. Its one decisive advantage. |
| ⑤ | Not fixed. Must be shown **not worse** (b′). | Not addressed. |
| RT invariant | Untouched. No live render-path change. | Amended: the render thread waits on another process [R M29 §5]. |
| Unknowns that gate it | Whether M1 or M2 holds (E0, G-SAX) | G1: whether an AUv2 renders out of process at all is **unmeasured** [R M29 §2.5] |
| Reversibility | Per-session `fresh` kill switch | A per-component default flip |
| Cost [A] | 5–7 d core; 8–11 d all | weeks (Leg −1 through Leg 6, ~10–15 d, plus an unbounded Leg 7) |
| User's word | only for the three questions in §12 | required for the milestone |
| Full Xcode, entitlements, signing | None for any item (§8) | None for Legs 0–6: `.loadOutOfProcess` uses Apple's own helper and asks nothing of an unsandboxed host. Leg 7 (the plugin UI across the boundary) needs an app bundle, which is not a full-Xcode requirement [R M29 §12]. Xcode 26.6 is installed anyway [M me 2026-09-27, `xcodebuild -version`: 26.6, 17F113]. **Neither design is gated on tooling;** M29's cost is its legs. |

**Recommendation.** Do AUR-0 and AUR-1 now, then AUR-2 and AUR-3. Decide on M29 when
three things are in: U1's upgrade result, E1's thread census, and whether crashes recur on
1.33.2 under `request`. If ④ recurs on a current plugin build with our churn removed, H-ours
is weakened and **containment is the only remaining answer: M29**. The two designs are
compatible: M29 §15.6 already names "out-of-process live, in-process offline" as its
fallback, and the offline pool is that in-process offline half.

---

## 10. Proposed ROADMAP items (text for the orchestrator; NOT applied, because this lane writes one file)

```
- [x] (m29-g0) Cost AU-instance reuse across offline renders (M29 §3.1 G0). DONE 2026-09-27 as design:
      docs/design/2026-09-27-au-instance-reuse.md. Verdicts: ③ likely fixed by AUR-1 if the throwaway is
      causal (M1), with a render-speed confound (M2) unexcluded; ④ exposure reduced, not contained; ⑤ not
      fixed by reuse (measured on fresh instances).
- [ ] (m29-aur-0) Zero-code probes, in order: a baseline round on the installed 1.29.0 (E0 single-track
      cold mixdown vs bounce-in-place; E2 RAM vs disk-streaming null, preset RR/random; G-SAX fresh
      column); then U1 (user updates DecentSampler to 1.33.2) and the same round again; E1 (thread
      census on staging, needs the user's OK) and P-STATE. Every run records the plugin version.
      Route: user / tester / qa-test-engineer.
- [ ] (m29-aur-1) The PDC plan prepares hosted INSERTS only; stems + bounce-in-place stop instantiating
      every hosted instrument for a plan that never reads its latency. Route: audio-dsp-engineer. Gate:
      T1, T2. After W7-ME2.
- [ ] (m29-aur-2) Engine-owned offline AU pool, policies fresh/request/session (default request), FIFO
      lease, presence-only GC, failures not memoized, reset contract R1-R3, offline ledger in
      auPrepareInFlight. Route: audio-dsp-engineer + daw-architect review. Gate: T3-T10.
- [ ] (m29-aur-2w) engine.setOfflineAUReuse + engine_set_offline_au_reuse; additive `offline` stats and
      per-render `auInstances`. Route: mcp-integration-engineer (wire token). Gate: T14, count gate.
- [ ] (m29-aur-3) Quiesced AU disposal (graveyard + grace), pool and live registry. Gate: T11.
- [ ] (m29-aur-4) CONDITIONAL on G-SAX (a) failing after aur-1/2: warm pass on the pooled instance.
- [ ] (m29-aur-5) CONDITIONAL: pace-cap diagnostic seam (offlinePaceFactor).
- [ ] (m29-aur-6) CONDITIONAL on G-SAX (b') + E1: default request -> session.
```

---

## 11. `docs/ARCHITECTURE.md` "Key future decisions": entry DRAFTED, NOT APPLIED

The brief confines this lane to one new file, so the entry is here for whoever applies it,
when the orchestrator ratifies AUR-1 and AUR-2:

> - **Offline AU instances: REUSED per export through an engine-owned pool, never the live
>   instance (W7-AUR, 2026-09-27; design `docs/design/2026-09-27-au-instance-reuse.md`).**
>   Until now every offline render built fresh AU instances, and `render.stems` and
>   `track.bounceInPlace` first built a whole throwaway set for a PDC plan. **That plan reads
>   only insert-effect latency** (`PlaybackGraph` PDC input), so its hosted instruments were
>   instantiated, state-restored and disposed mid-load for nothing. That throwaway is the one
>   code difference between the verbs that dropped a hosted sampler's opening cold and the
>   verb that did not. The design: (1) the plan prepares hosted inserts only; (2) an
>   `OfflineAUPool` holds one `AUHostRegistry(rendersOffline: true)` for the engine, with
>   policies `fresh` (the old path, kept as the A/B control), `request` (default: one set per
>   export) and `session`; (3) a FIFO lease replaces "isolated by construction"; (4) GC is by
>   track and effect **presence**, never by key, because pool keys are live-captured bytes and
>   live keys are model bytes; (5) failures are not memoized in the pool; (6) dirty instances
>   get an explicit reset (MIDI panic, controller neutralisation, `AudioUnitReset`, and a fixed
>   silent flush whose peak is recorded as `resetLeakDb`). The contract is byte-exact on Apple
>   units and "no worse than fresh-vs-fresh" on third-party plugins, because fresh instances
>   of DecentSampler were measured non-deterministic (−3.07 dB). **Leg R-1's safety always
>   came from the offline registry being SEPARATE, not fresh**, and the pool keeps it
>   separate. The render-thread invariant is untouched. **Not settled here:** whether the
>   default moves to `session` (memory against warm repeat bounces; gated on the tester's
>   (b′) null and a thread census), and M29 out-of-process hosting, which remains the only
>   design that *contains* the plugin crash whatever its cause.

---

## 12. Questions for the user (each has a default; nothing else here needs their word)

1. **Update DecentSampler to the newest version (1.33.2) on this Mac?** The copy installed
   now (1.29.0) is older than the vendor's fixes for crashes during sample loading and for a
   crash in its own update check. It lives in the system plug-in folder, which needs your
   admin password, so we will not do it for you. **Default: yes, after one baseline round on
   the current version** (about two hours of the tester's time; nothing for you to do).
   That round shows whether the update by itself fixes the silent opening in exported stems,
   so a fix the vendor shipped is not mistaken for ours. If you would rather update straight
   away, do: each before-and-after test of our own change runs on one plugin version either
   way, and every run records which one.
2. **May one of our agents load DecentSampler in the separate test copy of DAW Pro (never
   your own running app) to count its background threads over about 20 bounces?** Nothing
   is installed or changed; the test copy is closed afterwards. **Default: yes, test copy
   only.**
3. **Hold the out-of-process plug-in project (M29, several weeks) until this cheaper fix is
   measured?** **Default: yes, hold.** Revisit when the crash evidence above is in.

---

## 13. What I could not determine without measurement

1. Whether the throwaway causes ③ (M1), or render speed does (M2), or main-thread delivery
   does (M3). E0 and G-SAX decide it.
2. What retains warmth across fresh instances within one process (M29 §15.1 10a): the OS
   file cache, a plugin-global cache, or something else. Reuse does not need the answer;
   AUR-4 might.
3. Whether DecentSampler honours `AudioUnitReset` or CC 120/121 (K3). `resetLeakDb` will
   report the audible part.
4. Whether DecentSampler's `fullStateForDocument` bytes are stable across reads (P-STATE).
5. Whether ④ is H-ours, H-vendor, both, or neither. The `.ips` files are gone [M-c]; the
   installed build is not the crashing one [M-a].
6. Whether Apple units render byte-identically when reused with a continuing sample
   timeline (R4). T4 measures it.
7. Whether the 1.31.0 and 1.32.0 load-time fixes apply to the AU format on macOS. The notes
   do not say [R-web].
8. Every cost figure in this document.

---

## 14. Sources

- Source files, all read 2026-09-27 and re-verified at 2026-09-27 10:00 PDT against the versions in §14.1: `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift`,
  `Sources/DAWEngine/AudioUnits/HostedAUInstrument.swift`,
  `Sources/DAWEngine/Effects/HostedAUEffect.swift`, `Sources/DAWEngine/OfflineRenderer.swift`,
  `Sources/DAWEngine/AudioEngine.swift` (`:19-32`, `:941-948`, `:1340-1365`, `:2686-2840`,
  `:3541-3775`), `Sources/DAWEngine/PlaybackGraph.swift` (`:1800-1842`, `:2884-2894`),
  `Sources/DAWEngine/InstrumentSourceNode.swift` (`:455-512`),
  `Sources/DAWCore/ProjectStore+Render.swift`, `Sources/DAWCore/ProjectStore+Bounce.swift`,
  `Sources/DAWCore/ProjectStore.swift` (`:500-520`, `:7700-7757`, `:7984-8004`, `:8154-8216`,
  `:8602-8629`), `Sources/DAWCore/ProjectStore+TimbreLiveness.swift`,
  `Sources/DAWCore/StemPlan.swift` (`:255-315`), `Sources/DAWCore/EngineProtocol.swift`
  (`:689-690`, `:900-1027`, `:1731`, `:2198`, `:2244-2262`), `Sources/DAWCore/Model.swift` (`:300-330`, `:3926`),
  `Sources/DAWEngine/MIDISchedule.swift` (`:118-135`).
- Tests: `OfflineRenderReadinessTests.swift`, `FirstClipDropProbeTests.swift`,
  `StemNullTests.swift`, `PDCHostedAURenderTests.swift`, `AutomationFXParamTests.swift`
  (`:100-130`: automation lanes on `.audioUnit` inserts are inert, so automation cannot leak
  hosted-parameter state between renders), `MainActorOccupancySiteTests.swift` (`:1451`).
- Design and memory: `docs/research/design-m29-oop-au-hosting.md` (§1, §2, §3.1, §4, §5, §7,
  §9–§13, §15); `~/.claude/projects/-Users-dsemenov-Views-daw-pro/memory/daw-pro-sax-defects.md`;
  `.../memory/daw-pro-au-hosting-wedge.md`; `$S/w7/common.md`.
- Vendor: https://store.decentsamples.com/downloads/decent-sampler/versions (raw copy at
  `$S/w7/AUR/ds-versions.html`, text at `$S/w7/AUR/ds-versions.txt`).

### 14.1 The file versions the line numbers refer to

Measured at 2026-09-27 10:00 PDT [M me], immediately after the citation check passed. Re-check a file with `wc -l <file>` and `git hash-object <file>`; a mismatch means the file changed after this document was verified, so re-resolve its citations by symbol.

| file | lines | `git hash-object` (first 12) | modified |
|---|---|---|---|
| `Sources/DAWCore/BreathContour.swift` | 931 | `b1bbff0d3986` | 09-20 11:32 |
| `Sources/DAWCore/EngineProtocol.swift` | 2284 | `1e204786ba6a` | 09-27 09:51 |
| `Sources/DAWCore/Model.swift` | 4121 | `c35ec57013d3` | 09-27 07:03 |
| `Sources/DAWCore/ProjectStore+Bounce.swift` | 167 | `11d5bdd44736` | 09-27 09:51 |
| `Sources/DAWCore/ProjectStore+ClipFix.swift` | 472 | `c8c7db4ed56f` | 09-27 09:59 |
| `Sources/DAWCore/ProjectStore+ClipVoiceConversion.swift` | 477 | `039d94259ead` | 09-20 11:32 |
| `Sources/DAWCore/ProjectStore+Render.swift` | 486 | `3455282b294a` | 09-27 09:30 |
| `Sources/DAWCore/ProjectStore+TimbreLiveness.swift` | 192 | `cca38c91f557` | 09-20 18:28 |
| `Sources/DAWCore/ProjectStore.swift` | 9232 | `fceb7ceb9a86` | 09-27 09:30 |
| `Sources/DAWCore/RenderBlockSize.swift` | 102 | `480f92715d90` | 09-20 11:32 |
| `Sources/DAWCore/StemPlan.swift` | 385 | `f1bf9b92b133` | 09-20 11:32 |
| `Sources/DAWEngine/AudioEngine.swift` | 6418 | `11e22bf2a3bd` | 09-27 09:30 |
| `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift` | 1147 | `f74a9644e8e4` | 09-20 18:31 |
| `Sources/DAWEngine/AudioUnits/HostedAUInstrument.swift` | 326 | `3c35d9fcb526` | 09-20 11:32 |
| `Sources/DAWEngine/Effects/HostedAUEffect.swift` | 216 | `be38e9eb77e4` | 09-20 11:32 |
| `Sources/DAWEngine/InstrumentSourceNode.swift` | 1050 | `b67453fdf88a` | 09-20 11:32 |
| `Sources/DAWEngine/MIDISchedule.swift` | 504 | `965ee47c10d2` | 09-20 11:32 |
| `Sources/DAWEngine/OfflineRenderer.swift` | 704 | `1a5971671f4c` | 09-27 09:42 |
| `Sources/DAWEngine/PlaybackGraph.swift` | 4424 | `2686a1fda401` | 09-25 15:32 |
| `Tests/DAWEngineTests/AUHostingTests.swift` | 192 | `ca1b77ace8d9` | 09-20 11:20 |
| `Tests/DAWEngineTests/AutomationFXParamTests.swift` | 513 | `2ac4179c7ef2` | 09-20 11:20 |
| `Tests/DAWEngineTests/FirstClipDropProbeTests.swift` | 472 | `cfc40cdda00c` | 09-20 11:20 |
| `Tests/DAWEngineTests/MainActorOccupancySiteTests.swift` | 1856 | `5d08632e211d` | 09-24 10:20 |
| `Tests/DAWEngineTests/OfflineRenderReadinessTests.swift` | 635 | `d503ae895521` | 09-20 11:20 |
| `Tests/DAWEngineTests/PDCHostedAURenderTests.swift` | 382 | `ec9acfec3303` | 09-20 11:20 |
| `Tests/DAWEngineTests/SoundBankHostingTests.swift` | 744 | `ba9f9ffabc3c` | 09-20 11:20 |
| `Tests/DAWEngineTests/StemNullTests.swift` | 314 | `a4688cdbe388` | 09-20 11:20 |
| `docs/ARCHITECTURE.md` | 2355 | `e986798cbbd6` | 09-27 06:05 |
| `docs/research/design-m29-oop-au-hosting.md` | 1842 | `f1a2b8e93f5b` | 08-20 21:44 |
