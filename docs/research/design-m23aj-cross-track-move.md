# m23-aj — the cross-track clip MOVE verb: design record

**Status:** design complete 2026-08-02 (`daw-architect`). Ready for `swift-app-engineer` to implement
without re-deciding anything. Nothing here is provisional.
**AMENDED 2026-08-02 — read §18 FIRST.** The m23-aj-1 review found that the `.toTrack` collapse can
MANUFACTURE a silent mover-mover overlap this design never covered. **§18 is authoritative over §8's
error table and §15's drag bullet; it adds one `ProjectError` case, seven DAWCore test legs and three
gate legs.** §0, §8, §12, §13, §15 and §16 each carry a pointer to it, and **none of those six is
complete on its own any more**. Sections are deliberately **NOT renumbered** — `docs/ROADMAP.md` and
`ProjectStore.swift`'s own doc comment cite §9 / §9.3 / §12 / §13 by number.
**Primary files:** `Sources/DAWCore/ProjectStore.swift`, `Sources/DAWCore/Model.swift`,
`Sources/DAWControl/Commands.swift`, `Sources/DAWControl/CopilotCatalog.swift`,
`mcp-server/src/server.ts`, `Sources/DAWAppKit/ArrangeNudge.swift`,
`Sources/DAWApp/DAWProApp.swift`, `Sources/DAWApp/ContentView.swift`.
**Full Xcode:** NOT required. No entitlements, no AUv3, no code signing, no bundling. Everything
here is domain model + control protocol + SwiftUI key handling, all reachable from
`swift build` / `./scripts/test.sh` on Command Line Tools alone.

**Roadmap item:** `docs/ROADMAP.md:747`.

---

## §0 The decisions, in one table

| # | Question | Decision |
|---|---|---|
| Q1 | Two shapes or one? | **Two public shapes over ONE private core.** `moveClips(ids:byTracks:byBeats:)` (rigid track DELTA) and `moveClips(ids:toTrackId:byBeats:)` (explicit DESTINATION, collapses). **TWO control commands, TWO MCP tools** — not one command with an either/or param. |
| Q2 | Landing policy | **RAW TRACK INDEX is the vertical axis. No SKIP anywhere.** Top/bottom of the track list **CLAMPS** whole-group (the beat-0 precedent), reported by `clampedTracks`, no throw. A landing track that cannot hold the clip **REFUSES the whole move** with the errors `duplicateClip` already throws. A mixed audio+MIDI group succeeds only when every mover's landing accepts it — which in a normal layout means it is effectively immovable vertically, and that is stated, not hidden. |
| Q3 | The mechanic | **Two-phase: build the whole new `[Track]` value, then commit it once.** VACATE every crossing mover from every source array FIRST, then LAND on every destination. No index arithmetic survives across a mutation (`removeAll(where:)`, not `remove(at:)`). Same-track movers keep their array SLOT; crossing movers APPEND. |
| Q4 | Engine safety | **ONE `engine?.tracksDidChange(tracks)` at the end is sufficient and correct. NO `transportBusy` refusal.** The render thread never reads `[Track]`; the two-phase build makes a torn intermediate structurally unrepresentable. |
| Q5 | Combined move | **YES — carry `byBeats` (default 0) from day one.** The overlap window already needs the landing start, so the time delta costs one parameter now and a re-opened overlap computation later. The horizontal clamp and the per-mover overlap loop are hoisted to shared statics so there is exactly one of each. |
| Q6 | Result type | New `ClipsTrackMoveResult` with **per-clip `landings: [ClipLanding]`** (`clipID`/`fromTrackID`/`toTrackID`), the `requestedTrackDelta`/`effectiveTrackDelta`/`clampedTracks` honesty triple, and the horizontal triple + trimmed/removed inherited verbatim. **There is deliberately no `skipped` field** — its absence is a positive statement of the policy. |
| Q7 | Two movers colliding on ONE destination (**§18** — ruled after Q1-Q6, on the m23-aj-1 review) | **REFUSE the whole move, validate-first**, in a new phase **2b'**, throwing a NEW `ProjectError.clipsWouldOverlapOnDestination(firstID:firstName:secondID:secondName:)`. Only a collision this verb MANUFACTURED counts: two movers from the SAME source track were already overlapping (a sanctioned crossfade pair, `ProjectStore.swift:4028-4032`) and are **GRANDFATHERED**. The check runs UNCONDITIONALLY on both shapes and **does evaluate under `byTracks`** — a same-source overlapping pair co-lands there too. What the same-source qualifier removes is the REFUSAL, not the evaluation, and it is load-bearing on the `byTracks` path specifically (§18.4(ii)): without it the ↑/↓ nudge would refuse to move a crossfaded pair at all. **Rejected: movers trimming each other** — it picks which of the user's own clips dies by `uuidString`. |

---

## §1 Q1 — TWO SHAPES, ONE CORE

### 1.1 The decision

Two public entry points on `ProjectStore`, differing ONLY in how each mover's destination track index
is computed, forwarding to one private core:

```swift
/// WHERE the movers land, vertically. The ONLY thing the two public shapes disagree about.
public enum ClipTrackLanding: Sendable, Equatable {
    /// Every mover moves the SAME signed number of tracks (RIGID — vertical offsets survive).
    case byTracks(Int)
    /// Every mover lands on ONE named track (COLLAPSES a multi-track group by construction).
    case toTrack(UUID)
}

@discardableResult
public func moveClips(ids: [UUID], byTracks: Int, byBeats: Double = 0) throws -> ClipsTrackMoveResult

@discardableResult
public func moveClips(ids: [UUID], toTrackId: UUID, byBeats: Double = 0) throws -> ClipsTrackMoveResult

// both forward to:
private func moveClips(ids: [UUID], landing: ClipTrackLanding,
                       byBeats delta: Double) throws -> ClipsTrackMoveResult
```

`Int` — not `Double`, not `UUID?` — is the load-bearing choice on the delta shape, and it is the same
argument `ProjectStore.swift:3920` already makes for `moveClips`' single `Double`:

> "An absolute `[UUID: Double]` signature would let a caller hand in per-clip targets that do not
> share a delta — i.e. it would make 'relative offsets are preserved' a caller PROMISE instead of a
> type-level fact."

One `Int` is one amount. **Vertical rigidity is not something the implementation achieves; it is
something the signature makes unrepresentable to violate.** That is why the delta shape is not
expressed as `[UUID: UUID]` (per-clip destinations), which is the shape a "generalised" API would
reach for first and which would silently permit a non-rigid group move.

### 1.2 Wire: TWO commands, not one with an either/or param

| Surface | Delta shape | Destination shape |
|---|---|---|
| Control | `clip.moveManyByTracks` | `clip.moveManyToTrack` |
| MCP | `clip_move_many_by_tracks` | `clip_move_many_to_track` |
| Copilot catalog | both, in the `clip` section (14 → 16) | |

**Why two and not one `clip.moveManyAcross {ids, byTracks?, toTrackId?, byBeats?}`.** The rejected
form needs a runtime "exactly one of `byTracks` / `toTrackId`" check, and **neither schema surface
can express that**. `CopilotCatalog.schemaObject(_:required:)` is a flat property map plus a
`required` array — measured at `Sources/DAWControl/CopilotCatalog.swift:610-624` — with no `oneOf`;
the MCP `inputSchema` is a flat zod object literal for the same reason. So the schema would advertise
a call shape the router then rejects, which is exactly the failure this project refuses everywhere
else ("advertising an action the store will then refuse is worse than silence" —
`Model.swift:1096-1099`). Two commands make each tool's schema its whole contract.

**Why the DELTA shape is on the wire at all** (the strongest argument, and the one that settles it):
an agent that only had `toTrackId` would have to compute "one track down" itself — which means
reimplementing the vertical axis, including the bus rule, **in a model's head, outside Swift**. That
is a second home for the axis, in the one place no test can reach it. Exposing `byTracks` keeps the
axis where §2 puts it.

**Rejected: expose only the delta shape and let agents pass a big `byTracks`.** A destination is
what an agent's "move these to the Drums bus track… I mean the Drums audio track" actually means,
and computing a delta from two track ids requires the agent to know the array order. It would also
leave the future arrange DRAG — which resolves an ABSOLUTE destination under the pointer — with no
domain verb to call.

**Naming.** Follows `clip.moveMany` / `clip_move_many` (m23-w) exactly: the `Many` suffix marks the
group verbs, and the `ByTracks` / `ToTrack` suffixes name the parameter that distinguishes them.
Nothing is renamed; both are appended.

---

## §2 Q2 — THE LANDING POLICY (the decision this document exists for)

### 2.1 The decision

1. **The vertical axis is the RAW `tracks` index.** A bus occupies a position on it like any other
   track.
2. **Running off the TOP or BOTTOM of the list CLAMPS, whole-group** — never per clip, never a throw.
   `effectiveTrackDelta` is reduced (possibly to 0) and `clampedTracks` reports it.
3. **A landing track that cannot hold the moving clip REFUSES THE WHOLE MOVE**, validate-first, with
   no partial mutation, throwing the errors `duplicateClip` already throws:
   `midiClipsRequireInstrumentTrack(TrackKind)` for a MIDI clip, `trackKindUnsupported(TrackKind)`
   for an audio clip.
4. **There is no SKIP, in either sense** — not "search past a bus", not "move the clips that can and
   leave the rest".
5. **A MIXED audio+MIDI group is a legal input** and moves vertically only when EVERY mover's landing
   accepts it. In the ordinary layout (instrument tracks grouped, audio tracks grouped) that means a
   mixed group cannot move vertically at all. **This is stated loudly rather than engineered around**
   — see §2.5.

### 2.2 Why raw-index-and-refuse beats lane-space-and-skip

The seductive alternative — and the one this design held for a while — is a **clip-lane axis**: define
the vertical sequence as the tracks that can hold clips (`kind != .bus`), so a bus is not a position
at all and a `byTracks: 1` steps over it structurally rather than by searching. It is elegant, it
dissolves the "unsatisfiable search" problem, and it is **wrong**, for one measured reason:

> **`TimelineLanesView` draws a row for EVERY track, buses included.**
> `ContentView.swift:674-675` passes `tracks: store.tracks` (the whole array) and
> `TimelineLanesView.swift:1065 / 1139 / 1197 / 1221 / 1818` all iterate
> `ForEach(Array(tracks.enumerated()))` with no kind filter. A bus is a visible, empty arrange row.

Given that, the decisive argument is about the **future arrange cross-track DRAG**, which this verb
is the domain half of. A drag resolves an **absolute** destination: the row under the pointer. If the
pointer is over a bus row, the drag must refuse — it cannot "skip", because the pointer is where it
is. So the drag's vertical axis is raw rows with a refusal on non-lane rows. If the keyboard used
lane space, **the app would have two vertical axes that disagree about the same visible row**, and
the user would learn two contradictory rules: "↓ hops over the bus" and "you cannot drop on the bus".
That is precisely the class of divergence the `ArrangeDropSnap` / `TrackOrder` / `ResolvedDropBeat`
registries exist to make unrepresentable.

With raw-index-and-refuse there is **one rule, two gestures, one answer: you cannot put a clip on a
bus**, and it is the same predicate (`Track.canHold(_:)`, §2.4) that the drag will consult and that
`duplicateClip` already consults.

### 2.3 The strongest counter-argument, and why it is accepted rather than answered

**It is real: in `[A0, BUS, A1]` the keyboard can never move A0's clip to A1, while a drag can.**
↓ from A0 lands on the bus → refused. ↓↓ (`byTracks: 2`) would work from the wire, but the keyboard
only ever sends ±1, so from the keyboard that clip is stuck.

Accepted, with three mitigations and one honest admission:

* `track.reorder` (m23-h / m23-z, `TrackOrder` is the one home for the permutation) moves the bus out
  of the way, and putting buses at the bottom is what every engineer does anyway.
* The DESTINATION shape reaches A1 in one call from an agent, and the drag will reach it in one
  gesture from a user. Only the *keyboard delta* is weaker, and only in this layout.
* The refusal TEACHES: `trackKindUnsupported(.bus)`'s contract text is
  `"Track kind 'bus' cannot hold this content — only audio tracks accept audio clips."`
  (`MediaImporting.swift:205-206`). The user learns why, not that the key is broken.
* **Admission:** a keyboard that is weaker in an unusual layout is a worse feature than one that
  skips. It is a better *system* than one whose delta axis disagrees with its own visible rows. That
  is the trade, made deliberately.

