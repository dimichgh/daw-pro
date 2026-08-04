# m23-au — `AUViewResolver`'s main-actor-bound deadline: design

**Status:** design complete, not implemented. No source or test file was modified in producing this.
**Author:** daw-architect. **Date:** 2026-08-03. **Toolchain measured:** Apple Swift 6.3.3
(`swiftlang-6.3.3.1.3`), Xcode 26.6 (17F113), target `arm64-apple-macosx26.0`, package floor macOS 14.

---

## 0. The one-paragraph answer

Replace the hand-rolled race in `Sources/DAWApp/PluginUI/AUViewResolver.swift`
(`requestViewControllerOnMain`, its `ResumeGate`, and its `Task { @MainActor in sleep }`)
with **six lines** over `DAWCore.DeadlineRace`, racing directly on
`await au.requestViewController()` — the **async-imported** SDK method, which the
compiler confirms exists as `open func requestViewController() async -> NSViewController?`.
No inner continuation, no bridge type, no second gate, no orphan. **Two premises in the
roadmap line turn out to be false and are corrected below with compiler evidence:**
`NSViewController?` *is* `Sendable` in this toolchain, and the payload-free-enum
workaround is therefore unnecessary. The seam question resolves to **"ship on compile +
review, plus a source-site pin"** — not because the tree cannot test it, but because after
the conversion there is nothing left in `AUViewResolver` that is not already covered by
`Tests/DAWCoreTests/DeadlineRaceTests.swift`, and inventing a `DAWAppKit` bridge type
purely to have something to test would create exactly the second race implementation this
item exists to eliminate.

---

## 1. What I verified, and how

Every claim in this section was produced by the compiler or by a running binary in a
throwaway SwiftPM package (`swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]` — identical
to `/Users/dsemenov/Views/daw-pro/Package.swift`, so Swift 6 language mode and strict
concurrency are the same). Nothing here is recalled.

### 1.1 ⚠️ CORRECTION 1 — `NSViewController?` IS `Sendable`

The roadmap line states the obstacle as: *"its `RequestOutcome` carries `NSViewController?`
— **non-Sendable** — and the `@MainActor` on the gate is precisely WHY it compiles today;
moving the gate off-main forces an AppKit object across isolation domains."*

**That is not true on this toolchain.** AppKit's classes are `@MainActor`-annotated in the
SDK, and a global-actor-isolated class is *implicitly `Sendable`* (its state is protected
by the actor; passing the reference across domains is safe — only *using* it off-main is
what isolation forbids, and isolation still forbids that).

Measured — all three compile clean:

```swift
enum OutcomeA: Sendable {                 // ← accepted, no diagnostic
    case viewController(NSViewController?)
    case timedOut
}
func requiresSendable<T: Sendable>(_ v: T) -> T { v }
_ = requiresSendable(vc)                                   // T == NSViewController?   ✅
_ = requiresSendable(OutcomeA.viewController(nil))         // T == OutcomeA            ✅
```

and, with a **verbatim copy of `DAWCore.DeadlineRace`** pasted into the probe so the check is
against the real signature rather than a paraphrase:

```swift
let outcome = await DeadlineRace.run(timeout: timeout) { @MainActor in
    await au.requestViewController()      // T inferred as NSViewController?
}
```

→ `Build complete!`, zero warnings, zero errors. `DeadlineOutcome<NSViewController?>` is a
legal instantiation of a `T: Sendable` generic.

Runtime confirmation that this is not a type-checker-only fiction (generic metadata for
`NSViewController?` is instantiated and unwrapped at run time): the four-step probe printed
`step 1 … step 4 … ALL STEPS OK`, exit 0.

**Consequence:** the roadmap's prescribed workaround — *"race on a payload-free enum, stash
the VC in main-actor-isolated state, have the caller read it after"* — is **not needed**.
It was a sound plan for the obstacle as understood; the obstacle is not there.

### 1.2 ⚠️ CORRECTION 2 — there is an async-imported `requestViewController()`

The compiler volunteered this while diagnosing the completion-handler form:

```
warning: consider using asynchronous alternative function
CoreAudioKit.AUAudioUnit.requestViewController:2:11: note: 'requestViewController()' declared here
  open func requestViewController() async -> NSViewController?
```

This is the SDK declaration printed by the compiler, not a memory. It is the ObjC
async import of `requestViewController(completionHandler:)`.

Three things follow, and together they decide the design:

1. **The inner `withCheckedContinuation` disappears.** With it goes the entire orphan
   hazard the brief asked me to adjudicate (§3), the `arm`/`deliver`/`cancel-before-arm`
   state machine, and the `DAWAppKit` bridge type that would have had to host it.
2. **The main-actor hop is preserved *by construction*, not by hand.** The ObjC async
   thunk copies the `NSViewController?` *pointer* out of the completion on whatever thread
   the completion ran on and resumes the awaiting task; the awaiting task is
   `@MainActor`-isolated, so it re-acquires the main actor **before the first use** of the
   value. No AppKit method is invoked off-main. That is exactly the guarantee the existing
   hand-written hop and its comment provide — the header contract
   (*"may run on any thread"*, `CoreAudioKit/AUViewController.h`) is still honoured, and the
   reasoning behind that comment must be carried over into the new one (§5, step 3).
