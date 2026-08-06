# m23-dl — Model Lifecycle Manager: design

**Status:** design document, produced by `daw-architect` 2026-08-05. Read-only on source; no code changed.
**Roadmap item:** `docs/ROADMAP.md:861` (m23-dl). Prerequisite m23-bb is `[x]` — this builds ON `SidecarStopPlanner.swift`, it does not redesign it.

---

## 0. Measured evidence (do not re-derive; re-measure if you doubt it)

All numbers below were measured on the user's machine on 2026-08-05 by this design pass,
with ACE **never started** (absolute constraint). Probe sources are in
`/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/938b526d-443f-495a-8d43-8069327f0a40/scratchpad/`
(`memprobe.swift`, `rusageprobe.swift`, `allocctl.swift`).

### 0.1 What is reachable from Swift with **no new dependency and no entitlement**

| API | Reachable? | Evidence |
|---|---|---|
| `host_statistics64(mach_host_self(), HOST_VM_INFO64, …)` → `vm_statistics64_data_t` | **YES**, `kr = 0` | measured, no entitlement, plain `import Darwin` |
| `ProcessInfo.processInfo.physicalMemory` / `sysctl hw.memsize` | **YES**, both report 128.00 GB | measured |
| `proc_pid_rusage(pid, RUSAGE_INFO_V4, …)` → `ri_phys_footprint` on a **foreign, same-uid** pid | **YES**, `rc = 0` | measured against pid 795 (zoom, same uid): `ri_phys_footprint = 0.418 GB`, `ri_resident_size = 1.208 GB` |
| `proc_pid_rusage` on a **root-owned** pid | **NO**, `rc = -1` | measured against pid 1 |
| `task_for_pid(mach_task_self_, <foreign pid>, &task)` | **NO**, `kr = 5` (KERN_FAILURE) | measured against pid 795 *and* pid 1 — blocked without the `com.apple.security.cs.debugger` entitlement |
| `task_info(TASK_VM_INFO)` → `phys_footprint` on a foreign task | **NO** — unreachable, because `task_for_pid` is the only way to get the port | follows from the above |
| `os_proc_available_memory()` | **NOT USABLE** — reports the *current* process's jetsam headroom, not the system's, and is a no-op outside a jetsam-limited context | not measured; flagged **UNVERIFIED**, and irrelevant either way |

**Consequence #1 (load-bearing):** `phys_footprint` for a sidecar **is** reachable, but *only* via
`proc_pid_rusage`, *only* because we spawn the sidecar as the same uid. `task_for_pid` is a dead end —
do not let an implementing agent reach for it, it will fail at runtime and the failure looks like
"the check silently returned nil".

### 0.2 System-wide snapshot, idle machine, 2026-08-05

`vm_kernel_page_size = 16384`, `hw.memsize = 128.00 GB`.

```
free_count            2205114   33.65 GB
active_count          2951133   45.03 GB
inactive_count        2719707   41.50 GB
wire_count             425949    6.50 GB
speculative_count      219986    3.36 GB
compressor_page_count       0    0.00 GB
external_page_count   1676108   25.58 GB   (file-backed)
internal_page_count   4214718   64.31 GB   (anonymous)
purgeable_count        126944    1.94 GB
```

Derived: Activity-Monitor-style `memoryUsed = internal − purgeable + wire + compressor = 68.87 GB`,
so `physical − used = 59.13 GB`; `free + external + purgeable + speculative = 64.52 GB`.

**Verified relationship (useful for cross-checking against a tool the user can run):**
`vm_stat`'s printed *"Pages free"* is `free_count − speculative_count`, **not** `free_count`.
Measured: `free_count 2205114 − speculative 219986 = 1985128` against a `vm_stat` sample of
`1967839` taken seconds later. Anyone comparing our number to `vm_stat` will otherwise read a
3.4 GB discrepancy as a bug.

**Do not use `kern.memorystatus_level`** (measured: `94`). It is an undocumented kernel percentage
whose formula I could not reproduce from the published counters (my best reconstruction gave 96.5,
not 94). It may be useful as a corroborating signal; it must not be the number an admission
decision turns on. **UNVERIFIED formula.**

### 0.3 THE POSITIVE-CONTROL EXPERIMENT — which metric actually tracks a hold

Three allocation shapes, each 8 GB (4 GB for the file case), allocated by a child process,
touched page-by-page, held, then `SIGKILL`ed. Every metric sampled BEFORE / DURING / AFTER.
Run on the user's M5 Max / 128 GB machine, ACE not started. Harness: `scratchpad/allocctl.swift`.

| shape | `ps` RSS | `ri_phys_footprint` | Δ `free` | Δ `external` | Δ `amUsed` | Δ `reclaimable` |
|---|---|---|---|---|---|---|
| anonymous `mmap(MAP_ANON)` 8 GB | 8.01 GB | 8.01 GB | **−8.02** | 0 | **+8.19** | −8.19 |
| Metal `makeBuffer(.storageModeShared)` 8 GB | 8.01 GB | 8.01 GB | **−7.86** | 0 | **+7.69** | −7.68 |
| file-backed `mmap(PROT_READ)` 4 GB | 4.01 GB | **0.00 GB** | −2.10 | **+4.03** | **−0.52** | **+2.36** |

Metal device reported: `Apple M5 Max, hasUnifiedMemory = true, maxBufferLength = 80.64 GB,
recommendedMaxWorkingSetSize = 107.52 GB`.

**Four findings that change the design:**

1. **`phys_footprint` is the metric that lies, not RSS.** A 4 GB file-backed mapping is charged
   **0.00 GB** of footprint while `ps` RSS correctly reports 4.01 GB. PyTorch/`safetensors` mmap
   checkpoints by default, and ACE's checkpoint tree is **56 GB** (`du -sh scripts/ace-step`,
   measured — the roadmap's "54 GB" is close but stale). So a footprint-based residency check
   would report a mmap-loaded model as holding nothing. **Never make `phys_footprint` the
   authority.**
2. **`free_count` alone is also wrong.** It fell 2.10 GB for the file case where nothing was
   really held, and it is noisy (±0.3 GB between idle samples). It also does **not** come back on
   process exit for file-backed pages (`external` stayed at 29.80 GB after the child was killed) —
   an "unloaded" assertion built on `free` would FAIL on a correctly-unloaded file-backed model.
3. **The one metric correct across all three shapes is Activity-Monitor "Memory Used":**
   `amUsed = internal_page_count − purgeable_count + wire_count + compressor_page_count`.
   It moved +8.19 / +7.69 / −0.52 — i.e. it counts the two shapes that are genuinely a hold and
   correctly ignores reclaimable file cache. `available = physicalMemory − amUsed` is the number
   the admission decision must turn on, and it is also the number the user can corroborate in
   Activity Monitor, which matters for an honest refusal message.
4. **Metal/MPS unified memory needs no special accounting.** An 8 GB `.storageModeShared` buffer
   on this M5 Max landed in RSS, footprint and `internal_page_count` exactly like malloc'd memory.
   Delete "Metal accounting is invisible" from the hypothesis list — measured false on this machine.

### 0.4 Where "RSS reports ~1 GB while holding ~75 GB" most likely comes from

I could not reproduce a 75:1 RSS discrepancy with any of the three shapes; in all three RSS was
the *most* generous reporter. The leading explanation is **pid attribution, not accounting**:

* `scripts/ace-step/run.sh` ends `exec uv run --no-sync acestep-api` (read, not modified). Bash
  `exec`s into `uv`, so the pid `SidecarManager.writePidfile(process.processIdentifier)` records
  (`SidecarManager.swift:222`) is the **`uv` supervisor**, and `uv run` then spawns a *separate*
  python child.
* m23-bb's own report records the topology as `pid 49156 -> python 49160 listening on 8001`, and
  `SidecarProcessDiscovery.swift:71` states outright that "the CHILD is what holds the ~75 GB".
* `ps -o rss -p <pidfile pid>` therefore measures `uv`, which holds ~nothing.
* `scripts/rvc/run.sh` ends `exec "$VENV_PY" server.py` — **no split**, its pidfile pid IS the
  python. So this trap is ACE-specific, which is exactly why a pairwise special case fails.

**UNVERIFIED:** I cannot prove this is the provenance of the original ~1 GB reading, because
confirming it requires booting ACE and that is forbidden this cycle. Two other candidate
mechanisms survive and are consistent with everything above: (b) file-backed mmap of the 56 GB
checkpoint tree, which under-reports *footprint* to zero (measured) and would make the hold
reclaimable rather than fatal; (c) an `iokit_mapped`/`MTLHeap` path that behaves unlike the plain
shared buffer I tested. **The design below is deliberately robust to all three**, and §7.4
specifies a one-shot diagnostic that settles it the first time ACE actually runs.

### 0.5 DECISION — the memory metric

**Primary (authoritative, system-wide):**
`available = physicalMemory − (internal_page_count − purgeable_count + wire_count + compressor_page_count) × pageSize`,
read via a single `host_statistics64(HOST_VM_INFO64)` call. No entitlement, no dependency,
one syscall, ~microseconds. This is what admission and eviction verdicts turn on.

**Secondary (attribution/diagnostic only, allowed to be nil, never decides anything):**
per-**tree** `ri_phys_footprint` + `ri_resident_size` summed over the pidfile pid **and every
descendant** from `SidecarProcessDiscovery.Snapshot.descendants(of:)`, via `proc_pid_rusage`.
Summing the tree — not the pidfile pid — is the fix for §0.4.

**Rejected alternatives:**
* *`task_info(TASK_VM_INFO).phys_footprint`* — measured unreachable: `task_for_pid` on a foreign
  pid returns `KERN_FAILURE (5)`. Would need `com.apple.security.cs.debugger` + a signed,
  hardened-runtime binary. **Flagged: requires full Xcode + entitlement changes. Do not pursue.**
* *`ps -o rss` on the pidfile pid* — the exact trap that produced the "~1 GB" reading (§0.4).
* *`kern.memorystatus_level`* — undocumented, formula not reproducible (§0.2).
* *`free_count` / `vm_stat "Pages free"`* — measured wrong for file-backed holds (§0.3 finding 2).

### 0.6 Two premises in the briefing that I measured FALSE

1. ~~"There is no autostart anywhere."~~ ⚠️⚠️ **RETRACTED — I WAS WRONG, AND THE BRIEFING WAS
   RIGHT. Autostart is real.** Corrected facts, re-verified with the dumbest patterns:
   `grep -rniE 'auto.?start' Sources` returns **16 hits**, and `grep -rn 'Manager.start()' Sources`
   returns **five** call sites, not two:

   | call site | error handling | boots |
   |---|---|---|
   | `Sources/DAWControl/Commands.swift:3198` (`ai.sidecarStart`) | `try await` — propagates | ACE |
   | `Sources/DAWControl/Commands.swift:4502` (`vc.sidecarStart`) | `try await` — propagates | RVC |
   | `Sources/DAWApp/DAWProApp.swift:2726` (`ensureSidecar`, the m17-h AUTO-START on generate) | **`try?` — swallows** | ACE |
   | `Sources/DAWApp/DAWProApp.swift:6630` (`startSketchpadSidecar`, banner Start button) | **`try?` — swallows** | ACE |
   | `Sources/DAWApp/DAWProApp.swift:2680` (Voice panel `startSidecar`) | `try await` — propagates | RVC |

   `DAWProApp.swift:2720` says it verbatim: *"Auto-start (m17-h): boots the sidecar and waits for
   healthy…"*.

   **Two compounding errors, and the second is the worse one.** (a) My `grep -rni "autostart"`
   missed the source's spelling `Auto-start`/`auto-start` — the house law is *a grep returning
   nothing where a match exists is a broken pattern, not an absence; run the dumbest pattern
   first, especially when the empty result confirms your hypothesis*, and this empty result
   confirmed my hypothesis exactly. (b) Worse: my call-site grep was **scoped to a single file**
   (`… Sources/DAWControl/Commands.swift`) and I then wrote *"exactly one call site in the tree"*.
   A single-file result generalised to the tree is not a weaker measurement, it is a different
   claim. My first tree-wide attempt died on a fish glob error (`--include=*.swift`), and on retry
   I silently dropped two of the three patterns without noticing.

   **What survives:** the ONE-home conclusion. A precondition inside `SidecarManager.start()`
   still covers all three ACE doors and both RVC doors, so §3 and §5 stand unchanged.
   **What does not:** refusal *observability*. Two of the five callers use `try?`, which destroys
   a thrown refusal. **§15 is the correction** and it is mandatory reading before Phase 3.
2. **"Metal/MPS unified memory is invisible to normal accounting."** Measured false on this
   machine (§0.3 row 2).

### 0.7 Module placement is already settled by `Package.swift`

`AIServices` depends on `DAWCore` (+ WhisperKit) and `DAWControl` depends on `AIServices`
(`Package.swift:85`, `:91-92`). So everything in this design lives in **`AIServices`**, reaches
`DAWCore.AppDirectories` for the lock path, and is consumed by `DAWControl`. `DAWCore` stays
headless and dependency-free; nothing here touches `DAWEngine` or the render thread.

---

## 1. ARCHITECTURE AT A GLANCE (each line expanded in §3-§6)

* `Sources/AIServices/ModelMemory.swift` — the metric. `MemorySnapshot.sample()` (one
  `host_statistics64`), `availableBytes`, plus tree-summed `proc_pid_rusage` attribution.
* `Sources/AIServices/ModelRegistry.swift` — N-model registry: `ModelID`, `ModelDescriptor`
  (port, estimated hold, idle policy), no pairwise special cases.
* `Sources/AIServices/ModelAdmission.swift` — the **PURE planner**, exact shape of
  `SidecarStopPlanner.swift`: `Facts` → `resolve(_:) -> Plan` → messages, zero I/O.
* `Sources/AIServices/ModelLifecycleCoordinator.swift` — the one actor holding residency
  bookkeeping, the **global single-flight**, the monotonic `generation` nonce, the idle timer,
  and the eviction-verification loop. Both managers hold `.shared`.
