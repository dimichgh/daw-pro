# m23-al — Editor surface ownership: one home for "which surface is the user working in"

**Status:** DESIGN, ready for `swift-app-engineer`. No code written by this document.
**Author:** `daw-architect`, 2026-08-03.
**Supersedes as CAUSE:** the m23-al roadmap filing's `.onAppear`/`.onDisappear` rebuild race.
**Reads:** the orchestrator's ①–⑧ correction block in `docs/ROADMAP.md` (m23-al) and
`scripts/gates/_m23al-focus-probe.mjs` (5 sequences × 12 clicks, 3 runs, `settling=0`).

---

## 0. The decision, in one paragraph

`AppModel.pianoRollEditorFocused` is a *report of SwiftUI focus arbitration between two competing
`@FocusState` owners*, and no design that reads it can be deterministic. The fix is not to make
that flag stable. The fix is to stop routing on it and to introduce **one home for a different,
higher-level question — "which editing surface is the user working in?" — decided from app state
that the app itself writes, never from view focus.** That home is
`DAWAppKit.EditorSurfaceRouter` + the `ActiveEditorSurface` value it alone can mint
(`fileprivate init`, the `ArrangeDropSnap` pattern). The `@FocusState` layer is left **completely
untouched** in the first cycle, which is what makes the fix independent of key-window arbitration
and therefore fully provable on the unbundled staging binary. `pianoRollEditorFocused` stays fed
and stays echoed — as an *instrument*, unread by any routing decision, so the divergence between
"who holds SwiftUI focus" and "which surface is active" becomes visible on the wire instead of
being the bug.

---

## 1. Mechanism: what is confirmed, what is corrected, what stays undetermined

### 1.1 Confirmed by source (cite these, not a race)

The filing's cause is falsified — S4/S5 settle that and I re-derived the chain from source. But the
orchestrator's replacement mechanism contains one clause that source cannot support, and this
design deliberately does **not** rest on it. Three claims, each source-verifiable:

**C1 — There are two `@FocusState` owners in an ancestor/descendant pair, driven by two
independent event streams.**

| Owner | Declaration | Asserts when | Stream |
|---|---|---|---|
| Arrange workspace root | `ContentView.swift:1620` (`@FocusState private var focused`), bound `:1625` | `.onChange(of: model.arrangeKeyFocusNonce) { focused = true }` — `ContentView.swift:1695` | **per CLICK**: `DAWProApp.swift:694` (`clickClip`), `:743` (`clickTrack`) |
| Piano roll panel | `PianoRollView.swift:143`, bound `:268` | `.onAppear { isFocused = true }` — `PianoRollView.swift:275` | **per REBUILD**: `.id(clip.id)` at `ContentView.swift:661` |

The roll is a descendant of the arrange scope: `ContentView.swift:462-464` wraps
`arrangeWorkspace(geo)` — editor pane included — in the `VStack` that carries `ArrangeDeleteKey`.
`ContentView.swift:453-461` already records that this exact file was bitten once before by *"three
independent `@FocusState`s all asserting focus on the same nonce, i.e. a focus fight."* **This is
the second instance of that documented failure, not a novel risk.**

**C2 — `pianoRollEditorFocused` is a pure report of who won.** Its only writer is
`ContentView.swift:646` (`onFocusChange: { model.pianoRollEditorFocused = $0 }`), fed from
`PianoRollView.swift:279` (`.onChange(of: isFocused, initial: true)`) and `:318`
(`.onDisappear { onFocusChange(false) }`). It is therefore **not a function of any app state** —
it is a function of an arbitration outcome. Nothing in `ProjectStore`, `AppModel` or
`PanelLayoutModel` determines it.

**C3 — Therefore no consumer that reads it can be deterministic**, independent of which owner wins
in which order. That is the whole argument the fix needs, and it holds for *every* ordering rule.

### 1.2 What the data adds, and what it does not

S5 (12 clicks on one clip, zero rebuilds: `true` once at click 0, `false` ×11) proves something
source alone does not: **the arrange's per-click write demonstrably moves focus off the roll on a
rebuild-free click.** `isFocused` really went false — `PianoRollView.swift:279` is the only writer
of `false` outside `.onDisappear`, and no `PianoRollView` was created or destroyed in that
sequence.

**What stays UNDETERMINED, and this design does not assume it:** the orchestrator's clause (b) —
"writing `true` to an already-`true` `@FocusState` is not a change and arbitrates nothing" — is a
*plausible* SwiftUI rule, not a measured one, and it does **not** by itself produce S1–S3's perfect
alternation. On a switch click *both* the nonce write and the incoming instance's `.onAppear` fire;
which one lands last is SwiftUI's internal ordering, which cannot be read out of source and which
this tree cannot observe (m23-bw). The roadmap correction block's "NOW FULLY DETERMINED BY THE
DATA" over-claims by one step. **Do not inherit that phrasing into code comments.** The tree's own
law applies: an unmeasured rule is not a measured one however it reached you.

**Consequence for the design, and it is a positive one:** because the fix removes the flag from
every decision path, the ordering rule *does not need to be determined*. Any design whose
correctness argument requires knowing it is the wrong design.

### 1.3 The user-facing severity (why this is a bug, not a nit)

S5 is the finding that matters. Click a MIDI clip **twice** — an ordinary thing to do — and the
roll is unfocused from then on. ⌘+ zooms the ARRANGE for the rest of the session unless a clip
switch happens to hand focus back. The filed shape ("alternates") is the *milder* half.

---

## 2. What "the roll is the active editor" should MEAN

### 2.1 The decision

**It is NOT SwiftUI key focus. It is a higher-level app-state notion: the LAST SURFACE THE USER
ENGAGED, gated by whether that surface is on screen.** The view *reports gestures*; the app
*decides ownership*. The conflation of the two is the bug.

### 2.2 Two in-tree citations that appear to disagree, and how they resolve

- `DAWProApp.swift:468-470`: *"the roll self-focuses on appear and opens for ANY single selected
  MIDI clip, so `pianoRollEditorFocused` alone is already true when the user has merely clicked a
  clip in the arrange."* This is **descriptive**, inside the doc comment for a *different* property
  (`pianoRollNoteSelection`), and its job there is to argue why focus is a bad *nudge guard*. It
  states what the flag's value **is**. It does not state what zoom routing **should do**.