3. **Using the completion-handler form *directly in async context* emits a warning.**
   Measured: `au.requestViewController { … }` written straight into an `async` function
   produces `consider using asynchronous alternative function`, which the 0-warning build
   rejects.
   ⚠️ **But this is NOT a general check that the async form was used, and it must not be
   sold as one.** The warning fires only in async context. The natural way to rebuild
   alternative (A) puts the completion call inside a `withCheckedContinuation` **body
   closure**, which is *not* async — and emits **no warning at all**. That is precisely why
   the code shipping today is warning-free while using the completion form. Both sides of
   this were observed in the probe. So leg **B0** catches a *careless* implementation, not
   the *plausible* one; **the guard against alternative (A) is leg S4**, not the build.

### 1.3 The orphan verdict — measured, not recalled

The brief asked whether an orphaned `CheckedContinuation` whose canary deallocates
unresumed **logs** or **traps**. The answer on Swift 6.3.3:

```
[orphan] arming…
[orphan] holder alive: true
[orphan] Holder deinit — completion block released UNCALLED
SWIFT TASK CONTINUATION MISUSE: probe leaked its continuation without resuming it. This may cause tasks waiting on it to remain suspended forever.
[orphan] PROCESS SURVIVED 2 s after the canary dropped
exit=0
```

**It logs to stderr and the process survives.** It does **not** trap. (Note the exact
6.3.3 wording differs from the message the brief recalled — it is
`… leaked its continuation without resuming it. This may cause tasks waiting on it to
remain suspended forever.`, not `… leaked its continuation!`.)

The **contrast** case, which the brief needed for the once-gate argument, *does* trap:

```
[double] first resume ok; second resume now…
_Concurrency/CheckedContinuation.swift:172: Fatal error: SWIFT TASK CONTINUATION MISUSE: probe tried to resume its continuation more than once, returning ()!
```