### 2.4 Why SKIP loses on its own terms too, not just by the axis argument

Even granting lane space, SKIP would have to be a SEARCH the moment kinds enter it — "find the
nearest d′ ≥ |d| in this direction such that every mover lands somewhere that accepts it". Three
things kill it:

1. **Eligibility is PER-CLIP, so a group search is over the INTERSECTION** of every mover's eligible
   set. For a mixed audio+MIDI group that intersection is usually empty, so the search must fall back
   to refuse-or-clamp anyway — SKIP is an extra rule stacked on top of the rule you still need.
2. **A satisfied search is not a satisfying answer.** `byTracks: 1` producing a 3-track move is a
   correctness hazard for an agent, which asked for a specific arrangement change and will report a
   different one to the user.
3. **The brief's framing ("SKIP makes the keyboard layer non-thin") is not quite the reason, and it
   is worth correcting**: the search could live entirely in `ProjectStore`, which sees all tracks, so
   the keyboard would stay thin (pass ±1, read back `effectiveTrackDelta`). SKIP loses on (1) and (2)
   and on §2.2 — not on layering.

**Rejected: CLAMP on kind-incompatibility too** (reduce `|d|` toward 0 until every landing accepts,
floor 0, no throw). It makes ↓ over a bus a silent no-op forever, which is the "a dead key is
indistinguishable from a broken one" failure `ArrangeNudge.gridOffFallbackBeats` was written to avoid
(`ArrangeNudge.swift:120-126`). A refusal that says why is strictly more informative than a clamp
that says nothing.

### 2.5 The eligibility predicate — hoist the missing half

`Track.canHoldMIDIClips` (m23-v, `Model.swift:1115`) is already the ONE home for MIDI eligibility.
Its audio twin does not exist: `duplicateClip` writes the rule inline at `ProjectStore.swift:4161`
as `guard tracks[dt].kind == .audio`. That inline check is the second home, today, in the one verb
that already does cross-track placement. **Hoist it, and compose:**

```swift
// Sources/DAWCore/Model.swift, immediately after canHoldMIDIClips.

/// Whether an AUDIO clip is allowed to live on this track — the `canHoldMIDIClips` twin
/// (m23-aj). Hoisted out of `duplicateClip`'s inline `kind == .audio`, which was the second
/// home for this rule in the one verb that already places clips cross-track.
public var canHoldAudioClips: Bool { kind == .audio }

/// Whether THIS clip may live on THIS track — the composed predicate every cross-track
/// placement asks (m23-aj). Content decides, not the caller's intent: `Clip.isMIDI` is
/// `notes != nil` (`Model.swift:592`), so an audio clip and a MIDI clip are never confused.
/// One home for the QUESTION; the two predicates above stay separate so they can diverge
/// (the `canExportMIDI` / `canHoldMIDIClips` reasoning at Model.swift:1101-1108).
public func canHold(_ clip: Clip) -> Bool {
    clip.isMIDI ? canHoldMIDIClips : canHoldAudioClips
}
```

**Checked before writing this, per the "find the existing home first" law:** the third
`canHoldMIDIClips` consumer named in `Model.swift:1096` is `DAWAppKit.ArrangeEmptyLaneHints`
(`Sources/DAWAppKit/ArrangeEmptyLaneHint.swift:91-94`), and it is **not** a general "can this lane
take a clip" composer — it answers a narrower question (`canHoldMIDIClips && clips.isEmpty` → draw
the double-click hint). So `canHold(_:)` is net-new and does not duplicate it. It lives in **DAWCore**
because the store verb must call it and DAWCore cannot import DAWAppKit; `ArrangeEmptyLaneHints`
keeps consuming the underlying predicate, not the composer.

`duplicateClip:4155-4164` is rewritten to use `canHold(_:)` **with no behaviour change** — that is a
step of its own in §11, proven by the existing `duplicateClip` suite passing unchanged.

### 2.6 The clamp, exactly

```swift
/// The ONE home for the vertical WHOLE-GROUP clamp (m23-aj) — the discrete twin of the
/// beat-0 clamp. Never per clip: a per-clip `min(max(...))` would silently break vertical
/// offsets the moment the topmost mover hits track 0 while the others still have room,
/// which is the exact defect `moveClips`' whole-group beat clamp exists to prevent
/// (ProjectStore.swift:3938-3946).
static func clampedTrackDelta(requested: Int, minTrackIndex: Int, maxTrackIndex: Int,
                              trackCount: Int) -> (effective: Int, clamped: Bool) {
    guard trackCount > 0 else { return (0, requested != 0) }
    let lower = -minTrackIndex                    // topmost mover lands on track 0
    let upper = (trackCount - 1) - maxTrackIndex  // bottommost mover lands on the last track
    let effective = min(max(requested, lower), upper)
    return (effective, effective != requested)
}
```

`lower <= 0 <= upper` holds for any in-range source indices, so the clamp can never invert the sign
of the request, and `effective == 0` is always reachable. **The clamp is a pure range clamp and never
searches** — that is what keeps the "no skip" rule true: `byTracks: 5` on a 3-track project clamps to
the last track and then kind-checks THAT landing. It does not hunt for a landing that works.

### 2.7 Order of operations, and why it matters

**Clamp FIRST, kind-check the clamped landing SECOND.** The reverse order would make the kind check
a function of an out-of-range index. Concretely: `[A0, INST1, A2]`, audio clip on A0, `byTracks: 2`
clamps to 2 (in range), lands on A2, accepted. `byTracks: 1` lands on INST1 and throws. The two
answers are different and both are right; no search bridges them.

**A mover whose destination equals its source is never kind-checked.** Staying put is always legal,
and the verb must not refuse because of a pre-existing state it did not create. (The state cannot
arise today — the store never lets a MIDI clip onto an audio track — so this is a structural
guarantee, not a workaround.)

---

## §3 Q3 — THE ACTUAL NEW MECHANIC: the clip leaves its source array

### 3.1 The decision: build the whole new `[Track]`, then commit it once

```swift
performEdit(label, key: Self.moveClipsKey(ids: unique)) {
    var next = tracks
    …                       // every removal and insertion happens on `next`
    tracks = next           // ONE assignment
    engine?.tracksDidChange(tracks)
}
```

**Rejected: in-place mutation of `tracks`** (what `moveClips` does). It is correct there because a
`startBeat` write cannot invalidate an index. Here it cannot be made correct without index-fixup
bookkeeping, and every observer of `tracks` (SwiftUI, `@Published`/`@Observable` propagation, any
future engine hook inside the edit body) would see a sequence of half-states in which a clip exists
on two tracks, or on none. **The two-phase build makes a torn intermediate structurally
unrepresentable rather than merely absent** — the same reason the m23-ag / `ArrangeDropSnap` family
uses `fileprivate init` producers.

### 3.2 (i) Index invalidation — solved by never using an index across a mutation

Phase-1 `(track, clip)` pairs are used for exactly two things, both **before** any mutation: reading
the clip value, and running `requireNotCompMember`. The removal itself is **index-free**:

```swift
next[t].clips.removeAll { crossingIDs.contains($0.id) }
```

`removeAll(where:)`, never `remove(at:)`. There is no index arithmetic to invalidate, no descending
sort to remember, and no correctness dependence on the order of source tracks.

### 3.3 (ii) Source and destination sets OVERLAP — VACATE ALL, then LAND ALL

A group on tracks 1+2 moving down 1: track 2 is simultaneously vacated by one mover and landed on by
another. **The phases are global, not per-track, and that is the entire answer:**

```
Phase 3a — VACATE: for every source track that has a crossing mover, removeAll those ids.
Phase 3b — LAND:   for every destination track index, in sorted order, place + resolve.
```

By the time 3b touches track 2, the mover that vacated it is already gone from `next[2].clips`. A
per-track "remove mine then add mine" loop would have the vacating mover still present when the
landing mover's overlap pass runs, and the pass would either trim it (data loss) or need it in
`activeIDs` (a mover exempting itself on a track it is leaving — an incoherent exemption).

**`activeIDs` for the pass on destination `dt` is the set of movers LANDING on `dt`.** That is
sufficient: a mover that vacated `dt` is no longer in the array, and every mover that IS in the
window is in the set, so movers cannot trim each other. It is also the set that *says what it means*.

> ⚠️ **CORRECTION TO THE BRIEF, and it is load-bearing here.** The brief states that `moveClips`
> passes `activeIDs` = "the FULL moving set". It does not: `ProjectStore.swift:4042` computes
> `let movingIDs = Set(locs.map { tracks[t].clips[$0.clip].id })` where `locs = byTrack[t]` — the
> **per-track** moving set. The two are equivalent there because `resolvingOverlaps` only ever sees
> one track's array. The distinction matters here because "the movers on this track" is ambiguous
> once clips cross: it must mean **movers LANDING on `dt`**, not movers that STARTED on `dt`. Copying
> the phrase "the full moving set" literally is harmless (a superset over a disjoint array); copying
> `moveClips`' line literally — movers that started here — is a **bug**, because it would omit the
> arriving movers and let them trim each other.

### 3.4 (iii) Removal-then-insertion ordering, and array slots

Within phase 3b, for each destination `dt` in sorted index order:

1. **Same-track movers translate IN PLACE**, keeping their array slot:
   `next[dt].clips[i].startBeat = m.start`.
2. **Crossing movers APPEND**: `next[dt].clips.append(moved)` where `moved` is the clip VALUE with
   `startBeat` set to its landing.
3. **Then** one `resolvingOverlaps` pass per mover landing on `dt`, sorted by `(start, id)`, feeding
   the rebuilt array forward.

**Why same-track movers keep their slot.** Two reasons, both load-bearing.
(a) It is what makes `moveClips(ids:byBeats:)` expressible as this core with `byTracks: 0` — a
remove-then-append would reorder `tracks[t].clips` for a shipped verb that does not reorder it today,
an observable change in `project.snapshot`.
(b) Under `.toTrack`, a mover already on the destination must not be gratuitously shuffled to the end
of the array just because its siblings arrived.

**Why appending crossing movers is safe.** `Track.clips` has **no sortedness invariant** — measured:
the only sort in DAWCore is local, at `ProjectMIDIExportMapper.swift:687`, inside the exporter. Every
existing add path (`addClip`, `addMIDIClip`, `duplicateClip:4171`) appends. Nothing to preserve.

**The clip VALUE travels whole, and `reidentified` is NOT on this path.**

