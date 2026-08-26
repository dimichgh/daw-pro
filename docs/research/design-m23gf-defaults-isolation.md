# m23-gf — Isolating the staging corpus from the user's preferences domain

**Status: DESIGN, not implemented. No code changed by this document.**
Author: daw-architect, 2026-08-10. Hand-off targets: `qa-test-engineer` (Phases A–C, E), `swift-app-engineer` (Phase F only, optional).

---

## 0. The decision

**Give the staging binary its own CFPreferences identity by launching it through a symlink
named `DAWProStaging`, placed in the same directory as the real binary, created and verified
inside `startStaging`.**

A bundle-less macOS executable derives its preferences domain from its *executable path's last
component*. Renaming the path the kernel is asked to exec therefore moves the whole domain —
our six stores **and every key AppKit writes on its own** — in one move, with **zero Swift call
sites changed** and **one gate edited**.

This is measured, not reasoned. See §1.

The domain is cleared once per gate process and seeded from a checked-in fixture, so a gate run
is reproducible and inherits nothing from the user or from yesterday's run.

---

## 1. What I measured

A 12-line Swift probe (`swiftc`-compiled into the session scratchpad, **strictly read-only** —
no `set`, no `removeObject`, no `synchronize`) printing `ProcessInfo.processName`,
`Bundle.main.bundleIdentifier`, `Bundle.main.bundleURL`, `NSHomeDirectory()`, and how many of
four keys known to exist in `~/Library/Preferences/DAWApp.plist`
(`panelDensity.mixer`, `onboarding.state`, `copilot.model`, `panelLayout.sidebarWidth`) are
visible through `UserDefaults.standard.object(forKey:)`.

Run 1 is the **positive control**: if it did not report 4/4, every later absence would be
meaningless.

| # | How it was launched | `processName` | user's keys visible | `Bundle.main.bundleURL` |
|---|---|---|---|---|
| 1 | real path, file named `DAWApp` (**positive control**) | `DAWApp` | **4/4** | probe dir |
| 2 | **symlink** `DAWAppStaging` → `DAWApp`, same directory | `DAWAppStaging` | **0/4** | probe dir (unchanged) |
| 3 | **copy** named `DAWAppCopy` | `DAWAppCopy` | **0/4** | probe dir (unchanged) |
| 4 | real binary, node `spawn(..., { argv0: "DAWAppStaging" })` | `DAWApp` | **4/4** | probe dir |
| 5 | real binary, `HOME=/private/tmp/fakehome-probe` | `DAWApp` | **4/4** | probe dir |
| 6 | real binary, `CFFIXED_USER_HOME=/private/tmp/fakehome-probe` | `DAWApp` | **4/4** | probe dir |
| 7 | **symlink in a DIFFERENT directory** | `DAWAppStaging` | 0/4 | **the symlink's dir, NOT the target's** |

A second probe on Application Support resolution:

| env | `FileManager.urls(for: .applicationSupportDirectory)` | `NSHomeDirectory()` |
|---|---|---|
| plain | `/Users/dsemenov/Library/Application Support` | `/Users/dsemenov` |
| `HOME=/private/tmp/fakehome-probe` | `/Users/dsemenov/Library/Application Support` (**unmoved**) | `/Users/dsemenov` (**unmoved**) |
| `CFFIXED_USER_HOME=…` | `/tmp/fakehome-probe/Library/Application Support` | `/tmp/fakehome-probe` |

### What each row buys

- **Rows 1–3: the lever works.** Domain identity follows the executable path. Symlink and copy
  both move it.
- **Row 4 kills the cheapest-looking option.** `argv0` spoofing is the first thing an implementer
  reaches for (node supports it natively, no filesystem work). It **does not work** — CoreFoundation
  derives the process name from `_NSGetExecutablePath`, not from `argv[0]`. Without this row the
  implementing agent would very likely ship row 4 and believe it was isolated. **Do not use `argv0`.**
- **Row 7 is a hard constraint on placement.** `Bundle.main.bundleURL` follows the *symlink's*
  containing directory. `Sources/DAWApp/Onboarding/OnboardingTourView.swift:61-63` resolves its
  asset bundle off `Bundle.main.resourceURL` / `Bundle.main.bundleURL`, so an alias placed anywhere
  other than `.build/debug/` silently breaks SwiftPM resource lookup. **The alias must live beside
  the real binary.**
- **Rows 5–6 retire two alternatives and correct a documented decision** (see §2.2).

**Reproduce it:** the probe source and the exact runs are trivially re-creatable; the implementing
agent should re-run rows 1, 2 and 4 on their machine before writing code, because this whole design
rests on them and a macOS point release could in principle move it.

### Two more measured facts

**(a) There are TWO real preference domains, and they have already diverged.**

```
~/Library/Preferences/DAWApp.plist          # the BARE binary (.build/debug/DAWApp)
~/Library/Preferences/dev.dawpro.app.plist  # the BUNDLE (CFBundleIdentifier per scripts/Info.plist)
```

| key | `DAWApp` | `dev.dawpro.app` |
|---|---|---|
| `panelDensity.transport` | `pro` | `simple` |
| `panelLayout.sidebarWidth` | 260 | 420 |
| `panelLayout.followPlayhead` | 0 | 1 |
| `panelLayout.pianoRollPPB` | 32 | 86.437… |
| `NSWindow Frame …AppWindow-1` | `0 184 1440 900` | `0 72 1728 1012` |