- `PianoRollNoteSelectionBridge.swift:51-53`: *"The flag is still fine for what m21-c uses it for —
  routing ⌘+/⌘−/⌘0 to **whichever zoom the user most recently engaged**."* This is **normative
  about m21-c** and is the only sentence in the tree that states the intended routing rule.

**Last-engaged wins.** It is the normative citation, it matches Logic's active-area model (clicking
in an area makes it the zoom target), and it is the only reading that survives the "click a clip,
roll opens" case without surprising the user. The orchestrator's reading of `:468-470` as "STABLY
TRUE is the documented intent" reads a description as a specification; I am overruling it, and
saying so rather than hedging.

### 2.3 The rule, stated so an implementer needs nothing else

> **The active editor surface is `.pianoRoll` iff the piano roll is open AND the most recent
> user engagement was inside the roll. Otherwise `.arrange`.**

No transition terms, no "the roll just opened counts as engaging it" special case, no focus term.
Gesture *location* sets engagement; roll-not-open forces `.arrange`.

### 2.4 The accepted consequence, named up front

Clicking a MIDI clip in the arrange opens the roll **and leaves the arrange active**, so ⌘+ zooms
the arrange. To zoom the roll, click in it first. This is deliberate:

- it is what "most recently engaged" means;
- it makes the *whole app* give one answer to "which surface is the user working in" — the same
  gesture that gives the arrange DELETE (m23-y) gives it ⌘+;
- neither surface loses reachability: the arrange keeps its toolbar cluster and pinch, the roll
  keeps its header cluster (`PianoRollView.swift:782/790`) and pinch (`:826`).

**The alternative, should the orchestrator or user overrule me:** "opening the roll engages it" is
a *one-line change inside `resolve(...)`* — add an `openedBy` term or make `rollOpen` alone decide.
That the overrule costs one line, in one file, with one test table to update, is the entire point
of building a home. Do not scatter the choice.

---

## 3. The ONE HOME

### 3.1 New file: `Sources/DAWAppKit/EditorSurfaceRouter.swift`

DAWAppKit, not DAWApp: `DAWApp` has no test target (stated at `DAWProApp.swift:1246`-adjacent and
throughout), and this rule must be unit-tested headlessly like `ArrangeNudge.step`,
`ArrangeSelection` and `PianoRollNoteSelectionBridge.shouldDropNotes`.

```
public enum EditorSurface: String, Sendable, Equatable, CaseIterable { case arrange, pianoRoll }

public struct ActiveEditorSurface: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case notArrangeWorkspace  // the Mix console is up — no roll is MOUNTED at all
        case noRollOpen           // arrange workspace, but no MIDI clip open
        case engagedArrange       // roll on screen, last engagement was the arrange
        case engagedRoll          // roll on screen, last engagement was the roll
    }
    public let surface: EditorSurface
    public let reason: Reason
    fileprivate init(surface:reason:)          // ← unrepresentable elsewhere
}

public enum EditorSurfaceRouter {
    nonisolated public static func resolve(workspaceIsArrange: Bool,
                                           rollOpen: Bool,
                                           lastEngaged: EditorSurface) -> ActiveEditorSurface
}
```

`resolve` is total, pure, `nonisolated`, and four lines, in this order:
`workspaceIsArrange == false → (.arrange, .notArrangeWorkspace)`;
`rollOpen == false → (.arrange, .noRollOpen)`;
`lastEngaged == .pianoRoll → (.pianoRoll, .engagedRoll)`; else `(.arrange, .engagedArrange)`.

**THE WORKSPACE TERM IS NOT OPTIONAL AND IS THE EASIEST THING TO DROP.** `openEditorClip`
(`DAWProApp.swift:1490-1498`) is derived purely from `selectedClipID` + a store lookup and carries
**no workspace term** — but the editor pane is rendered inside `arrangeWorkspace`, so in the **Mix
console** a MIDI clip can stay selected while no `PianoRollView` is mounted at all. Without this
term, a latched `lastEngaged == .pianoRoll` makes the router zoom a roll the user cannot see. The
tree already treats this as a first-class guard rather than an afterthought: `handleArrangeNudgeKey`
opens with `guard workspaceMode == .arrange` (`DAWProApp.swift:1275`) **separately from** its
`openEditorClip` term, and `ContentView.swift:1261-1264` records that the Mix workspace is a
mutually exclusive branch of `switch model.workspaceMode`, which is why the master lane editor
reports nothing. A home that silently drops the term two existing sites carry *is* the divergence
this home exists to prevent.

`.arrange` (not "no surface") is the right Mix fallback: there is no mixer zoom, so ⌘+ zooming the
arrange behind the console is the existing, harmless behaviour, and adding a third `EditorSurface`
case would create a state every consumer would have to handle for no benefit.

**A `Bool`, not `WorkspaceMode`, and that is a module boundary, not laziness:** `WorkspaceMode` is
declared in `DAWApp` (`DAWProApp.swift:52`), which DAWAppKit must not depend on. The parameter is
named `workspaceIsArrange` so a caller cannot pass the wrong polarity by accident.

### 3.2 The engagement holder: `EditorSurfaceEngagement` (same file)

`@MainActor @Observable public final class`, the `PianoRollNoteSelectionBridge` /
`AutomationPointSelectionBridge` shape:

- `public private(set) var lastEngaged: EditorSurface = .arrange` — the app starts in the arrange
  and there is no fourth state; no `Optional`, because "nobody has engaged anything yet" and "the
  arrange is engaged" have identical consequences and a nil would be a state no consumer could act
  on differently.
- `public private(set) var transitionSeq = 0`
- `public func engage(_ surface: EditorSurface)` — **change-guarded**:
  `guard surface != lastEngaged else { return }`, then set + `transitionSeq &+= 1`.
  The guard is load-bearing, not an optimisation: `beginGesture` and `scrubDrag.onChanged` fire on
  every drag tick, and an unguarded `@Observable` write invalidates every observer of this object
  on every tick of every note drag. **The seq counts TRANSITIONS, not calls** — say so in the doc
  comment, because `keyFocusNonce` (`DAWProApp.swift:4165`) counts calls and a reader who assumes
  the same shape will write a gate leg that cannot fail.

