# Group selection + clipboard — design

**Date:** 2026-08-09
**Author:** `daw-architect`
**Status:** design settled, not implemented. This document is the spec implementing agents work from.
**Scope:** the user's request, verbatim — *"Add group selection using mouse area drag to enable copy/paste/drag to note editor as well as track view"*

---

## 0. The reading I took, stated so it can be corrected cheaply

I read the request as: **rubber-band group selection, group drag, and copy/paste should all work in the piano roll ("note editor") the same way they work in the arrange lanes ("track view").**

Two alternative readings exist and are **not** in scope here. If either is what was meant, say so now — correcting the reading costs one paragraph today and a rebuild later:

- dragging notes **between clips** (out of one roll, into another) — not designed here;
- dragging clips **from the arrange into the roll** (or vice versa) — not designed here.

---

## 1. What already ships (verified, not assumed)

|  | rubber band | group drag | copy / cut / paste |
|---|---|---|---|
| **arrange lanes** | **ships** — `Sources/DAWAppKit/ArrangeMarquee.swift` (m23-g3); gesture `Timeline/TimelineLanesView.swift:1533`; attached `.simultaneousGesture` at `:1496` | **ships** — `Sources/DAWAppKit/ArrangeGroupDrag.swift` (m23-g2) | **absent** |
| **piano roll** | **ABSENT** | **ships, but DEFORMS the group** — `PianoRollModel.beginMove()` `:306` / `moveSelection(…)` `:316` move the whole selection, but clamp pitch, floor the beat **and snap** *per note* (`:320-321`), which is the m23-g2 defect on both axes. Invisible for one note; reachable at scale the moment a band exists — **see GS-2b** | **absent** |

Copy/paste exists nowhere: `Sources/DAWApp/EditCommands.swift` is Undo / Redo / Delete only; the only `NSPasteboard` touch points in the app are `Copilot/CopilotPasteboard.swift` and `Settings/SettingsView.swift:485`. There is no ⌘C / ⌘X / ⌘V anywhere.

So the missing work is exactly **(1) a piano-roll rubber band** and **(2) copy/cut/paste on both surfaces.**

### 1.1 One adjacent gap, noted not scoped

There is **no Select All (⌘A)** anywhere in the app — `grep` over `Sources/DAWApp` finds `pianoRollNoteSelection.stage(selectAll:)` (`DAWProApp.swift:4671`, the debug seam) and nothing user-facing. A clipboard makes that omission much more visible ("copy 3 clips" implies "select all clips"). It is not in this plan; it is a natural GS-10.

---

## 2. Constraints this plan is bound by (restated, non-negotiable)

- **Control port 17600 is the user's LIVE app. Never touch it.** Staging is **17695**.
- No commits without the user's word. No `git checkout` / `stash` / `restore` / `clean` in this tree.
- `./scripts/test.sh`, never bare `swift test`. **It exits 0 even on failure** — a run is evidence only if you `grep '✘'` (anywhere in the line, not line-start) and reconcile the test-count delta against declared `@Test`s.
- Use `rtk proxy <cmd>` whenever command output is evidence — the shell hook strips `warning:` lines and compresses `swift build` output to ~20 bytes.
- **Additive-only on the wire.** Never rename a live command.
- `DAWCore` stays UI-free and engine-free. `DAWAppKit` stays headless (no SwiftUI, no AppKit).
- **A concurrent agent is editing** `Sources/DAWCore/StandardMIDIFileMapper.swift`, `Sources/DAWCore/ProjectStore+MIDIFile.swift` and possibly `Sources/DAWApp/DAWProApp.swift:6491`. Nothing in this plan depends on their current contents; GS-9 (SMF pasteboard mirror) is deliberately deferred behind that work.

---

# PART 1 — the piano-roll rubber band

## D1. Is the roll's vertical ladder uniform? **YES. Verified.**

The arrange marquee takes *resolved lane bands* as input specifically because its ladder is non-uniform (`ArrangeMarquee.swift:11-22`; `TimelineLanesView.laneTop(index)` accumulates `rowHeight + extraHeight(track) + laneSpacing`).

The roll's ladder is a pure affine map, with no folding, no expansion, and no per-row variation:

- `PianoRollModel.y(forPitch:)` — `PianoRollModel.swift:176-178` — `CGFloat(127 - pitch) * rowHeight`
- `PianoRollModel.pitch(forY:)` — `:181-184` — its exact inverse, clamped to `0...127`
- `PianoRollModel.contentHeight` — `:187` — always `128 * rowHeight`. Every pitch row is drawn, always.

`PianoRollGrid.drawBlackKeyRows` (`PianoRollView.swift:1550`) and `drawNotes` (`:1638`) both reproduce `(127 - pitch) * rowHeight` inline, so the drawn ladder is the model's ladder by construction.

**The velocity lane and the controller strip do not perturb it.** They are *siblings* of `editor` in the outer `VStack` (`PianoRollView.body:268-284`), each with its own coordinate space and its own horizontal `ScrollView` (`velocitySection:1402-1442`, `controllerSection:1465-1477`). They sit below the pitch stack, not inside it.

**Decision: do NOT mirror `ArrangeMarqueeLane`.** `PianoRollMarquee` takes the notes plus `rowHeight`/`pixelsPerBeat` and computes rects through the model's own mapping. Building a `[PianoRollMarqueeRow]` ladder here would be 128 rows of ceremony encoding a fact the model states in one line — and, worse, it would be a *second producer* of a mapping that currently has exactly one.

**Alternative rejected #1 — mirror the arrange shape "for consistency."** Loses because `ArrangeMarquee`'s shape is not a style, it is a *remedy for a specific hazard* that this surface does not have. `ArrangeMarquee.swift:16-22` says so explicitly, and its test suite carries a permanent validity leg that runs the rejected uniform mapping and asserts the two id sets differ. There is no such discriminator to write here: the uniform mapping is the correct one.

**Alternative rejected #2 — re-derive the pitch row inside the geometry type with `floor(y / rowHeight)`.** Loses on the *rect* question below, not on the ladder: a band must decide membership against the same rect a click uses, and that rect is not derivable from a row index alone.

## D2. ⚠️ The real trap: **which rect**

There are **three** candidate rectangles per note, and picking the wrong one ships a band that disagrees with a click:

1. `PianoRollModel.rect(for:)` — `PianoRollModel.swift:233-240` — applies **`max(3, lengthBeats * pixelsPerBeat)`**, a minimum *hit* width so a very short note stays clickable.
2. `PianoRollGrid.drawNotes`'s pill — `PianoRollView.swift:1636-1641` — the same rect then `.insetBy(dx: 0.5, dy: 1.5)`. This is the **drawn** rect and is strictly smaller.
3. A freshly re-derived `startBeat * ppb … endBeat * ppb` rect — what a careless implementation writes.

`PianoRollModel.hitTest(_:)` (`:274-286`) uses **(1)**.

**Decision: the band uses `PianoRollModel.rect(for:)`, and nothing else.** `PianoRollMarquee.hits` must be handed note rects produced by the model, or must be handed the model's `rowHeight`/`pixelsPerBeat` and call the same arithmetic — never its own beat math.

Why it matters concretely: at the default 32 px/beat, a 1/64 note (0.0625 beats) is 2 px wide, floored to 3 px by `rect(for:)`. Under (3) the band's rect is 2 px and the click's is 3 px — so there is a 1 px column where clicking selects the note and sweeping does not. Under (2) the band is 1 px inset and the discrepancy is worse and applies to *every* note. This is precisely the "two computations that agree by luck" failure `ArrangeGroupDrag.swift:21-29` and the m23-f finding legislate against.

**Carried over from `ArrangeMarquee`:**
- **TOUCH, not containment** (`ArrangeMarquee.swift:24-26`) — a note is selected when the band *overlaps* it.
- **STRICT overlap, so a degenerate band selects nothing** (`:28-33`) — `guard band.width > 0, band.height > 0 else { return [] }`. A press that never swept area cannot silently replace the user's selection with a lucky hit.
- **Normalized band** — `PianoRollMarquee.band(from:to:)` is a verbatim copy of `ArrangeMarquee.band(from:to:)` (`:92-95`). Two homes for the same four lines is acceptable here for the reason `ArrangeMarquee.dragSlop`'s own doc gives about `loopClickSlop`: these are per-surface constants with a cross-reference, not one shared quantity. **Cross-reference them in both directions in the doc comments.**

**NOT carried over:** `ArrangeMarquee.hits`'s `where clip.lengthBeats > 0` filter (`:119`). It has no referent here — `MIDINote.minLengthBeats` is `0.001` (`Model.swift:152`) and the `max(3, …)` floor means no note has zero extent. Copying it blind would ship a guard for a state that cannot exist, which is how dead rules accumulate.

## D3. Which surface arms the band, and what it must not steal

### What an empty-grid drag does **today** (read, not guessed)

`gridDrag` is `DragGesture(minimumDistance: 0)` attached with **`.gesture`** (not `.simultaneousGesture`) at `PianoRollView.swift:1043`:

- `beginGesture(at:)` `:1319-1338` — no hit, or shift held → `activeDrag = .click(hit?.id)`
- `applyGesture(_:)` `:1340-1359` — the `.click` branch is `break`. **Nothing happens during the drag.**
- `endGesture(_:)` `:1361-1384` — `.click(nil)` and no shift → **`model.clearSelection()`** (`:1369-1371`)

So today, dragging on empty grid does *nothing visible* until release, when it clears the selection.

Also attached to the same view: `.simultaneousGesture(gridPinch)` `:1046`; `.simultaneousGesture(SpatialTapGesture(count: 2))` `:1047-1058` (double-tap creates a note); `.contentShape(Rectangle())` `:1079`; `.contextMenu { noteContextMenu }` `:1080`. The `scrubStrip` overlay `:1112` owns its own `DragGesture` in a band `18 pt` tall pinned to the top of the visible grid.

### ⚠️ The arrange's `.simultaneousGesture` remedy does **NOT** transfer

`TimelineLanesView.swift:1484-1496` records exactly why arrange used `.simultaneousGesture`: `pointerHoverSurface` carries **two `onTapGesture`s** whose declaration order was chosen deliberately, and a competing `.gesture` would re-enter arbitration the file had already avoided. A `minimumDistance` excludes taps cleanly, so a simultaneous drag was free.