**(b) The window move has a mechanism, and it is not intermittent in the way the framing assumes.**

`debug.windowFrame` (`Sources/DAWApp/DAWProApp.swift:3885` dispatch, `setWindowFrame` at
`:4351`) sets the NSWindow frame and **holds the top-left corner stationary** — `:4377-4380`:
it keeps `frame.maxY` and drops the origin by the new height.

Ten gates and probes pin `debug.windowFrame {width: 1400, height: 1000}`
(`m17a-insert-editors:85`, `m17b-arrange-zoom:70`, `m18i-undo-split:144`, `m23ak-note-selection-drop:265`,
`m23cf-delete-key:269`, `m23ek-clipboard:134`, plus `_m23cf3-alternation-probe:83`,
`_m23cf3-onkeypress-probe:81`, `_m23fi-marquee-focus-probe:81`, `_m23fi-onkeypress-census:123`,
`_m23fk-delete-character-probe:105`).

Apply that rule to the observed before-state: `0 184 1440 900` → top = 184 + 900 = 1084 →
new origin y = 1084 − 1000 = **84**, x unchanged = **0**, size **1400 × 1000** →
`0 84 1400 1000`. **That is exactly the after-value the user recorded.**

So the frame *set* is deterministic and happens on every run of any of those gates. What is
intermittent is only whether AppKit **flushes its autosave** to the domain before the process is
killed. This matters for the verification design (§9): waiting for a collision to recur is not a
test; observing the write directly is.

⚠️ Mechanism ≠ cause: I have established the mechanism and an exact arithmetic match, not a
chain of custody to one specific gate run. Attribution to a named gate is not needed for the fix.

⚠️ Related: `m23ax-strip-reserves.mjs:99` pins `{width: 1440, height: 900}` — **the value the user
believes they restored by hand is itself one of the corpus's pins.** The current
`0 184 1440 900` is indistinguishable from that gate's residue. Do not treat it as a known-good
user value.

**(c) The corpus already suspected this, in writing.** `scripts/gates/m18i-undo-split.mjs:35-52`
records unexplained cross-run PNG-hash drift (382788 / 382765 / 382859 bytes over 11 runs, no
stable pattern, despite the m23-ay per-process profile root) and names the cause as *"a
`~/Library/Preferences` UserDefaults window-frame value is a plausible remaining store — it is
outside `DAWPRO_PROFILE_ROOT`'s relocation — but that is unmeasured, not a finding."*
m23-gf is the change that can settle that. Keep the discipline: it stays a hypothesis until the
drift is measured before and after.

---

## 2. Corrections to the framing I was given

The framing is unusually accurate. Five corrections, one of them load-bearing.

### 2.1 "the USER'S REAL preferences domain, `~/Library/Preferences/DAWApp.plist`" — singular is wrong

There are two (§1a). What the gate corpus corrupts is specifically the **bare-binary** domain.
The bundle domain `dev.dawpro.app` is untouched by gates today and must stay that way. This
*narrows* the fix: staging only has to be separated from human bare-binary runs.

It also raises a question this design does not answer: **which domain is "the user's live app"?**
Nothing was listening on 17600 or 17695 and no `DAWApp` process was running when I checked
(`/bin/ps -Ao pid,comm`, `lsof -nP -iTCP:17600 -sTCP:LISTEN`). Both plists are recent
(`DAWApp.plist` today 13:26, `dev.dawpro.app.plist` today 00:44), so both launch paths are in
active use. This changes urgency, not direction.

### 2.2 ⛔ The m23-ay note's stated reasoning is measurably FALSE — but its decision was right

`Sources/DAWCore/AppDirectories.swift:141-144` says:

> **Why an env var and not a temp `HOME`.** Redirecting `HOME` moves `UserDefaults` too, so
> preference-persistence gates (`m23c2`) would stop testing the thing they exist to test.

**Measured (rows 5 and the App-Support table): redirecting `HOME` moves neither `UserDefaults`
nor Application Support.** On this machine Foundation resolves the home directory through
CoreFoundation (`CFFIXED_USER_HOME`, then the passwd database), ignoring `$HOME` entirely; and
`CFFIXED_USER_HOME` moves Application Support but still **not** `UserDefaults`, because the
preferences domain is resolved by `cfprefsd` on the daemon side.

So: the env var was genuinely necessary (a temp `HOME` would have isolated *nothing*), but the
reason recorded for rejecting temp `HOME` is not the true reason. **The comment should be
corrected as part of this item** (Phase A, `AppDirectories.swift:141-144`) — it is exactly the
stale-MEASURED-comment class already filed twice (m23-fy, `DAWProApp.swift:2376`).

### 2.3 The user's suspicion about `m23c2-follow-playhead` is CORRECT — verified against the gate text

`scripts/gates/m23c2-follow-playhead.mjs:642-705` (Leg 6): set `followPlayhead: true` over the
wire; read back; kill process A by exact pid; relaunch **the same binary with the same env**
(`:664-679`, the one hand-rolled launch in the corpus); reconnect; assert the value survived
(`:697`).

That leg needs a domain that is **persistent and stable across the relaunch within the run**. It
does **not** need the user's domain. The real content of the m23-ay objection was that a
*fresh-per-launch* redirect would destroy restart continuity — which is answerable by the same
memoisation `stagingProfileRoot()` already uses (`_staging.mjs:114-144`: one root per node
process, deliberately not per launch, for exactly this reason).

**Conclusion: a suite/domain redirect is precise where a temp `HOME` was blunt, and the m23-ay
objection does not transfer to it.**