* Precondition call site: **`SidecarManager.start()` immediately after the `dryRun` branch**
  (`SidecarManager.swift:183-185`) and the identical spot in `VoiceConversionManager.start()`
  (`:183`). Two call sites, ONE decision — exactly the `SidecarStop` precedent.
* Wire: additive `ai.modelResidency` (read) + `ai.modelUnload` (verb); existing
  `ai.sidecarStart/Stop`, `vc.sidecarStart/Stop` keep working and route through the coordinator
  so residency bookkeeping cannot go stale.

---

## 2. THE ARITHMETIC PROBLEM THAT ALMOST BRICKED THIS FEATURE

> ⚠️⚠️ **SUPERSEDED IN PART BY §16 — READ §16 FIRST.** This section was written against a
> *guessed* 75 GB. ACE's hold has since been **measured twice, independently** (75–80 GB), so
> §2.1's "the requirement is really ~40 GB" hypothesis is **REFUTED** and §2.2's central rule
> **inverts for ACE**: the refusal below is now the feature working, not a regression. The
> *policy machinery* in §2.2 is unchanged and still correct; only ACE's number and its
> consequence move. §2.3's learning loop and every other section stand.

Re-sampled three times, 3 s apart, with the user's normal workload live (Chrome, Xcode,
VS Code, Slack, Zoom, two `claude` processes, a `swiftpm-testing-helper`):

```
available = physical − amUsed :  60.19 GB   60.67 GB   60.04 GB
```

**A naive check with the roadmap's "~75 GB" as ACE's requirement refuses ACE right now, at idle,
on a 128 GB machine.** That is strictly worse than the bug being fixed — today the product boots
ACE, and the "fix" would stop it. Any implementation that ships the 75 GB number as a hard
requirement is wrong and must be rejected in review.

### 2.1 Why 75 GB is very likely not the requirement

Measured, read-only, from the checkpoint tree:

```
runtime/checkpoints                  54 GB   (five checkpoints; a session loads a SUBSET)
  acestep-v15-xl-turbo               19 GB   DiT tier A
  acestep-v15-xl-sft                 19 GB   DiT tier B
  acestep-5Hz-lm-4B                 7.8 GB   LM tier A
  acestep-5Hz-lm-1.7B               3.5 GB   LM tier B
  acestep-v15-turbo                 4.5 GB   small DiT
  Qwen3-Embedding-0.6B              1.1 GB
runtime/src                         1.9 GB   (incl. 1.3 GB .venv)
scripts/rvc                         1.7 GB   (whole tree)
```

Worst realistic single-session weight load is `19 + 7.8 + 1.1 = 27.9 GB`, not 54 and not 75.

And §0.3 supplies a mechanism that explains the rest **and** explains why it should not be charged
to admission: **mmap + copy-to-device double-counts.** `safetensors` mmaps the checkpoint (lands in
`external_page_count` — reclaimable page cache, `phys_footprint` **0.00**, measured), and torch/MLX
then copies it into device-visible memory (lands in `internal_page_count` — a genuine hold,
measured). ~28 GB of cache + ~28 GB of copy + runtime ≈ 75 GB of *observed pressure*, of which only
about half is a real hold. `availableBytes` (amUsed-based) **already excludes the reclaimable half
by construction** — so charging admission the full 75 GB double-counts the exact pages the metric
was chosen to ignore.