### 3.3 The single accessor, on `AppModel`

```
var activeEditorSurface: ActiveEditorSurface {
    EditorSurfaceRouter.resolve(workspaceIsArrange: workspaceMode == .arrange,
                                rollOpen: openEditorClip != nil,
                                lastEngaged: editorEngagement.lastEngaged)
}
```

Both inputs are passed **raw** — no term is pre-combined into a `rollVisible` Bool at this
accessor. Folding them here would put half the rule in `DAWApp` where nothing can test it and
would give `ActiveEditorSurface.Reason` nothing to distinguish, which is the second-computation
seam in miniature.

`openEditorClip` (`DAWProApp.swift:1490`) is already the tree's ONE rule for "is the roll on
screen" — `ContentView`'s editor branch renders exactly when it is non-nil, and the
`debug.arrangeSelection` echo reports exactly it. This home *consumes* that home; it does not fork
it.

### 3.4 What this home OWNS

1. The answer to "which editing surface is the user working in", as a value, with its reason.
2. The latch that remembers the last engagement, and the only mutator of it.
3. The rule that a closed roll can never be the active surface.

### 3.5 What this home MUST NOT own

- **Any `@FocusState`, any SwiftUI focus concept, any `NSResponder` notion.** If a future edit adds
  a focus term to `resolve`, the whole point is lost — it becomes the current bug with more steps.
- **Which keystroke goes where.** DELETE and ←/→/↑/↓ arbitration stays exactly where it is
  (`handleArrangeDeleteKey`, `handleArrangeNudgeKey`'s six guards, the roll's own
  `.onKeyPress(.delete)`). See §5. Migrating those onto this home is m23-al-3 and is explicitly
  **not** in this arc.
- **Zoom ARITHMETIC.** `ArrangeZoom` / `PianoRollZoom` keep the ladders; this only says *which*.
- **Persistence.** Engagement is session state; it must not reach `PanelLayoutModel` (which
  persists) or a project file. A restored "the roll was engaged" with no roll open would be a
  latched lie, the exact failure `PianoRollNoteSelectionBridge.clear()` exists to prevent.

### 3.6 How divergence is made unrepresentable — honestly

Three mechanisms, and the first one alone is **not** sufficient. Say all three in the file's banner:

1. **`fileprivate init` on `ActiveEditorSurface`.** The only way to *hold* a verdict is to have
   called `resolve`. This is the `ResolvedDropBeat` property (`ArrangeDropSnap.swift:44`), and its
   honest limit is the same one: it prevents *holding* an unresolved verdict; it cannot prevent
   someone writing `if openEditorClip != nil { zoomPianoRollIn() }` — a divergent boolean that
   never constructs the type. **Do not overstate it in the comment.**