So the two misuses are asymmetric and the asymmetry matters for how you reason about
risk: **leak = a stderr line plus a permanently suspended task; double-resume = process
death.** `DeadlineRaceTests` leg 3 already relies on the second half of that
(*"A broken gate does not return a wrong value — `CheckedContinuation` TRAPS on the second
resume and takes the whole test process down"*) — that claim is confirmed.

### 1.4 One thing I could not fully explain (bounded, and it does not affect the design)

An early combined probe binary — which linked `AppKit`, `AVFAudio` and `CoreAudioKit` and
declared, but for the crashing path never *called*, a `MiniRace`/`Bridge` pair — terminated
with **SIGSEGV before its first line of output**. I bisected it as far as time allowed:

* **Ruled out:** the imports alone (minimal program with all four imports runs, exit 0);
  the AppKit-Sendable statements (`step 0 … ALL STEPS OK`, exit 0, run in isolation);
  the orphan probe (runs, exit 0); the final two-shape compile probe, which contains
  *both* candidate production shapes and printed `BOTH SHAPES COMPILE`, exit 0.
* **Not ruled out:** some interaction in that specific throwaway file — most likely
  top-level-code global initialisation ordering in a `main.swift` that mixes `@MainActor`
  top-level statements with AppKit metadata, which is a known-fiddly corner of executable
  targets and is **not** the shape any production file here has.

**Honest status: unexplained probe-harness artifact, not reproduced by any probe that
resembles the shipping code.** Every load-bearing claim in §1.1–§1.3 was re-established by
a probe that ran to a clean exit 0 *after* the bisect, so no conclusion in this document
rests on the crashing binary. If an implementer sees a SIGSEGV, this paragraph is the prior
art; it is not expected.

---

## 2. The decision

**Convert `requestViewControllerOnMain` to a thin adapter over `DAWCore.DeadlineRace`,
racing the async-imported `au.requestViewController()` directly. Delete the local
`ResumeGate`. Keep the `RequestOutcome` enum and `resolve`'s three-case switch exactly as
they are.**

### 2.1 The shape (this compiles — verified against the real `DeadlineRace` signature)

```swift
    /// Bridges `requestViewController` to an async main-actor result, raced against a
    /// REAL wall-clock deadline (`DAWCore.DeadlineRace`, m23-at).
    ///
    /// The deadline runs on `Task.detached` inside `DeadlineRace`, so it fires on wall
    /// time regardless of main-actor contention — the defect m23-au removed. `DeadlineRace`
    /// also cancels its own deadline task when the work wins, so a successful open no
    /// longer leaves a task sleeping out the full 5 s.
    ///
    /// `requestViewController()` is the SDK's ASYNC import of
    /// `requestViewController(completionHandler:)`. Using it rather than the
    /// completion-handler form is load-bearing, not cosmetic:
    ///  · it removes the hand-rolled inner continuation, so there is no continuation this
    ///    file could orphan when the deadline wins (m23-au §3);
    ///  · the header contract (`CoreAudioKit/AUViewController.h`: the completion may run on
    ///    ANY thread) is still honoured — the async thunk copies the VC POINTER out of the
    ///    completion on whatever thread it ran on and resumes this task, and this task is
    ///    `@MainActor`, so the first USE of the value is already on the main actor. That is
    ///    the same guarantee the old hand-written `Task { @MainActor in … }` hop gave, now
    ///    given by the language instead of by a comment;
    ///  · the completion-handler form inside an `async` function emits
    ///    "consider using asynchronous alternative function", which the 0-warning build
    ///    would reject.
    ///
    /// ⚠️ Do NOT reintroduce a local timeout, gate, or continuation here. `DeadlineRace`
    /// is the ONE home for this decision (m23-at/m23-au); this file was the last
    /// hand-rolled sleep-then-resume race in `Sources/`.
    ///
    /// ⚠️ Concurrency note, CORRECTED by m23-au: `PluginWindowManager.pendingOpens`
    /// serializes `openUI` CALLS per target, which is NOT the same as serializing
    /// outstanding view requests. Now that the deadline really fires, a timed-out request
    /// is still in flight when `openUI` returns; a close-then-reopen (or a stale-stamp
    /// reopen) then starts a second one, so two `requestViewController` calls CAN be
    /// outstanding on one AU. A plain reopen does NOT — it short-circuits to `focus()`.
    /// Each resolves into its own abandoned task and its result is discarded; nothing here
    /// is shared between them. See m23-au §8.4.
    @MainActor
    static func requestViewControllerOnMain(_ au: AUAudioUnit,
                                            timeout: Duration) async -> RequestOutcome {
        let outcome = await DeadlineRace.run(timeout: timeout) { @MainActor in
            await au.requestViewController()
        }
        switch outcome {
        case .value(let vc):
            return .viewController(vc)
        case .timedOut:
            return .timedOut
        case .error(let error):
            // Unreachable: `requestViewController()` is non-throwing, so `DeadlineRace`
            // cannot produce `.error` here. Handled rather than force-unwrapped because
            // the ladder is TOTAL (design §3.2) — fall through to steps 2/3 exactly as a
            // unit with no custom v3 view does, and say so on stderr rather than
            // mislabelling it a timeout in the user-facing warning.
            FileHandle.standardError.write(Data(
                "AUViewResolver: requestViewController surfaced an unexpected error (\(error)) — falling through to the ladder\n".utf8))
            return .viewController(nil)
        }
    }
```

Deletions: the whole `private final class ResumeGate` (`:127–142`), the
`withCheckedContinuation` body, the `Task { @MainActor in try? await Task.sleep… }`, and
the ⚠️ KNOWN-DEFECT comment block (`:89–100`) — replaced by the comment above.
`enum RequestOutcome` (`:79–82`), `static let requestTimeout` (`:38`), and `resolve`'s
switch (`:50–57`) are **untouched**.

### 2.2 Why the nil-vs-non-nil distinction survives

`resolve` switches on three cases: `.viewController(vc?)` → custom v3 body;
`.viewController(nil)` → *fall through to step 2*, the normal answer for a v2 unit;
`.timedOut` → warning + fall through. The adapter above maps `.value(nil)` →
`.viewController(nil)` and `.timedOut` → `.timedOut`, which are distinct enum cases. The
distinction is preserved at the type level, and leg **S6** in §7 pins it against a future
"simplification" that collapses them.

### 2.3 What this fixes, precisely

| Defect | Before | After |
|---|---|---|
| Deadline is main-actor-bound (`:120–123`) | Timeout task must re-acquire the actor to fire; under contention it is a sleep **plus** an unbounded queueing delay, and which task wins is a coin flip | Deadline is on `Task.detached` inside `DeadlineRace`; by the time the actor frees, the gate is **already** closed with `.timedOut` — deterministic, not a coin flip |
| Deadline task never cancelled | Every UI open leaves a task sleeping the full 5 s before a no-op resume | `DeadlineRace` calls `deadline.cancel()` when work wins (`DeadlineRace.swift:82`) |
| Duplicate `ResumeGate` (`:131`) | Second, untested once-gate implementation | Deleted. `DeadlineResumeGate` in `DAWCore/DeadlineRace.swift` is the only one left in `Sources/` |
| Hand-rolled race | `AUViewResolver` was the last one in the tree | Zero. m23-at's one-home claim becomes true |

### 2.4 The honest limit — what this does NOT fix

`resolve` and `requestViewControllerOnMain` are `@MainActor`. `DeadlineRace` makes the
deadline **decide** on wall time; **publishing** that decision back to a `@MainActor`
caller still needs the main actor. So if a plug-in wedges the main actor synchronously
(the Surge XT case, m23-av), `openUI` still does not return until the actor frees — the
outcome is merely already-decided when it does.

This is the *same* residual m23-at recorded for `performPrepare`, in the same words, and it
must be written into the ROADMAP close-out rather than left for a reader to discover.
**m23-au must not be read as fixing m23-av.**

---

## 3. Adjudication of the orphan hazard

The brief's central question. It is worth answering in full even though **the chosen shape
does not have an orphan**, because the answer is what *rules out* the alternatives in §4
and because a future implementer may be tempted back toward the bridge.

### 3.1 The hazard as posed

The naive prescribed shape nests a `withCheckedContinuation` *inside* `DeadlineRace`'s
work closure. `DeadlineRace` **abandons** work when the deadline wins (it never awaits it,
and it does not cancel it — `DeadlineRace.swift:33-35`, and `DeadlineRaceTests` leg 3
depends on exactly that). So the inner continuation is never resumed.

### 3.2 Question 1 — does an orphaned continuation trap?

**No. It logs and the process survives.** Measured, §1.3. So the naive shape would *not*
convert a benign timeout into a crash. But it is still bad, in three specific ways, and
"it only logs" is not a defence:

* The work task is **suspended forever**, retaining `au`, the closure, and its frame. One
  leak per timed-out open.
* `SWIFT TASK CONTINUATION MISUSE` on stderr is indistinguishable, to anyone triaging, from
  a genuine concurrency bug. Emitting it *by design* poisons the signal.
* The leak message only appears when the AU **releases** an uncalled completion block. If
  the AU *retains* it (a dead XPC connection holding the block), you get the leak with **no
  message at all** — silent. That third case is the one that would actually hurt, and it is
  the one nobody would ever see.

### 3.3 Question 2 — is caller-side `cancelPending()` correct?

**Yes, it is correct, and yes, the ordering guard the brief describes is required.** For
the record, because it is the right answer to the wrong question:

The work task may not have **started** when the deadline fires — that is the whole
scenario, a hogged main actor. So `cancelPending()` (running on the main actor, after
`DeadlineRace.run` returns) can arrive *before* `wait()` ever arms. A gate that only
resumes a stored continuation would drop that cancel on the floor and the orphan would
survive. The fix is a three-state machine where `cancelled` is **sticky** and a later
`arm` resumes immediately:

```swift
func wait() async {
    await withCheckedContinuation { c in
        switch state {
        case .delivered, .cancelled: c.resume()   // ← the cancel-before-arm path
        case .idle: state = .armed; continuation = c
        case .armed: c.resume()                   // programmer error; fail open, never trap
        }
    }
}
```

I built and compiled this (§1, `ViewRequestBridge`); it works. **It is nevertheless rejected**,
because §3.4 answers yes.

### 3.4 Question 3 — is there a shape with no inner continuation at all?

**Yes: `await au.requestViewController()`.** §1.2. It routes through `DeadlineRace`
unchanged, keeps the VC main-actor-confined, needs no bridge, no state machine, no
`cancelPending`, and emits no warning. This is why the answer to Q2, though correct, does
not get shipped.

**One residual is not removed by any shape, and I will not pretend otherwise:** if the
vendor never answers, the abandoned work task stays suspended forever, retaining `au`. That
is true of the async form, of the bridge form (before `cancelPending`), and — importantly —
**of the code shipping today**, where the completion block retains the `ResumeGate` and the
AU retains the block. It is a pre-existing, bounded (one per timed-out open), silent leak
that this item neither creates nor cures. §8.5.

---

## 4. Alternatives considered and rejected

Each is stated with its trade-off, not merely listed.

**(A) The roadmap's payload-free enum + main-actor box + `DAWAppKit` bridge.**
The design I was sent to write. Rejected on evidence: its premise (§1.1) is false, and the
async import (§1.2) removes the inner continuation it exists to manage. Shipping it would
add a ~60-line generic type, five test legs, and an orphan-cancel protocol to guard a
hazard that the chosen shape does not have. **This is the closest rival and the one a
future reader is most likely to try to "restore" — §7 leg S4 makes it fail loudly.**

**(B) `withTaskGroup` racing two child tasks.**
Structured concurrency requires the group to await *all* children. Cancelling the losing
child does **not** interrupt a `withCheckedContinuation` (no cancellation handler), so the
group would hang forever on a stalled vendor — the exact failure the deadline exists to
prevent, reintroduced by the mechanism meant to prevent it. Adding
`withTaskCancellationHandler` recovers correctness but rebuilds the §3.3 bridge with more
machinery, *and* constitutes a second race implementation. Rejected on both counts.

**(C) `AsyncStream` as the delivery channel.**
Still needs a deadline; `AsyncStream` + `Task.sleep` reproduces the main-actor-bound bug
unless it routes through `DeadlineRace` anyway, at which point the stream is pure overhead
(a buffer and ordering semantics for a single one-shot value). Rejected.

**(D) Teach `DeadlineRace` a callback-style overload.**
Tempting — "fix it upstream, once". Rejected: it doubles a *tested* primitive's public
surface for one caller, requires its own once-gate semantics and its own test legs, and
DAWCore is the headless domain module where every added entry point is a permanent cost.
The async import makes the overload unnecessary.

**(E) Promote `DeadlineResumeGate` to a public shared primitive and reuse it for the bridge.**
This is the alternative a naive reading of the one-home rule *demands*, so it needs a real
answer: **they are not two implementations of one decision; they are two different
decisions.** `DeadlineResumeGate` is a cross-executor, lock-guarded, once-only resume of a
`DeadlineOutcome<T>`. The bridge would be a main-actor-confined once-gate over a *payload-free*
signal with a *pre-arm* state machine (`cancel` before `arm` must be sticky). Fusing them
would either force the payload through a `Sendable`-typed generic or bolt pre-arm states
onto a primitive that has no use for them — weakening the invariant `DeadlineRaceTests`
leg 3 pins. The one-home rule forbids **two computations of the same answer**
(`ArrangeDropSnap`); it does not require unrelated mechanisms to share a type. Moot anyway
under the chosen shape, since there is no bridge.

**(F) Make `DeadlineRace` *cancel* the work task on timeout (instead of abandoning it).**
This would auto-resolve the orphan via `withTaskCancellationHandler`. Rejected with a
citation, because it looks free and is not: `DeadlineRace.swift:33-35` documents abandonment
as deliberate and preserved from the pre-m23-at design, and `DeadlineRaceTests`
leg 3 explicitly depends on it — *"only the DEADLINE task is cancelled, and an unstructured
`Task {}` does not inherit cancellation, so the work task's sleep can never throw. An error
here means something else broke."* Changing this silently changes what leg 3 tests, and it
changes semantics for `AUHostRegistry`'s two live call sites (a cancelled task mid
`allocateRenderResources`) for zero benefit here.