### 2.4 "the defaults domain is derived from the executable name" — correct, with a refinement that changes the implementation

It is derived from the executable **path**, not from `argv[0]` (row 4). Stated as "name" an
implementer will reach for `spawn(..., { argv0 })` and ship a no-op that looks like a fix.

### 2.5 The blast radius is bidirectional, and the outbound half is not the expensive one

The framing casts this as leakage **out** (gates corrupt the user). It is equally leakage **in**:
every staging launch inherits the user's ambient values. Today the corpus runs with **six of
seven panels at `pro`** while `PanelDensityStore.density(forPanel:)`
(`Sources/DAWAppKit/PanelDensityModel.swift:96-97`) ships `.simple` as its default. That is
the m23-et class ("ambient sticky state changes a gate's VERDICT, not just its pixels") at
corpus scale, and it is the single biggest cost of this design (§7.3).

### 2.6 Confirmed as stated (no correction)

- Six stores, all `UserDefaults.standard` by default, all constructed argument-free at
  `Sources/DAWApp/DAWProApp.swift:2498, 2509, 2527, 2535, 2545, 2575`. I re-grepped `UserDefaults`
  across all of `Sources/`: **there is no seventh**. The only other hits are the key-name constants
  `CopilotLimits.userDefaultsKey` and `AnthropicModelCatalog.userDefaultsKey` and doc comments.
- `_staging.mjs:45` launches the bare binary, not a bundle.
- `NSWindow Frame` is AppKit's own autosave; nothing in `Sources/` sets a frame autosave name.
- A suite applied to our six stores would not stop the window-frame writes.

---

## 3. The recommended seam, in detail

### 3.1 Name

**`DAWProStaging`** — the symlink's filename, the process name, and therefore the domain, all
the same string.

Not `DAWAppStaging`: that is a **prefix-extension of the real domain `DAWApp`**, so any glob or
prefix match (`defaults` hints, a cleanup sweep, `rm ~/Library/Preferences/DAWApp*`) would hit the
user's domain. `DAWProStaging` is a prefix of nothing real.

Side benefit, do **not** relax any rule on account of it: the staging process's `comm` becomes
`DAWProStaging`, so a name-based match can no longer reach the user's app. The pidfile-exact
kill discipline stays exactly as it is.

### 3.2 Symlink, not hardlink, not copy — and why that ranking is about correctness

- **Symlink (chosen).** Points at the *path*. `swift build` replacing the binary is transparently
  followed. Free.
- **Copy (works, row 3, rejected).** Must be re-made after every build and verified **by content
  hash, not mtime**, or the alias silently runs a stale binary — re-creating precisely the hazard
  `buildOrAbort` (`_staging.mjs:79-87`) exists to eliminate. Also costs a multi-hundred-MB copy per
  gate process.
- **Hardlink (rejected outright).** Pins the *inode*. After a rebuild the alias runs the OLD
  binary with no symptom at all. This is the worst available option and it is the one that looks
  cheapest.

### 3.3 Placement

`.build/debug/DAWProStaging`, i.e. **the same directory as the real binary** — forced by row 7
(`Bundle.main.bundleURL` follows the symlink's directory, and `OnboardingTourView` resolves its
asset bundle relative to it).

### 3.4 Where the mapping happens

**Inside `startStaging`**, applied to whatever `binary` the caller named. 72 gates call
`startStaging`; 29 of them pass an explicit `binary:`. Mapping inside the harness means **zero
gate edits** for all 72 — the same "a gate author cannot forget what they never have to write"
rule the module already states for `DAWPRO_PROFILE_ROOT` (`_staging.mjs:296-299`).

There is exactly **one** bypass in the corpus: `m23c2-follow-playhead.mjs:664`. Both files that
looked like additional bypasses — `_m23al-focus-probe.mjs:68` and `_m23an-geometry-probe.mjs:32` —
declare a `BINARY` const but hand it to `startStaging` (`:110` and `:69` respectively), so they
are covered.

### 3.5 Domain lifecycle: clear once per gate process, then seed

`gate-corpus-run.mjs` runs each gate as its own node process, so "once per node process" means
"once per gate" — a fresh, reproducible domain for every gate, and no inheritance across runs.
Within a run the domain is stable, which is what Leg 6 needs.

```
startStaging()
  ├─ assertStagingPort(port)                    (existing)
  ├─ stopStaging(gate)                          (existing — MUST precede the clear)
  ├─ resetStagingDefaultsDomain()               (NEW, memoised once per process)
  │     ├─ assertStagingDefaultsDomain(name)    deny-list + shape guard
  │     ├─ acquireDefaultsDomainLock()          pid-owner lock, throws on a LIVE foreign owner
  │     ├─ /usr/bin/defaults delete DAWProStaging      (non-zero when absent = success)
  │     ├─ seed from scripts/gates/_staging-defaults-seed.json
  │     └─ read back every seeded key           a setter's return is not proof it took
  ├─ stagingBinaryAlias(binary, root)           (NEW) → absolute alias path, or THROWS
  └─ spawn(alias, [], { cwd: root, env: childEnv, ... })
```

**Ordering is load-bearing.** `stopStaging` first: a surviving app from a previous run holds the
domain open in `cfprefsd`, and clearing underneath it is a race.

### 3.6 Guards (each mirrors an existing one in the module)