> ⚠️ **CORRECTION TO THE BRIEF.** The brief cites `reidentified` for `Clip.controllerLanes` travelling
> with the clip. Controller lanes do travel — but because the whole `Clip` value moves, not because
> `reidentified` copies them. **Calling `reidentified` here would be a bug**: it mints a fresh `id`
> (breaking every selection, every `edit.history` reference and the caller's own `ids`) and drops
> `takeGroupID` (`ProjectStore.swift:4096-4111`). A move preserves identity. Only `startBeat` changes.
> Confirmed separately: nothing on the `Track` side indexes `controllerLanes`; `Track`'s only
> clip-referencing member is `takeGroups`, handled in §3.5.

### 3.5 Take/comp members: refused WHOLE, validate-first — confirmed as the policy

`Track.takeGroups` is track-scoped (`Model.swift:1064`), and a comp member's geometry is rebuilt from
its group on every comp edit, so a member that crossed tracks would orphan its group. The existing
guard already refuses it: `requireNotCompMember(trackIndex:clipIndex:)`
(`ProjectStore.swift:3549-3554`) throws **`ProjectError.clipInTakeGroup(String)`** — a group NAME, not
an id, whose message is contract text (`MediaImporting.swift:347-349`). It runs in phase 1, over
every id, before any mutation, so a set containing one comp member refuses **whole**. No new rule and
no new error; the escape hatch stays `take.flatten`.

**Inherited, stated so nobody rediscovers it:** `resolvingOverlaps` exempts residents with
`takeGroupID != nil` (`ProjectStore.swift:4287`), so a mover landing on a track that HAS take groups
**silently stacks over the comp clips** rather than trimming them. That is `duplicateClip`'s
documented behaviour (`ProjectStore.swift:4128-4130` — "Take members on the target track are exempt;
they intentionally stack") inherited verbatim. It is pinned by a test (§12 leg 8) so it reads as a
decision rather than a surprise.

### 3.6 The core, in order

```
0  destination pre-resolve  — .toTrack ONLY: resolve toTrackId → index or throw trackNotFound.
                              Runs BEFORE the empty-ids check (see §3.7).
0b unique                   — seen/insert filter; .byTracks + empty ids → no-op result, no edit.
1  locate + comp guard      — locateClip(id) or throw clipNotFound; requireNotCompMember. NO MUTATION.
2a vertical resolve         — .byTracks: clampedTrackDelta(...) → (effectiveTrackDelta, clampedTracks);
                              destination[i] = source[i] + effectiveTrackDelta.
                              .toTrack: destination[i] = the resolved index for all i.
2b kind check               — for each mover with destination != source, in (sourceTrack, sourceClip)
                              order: guard tracks[dest].canHold(clip) else throw
                              (clip.isMIDI ? .midiClipsRequireInstrumentTrack : .trackKindUnsupported)
                              (tracks[dest].kind). FIRST failure wins, deterministically. NO MUTATION.
2c horizontal clamp         — clampedGroupBeatDelta(requested: delta, minStart:) → (effectiveBeats,
                              clamped). minStart is the LEFTMOST mover's start across ALL tracks.
2d nothing-changes return   — if no mover changes track AND effectiveBeats == 0: return the unchanged
                              clips with landings from==to. BEFORE performEdit, so no journal entry.
3  performEdit { … }        — 3a VACATE all crossing movers; 3b per destination: place, then one
                              resolvingOverlaps pass per landing mover; tracks = next;
                              engine?.tracksDidChange(tracks).
4  aggregate                — de-dup trimmed/removed (a REMOVAL supersedes any earlier trim of the
                              same clip — moveClips' rule, ProjectStore.swift:4068-4075); rebuild
                              `clips` in the caller's unique id order from the final tracks.
```

**Step 2d is not an optimisation.** It is `moveClips`' rule (`ProjectStore.swift:3979-3983`) and it
is load-bearing for the same reason: running the overlap pass at a clip's CURRENT position would trim
a legitimately-overlapping neighbour (a sanctioned crossfade partner) for a gesture that moved
nothing — and a held ↓ at the bottom of the track list emits exactly that gesture, repeatedly.

### 3.7 Two small asymmetries, decided

* **`.toTrack` validates its destination even when `ids` is empty.** `moveClips(ids: [])` validates
  nothing today because there is nothing to validate; here there is, and an agent that typo'd a track
  id must learn immediately rather than get a silent success. `.byTracks` with empty ids stays a pure
  no-op (an `Int` cannot be invalid).
* **Duplicate ids collapse; an unknown id throws `clipNotFound`** — the `removeClips` / `moveClips`
  contract, unchanged.

---

## §4 Q4 — ENGINE SAFETY AND THE RENDER THREAD

### 4.1 The decision

**One `engine?.tracksDidChange(tracks)` at the end of the single `performEdit` is sufficient and
correct. No `transportBusy` refusal. Safe mid-playback and mid-record.**

### 4.2 Why the render thread cannot observe a torn state

Three independent reasons, in increasing order of strength:

1. **The render thread never reads `[Track]`.** `tracks` is a stored property on the `@MainActor`
   `ProjectStore`. The engine's copy is `lastTracks` (`AudioEngine.swift:1014`), written on the main
   actor; the render thread reads the reconciled graph's player nodes and schedules, never the model.
   `AudioEngineProtocol` (`Sources/DAWCore/EngineProtocol.swift:355`) is the whole seam.
2. **The engine is told exactly once, with a value that is already final.** `tracksDidChange` is
   called after `tracks = next`, so `reconcile` sees a project in which every mover is on exactly one
   track. There is no window in which it could see a clip twice or not at all.
3. **The two-phase build makes the window structurally unreachable**, not merely unused: all
   mutation happens on the local `next`, which no observer holds a reference to. A future maintainer
   who adds an engine hook inside the edit body cannot create the torn state by accident.

Nothing on this path allocates, locks, or blocks on the render thread. The whole verb is main-actor
value manipulation; the only engine work is the existing `tracksDidChange` intent.

### 4.3 What the engine actually does with it, and the one thing to know

`tracksDidChange` → `withGuardedEngineIntent("track reconcile")` → `tracksDidChangeBody`
(`AudioEngine.swift:1009-1071`): AU instrument/effect sync, stretch-render sync,
`graph.reconcile(tracks:)`, `applyParameters`, MIDI-thru fanout, and then:

```swift
if changed, isRunning, let anchor = currentAnchor {
    restart(fromBeat: derivedBeats(), tempoMap: anchor.tempoMap, cause: .continuation)
}
```

A cross-track move flips `changed` (players appear on the destination strip and disappear from the
source), so **mid-playback it produces the same player-only continuation restart that every clip edit
already produces** — the path `AudioEngine.swift:1068-1069`'s own comment names ("any piano-roll note
edit or clip move flips `changed`"). It is heavier than a `startBeat` shift in reconcile work, but it
is not a new *kind* of event: reconcile already handles "clip left this track" (`clip.remove`) and
"clip arrived on this track" (`clip.add`, `clip.duplicate`), and this is exactly those two, in one
pass, with `needsEngineRebuild` untouched (no routing announce is involved).

### 4.4 Why NOT `transportBusy`

`insertBars` / `deleteBars` refuse **only while RECORDING** (`ProjectStore.swift:4350-4352`,
`guard !transport.isRecording`), and the reason is specific and does not transfer: those verbs
**re-anchor the TIMELINE** — the tempo map, the meter map, the loop region and every beat position
move underneath a rolling capture whose write position is expressed in that same beat space. A
cross-track move moves clips; the timeline, the maps and the record target track are all untouched.

`moveClip`, `moveClips` and `duplicateClip` have no transport guard, and adding one here would make
the arrow keys and every agent move fail during playback for no mechanism. **Decision: no guard.**
The alternative was considered and rejected on exactly that asymmetry.

### 4.5 ⚠️ This verb INHERITS m23-bv's open product question — do not close it by the back door

A MIDI clip crossing tracks mid-playback triggers `restart(cause: .continuation)`, and per m23-bp
`RescheduleCause.continuation` **chases held notes** (`PlaybackGraph.scheduleAll` reads
`chasesHeldNotes`). So moving a sustained pad from one instrument track to another while rolling
raises exactly the *missing pad vs phantom attack* question m23-bv filed, plus the measured audio/MIDI
asymmetry — and **that ruling is pending the user's decision.**

**Instruction to the implementer and to the gate author: OBSERVE it, do not PIN it.** The staging gate
may record what happens (§13 leg H) as a printed observation; it must not assert a preferred answer.
A pinned assertion here would settle m23-bv silently, in a cycle that was never asked to.

---

## §5 Q5 — COMBINED MOVE: yes, and the price is two hoisted statics

### 5.1 The decision

**`byBeats: Double = 0` is a parameter of both public shapes from day one.** One gesture can move
down-and-right in a single undo step.

**Why now rather than later.** The overlap pass needs each mover's **landing window**
`[start, start + length)`. With no time delta that reads `start = clip.startBeat`; with one it reads
`start = clip.startBeat + effectiveBeats`. Adding the delta later re-opens the exact lines that
compute the overlap windows and the clamp — i.e. the change is not additive at the point where it is
riskiest. Adding it now costs one parameter and one already-written clamp formula.

**Rejected: vertical-only with a stated extension point.** Honest, smaller, and it fails the first
real consumer: the arrange cross-track DRAG moves diagonally by definition, and as two calls it costs
two undo steps (`performEdit` is not re-entrant — `moveClips`' own note at
`ProjectStore.swift:3969-3972`, measured in `removeClips`). Shipping a verb the next feature must
immediately widen is worse than widening it once, deliberately, with a test.

### 5.2 The one-home problem this creates, and the fix

Carrying `byBeats` means the new verb needs the beat-0 clamp and the per-mover overlap loop — both of
which `moveClips` already has inline. **Two implementations of either is the failure mode this
project kills.** Fix: hoist each to exactly one `static`, and have BOTH verbs call it.

```swift
/// The ONE home for the WHOLE-GROUP beat-0 clamp (hoisted out of moveClips at m23-aj).
/// `minStart` is the LEFTMOST mover's start. Never per clip — see ProjectStore.swift:3938-3946.
static func clampedGroupBeatDelta(requested: Double, minStart: Double)
    -> (effective: Double, clamped: Bool) {
    let effective = max(requested, -minStart)
    return (effective, effective != requested)
}

/// The ONE home for the GROUP overlap RECIPE (hoisted out of moveClips at m23-aj): the single
/// choke point `resolvingOverlaps` run ONCE PER MOVER over one track's array, feeding the
/// rebuilt array forward, in a caller-order-independent sort.
///
/// THIS IS NOT A SECOND OVERLAP POLICY. It decides nothing about what a trim does — that stays
/// entirely inside `resolveOverlap` / `resolvingOverlaps`. It decides only HOW MANY windows are
/// applied and IN WHAT ORDER, which is the part m23-g2 reasoned about
/// (ProjectStore.swift:3948-3967) and the part a cross-track verb must not re-reason about.
static func resolvingGroupOverlaps(
    in clips: [Clip],
    movers: [(id: UUID, start: Double, end: Double)],
    activeIDs: Set<UUID>,
    tempoMap: TempoMap
) -> (clips: [Clip], trimmedIDs: [UUID], removedIDs: [UUID]) {
    var out = clips
    var trimmed: [UUID] = []
    var removed: [UUID] = []
    let ordered = movers.sorted {
        $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
    }
    for m in ordered {
        let r = resolvingOverlaps(in: out, activeIDs: activeIDs,
                                  start: m.start, end: m.end, tempoMap: tempoMap)
        out = r.clips
        trimmed.append(contentsOf: r.trimmedIDs)
        removed.append(contentsOf: r.removedIDs)
    }
    return (out, trimmed, removed)
}
```

`activeIDs` is an explicit parameter precisely because the two callers mean different sets:
`moveClips` passes the track's own movers, the cross-track core passes **the movers landing on this
destination** (§3.3).

### 5.3 Should `moveClips(ids:byBeats:)` become a forwarder?

**Recommended: yes, after the statics land — but it is now a LOW-STAKES choice**, because the
one-home property is secured by §5.2 either way. The forwarder is a tidiness win, not a correctness
requirement.

If the implementer takes it, the equivalence is an explicit checklist to verify against the EXISTING
`moveClips` suite, not a claim to assert:

1. Label byte-exact at `count == 1` (`"Move Clip 'NAME'"`) — `moveClipsLabel` unchanged.
2. Coalescing key identical — `moveClipsKey(ids:)` unchanged.
3. Zero-delta early return happens **before** any mutation and records **no** journal entry.
4. Per-track pass order identical: destination indices sorted ascending (== source indices when
   `byTracks == 0`), movers sorted by `(landing start, id)`.
5. Same-track movers keep their array slot (§3.4a) — this is the clause that makes the equivalence
   true at all.
6. Aggregate de-dup identical: removal supersedes trim.
7. `ClipsMoveResult`'s public shape and its `clip.moveMany` wire response are **unchanged**.

> ⚠️ **HARD STOP.** If any existing `moveClips` test changes behaviour, **stop and report**. Do not
> adjust the test. The forwarder is optional; the shipped verb's behaviour is not.

---

## §6 Q6 — WHAT THE RESULT REPORTS

```swift
/// One mover's VERTICAL outcome (m23-aj): which track it left, which it landed on. Reported
/// PER CLIP because a `byTracks` group spanning several tracks lands on several tracks —
/// a single `toTrackId` in the result would be a lie for exactly the case the item exists for.
public struct ClipLanding: Sendable, Equatable {
    public var clipID: UUID
    public var fromTrackID: UUID
    public var toTrackID: UUID
    public init(clipID: UUID, fromTrackID: UUID, toTrackID: UUID)
}

/// Outcome of the cross-track group move (m23-aj) — the vertical twin of `ClipsMoveResult`.
public struct ClipsTrackMoveResult: Sendable, Equatable {
    /// The moved clips in FINAL geometry, in the caller's unique id order.
    public var clips: [Clip]
    /// Every mover's from/to track, INCLUDING movers whose track did not change (from == to).
    /// Reporting the no-ops too is the honest shape: a consumer filters, it never has to infer.
    public var landings: [ClipLanding]
    /// Non-nil ONLY for the `byTracks` shape — a destination-shaped move has no delta, and a
    /// synthesised one would be a fiction for a group that collapsed from several tracks.
    public var requestedTrackDelta: Int?
    public var effectiveTrackDelta: Int?
    /// The vertical WHOLE-GROUP clamp engaged (top/bottom of the track list). Always false for
    /// the `toTrack` shape.
    public var clampedTracks: Bool
    /// The horizontal triple, identical in meaning to `ClipsMoveResult`'s.
    public var requestedDeltaBeats: Double
    public var effectiveDeltaBeats: Double
    public var clamped: Bool
    /// Residents the overlap policy edited ON THE DESTINATION TRACKS, aggregated across every
    /// mover's pass and de-duplicated; a removal supersedes an earlier trim of the same clip.
    public var trimmedClipIDs: [UUID]
    public var removedClipIDs: [UUID]
}
```

**Why `landings` and not a single `toTrackID`.** The item's headline case is a group spanning two
tracks moving down one. It lands on two tracks. Per-clip is the only shape that can report it, and it
is also what lets the gate assert **relative offsets intact in BOTH axes from the result alone**,
without re-deriving positions from a snapshot.

**Why there is no `skipped` field.** There is no skipping (§2.1.4). The absence is a positive
statement of the policy, and a `skipped: []` that is always empty would invite a future
implementation to fill it.

**Why `requestedTrackDelta` / `effectiveTrackDelta` are `Int?` rather than always-present.** The
`toTrack` shape genuinely has no delta. Emitting `0` would be indistinguishable from "the clamp
reduced the request to nothing", which is the one vertical fact a caller most needs to tell apart.

**Why a NEW type rather than fields on `ClipsMoveResult`.** `ClipsMoveResult` is the shipped
`clip.moveMany` response shape; widening it changes a live wire surface's payload for a command that
did not change. Additive-only means additive here too.

---

## §7 Undo label, coalescing key, and what folds into what

### 7.1 The label describes WHAT HAPPENED, not what was requested

```swift
/// The undo label a cross-track move journals (m23-aj). `destinationName` is non-nil ONLY when
/// every mover landed on the SAME track — a fact about the RESULT, so a `byTracks` group that
/// happened to collapse reads the same as a `toTrack` one.
static func moveClipsAcrossLabel(count: Int, singleName: String,
                                 destinationName: String?) -> String
```

| Case | Label |
|---|---|
| No mover changed track | `moveClipsLabel(count:singleName:)` **verbatim** |
| `count == 1`, crossed | `Move Clip 'NAME' to 'TRACK'` |
| `count > 1`, crossed, one common destination | `Move N Clips to 'TRACK'` |
| `count > 1`, crossed, several destinations | `Move N Clips Across Tracks` |

The first row is the `moveClipsLabel` byte-exactness argument one level up
(`ProjectStore.swift:3894-3904`): a cross-track verb that did not actually cross must read in the
Edit menu exactly like the horizontal one, or the menu text would depend on which API the caller
reached for. The others are countable and distinct, so a gate — and the user — can tell one atomic
cross-track move from a loop of single moves by the label alone.

### 7.2 The coalescing key is `moveClipsKey(ids:)`, UNCHANGED

**Decision: reuse it as-is.** It is already selection-stable (the sorted id list), so a burst of ↓
presses on an unchanged selection folds to ONE journal entry, which is the whole reason m23-x did not
need a new key.

**Consequence, measured, accepted.** Because the key does not encode the axis, a → followed by a ↓ on
the same selection inside `UndoJournal.coalescingWindow` (800 ms) folds into the SAME entry — and
`UndoJournal.recordEdit` (`Sources/DAWCore/UndoJournal.swift:130-137`) **keeps the FIRST entry's
label** on a merge. So a diagonal walk can read `Move 3 Clips` in the Edit menu even though it also
crossed tracks.

**Rejected: an axis-suffixed key** (`clip.moveMany:…:v`). It would keep the label honest at the cost
of making a diagonal keyboard walk cost TWO undo steps — which is the defect the coalescing exists to
prevent, traded for a cosmetic one. One gesture, one undo, wins.

---

## §8 Errors — every case, and which `ProjectError` it throws

| Condition | Error | Where it is decided |
|---|---|---|
| `ids` contains an unknown clip id | `.clipNotFound(UUID)` | phase 1 |
| any id is a take/comp member | `.clipInTakeGroup(String)` (the group NAME) | phase 1, `requireNotCompMember` |
| `.toTrack` names an unknown track | `.trackNotFound(UUID)` | phase 0, **even when `ids` is empty** |
| a MIDI clip lands on a non-instrument track (incl. a bus) | `.midiClipsRequireInstrumentTrack(TrackKind)` | phase 2b |
| an audio clip lands on a non-audio track (incl. a bus) | `.trackKindUnsupported(TrackKind)` | phase 2b |
| `byTracks` runs off the top/bottom | **no error** — whole-group clamp, `clampedTracks: true` | phase 2a |
| `byBeats` would carry the group past beat 0 | **no error** — whole-group clamp, `clamped: true` | phase 2c |
| nothing would change | **no error, no journal entry** | phase 2d |
| transport is playing or recording | **no error** — there is no transport guard (§4.4) | — |

Every error is thrown **before any mutation**, so a refusal leaves the project byte-identical.

> ⚠️ **AMENDED BY §18.** This table is INCOMPLETE as written: it is missing the mover-vs-mover
> collision the collapse path manufactures, which **does** add a `ProjectError` case
> (`.clipsWouldOverlapOnDestination`) and **does** need a new `LocalizedError` string. The sentence
> below stays true of the two KIND refusals — it was a finding about them, never a promise that this
> verb would need no error of its own. **Read §18 before implementing this table.**

No new `ProjectError` case is needed **for the kind refusals**: they are the exact cases
`duplicateClip` throws
(`ProjectStore.swift:4155-4164`), which keeps one refusal vocabulary across every cross-track
placement and means the control-protocol `LocalizedError` mapping needs no change.

**Noted, not fixed:** `midiClipsRequireInstrumentTrack` / `trackKindUnsupported` carry a `TrackKind`,
not a track NAME, so the message says "track kind 'bus' cannot hold…" rather than naming the track.
Reusing the exact shipped errors is worth more than a better message here; the message text is
contract (`MediaImporting.swift:205-206, 269-271`) and surfaced verbatim by the control protocol and
MCP. If a named variant is ever wanted it is an additive case, filed separately.

---

## §9 The wire

### 9.1 `clip.moveManyByTracks`

```jsonc
// request
{"command":"clip.moveManyByTracks",
 "params":{"ids":["<clip-uuid>", "…"], "byTracks":-1, "byBeats":0}}

// response
{"requestedTrackDelta":-1, "effectiveTrackDelta":-1, "clampedTracks":false,
 "requestedDeltaBeats":0, "effectiveDeltaBeats":0, "clamped":false,
 "landings":[{"clipId":"…","fromTrackId":"…","toTrackId":"…"}],
 "trimmedClipIDs":[], "removedClipIDs":[],
 "clips":[ /* JSONValue(encoding:) of each moved Clip */ ]}
```

* `ids` — required, array of uuid strings. May be empty (a no-op). Duplicates collapse.
  Parsed with the shared `parseClipIDs(_:field:requirement:)` (`Commands.swift:5953-5962`),
  `field: "ids"`, no minimum — the `clip.moveMany` contract.
* `byTracks` — **required, a whole number**, signed (negative = up / earlier in the track list,
  positive = down). Parse through the existing integer-parameter path (`arrange.insertBars`'s
  `atBar`/`count`, `track.reorder`'s `index`); a non-integral value is refused by that path, not by a
  new rule.
* `byBeats` — **optional, default 0**. Signed beat delta applied identically to every listed clip.
* `try params.rejectUnknownKeys(["ids", "byTracks", "byBeats"], verb: "clip.moveManyByTracks")`.

### 9.2 `clip.moveManyToTrack`

```jsonc
// request
{"command":"clip.moveManyToTrack",
 "params":{"ids":["<clip-uuid>", "…"], "toTrackId":"<track-uuid>", "byBeats":0}}

// response — IDENTICAL shape minus the two track-delta fields
{"clampedTracks":false,
 "requestedDeltaBeats":0, "effectiveDeltaBeats":0, "clamped":false,
 "landings":[{"clipId":"…","fromTrackId":"…","toTrackId":"…"}],
 "trimmedClipIDs":[], "removedClipIDs":[], "clips":[ … ]}
```

* `toTrackId` — required, uuid string; unknown → `trackNotFound`, even with `ids: []`.
* `try params.rejectUnknownKeys(["ids", "toTrackId", "byBeats"], verb: "clip.moveManyToTrack")`.

### 9.3 Response-key conventions (do not "fix" these)

`trimmedClipIDs` / `removedClipIDs` use capital `IDs` because that is what the live
`clip.moveMany` response already emits (`Commands.swift:4988-4989`) and renaming a live key is
forbidden. `landings` uses `clipId` / `fromTrackId` / `toTrackId` (lower-case `d`) because that is
the PARAMETER convention (`trackId`, `clipId`, `toTrackId`). The inconsistency is inherited and
deliberate; it is written down here so nobody harmonises it and breaks a live consumer.

Both commands are **APPENDED AT THE END** of `CommandRouter.allCommands`
(`Sources/DAWControl/Commands.swift:183`), following the additive-at-end convention stated at
`Commands.swift:384`.

### 9.4 MCP tools

`mcp-server/src/server.ts`, two `registerTool` calls appended in the clip section, each a thin
`bridge.send` forwarder in the `clip_move_many` style (`server.ts:7925-7968`):

```ts
registerTool("clip_move_many_by_tracks", { title: …, description: …, inputSchema: {
  ids: z.array(z.string().uuid()).describe(…),
  byTracks: z.number().int().describe(
    "Signed WHOLE number of tracks to move every listed clip by. Negative = up the track " +
    "list, positive = down. Every clip moves the SAME number of tracks, so a selection " +
    "spanning several tracks keeps its shape. Reduced (never per-clip) if it would carry the " +
    "group past the first or last track — check `clampedTracks`/`effectiveTrackDelta`."),
  byBeats: z.number().optional().describe(
    "Optional signed beat delta applied at the same time, so one call can move down AND " +
    "along in ONE undo step. Same whole-group beat-0 clamp as clip_move_many."),
}}, async ({ ids, byTracks, byBeats }) =>
  toToolResult(() => bridge.send("clip.moveManyByTracks", { ids, byTracks, byBeats })));

registerTool("clip_move_many_to_track", { title: …, description: …, inputSchema: {
  ids: …, toTrackId: z.string().uuid().describe(…), byBeats: z.number().optional().describe(…),
}}, async ({ ids, toTrackId, byBeats }) =>
  toToolResult(() => bridge.send("clip.moveManyToTrack", { ids, toTrackId, byBeats })));
```

**The descriptions must carry the three facts an agent cannot infer from the schema**, in this order
of importance:

1. **A move onto a track that cannot hold the clip REFUSES THE WHOLE CALL** — MIDI clips need an
   instrument track, audio clips need an audio track, and **bus tracks hold no clips at all**. Nothing
   is skipped and nothing is partially applied.
2. **Running off the top/bottom of the track list is CLAMPED, not refused** — read
   `effectiveTrackDelta` / `clampedTracks` rather than assuming `byTracks` fully applied (the
   `clip_move_many` `clamped` precedent, `server.ts:7936-7945`).
3. **`landings` is the per-clip truth** — a `by_tracks` move of a selection spanning several tracks
   lands on several tracks, so there is no single destination to report.

`clip_move_many_to_track`'s description must additionally say that it **COLLAPSES** a multi-track
selection onto one track (relative BEAT offsets survive, relative TRACK offsets are destroyed by
construction), and point at `clip_move_many_by_tracks` for the shape-preserving move. An agent
choosing the wrong one of these two is the most likely misuse, so each description names the other.

### 9.5 Copilot catalog

Two `CopilotTool` entries in `Sources/DAWControl/CopilotCatalog.swift`, immediately after the
`clip.moveMany` entry at `:616-625`. Update the section header comment at `:399` from
`// MARK: clip (14, m23-w added removeMany/moveMany)` to `// MARK: clip (16, m23-aj added
moveManyByTracks/moveManyToTrack)`. Schemas use `schemaObject([...], required: ["ids","byTracks"])`
and `required: ["ids","toTrackId"]` — `byBeats` is optional in both, so it is NOT in `required`.

---

## §10 The keyboard layer — ↑/↓ on the m23-x handler

### 10.1 A SEPARATE direction enum, and the grep that decided it

**Do NOT add `.up`/`.down` to `ArrangeNudgeDirection`.** Two measured reasons:

1. `ArrangeNudgeDirection` is `CaseIterable` and its `allCases` is iterated by a live test —
   `Tests/DAWAppKitTests/ArrangeNudgeTests.swift:204`, inside leg 7 (the ⌘/⌃ pass-through). Adding
   cases silently changes what that leg covers.
2. It carries `sign: Double` (`ArrangeNudge.swift:60-61`), and leg 8 is literally titled
   *"Direction is the ONLY source of sign"* (`ArrangeNudgeTests.swift:217-220`). A vertical case has
   no `Double` sign, and `ArrangeNudgeStep`'s other two fields (`magnitudeBeats`, `source`) are
   horizontal-grid concepts a lane move cannot answer either. A four-case enum would force three
   fields to lie.

```swift
// Sources/DAWAppKit/ArrangeNudge.swift

/// ↑/↓ (m23-aj). Separate from `ArrangeNudgeDirection` on purpose — see the design record.
public enum ArrangeVerticalNudgeDirection: String, Equatable, Sendable, CaseIterable {
    case up
    case down
    /// The ONE place a vertical arrow's sign is decided: −1 up, +1 down.
    public var trackSign: Int { self == .up ? -1 : 1 }
}

/// One vertical arrow press's answer. `fileprivate init` (the `ArrangeNudgeStep` model):
/// `ArrangeNudge.verticalStep` is the only producer, so a divergent step is unrepresentable.
public struct ArrangeVerticalNudgeStep: Equatable, Sendable {
    /// Always exactly ±1. There is no coarse or fine lane — a lane is a lane.
    public let trackDelta: Int
    public let direction: ArrangeVerticalNudgeDirection
    fileprivate init(trackDelta: Int, direction: ArrangeVerticalNudgeDirection)
}

extension ArrangeNudge {
    /// How far one vertical arrow press moves the arrange selection, or nil when the key is
    /// not ours and must PASS THROUGH untouched.
    public static func verticalStep(direction: ArrangeVerticalNudgeDirection,
                                    modifiers: TransportKeyModifiers) -> ArrangeVerticalNudgeStep?
}
```

### 10.2 Modifier policy: BARE PRESS ONLY

`guard modifiers.isEmpty else { return nil }`.

* **⌘ / ⌃ pass through** for the same reason as ←/→ (`ArrangeNudge.swift:134-140`): ⌘↑/⌘↓ are the
  system's document-start/end bindings and ⌃↑/⌃↓ are Mission Control.
* **⇧ and ⌥ ALSO pass through, and this is the decision.** They are RESERVED. ⇧↓ is the standard
  "extend the selection downward" and ⌥↓ is the standard "duplicate down" in this class of app; both
  are plausible next features on this exact surface (m23-y already shipped track selection). Adding
  meaning to a modifier later is additive; taking it back is a break.
* **Rejected: ignore ⇧/⌥ and nudge one lane anyway.** Cheaper today, and it spends two bindings we
  have concrete plans for on a behaviour nobody asked for.
* This is not the "dead key" hazard `gridOffFallbackBeats` guards against: a passed-through ⇧↓
  reaches `ContentView.swift:517`'s `ScrollView(.vertical)` and scrolls the lane list, which is a
  sensible answer to ⇧↓ and is visibly not-nothing.

There is no `ArrangeNudgeStepSource` analogue: with one rule there is nothing for the seam to
disambiguate. `trackDelta` is always ±1 and `direction` says which.

### 10.3 One handler, one guard stack

The guard stack is NOT duplicated — duplicating it is the m23-x/m23-ai failure mode. The handler
takes a sum type so the compiler enumerates the axes and the guards run exactly once:

```swift
// Sources/DAWApp/DAWProApp.swift
enum ArrangeNudgeAxisKey {
    case horizontal(ArrangeNudgeDirection)
    case vertical(ArrangeVerticalNudgeDirection)
}

@discardableResult
func handleArrangeNudgeKey(_ key: ArrangeNudgeAxisKey,
                           modifiers: TransportKeyModifiers) -> ArrangeNudgeOutcome
```

All six guards (`workspace`, `modal`, `textEditing`, `pianoRollNoteEdit`, `automationPointEdit`,
`emptySelection`) stay **exactly as shipped, in the same order, unchanged**. `DAWApp` has no test
target, so this signature change is only reachable through the `.onKeyPress` mount and the debug
seam, both of which change anyway.

**Both existing editor guards already cover ↑/↓ correctly, by their own stated rule, with no edit.**
Each asks "would the shielded surface itself have consumed this key". A piano roll holding a note
selection would consume ↑/↓ **more** strongly than ←/→ (↑/↓ is note transposition), and an automation
lane editor holding a breakpoint selection would consume ↑/↓ as value adjustment. The predicates
`openEditorClip != nil && pianoRollNoteSelection.hasSelection` and
`!automationPointSelection.lanesWithSelection.isEmpty` are correct for the vertical axis as written.
Per the brief, this design notes that implication and redesigns nothing.

### 10.4 Outcome additions

```swift
struct ArrangeNudgeOutcome {
    …existing fields unchanged…
    /// The vertical step the ONE producer chose (`ArrangeNudge.verticalStep`), echoed. Nil on
    /// the horizontal axis or when a guard refused before it was consulted.
    var trackStepDelta: Int?
    var requestedTrackDelta: Int = 0
    var effectiveTrackDelta: Int = 0
    /// The WHOLE-GROUP top/bottom clamp inside the store engaged.
    var clampedTracks: Bool = false
    var landings: [ClipLanding] = []

    var changed: Bool {
        effectiveDeltaBeats != 0 || effectiveTrackDelta != 0
            || !trimmedIDs.isEmpty || !removedIDs.isEmpty
    }
}
```

`changed` MUST gain the `effectiveTrackDelta != 0` term or the debug seam will skip its
`awaitClipLayoutRendered` wait for a move that did happen (`DAWProApp.swift:3839`), and every gate
leg would then read a pre-render snapshot.

### 10.5 The consume rule for the vertical axis

| Vertical outcome | `handled` | Why |
|---|---|---|
| moved | `true` | ours |
| boundary clamp reduced it to nothing | **`true`** | the beat-0-wall precedent, re-examined below |
| `.store` refusal (incompatible kind, comp member) | **`true`** — CHANGED for this axis only | below |
| `workspace` / `modal` / `textEditing` / `emptySelection` / `chord` | `false` | not ours |
| `pianoRollNoteEdit` / `automationPointEdit` | `true` | unchanged from m23-x / m23-ai |

**The re-examination the `ArrangeNudgeOutcome` doc demands** ("Any FOURTH such refusal gets the same
examination, not this precedent", `DAWProApp.swift:1030-1031`):

* **Ancestry, verified by reading:** `ArrangeDeleteKey` is mounted at `ContentView.swift:462-464`,
  wrapping `arrangeWorkspace(geo)`; the shared `ScrollView(.vertical)` that owns both the track rows
  and the lanes is inside it at `ContentView.swift:516-528`. So the vertical scroll view is a
  **descendant of the key mount**, which is the same structural relationship m23-x measured for the
  horizontal one.
* **Consequence:** an `.ignored` ↓ reaches that scroll view and slides the whole lane list under the
  user — the same class of surprise as m23-x's measured sideways slide (roll open, → moved the clip
  12 → 16), swapped for a different axis.
* ⚠️ **PREMISE NOT RE-MEASURED.** m23-x *measured* the horizontal slide. This design infers the
  vertical one from identical ancestry and has **not** observed it. Gate leg G (§13) exists to
  measure it. Until it runs, treat the vertical consume as reasoned, not proven — the
  `STILL NOT CLOSED, HONESTLY` convention in the same file.
* **Why `.store` changes only on this axis:** a vertical `.store` refusal is *guaranteed* to be
  reachable in ordinary use (a MIDI clip with an audio track below it), unlike the horizontal one
  (which needs a comp member). Leaving it `.ignored` would mean the single most common vertical
  refusal scrolls the arrangement. **The broader question — should ANY refusal past the guards
  consume? — is FILED, not silently widened.** The horizontal `.store` behaviour is untouched.

### 10.6 The mount and the debug seam

* `Sources/DAWApp/ContentView.swift`, `ArrangeDeleteKey` (`:1614-1629`): add
  `.onKeyPress(.upArrow)` / `.onKeyPress(.downArrow)` with `phases: [.down, .repeat]`, exactly like
  the existing ←/→ mount. Key repeat is welcome here for the same reason
  (`ArrangeNudge.swift:150-157`).
* `Sources/DAWApp/DAWProApp.swift:3809-3839`, the `debug.arrangeSelection {act:"nudge"}` seam:
  accept `"up"` / `"down"` in `direction`, and **replace the stale error text at `:3817-3818`**
  (`"…(there is no vertical nudge: see ArrangeNudge)"`) — that string is this item's own staleness
  marker. Echo `trackStepDelta`, `requestedTrackDelta`, `effectiveTrackDelta`, `clampedTracks`,
  `landings`. `workspaceMode` stays NOT forced to `.arrange` (`:3811-3814`) for the stated reason.
  `debug.*` is off both the `allCommands` and MCP surfaces, so this adds no wire count.
* Three doc blocks assert the thing this item removes and must be rewritten, not merely left:
  `ProjectStore.swift:3989-3995` ("HORIZONTAL ONLY"), `ArrangeNudge.swift:47-55`
  ("LEFT / RIGHT ONLY"), `DAWProApp.swift:1076-1078` ("↑/↓ ARE NOT HANDLED, AND THAT IS A DECISION").
  Each should now point at this record and at the new verb.

---

## §11 Implementation plan — ordered, each step independently testable

**File placement rule, non-obvious and load-bearing:** the new verb goes in
`Sources/DAWCore/ProjectStore.swift`, immediately after `moveClips`, **NOT** in a new
`ProjectStore+…swift` extension file. `locateClip(_ id:)` at `ProjectStore.swift:3514` is `private`,
i.e. file-scoped; the extension files each carry their OWN private re-declaration
(`ProjectStore+Quantize.swift:295`, `+Humanize.swift:122`, `+Transcription.swift:66`,
`+Analysis.swift:94` — 31 `locateClip(` sites across DAWCore, 21 of them in `ProjectStore.swift`).
A new file would silently need a 32nd, i.e. a second locator home. `requireNotCompMember`,
`resolvingOverlaps`, `moveClipsLabel` and `moveClipsKey` are all internal and would be reachable —
only the locator is not.

| # | Step | Files | Proof |
|---|---|---|---|
| 1 | `Track.canHoldAudioClips` + `Track.canHold(_:)`; rewrite `duplicateClip`'s inline `kind == .audio` (`:4161`) to use it | `Sources/DAWCore/Model.swift`, `Sources/DAWCore/ProjectStore.swift` | existing `duplicateClip` suite passes UNCHANGED (no behaviour change) + a small predicate suite |
| 2 | Hoist `clampedGroupBeatDelta` and `resolvingGroupOverlaps`; re-express `moveClips` in terms of them | `Sources/DAWCore/ProjectStore.swift` | existing `moveClips` suite passes UNCHANGED. **HARD STOP if any test changes behaviour** |
| 3 | `ClipTrackLanding`, `ClipLanding`, `ClipsTrackMoveResult`, `clampedTrackDelta` | `Sources/DAWCore/Model.swift` (types), `Sources/DAWCore/ProjectStore.swift` (clamp) | unit tests on the clamp: in-range, top, bottom, empty track list, `byTracks: 0` |
| 4 | The core + the two public overloads | `Sources/DAWCore/ProjectStore.swift` | §12 |
| 5 | New DAWCore suite `ClipCrossTrackMoveTests` | `Tests/DAWCoreTests/ClipCrossTrackMoveTests.swift` | §12 legs 1-14 |
| 6 | Two commands + `allCommands` entries (APPENDED AT THE END) | `Sources/DAWControl/Commands.swift` | §12 wire legs |
| 7 | Update **17 occurrences across 16 files** of `count == 169` → `171` | `Tests/DAWControlTests/*` | `./scripts/test.sh` |
| 8 | Two catalog entries + section header `clip (14 …)` → `clip (16 …)` at `:399` | `Sources/DAWControl/CopilotCatalog.swift` | catalog count test |
| 9 | Two MCP tools + `npm run build` | `mcp-server/src/server.ts` | `.claude/skills/mcp-verify` parity |
| 10 | `ArrangeVerticalNudgeDirection` / `…Step` / `ArrangeNudge.verticalStep`; rewrite the "LEFT / RIGHT ONLY" banner | `Sources/DAWAppKit/ArrangeNudge.swift` | `Tests/DAWAppKitTests/ArrangeVerticalNudgeTests.swift` |
| 11 | `ArrangeNudgeAxisKey`, handler signature, outcome fields, consume rule | `Sources/DAWApp/DAWProApp.swift` | gate only (`DAWApp` has no test target) |
| 12 | `.onKeyPress(.upArrow/.downArrow)` mount | `Sources/DAWApp/ContentView.swift` | gate |
| 13 | Debug seam accepts `up`/`down`; replace the stale error text at `:3817-3818`; echo the new fields | `Sources/DAWApp/DAWProApp.swift` | gate |
| 14 | Rewrite the three stale doc blocks (§10.6) | `ProjectStore.swift`, `ArrangeNudge.swift`, `DAWProApp.swift` | review |
| 15 | Staging gate + RED BASELINE + mutations | `scripts/gates/m23aj-cross-track-move.mjs` | §13 |
| 16 | ROADMAP tick, CHANGELOG, `docs/ARCHITECTURE.md` "Key future decisions" | `docs/` | close-out |

**Steps 1-2 are refactors with NO behaviour change and must be verified as such before step 4
starts.** Landing them together with the new verb would make a regression in either indistinguishable
from a bug in the new code.

---

## §12 Test strategy

### 12.1 `Tests/DAWCoreTests/ClipCrossTrackMoveTests.swift` — the domain suite

Fixture unless stated otherwise: tracks `[inst A, inst B, inst C, bus D, audio E]` (indices 0–4),
clips at known beats. **This fixture is load-bearing** — three consecutive instrument tracks give the
group moves room to land legally, the bus at index 3 is what leg 3 refuses on, and the audio track at
index 4 is what leg 6 clamps to before being kind-checked. Do not shorten it.

In this table “undo depth” means `store.undoHistory().undo.count` — the DAWCore-side quantity, the
idiom already used at `Tests/DAWCoreTests/TrackReorderTests.swift:100`. It is **not** `edit.history`,
which is the control-protocol surface and belongs in §12.2 / §13; a domain test must never reach for a
wire call.

⚠️ **§18 ADDS SEVEN MORE LEGS AND THEY ARE NOT IN THIS TABLE — see §18.8.** The collapse-collision
refusal was ruled after this table was written, and its legs are kept beside the ruling so the
argument and its proof stay adjacent. This table is the design's PLAN; it was never an index of the
shipped file (which carries a `3b` and its own probe numbering, and already has more than 14 legs).
When the two disagree, cite legs by DESCRIPTION, never by number.

| # | Leg | What it must assert (and what it must NOT settle for) |
|---|---|---|
| 1 | **The headline case.** Group spanning tracks 0+1 moves `byTracks: 1` | both land (0→1 inst B, 1→2 inst C — both legal); relative TRACK offset still 1; relative BEAT offsets unchanged; **undo depth is +1** — not "the clips moved", which cannot discriminate a loop of single moves (m23-g1's vacuity finding) |
| 2 | **Source/destination overlap.** Same group, `byTracks: 1` | `trimmedClipIDs` and `removedClipIDs` are BOTH empty — movers did not trim each other even though track 1 was simultaneously vacated and landed on. Both clips exist, once each |
| 3 | **All-or-nothing on kind.** 3-clip group on tracks 0+1+2, `byTracks: 1` — the last one lands on the bus at index 3 | throws `midiClipsRequireInstrumentTrack` / `trackKindUnsupported`; **compare the WHOLE `tracks` array to a pre-call copy** — not just the offending clip |
| 4 | **All-or-nothing on comp.** group containing one take member | throws `clipInTakeGroup`; whole-array comparison as in leg 3 |
| 5 | **Top clamp.** group already touching track 0, `byTracks: -1` | `effectiveTrackDelta == 0`, `clampedTracks == true`, NO throw, and **undo depth UNCHANGED** (a no-op must not consume an undo slot) |
| 6 | **Bottom clamp**, symmetric; plus a **MIDI** clip with `byTracks: 99` | the delta clamps to index 4 (`audio E`) FIRST and the kind check throws `midiClipsRequireInstrumentTrack` SECOND — exactly the §2.7 ordering. A leg that throws before clamping cannot tell the two orderings apart, so assert the error is the KIND one and not an out-of-range one |
| 7 | **Same overlap path, not a second one.** Build identical geometry twice: resolve it once via `moveClip` (same-track) and once via the cross-track verb landing on another track | the RESIDENT's resulting geometry is **identical** (start, length, `startOffsetSeconds`, surviving notes, fades, gain envelope, controller lanes). Asserting the rule twice is weaker than asserting the two paths agree |
| 8 | **Take members on the destination STACK** (inherited exemption, §3.5) | the comp clips are untouched; the mover overlaps them |
| 9 | **Combined move.** group on tracks 0+1, `byTracks: 1, byBeats: 4` | ONE journal entry; both axes applied; then the interaction: group at beat 0 with `byTracks: 1, byBeats: -8` → `clamped == true`, `clampedTracks == false`, beat offsets preserved, track offsets preserved |
| 10 | **`.toTrack` COLLAPSES.** group spanning tracks 0+1 → `inst C` (index 2) | every `landings[i].toTrackID` equal; relative BEAT offsets intact; ONE journal entry. ⚠️ **THIS LEG WAS GREEN WHILE §18's HOLE WAS OPEN** — its clips sit at beats 0 and **8**, DISJOINT, so it proved the collapse HAPPENED and never that the collapse was LEGAL (§18.1). **Keep the disjoint geometry**: under §18 it becomes the controlled SUCCESS half that the collision legs are read against |
| 11 | **`.toTrack` validates with empty ids.** `moveClips(ids: [], toTrackId: <unknown>)` | throws `trackNotFound` (§3.7) |
| 12 | **Array slots.** `.toTrack` where one mover is already on the destination | that clip keeps its index in `tracks[dt].clips`; crossing movers appear after it |
| 13 | **Forwarder equivalence** (only if step 2/§5.3's forwarder is taken) | `moveClips(ids:byBeats:)` and `moveClips(ids:byTracks:0, byBeats:)` produce identical `tracks`, identical journal label, identical key |
| 14 | **Mixed-kind group, controlled pair.** audio+MIDI over `[audio, inst, audio, inst]` | `byTracks: 2` succeeds (kinds line up); `byTracks: 1` throws (they do not). **Both halves** — the success half is what proves the failure half is about kinds and not about mixedness |

### 12.2 `Tests/DAWControlTests/ClipCrossTrackMoveCommandTests.swift`

Both commands: happy path with the full response shape; `rejectUnknownKeys`; every refusal mapping to
its `LocalizedError` text verbatim; `byBeats` omitted defaults to 0; `byTracks` required;
`CommandRouter.allCommands.count == 171`.

### 12.3 `Tests/DAWAppKitTests/ArrangeVerticalNudgeTests.swift`

`verticalStep` returns `trackDelta: ±1` on a bare press; returns **nil** for each of ⌘, ⌃, ⇧, ⌥ and
their combinations — each with the **controlled half** (strip the modifier and the same call answers),
or the leg proves nothing about the modifier. `up.trackSign == -1`, `down.trackSign == 1`, exact
opposites.

### 12.4 What Swift tests CANNOT prove here

`DAWApp` has no test target, so the handler, the guard stack on the vertical axis, the consume rule
and the debug seam are reachable **only** from the staging gate. Do not let a green suite stand in
for them.

---

## §13 The staging gate — `scripts/gates/m23aj-cross-track-move.mjs`

Staging port **17695**. **Never 17600 — that is the user's live app.** Kill the staging process
PIDFILE-EXACT; never `pkill`/`pgrep`. Read `scripts/gates/_staging.mjs` and the accumulated gate laws
before writing a line of it.

**RED BASELINE FIRST.** Run every leg against the unmodified tree and record which redden. A gate
authored against finished code and never seen failing is not a gate — the m20-d/e law. Record the
exact expected red SET, not a count (m20-e: a race makes totals a range; the set is stable).

**The gate's fixture, stated so nobody invents one.** Build the staging project with tracks
`[inst A, inst B, inst C, bus D, audio E]` in that order — the same shape as §12.1 and for the same
reason. ⚠️ The obvious three-track layout (`inst, inst, bus`) makes leg A's group land ON the bus and
reddens the headline leg for entirely the wrong reason. Track order is a fixture fact here, not
incidental setup: assert it after construction rather than assuming `track.add` ordering.

| Leg | What it proves |
|---|---|
| A | `clip.moveManyByTracks {byTracks: 1}` on the group spanning tracks 0+1: landings correct, relative offsets intact in both axes, `edit.history` depth **+1** |
| B | a landing on a bus refuses; `project.snapshot` is byte-identical before/after (no partial mutation) |
| C | destination residents: same geometry through `clip.move` on one track and through `clip.moveManyByTracks` onto another → identical resident geometry (the "not a second implementation" leg) |
| D | top clamp: `effectiveTrackDelta: 0`, `clampedTracks: true`, `edit.history` depth **unchanged** |
| E | `debug.arrangeSelection {act:"nudge", direction:"down"}` — a CONTROLLED PAIR per guard (guard inactive → nudges; guard active → refuses with the named `refusedBy`). A refusal-only leg passes against a dead handler |
| F | `{act:"nudge", direction:"down", repeat:5}` folds to **ONE** journal entry — assert the DEPTH |
| G | ⚠️ **the leg that measures §10.5's unproven premise.** Read the lanes' vertical scroll offset before and after a boundary-clamped ↓ and after a `.store`-refused ↓; both must leave it UNMOVED. If it moves, the consume rule is wrong or unreached, and that is the finding |
| H | **OBSERVATION ONLY, NOT A PIN (§4.5).** Move a MIDI clip between instrument tracks mid-playback over a held note; PRINT what happens. Do not assert a preferred outcome — m23-bv's ruling is the user's |
| I | `clip.moveManyToTrack` collapses a 2-track group onto one track in ONE step |

**Mutations to run** (each must redden a NAMED leg, and a leg that stays green under its own mutation
is a leg that measures nothing):

| Mutation | Expected red |
|---|---|
| M1 delete the phase-2b kind check | B |
| M2 replace the vertical clamp with a throw | D |
| M3 call `resolveOverlap` directly instead of `resolvingOverlaps` | C |
| M4 make phase 3 per-track (remove-then-add) instead of vacate-all-then-land-all | A, and probably C |
| M5 give the vertical move its own coalescing key | F |
| M6 return `.ignored` for the vertical `.store` refusal | G |
| M7 / M8 / M9 | **see §18.8 — they belong to the collision refusal and are NOT listed here** |

⚠️ **§18 ADDS GATE LEGS J / K / L AND MUTATIONS M7 / M8 / M9, and they are in §18.8, not in the two
tables above.** They also land with **m23-aj-2, not aj-1** — `clip.moveManyToTrack` is not on the wire
until then (`ProjectStore.swift:4303` carries the TODO). A gate author reading only the tables above
ships a gate with zero collision coverage and no way to notice it.

If a mutation reddens a leg you did NOT predict, that is a finding about the gate, not a pass —
write it down.

---

## §14 Corrections to the brief's measured facts

Four of the brief's facts needed adjusting. Three are small; the first is load-bearing.

1. ⚠️ **`moveClips` passes the PER-TRACK moving set as `activeIDs`, not "the FULL moving set".**
   `ProjectStore.swift:4042`. Equivalent there, ambiguous here, and copying the wrong reading is a
   bug. Full argument in §3.3.
2. **`reidentified` is not on this path and must not be used** — it mints a fresh id and drops
   `takeGroupID`. `Clip.controllerLanes` travel because the whole `Clip` VALUE moves. §3.4.
3. **`requireNotCompMember` throws `ProjectError.clipInTakeGroup(String)`** — a group NAME. The brief
   correctly identified the guard but not the error; the wire mapping needs the exact case. §8.
4. **`docs/ROADMAP.md:747` cites `moveClip` at `:3786`. It is at `:3867`** — the brief has it right,
   the roadmap line is stale. Worth fixing at close-out.

Everything else in the brief was verified correct against the tree, including: `moveClips` at `:4003`
and its `HORIZONTAL ONLY` comment at `:3989`; `duplicateClip` at `:4136` with its content-based type
check at `:4155-4164`; `resolvingOverlaps` at `:4278` with the take exemption at `:4287`;
`Clip` carrying no track id; `Track.takeGroups` at `Model.swift:1064`; `TrackKind` at `Model.swift:3`;
`TrackOrder` as the one home for track permutation; **31 `locateClip(` call sites** across DAWCore.

Two facts the brief did not state, both verified and both load-bearing:

* **`Track.clips` has no sortedness invariant** (the only sort is local, at
  `ProjectMIDIExportMapper.swift:687`), so appending crossing movers is safe. §3.4.
* **`TimelineLanesView` renders a row for EVERY track including buses** (`ContentView.swift:674-675`
  passes the whole array; the lanes' `ForEach`es have no kind filter). This is the fact that decides
  Q2. §2.2.

---

## §15 What this design deliberately does NOT decide

* **m23-bv's held-note product question.** Inherited, not answered. §4.5. The gate observes it.
* **Whether ANY refusal past the guards should consume the key.** Only the vertical `.store` refusal
  changes here; the horizontal one is untouched and the general question is filed.
* **The arrange cross-track DRAG.** This verb is its domain half, and `Track.canHold(_:)` is the
  predicate its drop affordance must consult so the cursor never advertises a landing the store
  refuses. ⚠️ **CORRECTED (§18).** This bullet used to say "`.toTrack` is exactly what a pointer
  drop resolves to". True for a SINGLE-clip drag, **wrong for a GROUP drag**: a multi-track selection
  dragged as one gesture must preserve its relative track offsets, so it derives **`byTracks`** from
  the ANCHOR clip's absolute landing — the same anchor-once discipline `ArrangeGroupDrag.plan`
  already applies to snapping (`ProjectStore.swift:3987-3994`). Sending a group drag down `.toTrack`
  would collapse the selection and run it straight into §18's refusal. The gesture, its snap
  interaction with `ArrangeDropSnap`, and its refusal affordance are a separate item.
* **A track-NAMED variant of the two kind errors.** Filed as an additive case, not taken here (§8).
* **Anything m23-x already settled**: step size as a delta, the selection-stable coalescing key, the
  whole-group beat-0 clamp's single home, the guard stack. Re-deriving them was the failure mode this
  design was briefed to avoid, and it did not.

---

## §16 Expected wire counts after this lands

Measured **2026-08-02**, on this tree, with the project's own recipes:

| Surface | Now | After | Recipe |
|---|---|---|---|
| `CommandRouter.allCommands` | **169** | **171** | pinned at 17 occurrences across 16 test files (`grep -rn "count == 169" Tests/`) |
| MCP tools | **172** | **174** | `server.registerTool(` = 37, minus 1 internal forwarder (`server.ts:104`), plus bare `^registerTool(` = 136. A naive `grep -c 'registerTool('` reads 174 now and 176 after — it counts the function DEFINITION too. `grep -c 'name: "'` and `^      name:` are BOTH broken here |
| Copilot catalog | **72** | **74** | `grep -c 'CopilotTool(' Sources/DAWControl/CopilotCatalog.swift` |
| Gate corpus | **55** non-harness `.mjs` | **56** | `find scripts/gates -maxdepth 1 -name '*.mjs'` = 57, minus `-name '_*.mjs'` = 2 harnesses. Re-measured for this document, not inherited |

**§18's ruling moves NONE of these four numbers, and that is worth stating rather than leaving to be
inferred from its absence here.** It adds a `ProjectError` case, which is not a wire surface: no
command, no MCP tool, no catalog entry, no new gate file (§18.8's legs J/K/L land inside
`m23aj-cross-track-move.mjs`, already counted in the row above). The one count it does move is the
DAWCore suite's test count, which is measured at implementation and never predicted here.

`./scripts/test.sh`, never bare `swift test`. **`./scripts/test.sh` EXITS 0 ON A FAILED RUN** — grep
`^✘`. Run the full suite backgrounded (~90 s).

---

## §17 Standing constraints this work touches

* Control port **17600 is the user's LIVE app** — never contacted. Staging is **17695**.
* Wire and MCP surfaces are **additive only**: nothing here renames or repurposes `clip.move`,
  `clip.moveMany`, `clip_move_many`, `ClipMoveResult` or `ClipsMoveResult`.
* Swift 6 strict concurrency. The verb is `@MainActor` (it is on `ProjectStore`); every new type is
  `Sendable`. **DAWCore stays UI-free and engine-free** — `ClipTrackLanding`, `ClipLanding`,
  `ClipsTrackMoveResult` and `Track.canHold(_:)` import nothing but Foundation.
* `git checkout` / `stash` / `restore` / `clean` are **forbidden in this tree**. Commits only on the
  user's word.
* **Full Xcode is NOT required** for any step of this item.

---

## §18 The collapse collision — a hole in this design, and the ruling

**Filed 2026-08-02, after m23-aj-1 landed green.** The implementation faithfully inherited a gap in
§0/Q1 that §12's original test table could not see. **This section is authoritative over §8's error
table and over §15's drag bullet**; both have been amended in place to point here.

### 18.1 The defect, as measured

`.toTrack` COLLAPSES a multi-track group onto one track — its defining property, stated in §0/Q1. Two
movers from DIFFERENT source tracks can therefore land on the SAME beats. Both are in `activeIDs`,
and the choke point exempts `activeIDs` members from being trimmed:

```swift
// ProjectStore.swift:4725, inside resolvingOverlaps
if activeIDs.contains(existing.id) || existing.takeGroupID != nil { rebuilt.append(existing); continue }
```

So they **silently stack**. Clip X at beat 0 on track A, clip Y at beat 0 on track B,
`moveClips(ids: [X, Y], toTrackId: C)` leaves two ORDINARY clips (`takeGroupID == nil`) occupying
`[0,4)` on track C at once. That is the no-silent-overlap invariant (m11-d, completed m13-b) failing
inside the very verb this design routes through the choke point to preserve it.

**Why the suite was green:** §12's collapse leg (leg 10) used clips at beats 0 and 8 — disjoint. The
hole was never in the window the tests looked through. Recorded because that is the reusable lesson,
not the bug: **a collapse leg whose members are disjoint cannot test collapse.**

### 18.2 The tree had already ruled on this, and I missed it

`moveClips`' own doc block states the invariant this verb breaks:

> "For movers that OVERLAP EACH OTHER, which **only sanctioned audio crossfade pairs (m11-d) can
> produce**, they are NOT [order-independent] … Sorting does not make that case principled, it makes
> it DETERMINISTIC and reproducible." — `ProjectStore.swift:4028-4032`

Two things follow, and together they decide the ruling:

1. **"Only sanctioned crossfade pairs can produce it" is a claim about the HORIZONTAL verb, and the
   collapse path falsifies it.** The hole is stated in the tree's own words; no new principle was
   needed to see it — only to notice the claim had acquired a new counter-example.
2. **The tree explicitly declines to call the landing order principled.** It is deterministic, and it
   says so in exactly those words. Anything built on that ordering inherits "reproducible but
   arbitrary."

### 18.3 The ruling — **(b), REFUSE, scoped to MANUFACTURED collisions**

> **A move is refused, whole and before any mutation, when two DISTINCT movers would occupy
> overlapping beat ranges on the SAME destination track AND that collision did not exist before the
> move.**

New error case, in the established style:

```swift
case clipsWouldOverlapOnDestination(firstID: UUID, firstName: String,
                                    secondID: UUID, secondName: String)

// MediaImporting.swift errorDescription — exact wording is contract (control protocol + MCP surface it verbatim)
return "clips '\(firstName)' (\(firstID.uuidString)) and '\(secondName)'"
     + " (\(secondID.uuidString)) would overlap on the destination track — moving several tracks'"
     + " clips onto one track needs them at different beats (move them one at a time, or use"
     + " clip.moveManyByTracks to keep them on separate tracks)"
```

⚠️ **IT CARRIES IDS AS WELL AS NAMES, AND THAT IS NOT DECORATION.** The obvious payload — two names,
following `clipInTakeGroup(String)` — is wrong HERE. A group name is a lookup key; **clip names are
not unique**, two takes are routinely both `Audio 1`, and this error fires precisely when two clips
sit at the same beats, which is exactly when duplicate names are most likely. `"clips 'Audio 1' and
'Audio 1' would overlap"` tells an agent nothing it can act on. `errorDescription` lives on the enum
and can reach no store, so a name it did not carry is a name it cannot render — the ids must be in
the payload. Precedent for printing a raw `uuidString` in contract text: `notABus`,
`automationLaneNotFound` (`MediaImporting.swift:208-211, 267`).

**The test is interval intersection, half-open, STRICT:**

```swift
a.start < b.end && b.start < a.end        // NOT <=
```

`[0,4)` and `[4,8)` **abut and must succeed.** An implementer reaching for `<=` refuses a legal
abutment and no other leg in the suite catches it. This matches `resolveOverlap`'s own half-open
window semantics.

**"Manufactured" is the PRINCIPLE; same-source-track is the MECHANICAL TEST.** A collision is
pre-existing iff the two movers came from the SAME source track — because every landing shape in this
design translates every mover by one uniform `byBeats`, so a same-source pair's relative geometry is
unchanged by the move: if it overlaps after, it overlapped before. Those are exactly the sanctioned
crossfade pairs of `:4028-4032`, and they are **GRANDFATHERED**. Write the principle into the code
comment, not just the shortcut — a future landing shape (e.g. a per-clip destination mapping) must
inherit *"refuse what the verb manufactured"*, not *"compare source track indices"*.

### 18.4 Two ways to get this wrong, both worth naming

**(i) Do NOT filter the check set to CROSSING movers.** Phase 2b's kind check iterates
`for i in checkOrder where crossing[i]`, and copying that filter here is the natural mistake and is
WRONG. Under `.toTrack` a mover ALREADY on the destination is non-crossing — it keeps its array slot
rather than being vacated and re-appended — but it is still in that destination's `activeIDs`, which
is built from `byDestination[dt]` and contains crossing and non-crossing movers alike. So clip X
already on track C at beat 0, plus clip Y on track B at beat 0, `toTrackId: C`, reproduces the defect
**without X ever crossing**. The check runs over **ALL movers assigned to a destination.**

**(ii) Do NOT drop the grandfather clause.** ⚠️ **This is the one place where the obvious rule
over-refuses, and it bites `byTracks`, not `.toTrack`.** The rule *"no two distinct movers on a
destination may overlap"*, stated without the source-track qualifier, refuses a sanctioned crossfade
pair — and a same-source overlapping pair lands on ONE destination under **both** shapes, so that
formulation would make the ↑/↓ keyboard nudge (m23-aj-3, which rides `byTracks`) refuse to move a
crossfaded pair at all. That is a straight regression against a configuration the tree calls legal
today. The source-track qualifier is what prevents it, and it is load-bearing on the `byTracks` path
specifically.

### 18.5 Where it goes: phase 2b′, run UNCONDITIONALLY

Insert **phase 2b′**, **after the kind check (2b) and BEFORE the beat clamp (2c)** — inside the
validate-first block, so it throws before any mutation and the project stays byte-identical.

**The check does not need the beat delta at all**, and this was worth verifying rather than assuming.
For movers i and j translated by a common `d`:

```
[s_i + d, s_i + d + L_i)  ∩  [s_j + d, s_j + d + L_j)  ≠  ∅
   ⟺   s_i < s_j + L_j  ∧  s_j < s_i + L_i
```

`d` cancels. Mover-on-mover collision is **invariant under the common horizontal delta**, clamped or
not, because the translation is rigid and the whole-group beat-0 clamp is likewise common to every
mover. Lengths are unchanged by a move. So the check depends only on the destination assignment plus
each mover's **pre-move `startBeat`/`lengthBeats`** — it can and should sit before 2c, where it fails
earlier and needs less state.

**Run it on BOTH landing shapes, not only on `.toTrack`.** Under `.byTracks` it provably never fires,
for two independent structural reasons — record both, because each kills a different failure mode:

1. **Injectivity.** `destination = source + effectiveTrackDelta` with a **single whole-group `Int`**
   (the vertical clamp is whole-group too, §2) is injective on source track index. Two movers share a
   destination **iff** they shared a source — and same-source pairs are grandfathered (§18.3). So no
   pair can both co-land and be manufactured.
2. **No crossing/non-crossing asymmetry.** Under a rigid common track delta a mover is non-crossing
   only when the delta is 0, and the delta is common — so either EVERY mover crosses or NONE does.
   The §18.4(i) case, "one mover sits still on the destination while another lands on it," is
   structurally **unrepresentable** under `byTracks`. It is representable under `.toTrack`.

**Those two paragraphs are why the guard is unconditional, and they must stay in the code comment.**
A later reader who finds a guard that never fires under `byTracks` and cannot reconstruct these
arguments will delete it as dead code. One unconditional phase enforcing the invariant beats a
conditional one plus a proof obligation on every future reader — the same reasoning as the "ONE home"
registry.

**Take/comp members change nothing:** `requireNotCompMember` already refuses them in phase 1, so no
mover reaching 2b′ has `takeGroupID != nil`. Do not re-exempt them here — a second take exemption
would be a second policy home.

**Zero-length / sub-`minClipLengthBeats` movers need no special handling — but NOT for the reason
this section first gave.** ⚠️ **CORRECTED, because an implementer who checks the old claim will find
it false and may then add exactly the special case it was arguing against.** It is *not* true that a
degenerate `[a,a)` interval "intersects nothing" under the strict test: take `a = [3,3)` and
`b = [0,10)` — `3 < 10 ∧ 0 < 3`, so the test says they DO intersect. A zero-length mover sitting
strictly INSIDE another mover's window is flagged. **That is the right answer**, and it is right for
the reason the conclusion always rested on: the predicate IS `resolveOverlap`'s own disjointness test
(`ProjectStore.swift:4686-4687`), so whatever it does with a degenerate interval it does CONSISTENTLY
with the invariant this check protects — a zero-length RESIDENT in that same position is found
non-disjoint and, being fully covered, REMOVED (`:4688-4689`). Add no special case.

Two supporting facts, measured: `Clip.init` floors length at `max(0, lengthBeats)`
(`Model.swift:643`), so zero-length clips ARE representable and this is not a hypothetical; and
`minClipLengthBeats` is a floor on **the result of a TRIM** (`ProjectStore.swift:4631`), while policy
(b) never trims — so it has no bearing on this path at all.

**WHICH pair the message names must be DETERMINISTIC, and this design already owns the order.** Visit
the movers in phase 2b's `checkOrder` — sorted by `(source track index, source clip index)`,
`ProjectStore.swift:4384-4388` — and report the FIRST colliding pair encountered while scanning it,
`first` being whichever of the two comes earlier in that order. Phase 2b's stated contract is "FIRST
failure wins, deterministically" and 2b' must not weaken it: a refusal that names a different pair
from run to run is one no test can pin and no agent can act on. **Do NOT reach for
`resolvingGroupOverlaps`' sort** (landing start, then `uuidString`) — that is precisely the ordering
§18.6(2) refuses to build anything user-visible on.

Cost is `O(k²)` within each destination-track group, `k` = movers landing there. `k` is a selection
size; this runs once per edit, on the main actor, never on the render thread.

### 18.6 The alternatives, and why they lose

**(a) / (c) — movers trim each other on the collapse path.** These are ONE policy: (c) is how you
would implement (a), by making each successive mover active only against those already landed.
**Rejected, on four grounds:**

1. **It decides "which of the user's own clips is destroyed" by UUID string.** The landing order is
   sort-by-start-then-id; at identical starts — precisely the collision case — the tiebreak is
   `uuidString <`. An agent asking "move these four takes to track C" gets one clip back, with the
   survivor chosen by a value no caller controls or can predict.
2. **It contradicts the design's own order-independence.** `resolvingGroupOverlaps` sorts precisely so
   "the result cannot depend on the caller's id order" (`ProjectStore.swift:3959-3963`), and `ids` is
   a SET (duplicates collapse). Trimming smuggles an ordering back in — one *worse* than caller order,
   because the caller cannot influence it. And per §18.2 the tree already declines to call that
   ordering principled; building clip destruction on it escalates an admittedly-arbitrary tiebreak
   from "which resident remnant survives" to "which of the user's clips survives."
3. **Resident-trim and mover-trim are not the same act.** Trimming a resident has a claimant and a
   yielder: the user said *this clip goes here*, and what was there yields. In a mover-vs-mover
   collision **there is no claimant** — both clips are equally "the thing the user is moving." Trim
   requires an asymmetry the user's intent does not contain.
4. **Fail-silent on an agent surface.** Under (a) the caller gets a SUCCESS carrying
   `removedClipIDs: [X]` and must notice its own move ate a clip. Under (b) it gets an actionable
   refusal it cannot miss. This is the same fail-loud discipline as the gate law that a leg staying
   green under its own mutation measures nothing.

The steelman for (a) — *"a user collapsing four takes onto one track at least gets something"* —
fails on its own terms: they get the UUID-highest take and lose three. That workflow wants a comp or
flatten verb, not a lossy move. If a deliberate "slam these down, I don't care what survives" mode is
ever wanted, it is an additive opt-in parameter, never the default.

**Clamping each collider onto the nearest free beat.** Rejected: it makes `.toTrack` silently not
honour the beats the caller asked for, inventing a horizontal move nobody requested, and it re-opens
the beat-0 clamp's single home (§5).

### 18.7 Blast radius

| Surface | Effect |
|---|---|
| `ClipsTrackMoveResult` | **UNCHANGED.** The refusal throws before any mutation, so nothing reaches the result type. No `collisions` field — its absence is the same positive statement as the missing `skipped` field (§0/Q6). |
| m23-aj-2 request/response JSON (§9) | **UNCHANGED.** Both shapes stand exactly as written. |
| §8 error table | **+1 row**: manufactured mover-vs-mover collision → `.clipsWouldOverlapOnDestination(firstID:firstName:secondID:secondName:)`, decided in phase 2b′. |
| `ProjectError` + `MediaImporting.swift` | **+1 case, +1 `errorDescription`**, additive. **The `LocalizedError` string IS required.** ✅ **VERIFIED, not assumed:** `ProjectError`'s own `errorDescription` switch (head at `MediaImporting.swift:201`) is the ONLY switch over its cases in the tree, and `DAWControl` surfaces the message generically (`Commands.swift:443-454` — the blanket `LocalizedError` arm at `:448`, whose comment reads "ProjectError and friends carry a client-readable message") rather than re-mapping cases — so there is no second, `default:`-shaped switch that would silently ship this refusal under a generic code. Exact wording becomes contract once it ships. |
| MCP `clip_move_many_to_track` description | Mention the refusal, so an agent learns the constraint from the tool list rather than by being refused. |
| m23-aj-3 (↑/↓ keyboard) | **UNAFFECTED** — but only because of the grandfather clause (§18.4(ii)). Without it this item would refuse crossfade-pair nudges. |
| Wire counts (§16) | **UNCHANGED.** No new command, no new tool, no new gate file. |

### 18.8 Test legs this adds

To `Tests/DAWCoreTests/ClipCrossTrackMoveTests.swift`. Keep the existing disjoint collapse leg
(leg 10) — it still proves collapse works.

⚠️ **§12's leg table (1–14) PREDATES the shipped suite, which already has at least 19 legs.** §12 is
the design's plan, not an index of the file. Do NOT renumber the file to match it; append, and cite
legs by NAME when it matters.

⚠️ **The tree currently holds a DELIBERATELY RED probe — leg 19 — that fails on exactly this defect.**
Under (b) it must be **rewritten**: it currently asserts the two clips do not overlap after the move;
it must instead assert the move **throws** `clipsWouldOverlapOnDestination` and that the whole
`tracks` array is unchanged. Expect to edit it, not to watch it go green.

| Leg | What it must assert |
|---|---|
| **Collision refuses** (rewritten leg 19) | X at beat 0 on A, Y at beat 0 on B, `toTrackId: C` → throws `clipsWouldOverlapOnDestination`; **compare the WHOLE `tracks` array against a pre-call copy**, not just the two clips |
| **Non-crossing collider** (§18.4(i)) | X ALREADY on C at beat 0, Y on B at beat 0, `toTrackId: C` → refuses. Without this leg an implementation that filters the check to crossing movers passes everything else |
| **Abutment succeeds** | X at `[0,4)` on A, Y at `[4,8)` on B, `toTrackId: C` → SUCCEEDS, both land intact. The `<` vs `<=` leg; nothing else catches it |
| **Grandfather** (§18.4(ii)) | a sanctioned crossfade pair kept WHOLE. ⚠️ **FIXTURE CORRECTION — as first written ("two overlapping AUDIO clips on source track A, collapsed onto C") this leg cannot be built on §12.1's `[inst A, inst B, inst C, bus D, audio E]`: A and C are INSTRUMENT tracks, so phase 2b refuses with `trackKindUnsupported` before 2b' is ever reached and the leg reddens for entirely the wrong reason.** Build it on the ONE audio track: audio `P [0,4)` and `Q [3,7)` on **track E (index 4)**, then `moveClips(ids: [P, Q], toTrackId: <E's id>, byBeats: 4)`. Both movers are NON-crossing, both land on E, so 2b' RUNS on them and the same-source qualifier is the only thing letting them through. **`byBeats: 4` is load-bearing** — it carries the call past phase 2d, so this is a real edit rather than a no-op return. Assert: both survive, `Q.startBeat - P.startBeat == 3` (rigid), `trimmedClipIDs` and `removedClipIDs` BOTH empty, undo depth **+1**. **Without this leg, (b) is indistinguishable from "refuse any mover overlap"**; it is what proves the refusal is about *manufactured* collisions |
| **Cross-source, non-colliding** | X at `[0,4)` on A, Y at `[8,12)` on B, `toTrackId: C` → succeeds. The controlled half of the collision leg: differing source tracks ALONE must not refuse |
| **`byTracks` never fires it** | the collision leg's geometry moved with `byTracks: 1` → succeeds, movers land on two different tracks. Pins §18.5's injectivity claim as a MEASUREMENT, not a comment |
| **`byTracks` grandfather** | the same crossfade pair carried DOWN a track. ⚠️ **Needs a LEG-LOCAL fixture — `[audio, audio]`, following §12 leg 14's precedent of a leg that builds its own track list: the shared fixture has exactly ONE audio track, so `byTracks: +1` from it clamps to a no-op and `byTracks: -1` lands on the bus.** Audio `P [0,4)` + `Q [3,7)` on audio track 0, `byTracks: 1` → **succeeds**, both cross to track 1, still overlapping, nothing trimmed, undo depth **+1**. This is the leg that would have caught §18.4(ii). (The clamped variant on the shared fixture does still redden under M8 — 2b' runs BEFORE phase 2d — but it proves nothing about a real cross-track carry, which is the case aj-3's ↑/↓ nudge actually emits. Build the real one.) |

**Gate (§13) — and mind the DEPENDENCY.** None of §13 runs during the m23-aj-1 fix:
`clip.moveManyToTrack` is not wired until **m23-aj-2** (`ProjectStore.swift:4303` carries the TODO).
Land the suite legs above with the fix; land these gate legs with aj-2.

⚠️ **Three gate legs, not one.** §13's own convention is that every mutation reddens a NAMED GATE
leg. A single "colliding movers refuse" leg gives M7 and M9 nothing to redden — it still refuses
under `<=`, and it still refuses when the check is wrongly filtered to crossing movers. Labelling
them against §18.8's DAWCore legs would reintroduce the exact trap §13 exists to prevent: *a leg that
stays green under its own mutation measures nothing.*

| Gate leg | What it proves | Mutation that must redden it |
|---|---|---|
| J | two cross-source colliding movers refuse; `project.snapshot` byte-identical before/after | — (the headline refusal) |
| K | abutting `[0,4)` + `[4,8)` from two source tracks COLLAPSE successfully | **M7** — relax the interval test to `<=` |
| L | a mover ALREADY on the destination collides with an arriving one and refuses | **M9** — filter the check to crossing movers |

**M8** (drop the same-source grandfather) reddens **§18.8's two grandfather legs** in the Swift
suite; it has no gate target and does not need one, because a crossfade pair is domain geometry the
suite can build directly. Say so in the gate file rather than leaving M8 looking unpaired.

### 18.9 Credit and one correction to the intake

The coordinator's scope reasoning was correct on both counts it raised: `.byTracks` cannot converge,
and the collision is invariant under the common beat delta (their own correction to their first
placement argument — the algebra is reproduced in §18.5 and checks out). Their third refinement,
that the check must cover non-crossing movers, is §18.4(i) and is a genuine defect I had not written
down.

**One correction back.** Their closing formulation — *"for each destination track, over ALL movers
assigned to it, no two DISTINCT movers may have overlapping `[start, end)` intervals"* — drops the
source-track qualifier and therefore **over-refuses**: it rejects sanctioned crossfade pairs, and
because a same-source overlapping pair co-lands under `byTracks` as well, it would break the ↑/↓
nudge, not just the collapse path. §18.4(ii) records this. The qualifier is not a refinement of the
rule; it is the rule.