**(G) Call `requestViewController()` from a `nonisolated` context so it starts without
waiting for the main actor.** `AUAudioUnit` is not `@MainActor` in the SDK, and the return
value is `Sendable` (§1.1), so this would compile. Rejected as **out of scope with a stated
unknown**: the SDK guarantees nothing about calling it off-main, m23-av says this AU surface
is where third-party plug-ins misbehave worst, and `DeadlineRace.run`'s `work` is
`@MainActor` by signature so the change would not be local. Recorded in §8.3 as the
accepted cost, and in §10 as a possible follow-up if measurement ever justifies it.

---

## 5. Implementation plan

**Single file changed.** Route: `swift-app-engineer` (app tier) with `daw-architect` review.
Estimated diff: **−45 / +30**.

### Step 1 — `Sources/DAWApp/PluginUI/AUViewResolver.swift`, imports
Add `import DAWCore` to the import block (`:1–7`). It is **not** currently imported, and
`DAWEngine` does not re-export it (`@_exported` is not used in this package). `CoreAudioKit`
is already imported and is what provides `requestViewController()`.

### Step 2 — replace `requestViewControllerOnMain` (`:84–125`)
With the body in §2.1. Verbatim; it has been compile-checked against the real
`DeadlineRace.run` signature.

### Step 3 — carry the reasoning, do not just delete it
Delete the ⚠️ KNOWN-DEFECT block (`:89–100`) and the `ResumeGate` class (`:127–142`).
**The off-main-thread argument from the old completion-hop comment (`:110–116`) must survive
into the new comment** — it is the only place in the tree that records *why* the header's
"may run on any thread" contract is satisfied. §2.1's comment does carry it; do not trim it.
m23-at's close-out found stale comments arguing *against* its own fix and had to correct
them; the equivalent mistake here is deleting the surviving justification.