- `assertStagingDefaultsDomain(name)` — the `assertStagingPort` shape (`_staging.mjs:61-72`).
  Refuses: a non-string / empty name; any name in `["DAWApp", "dev.dawpro.app"]`; any name not
  equal to `DAWProStaging`; any name containing `/` (a domain name that is a path writes an
  arbitrary plist).
- `stagingBinaryAlias` — **throws, never falls back.** If the real binary is missing, if the alias
  path exists and is not a symlink, or if the read-back `readlinkSync` does not equal the requested
  target, it aborts. Silent fallback to the real binary would put every write back in the user's
  domain while every log line said "isolated" — the `.refused` trap m23-ay already documents
  (`AppDirectories.swift:278-284`).
- **Concurrency lock**, `/tmp/daw-gate-out/_staging-defaults.lock`, holding the owning node pid.
  Acquire refuses if the file names a **live** foreign pid. A stale lock from a crashed run
  self-heals via the liveness check. Without it, a hand-run gate started during a corpus run would
  clear the corpus run's domain mid-flight — silent corruption. Released best-effort on the
  `armTeardown` exit path (`_staging.mjs:188-…`), which m23-bd already proved fires on every exit
  path including the watchdog.

### 3.7 Seeding — the part that must not be hand-waved

**Seeding is mandatory, and I measured why.** With `onboarding.state` absent,
`OnboardingModel.shouldOfferTour` is `state == .inactive`
(`Sources/DAWAppKit/OnboardingModel.swift:282`), and `offerTourIfEligible()`
(`Sources/DAWApp/DAWProApp.swift:3714-3716`) **begins the tour on every ContentView appear**. A
virgin domain therefore puts an onboarding overlay in front of every UI gate in the corpus.

Seed file: **`scripts/gates/_staging-defaults-seed.json`**, checked in, one comment per key naming
what breaks without it. It is applied with `/usr/bin/defaults write` (a real persistent write that
gates can then overwrite), **never** as command-line `-key value` arguments: `NSArgumentDomain`
outranks the persistent domain, so a gate that *writes* the key would read back the stale
argument value — a silent-wrong-answer shape, and `debug.onboardingState` exists precisely so
gates can write it.

Two seeds, in two phases, because they answer different questions:

- **Phase B seed = a snapshot of today's ambient values** (the seven `panelDensity.*`, the eight
  `panelLayout.*`, `copilot.model`, `onboarding.state`, captured once from the current
  `DAWApp.plist`). This makes the isolation change **behaviour-neutral**: the fail set must be
  *identical*, so any red is a real break and nothing else. It also decouples the corpus from the
  user's live prefs immediately.
- **Phase E seed = `{"onboarding.state": "completed"}` only**, everything else at shipped defaults.
  This is what the standing "pin to APP DEFAULTS" law actually wants, and it is a **separate,
  deliberately-attributed behavioural change**.

Shipping both at once would mix an isolation change with a corpus-wide UI-shape change and make
the fail-set comparison uninterpretable.

---

## 4. Alternatives, and why they lose

### 4.1 `UserDefaults(suiteName:)` threaded through the six backings — LOSES

The seam already exists and is proven by tests (`init(defaults:)` on all six). Six construction
sites in one file, plus an env-driven resolver in DAWAppKit. Clean, in-language, testable.

**It loses on the requirement, not on cost: it covers none of the AppKit-written state.** The
incident that actually hurt the user — the moved window — is `NSWindow Frame …`, written by
AppKit through `standardUserDefaults`. This option leaves every one of those writes in the shared
domain. A fix that does not fix the reported incident is not the fix.

Secondary: it needs a new env-var contract, a second spelling of a name Swift owns in
`_staging.mjs`, and a pinning test — the m23-ay tax — for strictly less coverage than a free
symlink.