2. **A READER SITE TEST** — the mechanism that closes (1)'s gap, and the tree's own precedent
   (`RenderClockTrustSiteTests`, `StartAnchorPolicySiteTests`, `ContinuationResumeStateSiteTests`
   in `Tests/DAWEngineTests/`; `#filePath` anchoring idiom at
   `Tests/DAWAppKitTests/PollDisciplinePinTests.swift:35`). New:
   `Tests/DAWAppKitTests/EditorSurfaceOwnershipSiteTests.swift`, asserting on the *text* of
   `Sources/DAWApp/`:
   - `openEditorClip` is read by an enumerated set of sites and `activeEditorSurface` is the only
     new one (pin the count of `openEditorClip` occurrences; the existing readers are the nudge
     guard `:1312`, the echo `:4112`, `ContentView`'s editor branch and this accessor).
   - `pianoRollEditorFocused` appears **nowhere inside the bodies of `zoomIn`/`zoomOut`/
     `zoomReset`**. This is the test that fails if anyone routes on it again.
     ⚠️ **Do NOT pin it to "exactly three occurrences."** It legitimately appears in doc comments
     at `DAWProApp.swift:469`, `:1218` and `:1284` — and the last two are the nudge guard's
     *"deliberately not a term here"* argument, which must SURVIVE. Pin the router bodies (extract
     the three functions' text between their braces), and if a whole-file count is also wanted,
     strip `//` and `///` lines first and re-measure against the final tree.
   - `activeEditorSurface` appears only in the three router entry points and the echo.
3. **A NO-FEEDBACK site assertion, in the same test.** No `engage(` call may appear inside
   `zoomIn`/`zoomOut`/`zoomReset`/`setArrangeZoom`/`zoomArrangeIn/Out/Reset`/
   `zoomPianoRollIn/Out/Reset`. A router that engages the surface it routed to is self-confirming
   and latches forever; this is exactly the kind of "improvement" an implementer adds while tidying
   up, and a comment will not stop it. Assert it as text over `DAWProApp.swift`.

---

## 4. Where engagement is reported

### 4.1 Arrange (`.arrange`) — 5 sites, all already ONE-handler funnels

| Site | File:line | Note |
|---|---|---|
| `clickClip` | `DAWProApp.swift:694` (beside the nonce bump) | THE one click handler; the `ClipBlock` tap (`ContentView.swift:940-942`) and `debug.arrangeSelection {act:"click"}` both land here |
| `clickTrack` | `DAWProApp.swift:743` | m23-y's twin |
| `applyArrangeMarquee` | `DAWProApp.swift:767-774` | note it deliberately does NOT bump the focus nonce; it SHOULD engage — a band is unambiguously an arrange gesture |
| arrange toolbar zoom `+` / `−` / reset buttons | `ContentView.swift` `arrangeToolbar` (from `:951`) | the button, **not** `setArrangeZoom` — see the no-feedback rule |
| arrange pinch | **`arrangePinchChanged(anchorContentX:magnification:)`** — `DAWProApp.swift:3399`, first line (VERIFIED: it is the gesture-state entry and writes `panelLayout.setArrangePPB` directly, **not** through `setArrangeZoom` or the router, so it is safe under §3.6(3)) | optional in al-1; if omitted, name it as a known gap. Do **not** put it in `arrangePinchEnded` (`:3412`) or `setArrangeZoom` (`:3341`) |
| `noteCreatedClip` | `DAWProApp.swift:674-678`, beside `arrangeSplitRefusal = nil` | **easy to miss:** the empty-lane create sets `selectedClipID` directly and does **not** go through `clickClip`, so it neither bumps the nonce nor engages. Without it, a user who was editing notes and then double-clicks an empty arrange lane gets a new clip with the roll still engaged and ⌘+ aimed at the roll |

### 4.2 Piano roll (`.pianoRoll`) — 6 enumerated funnels, via one new closure

Add **one** parameter to `PianoRollView`: `var onEngage: () -> Void = {}`, wired at
`ContentView.swift` beside `onFocusChange:` (`:646`) as
`onEngage: { model.editorEngagement.engage(.pianoRoll) }`.

Call it at exactly these funnels:

| # | Site | File:line | Covers |
|---|---|---|---|
| R1 | `beginGesture(at:)`, first line | `PianoRollView.swift:1194` | every grid press: note click, move, resize, empty-grid click — the `gridDrag` funnel (`:1172-1192`, attached `:976`) |
| R2 | `scrubDrag.onChanged`, first line | `PianoRollView.swift:1148` | ruler scrub (attached `:1140`) |
| R3 | `gridPinch.onChanged`, first line | `PianoRollView.swift:827` | pinch-zoom the roll (attached `:979`) |
| R4 | the double-tap add-note `onEnded` | `PianoRollView.swift:981` | add note on empty grid |
| R5 | the header zoom cluster's two buttons | `PianoRollView.swift:782`, `:790` | the roll's own `−` / `+` |
| R6 | `commit()` | `PianoRollView.swift:444` | **VERIFIED coverage, not assumed:** its only three callers are the roll's own `.onKeyPress(.delete)` (`:272`), the double-tap add (`:988`) and `endGesture` when the note moved (`:1233`) — all user gestures, **no non-gesture caller**, so it cannot false-engage. It ALSO catches the **velocity lane**, which commits through it (`VelocityLane(model:noteColor:onCommit: commit)`, `:1285`) |
| R7 | `commitControllerLane()`, first line | `PianoRollView.swift:1350` | **the controller strip does NOT go through `commit()`** — `ControllerLaneStrip` carries its own `onCommit` (`ControllerLaneStrip.swift:36`, fired at `:354`), threaded to this separate funnel at `PianoRollView.swift:1344`. Missing this means editing a CC lane never engages the roll |
| R8 | the `KeyboardSidebar` call site — wrap the `onAudition` argument | `PianoRollView.swift:939-940` | the gutter keyboard is a `DragGesture` in another file (`KeyboardSidebar.swift:45`, attached `:127`); wrapping the closure **at this call site** engages without editing that file. ⚠️ Wrap only THIS argument — `PianoRollView` also calls `onAudition` from `applyGesture` and from `.onDisappear` (`:325`, `onAudition([], 0)`), and engaging on teardown would be a false engage |

R6 makes R1/R4 redundant for *mutating* gestures; keep all of them anyway — R1 fires on a
**selection-only** click (`activeDrag = .click`, `:1205`), which mutates nothing and must still
engage.

**Narrowed claim, stated rather than rounded up:** a controller-lane drag that ends with
`didEdit == false` (`ControllerLaneStrip.swift:354`) does not commit and therefore does not engage.
Accepted: it changed nothing, and the alternative is editing a child view to report a gesture that
had no effect.

### 4.3 REJECTED: a single root `.simultaneousGesture` on `PianoRollView.body`

I drafted this first (one site, structurally complete: any pointer-down anywhere in the roll's
bounds), and it is the wrong call:

- **Nothing in this tree can prove it fires** on a click inside the grid's descendant `ScrollView`.
  Its correctness rests on exactly the class of unobservable SwiftUI behaviour this item exists to
  get *out* of the design (m23-bw).
- **Its failure is silent and total.** If it does not fire, the roll can never be engaged, ⌘+ never
  routes to the roll, and m21-c's whole feature is dead — while every gate leg except E still
  passes. An enumerated funnel that someone forgets costs one gesture; this costs the feature.

The enumerated funnels are plain Swift calls that a pin test can count, which is strictly better
than a mechanism that is invisible to every test in the repo.

### 4.4 The drift guard for §4.2

`Tests/DAWAppKitTests/EditorSurfaceOwnershipSiteTests.swift` also pins the **count of gesture
attachments** under `Sources/DAWApp/PianoRoll/` — occurrences of `.gesture(`,
`.simultaneousGesture(`, `.onTapGesture` (measured: 4 in `PianoRollView.swift` at `:976`, `:979`,
`:980`, `:1140`; **re-measure across the whole directory before writing the number — do not copy
mine**). A seventh gesture reddens the test and forces the author to decide whether it engages.
Copy `PollDisciplinePinTests.swift`'s `#filePath` root-walk (`:35-45`) verbatim, including its
`Issue.record` when `Sources/` cannot be located — a pin test that silently finds no files is the
"synthetic probe the tool never read" failure the memory names.

---

## 5. DELETE keeps working — because nothing in the key path changes

**Cycle 1 changes ZERO focus behaviour.** `PianoRollView.swift:275` (`.onAppear { isFocused =
true }`), `ContentView.swift:1695` (`.onChange(of: nonce) { focused = true }`), both nonce bumps,
and every one of `handleArrangeDeleteKey`'s four guards and `handleArrangeNudgeKey`'s six are
untouched. `pianoRollEditorFocused` keeps alternating exactly as measured. It simply stops being
read by anything that decides anything.

### 5.1 Tests and gates that would prove a regression, and what they assert after this change

| Artefact | What it protects | Changed by al-1? |
|---|---|---|
| `scripts/gates/m23y-track-select.mjs` | header click selects + bumps `keyFocusNonce`; DELETE reaches the clips | **No.** Nonce semantics and count unchanged; `clickTrack` gains one `engage` call that touches no field it asserts on. ⚠️ Its A2p probe is already narrowed by m23-ak (roadmap m23-bw ③) — that narrowing is pre-existing and this design does not touch it. |
| `scripts/gates/m23x-arrow-nudge.mjs` | `refusedBy: piano-roll-note-edit` fires iff roll open AND notes selected | **No.** The fifth guard's two terms (`openEditorClip != nil`, `pianoRollNoteSelection.hasSelection`) are unchanged and still contain no focus term. |
| `scripts/gates/m23ai-automation-nudge-guard.mjs` | sixth guard, the lane-set version | **No.** |
| `scripts/gates/m23ak-note-selection-drop.mjs` | widened arrange selection drops the roll's note claim | **No.** `shouldDropNotes` and the `arrangeSelection` `didSet` are untouched. ⚠️ Its L4d/L4e legs are the ones my predecessor's mutant showed to be the load-bearing pair; do not disturb them. |
| `Tests/DAWAppKitTests/WidenedArrangeSelectionDropTests.swift` | m23-ak's pure predicate | **No.** |
| `Tests/DAWAppKitTests/ArrangeVerticalNudgeTests.swift`, `ArrangeNudge*` | modifier policy | **No.** |
| Suite baseline **4633 / 477, zero ✘** | — | al-1 ADDS tests (§9); it must not change any existing assertion. **If an implementer finds themselves editing an existing assertion, they have left the design.** |

### 5.2 Why the arrange keeps DELETE, stated as the invariant

`clickClip`'s comment (`DAWProApp.swift:690-693`) says the nonce must be bumped on *every* click,
including a re-click, because *"opening the piano roll steals focus back (its `.onAppear`), so a
one-shot flag would leave the arrange permanently unfocused for MIDI."* That reasoning is
**unaffected** — al-1 removes no bump and adds no competing focus write. The two requirements stop
fighting not because one yielded, but because **they were never about the same thing**: DELETE
routing is about SwiftUI key focus; zoom routing is about which surface the user is working in.
Cycle 1 separates them; cycle 2 (§11) makes the focus layer *follow* the surface decision rather
than compete with it.

---

## 6. Key-window residue — the bound

**al-1's correctness does not depend on `@FocusState` arbitration at all.** Every term in the
decision is app state the app itself writes:

- `rollOpen` ← `openEditorClip` ← `selectedClipID` + a store lookup. No focus.
- `lastEngaged` ← explicit `engage(_:)` calls from gesture funnels. No focus.
- the verdict ← a pure function of those two.

So the fix behaves identically in a key window and in the unbundled staging binary, and the gate's
green is a real green rather than a green that happens to hold when no key events are delivered.
**That is the single most valuable property of this design and it is why the `@FocusState` layer is
out of scope for cycle 1.**

**The one link the gate cannot prove**, stated as a debt and not hidden: *gesture → `engage`*. The
seam calls `engageSurface` directly; a mutant that deletes the call from `PianoRollView.swift:1194`
passes every wire leg. Its substitute is **structural, not a gate leg**: the site test of §3.6(2)
asserts each of R1–R8 exists in source, and §4.4's count pin catches a new gesture. Same class as
m23-aj-3's leg G and m23-ak's DELETE half — say so in the gate's banner so the next reader does not
rediscover it as a surprise.

---

## 7. Wire and seam additions

### 7.1 `debug.viewZoom` — new debug command (app tier)

Registered in the `installDebugCommands` switch at `Sources/DAWApp/DAWProApp.swift:2927-…` (insert
beside `debug.arrangeZoom`, `:2941`). Params: `act` = `"in" | "out" | "reset"`, optional (omitted →
report only). It calls **`model.zoomIn()` / `zoomOut()` / `zoomReset()` — the SAME router the View
menu (`ViewCommands.swift:20/22/24`) and the ⌘= alias (`ContentView.swift:326`) call.** Not the
per-surface entry points; routing through the router is the entire thing under test.

Response object (report-only when `act` is absent):

```
{ "activeSurface": "arrange" | "pianoRoll",
  "reason": "noRollOpen" | "engagedArrange" | "engagedRoll",
  "lastEngaged": "arrange" | "pianoRoll",
  "engagementSeq": <int>,               // TRANSITIONS, not calls
  "rollOpen": <bool>,
  "arrangePPB": <number>, "pianoRollPPB": <number>,
  "pianoRollEditorFocused": <bool> }    // the instrument, NOT an input
```

Both PPBs on every read so a gate can baseline with the same call it asserts with (the
`automationPointSelection` echo law, `DAWProApp.swift:4138-4143`).

**Why debug-tier and not an agent-facing `view.zoom`:** `debug.*` lives off `allCommands` / MCP
parity by convention — stated at `Sources/DAWControl/Commands.swift:5093`. So this addition leaves
the pins **allCommands 171 / MCP 174 / catalog 74 GREEN**, which is correct for a bug fix. The
one-command-surface invariant is already satisfied for the *capability*: both zoom slots are
wire-settable via `debug.panelLayout` (`DAWProApp.swift:3128/3147`) and `debug.arrangeZoom`. What
is not wire-reachable is the **router**, which is a UI affordance (a key equivalent's target), not
a capability. **Do not add `view.zoom` in this item** — it would redden three pinned counts for no
capability gain.

### 7.2 `debug.arrangeSelection {act:"engage", surface:"arrange"|"pianoRoll"}`

Added to the `act` switch at `DAWProApp.swift:3903-…`, following the `pianoRollNotes` (`:3940`) and
`automationPoints` (`:3959`) precedents. Rules:

- Calls `editorEngagement.engage(...)` — **the same method the gesture funnels call.**
- **THROWS when unsatisfiable**, following `automationPoints`' law (`:3983-3993`): staging
  `surface:"pianoRoll"` with `openEditorClip == nil` must be TOLD
  (`DebugError("act \"engage\" surface \"pianoRoll\" needs an open piano roll")`), never answered
  green. A gate that reads `ok` for an engagement the resolver will immediately override as
  `.arrange` has been handed a false "fixture armed" — the m23-x failure class (9 of 46 red, every
  one a control half).
- **Does NOT force `workspaceMode`**, unlike `act:"click"` (`:3910`) and `act:"clickTrack"`
  (`:3930`). Engagement is not a workspace-scoped gesture and a gate must be able to set up the Mix
  case if it ever wants to.
- **Needs no runloop pump**, unlike `pianoRollNotes` (`:3951-3958`) and `automationPoints`
  (`:3971-3982`): engagement is synchronous app state, not a value a view has to apply on the next
  turn. Say this in the comment or somebody will paste the pump in.

### 7.3 Additive echo fields on `debug.arrangeSelection`

Add beside `pianoRollEditorFocused` (`DAWProApp.swift:4132`), never replacing it:
`"activeEditorSurface"`, `"activeEditorSurfaceReason"`, `"lastEngagedSurface"`,
`"engagementSeq"`. Keeping the old field fed and echoed alongside the new verdict is what makes the
*divergence* observable — precisely the instrument m23-bw needs and precisely the thing that was
invisible for two cycles.

---

## 8. The gate

`scripts/gates/m23al-editor-surface.mjs` (non-`_`-prefixed; grows the corpus 58 → 59). Fixture:
reuse `_m23al-focus-probe.mjs`'s — 4 MIDI clips **with notes** on one track (a noteless clip is a
different fixture). Staging port **17695** only; PIDFILE-exact teardown via `_staging.mjs`.

**⚠️ The roadmap's stated gate ("stable across 12 consecutive clip switches") is INADEQUATE** — it
is Leg B alone, and Leg B alone passes on a fix that only handles rebuilds, which is exactly what
S4/S5 expose.

### 8.1 Legs

| Leg | Setup | Assert |
|---|---|---|
| **A** baseline, roll closed | `act:"clear"` | `activeSurface == "arrange"`, `reason == "noRollOpen"`; `viewZoom{act:"in"}` raises `arrangePPB`, leaves `pianoRollPPB` byte-identical |
| **B** S3-shape switches | 12 clicks A,B,C,D×3 | after **every** click: `activeSurface == "arrange"`, and `viewZoom{act:"in"}` moves the arrange (12/12) |
| **C** ⭐ S5-shape repeats | 12 clicks on **one** clip | same, 12/12. **The leg the roadmap's gate lacks.** |
| **D** S4-shape | 12 clicks A,A,B,B,… | same, 12/12 |
| **E** ⭐ roll engaged | click a clip, then `act:"engage", surface:"pianoRoll"` | `activeSurface == "pianoRoll"`, `reason == "engagedRoll"`; `viewZoom{act:"in"}` raises `pianoRollPPB` and leaves `arrangePPB` byte-identical. **Anti-vacuity: without E, a fix that hardwires `.arrange` passes B/C/D.** |
| **F** re-armability | engage roll → **repeat**-click the same clip → engage roll again | `.pianoRoll` → `.arrange` → `.pianoRoll`; `engagementSeq` grows by exactly 3. The m23-ak law: a desynchronised latch can never be RE-claimed |
| **G** ⭐ close while engaged | engage roll → `act:"clear"` | `activeSurface == "arrange"`, `reason == "noRollOpen"`, while `lastEngaged` is still `"pianoRoll"`. **Proves `rollOpen` is a live term and the latch is not consulted when the surface is gone.** |
| **H** all three entry points | with `.pianoRoll` active and `arrangePPB` set to a non-default via `debug.panelLayout` | `act:"out"` moves only the roll; `act:"reset"` resets only the roll and leaves `arrangePPB` at the non-default. Proves in/out/reset all read the one home |
| **I** ⭐ invariance to the old flag | across B and C, record `pianoRollEditorFocused` per row | **fixture-armed check first**: both `true` and `false` must appear (S1–S3 guarantee 6/6) — if not, FAIL the leg loudly as vacuous. Then: `activeSurface == "arrange"` on the `true` rows AND on the `false` rows. **The routing verdict is invariant to the alternating flag.** |
| **J** seam honesty | `act:"engage", surface:"pianoRoll"` with no roll open | the call **throws**; a green answer is a failure |
| **K** ⭐ Mix workspace | click a clip, engage the roll, then `ui.showMixer {"show": true}` (VERIFIED signature — `show` is optional, defaults true, returns `{"mode":"mix"}`; restore with `{"show": false}` before the next leg) | `activeSurface == "arrange"`, `reason == "notArrangeWorkspace"`, while `rollOpen` is still `true` and `lastEngaged` is still `"pianoRoll"`. **Proves the workspace term is live** — without it a latched roll engagement zooms an unmounted editor behind the console |

Every PPB comparison must be against a value read in the **same call** that performs the act (§7.1
returns both), never against a remembered constant.

### 8.2 Mutants — one per load-bearing leg

| Mutant | Change | Must redden |
|---|---|---|
| **M1** | `zoomIn/Out/Reset` revert to `if pianoRollEditorFocused` | **I**, plus roughly half of **B**'s rows (the `true` ones) |
| **M2** | `resolve` returns `.arrange` unconditionally | **E**, **F**(second half), **H**. *Nothing else.* **This is the mutant the roadmap's stated gate cannot kill.** |
| **M3** | `resolve` returns `.pianoRoll` whenever `rollOpen` (drop the engagement term) | **B**, **C**, **D** (all rows) |
| **M4** | `resolve` drops the `rollOpen` term | **G** only |
| **M5** | remove `engage(.arrange)` from `clickClip` | **B**, **C**, **D**, **F** |
| **M6** | remove the change-guard in `engage` (seq bumps on every call) | **F**'s exact `+3` |
| **M7** | leave `zoomReset()` reading the old flag while in/out migrate | **H** only |
| **M8** | `act:"engage"` answers `ok` instead of throwing when no roll is open | **J** only |
| **M9** | `resolve` drops the `workspaceIsArrange` term | **K** only |

Every mutant must be applied and reverted **by editing and re-editing the source** — `git
checkout`/`stash`/`restore` are FORBIDDEN in this tree. Write the mutant patch to the scratchpad
first so the revert is mechanical.

### 8.3 Red baseline first

Run the gate against the **unpatched** tree before writing a line of the fix. The baseline must be
RED, and it must include **Leg C** among the red legs. If C is green on the unpatched tree the
fixture is not reproducing S5 and the gate is measuring nothing — stop and fix the fixture. Record
the baseline leg-set (not just the count) in the close-out: m20-e's lesson is that a race can make
the total a RANGE, so **pin the SET of legs that redden, never the count.**

---

## 9. Swift tests

1. `Tests/DAWAppKitTests/EditorSurfaceRouterTests.swift` — the full 2×2×2 truth table for `resolve`
   (`workspaceIsArrange` × `rollOpen` × `lastEngaged` — all 8 rows, no omissions: the four
   `workspaceIsArrange == false` rows are what pin M9), asserting both `surface` **and** `reason`; `EditorSurface`
   round-trips its `rawValue` (the wire depends on it); `engage` is change-guarded (two identical
   engages → `transitionSeq` +1, not +2); `engage` alternating → +2. Non-`@MainActor` for `resolve`
   (it is `nonisolated`); `@MainActor` for the engagement class. The actor-freedom of `resolve` is
   itself the structural claim that the rule needs no app, view or actor — the
   `WidenedArrangeSelectionDropTests` precedent.
2. `Tests/DAWAppKitTests/EditorSurfaceOwnershipSiteTests.swift` — §3.6(2), §3.6(3), §4.4.

Expected suite delta: **+~12 tests / +2 suites** over the 4633 / 477 baseline. Run with
`./scripts/test.sh` **backgrounded** (~90 s) and grep `^✘` — the wrapper **exits 0 on failure**.

---

## 10. Implementation order (m23-al-1)

1. **Red baseline.** Write `scripts/gates/m23al-editor-surface.mjs` (§8) against the *current*
   tree. Confirm it is RED and that **Leg C** is among the red legs. Save the leg-set.
2. `Sources/DAWAppKit/EditorSurfaceRouter.swift` — §3.1, §3.2. Banner comment carries: the three
   confirmed claims (§1.1), the undetermined ordering rule (§1.2, explicitly labelled
   undetermined), the product decision with **both** citations (§2.2), and the honest limit of
   `fileprivate init` (§3.6).
3. `Tests/DAWAppKitTests/EditorSurfaceRouterTests.swift`. Green before touching `DAWApp`.
4. `Sources/DAWApp/DAWProApp.swift`: `let editorEngagement = EditorSurfaceEngagement()` beside
   `pianoRollNoteSelection` (`:473`); `var activeEditorSurface` beside `openEditorClip` (`:1490`);
   `engage(.arrange)` at `:694`, `:743`, `:767`, `:3399`, and in `noteCreatedClip` beside
   `arrangeSplitRefusal = nil` (`:676`); rewrite
   `zoomIn/zoomOut/zoomReset` (`:3368-3376`)
   to switch on `activeEditorSurface.surface`. **Leave `:463` `pianoRollEditorFocused` declared,
   written and echoed; update its doc comment to say it is an instrument, not a routing input, and
   why.**
5. `Sources/DAWApp/ContentView.swift`: `onEngage:` beside `onFocusChange:` (`:646`); arrange
   toolbar zoom buttons engage `.arrange`.
6. `Sources/DAWApp/PianoRoll/PianoRollView.swift`: the `onEngage` parameter (beside
   `onFocusChange` at `:85`/`:173`/`:192`) and the eight call sites R1–R8 (§4.2).
7. Seams: `debug.viewZoom` (§7.1) at `:2927`-switch + handler; `act:"engage"` (§7.2) at `:3903`;
   echo fields (§7.3) at `:4132`.
8. `Tests/DAWAppKitTests/EditorSurfaceOwnershipSiteTests.swift` (§9.2). **Re-measure** every pinned
   count against the final tree; never copy a number from this document.
9. Full suite backgrounded; grep `^✘`. Gate GREEN. Then M1–M8, each applied and reverted by hand,
   recording which legs reddened.
10. Re-run `scripts/gates/m23y-track-select.mjs`, `m23x-arrow-nudge.mjs`, `m23ai-automation-nudge-guard.mjs`,
    `m23ak-note-selection-drop.mjs` — all must stay at their recorded totals (§5.1).
11. Verify the wire pins are **unchanged**: allCommands 171 / MCP 174 / catalog 74. Count
    `CopilotTool(` in `Sources/DAWControl/CopilotCatalog.swift` — **not** in `Sources/AIServices/`,
    which returns a confident 0.

**Orchestrator close-out (not the implementing agent's):** roadmap tick + ORCH record + CHANGELOG +
memory patch + baselines, and add the ARCHITECTURE.md entry below.

### 10.1 `docs/ARCHITECTURE.md` "Key future decisions" entry (§165), to be added at close-out

> **Editor surface ownership: which surface the user is WORKING IN is app state, not SwiftUI focus
> (m23-al, settled 2026-08-03).** `EditorSurfaceRouter.resolve(workspaceIsArrange:rollOpen:lastEngaged:)` in DAWAppKit
> is the ONE home; `ActiveEditorSurface` has a `fileprivate init` so a verdict cannot be minted
> elsewhere, and `EditorSurfaceOwnershipSiteTests` pins the readers and forbids `engage` inside any
> zoom entry point. Zoom routing (m21-c ⌘+/⌘−/⌘0) reads this and nothing else.
> Three terms, and the workspace one is load-bearing: in the Mix console `openEditorClip` stays
> non-nil with no roll mounted, so a latched roll engagement would zoom an invisible editor.
> **Rejected: reading `@FocusState`** (the status quo — measured non-deterministic: the flag is a
> report of arbitration between two competing `@FocusState` owners, `ContentView.swift:1620` vs
> `PianoRollView.swift:268`, driven by a per-click and a per-rebuild stream; 12 repeat clicks on
> ONE clip read `true` once and `false` eleven times, so an ordinary double click leaves ⌘+ aimed at
> the wrong surface for the session). **Rejected: "roll open ⇒ roll is active"** (deterministic and
> one line, but it takes ⌘+ away from the arrange for as long as any MIDI clip is selected, and it
> contradicts m21-c's own stated rule — "whichever zoom the user most recently engaged",
> `PianoRollNoteSelectionBridge.swift:51-53`). **Known limit, filed not hidden:** the
> `@FocusState` layer still has two competitors and `pianoRollEditorFocused` still alternates; it is
> now an *instrument* (echoed, unread) rather than an input. Making the focus layer follow this home
> is m23-al-2, blocked on m23-bw ① (a bundled staging app with a real key window).

---

## 11. Scope split

### m23-al-1 — the home + zoom routing. **Stands alone. Do this one.**
Everything in §3–§10. Fully provable on the unbundled staging binary; changes no focus behaviour;
changes no existing assertion. **This closes the user-facing bug.**

### m23-al-2 — the `@FocusState` layer becomes a SLAVE to the home. **BLOCKED on m23-bw ①.**
`PianoRollView.swift:275` `.onAppear { isFocused = true }` becomes conditional on
`activeEditorSurface.surface == .pianoRoll`, plus a symmetric
`.onChange(of: model.activeEditorSurface.surface)` that asserts focus when the roll becomes active
— exactly mirroring `ArrangeDeleteKey`'s `.onChange(of: arrangeKeyFocusNonce)`
(`ContentView.swift:1695`). Both owners then read the **same** decision and can no longer both
assert; `pianoRollEditorFocused` becomes stable as a *consequence* rather than as a goal.

**Blocked, not merely "needs a human":** it changes *who holds key focus*, which is the
m23-y / m23-x / m23-ak path, and this tree cannot deliver a key event (`delivered:false`,
m23-g1). Sequence it after m23-bw ① decides whether `scripts/bundle.sh --output <scratch>` makes
`delivered=true` reachable. **Do not attempt al-2 before that ruling.**

### m23-al-3 — migrate the keyboard guards onto the home. **NOT in this arc; propose only.**
`handleArrangeNudgeKey`'s fifth guard (`DAWProApp.swift:1312`) and m23-ak's `shouldDropNotes` are
both hand-rolled proxies for "which surface is the user working in", invented because there was no
home. They could become `activeEditorSurface.surface == .pianoRoll && hasSelection`. m23-ak
explicitly declined to re-cut the m23-x predicate a third time; this design declines too. File it;
do not fold it in.

---

## 12. The two strongest alternatives, and why they lose

**A. "Roll open ⇒ the roll is active" (`pianoRollEditorFocused = openEditorClip != nil`).**
One line, deterministic, kills the bug, needs no new type, no new seam and no gate beyond Leg B/C.
The orchestrator's reading of `DAWProApp.swift:468-470` points here.
*Why it loses:* it takes ⌘+ away from the arrange for as long as **any** MIDI clip is selected —
and clicking a clip is how you select one, so in a MIDI-heavy project the arrange's keyboard zoom
is effectively gone. It contradicts m21-c's own normative sentence
(`PianoRollNoteSelectionBridge.swift:51-53`). And it builds nothing: the next surface-scoped
command (⌘A, ⌘C/⌘V, find, a future ⌘-arrow) arrives with no home and mints proxy #3.
*Kept cheap on purpose:* under this design it is a one-line change **inside `resolve`**, so if the
user overrules §2, the cost is one line and one test table.

**B. Fix the focus fight itself — remove `PianoRollView.swift:275` and let real clicks move focus,
then keep routing on `pianoRollEditorFocused`.**
Arguably the "real" fix: one `@FocusState` owner asserting at a time, and on macOS a click on a
`.focusable()` view moves focus natively.
*Why it loses HERE:* its correctness rests entirely on key-window arbitration, which this tree
cannot observe (m23-bw) — the gate would be green because no key events are delivered, not because
the design works. It also changes who receives DELETE, putting the roll's note-DELETE path (which
already "needs a human", `DAWProApp.swift:4130-4131`) at risk in the same cycle as a zoom fix. It
is the right *eventual* shape and it is **m23-al-2**, sequenced after m23-bw ① rather than
abandoned.

---

## 13. Failure modes

| # | Failure | Detection | Mitigation |
|---|---|---|---|
| F1 | A future edit adds a focus term to `resolve`, restoring the bug with extra steps | `EditorSurfaceOwnershipSiteTests` (`pianoRollEditorFocused` may not appear in the router) | site test + banner comment |
| F2 | A router path calls `engage`, self-confirming and latching forever | §3.6(3) site assertion | site test, **not** a comment |
| F3 | A new roll gesture forgets to engage → that gesture silently fails to claim ⌘+ | §4.4 gesture-count pin | pin reddens; author must decide |
| F4 | `engage` on every drag tick storms `@Observable` observers | change-guard in `engage` (§3.2); M6 pins it | measure a note drag if the UI feels heavy |
| F5 | Someone reads `engagementSeq` as "a report happened" and writes an unfailable leg | doc comment says TRANSITIONS; Leg F pins the exact `+3` | — |
| F6 | `act:"engage"` answers green for an unarmable state → false "fixture armed" | Leg J; M8 | throw, per `automationPoints` (`:3983-3993`) |
| F7 | An agent-facing `view.zoom` is added "for completeness" and reddens 171/174/74 | the pins | §7.1 says do not; state it in the PR |
| F8 | The gate passes because `zoomIn` was tested via `zoomArrangeIn` instead of the router | code review of `debug.viewZoom` | §7.1: the seam calls `zoomIn()`, never the per-surface entry points |
| F9 | Engagement persisted into `PanelLayoutModel`, restoring a latched lie | §3.5 | keep it off the layout store |
| F10 | The `workspaceIsArrange` term is "simplified away" because `openEditorClip` looks like it already means "on screen" | Leg **K**, mutant **M9**, and the 4 Mix rows of the truth table | §3.1's banner paragraph must survive into the source comment |
| F11 | The controller strip's separate commit funnel (R7) is dropped as "already covered by `commit()`" | site test asserts R7 exists | §4.2 records that `commit()` has exactly three callers and none of them is the strip |

**RT-safety:** none of this is within a mile of the render thread. `EditorSurfaceRouter` is a pure
value function on `@MainActor` app state; no allocation, lock or dispatch is added to any audio
path. DAWCore is untouched; DAWEngine is untouched.

**Full Xcode:** **not required.** No entitlements, no AUv3, no signing, no bundling. (m23-al-**2**
*does* touch the bundling question via m23-bw ① — `scripts/bundle.sh --output <scratch path>`,
never a `dist/` rebuild, which is the user's call.)

---

## 14. Standing constraints this work must respect

Port **17600 is the user's LIVE app** — staging is **17695** only, killed PIDFILE-exact, never
`pkill`/`pgrep`. `git checkout`/`stash`/`restore`/`clean` are **forbidden** in this tree (this is
why mutants are hand-reverted). **Commits only on the user's word.** `./scripts/test.sh`, never
bare `swift test`, and it **exits 0 on a failed run** — grep `^✘`. `--filter` is a substring match:
check the printed count. Additive-only wire; never rename a live command. `dist/DAWPro.app` is
stale and must not be rebuilt unilaterally.