### Step 4 — correct the `pendingOpens` claim
The old comment asserts *"Never call this twice concurrently for one AU — `PluginWindowManager`'s
`pendingOpens` serializes opens per target."* Once the deadline really fires, that is no
longer accurate (§8.4). §2.1's comment states what is actually guaranteed. A comment that
contradicts the code beside it is how the next author concludes the old shape is still
sanctioned.

### Step 5 — build, and read the warnings
```
swift build            # via `rtk proxy swift build` — the hook STRIPS warning: lines
```
Must be **0 errors, 0 warnings**. In particular there must be no
`consider using asynchronous alternative function` — if it appears, the implementer used
the completion-handler form and the design was not followed (leg **B0**, §7).

### Step 6 — add the site pin
New file `Tests/DAWAppKitTests/AUViewResolverDeadlineSiteTests.swift`, §7.

### Step 7 — run the suite
`./scripts/test.sh` (never bare `swift test`). ⚠️ It **exits 0 on a failed run** — grep for
`✘`. Expect the current baseline **+ the new legs**, and no change elsewhere: this item
touches no runtime path any existing test exercises.

### Step 8 — docs
* `docs/ROADMAP.md` m23-au → `[x]`, with the §2.4 residual and the §8 second-order effects
  stated in the close-out (especially §8.1 — it is user-visible).
* `docs/ARCHITECTURE.md` "Key future decisions" — see §11.
* `CHANGELOG.md`.

### Not required
No control-protocol command, no MCP tool, no wire-count change. This is a behavioural fix
behind an existing verb (`plugin.openUI`); the CLAUDE.md "every capability ships a command +
tool + test" rule is about *new capabilities*.

---

## 6. Module / seam decision

**Chosen: (b) — compile + review, plus a source-site pin. Explicitly NOT (a).**

The brief framed this as *"`DAWApp` cannot be tested, so either extract a testable type or
admit it ships untested."* The chosen shape dissolves the dilemma, and the reasoning is the
part worth keeping:

1. **There is nothing left to extract.** After the conversion, `requestViewControllerOnMain`
   is a `switch` over three enum cases around one call to an already-tested primitive. The
   *behaviour* — deadline fires under main-actor contention (leg 1), does not fire
   spuriously (leg 2), once-gate holds across executors (leg 3) — is covered by
   `Tests/DAWCoreTests/DeadlineRaceTests.swift`, at 4 legs, against the exact code path this
   file will now use. **That coverage is not an accident; it is the point of the item.** The
   whole purpose of m23-au is to stop having a second implementation, and a second
   implementation is precisely what you would need in order to have a second thing to test.
2. **Option (a) would manufacture the divergence this item exists to close.** A
   `DAWAppKit` bridge type would be a second gate/race mechanism in the tree, tested,
   blessed, and available to copy. `ArrangeDropSnap` exists to make divergence
   *unrepresentable*; adding a rival primitive to satisfy a coverage metric inverts that.
3. **The tree already has a sanctioned way to gate app-tier source shape.**
   `DAWAppKitTests` reaches into `Sources/DAWApp/` via `#filePath` anchoring —
   `EditorSurfaceOwnershipSiteTests`, `PollDisciplinePinTests`, `CanvasContractPinTests`,
   and in `DAWEngineTests` the `StartAnchorPolicySiteTests` / `RenderClockTrustSiteTests`
   pair. That idiom gives m23-au a **real** regression gate with **real** kill-mutations
   (§7), and it gates the property that actually matters here — *this file contains no
   second race* — which no behavioural test could gate anyway.

**Stated plainly, so nobody reads more into it:** a site pin is a **token search**, and a
token search finds the token, not the behaviour. `EditorSurfaceOwnershipSiteTests`' own
header says so and this suite must repeat it. What the pins guarantee is that the
*structure* cannot regress silently. What proves the *behaviour* is `DeadlineRaceTests`,
plus the compiler, plus review.