**Keep it in the back pocket** for one case only: if a future staging launch has to use the
*bundle* (which would land in `dev.dawpro.app`, the user's other real domain), the alias trick is
unavailable and suites become the only lever for our six stores.

### 4.2 A distinct bundle identity for the staging binary — LOSES

Embedding an `Info.plist` (`-Wl,-sectcreate,__TEXT,__info_plist,…`) gives the bare binary a
`CFBundleIdentifier` and thus a domain. But it is a **build-time** property: every bare-binary
launch — including the user's own `swift run DAWApp` — would move to the same new domain. It
separates bare-binary from bundle, which is not the split we need; it does not separate staging
from the human. It also silently migrates the user's existing `DAWApp.plist` values to nowhere.

### 4.3 Harness-level whole-domain snapshot/restore — LOSES, and is actively dangerous

Write-back through `cfprefsd` is asynchronous and the daemon caches; editing
`~/Library/Preferences/DAWApp.plist` behind it is unreliable and can be overwritten. Worse, if
the user's app is *running* during a corpus run, restore would revert their legitimate concurrent
edits. It also fails the same way the current per-key guards fail (§4.5): a restore can only put
back what it knew to snapshot, and the AppKit key names are not stable (§5).

Useful only as a **measuring instrument** in the verification gate (§9), never as the mechanism.

### 4.4 Accept the split (isolate ours, handle AppKit's separately) — LOSES on cost, not principle

This is what §4.1 plus a Swift-side `setFrameAutosaveName("")` amounts to: two mechanisms, two
contracts, two tests, a production-shape deviation conditioned on test state — to reach an outcome
one symlink reaches for free. Its only merit is that it needs no new process-identity concept.

### 4.5 Extend `panelDensityGuard` to the AppKit keys — IMPOSSIBLE, not merely expensive

The window autosave name embeds the **SwiftUI root view's Swift type**. Both real domains contain
keys of the form

```
NSWindow Frame SwiftUI.ModifiedContent<…DAWApp.ContentView…>-1-AppWindow-1
```

and `DAWApp.plist` holds **two different ones**, differing by whether `AppModel` is in the
modifier chain — i.e. the key changed when the view hierarchy changed. There is no stable key to
snapshot, guard, or deny-list. Any per-key guard here would rot at the next view refactor and
report a confident green.

### 4.6 `argv0` spoofing / temp `HOME` / `CFFIXED_USER_HOME` — MEASURED NOT TO WORK

Rows 4, 5, 6. Recorded so nobody re-proposes them.

---

## 5. The AppKit-written state — the explicit answer

**Domain identity moves it. It is the only option that does, and the evidence is already on disk.**

The measured non-ours keys, exhaustively, across both real domains:

| key | where | what it is |
|---|---|---|
| `NSWindow Frame SwiftUI.ModifiedContent<…>-1-AppWindow-1` (2 variants) | `DAWApp` | **the incident** — main window geometry |
| `NSWindow Frame SwiftUI.ModifiedContent<…>-1-AppWindow-1` | `dev.dawpro.app` | same, different value |
| `NSWindow Frame NSColorPanel` | both | color-panel geometry |
| `NSSplitView Subview Frames NSColorPanelSplitView` | both | color-panel splitter |
| `NSToolbar Configuration com.apple.NSColorPanel` | both | color-panel toolbar |
| `NSNavPanelExpandedSizeForOpenMode` / `ForSaveMode` / `ExpandedStateForSaveMode` | `dev.dawpro.app` | open/save panel geometry |
| `NSOSPLastRootDirectory` | `dev.dawpro.app` | last open-panel directory |

**Why domain identity covers them, as an observation rather than an assumption:** the *same
logical key* (`NSWindow Frame …AppWindow-1`) exists in **both** files with **different values**.
AppKit therefore writes it into whichever domain the running process's identity resolves to. Move
the identity and the write moves with it. No enumeration of AppKit's keys is required — which is
the whole point, because that enumeration is not knowable in advance.

**Saved application state is not a second channel today** — measured: no
`~/Library/Saved Application State/*aw*` exists (a bundle-less process has no bundle identifier to
name a `.savedState` directory with). Note the corollary: **if staging ever switches to launching
the `.app` bundle, it acquires both `dev.dawpro.app` prefs and a saved-state directory shared with
the user.** That is a reason to keep staging on the bare binary, recorded here so the decision is
not silently reversed.

**Fallback, if a future macOS breaks rows 2/3:** in `DAWProApp`, when the staging env var is set,
call `setFrameAutosaveName("")` on the content window (the file already reaches `NSWindow` in nine
places). It stops that specific write. Cost: a production-shape deviation conditioned on test
state — the `TestEnvironment.isSwiftTestProcess` precedent, acceptable but strictly worse than a
launch-time change that leaves the process production-shaped. **Not needed given the probe.**

---

## 6. Failure modes

| # | Failure | Detection | Mitigation |
|---|---|---|---|
| F1 | **Silent fallback to the real binary** — alias creation fails, harness launches `DAWApp`, everything looks isolated | none, by construction — this is the killer | `stagingBinaryAlias` THROWS, never falls back. Plus out-of-band confirmation: `/bin/ps -o comm= -p <pid>` must read `DAWProStaging`. Assert it in `startStaging` after spawn. |
| F2 | Two node processes clear each other's domain mid-run | silent wrong verdicts | pid-owner lock (§3.6), refuses loudly |
| F3 | `swift package clean` leaves a dangling alias | `spawn` ENOENT | loud already; alias is re-created every `startStaging` |
| F4 | m23c2 Leg 6 relaunch missed → B runs in the real domain | **fails loudly**: B reads a different domain, `followPlayhead` is `false` at `:697` | the good failure mode. Named here so it is not mistaken for a regression. |
| F5 | AppKit writes leaked before the alias took effect | the verification gate's POS2 (§9) | none needed — identity is fixed at exec |
| F6 | `cfprefsd` has not persisted A's write when A is killed in Leg 6 | Leg 6 fails | **unchanged risk**: A and B talk to the same `cfprefsd`, which holds the value in memory regardless of disk flush. This is exactly today's mechanism; isolation does not alter it. |
| F7 | Remediation hints name the wrong domain | operator edits the USER's domain to fix a STAGING problem | 5 sites in 3 files must be updated (§7.2) |
| F8 | Seed drifts into "reproduce the user's prefs forever" | design rot | the seed file is checked in with a per-key justification, and Phase E shrinks it to one key |
| F9 | **A later "cleanup" refactors m23c2 Leg 6's hand-rolled spawn into `startStaging`** | none — the leg would go green for the wrong reason, or red with a misleading message | `startStaging` calls `resetStagingDefaultsDomain()`, which would **wipe the very value Leg 6 exists to prove survived**. It is safe today only because the reset is memoised per process, and that memoisation is invisible at the call site. The prohibition must be written **in the gate**, next to the existing `:666-673` comment that explains why the hand-rolled launch exists. |

---

## 7. Cost

### 7.1 Swift call sites changed: **ZERO**

That is the headline. `Sources/` gets one comment correction (§2.2) and, optionally, one debug
verb in Phase F. The six backings, `DAWProApp.swift`'s six construction sites, and
`AppDirectories`' override are all untouched.

`TestEnvironment.isSwiftTestProcess(processName:)`
(`Sources/DAWCore/TestEnvironment.swift:33-35`) is the **only** consumer of `processName` in
`Sources/` and it matches `"swiftpm-testing-helper"` — **checked**: an alias named
`DAWProStaging` cannot perturb it.

### 7.2 Gate/harness edits

| file | change |
|---|---|
| `scripts/gates/_staging.mjs` | the whole mechanism: `stagingBinaryAlias`, `resetStagingDefaultsDomain`, `assertStagingDefaultsDomain`, the lock, the `ps` confirmation, wiring into `startStaging`, return `{ binary, defaultsDomain }` |
| `scripts/gates/m23c2-follow-playhead.mjs:664` | the one bypass — spawn the alias, not `BINARY` |
| `scripts/gates/_staging.mjs:725, :892` | hint text `defaults delete DAWApp panelDensity.<panel>` → the staging domain |
| `scripts/gates/m23ej-panel-density-forms.mjs:121, :140` | same hint-text class |
| `scripts/gates/m23s-insert-labels.mjs:127` | same (`defaults write DAWApp panelLayout.mixerInsertsCollapsed`) |
| `scripts/gates/_staging-defaults-seed.json` | NEW, checked in |
| `scripts/gates/m23gf-defaults-isolation.mjs` | NEW verification gate (§9) |
| `Sources/DAWCore/AppDirectories.swift:141-144` | correct the false rationale (§2.2) |

**Five existing files touched** (`_staging.mjs` appears twice above — mechanism, then hint text)**, two created. No gate's assertions change.**

### 7.3 The real cost: gates that have been inheriting the user's values

This is where the risk lives, and it is why Phase C exists.

`PanelDensityStore.density(forPanel:)` ships `.simple`
(`Sources/DAWAppKit/PanelDensityModel.swift:96-97`). The user's `DAWApp.plist` currently holds
**`pro` for arrange, instrumentPicker, mixer, pianoRoll, quantize and transport** — six of seven
panels — so every staging launch today runs in a `pro` UI that the shipped defaults would not
produce. A virgin domain flips all six.

Layout is milder: `sidebarWidth 260` and `editorFraction 0.45` **match** the shipped defaults
(`PanelLayoutStore.defaultSidebarWidth`, `defaultEditorFraction`); `rowHeight 34`, `arrangePPB 16`,
`pianoRollPPB 32`, `followPlayhead 0`, `auditionEnabled 1`, `mixerInsertsCollapsed 0` need the same
comparison made key-by-key by the implementer before Phase E.

`copilot.model = claude-sonnet-5` today; absent means the `AnthropicModelCatalog` default. Any
COPILOT gate asserting a model name is at risk in Phase E.

**Not at risk: the control port.** `ControlPortConfig.resolve`
(`Sources/DAWAppKit/ControlPortConfig.swift:72-79`) gives the environment strict precedence over
the persisted setting, and `startStaging` always sets `DAW_CONTROL_PORT`. Verified by reading the
resolver, not assumed.

### 7.4 Gates I believe are at risk — and how to find out rather than guess

Named because the framing asked for names, **not** because I claim they break:

- `m23c2-follow-playhead` — the one bypass (F4). Certain to need the edit; fails loudly if missed.
- `m23ay-profile-isolation` — asserts the app's stderr override announcement (ISO2) and that the
  user's real profile is byte-identical (A1–A3). Unaffected in principle, but it is the gate whose
  instrument the new gate reuses. Run it first and last.
- **Phase E only** — every gate carrying a `panelDensityGuard` (`m17f`, `m19g`, `m22g`, `m23a`,
  `m23a2`, `m23ag`, `m23ah`, `m23ak`, `m23ax`, `m23b`, `m23c2`, `m23cf`), plus `m17b-arrange-zoom`
  (which the m23-er census showed mutates layout while calling the verb zero times), plus the
  geometry/pixel gates (`m18i`, `m23al`, `m23an`, `m23s`).

**The method, not the list, is the deliverable.** Run `scripts/gate-corpus-run.mjs` before and
after and compare **fail sets by identity**, never counts — the standing law, and here it is
exactly what separates "the onboarding tour reddened eleven UI gates" from "I broke something".
The current baseline (`scripts/gate-corpus-baseline.json`) is 65 PASS / 1 EXPECTED-RED / 3 FAIL,
with 3 gates unmeasured (`m17h`, `m23bb1`, `m23fo`) — **unmeasured is not green**; do not let them
silently join the "after" set.

---

## 8. Implementation plan

### Phase A — correct the record (no behaviour change)
1. `Sources/DAWCore/AppDirectories.swift:141-144` — replace the false temp-`HOME` rationale with
   the measured one: `HOME` moves neither `UserDefaults` nor Application Support; `CFFIXED_USER_HOME`
   moves Application Support but not `UserDefaults`; the preferences domain follows the executable
   path and is resolved daemon-side. Keep the decision, fix the reason. Cite this document.
2. Re-run rows 1, 2, 4 of §1 on the implementing machine and paste the output into the item.
   **If row 2 does not report 0/4, stop — the design's spine is gone and §4.1 + §5's fallback
   becomes the plan.**

### Phase B — the seam, isolation-only

⚠️ **The seed file lands in THIS phase, not later.** `resetStagingDefaultsDomain()` clears the
domain; if the seed does not yet exist, the corpus runs virgin and the onboarding tour appears in
front of every UI gate (§3.7). Clearing and seeding must land together or not at all.

3. Capture `~/Library/Preferences/DAWApp.plist` **read-only** into
   `scripts/gates/_staging-defaults-seed.json` — the panel/copilot/onboarding keys only, **never**
   the `NS*` keys, which must be allowed to regenerate. One comment per key naming what breaks
   without it.
4. `scripts/gates/_staging.mjs`: add `STAGING_DEFAULTS_DOMAIN = "DAWProStaging"`,
   `REAL_DEFAULTS_DOMAINS = ["DAWApp", "dev.dawpro.app"]`, `assertStagingDefaultsDomain`,
   `stagingBinaryAlias`, `resetStagingDefaultsDomain` (memoised, lock-guarded, seeds from step 3),
   and the `/bin/ps -o comm= -p <pid>` post-spawn confirmation (F1).
5. Wire into `startStaging` in the order of §3.5. Extend the return value with
   `{ binary: aliasPath, defaultsDomain }`.
6. **B-smoke — close the gap between the toy probe and the real app. Do this before touching any
   gate.** §1's rows prove the mechanism for a 12-line binary; nothing yet shows that the real
   SwiftUI `DAWApp` comes up through a symlink. Launch ONE staging instance on **17695** through the
   alias and confirm, in order: it serves a bare `debug.panelLayout {}`; `/bin/ps -o comm= -p <pid>`
   reads `DAWProStaging`; `~/Library/Preferences/DAWProStaging.plist` appears;
   `~/Library/Preferences/DAWApp.plist` is byte-identical; **the onboarding tour does NOT appear**
   (i.e. the step-3 seed took) — check `debug.onboardingState`/`tourStep`; and the app's resources
   still resolve (the row-7 hazard — open the onboarding tour view or any asset-backed panel).
   **If any of these fail, stop.** Phase A step 2 re-runs the toy probe, which structurally cannot
   catch a real-app failure.
7. Fix the one bypass, `m23c2-follow-playhead.mjs:664` — spawn the alias, not `BINARY`.
   ⛔ **Add the F9 prohibition in that gate while you are there**: do not refactor Leg 6 into
   `startStaging`; the domain reset would destroy the assertion.
8. Fix the 5 hint-text sites (§7.2).

⚠️ **Leave every existing per-key guard and restore in place.** After Phase B the tree has
isolation *plus* the old mitigation — strictly more protection than today, at every moment.

### Phase C — verification
9. Write `scripts/gates/m23gf-defaults-isolation.mjs` (§9).
10. **Corpus comparison, and the BEFORE run must be FRESH.** Run
    `scripts/gate-corpus-run.mjs` on the tree **with Phase B reverted or stashed-equivalent** (do
    not use `git stash` — re-run from a clean checkout in a scratch clone, or run BEFORE landing
    Phase B), then again after, **back-to-back in the same session**. Compare **fail sets by
    identity**, never counts.
    ⛔ **Do NOT compare against `scripts/gate-corpus-baseline.json` as the primary reference.**
    That baseline was produced at m23-ep-2 against whatever `DAWApp.plist` held then, and the
    ambient domain has drifted every run since — by the very mechanism this item documents
    (§1b: the 1400×1000 and 1440×900 pins land in it). A difference against the stored baseline
    can have nothing to do with this change and you would have no way to tell. Use it as a third
    data point only.
    Carry the 3 unmeasured gates (`m17h`, `m23bb1`, `m23fo`) forward as **unmeasured**, never as
    passes.

### Phase D — settle the m18i hypothesis (cheap, high value)
11. Re-run `m18i-undo-split` N≥11 times and compare the cross-run hash spread against the recorded
    382788 / 382765 / 382859. If the drift is gone, m18i's suspicion is confirmed and its comment
    should say so. **If it is not gone, say so just as loudly** — it stays unexplained, and this
    item does not get to claim it.

### Phase E — flip the seed to shipped defaults (separate item; needs its own attribution)
12. Shrink the seed to `{"onboarding.state": "completed"}`.
13. Full corpus run (fresh before/after, same rule as step 10); attribute **every** new red to a
    named inherited key, or revert.

### Phase F — optional, and worth it (`m23-gf-2`)
14. Add `debug.defaultsDomain` returning `ProcessInfo.processInfo.processName` and the resolved
    domain, so the app **states** its own isolation instead of the harness inferring it — the same
    upgrade `ISO2` gave m23-ay. This is the only Swift change in the whole design. It is optional
    because Phase B's `/bin/ps` check already provides out-of-band confirmation.

**Nothing here requires full Xcode.** No entitlements, no signing, no AUv3, no bundle changes.
`scripts/bundle.sh` and `scripts/Info.plist` are untouched. (Recorded because "the bundle
identifier" appears in this design as an *alternative* — §4.2 — and that one would have.)

---

## 9. Test strategy

Model the new gate on `scripts/gates/m23ay-profile-isolation.mjs`, which already solves the
"prove a launch did not touch the user's stuff" problem for the filesystem and carries the
control set to copy.

`scripts/gates/m23gf-defaults-isolation.mjs`:

**Controls first (m23ay's CTL0–CTL6 shape).**
- CTL-a: the differ detects a deliberate change to a scratch plist. *A negative result from a
  hand-built probe is the weakest evidence there is — make the probe find something you know is
  there before recording an absence.*
- CTL-b: `~/Library/Preferences/DAWApp.plist` is **non-empty** before the run (m23ay's CTL6 —
  otherwise "unchanged" is a claim about nothing).

**Assertions.**
- **A1** `~/Library/Preferences/DAWApp.plist` is byte-identical across a staging launch that
  provably writes preferences (hash + size + mtime).
- **A2** the same for `dev.dawpro.app.plist`.
- **POS1** `~/Library/Preferences/DAWProStaging.plist` **exists** and contains a
  `panelDensity.*` / `panelLayout.*` key the gate itself set. *Without POS1, A1 passes for a
  staging app that crashed before writing anything.*
- **POS2 — the assertion that closes the reported incident.** Drive
  `debug.windowFrame {width: 1400, height: 1000}` (the exact call ten gates already make, §1b),
  quit cleanly, then assert the **staging** domain gained a key matching
  `^NSWindow Frame .*AppWindow-1$` **and** that no such key in `DAWApp.plist` changed.
  This is deterministic where waiting for the collision to recur is not — the user saw it twice in
  one day and zero times across another agent's four launches, so **flush timing is the only
  variable**. If the flush cannot be forced reliably, report it as an explicit
  `UNKNOWN, not zero` tally (the m23-fv law), never as a green check.
- **NEG — a DECOY domain, never a disabled one.** The gate creates a *second* alias
  (`DAWProStagingDecoy`), launches through it, and asserts the differ **detects** the write to the
  decoy domain while **both** `DAWProStaging` and `DAWApp` are unchanged. That proves the
  instrument fires on a domain the app really is writing, which is the whole job of a negative
  control, without ever pointing the app at the user's preferences.
  ⛔ **Do NOT implement this as an isolation-defeating env switch.** "Disable isolation and assert
  A1 fails" would, when it fires, write into `DAWApp.plist` — damaging the exact asset this item
  exists to protect — and it re-creates the m23-ay defect one variable over. `_staging.mjs:296-299`
  already states the rule for the profile root: *"There is deliberately no way to UNSET it from
  here — an opt-out would be a per-gate switch that puts writes back in the user's real profile."*
  The same rule binds here. **No isolation-defeating switch exists, by design.**
- **PS** the spawned pid's `comm` reads `DAWProStaging` (F1's out-of-band confirmation).

**Corpus level.** `scripts/gate-corpus-run.mjs` before/after, compared by **fail-set identity**
against `scripts/gate-corpus-baseline.json`. Carry the 3 unmeasured gates forward as
**unmeasured**, not as passes.

**Swift tests.** None required by Phases A–E (no Swift behaviour changes). Phase A touches a
comment only; re-run `./scripts/test.sh` to confirm 0 ✘ and do **not** inherit the 5338/545 figure
without re-measuring if any Swift file changed. Phase F would add
`DAWControl`/`DAWApp` coverage for the new debug verb.

---

## 10. Migration order — why it is never less protected than today

| step | state of the user's prefs |
|---|---|
| today | 6 stores + all AppKit keys write into `DAWApp.plist`; partial per-key guards |
| after A | unchanged (comment only) |
| after B | **staging writes nothing into `DAWApp.plist`**; per-key guards still in place (redundant, harmless) |
| after C | same, plus a reproducible seed and a gate that proves it |
| after E | same, plus gates pinned to shipped defaults |
| after a future step | per-key guards may be retired — **only** with their own before/after evidence |

The guards are removed **last, or never**. Removing them earlier would trade a proven mitigation
for an unproven one during the window when the new mechanism is least tested.

---

## 11. Text for `docs/ARCHITECTURE.md` "Key future decisions"

I did **not** apply this — the task was read-only on existing files. Paste it under
`## Key future decisions` (line 191) when Phase B lands, adjusting the status word.

> - **Staging preference isolation (m23-gf, SETTLED 2026-08-10; DESIGN in
> `docs/research/design-m23gf-defaults-isolation.md`).** Gates launch the staging app through a
> symlink named `DAWProStaging` beside the real binary, so the process's CFPreferences domain is
> `DAWProStaging` and not the user's `DAWApp`. **Measured**: a bundle-less executable's domain
> follows its executable *path* (a symlink or copy moves it; `argv0` spoofing does **not**, nor
> does `HOME`, nor `CFFIXED_USER_HOME` — the domain is resolved daemon-side by `cfprefsd`). The
> alias must sit in the same directory as the real binary, because `Bundle.main.bundleURL` follows
> the symlink's directory and `OnboardingTourView` resolves its asset bundle off it. **Why this
> and not `UserDefaults(suiteName:)` through the six backings:** the incident that forced the item
> was AppKit moving the user's window via its own `NSWindow Frame …` autosave, which no suite on
> our stores can reach; domain identity moves our six stores *and* everything AppKit writes, for
> zero Swift call sites. Hardlink rejected (pins the inode, so a rebuild silently runs a stale
> binary); copy rejected (needs hash-verified refresh per build). The domain is cleared once per
> gate process and seeded from `scripts/gates/_staging-defaults-seed.json`, because an absent
> `onboarding.state` makes `shouldOfferTour` true and puts the tour in front of every UI gate.
> ⚠️ This **corrects** the m23-ay note at `AppDirectories.swift:141-144`: redirecting `HOME` moves
> neither `UserDefaults` nor Application Support, so the reason recorded for rejecting a temp
> `HOME` was wrong even though the decision (an env var) was right. And it **retires** the m23-ay
> objection for this item: `m23c2-follow-playhead` Leg 6 needs a domain that is persistent and
> stable across the relaunch *within a run*, not the user's domain specifically.