~~**UNVERIFIED but consistent with every measurement I took.**~~ ⚠️ **REFUTED 2026-08-05 — see
§16.1.** The m23-ac-3e-2 teardown returned **+75.0 GB to the FREE page count** when ACE was
killed, and file-backed cache does **not** return to free on process exit (measured, §0.3: my
file-mmap child's `external` stayed at 29.80 GB after `SIGKILL`). So ≥75 GB of ACE's hold was
**not** reclaimable cache, and the mmap-double-count hypothesis cannot explain it away. The
hypothesis was reasonable and it was wrong; the measurement wins.

### 2.2 DECISION — a policy that cannot brick the feature on a guess

Every requirement number carries a **provenance**, and an *estimated* number may WARN but may
never REFUSE. Only a number measured on **this machine, for this model** may refuse.

```
required          = observed[model] ?? descriptor.estimatedHoldBytes
confidence        = observed[model] != nil ? .measured : .estimated
evictable         = resident models other than `model`, with an observed-or-estimated hold
projectedAvailable= availableBytes + Σ(hold of the evictable models we plan to evict)

projectedAvailable >= required + reserveBytes              -> .admit(evicting: […])
confidence == .estimated && projectedAvailable >= hardFloor -> .admitUnverified(…)   // warn, boot
force == true                                               -> .admitForced(…)
otherwise                                                   -> .refuse(.insufficientMemory(…))
```

Defaults, each grounded in a number I measured rather than picked:

| knob | value | why |
|---|---|---|
| `reserveBytes` | 4 GiB | OS + DAW Pro + the audio graph must not be squeezed; comfortably above the ±0.3 GB idle drift I measured between adjacent samples |
| `hardFloorBytes` | 8 GiB | one "small model" worth — my 8 GB anonymous allocation moved `available` by 8.19 GB, so below this a multi-GB load will thrash |
| ACE hold | ~~34 GiB placeholder~~ → **74.5 GiB, `confidence: .measured`** | **DROPPED THE PLACEHOLDER — §16.1.** Two independent observations (user's memory monitor 80 GB; m23-ac-3e-2 teardown +75.0 GB of freed pages). Ships as a seeded measurement, not an estimate. |
| RVC `estimatedHoldBytes` | **3 GiB** — PLACEHOLDER | whole tree is 1.7 GB on disk; RVC is a small model |
| Music Flamingo (m23-dg) | unset → treated as `.estimated` with `hardFloor` only | not installed; nothing to measure |

Arithmetic against today's machine (§16.2): `74.5 + 4 = 78.5 GiB` required vs **~57 GB** available
→ **REFUSES, and that is correct.** See §16 before reading this as a regression.

### 2.3 Learning the real number

At `.admit` the coordinator records `availableAtAdmission`. When the model's health probe first
reports healthy, it records `availableAtHealthy` and stores
`observedHoldBytes = max(0, availableAtAdmission − availableAtHealthy)`, together with the sample
timestamp and the machine's `physicalMemory`. Persisted to
`AppDirectories.applicationSupport(.support)/model-lifecycle/observations.json` (so it survives
relaunch and honours `DAWPRO_PROFILE_ROOT`, which m23-ay made the ONE home for profile roots).

An observation is **discarded** and confidence falls back to `.estimated` when:
* another model's residency changed during the boot window (attribution is not ours), or
* the delta is negative or `< 1 GiB` (the load plainly did not happen the way we think), or
* `physicalMemory` differs from the recorded one (different machine / profile copied).

The refusal and warning messages MUST name the provenance verbatim — *"needs ~34 GiB (estimated
from on-disk checkpoint sizes; never measured resident on this machine)"* vs *"needs ~41.2 GiB
(measured on this machine 2026-08-06)"*. A number whose origin the message hides is a number
nobody can argue with, and this one is a guess.

---

## 3. TYPES — file by file

Naming and shape deliberately mirror `SidecarStopPlanner.swift` / `SidecarProcessDiscovery.swift`
so a reader who knows m23-bb recognises this instantly: **read-only fact gathering → pure planner
→ act**, with every message pure and every decision unit-testable headless.

### 3.1 `Sources/AIServices/ModelMemory.swift` — the metric (NEW)

```swift
/// One home for "how much memory does this machine actually have left, and what
/// is this process tree holding?" — m23-dl.
public enum ModelMemory {

    /// A single `host_statistics64(HOST_VM_INFO64)` sample. Codable so it goes
    /// on the wire verbatim (house "wire never drifts" rule).
    public struct Snapshot: Codable, Sendable, Equatable {
        public var pageSizeBytes: UInt64
        public var physicalBytes: UInt64
        public var internalBytes: UInt64      // anonymous
        public var purgeableBytes: UInt64
        public var wiredBytes: UInt64
        public var compressorBytes: UInt64
        public var freeBytes: UInt64
        public var speculativeBytes: UInt64
        public var externalBytes: UInt64      // file-backed / page cache
        public var sampledAt: Date

        /// Activity Monitor's "Memory Used". THE metric — §0.3 finding 3: the
        /// only one of six that tracked all three allocation shapes correctly.
        public var usedBytes: UInt64 { internalBytes - min(internalBytes, purgeableBytes)
                                       + wiredBytes + compressorBytes }
        /// What admission spends. Deliberately NOT `freeBytes`: measured wrong
        /// for file-backed holds, and noisy by ±0.3 GB at idle.
        public var availableBytes: UInt64 { physicalBytes - min(physicalBytes, usedBytes) }
        /// `vm_stat`'s printed "Pages free" — free MINUS speculative. Exposed only
        /// so a human comparing us to `vm_stat` does not read a 3.4 GB phantom bug.
        public var vmStatFreeBytes: UInt64 { freeBytes - min(freeBytes, speculativeBytes) }
    }

    /// IMPURE (one mach trap, microseconds, no allocation beyond the struct).
    public static func sample() -> Snapshot

    /// PURE — everything above `sample()` is derived, so every threshold in the
    /// planner is testable by constructing a Snapshot directly.
    public static func snapshot(pageSize: UInt64, physical: UInt64, internalPages: UInt64,
                                purgeablePages: UInt64, wirePages: UInt64,
                                compressorPages: UInt64, freePages: UInt64,
                                speculativePages: UInt64, externalPages: UInt64,
                                at: Date) -> Snapshot

    /// ATTRIBUTION ONLY — never decides anything. Sums `proc_pid_rusage`
    /// (RUSAGE_INFO_V4) over `pid` AND every descendant, because for ACE the
    /// pidfile pid is the `uv` supervisor and the python CHILD holds the memory
    /// (§0.4). nil when `proc_pid_rusage` fails (measured: it does, for pids we
    /// do not own).
    ///
    /// ⚠️ `ri_phys_footprint` reports 0.00 GB for a 4 GB file-backed mapping
    /// (measured, §0.3). Both fields are reported; neither may gate a verdict.
    public struct TreeUsage: Codable, Sendable, Equatable {
        public var pids: [Int32]
        public var footprintBytes: UInt64
        public var residentBytes: UInt64
        public var unreadablePids: [Int32]   // rusage failed — honest, not zero
    }
    public static func treeUsage(rootPid: Int32,
                                 snapshot: SidecarProcessDiscovery.Snapshot) -> TreeUsage?
}
```

**Do not** add `task_for_pid`/`TASK_VM_INFO`. Measured `KERN_FAILURE (5)` for foreign pids; it
would need the `com.apple.security.cs.debugger` entitlement — see §9 (Xcode flags).

### 3.2 `Sources/AIServices/ModelRegistry.swift` — N models, no pairwise cases (NEW)

```swift
public struct ModelID: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public static let aceStep = ModelID(rawValue: "ace-step")
    public static let rvc     = ModelID(rawValue: "rvc")
    // m23-dg adds `.musicFlamingo` HERE and nowhere else.
}

public struct ModelDescriptor: Codable, Sendable, Equatable {
    public var id: ModelID
    public var displayName: String            // "ACE-Step song generation"
    public var baseURL: URL                   // port is derived, never hardcoded
    /// PLACEHOLDER until observed. §2.2 — an estimate may WARN, never REFUSE.
    public var estimatedHoldBytes: UInt64
    /// May this model be evicted to make room for another? RVC yes; a model in
    /// the middle of a user-visible job is protected by `activeJobs`, not by this.
    public var isEvictable: Bool
    /// Idle-unload seconds, or nil = never (the default — §6.3, a product decision).
    public var idleUnloadSeconds: Double?
    /// Which manager can actually stop it. Set at registration, not in a literal.
    public var stopVocabulary: SidecarStop.Vocabulary
}

public struct ModelLifecyclePolicy: Codable, Sendable, Equatable {
    public var reserveBytes: UInt64   = 4 << 30
    public var hardFloorBytes: UInt64 = 8 << 30
}
```

There is **no** `ExclusionGroup` and no "large vs small" enum. Mutual exclusion is an *arithmetic
consequence* — if two models do not fit, one is evicted — which is the only formulation that
survives the third model without an edit. An enum would need a new case and a new pairwise
table every time.

### 3.3 `Sources/AIServices/ModelAdmission.swift` — THE PURE PLANNER (NEW)

Zero I/O, zero actor state, mirrors `SidecarStop.resolvePlan` exactly.

```swift
public enum ModelAdmission {

    public struct Resident: Sendable, Equatable {
        public var id: ModelID
        public var holdBytes: UInt64
        public var holdConfidence: Confidence
        public var isEvictable: Bool
        public var activeJobs: Int          // >0 ⇒ never evicted, however tight memory is
        public var admittedAt: Date
        public var lastJobEndedAt: Date?
    }

    public enum Confidence: String, Codable, Sendable, Equatable {
        case measured     // observed on THIS machine for THIS model
        case estimated    // §2.2 — may warn, may never refuse
    }

    /// Everything the decision reasons over. A value type, so the ONE case that
    /// is otherwise only reproducible against a live 34 GiB model — "not enough
    /// memory, and evicting the other model would fix it" — is a unit test.
    public struct Facts: Sendable, Equatable {
        public var request: ModelDescriptor
        public var memory: ModelMemory.Snapshot
        public var observedHoldBytes: UInt64?      // nil ⇒ .estimated
        public var resident: [Resident]
        public var inFlight: InFlight?             // global single-flight, §4.2
        public var policy: ModelLifecyclePolicy
        public var force: Bool
        public var now: Date
    }

    public struct InFlight: Sendable, Equatable {
        public var id: ModelID
        public var since: Date
        public var ticket: UInt64                  // the m23-ah nonce
    }

    public enum Plan: Sendable, Equatable {
        /// Already up and healthy — `start()`'s existing early return. No-op.
        /// ⚠️ Mints NO ticket (§4.1): nothing to boot, nothing to release, and a
        /// ticket minted here would leak a flight slot until the stale timer ran.
        /// ⚠️ NOT DEAD CODE, though it is nearly unreachable from `start()` — which
        /// returns early on `current.state == .healthy` (`SidecarManager.swift:178-179`)
        /// before `resolveAdmission` is ever called. Its live caller is
        /// `wouldAdmitNow` in `ai.modelResidency` (§6.1). Do not delete it.
        case alreadyResident(ModelID)
        /// Boot it. `evicting` may be empty. `projectedAvailableBytes` is what we
        /// PREDICT; §2.3 compares it to what actually happened.
        case admit(evicting: [ModelID], requiredBytes: UInt64,
                   projectedAvailableBytes: UInt64, confidence: Confidence)
        /// Boot it, but say out loud that we are working from a guess (§2.2).
        /// NEVER reachable when `confidence == .measured`.
        case admitUnverified(evicting: [ModelID], estimatedBytes: UInt64,
                             availableBytes: UInt64)
        /// The user said `force: true` over a MEASURED refusal. Boots, and the
        /// message states exactly what it is overriding.
        case admitForced(evicting: [ModelID], requiredBytes: UInt64,
                         availableBytes: UInt64)
        case refuse(Refusal)
    }

    public enum Refusal: Sendable, Equatable {
        /// The user's ask, answered honestly and numerically.
        case insufficientMemory(required: UInt64, available: UInt64,
                                projectedAfterEviction: UInt64,
                                confidence: Confidence,
                                resident: [ModelID], protectedByJobs: [ModelID])
        /// Global single-flight (§4.2). Names WHO and for how long.
        case bootInFlight(ModelID, seconds: Int, ticket: UInt64)
        /// Below `hardFloorBytes` — nothing of this size can work right now.
        case belowHardFloor(available: UInt64, hardFloor: UInt64)
        case unknownModel(String)
    }

    /// PURE. This is the whole decision.
    public static func resolve(_ facts: Facts) -> Plan

    /// PURE messages, one per case. `force` is named in every refusal message so
    /// the escape hatch is discoverable from the failure itself.
    public static func message(for plan: Plan, descriptor: ModelDescriptor) -> String
    public static func refusalMessage(_ r: Refusal, descriptor: ModelDescriptor) -> String
}

extension ModelAdmission.Plan {
    /// True for `.admit`/`.admitUnverified`/`.admitForced`; false for
    /// `.alreadyResident` (nothing to boot) and `.refuse`.
    public var isAdmitted: Bool { get }
    /// The models this plan would evict — empty for every non-admitting case.
    public var evicting: [ModelID] { get }
    /// ALWAYS contains `launch`, in both the admitted and refused forms — the
    /// existing dry-run test asserts on the command line (§7.0).
    public func dryRunMessage(launch: String, descriptor: ModelDescriptor) -> String
}
```

**Ordering inside `resolve` (this order is the design, not an implementation detail):**

1. `inFlight != nil` → `.refuse(.bootInFlight)` — **even if it is the same model**. Two boots of
   the same model is the double-load the user is trying to prevent.
2. `resident` contains `request.id` → `.alreadyResident`.
3. `available < hardFloor` and `!force` → `.refuse(.belowHardFloor)`.
4. Compute `evicting`: evictable residents with `activeJobs == 0`, **largest hold first**, taking
   only as many as the arithmetic needs. A model with `activeJobs > 0` is never evicted and is
   named in `protectedByJobs` so the refusal explains itself.
5. Fits → `.admit`. Else `.estimated` → `.admitUnverified`. Else `force` → `.admitForced`.
   Else `.refuse(.insufficientMemory)`.

**Why "largest first" and not "least recently used":** the goal is to free a specific number of
bytes with the fewest reloads. LRU can evict three small models and still not fit.

### 3.4 `Sources/AIServices/ModelLifecycleCoordinator.swift` — the one actor (NEW)

```swift
public actor ModelLifecycleCoordinator {
    public static let shared = ModelLifecycleCoordinator()

    /// ⭐ THE m23-ah NONCE. Monotonic, never reset, bumped on EVERY residency
    /// transition: admit, healthy, evict, evict-failed, idle-fire. Returned by
    /// every verb and by `ai.modelResidency`. Turns "did this actually unload?"
    /// from inference into observation — two reads with the same `generation`
    /// describe the same world, and an eviction that did not bump it did not
    /// happen.
    private(set) var generation: UInt64 = 0

    public func register(_ descriptor: ModelDescriptor, evictor: ModelEvicting) async
    // ⚠️ TWO methods, never one — §4.1 Rule 2. `resolve` is read-only and safe
    // before the dryRun branch; `commit` mints the ticket AND evicts, so it runs
    // only on the real path. A single `admit()` that did both would let
    // `dryRun: true` SIGTERM the user's live RVC sidecar.
    public func resolveAdmission(_ id: ModelID, force: Bool) async -> ModelAdmission.Plan
    public func commitAdmission(_ plan: ModelAdmission.Plan) async throws -> Ticket
    /// Releases the flight ticket AND records the §2.3 observation. Called from
    /// the manager's own three clearing rules — NEVER from a `defer` (§4.1.1).
    public func admitted(_ ticket: Ticket, healthy: Bool) async
    public func noteJobStarted(_ id: ModelID) async
    public func noteJobEnded(_ id: ModelID) async
    public func unload(_ id: ModelID, reason: EvictionReason) async -> EvictionReport
    public func unloadAll(reason: EvictionReason) async -> [EvictionReport]
    public func residency() async -> ResidencyReport                     // §6.1
}

/// How the coordinator stops something without importing DAWControl or knowing
/// what a sidecar is. Both managers conform and register themselves.
public protocol ModelEvicting: Sendable {
    var modelID: ModelID { get }
    /// MUST NOT call back into the coordinator (§4.3).
    func evictWithoutCoordinator() async throws -> EvictionEvidence
}
```

---

## 4. MECHANISMS

#### 4.1 The precondition lives in `start()` — RESOLVE before the dry-run branch, COMMIT after

Two rules, and they are separate because they fail differently.

**Rule 1 — the DECISION is resolved before the `dryRun` branch.**
`SidecarStopPlanner.swift:686-690` states it: *"The DECISION is shared, so a dry-run can never
describe a different decision than the one the real path would take."* `stop()` already obeys it —
`let plan = await resolvedStopPlan()` at `SidecarManager.swift:299`, **then** `if config.dryRun` at
`:301`. A dry-run that prints `[dry-run] would spawn: …` while the real path would refuse for
memory is exactly the defect m23-bb closed.

**Rule 2 — the ACTION (minting a ticket, evicting a model) happens only AFTER the `dryRun` branch.**
⚠️ This is the correction that matters most: `.admit(evicting: [.rvc])` means *SIGTERM the user's
running RVC sidecar*. If that ran inside a single `admit()` call placed before the `dryRun` branch,
then `dryRun: true` — a mode whose entire contract is "spawn nothing, signal nothing" — would kill
a live sidecar. The hermetic-coordinator seam in §7.0 means **no test would catch it.** `stop()`
already models the split exactly: plan at `:299`, act at `:311`.

So the coordinator exposes **two** methods, never one:

```swift
/// READ-ONLY. host_statistics64 (a mach trap) + SidecarProcessDiscovery
/// (which never signals) + pure ModelAdmission.resolve. Signals nothing,
/// mints nothing, mutates no residency state. Safe before the dryRun branch.
public func resolveAdmission(_ id: ModelID, force: Bool) async -> ModelAdmission.Plan

/// ACTS: mints the flight ticket and performs the evictions the plan names.
/// Called ONLY on the real path, after the dryRun branch has returned.
/// Re-checks single-flight under the actor before minting — the plan may be
/// seconds stale.
public func commitAdmission(_ plan: ModelAdmission.Plan) async throws -> Ticket
```

Shape at `Sources/AIServices/SidecarManager.swift`, replacing lines 176-185:

```
public func start(force: Bool = false) async throws -> SidecarStatus {
    let current = await status();  if current.state == .healthy { return current }
    let launch = try config.resolveLaunchPlan()

    let admission = await config.lifecycle.resolveAdmission(.aceStep, force: force)  // ← READ-ONLY

    if config.dryRun {
        // Describes the SAME decision the real path would take, and performs
        // none of it. Always contains the command line (§7.0).
        return SidecarStatus(state: admission.isAdmitted ? .starting : .error,
                             message: admission.dryRunMessage(launch: launch.commandLine))
    }
    guard admission.isAdmitted else {
        throw SidecarError.admissionRefused(
            ModelAdmission.message(for: admission, descriptor: ModelRegistry.aceStep))
    }
    let ticket = try await config.lifecycle.commitAdmission(admission)   // ← mints + evicts
    ...existing spawn, unchanged...
    // NO `defer { release(ticket) }` — see the ticket-lifetime rule below.
}
```

#### 4.1.2 ⚠️ WHAT HAPPENS WHEN AN EVICTION REFUSES — the branch an implementer will otherwise guess

`commitAdmission` performs the evictions the plan names, and **an eviction can legitimately fail**:
`SidecarStop.resolvePlan` returns `.refuse(...)` whenever the sidecar is demonstrably answering but
nothing safe to signal was found — that is the whole of m23-bb, and §4.4 says such a stop throws
`stopFailed` and mutates nothing. So we planned to free 20 GiB by evicting RVC, RVC refused, and we
hold a flight ticket for a boot whose arithmetic no longer works. Three outcomes are available and
an unspecified branch will be resolved by guessing:

* boot anyway → **over-commit**, i.e. the OOM this item exists to prevent. **Forbidden.**
* throw `launchFailed` → wrong error class; the message blames a launch that never happened.
* **throw `admissionRefused`, naming the eviction that failed and quoting its refusal message.**
  ← this one.

And it is **arithmetic, not all-or-nothing**. If the plan names three evictions and the second
refuses, `commitAdmission` re-samples `ModelMemory` and re-runs the **same pure**
`ModelAdmission.resolve` against what was actually freed. If the boot now fits, proceed; if not,
refuse. Re-running the shared planner — rather than writing a second, simpler sufficiency test
here — is the m23-bb law: two answers to one question is the defect class.

**The ticket is released on every refusal path.** A refusal after minting must not leak a flight
slot; that would wedge all model loading until the §4.2 stale-ticket timer fired.

**Losing the single-flight race inside `commit`.** `commitAdmission` re-checks single-flight under
the actor and re-takes the `flock`, and can lose to another *process* between resolve and commit.
That surfaces as `admissionRefused` carrying `.bootInFlight` — **never** as a launch error, and
never as a silent proceed.

**Which plans mint a ticket:** `.admit`, `.admitUnverified` and `.admitForced` do.
`.alreadyResident` does **not** — there is nothing to boot and nothing to release, and minting one
would leak a flight slot until the stale-ticket timer reclaimed it. `.refuse` throws.

#### 4.1.1 ⚠️ TICKET LIFETIME IS NOT FUNCTION SCOPE — the defect that would defeat single-flight

**`start()` returns while the boot is still in flight.** `SidecarManager.swift:249-259` returns
`.starting` when the 30 s poll window expires without healthy, and the file's own comment at
`:24-26` says model loads *"can legitimately take ~1 min cold, well past the 30s window `start()`
itself blocks for."* So a `defer { release(ticket) }` on a cold ACE boot releases the flight token
at 30 s with 34 GiB still loading — and the next `ai.sidecarStart`, or a Music Flamingo start, is
admitted on top of it. **That is precisely the double-load this item exists to prevent.**

The fix is already written in this codebase for the adjacent problem. `startedAt` is deliberately
**not** cleared on return; it has three explicit clearing rules (`SidecarManager.swift:20-27`):
(a) a health probe observes healthy, (b) the tracked process is found dead, (c) `stop()` runs.
**The flight ticket takes those same three rules.** Concretely:

| ticket released by | trigger |
|---|---|
| (a) `coordinator.admitted(ticket:healthy: true)` | the first `status()` that observes `.healthy` — the manager already detects this at `:46-49` |
| (b) `coordinator.admitted(ticket:healthy: false)` | `runningProcess.isRunning == false`, the same signal that sets `.failedBoot` at `:130-136` and `:226-235` |
| (c) `coordinator.unload(_:reason:)` | any stop of that model |
| backstop | the stale-ticket reclamation in §4.2 — a ticket older than `startupTimeoutSeconds × 4` **whose recorded pid is dead** |

**Who holds the ticket, and who calls `admitted(ticket:healthy:)`.** The manager gains one piece
of actor state — `private var flightTicket: Ticket?` — set by `commitAdmission` and cleared by
whichever rule fires first. The call sites are the ones that already clear `startedAt`:

* **rule (a)** — `status()`, `SidecarManager.swift:46-49`, where `startedAt = nil` already happens
  on a healthy probe (`VoiceConversionManager.swift:77` is the twin);
* **rule (b)** — the dead-child detections at `:130-136` (inside `bootProgress()`) and `:226-235`
  (inline in `start()`'s poll loop); twins at `VoiceConversionManager.swift:142-143` and `:214-215`;
* **rule (c)** — `stop()` at `:318`/`:351`, which now routes through `coordinator.unload`.

⚠️ **`bootProgress()` is a SYNCHRONOUS `private func`** (`SidecarManager.swift:128`,
`VoiceConversionManager.swift:140`). It cannot `await` the coordinator, and the obvious workaround
— `Task { await … }` — is banned two paragraphs below. **Checked, so nobody has to restructure
anything:** `bootProgress()` has exactly ONE caller in each manager (`SidecarManager.swift:65`,
`VoiceConversionManager.swift:95`) and that caller is the async `status()`. So rule (b) is notified
from `status()`, acting on `bootProgress()`'s `.failedBoot` return value; `bootProgress()` itself
stays synchronous and unchanged. `.failedBoot` is reachable from no synchronous-only context.

**Never `defer { Task { await …release(ticket) } }`.** Beyond the lifetime bug, a `Task` inside
`defer` is fire-and-forget: unordered with respect to everything else and outside the actor's
serialisation, so two of them can interleave with a `commitAdmission`.

`force` is a **defaulted** parameter, so `SidecarManaging` conformers and every existing call site
compile unchanged; the protocol gains `func start(force: Bool) async throws -> SidecarStatus` with
a protocol extension supplying `start()` → `start(force: false)`. `VoiceConversionManager.start()`
takes the identical edit at `:177-185` with `.rvc`.

`SidecarError` gains one case — `admissionRefused(String)` — additive, alongside the existing
`.notInstalled/.launchFailed/.stopFailed`.

#### 4.2 Single-flight — GLOBAL, not per-model, and it refuses rather than blocks

**One boot at a time across the whole registry.** Per-model single-flight does not solve the
problem the user named: ACE and Flamingo booting concurrently is the dangerous case, and two
per-model locks both succeed.

*In-process:* the coordinator is an actor; `inFlight: InFlight?` is set inside `admit()` before any
`await`, so two concurrent `admit()` calls cannot both see nil.

*Cross-process:* the app, a staging instance and a gate run are separate processes. A lock file at
`AppDirectories.applicationSupport(.support)/model-lifecycle/flight.lock`, opened `O_CREAT|O_RDWR`
and taken with `flock(fd, LOCK_EX|LOCK_NB)`. `flock` is released by the kernel when the fd closes
or the process dies, so a crashed app cannot wedge the lock — which a pidfile would. The lock file
records `{pid, modelID, ticket, since}` for the message.
⚠️ It resolves under `DAWPRO_PROFILE_ROOT` (m23-ay), so **a staging instance gets its own lock and
cannot serialise against the user's live app** — deliberate, and it must be stated in the file's
header or someone will "fix" it into a global lock and make gate runs block on the user's app.

**Refuse, do not block.** Blocking inside an actor while another boot runs its 30 s health-poll
loop would serialise every `ai.sidecarStatus` behind it. `.refuse(.bootInFlight(id, seconds,
ticket))` names who holds it and for how long; the caller polls. This matches the house rule that a
command never lies about what happened.

**Stale ticket recovery:** a ticket older than `startupTimeoutSeconds × 4` (120 s for ACE) whose
recorded pid is dead is reclaimed, generation bumped, and the reclamation stated in the next
message. A ticket whose pid is *alive* is never reclaimed on a timer — that is the `kill -0`-on-a-
zombie trap in a different costume.

#### 4.3 Eviction re-entrancy — `evictWithoutCoordinator()` is not a naming quirk

`start()` → `admit()` → coordinator evicts RVC → `VoiceConversionManager.stop()` → if that routed
back through the coordinator, we re-enter `admit()`'s actor context. Swift actors are reentrant at
every `await`, so there is no deadlock — there is something worse: residency state observable
mid-mutation and a single-flight flag that can be cleared twice.

So: `ModelEvicting.evictWithoutCoordinator()` performs the raw stop (`SidecarStop`, unchanged) and
returns evidence. **It must not call `admit`, `unload`, `release` or `noteJob*`.** The coordinator
is the only thing that mutates residency, and it does so after `evictWithoutCoordinator()` returns.
The public `ai.sidecarStop` / `vc.sidecarStop` path calls `coordinator.unload(_:reason:)`, which
takes the flight token itself and then calls `evictWithoutCoordinator()` — one home, no recursion.

#### 4.4 "Unloaded" as an observable — authority vs corroboration

⚠️ **Do not gate the verdict on memory.** `availableAtAdmission` is a differential on a shared,
noisy counter across a window that can be minutes long: I measured ±0.3 GB drift between adjacent
idle samples, and in the file-backed run the baseline moved 2.13 GB and **stayed moved after the
child was killed**. Over a real generation job with Chrome and Xcode live it is stale by GBs for
reasons that have nothing to do with the sidecar. A memory-gated verdict reports failed unloads
that did not fail — the "fails for unrelated reasons" class this codebase keeps paying for.

**Authority — any one of these false ⇒ the unload FAILED (`SidecarError.stopFailed`, existing):**
1. `SidecarProcessDiscovery.listeners(onPort:)` returns `.nothingListening`
   (`.unavailable` is NOT success — the m23-az-1 "could not ask ≠ found nothing" law).
2. The health probe is `.unreachable`.
3. No pid in the **pre-kill captured tree** is alive (`SidecarStop` already captures descendants
   before signalling — `SidecarStopPlanner.swift:486-492`).

**Corroboration — reported, never fails the verb:**

```swift
public struct EvictionEvidence: Codable, Sendable, Equatable {
    public var portFree: Bool
    public var probeUnreachable: Bool
    public var treePidsAliveAfter: [Int32]
    public var availableBeforeBytes: UInt64
    public var availableAfterBytes: UInt64
    public var memoryReturnedBytes: Int64          // signed — may legitimately be negative
    public var memoryVerdict: MemoryVerdict
    public var generationBefore: UInt64
    public var generationAfter: UInt64
}
public enum MemoryVerdict: String, Codable, Sendable {
    case returned        // returned >= 0.5 × expected hold
    case partial         // returned > 1 GiB but < 0.5 × expected
    case inconclusive    // below the 1 GiB noise floor, or expected hold unknown
    case notAHold        // expected hold < 1 GiB — file-backed model, nothing WAS held (§0.3)
}
```

The 1 GiB noise floor and the 0.5 factor are grounded in the measured post-kill deltas
(−0.07 GB / +0.12 GB for the two real holds; −2.13 GB for the file case where the cache correctly
stayed warm). `memoryVerdict` is the honest answer to *"did the memory come back?"*; `portFree` +
`treePidsAliveAfter` are the answer to *"did it stop?"*, and only the latter can fail a command.

Sampling: `availableAfterBytes` is taken **after** a settle delay of 1.0 s (the anonymous run
returned to −0.07 GB of baseline within the 2 s I used; 1 s is the floor, and the value is
reported, not asserted, so being early only makes the verdict more conservative).

---

## 5. WHERE EVERY PIECE LIVES (the ONE-home table)

| Question | ONE home | File |
|---|---|---|
| How much memory does this machine have left? | `ModelMemory.Snapshot.availableBytes` | `Sources/AIServices/ModelMemory.swift` (NEW) |
| What is this process tree holding? (attribution only) | `ModelMemory.treeUsage(rootPid:snapshot:)` | same |
| Which models exist, what do they cost, may they be evicted? | `ModelRegistry` / `ModelDescriptor` | `Sources/AIServices/ModelRegistry.swift` (NEW) |
| **May this model load right now?** | `ModelAdmission.resolve(_:)` — **PURE** | `Sources/AIServices/ModelAdmission.swift` (NEW) |
| Who is resident, who is booting, what is the nonce? | `ModelLifecycleCoordinator` (actor) | `Sources/AIServices/ModelLifecycleCoordinator.swift` (NEW) |
| **What should `stop()` do, and is it safe to signal that pid?** | `SidecarStop` — **UNCHANGED, m23-bb** | `Sources/AIServices/SidecarStopPlanner.swift` |
| Who is listening / what is the process tree? | `SidecarProcessDiscovery` — **UNCHANGED** | `Sources/AIServices/SidecarProcessDiscovery.swift` |
| ACE boot | `SidecarManager.start()` — **one edit**, before the `dryRun` branch | `Sources/AIServices/SidecarManager.swift:176-185` |
| RVC boot | `VoiceConversionManager.start()` — the identical edit | `Sources/AIServices/VoiceConversionManager.swift:177-185` |
| Wire | `ai.modelResidency`, `ai.modelUnload` + `force` on the two start verbs | `Sources/DAWControl/Commands.swift` |
| MCP | two new tools + one changed schema | `mcp-server/src/server.ts` |

**Files that must NOT change:** `Sources/DAWCore/*` (stays headless and dependency-free — nothing
here reaches it except `AppDirectories` for the lock/observation paths, which is an existing public
API), `Sources/DAWEngine/*`, `scripts/ace-step/*`, `scripts/rvc/*`, `.env`.

**Real-time safety:** nothing in this design is reachable from the render thread. It allocates,
takes a mach trap, shells out to `/bin/ps` and `/usr/sbin/lsof`, and does file I/O — all of it in
`AIServices`, none of it in `DAWEngine`. ⚠️ Two rules for whoever wires the UI:
`SidecarProcessDiscovery.captureSnapshot()`/`listeners(onPort:)` fork a helper process (tens of ms)
and **must never be called from a `@MainActor` view body or a polling timer on the main actor** —
the moment someone puts "resident model" in a status bar, that is the mistake they will make.
`ModelMemory.sample()` alone (one mach trap, no fork) is cheap enough for a 1 Hz UI poll off the
main actor.

---

## 6. WIRE SURFACE (additive only — nothing renamed, nothing removed)

`Sources/DAWControl/Commands.swift` `allCommands` **171 → 173**.

### 6.1 `ai.modelResidency` — the observable (read)

⚠️ **One optional param, `includeProcessDetail` (default `false`).** `treeFootprintBytes` /
`treeResidentBytes` / `pids` come from `SidecarProcessDiscovery.captureSnapshot()`, which
**forks `/bin/ps`** — tens of milliseconds. §5 anticipates someone polling this at 1 Hz for a
status bar, and that would fork `ps` once a second forever. With the flag `false` (the default)
those three fields are served from the coordinator's last cached snapshot and carry
`processDetailAgeSeconds`; with it `true` a fresh snapshot is taken. `memory` is always fresh —
`ModelMemory.sample()` is one mach trap and costs nothing.

The answer to scope item ④. Also the thing that makes every other verb checkable.

```jsonc
{
  "generation": 42,                       // the m23-ah nonce; bumps on EVERY residency transition
  "sampledAt": "2026-08-06T…",
  "memory": {
    "physicalBytes": 137438953472,
    "usedBytes": 72833204224,             // Activity Monitor "Memory Used"
    "availableBytes": 64605749248,        // what admission spends
    "freeBytes": …, "externalBytes": …, "compressorBytes": …, "wiredBytes": …,
    "vmStatFreeBytes": …                  // so a human can reconcile with `vm_stat`
  },
  "policy": { "reserveBytes": 4294967296, "hardFloorBytes": 8589934592 },
  "inFlight": { "modelId": "ace-step", "seconds": 12, "ticket": 41 },   // or null
  "models": [
    { "modelId": "ace-step", "displayName": "ACE-Step song generation",
      "port": 8001, "state": "resident",         // notInstalled|notRunning|starting|resident|error
      "holdBytes": 44238766080, "holdConfidence": "measured",
      "holdMeasuredAt": "2026-08-06T…",
      "estimatedHoldBytes": 36507222016,
      "treeFootprintBytes": 41…, "treeResidentBytes": 46…, "pids": [49156, 49160],
      "activeJobs": 0, "idleForSeconds": 431, "idleUnloadSeconds": null,
      "wouldAdmitNow": true }                    // dry admission, computed from the SAME planner
  ]
}
```

`wouldAdmitNow` runs `ModelAdmission.resolve` with `force: false` — so the panel and the boot
path can never disagree about whether something fits.

### 6.2 `ai.modelUnload` — the N-model verb

Params: `{ "modelId": "ace-step" }` **or** `{ "all": true }` (exactly one; both/neither is a
teaching error naming the valid model ids, matching the m23-cy pattern the audit praised).
Returns `EvictionEvidence` per model plus `generationBefore`/`generationAfter`. Fails
(`stopFailed`) when the §4.4 *authority* limbs fail; reports `memoryVerdict` either way.

Existing `ai.sidecarStop` and `vc.sidecarStop` are **unchanged in name, params and response** but
re-routed through `coordinator.unload(_:reason: .explicit)` so residency bookkeeping cannot go
stale. Their `SidecarStatus`/`VoiceConversionStatus` responses are untouched — the evidence is
reachable via `ai.modelResidency`'s `generation`.

### 6.3 `force` on the two start verbs

`ai.sidecarStart` / `vc.sidecarStart` gain one optional boolean, `force` (default `false`).
`rejectUnknownKeys([])` becomes `rejectUnknownKeys(["force"], verb:)` at
`Commands.swift:3197` and `:4501`. Additive: every existing caller sends `{}` and behaves exactly
as before *unless* memory is genuinely short.
⚠️⚠️ **`force` GOES ON THE TWO *START* VERBS ONLY — NEVER ON `ai.sidecarStop`.** Checked, not
assumed: `Tests/DAWControlTests/WireHardeningM16ETests.swift:416-423` is a test named
*"ai.sidecarStop rejects a stray param"* whose stray param is literally
`params: ["force": .bool(true)]`, and it asserts the error text contains `'force'`. An agent
adding `force` symmetrically to start **and** stop breaks that test, and the breakage reads as
mysterious rather than as the deliberate collision it is.

Gate corpus checked (`grep -rl` over `scripts/gates/`): **three** gates touch these verbs —
`m18g-sketchpad-honesty.mjs:126` and `m17h-generation-card.mjs` (both poll `ai.sidecarStatus`;
m17h also resolves and kills a pid) and `m23bb1-vc-stop-honesty.mjs:126-159` (drives a LIVE
`vc.sidecarStop` and asserts it fails rather than lying). **None pins a parameter list and none
asserts the dry-run message text** (`grep -rl 'dry-run\|would spawn' scripts/gates/` → zero).
So `force` is safe to add; `m23bb1-vc-stop-honesty.mjs` is the gate that must still pass after
`vc.sidecarStop` is re-routed through the coordinator, and it is the cheapest end-to-end proof
that the re-route did not break stop honesty.

### 6.4 MCP — `mcp-server/src/server.ts`, 174 → 176

Two new tools, `model_residency` (read, exempt from `.strict()` like the other 33 pure reads) and
`model_unload` (wrapper, `.strict()`), plus `force` added to the two existing start tools'
schemas. The MCP tool descriptions must state the honest bit: *"an estimated requirement warns but
never refuses; only a requirement measured on this machine can refuse a boot."* Otherwise an agent
reading a refusal will not know `force` exists.

### 6.5 Idle unload (scope item ②) — DECIDED: ships OFF

**Ship demand-driven eviction only.** When model B requests admission and the arithmetic needs
room, evict A. That needs nobody's policy call, is always correct, and is the leg the user
explicitly asked for (*"unload… when we attempt to load other model"*).

The **timer** (unload N seconds after a job reaches terminal state) is a genuine product
trade-off — a silent 60 s reload penalty against held memory, and firing it while the user is
about to hit Generate again is surprising. Therefore:

* `ModelDescriptor.idleUnloadSeconds` ships as **`nil` (off) for every model**, the plumbing is
  built and tested, and `noteJobStarted`/`noteJobEnded` are wired from `ACEStepClient`'s terminal
  job states.
* ⭐ **USER DECISION 2026-08-05: *"Ship it off, decide later."*** So `idleUnloadSeconds` ships
  `nil` for every model. My recommendation had been (b) on at 600 s for ACE only; it is not taken,
  and nobody should re-litigate it inside this item.
* ⚠️⚠️ **THE OFF STATE MUST BE GENUINELY INERT — this is the part an implementer gets wrong.**
  `idleUnloadSeconds == nil` means **no `Task` is created, no `Task.sleep` is pending, no deadline
  is stored, and `noteJobEnded` schedules nothing.** It does NOT mean a timer with a very large
  interval, and it does NOT mean a timer that fires and then declines to act. A dormant timer is
  still a scheduled wake-up, still a cancellation path that can leak, and still a code path that
  can fire after the actor's state has moved on — all cost and risk for a feature that is off.
  §16.5 makes this a test with both polarities.
* The standing manual rule — kill the ACE sidecar pid-exact after every test that no longer needs
  the model — **remains in force** while this is off. This item is the mechanism that retires it
  when the default flips; it does not retire it yet.

When the timer does fire it MUST bump `generation` and broadcast (`ControlServer.broadcast`,
`Sources/DAWControl/ControlServer.swift:234`) so a model vanishing is observed, not discovered.

---

## 7. TEST STRATEGY

### 7.0 ⚠️ FIRST, THE SEAM — or this item makes every existing sidecar test host-dependent

An admission check that reads the real machine turns `SidecarManagerTests` and
`VoiceConversionManagerTests` into tests whose verdict depends on how much Chrome the developer
has open. Concretely, `Tests/AIServicesTests/SidecarManagerTests.swift:228-238` asserts
`status.state == .starting` for a dry-run start — on a 16 GB CI box `available` would sit below
`hardFloorBytes` and that test would start failing for a reason unrelated to what it tests.

**Therefore the memory sample and the clock are injected, not read, in tests:**

```swift
public actor ModelLifecycleCoordinator {
    public init(policy: ModelLifecyclePolicy = .init(),
                sampleMemory: @Sendable @escaping () -> ModelMemory.Snapshot = ModelMemory.sample,
                now: @Sendable @escaping () -> Date = Date.init,
                lockURL: URL? = nil)          // nil ⇒ AppDirectories-resolved production path
}
```
and `SidecarManager.Configuration` / `VoiceConversionManager.Configuration` each gain
`var lifecycle: ModelLifecycleCoordinator = .shared`. Production behaviour is unchanged; every
test gets a hermetic coordinator with a stubbed snapshot. The existing dry-run test then passes
**unedited**.

**Second guard on that same test:** the dry-run message must retain the launch command line in
*every* branch, because `:233-235` asserts `contains("run.sh")`, `contains(dir.path)` and
`contains("[dry-run]")`. Specify the two forms exactly:
* admitted → `"[dry-run] would spawn: <commandLine> — admission ok (needs ~34.0 GiB estimated; 60.1 GiB available)."`
* refused  → `"[dry-run] would NOT spawn: <commandLine> — admission REFUSED: <refusalMessage>"` with state `.error`, matching `SidecarStop.dryRunReport`'s precedent.

### 7.1 MANDATORY pure tests (no allocation, no sidecar, milliseconds)

`Tests/AIServicesTests/ModelAdmissionTests.swift` (NEW):

| # | Test | Assert |
|---|---|---|
| 1 | **The refusal.** Facts: `available = 20 GiB`, required 34 GiB **measured**, no evictable residents | `.refuse(.insufficientMemory(required:available:…))` |
| 2 | **The anti-vacuity twin.** Identical Facts, `available = 90 GiB` | `.admit(evicting: [])` — without this, #1 passes for the wrong reason (the m23-ee `[].every()` class) |
| 3 | **An estimate may not brick.** Identical to #1 but `confidence == .estimated` | `.admitUnverified`, **not** `.refuse` — this is §2.2's whole point |
| 4 | **Eviction arithmetic.** `available = 20 GiB`, required 34 GiB, RVC resident holding 20 GiB, evictable | `.admit(evicting: [.rvc])`, `projectedAvailableBytes == 40 GiB` |
| 5 | **A busy model is never evicted.** Same as #4 with `activeJobs = 1` on RVC | `.refuse(.insufficientMemory(protectedByJobs: [.rvc]))` |
| 6 | **Largest-first.** three evictable residents 5/25/5 GiB, need 20 GiB | evicts the 25 GiB one **only** — one reload, not three |
| 7 | **Hard floor.** `available = 2 GiB`, `force = false` | `.refuse(.belowHardFloor)` |
| 8 | **Force overrides a measured refusal.** #1 with `force = true` | `.admitForced` |
| 9 | **Single-flight beats everything**, including `alreadyResident` and `force` | `.refuse(.bootInFlight)` |
| 10 | **Third model needs no planner edit.** register a synthetic `ModelID("music-flamingo")`, run #4's scenario | passes with zero changes to `ModelAdmission.swift` — the N-model claim, asserted |
| 11 | Every `Refusal` case produces a message naming `force` | so the escape hatch is discoverable from the failure |

`Tests/AIServicesTests/ModelMemoryTests.swift` (NEW): pure-derivation tests for
`usedBytes`/`availableBytes`/`vmStatFreeBytes` from a hand-built Snapshot, incl. the file-backed
shape (high `externalBytes`, unchanged `usedBytes`) and saturation (`purgeable > internal` must not
underflow — these are `UInt64`).

### 7.1b THE TWO TESTS THAT GUARD F14 AND F15 (the defects a structural review missed)

`Tests/AIServicesTests/ModelLifecycleCoordinatorTests.swift` (NEW). Neither needs a sidecar; both
use the §7.0 hermetic coordinator with a **spy evictor** that records calls and stops nothing.

**T-A — `dryRun: true` evicts NOTHING (guards F15).** Register a resident, evictable RVC holding
20 GiB; stub `availableBytes` at 20 GiB so the plan is `.admit(evicting: [.rvc])`; call
`SidecarManager(configuration: .init(…, dryRun: true)).start()`.
Assert: the spy's `evictWithoutCoordinator()` was called **zero** times; residency still lists RVC;
no ticket was minted (`inFlight == nil`); **and** the returned message still names the eviction the
real path would perform, plus `run.sh` and `[dry-run]`.
*Anti-vacuity twin:* the identical scenario with `dryRun: false` must call the spy **exactly once**
— otherwise T-A passes because eviction is broken everywhere.

**T-B — the ticket outlives a `.starting` return (guards F14).** Point the manager at a port
nothing answers, with `startupTimeoutSeconds` ~0.2 s so `start()` returns `.starting` rather than
throwing. Assert in order:
1. `start()` returned `.starting`;
2. `coordinator.residency().inFlight != nil` — **the ticket is still held**. This is the assertion
   a `defer`-released implementation fails, and it is the whole point of the test;
3. a second `start()` (and a start of the *other* model) → `.refuse(.bootInFlight)` naming the
   holder and its elapsed seconds;
4. `await coordinator.admitted(ticket, healthy: true)` → `inFlight == nil`, `generation` bumped;
5. now the second start proceeds — the anti-vacuity twin, without which step 3 could pass because
   nothing ever admits.
6. Separately: with the clock stub advanced past `startupTimeoutSeconds × 4` and the recorded pid
   **dead**, the stale-ticket rule reclaims it; with the pid **alive**, it does not. That second
   half is the `kill -0`-on-a-zombie trap stated as a test.

### 7.2 THE POSITIVE CONTROL FOR THE METRIC ITSELF

Without this, a `ModelMemory.sample()` that returns zeros passes every test in §7.1.

`Tests/AIServicesTests/ModelMemoryLiveTests.swift` (NEW):
allocate 2 GiB with `mmap(MAP_ANON)`, **touch every page** (untouched pages move nothing — this
is the step that makes it a real control), sample, `munmap`, sample again.
Assert `availableBytes` fell by **≥ 1 GiB** while held, and recovered to within 1 GiB after.
⚠️ **Guard on AVAILABLE memory at sample time, NOT on `physicalMemory`.** Skip the test when
`ModelMemory.sample().availableBytes < 8 GiB`. A total-RAM guard is the wrong check and it is the
one an implementer will write: this very 128 GB machine sits at **~57 GB available** and can drop
far lower under the user's workload (§16.2), so `physicalMemory >= 16 GiB` would happily allocate
2 GiB into a machine that is already compressing — a test that degrades the machine it is
measuring. **The same guard applies to §7.3's 2 GiB helper.**
Grounded in my measurement: an 8 GiB anonymous hold moved `available` by 8.19 GB and released to
within 0.26 GB; idle drift between adjacent samples is ±0.3 GB, so 2 GiB / 1 GiB is well outside
noise. Harness proven at `scratchpad/allocctl.swift`.

### 7.3 THE POSITIVE CONTROL FOR "UNLOADED" — it must be able to FAIL

⚠️ **ACE IS NEVER STARTED.** Use the m23-bb trick (`docs/ROADMAP.md:508`): a fake `/health`
responder. `Tests/AIServicesTests/ModelEvictionEvidenceTests.swift` (NEW), on an **ephemeral
port**, never 8001/8002/17600:

0. **Same availability guard as §7.2** — skip when `availableBytes < 8 GiB`; do not gate on
   `physicalMemory`.
1. Spawn a helper that binds the port, answers ACE's `{"data":{…}}` envelope, and holds 2 GiB
   touched.
2. Run the verification with the helper **alive** → assert `portFree == false`,
   `probeUnreachable == false`, `treePidsAliveAfter` non-empty → **the check FAILS. This is the
   positive control.** A verification that cannot produce this result is vacuous.
3. Stop the helper via the real `SidecarStop` path.
4. Re-verify → `portFree == true`, `probeUnreachable == true`, `treePidsAliveAfter == []`.
5. Assert `memoryReturnedBytes` is **present and finite** and `memoryVerdict` is one of the enum
   cases — **do NOT assert a threshold** (§4.4: it is corroboration, not authority; asserting it
   is how the suite starts failing because someone opened Chrome).
6. Assert `generationAfter > generationBefore`.

### 7.4 THE ONE-SHOT DIAGNOSTIC THAT SETTLES THE 75 GB QUESTION

§0.4/§2.1 leave the mechanism UNVERIFIED because booting ACE is forbidden this cycle. Rather than
guess forever, the coordinator writes, on **every** admission and eviction, a full row to
`AppDirectories.applicationSupport(.support)/model-lifecycle/observations.json`:
`{modelId, phase: admit|healthy|evict, generation, full ModelMemory.Snapshot (all nine counters),
TreeUsage (footprint + resident + pids), wallClock}`.

The first real ACE boot then answers, from data and without a special session:
* is the hold in `internalBytes` (a real hold) or `externalBytes` (reclaimable cache)? — settles
  §2.1's mmap+copy hypothesis;
* does `treeFootprintBytes` under-report the way the 4 GB file test did? — settles §0.3;
* what is the true `observedHoldBytes`, replacing the 34 GiB placeholder.

**Follow-up item to file:** *"m23-dl-2: replace ACE's estimated 34 GiB with the measured value from
`observations.json` after the first real generation run."*

### 7.5 Wire + MCP tests

* `Tests/DAWControlTests/ModelLifecycleCommandTests.swift` (NEW) — `ai.modelResidency` shape;
  `ai.modelUnload` with `modelId`, with `all`, with **both** and with **neither** (teaching error
  naming the valid ids, the m23-cy pattern); unknown key still rejected.
* Extend `Tests/DAWControlTests/SidecarCommandTests.swift` and
  `VoiceConversionCommandTests.swift` — `force: true` accepted, `force: "yes"` rejected, `{}`
  behaves exactly as before. `FakeSidecarManager` (`SidecarCommandTests.swift:11`) and
  `FakeVoiceConversionManager` (`VoiceConversionCommandTests.swift:13`) need the new
  `start(force:)` signature; the protocol extension default keeps their existing `start()` valid.
* MCP suite: 318 → 320+; the two new tools' schemas and the `force` addition.

### 7.6 Counts and artefacts that rot silently — REQUIRED follow-ups

* `allCommands` **171 → 173** — ⚠️ **DECOMPOSE the count, never eyeball it.** `allCommands` is a
  bare `[String]` so `Command(`-shaped patterns return a confident 0 and a naive quoted-string
  count returns 172 off a comment inside the array; cross-check via
  `rejectUnknownKeys(…, verb:)` occurrences.
* MCP **174 → 176** (wrapper vs the 33 deliberately-exempt pure reads — `model_residency` joins
  the reads, so 141 → 142 wrappers and 33 → 34 direct).
* `dist/DAWPro.app` and `claude-plugin/server/index.mjs` **both rot with no gate** after any wire
  growth. Rebuild both and re-verify in-binary.
* `docs/ARCHITECTURE.md` command totals are PROSE and nothing greps them — they have gone stale
  twice. Update the headline AND the per-row figures.
* Full suite backgrounded (~90 s), `./scripts/test.sh`, and **grep `✘` anywhere, not line-start —
  the wrapper exits 0 on a failed run.** Baseline to beat: 5006 tests / 520 suites, zero ✘.

---

## 8. FAILURE MODES (what this design can still get wrong)

| # | Failure | Why it happens | Mitigation in this design |
|---|---|---|---|
| F1 | **The check refuses ACE on a healthy machine** | the 75 GB figure double-counts reclaimable page cache (§2.1) | an `.estimated` requirement may only WARN (§2.2); `force`; the placeholder is 34 GiB not 75 GiB; §7.4 replaces it with a measurement |
| F2 | **Existing tests become host-dependent** | the planner reads real machine memory | the injected `sampleMemory`/`now` seam (§7.0) — this is the single most likely way this item breaks the suite |
| F3 | **"Unloaded" reported for a still-resident model** | `kill -0` on a zombie; `ps` on the `uv` parent | authority = port free + probe unreachable + **captured-tree** liveness (§4.4); tree, never the pidfile pid (§0.4) |
| F4 | **"Unload failed" reported for a clean unload** | memory-gated verdict on a noisy shared counter | memory is corroboration only, never fails the verb (§4.4) |
| F5 | **Double load** | two `admit()` seeing `inFlight == nil` | actor-serialised set before any `await`, plus a cross-process `flock` (§4.2) |
| F6 | **A crashed app wedges the lock forever** | pidfile-style locking | `flock` is released by the kernel on fd close/process death; the stale-ticket rule never reclaims a lock whose pid is alive (§4.2) |
| F7 | **Eviction re-entrancy corrupts residency** | `stop()` routing back through the coordinator | `evictWithoutCoordinator()` is documented as forbidden from calling back (§4.3) |
| F8 | **Evicting a model mid-job** | eviction driven purely by arithmetic | `activeJobs > 0` is an absolute veto; the model appears in `protectedByJobs` in the refusal |
| F9 | **A staging gate run blocks on the user's live app** | one global lock file | the lock resolves under `DAWPRO_PROFILE_ROOT` (m23-ay), so staging gets its own — **deliberate, and stated in the file header** |
| F10 | **Learned footprint is garbage** | another model loaded during the window; a different machine | observations discarded on concurrent residency change, on `< 1 GiB` or negative deltas, and on `physicalMemory` mismatch (§2.3) |
| F11 | **Someone adds `task_for_pid` "for better numbers"** | it looks like the obvious API | measured `KERN_FAILURE (5)`; §3.1 and §9 say do not, and why |
| F12 | **A UI poll forks `ps`/`lsof` on the main actor** | "show the resident model" is the obvious next feature | §5 states the rule; `ModelMemory.sample()` (one mach trap) is the cheap path |
| F13 | **Idle unload surprises the user mid-session** | a timer nobody asked for | ships **off**; the decision is offered, not taken (§6.5) |
| F14 | **Single-flight defeated on exactly the ACE case** | `start()` returns `.starting` at 30 s while a cold load runs on past 60 s (`SidecarManager.swift:249-259`, `:24-26`), so a scope-lifetime ticket is released mid-boot and the next start is admitted on top | ticket lifetime = the manager's own three clearing rules, never `defer` (§4.1.1) |
| F15 | **`dryRun: true` kills the user's live RVC** | eviction folded into a single `admit()` placed before the `dryRun` branch | `resolveAdmission` (read-only) / `commitAdmission` (acts) split, §4.1 Rule 2 — ⚠️ the §7.0 hermetic seam means no test catches this; it is a review item |
| F16 | **`force` added to `ai.sidecarStop` too** | symmetry looks right | `WireHardeningM16ETests.swift:416-423` uses `force` as its stray-param probe against that exact verb (§6.3) |
| F17 | **`ai.modelResidency` forks `ps` once a second** | a status-bar poll | `includeProcessDetail` defaults `false`; cached snapshot + age (§6.1) |
| F18 | ⚠️ **A memory refusal presents as a SILENT 15-MINUTE HANG on Generate** | `DAWProApp.swift:2726` swallows the throw with `try?`, then `:2729-2738` polls for 15 min treating `.installedNotRunning` as keep-waiting; the failure card then quotes the ORIGINAL unreachable error, not the refusal | §15 in full — refusal recorded on the coordinator and rendered into `status().admission`, `EnsureSidecar` widened past `Bool`, checked BEFORE the deadline loop. **Phase 3 must not land without Phase 3b** |
| F19 | **Auto-start forces itself past a refusal** | `force` looks like the obvious way to keep generate working | the auto-start path may NEVER force (§15.5), and §15.6 test 7 asserts it |
| F20 | **Generate button stays enabled under a refusal** | `SketchpadModel.canGenerate` treats `.installedNotRunning` as usable (`SketchpadModel.swift:87-92`) | `canGenerate` reads `admission?.refused` (§15.4c), with the both-polarities twin in §15.6 test 3 |
| F21 | ⚠️ **ACE's seeded 74.5 GiB can never self-correct** | the §2.3 observation recorder is wired only to `.admit`, but on this desktop the first real boot arrives via `force: true` (`.admitForced`) — so no observation is ever taken and the seeded figure is frozen forever | record the observation on **`.admitForced` and `.admitUnverified` too**, not just `.admit` (§16.5 test 6). Name it in Phase 2 |
| F22 | **The shortfall figure is dropped as redundant** | it looks derivable from the other two numbers | it is the only clause that tells the user *when to stop closing apps*; §16.5 test 3 asserts on it specifically |
| F23 | **"Off" idle unload is a dormant timer** | `idleUnloadSeconds = .greatestFiniteMagnitude` looks equivalent | it is not: a scheduled wake-up, a cancellation path that can leak, and a code path that can fire after actor state moved on. §6.5 + §16.5 test 5 assert zero wake-ups created |

---

## 9. ALTERNATIVES CONSIDERED, AND WHY THEY LOSE

**The decision:** *system-wide `available` (Activity-Monitor "Memory Used") as the authority for
admission; port + captured-process-tree liveness as the authority for eviction; per-process
footprint demoted to attribution.*

**Alternative A — per-process `phys_footprint` as the authority** (the obvious design: ask the
sidecar how much it holds). **Loses on measurement:** a 4 GB file-backed mapping is charged
**0.00 GB** of footprint (§0.3), and `safetensors` mmaps checkpoints by default, so a mmap-loaded
ACE would report as holding nothing — the manager would happily admit a second large model on top
of it. It also loses on reachability for the richer variant: `task_info(TASK_VM_INFO)` needs
`task_for_pid`, measured `KERN_FAILURE`. Kept as a *reported* field precisely because it is
diagnostic gold (a footprint far below resident is the fingerprint of a mmap'd model), but it
decides nothing.

**Alternative B — a fixed exclusion table ("only one large model at a time")**. Simplest possible
mutual exclusion, no memory metric needed, and it does satisfy the literal ask. **Loses on the
third model and on honesty:** it needs a new pairwise rule for every model added (the roadmap
names this failure explicitly), it cannot answer the user's actual question *"do we have enough
memory?"*, it evicts ACE to load RVC even when 60 GB is free, and it has nothing to say when a
single model does not fit by itself. Arithmetic subsumes it: with real numbers, "two large models
do not fit" falls out without a table.

**Also rejected:** `free_count`/`vm_stat` (measured wrong for file-backed, ±0.3 GB noisy, and does
not recover after a file-backed process exits); `kern.memorystatus_level` (undocumented, formula
not reproducible); `os_proc_available_memory` (current-process jetsam headroom, not the system's);
per-model rather than global single-flight (does not stop the ACE+Flamingo case, which is the one
that matters).

---

## 10. IMPLEMENTATION PLAN — ordered, each step independently testable

**Phase 1 — the metric and the planner (no behaviour change, nothing wired).**
1. `Sources/AIServices/ModelMemory.swift` + `Tests/AIServicesTests/ModelMemoryTests.swift`
   (pure) + `ModelMemoryLiveTests.swift` (§7.2 positive control). **Land and run this alone** —
   if `availableBytes` does not move by ≥ 1 GiB under a touched 2 GiB allocation, stop; nothing
   downstream is worth building.
2. `Sources/AIServices/ModelRegistry.swift` — descriptors for `.aceStep` and `.rvc` only.
   Ports come from the managers' `baseURL`; **hardcode no port.**
3. `Sources/AIServices/ModelAdmission.swift` + `ModelAdmissionTests.swift` (§7.1, all 11).
   Still nothing calls it.

**Phase 2 — the coordinator, still not wired to a boot.**
4. `Sources/AIServices/ModelLifecycleCoordinator.swift`: registration, residency bookkeeping,
   the `generation` nonce, in-process single-flight, `flock` cross-process lock, observation
   persistence (§2.3) and the §7.4 diagnostic rows.
5. `ModelEvicting` conformance on `SidecarManager` and `VoiceConversionManager` —
   `evictWithoutCoordinator()` wrapping the **existing, unchanged** `stop()` internals. No
   change to `SidecarStop`.
6. `ModelEvictionEvidenceTests.swift` (§7.3) — the fake-`/health`-plus-2 GiB helper on an
   ephemeral port. **Get the FAILING case (step 2 of §7.3) green before the passing one.**

**Phase 3 — wire the precondition (the first behaviour change).**
7. `SidecarManager.start(force:)` — `resolveAdmission` **before** the `dryRun` branch,
   `commitAdmission` **after** it (§4.1 Rules 1 and 2), `SidecarError.admissionRefused`, and the
   ticket released by the three clearing rules — **never by `defer`** (§4.1.1). Add `lifecycle`
   to `Configuration`.
8. Same edit in `VoiceConversionManager.start(force:)`.
9. `SidecarManaging` / `VoiceConversionManaging` gain `start(force:)` with a protocol-extension
   default. Update the two fakes.
10. Re-run the full suite. **The dry-run test at `SidecarManagerTests.swift:228` is the canary.**

**Phase 4 — the wire.**
11. `ai.modelResidency`, `ai.modelUnload` in `Sources/DAWControl/Commands.swift`; `force` on the
    two start verbs; re-route `ai.sidecarStop`/`vc.sidecarStop` through `coordinator.unload`.
12. `Tests/DAWControlTests/ModelLifecycleCommandTests.swift` + the extensions in §7.5.
13. `mcp-server/src/server.ts` — two tools + two schema additions; MCP suite.
14. Counts, `dist/DAWPro.app`, `claude-plugin/server/index.mjs`, `docs/ARCHITECTURE.md` (§7.6).

**Phase 5 — idle (plumbing only).**
15. `noteJobStarted`/`noteJobEnded` from `ACEStepClient`'s terminal job states; the timer built,
    tested, and **shipped off** (`idleUnloadSeconds = nil`). Broadcast + generation bump when it
    fires. Do not enable it without the user's word (§6.5).

**Routing.** Phases 1-3 are `daw-architect` / `audio-dsp-engineer`-grade reasoning about
accounting and concurrency — route to an **opus** agent. Phase 4 is well-specified wire plumbing:
`mcp-integration-engineer` (sonnet). Phase 5 needs the decision first.

---

## 11. FULL-XCODE / ENTITLEMENT FLAGS

* **Nothing in this design needs full Xcode, entitlements, signing or AUv3.** Every API used
  (`host_statistics64`, `proc_pid_rusage`, `flock`, `Process`) works from a plain SwiftPM build
  under Command Line Tools. Verified by running all of them from `swiftc`-built binaries during
  this design pass.
* **The one thing that WOULD need an entitlement is explicitly designed out:**
  `task_for_pid`/`task_info(TASK_VM_INFO)` on a foreign process requires
  `com.apple.security.cs.debugger` plus a signed hardened-runtime binary. Measured
  `KERN_FAILURE (5)` without it. **Do not add it.** If a future cycle wants it, that is a signing
  and provisioning change, and it collides with the standing decision that DAW Pro ships ad-hoc
  signed for local use only.
* `Sources/DAWCore` gains nothing and keeps no new dependency; `DAWEngine` is untouched.

---

## 12. DECISIONS — ALL THREE NOW SETTLED (2026-08-05)

**Nothing in this design is left waiting on the user.** All three are closed:

1. ~~Idle unload after a job finishes~~ → **USER DECISION: *"Ship it off, decide later."*** The
   timer and its policy are BUILT and TESTED; `idleUnloadSeconds` ships `nil` for every model and
   the off state must be **genuinely inert** — no `Task` scheduled, no interval, no behaviour
   change — never a timer with a large interval (§6.5, §16.5). The standing manual rule (kill the
   ACE sidecar pid-exact after every test that no longer needs the model) **stays in force**
   meanwhile, and this item is the mechanism that will retire it once the default flips.
2. ~~Should a refusal ever be silent-auto-forced?~~ → **DEFAULT TAKEN, CONFIRMED: never.** `force`
   stays an explicit act by the user or an agent. Silently overriding a memory guard would
   recreate the m23-bb shape — a verb doing something other than what it reports. Asserted by
   §15.6 test 7 (auto-start never forces) and by §16.4's message contract.
3. ~~ACE's 34 GiB placeholder~~ → **RESOLVED BY MEASUREMENT, NOT BY CHOICE.** The placeholder is
   **dropped**; ACE ships a seeded `.measured` hold of 74.5 GiB from two independent observations
   (§16.1). No invented number remains anywhere in this design.

---

## 13. `docs/ARCHITECTURE.md` — "Key future decisions" entry to add on landing

> ⚠️ **§16.6 REPLACES TWO CLAUSES IN THE BLOCK BELOW.** Apply §16.6 before pasting this into
> `docs/ARCHITECTURE.md`, or the entry will ship the pre-measurement framing of ACE's hold.

> **Local model lifecycle (m23-dl, settled 2026-08-05).** Admission for local model sidecars turns
> on **system-wide available memory** — `physicalMemory − (internal − purgeable + wired +
> compressor)`, i.e. Activity Monitor's "Memory Used" — sampled with one
> `host_statistics64(HOST_VM_INFO64)` call from `AIServices/ModelMemory.swift`. Per-process
> `phys_footprint` is **attribution only**: it reports 0 bytes for file-backed (mmap'd) model
> weights, measured. `task_for_pid`/`TASK_VM_INFO` is unreachable without the debugger entitlement
> and is deliberately not used. "Unloaded" is an observable with three authoritative limbs — port
> free, health probe unreachable, no pid alive in the **pre-kill captured tree** — and memory
> return is reported as corroboration but never fails a verb. Mutual exclusion between models is
> **arithmetic, not a pairwise table**, so a third model needs no planner change; boots are
> serialised by one global single-flight (in-process actor state + a `flock`ed file under
> `DAWPRO_PROFILE_ROOT`). A requirement that was only *estimated* may warn but may never refuse —
> only a hold measured on this machine can refuse a boot, and `force: true` overrides even that.
> One monotonic `generation` counter, returned by every lifecycle verb, makes "did it actually
> unload?" observable rather than inferred (the m23-ah nonce pattern). A refusal is **both**
> thrown (`SidecarError.admissionRefused`, so the wire answers `ok: false`) **and** recorded on the
> coordinator and rendered into `SidecarStatus.admission` — because two of the five `start()` call
> sites are app-side `try?` auto-start paths that structurally cannot see a throw, and a swallowed
> refusal there becomes a 15-minute silent hang on Generate.

---

## 15. REFUSAL OBSERVABILITY — the three ACE doors, two of which swallow errors

**Added after §0.6 item 1 was retracted.** Everything in §0-§13 stands; this section is the
correction, and it is **mandatory reading before Phase 3** (§10 step 7). Without it, m23-dl ships a
regression that is worse than the bug it fixes.

### 15.1 THE DEFECT: an out-of-memory refusal presents as a silent 15-minute hang

Walk `Sources/DAWApp/DAWProApp.swift:2725-2740` (`ensureSidecar`, the m17-h auto-start that every
Sketchpad generate runs through) with a refusal in it:

```
if let started = try? await sidecarManager.start(), started.state == .healthy { return true }
let deadline = Date().addingTimeInterval(15 * 60)
while Date() < deadline {
    let probe = await sidecarManager.status()
    switch probe.state {
    case .healthy: return true
    case .notInstalled, .error: return false
    case .starting, .installedNotRunning: break        // ← keep waiting
    }
    try? await Task.sleep(nanoseconds: 2_000_000_000)
}
return false
```

1. `start()` throws `admissionRefused`. **`try?` discards it to `nil`** — the reason is gone.
2. The loop is entered. `status()` health-probes the port; ACE is installed and not running, so it
   returns **`.installedNotRunning`** — which the switch treats as *keep waiting*.
3. It polls every 2 s **for fifteen minutes**, then returns `false`.
4. `GenerationPresenceModel.handleSubmitError` (`Sources/DAWAppKit/GenerationPresenceModel.swift:762-767`)
   then registers a failure whose reason is `verbatimReason(error)` where `error` is the **original
   unreachable error**, not the refusal. The user is told the sidecar was unreachable.

So the user presses Generate, waits 15 minutes, and is told the wrong thing. That is the m23-bb
defect class exactly — a verb that fails while reporting something else — and it is strictly worse
than today, where the boot simply succeeds.

⚠️ **`.error` returning `false` does NOT save this.** Even if `start()` returned a
`SidecarStatus(state: .error)` instead of throwing, the loop's first act is a **fresh `status()`
probe**, which knows nothing about the refusal and answers `.installedNotRunning`. The status
returned by `start()` is discarded unless it is `.healthy`. **The fix cannot live only in the
return type; the refusal must be reachable from `status()`.**

`Sources/DAWApp/DAWProApp.swift:6629-6635` (the banner Start button) is the milder twin: `try?` →
`nil` → `refreshSketchpadSidecar()` → an unchanged `.installedNotRunning` banner reading *"press
Start to launch it now"*, with no hint that Start just refused and why.

### 15.2 DECISION — throw **and** record; the record is what `status()` renders

**Both shapes, one source of truth.** Neither alone is sufficient, and the reasons are independent:

* **Throw `SidecarError.admissionRefused(String)`.** Required for the wire. `ai.sidecarStart`
  (`Commands.swift:3198`) uses `try await`, so a throw becomes `ok: false` with the reason —
  the honest wire shape. Returning a success-shaped `SidecarStatus` carrying an error state would
  be *"a success-shaped response to a request that did not happen"*, the exact family m23-ah
  closed and `SidecarError.stopFailed` was created to avoid (`SidecarStatus.swift:93-100`).
* **Record the refusal on the coordinator, and render it into `status()`.** Required for the two
  `try?` callers, which structurally cannot see a throw. This is what makes the *existing*
  fallback path correct instead of requiring it to be rewritten.

The **ONE home** is the coordinator's refusal record — the same object both shapes read, so the
thrown message and the status field can never disagree:

```swift
/// Additive optional field on the EXISTING wire types. The key is ABSENT — not
/// null — whenever there is no current refusal, so every existing client, gate
/// and the `dist/` bundle sees a byte-identical payload. MEASURED, not assumed:
/// see the note directly below.
public struct AdmissionSummary: Codable, Sendable, Equatable {
    public var refused: Bool
    public var reason: String            // the verbatim planner message
    public var requiredBytes: UInt64
    public var availableBytes: UInt64
    public var confidence: ModelAdmission.Confidence
    public var evictionBlockedBy: [ModelID]   // models held by active jobs
    public var canRetryWithForce: Bool        // false for .belowHardFloor without force
    public var refusedSecondsAgo: Int
    public var generation: UInt64
}
```

* `SidecarStatus.admission: AdmissionSummary?` — additive (`SidecarStatus.swift:19-64`).
* `VoiceConversionStatus.admission: AdmissionSummary?` — the twin, additive.

**⭐ The "absent, not null" claim is MEASURED (2026-08-05), because §15.6 test 6 asserts on it.**
`SidecarStatus` reaches the wire through `try JSONValue(encoding: sidecarStatus)`
(`Commands.swift:3180`), **not** a bare `JSONEncoder` — so nil-omission is a property of
`JSONValue.init(encoding:)`, which I read rather than assumed:
`Sources/DAWControl/JSONValue.swift:57-62` is `JSONEncoder()` (+ `.iso8601` dates) →
`Data` → `JSONDecoder().decode(JSONValue.self, from:)`. A key absent from the intermediate `Data`
cannot appear in the decoded `JSONValue`. I then reproduced the encoder half directly on a struct
of `SidecarStatus`'s exact shape (`scratchpad/niltest.swift`):

```
no refusal  {"message":"not running","state":"installedNotRunning"}      hasAdmissionKey=false
refusal     {"admission":{…},"message":"refused","pid":42,"state":"error"} hasAdmissionKey=true
```

Synthesized `Codable` emits `encodeIfPresent`, so nil optionals produce **no key at all**.
Corroboration from production: `SidecarStatus` **already** ships six optionals through this exact
path (`version`, `ditModel`, `lmModel`, `pid`, `phase`, `startingForSeconds`) and today's
not-running payload carries none of them. ⚠️ This holds only while `SidecarStatus` keeps its
**synthesized** encoding — a hand-written `encode(to:)` using `encode` instead of `encodeIfPresent`
would materialise `null` keys and silently break additivity.

**Freshness rule (the coordinator's, computed once, never at a call site).** The field is populated
only when the coordinator's refusal record for that model is **(a)** newer than that model's last
successful admission, **(b)** newer than its last successful boot or unload, and **(c)** less than
**120 s** old. A stale refusal reported as current would be its own lie. `refusedSecondsAgo` is
carried so a consumer can be stricter, never looser.

### 15.3 `EnsureSidecar` must stop being a `Bool`

`Sources/DAWAppKit/GenerationPresenceModel.swift:627` declares
`public typealias EnsureSidecar = @Sendable () async -> Bool`. **A Bool cannot carry a reason —
the defect is encoded in the type.** Widen it:

```swift
public enum SidecarBootOutcome: Sendable, Equatable {
    case healthy
    /// Today's `false`: timed out, not installed, or a boot that failed.
    case gaveUp(reason: String?)
    /// NEW — TERMINAL. Admission refused; this will never become healthy by
    /// waiting, so the caller must stop waiting immediately.
    case refused(AdmissionSummary)
}
public typealias EnsureSidecar = @Sendable () async -> SidecarBootOutcome
```

This is an internal Swift signature, not a wire verb — the additive-only law governs the control
protocol, not `DAWAppKit` typealiases. It has exactly **two** definition/use sites
(`GenerationPresenceModel.swift:627,632,639` and `DAWProApp.swift:2725`) plus test constructions in
`Tests/DAWAppKitTests/` that pass `{ true }`; those become `{ .healthy }`.

*Cheaper alternative, recorded and rejected:* keep `-> Bool` and have `handleSubmitError` re-probe
`status()` for `.admission` when it gets `false`. It works (the field exists either way) but it
costs a second round-trip, races the freshness window, and leaves the type still lying. Take the
enum.

### 15.4 The three edits that make a refusal visible

**(a) `ensureSidecar` — `DAWProApp.swift:2725-2740`.** Two changes:

⚠️ **`startCapturingRefusal()` is a THIN NON-THROWING WRAPPER over the same `start(force:)` — not
a second boot path.** The name reads like a parallel implementation and a second implementation
would be the m23-bb defect class (two answers to one question) in a new costume. It calls
`try await start(force: false)`, catches **only** `SidecarError.admissionRefused` and maps it to
`.refused(summary)` (reading the summary off the coordinator's refusal record, the same one
`status()` renders); every other error maps to `.gaveUp(reason: error.localizedDescription)`. No
second decision, no second spawn, no duplicated dry-run branch.

```
let outcome = await sidecarManager.startCapturingRefusal()      // throws nothing; returns the outcome
if case .refused(let summary) = outcome { return .refused(summary) }   // ← BEFORE the deadline loop
if case .healthy = outcome { return .healthy }
let deadline = Date().addingTimeInterval(15 * 60)
while Date() < deadline {
    let probe = await sidecarManager.status()
    if let admission = probe.admission, admission.refused {     // ← a refusal that arrived LATER
        return .refused(admission)
    }
    switch probe.state { … unchanged … }
}
return .gaveUp(reason: nil)
```

The `try?` is replaced by an explicit capture — **not** by `try?` plus a re-probe, because the
whole point is that `try?` is where the reason died. The second check inside the loop covers a
refusal raised by a *concurrent* boot of another model (single-flight, §4.2), which the pre-loop
check cannot have seen.

⚠️ **Do not "fix" this by making the switch treat `.installedNotRunning` as terminal.** That state
legitimately means *keep waiting* during a normal boot; narrowing it would break m17-h's whole
reason for existing. The refusal must be its own signal.

**(b) `GenerationPresenceModel.handleSubmitError` — `:753-771`.** It already has the right seam:
`.startingSidecar(detail:)` for the in-flight boot (`:36`) and `registerSubmissionFailure(reason:)`
for the terminal case, and its own comment at `:753` already anticipates *"a real refusal … a
failed card, verbatim."* The edit is to **stop passing the wrong string**:

```
switch await ensureSidecar() {
case .healthy: return                                   // unchanged — caller retries the submit
case .refused(let summary):
    await presence.registerSubmissionFailure(
        origin: origin, label: label, reason: summary.reason)   // ← VERBATIM refusal, not the
                                                                //   original unreachable error
    throw SidecarError.admissionRefused(summary.reason)
case .gaveUp:
    await presence.registerSubmissionFailure(
        origin: origin, label: label,
        reason: GenerationPresenceModel.verbatimReason(error))  // unchanged
    throw error
}
```

A refused card appears in **seconds**, naming the memory numbers and `force`, instead of a wrong
card after fifteen minutes. `verbatimReason` is the house pattern for exactly this and is already
used on both sides.

**(c) `SketchpadModel` — `Sources/DAWAppKit/SketchpadModel.swift:87-115`.** Two derived properties
are wrong under a refusal and both are one-line reads of the new field:

* `canGenerate` (`:87-92`) treats `.installedNotRunning` as usable, so **Generate stays enabled
  and leads straight into the hang.** Add: `&& !(sidecarStatus?.admission?.refused ?? false)`.
* `banner` (`:96-115`) must gain a refusal case ahead of the `.installedNotRunning` case, with
  `tone: .warning`, `message: admission.reason`, and `canStartSidecar: admission.canRetryWithForce`
  (the Start button becomes **"Start anyway"** — §15.5). The existing copy *"press Start to launch
  it now"* is actively misleading when Start just refused.

`Sources/DAWApp/DAWProApp.swift:6629-6635` (`startSketchpadSidecar`) then needs no structural
change: its existing `try?` → `refreshSketchpadSidecar()` fallback re-probes `status()`, which now
carries `.admission`, so the banner explains itself. **That is the payoff of §15.2's
record-and-render decision** — the swallowing fallback becomes correct rather than needing rewriting.

**Not affected:** `DAWProApp.swift:2680` (Voice panel) uses `try await`, so a thrown refusal
propagates into `VoicePanelModel.startSidecar()` (`Sources/DAWAppKit/VoicePanelModel.swift:147`),
which already catches and surfaces errors. It gets the reason for free; only the `AdmissionSummary`
field on `VoiceConversionStatus` is added, for parity.

### 15.5 Where `force: true` enters from callers that take no parameters

| caller | forces? | why |
|---|---|---|
| `ai.sidecarStart` / `vc.sidecarStart` | **opt-in**, `force` param (§6.3) | an agent must ask explicitly |
| `ensureSidecar` (auto-start, `:2725`) | **NEVER** | an automatic path that forces itself past a memory refusal is the silent over-commit this item exists to prevent. It surfaces the refusal and stops. **Non-negotiable.** |
| `startSketchpadSidecar` (`:6629`) | **yes, on a second explicit press** | a human pressed a button; the honest escape hatch is a visible one |
| Voice panel `startSidecar` (`:2680`) | same pattern, RVC | parity |

Mechanism for the banner: `func startSketchpadSidecar(force: Bool = false)` — a defaulted
parameter, so every existing call compiles. `SketchpadBanner` gains
`startIsForce: Bool` so the view can label the button **"Start anyway"** and the copy can say what
is being overridden. Route the visual treatment to `ui-design-engineer`; the model-level property
belongs in `DAWAppKit` (testable), the button in `DAWApp`.

⚠️ **Testability:** `DAWApp` has **no test target**, so none of this is directly unit-testable
there — the standing `debug.*` rule. Decision logic (`canGenerate`, `banner`, `startIsForce`) goes
in `DAWAppKit`/`SketchpadModel`, which **is** tested; `DAWProApp.swift` keeps only the wiring. The
existing `debug.sketchpad` command gains a `startSidecarForce` flag for E2E staging, following the
`debug.voicePanel` precedent (`DAWProApp.swift:6665-6669`).

### 15.6 Tests this section adds

All hermetic (§7.0 seam); none starts ACE or RVC.

1. **The 15-minute hang, as a test.** `ensureSidecar` with a coordinator stubbed to refuse →
   returns `.refused` in **well under one poll interval**. Assert the elapsed time is < 1 s and
   that `status()` was polled **zero or one** times. *Anti-vacuity twin:* the same harness with a
   sidecar that goes healthy on the third probe still returns `.healthy` — otherwise the test
   passes because `ensureSidecar` returns early for everything.
2. **The reason survives.** `handleSubmitError` with `.refused(summary)` registers a failure whose
   reason is **`summary.reason` verbatim**, and specifically **not** `verbatimReason(error)` of the
   original unreachable error. Assert on the refusal's distinctive substring (the byte figures), so
   the test cannot pass on a generic message.
3. **`canGenerate` is false under a refusal**, and **true** for the same `.installedNotRunning`
   status without one — the twin that proves the gate reads the field rather than being stuck off.
4. **Banner renders the verbatim reason** and sets `startIsForce` from `canRetryWithForce`, both
   polarities.
5. **Freshness.** A refusal record 121 s old is **absent** from `status()`; at 119 s it is present;
   a record older than the last successful boot is absent regardless of age.
6. **Wire additivity.** `ai.sidecarStatus` with no refusal encodes **no `admission` key at all** —
   assert key absence, not `null`, so existing gates and the `dist/` bundle see byte-identical
   payloads.
7. **Auto-start never forces.** Drive a refusal through `ensureSidecar` and assert the coordinator
   observed `force == false` on every call. This is a policy assertion, and policy that is not
   asserted drifts.

### 15.7 Additions to the §10 implementation plan

* **Phase 3** gains: `AdmissionSummary` + the two additive status fields + the coordinator's
  refusal record and freshness rule. ⚠️ **The record must be rendered into BOTH readers in the same
  step, because §15.4(a) reads it through both:** (i) `status()` populates `.admission` (the
  in-loop check, and the path `startSketchpadSidecar`'s `try?` fallback depends on), and (ii)
  `startCapturingRefusal()` maps the thrown refusal to `.refused(summary)` (the pre-loop check).
  Shipping only one leaves `ensureSidecar` half-fixed, and the half that is missing is not obvious
  from either call site. `AdmissionSummary` is a plain value type, so the outcome `ensureSidecar`
  returns is self-contained — the `@Sendable` closure at `DAWProApp.swift:2725` captures only
  `[sidecarManager]` and needs no coordinator capture. The throwing `start(force:)` is unchanged
  and is what the wire keeps calling.
* **Phase 3b (NEW, route: `swift-app-engineer`, with `ui-design-engineer` on the banner):**
  the `EnsureSidecar` widening, the `handleSubmitError` edit, `SketchpadModel.canGenerate`/`banner`,
  `startSketchpadSidecar(force:)`, the `debug.sketchpad` flag, and the §15.6 tests. **Phase 3 must
  not land without 3b** — Phase 3 alone is the 15-minute hang.
* **Gate impact:** `scripts/gates/m17h-generation-card.mjs` is the auto-start gate and drives
  `ai.sidecarStatus` polling plus a pid kill; `scripts/gates/m18g-sketchpad-honesty.mjs:126` reads
  `ai.sidecarStatus`. **Take both baselines before touching any Swift** (the m23-dw lesson), and
  re-run both after — they are the cheapest end-to-end proof that auto-start still behaves.

---

## 16. REVISION — ACE'S HOLD IS MEASURED, AND THE REFUSAL IS THE FEATURE

**Supersedes §2.1's hypothesis and inverts §2.2's consequence for ACE. §2.2's policy *machinery* is
unchanged — the provenance rule is still exactly right; ACE simply stopped being an estimate.**

### 16.1 Two independent measurements, and what the second one rules out

| source | figure | metric |
|---|---|---|
| user's memory monitor with ACE loaded (2026-08-05) | **80 GB** (≈ **74.5 GiB**) | Activity Monitor memory |
| m23-ac-3e-2 teardown: `vm_stat` free pages `1,166,504 → 5,744,768` @ 16384 B | **+75.01 GB returned** (**69.86 GiB**) | free-page delta on kill |

Computed, not quoted: `(5,744,768 − 1,166,504) × 16,384 = 75,010,277,376 B = 69.86 GiB`.

**⭐ The teardown figure is a LOWER BOUND on the genuine hold, and that is what refutes §2.1.**
My §2.1 hypothesis was that ~half the 75 GB was reclaimable page cache from mmap'd checkpoints,
which `availableBytes` already discounts. But §0.3 measured that **file-backed pages do not return
to `free` when the mapping process dies** — my 4 GB file-mmap child was `SIGKILL`ed and `external`
stayed at 29.80 GB, `free` recovered nothing. So 75 GB *returning to free* means ≥75 GB was
**anonymous/wired**, i.e. exactly the pages `amUsed` counts. The double-count hypothesis cannot
explain it away. **It was a reasonable hypothesis and it was wrong; the measurement wins.**

*Residual uncertainty, stated rather than hidden:* a teardown that big could itself have triggered
cache reclamation, so some of the +75 GB might be cache the kernel released under the pressure ACE
created. That would make the true hold *smaller*, never larger — and the user's independent 80 GB
reading bounds it from the other side. **Ship 74.5 GiB, `confidence: .measured`**, and let §2.3's
learning loop replace it with a first-party observation on the first admitted boot.

**Consequence for §2.2's rule.** The rule stands verbatim — *an estimated requirement may warn but
may never refuse; only a hold measured on this machine may refuse.* ACE has now crossed that line,
so ACE can refuse. `.admitUnverified` is no longer reachable for ACE; it remains the correct path
for RVC (3 GiB, still an estimate) and for Music Flamingo (no number at all).

### 16.2 The refusal is CORRECT — and the variable is the user's workload, not ACE

Re-sampled twice while writing this: **available = 56.97 GB, 57.19 GB** (§2's earlier samples read
60.0–60.7 GB; the coordinator's 18:02 `vm_stat` computes ~54 GB by the same formula). The spread is
the point — it is workload, not noise.

```
required   74.5 GiB  (measured)
reserve   + 4.0 GiB
          ─────────
needed      78.5 GiB      vs   available ~57 GB      →  SHORTFALL ≈ 21 GiB
```

**So admission refuses ACE on the user's current desktop, and that refusal is the feature working.**
Booting anyway is a ~21 GiB over-commit that drives the machine into compression and swap — the
wedge that started this cycle. §2's framing ("refusing ACE is strictly worse than the bug") was
correct against a *guessed* 75 GB and is **withdrawn** against a measured one.

Why it used to boot fine: at the 2026-08-03 baseline, used was ~34 GB and free returned to ~94 GB
after the kill. Today Chrome, Zoom, VS Code, Slack and a 2.5 GB Terminal have eaten that headroom.
**ACE did not change. The desktop did.** The refusal message must say so, or the user will conclude
the DAW broke.

### 16.3 Does `hardFloorBytes` still earn its place? — YES, but its job narrowed

Re-examined as asked. For a model with a **measured** hold the floor is fully subsumed: if
`available < 8 GiB` then certainly `available < 74.5 + 4`, so the arithmetic refuses first and the
floor never fires. It does **not** collapse, though, because §2.2 forbids an *estimated* requirement
from refusing — which leaves exactly one job:

> **`hardFloorBytes` is the ONLY refusal available for a model we have never measured.**

Its live consumers are RVC (3 GiB estimated) and Music Flamingo (no number). Keep it at 8 GiB, and
**re-document it in `ModelLifecyclePolicy` with that narrowed charter** — as a general "safety net"
it now reads as dead weight and someone will delete it, taking the unmeasured-model guard with it.
It is dead weight *for ACE specifically*, and that is fine.

### 16.4 THE REFUSAL MESSAGE IS NOW THE MOST IMPORTANT SURFACE IN THIS FEATURE

Given §16.2, most users meeting this feature meet it as a refusal. A message reading "not enough
memory" sends them to close things at random. **Contract — every clause is mandatory:**

1. **The measured requirement, with its provenance.** *"ACE-Step needs about 75 GB (measured on
   this machine)"* — never a bare number, so it cannot be mistaken for a guess.
2. **Current available, in the same units**, and named so it is reconcilable with Activity Monitor's
   "Memory Used" (§0.5 chose that metric partly for this).
3. **THE SHORTFALL IN GB, as its own sentence.** *"You need about 21 GB more free."* This is the
   only number that tells the user when to stop closing things, and it is the clause an
   implementer will drop as redundant. It is not.
4. **That the requirement did not change — their workload did.** One clause, and it is what stops
   this reading as "the DAW broke".
5. **What we own and can act on, named with figures**: any evictable resident model and its hold
   (*"stopping the voice-conversion sidecar would free 3 GB"*), plus anything blocked by an active
   job (`evictionBlockedBy`) so a blocked eviction explains itself.
6. **The override, spelled exactly**: `force: true` on the wire; **"Start anyway"** on the banner
   (§15.5). A refusal that hides its escape hatch is a dead end.
7. **The `generation` nonce**, so a retry can be proven to be a new decision.

**Naming the user's largest memory consumers — CONSIDERED AND REJECTED.** Tempting, and the
coordinator asked whether it is cheap. It is not safe: ranking would use `ri_phys_footprint`, which
**measured 0.00 GB for a 4 GB file-backed mapping** (§0.3) — so the ranker would systematically
mis-rank exactly the cache-heavy processes worth closing — and `proc_pid_rusage` **fails outright
on processes we do not own** (measured, pid 1), so root-owned consumers are invisible. A confidently
wrong "close Chrome" is worse than no list. It is also a process-ranking feature, and this item is
not that. **Instead:** name our own models (clause 5 — accurate, actionable, ours), and point at the
tool that is already correct: *"Activity Monitor ▸ Memory, sorted by Memory, shows the largest."*

Illustrative rendering (wording is the implementer's; every clause above must survive):

> Not enough memory to load ACE-Step. It needs about **75 GB** (measured on this machine) plus
> 4 GB headroom, and about **57 GB** is available right now — **you need about 21 GB more free.**
> ACE-Step's requirement has not changed; other apps are using more memory than they were.
> Stopping the voice-conversion sidecar would free about 3 GB. Activity Monitor ▸ Memory, sorted by
> Memory, shows the largest consumers. To load it anyway, use **Start anyway** (or `force: true`).

### 16.5 Tests this revision adds or changes

1. **CHANGED — §7.1 test 1's numbers.** `available = 57 GiB`, required 74.5 GiB **measured** →
   `.refuse(.insufficientMemory)`. ⚠️ **These are ILLUSTRATIVE CONSTANTS chosen to straddle the
   threshold, not a measurement the test re-derives.** The `Facts` are hand-built, so the test is
   deterministic and never reads the host — say so in a comment, or a later reader will see
   `57 GiB`, re-measure the machine, find a different number, and conclude the test is stale. The
   only thing that makes 57/74.5 worth using as the constants is that they are the real shape of
   the problem (§16.2), not that any test verifies them.
2. **CHANGED — §7.1 test 3** (`.estimated` may not brick) must now use **RVC or a synthetic
   model**, not ACE. ACE is `.measured` and `.admitUnverified` is unreachable for it — leaving ACE
   in that test would make it pass for the wrong reason, which is the m23-ee vacuity class.
3. **NEW — the refusal message carries every §16.4 clause.** Assert on the **shortfall figure**
   specifically (the clause most likely to be dropped), on the word `force`, and on the
   provenance word `measured`. Generic-substring assertions do not count.
4. **NEW — `hardFloorBytes` fires only for an unmeasured model.** With a `.measured` model at
   `available = 2 GiB`, the refusal must be `.insufficientMemory` (arithmetic), **not**
   `.belowHardFloor`; with an unmeasured model at the same available, `.belowHardFloor`. Both
   polarities, or §16.3's charter is unasserted.
5. **NEW — idle-off is genuinely inert (§6.5).** With `idleUnloadSeconds == nil`, `noteJobEnded`
   must schedule **nothing**: assert through a task-scheduling spy that zero wake-ups were created,
   then advance the stub clock arbitrarily far and assert no eviction and **no `generation` bump**.
   *Anti-vacuity twin:* the same harness with `idleUnloadSeconds = 600` **does** schedule exactly
   one and **does** evict after the clock advances — otherwise test 5 passes because the timer is
   broken everywhere.
6. **UNCHANGED and now more valuable — §7.4's diagnostic.** The first *admitted* ACE boot writes a
   first-party `observedHoldBytes` that replaces the seeded 74.5 GiB. Because admission now refuses
   on this desktop, that first boot will most likely come via `force: true` — so **the observation
   recorder must run on the forced path too**, or the number can never self-correct. Name this in
   Phase 2; it is easy to wire only to `.admit`.

### 16.6 §13's ARCHITECTURE.md text — replace two clauses

In §13's block, replace *"A requirement that was only estimated may warn but may never refuse — only
a hold measured on this machine can refuse a boot, and `force: true` overrides even that."* with:

> A requirement that was only *estimated* may warn but may never refuse; only a hold **measured on
> this machine** can refuse a boot, and `force: true` overrides even that. ACE-Step's hold **is**
> measured — 75–80 GB from two independent observations — so on a busy desktop (~57 GB available)
> admission **refuses ACE, and that refusal is correct**: the requirement did not change, the
> user's workload did. The refusal message is therefore a first-class surface and must state the
> measured requirement, the current available figure, **the shortfall in GB**, and the override.
> Idle unload ships **off** by user decision (2026-08-05, *"ship it off, decide later"*), and off
> means genuinely inert — no timer scheduled. A refusal is **never** silently auto-forced.