---

## 7. Test legs and their kill-mutations

House rule: **a test must be able to fail for the reason it claims.** Each leg below states
the production mutation that turns it red. All except B0 live in the new
`Tests/DAWAppKitTests/AUViewResolverDeadlineSiteTests.swift`.

**Mandatory harness detail — this leg set is worthless without it.** Assertions must run
over **comments-stripped** source, using the `codeOnly(_:)` helper from
`EditorSurfaceOwnershipSiteTests.swift:67-76`. The new file's own doc comment will
*discuss* `Task.sleep` and `ResumeGate` (it must, to explain what it forbids), and
`AUViewResolver`'s new comment names them too. A raw `contains` would match the prose and
green/red at random. Copy the `sourcesDir()` / `text(_:)` / `codeOnly(_:)` / `body(of:in:)` quartet verbatim from
`EditorSurfaceOwnershipSiteTests.swift:36,53,67,85`; do **not** re-derive them.

| Leg | Assertion | Kill-mutation (what turns it red) |
|---|---|---|
| **B0** *(build, not a test)* | `swift build` emits 0 warnings | Call `au.requestViewController { … }` **directly in async context** → `consider using asynchronous alternative function`. **Measured**, §1.2. ⚠️ **Narrow**: wrapping the same call in a `withCheckedContinuation` body closure emits nothing (that is today's warning-free shipping code). B0 does **not** guard against alternative (A); **S4 does.** |
| **S1** | Code-only text of `AUViewResolver.swift` contains no `Task.sleep` | Reintroduce `Task { @MainActor in try? await Task.sleep(for: timeout); … }` → red. This is the m23-au defect itself. |
| **S2** | Code-only text contains no `class ResumeGate` and no identifier ending `ResumeGate` | Re-add `private final class ResumeGate` → red. |
| **S3** | Code-only text contains **exactly one** occurrence of `DeadlineRace.run(`, and it lies inside the `requestViewControllerOnMain` body (brace-matched via `body(of:in:)`, the extractor the sibling suite already has at `EditorSurfaceOwnershipSiteTests.swift:85`) | Delete the call and hand-roll a race → red (count 0). Add a second race elsewhere in the file → red (count 2). Move it out of the function → red. |
| **S4** | Code-only text contains no `withCheckedContinuation` and no `withUnsafeContinuation` | Reintroduce the inner continuation — i.e. rebuild alternative (A) or the §3.3 bridge inside this file → red. **This is the one-home leg**: it makes a half-migration in this file structurally unrepresentable, which is the item's actual point. |
| **S5** *(tree-wide)* | Across every `.swift` file under `Sources/`, the only declaration of a type whose name ends in `ResumeGate` is in `DAWCore/DeadlineRace.swift` | Add `private final class AnythingResumeGate` in any module → red. This is the standing guard against the *next* hand-rolled gate, not just this one. |
| **S6** | `resolve`'s body (comments stripped) still contains all three of `case .viewController(let vc?)`, `case .viewController(nil)`, and `case .timedOut` as distinct branches | Collapse `.viewController(nil)` into the `.timedOut` branch, or map `.timedOut` to `.viewController(nil)` in the adapter → red. Pins the load-bearing nil-vs-non-nil distinction (a v2 unit legitimately returns nil and must fall through **without** a user-facing warning; a timeout must fall through **with** one). |
| **S8** ⭐ | In the brace-matched body of `requestViewControllerOnMain` (comments stripped), `case .timedOut:` maps to `return .timedOut`, and `case .value(let vc)` maps to `return .viewController(vc)` | Swap either arm — e.g. `case .timedOut: return .viewController(nil)` → red. **This leg closes a real hole the rest of the set does not cover**: that mutation leaves S1–S6 green and the build clean while silently deleting the user-facing `"custom view request timed out after 5s"` warning for every timeout. The nil-vs-timedOut distinction has **two** halves — `resolve` owns nil-vs-non-nil (S6), the adapter owns timedOut-vs-nil (S8) — and pinning only the pre-existing half would have left the half this item *introduces* unguarded. Same token-search limitation as every other leg here. |
| **S7** | The file contains no `import` of a module that would let it hand-roll a deadline… — **REJECTED, do not implement.** | *(Recorded so nobody adds it: `Foundation`/`Dispatch` are legitimately reachable; such a leg would be a tripwire with no failure mode it alone can catch, and S1/S3/S4 already cover the real one.)* |

**⚠️ S1 MUST STAY FILE-SCOPED — do not generalise it.** Measured: `Task.sleep` appears in
**20 files** under `Sources/` (SwiftUI animation delays, sidecar poll loops, retry backoff,
`TransportBroadcaster`, and `DeadlineRace` itself). A tree-wide `Task.sleep` ban is not
viable and an implementer who "strengthens" S1 that way will produce a suite that is red on
arrival for twenty unrelated legitimate uses. The property being pinned is *"this file has
no local deadline"*, not *"the tree has no sleeps"*. The tree-wide leg is **S5**, which keys
on `*ResumeGate` — measured as unique: the only hits under `Sources/` today are
`DeadlineRace.swift:101` (`DeadlineResumeGate`, the keeper) and
`AUViewResolver.swift:108,131` (the one this item deletes). After the conversion S5's
allowed set is exactly one file.

**Anti-vacuity requirement.** S1–S6 and S8 all assert *absence* or *presence* in a file located at
run time. A pin that silently finds **no file** is the cleanest possible green and the most
dangerous. The sibling suite handles this with `Issue.record("Could not locate Sources …")`
— copy it, and additionally assert one **positive** anchor in the same file (e.g.
`enum AUViewResolver` appears in the code-only text). Without that, deleting
`AUViewResolver.swift` outright would pass every leg.

**Verification the implementer owes, not just claims.** Each of S1–S6 and S8 must be
*demonstrated* red by applying its kill-mutation, observing the failure, and reverting
byte-exact (the m23-as-2a negative-control discipline). ⚠️ `git checkout` is forbidden in
this tree — revert by re-editing and verify with `grep`, not with git.

---

## 8. Second-order effects

The brief asked for the analogue of m23-at's *"abandoned work that now runs to completion
lengthens the queue everything else waits in."* There is one, and there are four more.

### 8.1 ⭐ Timeouts will start actually happening — this is user-visible
Today the timeout is main-actor-bound, so under contention it essentially **cannot** fire:
the sleeper only gets to run once the actor frees, by which point the completion has almost
always already won the gate. In practice `plugin.openUI` today returns the vendor view
*late* rather than returning generic. After the fix, a genuinely slow vendor (or a
sufficiently contended main actor) will produce `.timedOut` → **generic body + the
"custom view request timed out after 5s" warning** where the user previously got the
vendor's own UI.

That is the designed trade (design §3.3: bounded open, total ladder) and it is correct —
but it is regression-*shaped* from a user's seat and **must be in the close-out**, not
discovered from a bug report. The `.seconds(5)` budget (`:38`) is deliberately unchanged by
this item; retuning it is a separate decision with its own evidence, and raising a number to
mask a newly-honest deadline is the m23-at anti-pattern.

### 8.2 The m23-at queue-lengthening analogue — pre-existing, newly *reachable*
After a timeout, the abandoned work task keeps waiting on the vendor. When the vendor
answers, the vendor's `NSViewController` is **constructed on the main actor** — for some
vendors an expensive Metal/GL view — and then immediately released, because
`gate.resume(.value(vc))` is a no-op and the value is discarded. So main-actor work lands
*after* the generic window is already up, lengthening the queue everything else waits in.

Two honest qualifications. (i) This happens **today too**: the late completion still fires
and the VC is still dropped by the no-op gate resume. It is not new. (ii) It becomes
**more frequent**, because §8.1 makes timeouts real. Do not describe it as a regression;
describe it as a pre-existing cost that this item makes reachable.

### 8.3 The vendor request now starts *later*
`resolve` holds the main actor when it calls the adapter. Today `requestViewController` is
invoked synchronously in that same turn. After the change, the call happens inside
`DeadlineRace`'s `Task { @MainActor in … }`, which must **re-acquire** the actor — so under
contention the request may not start until well into the budget, or not at all before it
expires. We can therefore time out **without ever having asked the plug-in**.

Accepted, with the reasoning recorded: building and installing an `NSView` is itself
main-actor work, so an actor too contended to *start* the request in 5 s could not have
*finished* the open in 5 s either — starting earlier would mostly convert "timed out" into
"timed out slightly later". The measurable loss is narrow: for an **out-of-process v3**
extension, an earlier start would let XPC latency overlap the contention. Buying that back
requires firing the request before the race, which requires the bridge, which brings back
the orphan (§3), a second gate (§4E), and a build warning (§1.2). Not worth it. Alternative
(G) in §4 is the cheaper future lever if measurement ever says otherwise.

### 8.4 ⚠️ `pendingOpens` no longer serializes what its comment claims
`PluginWindowManager.openUI` (`PluginWindowManager.swift:65-69`) guards with
`pendingOpens` + `defer { remove }`, and `AUViewResolver`'s comment leans on it: *"Never
call this twice concurrently for one AU."* That guard serializes **`openUI` calls**, not
**outstanding view requests**. Once the deadline really fires, `openUI` returns at 5 s with
the first request still in flight, and the user can immediately reopen — so two
`requestViewController` calls can be outstanding on one AU.

⚠️ **Reachability is NARROWER than "the user reopens", and the doc must not overstate it.**
`openUI` short-circuits a reopen: if `controllers[key]` exists and `!ledger.isStale(key, …)`
it calls `controller.focus()` and returns (`PluginWindowManager.swift:50-55`) — **without a
second `AUViewResolver.resolve` call**. So a plain retry after a timeout does *not* produce
two outstanding requests. Reaching the overlap needs **close-then-reopen**, or an AU
instance swap that makes the ledger entry stale (`controller.close()` then fall through,
`:56-59`). Rare, but reachable — and the comment is unconditionally wrong either way.

Assessment: **benign but the comment is now wrong.** Nothing is shared between the two
requests (no gate, no box, no continuation — that is a direct benefit of the chosen shape;
the bridge form would have had a per-call object whose lifetime overlapped), each resolves
into its own abandoned task, and the stale result is discarded. Step 4 of §5 corrects the
comment. If the SDK ever turns out to dislike concurrent requests on one unit, the remedy
is a per-AU in-flight set in `PluginWindowManager` — **not** a gate back in `AUViewResolver`.

### 8.5 A bounded, silent leak survives — unchanged, not introduced
If a vendor never answers and never releases its completion block, the abandoned work task
stays suspended forever, retaining `au`. One per timed-out open. This is true today (the
block retains the `ResumeGate`; the AU retains the block) and is true after. §3.4. Not
cured here; worth a line in the close-out so it is not "discovered" later as a regression
of this change.

---

## 9. What remains unverifiable, stated plainly

* **The real `au.requestViewController` interaction cannot be tested headlessly.** There is
  no way in this tree to make a genuine third-party AU stall its view request on demand.
  Nothing in §7 covers "a vendor takes 30 s and we degrade to generic with a warning" —
  that path ships on the compiler, on `DeadlineRaceTests`, and on review. Do not let the
  green site pins imply otherwise in the close-out.
* **The async import's off-thread delivery is reasoned, not measured.** §1.2 point 2 is an
  argument from the ObjC async-import contract plus `@MainActor` isolation. It is a strong
  argument — and it is the *same* argument the current hand-written hop rests on, so this is
  not a new unknown — but no probe here observed a vendor completion arriving off-main.
* **§8.1's magnitude is unquantified.** I assert timeouts become reachable; I have not
  measured how often on a real machine with real plug-ins. Anyone tempted to retune
  `requestTimeout` on the strength of this document should measure first.
* **The SIGSEGV in §1.4 is unexplained.** Bounded, bisected as far as time allowed, not
  reproduced by any probe resembling shipping code, and no conclusion rests on it.
* **α-style reasoning is absent by design.** Unlike m23-as, this item has no timing
  quantity to normalise. The one wall-clock number (`5 s`) is a *product* budget, not a
  test threshold, and no test asserts on it.
* **`dist/DAWPro.app` will not contain this fix.** The bundle is stale (161 commands vs the
  tree's 171, last rebuilt 2026-07-28). This is an app-tier change, so the gap widens. Offer
  `scripts/bundle.sh`; **do not rebuild unilaterally.**

---

## 10. Full-Xcode / entitlement flags

**None new.** This change adds no entitlement, no AUv3 hosting capability, no code-signing
requirement, and no bundle resource. It is a pure `swift build` / `./scripts/test.sh` item
on Command Line Tools alone. (Xcode 26.6 *is* present on this machine — verified — but is
not required for this work.) The pre-existing rule stands unchanged: full Xcode is required
for app bundling, signing, and AUv3 hosting entitlements, and `plugin.openUI`'s *packaged*
behaviour lives behind that.

---

## 11. `docs/ARCHITECTURE.md` — "Key future decisions"

Settle the entry as follows (docs-scribe, at close-out):

> **Deadline racing (SETTLED, m23-at + m23-au).** `DAWCore.DeadlineRace` is the **one home**
> for racing main-actor work against a wall-clock deadline. The deadline runs on
> `Task.detached`; work runs `@MainActor` and is abandoned (never cancelled, never awaited)
> when the deadline wins; the once-gate is `NSLock`-guarded because the two resumers live on
> different executors. **No module may hand-roll a `Task.sleep`-plus-resume race.** m23-at
> converted `AUHostRegistry`'s two call sites; m23-au converted `AUViewResolver` — the last
> one — and deleted its duplicate `ResumeGate`. Enforced by
> `Tests/DAWCoreTests/DeadlineRaceTests.swift` (behaviour, 4 legs) and
> `Tests/DAWAppKitTests/AUViewResolverDeadlineSiteTests.swift` (source shape, incl. a
> tree-wide `*ResumeGate` uniqueness pin).
> **Two corrections this settled, both from compiler evidence (m23-au §1):** AppKit classes
> are `@MainActor` in the SDK and therefore *implicitly `Sendable`*, so `NSViewController?`
> crosses a `T: Sendable` generic legally — the "non-Sendable AppKit payload" obstacle does
> not exist; and `AUAudioUnit` exposes an async-imported
> `requestViewController() async -> NSViewController?`, which is why no continuation bridge
> was needed.
> **Residual, unfixed and NOT closed by this:** `DeadlineRace` makes the deadline *decide*
> on wall time; publishing the decision to a `@MainActor` caller still needs the actor a
> wedged plug-in holds (m23-av).

---

## 12. Summary of prescribed changes

| Path | Change |
|---|---|
| `/Users/dsemenov/Views/daw-pro/Sources/DAWApp/PluginUI/AUViewResolver.swift` | Add `import DAWCore`; replace `requestViewControllerOnMain` (§2.1); delete `ResumeGate` and the KNOWN-DEFECT block; correct the `pendingOpens` comment. **−45 / +30.** |
| `/Users/dsemenov/Views/daw-pro/Tests/DAWAppKitTests/AUViewResolverDeadlineSiteTests.swift` | **New.** Legs S1–S6 + S8 + the tree-wide S5, on the `EditorSurfaceOwnershipSiteTests` harness (§7). |
| `/Users/dsemenov/Views/daw-pro/docs/ROADMAP.md` | m23-au → `[x]`; close-out records §2.4, §8.1, §8.2, §8.4, §9. |
| `/Users/dsemenov/Views/daw-pro/docs/ARCHITECTURE.md` | "Key future decisions" entry per §11. |
| `/Users/dsemenov/Views/daw-pro/CHANGELOG.md` | One line. |

**Not changed:** `DAWCore/DeadlineRace.swift` (§4D, §4F), `DeadlineRaceTests.swift`,
`PluginWindowManager.swift` (§8.4 is a comment correction in `AUViewResolver`, not a code
change), the wire protocol, the MCP tool set, `requestTimeout`'s value.