**The roll's competitor is not a tap. It is a `DragGesture(minimumDistance: 0)` that already claims every press on the grid and unconditionally clears the selection on release.** A `.simultaneousGesture(marqueeGesture)` would run *concurrently* with `gridDrag`, and at release both `onEnded` bodies fire — one applying the band's selection, the other calling `clearSelection()`. **The order between them is SwiftUI's and is not observable from this tree** (the m23-bw law). No `minimumDistance` can exclude a gesture that already began at 0.

You could add a flag to `endGesture` ("don't clear while a marquee is live"), but that puts the arbitration back — split across two gesture bodies, coupled by a mutable flag, with the same unobservable ordering underneath.

### ✅ DECISION: **promotion inside the existing `gridDrag`**

Add one case to `ActiveDrag` (`PianoRollView.swift:255-265`):

```
case marquee(origin: CGPoint, base: Set<UUID>, additive: Bool)
```

- **Press** is unchanged. Empty grid (or any shift/⌘ press on empty grid) still enters `.click(nil)`.
- **In `applyGesture`**, when `activeDrag` is `.click(nil)` and `hypot(translation.width, translation.height) >= PianoRollMarquee.dragSlop`, **promote** to `.marquee(origin: value.startLocation, base: model.selection, additive: <chord>)`, then apply the band on that same tick.
- **Subsequent ticks** in `.marquee` re-decide the whole selection from the frozen `base` (grow adds, shrink gives back — the `updateMarquee` rule, `TimelineLanesView.swift:1562-1574`).
- **`endGesture`** in `.marquee` applies the final band, clears the band rect, and emits one final report.

Everything this buys, stated because each is a hazard that does not need handling:

- **Click-to-deselect survives byte-identically.** No travel → never promotes → the `.click(nil)` branch runs exactly as today.
- **NO tap-suppression window is needed.** `ArrangeMarquee`'s `marqueeEndedAt` / `consumeMarqueeClickSuppression` (`TimelineLanesView.swift:1600-1607`) exists because a marquee's mouse-up can synthesize a *separate* tap that would seek. Here the click *is* `gridDrag`'s own `.click` branch, which promotion has already left. **Write this down in the code comment** — otherwise a future reader "restoring consistency with arrange" will add a flag that can only cause bugs.
- **Promotion is gated on `.click(nil)` only.** A shift-press on a *note* is `.click(hit.id)` and can never become a band. A plain press on a note is `.move` and can never become a band.
- **`SpatialTapGesture(count: 2)` is untouched** — a double-tap has no travel, so it never crosses the slop.
- **Adding an enum case forces all three `switch`es** (`gridDrag.onChanged`'s cursor switch `:1305-1309`, `applyGesture` `:1341`, `endGesture` `:1362`) to be updated. Take the compiler pressure; do not add a `default:` to any of them.

**Alternative rejected #1 — `.simultaneousGesture(marqueeGesture)`, the arrange shape.** Loses as argued above: the competitor is a zero-distance drag, not a tap, and the release ordering is unobservable. This is the single most likely wrong turn in this item.

**Alternative rejected #2 — a separate marquee surface layered under the grid Canvas (the `pointerHoverSurface` analogue).** Loses because `PianoRollGrid` carries `.contentShape(Rectangle())` at `:1079`, which was added at m23-cf **after live measurement** (`:1065-1078`: a `Canvas` contributes no AppKit hit region, so the context menu did not appear without it). That shape takes the whole hit area; an underlay would never see a press. Shrinking or removing it to make room would break the m23-cf context menu that was measured into existence. **Do not touch `.contentShape(Rectangle())`.**

### Slop constants — say which is which

The roll **already** has a travel threshold: `applyGesture` uses `abs(translation.width) > 3 || abs(translation.height) > 3` to set `didMove` (`:1346`, `:1355`), which decides whether a move/resize *commits*.

These are two different decisions and must not be merged: `didMove` answers "was this an edit or a click?", promotion answers "was this a click or a band?". Changing `didMove`'s 3 would alter shipped note-drag commit behaviour and is out of scope.

**Decision:** add both to the new geometry type as named constants, changing neither value:
- `PianoRollMarquee.dragSlop: CGFloat = 4` — the promotion threshold (radial), matching `ArrangeMarquee.dragSlop`'s value and reasoning.
- `PianoRollMarquee.moveCommitSlop: CGFloat = 3` — the existing per-axis `didMove` threshold, hoisted verbatim from `PianoRollView` so the surface has one home for pointer-travel thresholds and the difference between them is legible.

### The m18-i cancel path

`reseedFromExternalMutation` (`:468-482`) parks an in-flight gesture in `.cancelled` when an external mutation lands. A live marquee must be cancelled the same way, **and the band rect must be cleared** — otherwise a ghost band stays on screen with no gesture behind it, and the next release would apply a selection decided against dead content. Add the band-state reset to the existing `if activeDrag != .none { activeDrag = .cancelled; didMove = false }` block.

## D4. Does the band include the velocity lane / controller strip?

**Decision: velocity lane — OUT. Controller strip — OUT.** Both for v1 and, for the controller strip, structurally.

**Velocity lane (`Sources/DAWApp/PianoRoll/VelocityLane.swift`).** Sweeping a band over VEL stems to select the corresponding notes is a real DAW idiom, and it is tempting. It loses on three counts:

1. **y means velocity there, not pitch.** A band in that lane needs an *x-only* membership rule — a second geometry rule on the same surface. `VelocityLane.note(nearX:)` (`:20-25`) is already a *third* targeting rule (nearest onset within 10 pt), distinct from both `hitTest` and any band. Adding a fourth would give one surface four ways to decide "which note did the pointer mean".
2. **Separate coordinate space and an independent scroller** (`velocitySection:1414-1434`), Pro-density only. A band spanning grid → velocity lane would have to cross two scroll offsets that follow-the-playhead moves independently.
3. **The benefit is already delivered.** `VelocityLane(model: model, …)` (`:1416`) shares the *same* `PianoRollModel`, and its Canvas reads `selectedIDs = model.selection` (`:39`, used at `:67`). **A band drawn in the note grid already lights up the corresponding VEL stems.** Only the *gesture* would be new, not the capability.

If a user later asks for it, the honest version is an x-only band in the velocity lane that unions into `model.selection` — one new rule in `PianoRollMarquee`, one gesture. Cheap later; not worth the fourth targeting rule now.

**Controller strip (`ControllerStripModel`).** Definitively out. It edits `MIDIControllerPoint`s, a **different selection domain** with a different commit path (`onCommitControllerLane`, m23-al R7, `:1481-1498`). A band over breakpoints is the automation idiom, and its home is the `AutomationPointSelectionBridge` lineage, not this one.

## D5. Chord handling — one mapping, and it is a stated behaviour change

**The one mapping is `ArrangeClickIntent.intent(for:)`** — `Sources/DAWAppKit/ArrangeSelection.swift:89-91`:
`(modifiers.contains(.shift) || modifiers.contains(.command)) ? .toggle : .replace`.
Its doc (`:73-91`) records that shift and ⌘ both mean toggle *deliberately*, and that m23-g3's rubber band reuses it rather than growing a second chord table.

**The AppKit bridge is `ArrangeClickModifiers.current`** — `Sources/DAWApp/Timeline/ArrangeClickModifiersBridge.swift:34`. ✅ **Verified reachable:** the extension is `internal` (no `public`) and lives in `Sources/DAWApp/`, the same module as `PianoRollView.swift`. **No promotion or file move is needed.**

**The roll does not use this mapping today.** `beginGesture:1326` and `endGesture:1366` each read `NSEvent.modifierFlags.contains(.shift)` raw. Consequently **⌘ currently does nothing in the roll**: a ⌘-press on a note takes the `!shift` branch and starts a *move*; a ⌘-click on empty grid clears the selection.

**Decision: route BOTH the band and the click through `ArrangeClickIntent`, in the same item.** The band's correctness argument is "the chord means the same thing on a band as on a click" — that claim is *false* unless the click side moves too, and shipping a band-only mapping would create the second chord table the arrange doc exists to prevent.

This is a **behaviour change to shipped click handling**, and it must be named in the item, not tidied in silently. Exactly three behaviours change, all in the direction of arrange consistency:

| gesture | today | after |
|---|---|---|
| ⌘-press on a note, then drag | starts a **move** | `.click(id)` → **toggles** that note on release; no move |
| ⌘-click on a note | selects only that note | **toggles** it |
| ⌘-click on empty grid | clears the selection | **leaves the selection alone** (matches shift) |

Shift behaviour is unchanged in every case.

**Each row above gets its own gate leg.** A change to shipped pointer behaviour with no assertion naming it is how a regression ships as a feature.

**Do NOT rename `ArrangeClickModifiers` / `ArrangeClickIntent`** to drop the `Arrange` prefix. Amend their doc comments to name the second consumer (the roll) instead; a rename touches ~10 sites for cosmetics.

**Narrower fallback, if the click-side change is refused:** route only the band through the mapping and leave the click reading `.shift` raw. Cost: ⌘-band is additive while ⌘-click is not — a real inconsistency, on the exact surface m23-e/m23-d/m23-cf just repaired. Recommended against; recorded so the choice is visible.

## D6. The staging seam — the SAME shape as `debug.arrangeMarquee`

Not a second pattern. The precedent is `debug.arrangeMarquee` (`Sources/DAWApp/DAWProApp.swift:5186-5274`), its stage type (`Sources/DAWApp/Timeline/ArrangeMarqueeStaging.swift`), and its bounded await (`awaitMarqueeApplied`, `:5179-5184`).

**Verb: `debug.pianoRollMarquee`. App tier, debug only — OFF `allCommands`, OFF MCP.** Justified by `Commands.swift:170-172` ("`debug.*` is deliberately EXCLUDED from `allCommands` / MCP parity — it's a developer/verification surface") and by `debug.arrangeMarquee`'s own rationale (`DAWProApp.swift:5187-5190`): a marquee's only domain effect is a **selection**, which is UI state. **Zero wire growth.**

**Shape:**

- `{}` — **read-only** (the m11-a bare-read law). A bare read must never stage a degenerate band; that makes gates vacuously green.
- `{act:"begin", x, y, shift?, command?}` — press. Freezes the origin and the pre-drag selection, applies the (degenerate) band.
- `{act:"changed", x, y}` — drag the free corner; re-decides the whole selection from the frozen base.
- `{act:"end", x, y}` — release: apply the final band, then clear it.

**Phased, not one-shot** — for `ArrangeMarqueeStaging.swift:15-20`'s reason verbatim: a one-shot "select this rect" seam structurally cannot observe "the band is VISIBLE during the drag", because it begins and ends inside one call with nothing standing to look at.

**Chord passed EXPLICITLY** — a synthesized gesture carries no real `NSEvent.modifierFlags` (`ArrangeClickModifiersBridge.swift:25-33`). The one line the seam therefore cannot exercise is the live `.current` read; that is accepted and recorded, exactly as arrange records it.

**Echo — GROUND TRUTH only.** The band reported must be the rect the roll is *drawing*, reported up from the view, never the seam's input.

```
{
  "rowHeight":       <CGFloat>,      // ALWAYS echoed — see below
  "ppb":             <CGFloat>,      // ALWAYS echoed — see below
  "clipLengthBeats": <Double>,
  "noteCount":       <Int>,
  "bandRect":        {x,y,width,height} | null,
  "hitIds":          [uuid...],      // what the last band TOUCHED
  "selectedIds":     [uuid...],      // the model's own selection (base ∪ hits under a chord)
  "count":           <Int>,
  "editorClipId":    uuid | null,
  "reportSeq":       <Int>
}
```

**⚠️ `rowHeight` and `ppb` are echoed even though the ladder is uniform, and this is load-bearing.** `PianoRollModel.rowHeight` is a `var` (`:97`) and `pixelsPerBeat` is driven by the persisted, user-zoomable `PanelLayoutStore.pianoRollPPB` (`PianoRollView.swift:371-374`). **A gate fixture MUST derive its coordinates from this echo and MUST NOT hardcode `14` or `32`.** A hardcoded fixture passes at defaults and silently tests nothing at any other zoom — the same class of trap `ArrangeMarqueeStaging.swift:44-52` names for `laneTops`.

**Bounded await.** Add `awaitPianoRollMarqueeApplied(after:)`, a verbatim twin of `awaitMarqueeApplied` (`:5179-5184`): spin `RunLoop.main` until `reportSeq` moves, hard-stop at a 0.30 s deadline so a Mix-workspace call (no roll mounted) returns instead of hanging. Without it the echo answers with the **previous** step's band — which does not merely fail a gate, it poisons every diagnosis made through the seam.

### ⚠️ The bridge trap that is already written down

The seam needs `selectedIds`/`count` out of a `@State private PianoRollModel`. The only channel is `PianoRollNoteSelectionBridge` (`Sources/DAWAppKit/PianoRollNoteSelectionBridge.swift:56-61` declares exactly that charter). **Extend it; do not add a second bridge.**

But `DeleteMenuPolicy.swift:136-143` **already anticipates this feature** and warns against the obvious implementation:

> `PianoRollNoteSelectionBridge` publishes a BOOL, not a count, because its report fires on the empty ↔ non-empty transition only — keying it on `count` would rewrite a keyboard-gating observable to fire on every pointer update of a note marquee.

**So: `hasSelection` stays a transition-reported `Bool`.** Carry the ids on a **separate, `@ObservationIgnored`** property written by the same report path the band already runs, read only at seam time. A band drag must not invalidate the observation graph on every pointer tick — and `hasSelection` gates a keyboard path (`AppModel.pianoRollWouldConsumeKey`, `DAWProApp.swift:1045-1047`), so making it noisy would be a correctness regression, not a performance one.

## D7. Failure modes — Part 1

| # | failure | why it happens | the assertion that catches it |
|---|---|---|---|
| **F1** | band and `clearSelection()` race at release; selection is non-deterministic | `.simultaneousGesture` instead of promotion | a gate leg that drags a band over 2 notes and asserts `count == 2` after release, run ≥3× (a race passes once) |
| **F2** | band and click disagree on a very short note | band uses the drawn (`insetBy`) or a re-derived rect | headless: a 1/64 note at low ppb is in `hits(band:)` for exactly the x-range `hitTest` accepts |
| **F3** | gate is green at defaults, meaningless at any zoom | fixture hardcodes `rowHeight = 14` / `ppb = 32` | run the same gate twice — once at default ppb, once after `layout.setPianoRollPPB(…)` — deriving both fixtures from the echo |
| **F4** | note-drag performance collapses; keyboard routing goes noisy | `hasSelection` made count-keyed to feed the seam | `PianoRollNoteSelectionBridge` test: a selection going 2 → 3 notes does **not** bump the report |
| **F5** | ghost band on screen after an external mutation; selection decided against dead content | m18-i reseed does not clear band state | stage `begin` + `changed`, mutate the clip over the wire, assert `bandRect == null` and the selection did not change |
| **F6** | double-click-to-add swallowed by a jittery press | promotion threshold too low / mis-gated | a `begin`+`end` pair inside `dragSlop` still runs the `.click` branch; and a live double-tap add still creates a note |
| **F7** | ⌘-drag-on-a-note silently stops moving notes | chord unification lands with no leg naming it | three legs, one per row of the D5 table |
| **F8** | context menu stops appearing | `.contentShape(Rectangle())` removed while restructuring | `EditorSurfaceOwnershipSiteTests`-style site pin: `.contentShape(Rectangle())` still present at the grid |
| **F9** | the roll's engagement (`onEngage`, m23-al R1) stops firing | promotion path bypasses `beginGesture` | it cannot — promotion happens in `applyGesture`, downstream of `beginGesture`'s `onEngage()`. Pin it anyway: after a staged band, `activeEditorSurface == .pianoRoll` |

## D8. Implementation plan — Part 1

### GS-1 — `PianoRollMarquee` geometry (DAWAppKit, headless)

**New file:** `Sources/DAWAppKit/PianoRollMarquee.swift`

```
public enum PianoRollMarquee {
    public static let dragSlop: CGFloat = 4          // click → band promotion (radial)
    public static let moveCommitSlop: CGFloat = 3    // hoisted verbatim from PianoRollView's didMove
    public static func band(from: CGPoint, to: CGPoint) -> CGRect
    public static func hits(band: CGRect, rects: [(id: UUID, rect: CGRect)]) -> Set<UUID>
}
```

### ⚠️ REQUIRED, NOT OPTIONAL: extract the note rect to ONE producer first

`hits` must **not** take `notes` + `rowHeight` + `pixelsPerBeat` and build rects itself — that signature *forces* it to re-spell `max(3, lengthBeats * ppb)` and `(127 - pitch) * rowHeight` inline, which is precisely the second spelling **F2** exists to catch. A rule cannot be enforced by a signature that makes breaking it the path of least resistance.

**Do this first, in GS-1:**

1. Add `PianoRollModel.noteRect(_ note: MIDINote, rowHeight: CGFloat, pixelsPerBeat: CGFloat) -> CGRect` as a **`nonisolated static`**. `nonisolated` is required, not stylistic: the `@Sendable` Canvas renderers already need this arithmetic (`PianoRollView.swift:1636-1641`), and `PianoRollModel` already uses `nonisolated static` for exactly this reason on `pitchCount` (`:92`), `drawnWidth` (`:206`) and `playableEndBeat` (`:224`).
2. `PianoRollModel.rect(for:)` (`:233-240`) becomes a one-line forwarder.
3. `PianoRollMarquee.hits` takes **already-built rects** (or calls the same static), and tests strict overlap on both axes. It contains **no beat math and no pitch math at all** — there is nothing in it that *could* drift.

**Strongly recommended in the same pass:** fold `PianoRollGrid.drawNotes`' inline rect (`PianoRollView.swift:1636-1641`, candidate rect #2) into the same static, keeping its `.insetBy(dx: 0.5, dy: 1.5)` at the call site. Leaving it hand-rolled keeps a third copy of the arithmetic alive, and it is the copy a future zoom change is most likely to touch.

**Header comment must carry:** why the ladder is uniform (with the `ArrangeMarquee.swift:11-22` contrast), why `rect(for:)` and not the drawn pill, the touch-not-containment rule, the strict-degenerate rule, and the cross-reference to `ArrangeMarquee.dragSlop`.

**Tests:** `Tests/DAWAppKitTests/PianoRollMarqueeTests.swift`
- normalization: all four drag directions produce the same rect
- degenerate band (zero width, zero height, both) → empty set
- touch not containment: a note wider than the band is selected
- edge-exact: `band.maxY == note.rect.minY` selects nothing (strict)
- **the F2 leg**: a 1/64 note at ppb 8 is hit exactly across `[x, x+3)` — the same range `PianoRollModel.hitTest` accepts. Assert both, in one test, against the same fixture.
- **a discriminator leg**: the *drawn* rect (`insetBy(0.5, 1.5)`) produces a **different** hit set for a short note than `rect(for:)` does. This is the `ArrangeMarqueeTests` validity-leg idiom — it proves the test can tell the two apart, not merely that the right one passes.

**Route:** `swift-app-engineer`. **Depends on:** nothing. **Weight:** S.

### GS-2 — promotion + chord unification (DAWApp)

**Files:** `Sources/DAWApp/PianoRoll/PianoRollView.swift` only.

1. `ActiveDrag` gains `case marquee(origin: CGPoint, base: Set<UUID>, additive: Bool)`.
2. `beginGesture` — replace `let shift = NSEvent.modifierFlags.contains(.shift)` with `let intent = ArrangeClickIntent.intent(for: .current)`; the two `!shift` guards become `intent == .replace`.
3. `applyGesture` — in the `.click(nil)` case, promote past `PianoRollMarquee.dragSlop` (freezing `base = model.selection` and `additive = intent == .toggle`), then fall through to the marquee apply. Add the `.marquee` case: recompute band, recompute hits, set `model.selection` = `additive ? base ∪ hits : hits`, publish the report.
4. `endGesture` — `.marquee`: final apply, clear band state, one final report. `.click`: `shift` → `intent`.
5. `gridDrag.onChanged`'s cursor switch — `.marquee` sets no drag cursor (the arrow is correct for a sweep; `DragCursor` is for grab/resize).
6. `reseedFromExternalMutation` — clear band state alongside `.cancelled`.
7. **New `@State private var marqueeBand: CGRect?`** + a hit-test-inert band overlay on the grid, styled as `TimelineLanesView.marqueeBandView` (`:1634-1647`): `DAWTheme.playback` at 0.12 fill, 0.85 stroke, `glow(radius: 6, intensity: 0.35)`. Same visual vocabulary, per `docs/DESIGN-LANGUAGE.md` — cyan is active state, glow is earned, nothing static glows, and this exists only while a gesture is live.

**Freezing `base` at promotion rather than at press is provably equivalent**, because `applyGesture`'s `.click` branch is `break` — nothing can mutate `model.selection` between press and promotion. State this in the comment and pin it with a test.

**⚠️ Do not touch:** `.contentShape(Rectangle())` `:1079`, `.contextMenu` `:1080`, `SpatialTapGesture(count: 2)` `:1047`, `gridPinch` `:1046`, `scrubStrip` `:1112`, or `didMove`'s value.

**Route:** `swift-app-engineer`. **Depends on:** GS-1. **Weight:** M.

### GS-2b — ⚠️ group-drag rigidity: the m23-g2 defect, on BOTH axes

**The brief named drag explicitly, and §1's table's "group drag ships" is true but incomplete.** `PianoRollModel.moveSelection` (`:316-327`) already moves the whole selection — but it **deforms it**, per element, on both axes. Verified by reading `:320-321`:

```swift
let newPitch  = (base.pitch + deltaPitch).clamped(to: MIDINote.pitchRange)
let newStart  = snap(beat: max(0, base.startBeat + deltaBeats), resolution: resolution)
```

Three per-element operations, each of which is the **m23-g2 defect** (`ArrangeGroupDrag.swift:11-19`: *snapping is a property of the GESTURE, not of each clip*):

1. **Per-note pitch clamp.** Drag a selection up until its top note reaches 127: that note stops, the rest keep rising. **Intervals collapse.** A chord becomes a cluster.
2. **Per-note beat floor.** Drag left past beat 0: notes pile up at 0 and the rhythm is destroyed.
3. **Per-note snap.** Two notes at beats 0 and 0.5 under `.beat` snap, dragged +0.1 → `snap(0.1) = 0` and `snap(0.6) = 1`. The 0.5-beat gap becomes 1.0. **This is m23-g2's welding, verbatim, on the beat axis** — and nothing warns the user.

**Why it has been invisible, and why the band makes it urgent:** for a *single* note the anchor **is** the note, so all three per-element operations equal the anchor rule exactly. Before GS-2, multi-note selections were only reachable by shift-clicking a handful of notes; a rubber band makes 40-note selections a one-gesture operation, which is precisely when these deform.

**Fix — `ArrangeGroupDrag`'s rule, applied to the roll:**

- `beginMove(anchorID:)` — additive parameter; `beginGesture` already holds `hit.id` (`PianoRollView.swift:1327`, `beginMove()` called `:1333`), so the anchor costs nothing to thread.
- **Clamp `deltaPitch` ONCE** against the selection's min/max pitch, then apply rigidly.
- **Floor `deltaBeats` ONCE** against the selection's minimum start, then apply rigidly.
- **Snap the ANCHOR's absolute start ONCE**; every other note translates by the resulting delta.

⭐ **SAFETY PROPERTY, and it is what makes this cheap:** for a single-note selection the anchor is that note, so all three rules reduce to the current expressions and the behaviour is **byte-identical**. Only multi-note drags change — and they change from deforming to rigid.

**Where the rule lives:** `PianoRollModel` (headless, already `Tests/`-reachable), *not* the view. Consider reusing `ArrangeGroupDrag.plan(...)` for the beat axis — it already owns "snap the anchor once, translate rigidly" and returns a `flooredAtZero` flag — but only if it can be used **without** re-deriving anything; a partial reuse that recomputes the floor would be the duplicate computation its own doc (`:21-29`) forbids.

**Tests:** `Tests/DAWAppKitTests/PianoRollModelTests.swift` — (i) a 3-note chord dragged into the 127 ceiling keeps its intervals and stops as a unit; (ii) a group dragged left past 0 keeps its gaps and stops as a unit; (iii) two notes at sub-grid phases 0 / 0.5 keep their 0.5-beat gap through a snapped drag — **and a validity leg asserting the OLD per-note expression gives a DIFFERENT answer**, the `ArrangeMarqueeTests` discriminator idiom; (iv) single-note drags are unchanged across the whole snap ladder.

**Route:** `swift-app-engineer`. **Depends on:** GS-2 (the band is what makes it reachable; the fix itself is independent and could land first). **Weight:** S–M.

### GS-3 — the staging seam + its gate

**Files:**
- `Sources/DAWApp/PianoRoll/PianoRollMarqueeStaging.swift` (new — the `ArrangeMarqueeStaging.swift` twin: a `PianoRollMarqueeStage` struct with `action` / `x` / `y` / `additive` / `nonce`)
- `Sources/DAWAppKit/PianoRollNoteSelectionBridge.swift` — extend: stage nonce in, band + hits + ids + `reportSeq` out. **Keep `hasSelection` a transition-reported `Bool`; ids go on a separate `@ObservationIgnored` path.**
- `Sources/DAWApp/PianoRoll/PianoRollView.swift` — `.onChange(of: bridge.marqueeStageNonce)` → `applyMarqueeStage`, running the **same** promotion/apply/end handlers the live gesture runs.
- `Sources/DAWApp/DAWProApp.swift` — `case "debug.pianoRollMarquee"` in the app command handler, `pianoRollMarqueeDebug(_:)`, `awaitPianoRollMarqueeApplied(after:)`.

**Gate:** `scripts/gates/<id>-pianoroll-marquee.mjs`, on **staging port 17695**, never 17600.

Legs, at minimum:
1. **positive** — sweep a band over 2 of 4 notes → `selectedIds` is exactly those 2
2. **visibility** — `bandRect` is non-null mid-drag, null after `end`. *(A "gone after" leg alone passes vacuously against an implementation that never draws a band.)*
3. **shrink gives back** — grow to 3 notes, shrink to 1, assert 1
4. **additive** — `{shift:true}` band unions onto the base rather than replacing it
5. **degenerate** — `begin`+`end` at one point: **no band is ever drawn** (`bandRect` stays null throughout) **and the selection is CLEARED**. ⭐ That is not a bug and it is not the arrange's answer — it is D3's shipped rule: a sub-slop press never promotes, so `activeDrag` stays `.click(nil)` and `endGesture`'s `.click(nil)` branch runs, which under `.replace` clears exactly as it does today. Asserting "selects nothing **and** leaves the selection alone" would assert the opposite of what ships.
6. **zoom-invariance** — re-run leg 1 after changing `pianoRollPPB`, deriving the fixture from the echoed `ppb`
7. **row-height invariance** — same, deriving from echoed `rowHeight`
8. **not the scrub strip** — a band begun below `scrubStripHeight` does not seek the transport
9. **double-tap still creates** — the m23-e-style regression leg
10. **the D5 chord table** — three legs, one per changed behaviour

⚠️ **WHAT THIS SEAM STRUCTURALLY CANNOT TEST, stated so nobody writes a leg that passes vacuously:** a staged `begin` carries explicit coordinates, so a staged `begin`+`end` at one point **bypasses the promotion threshold entirely** and can never exercise it. **Promotion is reachable only through `changed`** — the seam's `begin` freezes the origin, and the first `changed` past `dragSlop` is what promotes. A leg claiming to test the slop must therefore be a `begin` → `changed` *within* slop (assert `bandRect == null`) → `changed` *past* slop (assert non-null). Anything else tests the seam, not the gesture.

**Route:** `swift-app-engineer` for the seam; `qa-test-engineer` for the gate. **Depends on:** GS-2. **Weight:** M.

---

# PART 2 — copy / cut / paste

## D9. Clipboard model and its home

**Decision: an in-app, typed, `@MainActor @Observable` clipboard living in `DAWAppKit`, held by `AppModel`. No `NSPasteboard` in v1. NO `DAWCore` CHANGE IS REQUIRED FOR THE CLIPBOARD AT ALL.**

**Where it lives:**

```
// Sources/DAWAppKit/EditClipboard.swift        (new)
public struct ClipboardClip: Equatable, Sendable {
    public var clip: Clip                 // DAWCore value type — a value copy IS the snapshot
    public var sourceTrackID: UUID
    public var sourceTrackIndex: Int
}
public struct ClipboardNotes: Equatable, Sendable {
    public var notes: [MIDINote]
    public var sourceClipID: UUID
}
public enum ClipboardPayload: Equatable, Sendable {
    case clips([ClipboardClip])
    case notes(ClipboardNotes)
}
public enum ClipboardKind: String, Sendable, CaseIterable { case clips, notes }

@MainActor @Observable public final class EditClipboard {
    public private(set) var payload: ClipboardPayload?
    public private(set) var seq = 0            // bumped per put — gate observability
    public var kind: ClipboardKind? { … }      // DERIVED, never stored
    public func put(_ payload: ClipboardPayload)
    public func clear()
}
```

This is the `PianoRollNoteSelectionBridge` / `EditorSurfaceEngagement` shape verbatim: a small `@Observable` class in DAWAppKit that `AppModel` holds. `DAWAppKit` already imports `DAWCore` (`PianoRollModel.swift:4`), so `Clip` and `MIDINote` cross cleanly — both are `Codable, Sendable, Equatable` (`Model.swift:490`, `:137`).

**Fresh ids are minted at PASTE time, never at copy time.** Pasting twice must yield two distinct sets of objects. Use `ProjectStore.reidentified(_:id:startBeat:)` (`ProjectStore.swift:4741-4757`) for clips — it already re-mints the id, copies controller lanes verbatim, and clears `takeGroupID`, which is exactly right for a paste.

### Why not `NSPasteboard` in v1

**Four reasons, in descending force:**

1. **The cross-project motivation does not exist yet.** ✅ Verified: `DAWProApp` (`:11-45`) is a **single** `WindowGroup` over an **App-level** `@State private var model = AppModel()` (`:12`) — so every window would share one `ProjectStore`. And `FileCommands` does `CommandGroup(replacing: .newItem)` (`FileCommands.swift:29`), which replaces the group where macOS puts *New Window*. There is no `DocumentGroup`. **One project per process; cross-window paste is paste within the same project**, which an in-app clipboard covers completely. The premise "the user may reasonably expect to paste between two DAW Pro projects" is a *future* premise, not a current one.
2. **Two clipboards = two sources of truth.** An `NSPasteboard` mirror plus an in-app clipboard needs a `changeCount` arbitration rule ("did something else write the pasteboard since our last put?"). Get it wrong and ⌘V pastes stale objects. That is exactly the agree-by-luck duplication `ArrangeGroupDrag.swift:21-29` and the m23-f finding legislate against.
3. **The MIDI interchange path is under concurrent edit.** The obvious `NSPasteboard` representation for notes is a Standard MIDI File, and `Sources/DAWCore/StandardMIDIFileMapper.swift` + `ProjectStore+MIDIFile.swift` are being edited by another agent right now. Building on their current contents is explicitly forbidden by this brief.
4. **Audio clips have no honest pasteboard representation.** A `Clip` carries an `audioFileURL` plus `startOffsetSeconds`, `gainDb`, fades, curves, `stretchRatio`, a gain envelope and controller lanes. Anything short of the whole struct is lossy; the whole struct is a private format anyway.

**Deferred as GS-9** (below): an `NSPasteboard` **mirror** — the in-app clipboard stays authoritative, and copy *additionally* writes an SMF flavour for notes so ⌘C in the roll can paste into Logic. That is genuinely valuable and genuinely a separate item.

## D10. Routing — reuse the `DeleteMenuPolicy` shape, in a sibling file

**Decision: a new `Sources/DAWAppKit/ClipboardMenuPolicy.swift`, structurally identical to `DeleteMenuPolicy`, cross-referenced from it. Not an extension of it.**

Why a sibling and not an extension: `DeleteMenuPolicy`'s own doc (`:3-4`) declares it "The ONE home for the question *what does a DELETE menu item act on*". Copy/Cut/Paste is a different question with a different (larger) answer set. A file that owns two questions is how a home stops being one.

**Copy and Cut reuse the Delete guard stack verbatim** — same order, same reasons (`DeleteMenuPolicy.swift:59-114`):

1. `arrangeWorkspace` — the Mix console has no clip selection
2. `!isModalPresented` — no acting behind a scrimmed panel
3. the piano roll would have consumed it — `AppModel.pianoRollWouldConsumeKey` (`DAWProApp.swift:1045-1047`), the **same** property, never a second spelling
4. an automation lane would have consumed it — `automationPointSelection.lanesWithSelection.count`
5. otherwise the arrange owns it, if anything is selected

**Automation points are OUT of scope for the clipboard in v1.** Under the stack above, a live automation selection makes Copy *inert* (refused), not "copies clips". That is the honest behaviour — refusing is not the same as silently acting on a surface the user was not pointing at — and it keeps the item's precedence identical to Delete's, which is the property that makes both explainable. Extending the clipboard to breakpoints is a later item.

**Copy/Cut carry `DeleteMenuPolicy`'s two reasoned divergences unchanged:** no `isArrangeTextEditingFocused` term (it is not observable, so it would make the item go stale — `:93-109`), and every other input is `@Observable` (`DAWProApp.swift:1058-1061`).

### ⚠️ Paste is a genuinely different question

Paste's enablement depends on the **clipboard**, not on a selection — you can paste with nothing selected, and the Delete precedence stack has no term for that.

**Decision: route paste on clipboard KIND first, then check the surface that kind requires.**

```
pasteMenuItem(clipboardKind:arrangeWorkspace:isModalPresented:rollOpen:trackCount:) -> PasteMenuItem

  kind == nil                      -> inert, refusedBy .emptyClipboard
  !arrangeWorkspace                -> inert, refusedBy .workspace
  isModalPresented                 -> inert, refusedBy .modal
  kind == .notes  && !rollOpen     -> inert, refusedBy .noRollOpen
  kind == .clips  && trackCount==0 -> inert, refusedBy .noTracks
  otherwise                        -> live, surface = (.pianoRollNotes | .arrangeClips)
```

**Why kind and not engagement.** `AppModel:1029-1036` explicitly rejects `activeEditorSurface` for Delete: engagement answers "which editor did the user last *engage*", which comes apart from "which surface would *consume* this". For paste the discriminator is even simpler and more honest: **notes can only go in a roll and clips can only go in the arrange**, so the payload determines the surface with no ambiguity to arbitrate. Reach for `EditorSurfaceEngagement.lastEngaged` only if a case is found that kind alone cannot resolve — I could not construct one.

**Every input above is `@Observable`** (`EditClipboard.payload`, `workspaceMode`, `isModalPresented`, `openEditorClip`, `store.tracks`), so the item cannot go stale — the property `deleteMenuItem`'s doc (`:1058-1061`) calls load-bearing.

**Carry the `refusedBy` idiom.** A bare `isEnabled == false` cannot tell a test that meant to prove the empty-clipboard guard from one whose roll had quietly closed (`DeleteMenuRefusal`'s doc, `:231-241`).

### Titles

`DeleteMenuPolicy.countedTitle` (`:217-219`) hardcodes the verb `"Delete"`, so it cannot be reused as-is. Its doc demands "ONE producer, so no surface can invent its own plural", and two plural producers would violate that.

**Decision:** hoist the plural rule into a tiny `EditMenuTitles.counted(verb:count:singular:plural:)` in DAWAppKit; `DeleteMenuPolicy.countedTitle` becomes a two-line forwarder. **Existing `DeleteMenuPolicyTests` must stay green with no edits** — that is the acceptance criterion for the refactor.

Titles, following the Delete precedent of always naming the blast radius:

- `"Copy Clip"` / `"Copy 3 Clips"`, `"Cut Clip"` / `"Cut 3 Clips"`
- `"Copy Selected Notes"` / `"Cut Selected Notes"` — **no count**, for `DeleteMenuPolicy.swift:136-143`'s reason: the bridge publishes a Bool, and this policy does not have the number
- `"Paste Clip"` / `"Paste 3 Clips"`, `"Paste Note"` / `"Paste 12 Notes"` — **paste CAN name the note count**, because the count comes from the *clipboard*, which the policy holds. The bridge constraint does not apply on this side. Say so in the doc comment or somebody will "fix" the asymmetry.
- Inert titles: `"Copy"`, `"Cut"`, `"Paste"` — bare, per `DeleteMenuPolicy.inertTitle`'s rule that a disabled item must not name a blast radius it does not have.

⚠️ Unlike Delete, the bare inert titles here **do** collide with the native pasteboard items. That is correct and is the same argument `DeleteMenuPolicy.swift:40-48` makes for keeping both Deletes: the native `copy:`/`paste:` come alive inside a text field and act on **text**; ours act on **objects**. With a rename field open the Edit menu honestly offers both. What makes the collision tolerable there is the *live* title carrying the disambiguation ("Delete 3 Clips"), and the same holds here.

## D11. Paste anchor — stated precisely enough to test

### Clips

Payload: `[ClipboardClip]`. Anchor: `anchorBeat` = the transport playhead in **project** beats.

1. `minStart = min(clip.startBeat)` over the payload.
2. For each entry: **`newStart = anchorBeat + (clip.startBeat - minStart)`**.
   This is the rule that "preserving relative offsets" underdetermines: it says the **earliest** copied clip lands on the playhead and everything else keeps its offset from it.
3. **Negative beats cannot arise.** `anchorBeat >= 0` and `(clip.startBeat - minStart) >= 0` by construction. ✅ **Do not write a clamp for this; write the argument.** (A clamp would be untestable dead code, and dead clamps are how a rule stops being checkable.)
4. **Track resolution — all-or-nothing, deliberately:**
   - **P1, paste in place:** if **every** `sourceTrackID` in the payload still exists in the project, each clip lands on its own source track.
   - **P2, relocated paste:** otherwise, resolve a **base track** = the track owning `arrangeSelection.focusID` if that clip exists; else the first track in store order that can hold the payload's topmost clip; else **refuse the whole paste** with `refusedBy: .noCompatibleTrack`. Then, with `minSourceIndex = min(sourceTrackIndex)`:
     `targetIndex = clamp(baseIndex + (sourceTrackIndex - minSourceIndex), 0, tracks.count - 1)`.
     **The clamp is mandatory and must be written down**, or a 3-track copy pasted onto the last track either crashes or silently drops clips.

   **Why all-or-nothing rather than per-clip:** a paste that lands two clips at home and one relocated is unexplainable to a user. The switch is deterministic and states in one sentence: *"your tracks are still there, so it pastes in place; otherwise it places relative to where you are."*

5. **Kind check** — `Track.canHoldMIDIClips` (`Model.swift:1213`) / `canHoldAudioClips` (`:1231`). Never a local `kind == .instrument` (the m23-v / m23-aj rule).
6. **Kind mismatch and any other per-clip failure → SKIP AND REPORT.** The in-tree precedent is `importAudioBatch` (`ProjectStore+AudioImportBatch.swift:63-70`, `:128-132`): all validation happens **outside** the edit body, a bad item is reported and skipped and never aborts the others, **and the successes land as ONE undo**. If *nothing* is placeable, mutate nothing (no stray undo entry) and report.
7. **⚠️ OVERLAP MUST RESOLVE.** A bespoke batch paste that appends clips without running `ProjectStore.resolvingOverlaps` ships a **silent +6 dB overlap** — the exact defect m11-d/m13-b exist to prevent. Either route each landing through the existing primitives (`duplicateClip` / `addMIDIClip`, which already resolve — `ProjectStore.swift:4820-4823`, `:3317-3320`) or call `resolvingOverlaps` explicitly per landing inside the one `performEdit`.
8. **Selection after paste:** `arrangeSelection.replace(with: pastedIDs)`. Focus is **not** adopted, per `ArrangeSelection.replace(with:)`'s stated rule (`:157-179`): selecting is not opening, and a paste must not open the note editor on a clip the user never clicked.
   **Stated consequence:** if the roll was open on the source clip, pasting closes it (the focus is no longer a member). Accepted. If it reads badly in use, the one-line alternative is `if pastedIDs.count == 1 { selectOnly }` — record which was chosen.

### Notes

Payload: `ClipboardNotes` — clip-local starts, original relative offsets. Target: the clip the roll is open on (`AppModel.openEditorClip`).

1. **Local anchor.** If the transport is inside the edited clip: `localAnchor = playheadProjectBeat - clip.startBeat`. If it is **outside**: `localAnchor = 0`.
   ⚠️ Use the **same** `isVisible` predicate `PianoRollPlayhead.lineX` uses (`PianoRollView.swift:1158-1160`); do not re-derive it.
   **`0` is not an invention** — it is the roll's own shipped rule for playhead-relative operations: `PianoRollBarOps.targetBarStartBeat` is documented as "the bar under the playhead, **else bar 0**" and drives the bar-ops cluster (`PianoRollView.swift:568-572`). And **parking at the nearer edge is refused by precedent**: m23-c1 established that the roll never parks the playhead at an edge — off-clip it draws `OffClipEdgeCue` instead.
2. **Snap the anchor ONCE, then translate rigidly:**
   `snappedAnchor = model.snap(beat: localAnchor, resolution: effectiveSnap)`, then
   **`newStart = snappedAnchor + (note.startBeat - minNoteStart)`**.
   ⚠️ **Never snap each note individually.** That is the m23-g2 defect verbatim (`ArrangeGroupDrag.swift:11-19`): snapping each element's absolute start **welds together** elements at different sub-grid phases and silently destroys the rhythm the user copied. Snapping is a property of the gesture, not of each element. With snap `off`, `PianoRollModel.snap` passes through (floored at 0), so the same code path is correct.
3. **Past the clip end: no clamp, no length extension.** ✅ A note pasted past `clipLengthBeats` is **legal-but-latent** and the app **already renders it honestly**: `PianoRollModel.playableEndBeat` returns nil (`:224-229`) and `drawNotes` gives it the m19-g ghost pill (`PianoRollView.swift:1644-1671`), with the velocity lane matching (`VelocityLane.swift:75-83`). The honest behaviour already has a visual vocabulary; do not invent a clamp for it.
4. **⚠️ Fresh UUIDs for every pasted note.** `MIDINote(id: UUID(), pitch:velocity:startBeat:lengthBeats:)`. Reusing source ids while pasting into the same clip yields duplicate ids, which breaks `MIDINote.canonicallyOrdered` comparisons (used by `needsReseed`, `:149-152`) and makes selection ambiguous.
5. **Selection after paste:** the pasted notes become `model.selection`, so the user can drag them immediately. This matches the double-tap-add precedent (`model.selectOnly(note.id)`, `:1055`).
6. **Repeated ⌘V: the anchor does NOT advance.** Two pastes at one playhead position stack. **This is a product call — flagged in §D16.** Default rationale: the playhead is visible, so a non-advancing anchor is explainable; an invisible advancing anchor is not.

## D12. Undo — confirmed mechanism, and ⚠️ one real trap

**Mechanism, confirmed:** `ProjectStore.performEdit(_:key:_:)` (`ProjectStore.swift:5980-5995`) is the single funnel; it journals only when the state actually changed. The `importAudioBatch` precedent (`ProjectStore+AudioImportBatch.swift:141-170`) is exactly right for clip paste: validate outside, mutate inside **one** `performEdit`, call `engine?.tracksDidChange(tracks)` **once** at the end. One paste = one undo step. ✅

### ⚠️ THE COALESCING TRAP — verified by reading, needs a test

`ProjectStore.setClipNotes` journals with **`key: "clip.notes:\(clipID.uuidString)"`** (`ProjectStore.swift:3346`), i.e. it **coalesces**. `UndoJournal.coalescingWindow` is **800 ms** (`UndoJournal.swift:91`) and `recordEdit` folds when the top entry has the same non-nil key inside the window (`:127-141`).

**Consequence:** a note paste routed through the roll's existing `commit()` → `setClipNotes` path, landing within 800 ms of a note drag on the same clip, **folds into the drag's journal entry**. One ⌘Z undoes both. Two rapid pastes fold into one. A gate that pastes once into a quiet clip would pass and never see it.

**Fix — one additive `DAWCore` entry point, no wire change:**

```
@discardableResult
public func pasteNotes(clipID: UUID, notes: [MIDINote]) throws -> Clip
```

Same validation as `setClipNotes` (`clipNotFound`, `requireNotCompMember`, `notAMIDIClip`, the re-clamp through `MIDINote.init`, `canonicallyOrdered`), but `performEdit("Paste Notes")` with **no key**. The view calls a new `onPasteNotes` closure instead of `onCommit`.

Why not a defaulted parameter on `setClipNotes`: the coalescing key is derived from `clipID`, and a Swift default expression cannot reference another parameter. A separate method is the clean version, and it is additive — `setClipNotes` and every one of its callers (the wire's `clip.setNotes`, the roll's `commit()`, MIDI import) are untouched.

**A later note drag does not fold into the paste**, because `recordEdit` requires **both** keys non-nil and equal, and the paste's key is nil. So paste and the drag after it are two entries. Correct.

**Test (DAWCore, headless):** `setClipNotes` → `pasteNotes` back-to-back on the same clip with an injected clock inside the 800 ms window; assert `store.undoLabels` holds **two** entries and that the top reads `"Paste Notes"`. `UndoJournal` already carries a `now: () -> ContinuousClock.Instant` clock seam (`:96`) that tests inject.

### Cut

**Cut = the delete that already ships, plus a clipboard write.** Copy has no domain effect, so cut's only journal entry is the delete's. One ⌘Z undoes a cut. ✅

**⚠️ Order matters: capture the payload from live state, perform the delete, and write the clipboard ONLY on success.** `ProjectStore.removeClips` can refuse (a take-comp member — `:3602ff`), and a cut that leaves the clipboard loaded while nothing was removed is a lie about what happened. Route through `AppModel.deleteArrangeSelection()` (`:994-1014`) verbatim, so the stale-id filter, the m23-am refusal-anchor policy and the clear-only-on-success rule all apply unchanged; write the clipboard on its `true` return.

**Cosmetic gap, named:** the undo entry for a cut will read whatever `removeClips` labels it, not "Cut 3 Clips". Fixing that means a defaulted `label:` parameter on `removeClips` — additive and safe, but a separate optional item. Do not bundle it.

## D13. ⚠️⚠️ ⌘X / ⌘C / ⌘V — the hazard, precisely

**Getting this wrong breaks every text field in the app.** The reasoning must be exact, so here it is in full.

**The m17-d hazard, restated:** menu key equivalents are checked **before** text insertion. `EditCommands.swift:33-40` and `DeleteMenuPolicy.swift:14-21` are emphatic that a Delete item with `.keyboardShortcut(.delete)` would steal Backspace from every rename field. **The hazard belongs to the SHORTCUT, not to the ITEM** — that distinction is what made the m23-cf Delete menu item possible at all.

**Is ⌘C/⌘X/⌘V the same hazard? Partly — and the difference matters.**

- Backspace's hazard is that it is an **unmodified, text-insertion-adjacent** key that has no legitimate menu meaning.
- ⌘C/⌘X/⌘V are the **standard pasteboard equivalents**. AppKit routes them as `copy:` / `cut:` / `paste:` down the responder chain, and `NSTextView` implements all three — so **in a text field they already work on text**, natively, today, with no code in this app.

**But the hazard is real in the other direction, and it is the same shape.** `Button("Copy 3 Clips") { … }.keyboardShortcut("c", modifiers: .command)` inside a `CommandGroup` creates a menu item whose key equivalent is ⌘C and whose action is **your closure**. Menu key equivalents are checked before the responder chain. **So ⌘C typed in a rename field would fire clip-copy instead of copying the text.** That is m17-d transposed exactly: a menu key equivalent outranking a text field.

**Four options:**

| | approach | verdict |
|---|---|---|
| **1** | `CommandGroup(replacing: .pasteboard)` with custom items carrying ⌘C/⌘X/⌘V | **Reject.** Removes the native items outright; text fields lose copy/paste app-wide. |
| **2** | `CommandGroup(after: .pasteboard)` with new items *also* carrying ⌘C/⌘X/⌘V | **Reject for v1 — and it is worse than "unknown": it is UNGATEABLE.** See the m23-g1 law immediately below. |
| **3** | `CommandGroup(after: .pasteboard)`, **no key equivalents at all** — "Copy 3 Clips" / "Paste 12 Notes" | ✅ **RECOMMENDED FOR v1.** Zero hazard, by exactly the m23-cf argument that is already paid for. |
| **4** | Implement `copy:` / `cut:` / `paste:` on the responder chain so the **native** items go live per surface | ✅ **The macOS-correct end state — GS-9b, a later item.** Note `EditorSurfaceRouter`'s ban on `NSResponder` notions (`EditorSurfaceRouter.swift:81-82`) is scoped to *that router*, not app-wide, so this is not forbidden — but it is a new arbitration mechanism and deserves its own item and its own measurement. |

### ⚠⚠ Two standing in-tree arguments I found late, and they are decisive

Both are written on shipped code that made this exact choice, and both apply verbatim.

**(a) A KEY EQUIVALENT CANNOT BE VERIFIED BY ANY GATE IN THIS TREE.** The m23-g1 law, recorded on the Export item (`Sources/DAWAppKit/ExportMenuPolicy.swift:17-33`) and again on the Bounce item (`Sources/DAWApp/FileCommands.swift:47-55`):

> an unbundled staging binary does not route real key events, so a key equivalent cannot be verified by any gate here — only by `dist/DAWPro.app` and the user's hands.

So the "measure option 2 on staging" fallback is **not available**: staging on 17695 cannot exercise it at all. Verifying ⌘C/⌘X/⌘V costs a `dist/DAWPro.app` rebuild plus manual testing, every time, forever. **A menu item with no key equivalent is fully testable; a key equivalent is invisible to the whole gate corpus.** That asymmetry, not taste, is why every recent menu item in this app ships without one.

**(b) THERE IS ALREADY ONE UNDIAGNOSED KEY PATH IN THIS APP.** `FileCommands.swift:51-53`:

> m23-cf is still OPEN on an undiagnosed DELETE key that never reaches its handlers; adding a second key path before the first is understood makes both harder to diagnose.

✅ **Verified in the roadmap, not recalled:** `docs/ROADMAP.md:825` carries `- [ ] (m23-cf)` with the user's own answer recorded — selection works and is visible on **both** surfaces, while DELETE fails on both, so *"this is NOT the roll, it is the key never reaching any handler"*, with SwiftUI keyboard focus / macOS Full Keyboard Access as the live suspects. The menu half shipped; the **key** is still undiagnosed. And this is already a **standing roadmap-level rule**, not an inference of mine: `docs/ROADMAP.md:843` (m23-ct, computer-keyboard input) states verbatim *"Do not start this until m23-cf's key-path half is understood — building a second keyboard consumer on top of an unexplained keyboard bug would make both harder to diagnose."* Adding three new key paths (⌘C/⌘X/⌘V) into a keyboard layer with a live, unexplained delivery failure would make both problems harder to isolate. **This argument expires when m23-cf is diagnosed, and not before.**

Together these turn option 3 from "the cautious choice" into **the only choice that this tree can currently verify**, and they set the precondition for GS-9b: diagnose m23-cf first.

**⚠️ FLAG PLAINLY: the user asked for "copy/paste", and option 3 ships it MENU-ONLY.** ⌘C/⌘V will not work on clips or notes in v1. That is a partial delivery of the request and it belongs in the user-decision list (§D16), not buried in an implementation note.

## D14. ⚠️ THE WIRE QUESTION — recommendation and its cost

### Recommendation: **(b) staging-tier only.**

The framing "(a) real verbs vs (b) staging-tier" hides the actual discriminator, which is visible in the *different* written rationales of the two app-tier precedents:

- **`debug.arrangeMarquee`** — no wire verb because the effect is **UI state** (`DAWProApp.swift:5187-5190`: "the selection is UI state, and the marquee's only domain effect is the selection it produces").
- **`debug.trackHeaderDrag`** — no wire verb because the effect is a **domain mutation that already has one** (`:5289-5291`: "the drag's only domain effect is `track.reorder`, which IS on the wire, so a second agent-facing verb here would be a duplicate ordering authority").

**Applied here, both arguments fire, and they fire on different verbs:**

1. **`edit.copy` / `edit.cut` have no domain effect at all.** Copy mutates nothing. Putting `edit.copy` on the wire means putting **app clipboard state** on the wire — the same category `debug.arrangeMarquee` rejects for selection.
2. **`edit.paste` would have to READ that app-tier clipboard**, so it cannot be a headless `DAWControl` verb. It would route through `appCommandHandler` — which `Commands.swift:170-172` documents as *the debug tier by definition*. An `edit.paste` on `allCommands` whose implementation lives behind `appCommandHandler` is a wire verb that is architecturally a debug command wearing a badge.

That is an architectural argument, not a taste one.

### The honest audit of what agents can already do

- **Notes: fully reachable, already atomic.** `clip.setNotes` → `ProjectStore.setClipNotes(clipID:notes:)` takes the **whole array** (`:3332`). An agent reads a clip's notes, merges a transposed/offset copy, writes back — one call, one undo step. `edit.copy`+`edit.paste` for notes would add **zero** agent power.
- **Clips: reachable, but NOT atomically.** `clip.duplicate` → `duplicateClip(clipId:toStartBeat:toTrackId:)` (`:4781`) does exactly one clip per call, each its own `performEdit("Duplicate Clip '…'")`. N clips = **N undo steps**.

**So the real gap is not "copy/paste". It is atomic multi-clip duplication.** And if the user wants agents to have that, the honest verb is **one** batch verb — `clip.duplicateBatch {items:[{clipId, toStartBeat?, toTrackId?}]}`, one `performEdit`, `importAudioBatch`'s skip-and-report shape — **not three edit verbs over an app-tier clipboard.** That is a *user decision about agent capability* (§D16), not an engineering one, and it is cleanly separable from everything else in this plan.

### The cost of (a), stated honestly

Choosing (a) moves **six-plus pinned sites** for zero added agent power:

| site | today | after |
|---|---|---|
| `Sources/DAWControl/Commands.swift` `allCommands` | 173 | 176 |
| MCP server tool count | 176 (142 wrapper + 34 direct) | 179 |
| `scripts/gates/m23t-baroperand.mjs:377` `EXPECTED_VERBS` | 173 | 176 |
| `docs/ARCHITECTURE.md` "**173 commands**" headline | 173 | 176 |
| `dist/DAWPro.app` in-binary verb count | 173/173 | must be rebuilt |
| `claude-plugin/server/index.mjs` | **already stale at 174 vs 176** | must be regenerated |

⚠️ And re-counting is itself a known trap: `allCommands` is a bare `[String]`, so `Command(`-shaped patterns return a confident **0**, and a naive quoted-string count returns **174** off a comment inside the array. Cross-check via `rejectUnknownKeys(…, verb:)` occurrences. **Decompose; never eyeball.**

### The staging-tier seam (what (b) actually ships)

**Verb: `debug.editClipboard`. App tier, off `allCommands`, off MCP. Zero wire growth.**

- `{}` — **read-only** (the m11-a bare-read law).
- `{act:"copy"|"cut"|"paste"}` — drives the **same** `AppModel.performMenuCopy() / performMenuCut() / performMenuPaste()` the menu buttons call, so the seam cannot drift from the menu (the `debug.arrangeSelection {act:"delete"}` precedent).

Echo:
```
{
  "kind": "clips"|"notes"|null, "clipCount": n, "noteCount": n, "seq": n,
  "menu": { "copy":  {title, enabled, refusedBy},
            "cut":   {title, enabled, refusedBy},
            "paste": {title, enabled, refusedBy} },
  "pastedClipIds": [...], "pastedNoteIds": [...],
  "skipped": [{reason, sourceClipId}], "refusal": string|null
}
```

The `menu` block is what makes every `refusedBy` branch gate-able without a screenshot, and `skipped` is what makes the skip-and-report rule provable.

## D15. Failure modes — Part 2

| # | failure | why | the assertion that catches it |
|---|---|---|---|
| **F10** | pasted clip silently overlaps a resident: **+6 dB, no warning** | batch paste bypasses `resolvingOverlaps` | paste onto an occupied region; assert the resident was trimmed/removed exactly as `clip.move` would |
| **F11** | one ⌘Z undoes a paste **and** the edit before it | note paste routed through coalescing `setClipNotes` | injected-clock DAWCore test: edit-then-paste inside 800 ms → **two** journal entries |
| **F12** | duplicate note ids in one clip; reseed/selection misbehave | pasted notes reuse source ids | paste into the source clip; assert `Set(ids).count == notes.count` |
| **F13** | ⌘C stops working in every rename field | key equivalents added to a `CommandGroup` | none in v1 — **option 3 removes the failure mode rather than testing for it** |
| **F14** | Paste greyed when it should be live (or vice versa) | an input that is not `@Observable` | drive `debug.editClipboard` copy → open the roll → assert `menu.paste.enabled` flipped with no other action |
| **F15** | clipboard loaded but nothing was cut | cut writes the clipboard before the delete is known to succeed | cut a take-comp member; assert refusal **and** `kind == null` (clipboard untouched) |
| **F16** | repeated ⌘V drifts to an invisible anchor | someone adds anchor advance without a visible referent | paste twice; assert identical `startBeat`s (or the decided rule) |
| **F17** | 3-track paste onto the last track crashes or drops clips | missing `clamp` in the P2 index map | headless: `baseIndex + delta` past `tracks.count-1` clamps, and the collisions are reported as skips |
| **F18** | paste of a mixed audio+MIDI payload onto one track kind aborts everything | a `throw` inside the edit body instead of skip-and-report | mixed payload onto an instrument track: MIDI lands, audio is reported, **one** undo step |
| **F19** | a fully-refused paste still leaves a stray undo entry | `performEdit` entered with nothing to do | `undoLabels.count` unchanged after a paste that placed nothing |

## D16. Implementation plan — Part 2

### GS-4 — clipboard model + policy (DAWAppKit, headless, no wiring)

**New files:** `Sources/DAWAppKit/EditClipboard.swift`, `Sources/DAWAppKit/ClipboardMenuPolicy.swift`, `Sources/DAWAppKit/PasteAnchorPolicy.swift`, `Sources/DAWAppKit/EditMenuTitles.swift`
**Touched:** `Sources/DAWAppKit/DeleteMenuPolicy.swift` (only: `countedTitle` becomes a forwarder + a cross-reference sentence)

`PasteAnchorPolicy` is a pure `nonisolated enum` owning the D11 rules — the offset rule, the P1/P2 track resolution with its clamp, and the note local-anchor rule — taking plain values (payload, `anchorBeat`, live track kinds/ids/indices) and returning resolved landings plus skips. **It must not touch `ProjectStore`, SwiftUI or AppKit.** Put the paste-in-place vs paste-to-selected-track fork behind a single named enum case so overruling it is one line and one test table (the `EditorSurfaceRouter.swift:73-77` "the overrule costs one line" discipline).

**Tests:** `Tests/DAWAppKitTests/PasteAnchorPolicyTests.swift`, `ClipboardMenuPolicyTests.swift` — sweep every `refusedBy` branch exhaustively (the `EditorSurfaceRouterTests` shape), plus every D11 numbered rule including the P2 clamp and the "no negative beat is reachable" argument as a property test over random payloads.
**Route:** `swift-app-engineer`. **Depends on:** nothing. **Runs in parallel with all of Part 1.** **Weight:** M.

### GS-5 — Copy / Cut, arrange + roll (DAWApp)

**Touched:** `Sources/DAWApp/EditCommands.swift` (add to the existing `CommandGroup(after: .pasteboard)`, **no key equivalents** — carry the D13 banner comment verbatim), `Sources/DAWApp/DAWProApp.swift` (`AppModel`: hold `EditClipboard`; add `copyMenuItem` / `cutMenuItem` / `performMenuCopy()` / `performMenuCut()` mirroring `deleteMenuItem` / `performMenuDelete` `:1062-1112`), `Sources/DAWAppKit/PianoRollNoteSelectionBridge.swift` (a `copyNonce`, the `deleteNonce` twin, so the menu can reach the `@State private` model), `Sources/DAWApp/PianoRoll/PianoRollView.swift` (`.onChange(of: copyNonce)`).

⚠️ **Cut writes the clipboard only after the delete returns `true`** (F15).
⚠️ Also add Copy/Cut to the **existing context menus** — the arrange clip menu and the roll's `noteContextMenu` (`PianoRollView.swift:1134-1147`). With no key equivalents in v1, the context menu is the fast path, and m23-cf's whole lesson is that an operation reachable by only one route is an operation that goes missing.

**Route:** `swift-app-engineer`. **Depends on:** GS-4. **Weight:** M.

### GS-6 — Paste clips (DAWCore + DAWApp)

**Touched:** `Sources/DAWCore/ProjectStore.swift` or a **new** `Sources/DAWCore/ProjectStore+Paste.swift` (preferred — keeps the 7 245-line file from growing): `pasteClips(_ landings: [ResolvedClipLanding]) throws -> [ClipPasteOutcome]`, built to the `importAudioBatch` template — validate outside, one `performEdit("Paste N Clips")`, `resolvingOverlaps` per landing, one `engine?.tracksDidChange`, per-item outcomes in request order.
**Touched:** `Sources/DAWApp/DAWProApp.swift` — `pasteMenuItem`, `performMenuPaste()`, skips surfaced through the existing amber refusal bubble (`presentArrangeSplitRefusal`, `:746`).

**Tests:** `Tests/DAWCoreTests/ProjectStorePasteTests.swift` — one undo step for N clips; overlap resolution matches `clip.move`; a mixed-kind payload skips-and-reports without aborting; a fully-refused paste adds **no** journal entry (F19); the P2 clamp (F17).
**Route:** `swift-app-engineer`. **Depends on:** GS-4, GS-5. **Weight:** M.

### GS-7 — Paste notes (DAWCore + DAWApp)

**Touched:** `Sources/DAWCore/ProjectStore.swift` — **`pasteNotes(clipID:notes:)`**, uncoalesced, label `"Paste Notes"` (D12).
**Touched:** `Sources/DAWApp/PianoRoll/PianoRollView.swift` — a `pasteNonce` on the bridge; an `onPasteNotes` closure (the `onCommit` shape, so the view stays store-free and previewable); anchor via `PasteAnchorPolicy`; snap the anchor **once**; select the pasted notes.

**Tests:** `Tests/DAWCoreTests/` — **the F11 coalescing leg with an injected clock** (the highest-value test in Part 2); fresh ids (F12); a note pasted past the clip end survives as latent data with the clip length unchanged.
**Route:** `swift-app-engineer`. **Depends on:** GS-4, GS-5. **Runs in parallel with GS-6.** **Weight:** M.

### GS-8 — clipboard seam + gate

**Touched:** `Sources/DAWApp/DAWProApp.swift` — `case "debug.editClipboard"`, driving the same `performMenuCopy/Cut/Paste`.
**New:** `scripts/gates/<id>-clipboard.mjs`, **staging port 17695**.

Legs: round-trip clip copy→paste at a known playhead lands at the derived beat; multi-clip relative offsets preserved; kind mismatch skipped-and-reported; **one** undo step reverses a whole paste (read `edit.history` before/after); note copy→paste round-trip; every `refusedBy` branch reachable and named; cut refusal leaves the clipboard empty.

⚠️ **Take the baselines of any gate you touch BEFORE mutating Swift.** ⚠️ The gate must **derive** its beats from the echoed `ppb`/playhead, never hardcode. ⚠⚠ **NO LEG MAY DEPEND ON A REAL KEY EVENT** — an unbundled staging binary does not route them (m23-g1), so such a leg would pass or fail for reasons unrelated to the code. Every route here is reachable through the seam or the menu policy; keep it that way.
**Route:** `mcp-integration-engineer` for the seam plumbing, `qa-test-engineer` for the gate. **Depends on:** GS-6, GS-7. **Weight:** M.

### GS-9 (deferred) — `NSPasteboard` mirror + SMF flavour

⚠️ **BLOCKED** on the concurrent `StandardMIDIFileMapper.swift` / `ProjectStore+MIDIFile.swift` work. Needs a `changeCount` arbitration rule (D9 reason 2) written down before any code. **Route:** `swift-app-engineer`.

### GS-9b (deferred) — `copy:` / `cut:` / `paste:` on the responder chain

The macOS-correct way to make the **native** ⌘C/⌘X/⌘V items go live per surface — and the only route that adds keystrokes **without** creating a `CommandGroup` key equivalent that outranks text fields. ⚠️ **PRECONDITION: m23-cf's undiagnosed DELETE key must be diagnosed first** (`FileCommands.swift:51-53`), and ⚠️ **it cannot be gated on staging** (m23-g1) — acceptance is a `dist/DAWPro.app` rebuild plus manual verification, which must be budgeted in the item, not discovered during it. **Route:** `swift-app-engineer`.

---

# PART 3 — sequencing

## Dependency graph

```
TRACK A (roll band) ── independent of Track B ──────────────────────
  GS-1  PianoRollMarquee geometry (DAWAppKit)          [S]
    │     (⚠ starts by extracting PianoRollModel.noteRect — ONE producer)
    └── GS-2  promotion + chord unification (DAWApp)   [M]
          ├── GS-2b group-drag rigidity, both axes     [S–M]  ← the m23-g2 defect
          └── GS-3  debug.pianoRollMarquee + gate      [M]

TRACK B (clipboard) ── independent of Track A ─────────────────────
  GS-4  EditClipboard + policies (DAWAppKit)           [M]
    └── GS-5  Copy / Cut, both surfaces + menus        [M]
          ├── GS-6  Paste clips (DAWCore + app)        [M] ┐ parallel
          └── GS-7  Paste notes (coalescing fix)       [M] ┘
                └── GS-8  debug.editClipboard + gate   [M]

DEFERRED — each its own item, each needs a decision first
  GS-9   NSPasteboard / SMF mirror       (blocked: concurrent MIDI-file work)
  GS-9b  responder-chain ⌘C/⌘X/⌘V        (blocked: m23-cf diagnosis; ungateable on staging)
  GS-10  Select All (⌘A)                 (adjacent gap, §1.1)
```

## What runs in parallel

- **GS-1 and GS-4 can start simultaneously.** Neither touches a file the other touches; both are headless DAWAppKit + tests.
- **Track A and Track B stay disjoint through GS-3 / GS-5.** The one shared file is `PianoRollNoteSelectionBridge.swift` — GS-3 adds the marquee stage/echo, GS-5 adds `copyNonce`, GS-7 adds `pasteNonce`. ⚠️ **Serialize the bridge edits or expect a merge conflict.** Cheapest fix: land GS-3 before GS-5, or have one agent make all three bridge additions in one pass up front.
- **GS-6 and GS-7 are parallel** — different store methods, different surfaces, one shared `AppModel` region.
- **GS-2b is parallel with GS-3** — GS-2b is pure `PianoRollModel` + headless tests; GS-3 is the seam + gate. Neither reads the other's changes. ⚠️ **GS-2b does not strictly depend on GS-2 either** — the deformation ships today and can be fixed first. It is placed after GS-2 only because the band is what makes it *reachable*, so fixing it earlier is correct but harder to demonstrate.
- **GS-3 and GS-8 gates are parallel** and belong to `qa-test-engineer`.

## Suggested order if run serially

GS-1 → GS-4 → GS-2 → GS-5 → GS-2b → GS-3 → GS-7 → GS-6 → GS-8.

Two orderings are deliberate, not incidental:
- **GS-7 before GS-6** — the undo-coalescing trap (D12) is the highest-risk unknown in Part 2 and should be proven early, on the cheaper of the two paste surfaces.
- **GS-2b before GS-3** — GS-3's gate drives bands that produce large selections, and a large selection is exactly what makes the deformation visible. Fixing the deformation first means the marquee gate never has to encode deformed positions as expected values.

## Roadmap ids

`GS-n` are **plan-local labels**. This document is read-only work; real ids must be assigned from the live `docs/ROADMAP.md` at pick-up time. ⚠️ **Re-enumerate from the roadmap rather than trusting any cached queue** — that index has been wrong in consecutive cycles.

---

## D17. ⚠️ USER DECISIONS — offer options, do not act

Five, in descending order of how much they change the delivery:

1. **⌘C / ⌘X / ⌘V keystrokes.** The user asked for "copy/paste"; **v1 as designed is MENU + CONTEXT-MENU ONLY, with no keystrokes** (D13 option 3), because a `CommandGroup` key equivalent outranks text fields and would break every rename field — the m17-d hazard transposed. Options: **(i)** ship menu-only now, add GS-9b later once m23-cf is diagnosed (recommended); **(ii)** ship key equivalents now and verify them by hand against a rebuilt `dist/DAWPro.app` (**⚠️ no gate can cover them — the m23-g1 law**, and it would add a second key path while m23-cf's DELETE key is still undiagnosed); **(iii)** hold all of Part 2 until m23-cf is diagnosed.
2. **The wire.** Recommended **(b) staging-tier only**, with the honest finding that **agents already have note copy/paste atomically** via `clip.setNotes`, and the real gap is **atomic multi-clip duplication**. If the user wants agents to have that, the right answer is **one** additive `clip.duplicateBatch` verb (+1 on every pinned count), **not** three `edit.*` verbs over an app-tier clipboard.
3. **Paste-in-place vs paste-to-selected-track.** The brief's default (paste home when the source tracks still exist) is implemented. **Logic and Pro Tools both paste to the selected track.** The fork is one enum case in `PasteAnchorPolicy` plus one test table.
4. **Repeated ⌘V.** Default: the anchor does **not** advance; two pastes stack. Alternative: advance by the payload's span.
5. **Single-clip paste closes an open piano roll**, because `ArrangeSelection.replace(with:)` never adopts a focus (selecting is not opening). Accepted as designed; the alternative is one line (`if pastedIDs.count == 1 { selectOnly }`).

---

## D18. `docs/ARCHITECTURE.md` — proposed "Key future decisions" patch

I am read-only for this task, so this is the **text to apply**, not an applied edit. Add under **Key future decisions**:

> **Piano-roll rubber band (settled 2026-08-09).** The roll's pitch ladder is **uniform** (`PianoRollModel.y(forPitch:)`), unlike the arrange's, so `PianoRollMarquee` takes notes + `rowHeight`/`pixelsPerBeat` rather than resolved lane bands. Membership is decided against **`PianoRollModel.rect(for:)`** — the hit rect with its `max(3, …)` floor — never the drawn (inset) pill and never re-derived beat math, so a band and a click can never disagree. The band is armed by **promotion inside the existing `gridDrag`**, not by a `.simultaneousGesture`: the roll's competitor is a zero-distance drag that already clears the selection on release, so a simultaneous gesture would race it at an ordering this tree cannot observe. Shift/⌘ route through the one `ArrangeClickIntent` mapping on **both** the band and the click — a stated change to shipped ⌘-click behaviour in the roll.
>
> **Clipboard (settled 2026-08-09).** In-app, typed, `@MainActor @Observable`, living in **DAWAppKit** and held by `AppModel` (the `PianoRollNoteSelectionBridge` shape). **No `DAWCore` change is required for the clipboard.** `NSPasteboard` is deliberately **not** used in v1: the app is a single `WindowGroup` over an App-level `AppModel` with `.newItem` replaced, so there is one project per process and no cross-project paste to serve; a pasteboard mirror alongside an in-app clipboard would need `changeCount` arbitration — two sources of truth for one question. Copy/cut/paste ship **staging-tier only** (`debug.editClipboard`), with **zero wire growth**: `edit.copy` has no domain effect, and `edit.paste` would have to read app-tier state through `appCommandHandler`, which is the debug tier by definition. Agents already have atomic note copy/paste via `clip.setNotes`; the only genuine agent gap is atomic multi-clip duplication, whose honest form is one additive `clip.duplicateBatch` verb — **pending the user's word**.
>
> **⌘X/⌘C/⌘V (open).** v1 ships menu + context-menu routes with **no key equivalents**, because a `CommandGroup` key equivalent is checked before text insertion and would steal ⌘C from every rename field (the m17-d hazard). Making the **native** pasteboard items go live per surface via `copy:`/`cut:`/`paste:` on the responder chain is the macOS-correct end state and is a separate item.

⚠️ While editing that file: its command **total** has rotted twice already (headline 168 vs a coherent 171; then "101 of 126" vs a measured 171 of 171). **Do not touch the count in this patch** — nothing here moves it.
