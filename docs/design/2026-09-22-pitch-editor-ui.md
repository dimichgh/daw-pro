# m23-ap Phase 2 — The Pitch Editor UI

**Design doc. Written 2026-09-22 by `daw-architect`, before implementation, because
`docs/research/m23-q-pitch-correction-design.md` §11.2 requires one.**

Status: **DECIDED for everything that does not depend on the TUNE X video.
The INTERACTION MODEL (§7) is deliberately OPEN and must not be invented.**

Route for the increments this doc specifies: `swift-app-engineer` (surface),
`daw-architect` re-review before Increment C is picked up.

---

## 0. What this document decides, and the one thing it does not

The user asked, verbatim:

> **"And we also need UI to allow human edit them as well or use preset actions"**

and stated the priority, verbatim:

> **"primary focus on vocal editing with wave and auto-tune and note editor"**

The reference is **SLIMZ TUNE X** — a waveform with detected notes drawn as blobs
over it, a piano keyboard down the left edge as a pitch ruler, and a pitch contour
line through each note.

**This doc decides:** where the surface lives, what it is made of, what its
headless model owns, what ships first, where the four preset actions live, how a
drag coalesces into one undo step, what the command surface is, and what is out of
scope.

**This doc deliberately does NOT decide the interaction model** — what a drag does,
what the tools are, what a double-click does, whether there is multi-select, how
split/merge are gestured. ⚠️ **The user offered a video of TUNE X in action and has
not sent it yet. That video is the spec for the interaction.** §7 is a hole with a
shape, not a proposal. Filling it from imagination and presenting it as settled is
the failure this doc exists to avoid, and it would be the more expensive mistake
because the interaction is the half a user can see.

Everything in §§1–6 and §§8–13 is buildable and testable without the video.

---

## 1. The §11.2 requirement, verbatim

⚠️ **CORRECTION TO THE BRIEF I WAS GIVEN: the m23-q design doc is not in
`docs/design/`.** It is at
**`/Users/dsemenov/Views/daw-pro/docs/research/m23-q-pitch-correction-design.md`**
(922 lines). `docs/design/` contains seven m39-era docs and nothing for m23-q. The
requirement reads, at lines 804–810 of that file, in full:

> **Phase 2 — The note editor. `5–7 weeks` / 5–6 sub-items. The Melodyne-class feature.**
>
> Segmentation into notes; a blob/piano-roll-hybrid editor; per-note drag for pitch, drift and vibrato; split/merge; scale snap; selection and multi-edit; audition.
>
> *Ships:* the actual ask.
> *Basis:* segmentation is 1.5–2 weeks (three input signals to fuse, and F1 says the failure is here, not in detection). **The editor UI is 3–4 weeks and is the single largest chunk in the milestone, because it has no substrate** — the comparable in-repo items are the m22-b EQ curve editor and the m23-d note-audition surface, each of which needed a full design doc of its own before implementation. Wire, undo keys and tests are ~1 week.
> *Risk:* UI scope creep. Mitigation: **phase 2 should get its own design doc before implementation**, exactly as m22-b and note-audition did. Treat the number as covering an editor with the operations listed and nothing more.

And the same file restates it as an inherited condition (§12, "Conditions the
implementing milestone inherits", item 3):

> 3. The phase-2 editor gets **its own design doc** before implementation (the m22-b / note-audition precedent).

Two further conditions from that list bind this doc directly:

> 4. The editor addresses clips **by id** so take lanes work from day one (§7.5, F11).
> 5. **No pitch DSP on the render thread, ever** (§7.6, F12).

And one entry in "Deliberately left unresolved" is precisely the hole this doc
inherits and does not close:

> - **The phase-2 editor's interaction design.** Out of scope for a GO/NO-GO; it needs its own doc.

**What §11.2 obliges, read strictly:** the number covers *"an editor with the
operations listed and nothing more"* — segmentation, per-note drag for pitch/drift/
vibrato, split/merge, scale snap, selection and multi-edit, audition. Anything not
on that list is scope creep by the design doc's own definition, and §10 below says
so by name.

---

## 2. Findings that change the brief — verified, each with its citation

Every claim in the task I was given was checked. Two were wrong and four things
nobody mentioned turn out to be load-bearing.

### 2.1 ⚠️ THE READ-ONLY VIEW IS THE HALF THE USER CAN HAVE SOONEST — AND THIS FINDING ROTTED WITHIN THE HOUR

**Read §4 before acting on anything in this subsection.** It is left standing as
written because *how* it moved is the more useful lesson.

When I began this doc, three facts said a preset button would store an edit set
that made no sound:

1. Nothing wrote `Clip.pitchEdits`.
2. Nothing rendered it — `Clip.isStretchIdentity` was unchanged and the field's own
   comment read *"⚠️ **NOTHING RENDERS THIS YET.**"*
3. E2 (`m23-ap-5`), the human listening leg, was unrun and needed the user's own
   dry vocal.

⭐⭐ **TWO OF THE THREE STOPPED BEING TRUE WHILE THIS DOCUMENT WAS BEING WRITTEN.**
Two concurrent agents landed the carry fix and the render integration in the same
session. Re-measured at 2026-09-22, directly:

- `Sources/DAWEngine/Stretch/StretchRenderCache.swift:106` now reads
  **`!clip.isStretchIdentity || clip.hasPitchEdits`** — a pitch-edited clip DOES
  reach the curve render.
- `Params` carries `pitchEdits` + `pitchEditSetHash`; the digest enters the on-disk
  key (`:201-202`) and `PlaybackGraph`'s `ClipKey` (`:60-88`) so the graph re-keys
  and cannot go on playing the old file.
- The carry sites are threaded and gated by `Tests/DAWCoreTests/PitchEditCarryTests.swift`.

⚠️ **And the comment in `Model.swift:631` still says "NOTHING RENDERS THIS YET".
It is now false.** The prose and the behaviour disagree, which is this tree's
characteristic failure: *the record says X, the source says Y, and nothing compares
them.* An implementer who trusts that comment will draw the wrong conclusion.
**Whoever next touches `Model.swift` should correct it.**

**What did NOT change: nothing writes `pitchEdits` (R3).** No store op, no wire verb,
no MCP tool, no UI — verified by grep across `Sources/`: the only assignments are
`Clip.init`'s empty→nil normalisation, `ClipDocument`'s persistence, and
`Params`' own copy. So the conclusion **survives its own evidence being replaced**,
for a different and simpler reason: **the read-only view still ships first, because
the preset button has no store operation to call.** That operation is now the whole
of the remaining work, and §6 specifies it.

**The transferable rule:** a prerequisite ladder is a measurement with an expiry
date. §4 carries the re-measurement recipe; run it, do not quote it.

### 2.2 ✅ The carry trap was armed and has been DISARMED — but the census MOVED, which is the point

When this doc began, `Sources/DAWCore/Model.swift` carried an armed trap: the
`Clip`-rebuild sites all dropped `pitchEdits` to nil, and the field's comment
censused them **by function** as `ProjectStore.splitClip` (twice),
`applyTrimWindow`, `moveClips(ids:byTracks:)`, `clipTrimmedToWindow`, and
`Takes.flatten`.

**It has since been fixed**, and `Tests/DAWCoreTests/PitchEditCarryTests.swift`
gates it. Two things about how it landed are worth carrying forward:

1. ⚠️ **THE SITE COUNT MOVED WHILE NOBODY WAS LOOKING.** The model comment named
   six call sites; the carry suite opens *"Seven `Clip(...)` construction sites in
   `Sources/DAWCore` REBUILD an existing clip field-by-field."* A re-census today
   finds carries in `ProjectStore.swift` (five), `Takes.swift`, `AudioQuantize.swift`
   — the last of which appears in no version of the original list. **Never quote a
   per-site count; census it, and report the method.**
2. ⭐ **THE SUITE ASSERTS IDENTITY, NOT PRESENCE, AND THAT DISTINCTION IS THE WHOLE
   GATE.** Its own banner: *"THE ASSERTION IS 'THE TIMES ARE UNCHANGED', NOT 'A SET
   IS PRESENT'. … A nil-check would pass against a rebased carry, and a rebased
   carry is the MORE LIKELY bug."* `windowedGainEnvelope` / `windowedControllerLanes`
   sit three lines above these sites doing exactly that re-anchoring — because those
   fields are clip-relative BEATS, while `NoteSegment` times are source-file seconds.
   Copying their shape would corrupt every segment on the right of a split *and
   leave a healthy-looking non-nil set behind*.
3. ⚠️ **A CORRECTION TO m23-q §7.5, ALREADY MADE IN THE TREE:** the design said
   comping's mapping is *"a filter, not a transform"*. The carry suite records that
   there is **no filter at `CompFlattener.flatten` either** — the carry is verbatim
   there too. Any §7-era design that assumes a comp filter is working from the
   superseded text.

### 2.3 `clip.detectPitch` is READ-ONLY and stores nothing

m23-q §7.7 described `clip.detectPitch` as a Phase-1 verb that *"runs detection,
stores the segment set"*. **What shipped (m23-ap-3) does not store.**
`Sources/DAWCore/ProjectStore+PitchDetection.swift:52` — `detectClipPitch` — is
documented as *"Read-only — no `performEdit`, no undo entry, nothing persisted …
NOT result-cached"*. It returns a per-frame contour (`ClipPitchDetection`
wrapping `PitchDetectionResult`), not segments.

**This is good news for the first increment** (§5): the read-only note view can run
entirely off this call plus `PitchAutoCorrect.voicedRuns`, in memory, writing
nothing — which is exactly why it dodges §2.2 entirely.

### 2.4 There is no clip inspector

m23-q §11.2's Phase 1 says the minimal UI is *"a control in the clip inspector"*.
**No clip inspector exists in this app.** Per-clip actions live in the clip's
CONTEXT MENU (`Sources/DAWApp/Timeline/TimelineLanesView.swift:3958`,
`ClipBlock.contextMenu`) — "Chop to Pads…", "Quantize…", "Humanize…",
"Breath Pad…", "Extract Groove…", "Fit to Content", "Reset Gain". §6 puts the
presets there, following that menu's own audio-only gating rule verbatim.

### 2.5 `openEditorClip` cannot be widened — a census test pins it at 14

`Sources/DAWApp/DAWProApp.swift:3168` filters to `clip.isMIDI` and is described in
the tree as *"the ONE rule"* for "is the roll on screen". It has **at least 14
mentions in that one file alone, and
`Tests/DAWAppKitTests/EditorSurfaceOwnershipSiteTests.swift:635-638` asserts the
count exactly**:

```
let note = "expected 14 code mentions of `openEditorClip` in DAWProApp.swift, found "
#expect(hits == 14, "\(note)")
```

Its readers include `activeEditorSurface`, `openEditorSurface`,
`pianoRollWouldConsumeKey`, `ClipboardMenuPolicy.pasteMenuItem`,
`SelectAllMenuPolicy`, `debug.viewZoom` and three `editorClipId` echoes. **Widening
it to admit audio clips would hand ⌘A "select all notes", Edit ▸ Paste and the
DELETE routing an audio clip with no notes.** §3 decides a sibling instead.

### 2.6 `view.selectClip` will start lying, and its reason string is pinned in five places

`view.selectClip` answers `audio-clip-has-no-editor` for an audio clip, and
`Sources/DAWApp/ViewUIWireSurface.swift:153` notes *"`reason` IS DERIVED FROM
`openEditorClip`, NOT FROM `clip.isMIDI`"*. The string is pinned in
`Tests/DAWControlTests/ViewSurfaceCommandTests.swift` (two sites),
`mcp-server/test/view-surface.test.ts` (two sites), `mcp-server/src/server.ts`,
**and the shipped `claude-plugin/server/index.mjs` bundle the user's agents
actually load.** §9 handles this additively rather than by editing the string.

---

## 3. DECISION 1 — Reuse vs new

### 3.1 The decision

> **The pitch editor is a SECOND BOTTOM EDITOR PANE — a sibling of the piano roll
> in the arrange's editor slot, not a third modal overlay and not a mode of
> `PianoRollView`. It reuses the PANE INFRASTRUCTURE (splitter, maximize,
> fraction, rebuild-on-clip-id) and reuses NOTHING of `PianoRollView`'s internals.
> Its math lives in a new headless `PitchEditorModel` in `Sources/DAWAppKit/`, on
> the `EQCurveEditorModel` / `AutomationLaneModel` pattern.**

The view file is `Sources/DAWApp/PitchEditor/PitchEditorView.swift`; the headless
model is `Sources/DAWAppKit/PitchEditorModel.swift`; the pitch ruler is
`Sources/DAWApp/PitchEditor/PitchRulerSidebar.swift`.

### 3.2 Alternative A — a third overlay in the `EffectEditorOverlay` mould. **Loses on shape.**

`EffectEditorOverlay` (`Sources/DAWApp/Mixer/EffectEditorOverlay.swift`) and
`SamplerEditorOverlay` are, in the tree's own words, *"the FIFTH instance of the
centered dark-glass modal over a dimmed scrim … an in-window card, NEVER a popover
or NSWindow."* They are fixed-width cards of knobs. Mounted in `ContentView.swift`
around lines 433–470, gated on `model.<x>Target != nil` plus a validity guard.

They lose for four reasons, in strength order:

1. **A pitch editor is a TIME-ALIGNED surface and a modal card is not.** It needs a
   horizontal scroll over the clip's whole span, a zoom ladder, a playhead that
   lines up with the transport, and follow-playhead. Every one of those already
   exists in the editor-pane slot (`PianoRollZoomModel`, `FollowPlayheadModel`,
   `PianoRollPlayhead`, `PianoRollScrubRulerBand`) and none of it exists in the
   overlay slot.
2. **A scrim is wrong for this task.** Tuning a vocal is an iterative listen-edit
   loop against the arrangement. Dimming the arrangement to do it is the Logic
   floating-window clutter the design language explicitly rejects.
3. **Modal cards are sized to fit a window floor.** `EffectEditorOverlay` reports
   its measured height back to `AppModel` specifically because it is a modal with
   no scroll of its own and its height is a real constraint against
   `WindowFloor.minHeight`. A vocal with 450 note segments does not fit that
   budget at any density.
4. **The overlays are one-at-a-time by construction.** Their mutual exclusion is a
   feature for knob cards. Here it would mean opening the pitch editor closes the
   effect editor the user is A/B-ing against, which is the wrong coupling.

### 3.3 Alternative B — a MODE of `PianoRollView`. **Loses on the data model, not on tidiness.**

This is the tempting one: TUNE X's screen *looks* like a piano roll, the roll
already has a piano keyboard down the left edge, and it is already the bottom pane.
It loses anyway, on four measured facts:

1. **The note models are incompatible at the type level.** `PianoRollView` edits
   `[MIDINote]` — integer pitch, beat-space rects, committed through
   `ProjectStore.setClipNotes`. A pitch editor edits `[NoteSegment]` — continuous
   `detectedHz` in **source-file seconds**, with `pitchOffsetCents` as a
   `Double`, committed through a different store op onto a different field of
   `Clip`. `PianoRollModel.y(forPitch: Int)` (`Sources/DAWAppKit/PianoRollModel.swift:265`)
   takes an `Int`. A pitch contour needs `y(forMidi: Double)`. That is not a
   parameter tweak; it is a different axis.
2. **`PianoRollView` is 4557 lines with one mount point.** Its own comments record
   that it defaults its selection bridge *"because it has exactly one mount"*. It
   carries bar ops, controller lanes, velocity lanes, marquee, musical typing,
   quantize/humanize/breath-pad chips, a step-sequencer bridge, and three
   `.onKeyPress` arbitration paths. Adding a second data model behind a mode flag
   doubles the surface every one of those has to be correct across, in the file
   that is already the app's largest.
3. **Every gate of the roll is MIDI-shaped.** `openEditorClip` filters
   `clip.isMIDI` (§2.5); ⌘A selects notes; Edit ▸ Paste pastes notes; DELETE routes
   on `pianoRollWouldConsumeKey`, which means *"the roll is open AND holds a NOTE
   selection"*. A mode flag would either inherit all of those wrongly or need a
   parallel set — which is Alternative C with extra steps and less honesty.
4. **The audition mechanism does not transfer.** The roll auditions by sending MIDI
   note-ons to the track's instrument (`KeyboardSidebar.onAudition`,
   `Sources/DAWCore/Audition.swift`). Auditioning a vocal segment means playing
   *audio*, and m23-q §7.6 names that distinction explicitly:
   *"it is MIDI note audition, not audio — it is the pattern to copy for where the
   policy lives, not a mechanism we can reuse for audio."*

### 3.4 What the decision DOES reuse — a precise list

| Reused | From | Why it transfers |
|---|---|---|
| The editor-pane slot: `editorSplitter(geoHeight:)`, `EditorMaximize.arrangeHeight`, `editorPaneFraction`, the 0.30–0.55 clamp, Escape-to-restore | `ContentView.swift` ~775, `Sources/DAWAppKit/EditorMaximize.swift` | It is geometry over "the bottom pane", with no MIDI term in it. Second pane = second branch on the same helpers. |
| `.id(clip.id)` rebuild-on-switch | `ContentView.swift:953` | Same need: switching clips must reset the editor's draft, not migrate it. |
| `WaveformStore` + `WaveformPeaks.magnitude(atSeconds:)` | `Sources/DAWApp/Timeline/ClipWaveform.swift:51,35` | Already a `@MainActor @Observable` URL-keyed cache with off-main `Task.detached` reads at 150 buckets/s, file-scope `peakMax`. Splits share a file, which is exactly right here. |
| `WaveformScale.drawScale(peakMax:normalize:verticalZoom:)` | `Sources/DAWAppKit/WaveformScale.swift` | One scalar, resolved per-view before the Canvas closure. The m25-e auto-fit rules apply unchanged. |
| The Canvas contract (m16-a): `@Sendable` renderer closures capture **values only**, snapshotted on the main actor into a `DrawContext` struct before the closure | `AutomationLaneEditor.swift:260-281`, `ClipWaveform.swift:149` | Non-negotiable. A crash precedent exists: `docs/research/design-m16a-canvas-crash.md`. |
| The headless-model pattern: all geometry + all edit rules in `DAWAppKit`, the view is drawing and gestures only | `EQCurveEditorModel`, `AutomationLaneModel`, `PianoRollModel` | **`DAWApp` has no test target.** `Tests/DAWAppKitTests/` is where this can be tested at all. This is the reason, not a preference. |
| `FollowPlayheadModel`, `PianoRollPlayhead`'s "clip-local playhead from the ONE transport source" rule, `OffClipEdgeCue` | `Sources/DAWAppKit/`, `Sources/DAWApp/Components/OffClipEdgeCue.swift` | No second ticker. The pitch editor renders `store.transport.positionBeats`, mapped clip-local, exactly as the roll does. |
| `ClipShimmer` as the "this clip is re-rendering" cue | `Sources/DAWApp/Timeline/TimelineLanesView.swift:4203`, painted at `:3273` via `ClipRenderVisual.shimmer` | m23-q §7.6 names it as the existing visual language for a pending offline render. Increment C inherits it for free through `ClipStretchStatus`. |
| `PanelSplitter`, `DAWTheme`, `.glow`, `hoverCursor`, `CursorAffordance` | `Sources/DAWApp/Components/`, `Theme.swift` | House chrome. |

### 3.5 What the decision DOES NOT reuse, and why — stated explicitly

- **`PianoRollView` itself, and every one of its sub-views.** §3.3.
- **`KeyboardSidebar` (`Sources/DAWApp/PianoRoll/KeyboardSidebar.swift`).** Two
  disqualifiers, either alone sufficient. (a) It takes `model: PianoRollModel` and
  maps **integer** pitch to y. (b) It is, in its own words, *"the app's one light
  surface"* with a whole dual-ink token set (`DAWTheme.…OnWhite`) existing because
  *"Reaching for `hairline`, `gridEmphasis`, `textDim` or `playback` on an ivory row
  measures 1.0–2.2:1, i.e. invisible."* A pitch ruler drawn over a dark waveform is
  a **dark** surface. **A new `PitchRulerSidebar` is the right answer, and it must
  not silently re-derive the light tokens.** What it SHOULD copy is the
  `keyLabel` density decision (every key named, C-1…G9) and the press-and-hold
  `DragGesture(minimumDistance: 0)` + `.contentShape` idiom.
- **`ClipWaveform` the View.** It draws in **beat space** at `pixelsPerBeat` against
  a clip block's height, with `.allowsHitTesting(false)`. The editor needs a
  different height budget, a different vertical anchor (the waveform sits *behind*
  the note blobs, not centred in a block), and — later — hit testing. Reuse
  `WaveformPeaks` and `WaveformStore`; write the editor's own Canvas.
- **`AutomationGeometry` / `AutomationEdit`.** Right *shape*, wrong axis: value is a
  normalised 0–1 in a lane, not a pitch in cents over a piano ruler. Copy the
  pattern (`geometry.hitTest(location, points:)`, `draft` + `onCommit`), not the type.
- **`openEditorClip`.** §2.5, and §3.6 below.

### 3.6 DECISION 2 — how the pane is addressed, and why it is a LATCH and not a derivation

`openEditorClip` derives from `selectedClipID` + a MIDI filter. **The pitch editor
must NOT copy that**, for a product reason:

> A MIDI clip *is* notes, so a note editor is always the right editor for it and
> auto-opening is correct. An audio clip may be a drum loop, a rendered stem, a
> field recording or a vocal. SwiftF0 is a **monophonic** detector. Auto-opening a
> vocal pitch editor on every audio clip selection would make a claim the app
> cannot support, on the majority of audio clips in a real project.

**So opening the pitch editor is an EXPLICIT act.** The accessor:

```
// Sources/DAWApp/DAWProApp.swift — AppModel
private var pitchEditorRequestedClipID: UUID?     // set only by an explicit open

var openPitchEditorClip: Clip? {
    guard let id = pitchEditorRequestedClipID, id == selectedClipID else { return nil }
    for track in store.tracks {
        if let clip = track.clips.first(where: { $0.id == id }), !clip.isMIDI { return clip }
    }
    return nil
}
```

Four properties fall out of that shape, and each is the reason for a term:

1. **The two panes are mutually exclusive by construction, not by arbitration.**
   Both resolve the SAME `selectedClipID`; `openEditorClip` requires `isMIDI`,
   this requires `!isMIDI`. They cannot both be non-nil. **No one-at-a-time rule
   has to be written, tested, or kept in sync.**
2. **Selecting any other clip closes it**, because the `id == selectedClipID` term
   fails. That matches the roll's behaviour and needs no `onChange` watcher.
3. **A deleted clip closes it**, because the store lookup returns nil — the same
   safety `openEditorClip`'s doc comment claims for itself (*"a stale id after an
   undo resolves to nil here, closing the panel and emptying the echo together"*).
4. **`openEditorClip`'s census stays at 14.** This accessor does not mention it.
   ⚠️ If an implementer finds themselves adding a mention, stop: that is the
   second-computation failure `EditorSurfaceOwnershipSiteTests` exists to catch.

**`EditorSurface` grows a third case, `.pitchEditor`, and `EditorSurfaceRouter`
grows one term.** This is required, not optional: `resolve` routes ⌘+/⌘−/⌘0 and
`openSurface` routes ⌘A, and a pitch editor that is on screen but invisible to both
would hand the arrange every zoom the user aims at the editor. The change is:

- `EditorSurface` gains `.pitchEditor` (it is `CaseIterable`; `EditorSurfaceRouterTests.fullTruthTable`
  grows rows).
- `openSurface(workspaceIsArrange:rollOpen:pitchEditorOpen:)` — third parameter,
  applied **after** `rollOpen` (they are mutually exclusive, so order is a
  formality; fixing it makes the truth table total).
- `resolve` stays implemented on top of `openSurface` — the shared-terms invariant
  `EditorSurfaceRouterTests.theSharedTermsCannotDrift` pins must not be broken.
- `EditorSurfaceEngagement.engage(.pitchEditor)` from the pitch editor's own
  gestures, with the change-guard intact (it is load-bearing: an unguarded write
  invalidates every observer at pointer rate).

⚠️ **THIS COSTS MORE THAN "ONE TERM", AND THE COST MUST BE CENSUSED, NOT GUESSED.**
Three things move with the case, and the third is the one that bites:

1. **`ActiveEditorSurface.Reason` and `OpenEditorSurface.Reason` are SEPARATE
   `CaseIterable` enums, echoed on the wire.** They are separate deliberately (the
   router's banner: sharing would give consumers cases that are unreachable by
   construction). Each needs its own new case — `engagedPitchEditor` on the first,
   `pitchEditorOpen` on the second — and `EditorSurfaceRouterTests.fullTruthTable`
   sweeps **both** surface and reason, so a mapping slip is a red row rather than a
   silent re-route. Good.
2. **`EditorSurface` is `CaseIterable`**, so any exhaustive `switch` over it stops
   compiling — which is the *desired* failure: the compiler enumerates the sites.
3. ⭐⭐ **CENSUS THE READERS BY METHOD, AND BEWARE THE OBVIOUS PATTERN.**
   `grep -rn "\.pianoRoll" Sources/DAWApp Sources/DAWAppKit Tests/DAWAppKitTests`
   returns **214 hits across 36 files — and that number is nearly 6× wrong**, because
   the pattern also matches `.pianoRollPPB`, `.pianoRollRowHeight`,
   `.pianoRollMinimap`, `.pianoRollNotes`, `.pianoRollMarquee`, `.pianoRollBarOps`
   and a dozen more identifiers that have nothing to do with `EditorSurface`.
   Disambiguate before believing anything:

   ```
   grep -rno "\.pianoRoll[A-Za-z]*" Sources/DAWApp Sources/DAWAppKit Tests/DAWAppKitTests \
     --include="*.swift" | sed 's/.*://' | sort | uniq -c | sort -rn
   ```

   Bare `.pianoRoll` is ~36 of those — **and even that is an upper bound**, since it
   still catches any other enum with a `pianoRoll` case (panel IDs, for one). **Let
   the compiler produce the real list: add the case, build, and fix what breaks.**
   Report the method and the file list; never quote a number from the naive grep.

**⚠️ WHEN THE LATCH CLEARS, AND THE CLOSE DOOR — specify both, or an implementer
picks by accident.** As written above the latch survives a selection change, so
open on A → select B (pane hides) → select A again → **the pane reappears**. Two
defensible readings; **this doc picks the first and names the second**:

- ✅ **CHOSEN — "selecting away CLOSES."** `pitchEditorRequestedClipID = nil`
  whenever `selectedClipID` changes to anything else. Rationale: it matches the
  roll (deselect closes), it makes "is the pitch editor open" a question with one
  visible answer, and a sticky pane that springs back on re-selection is a surprise
  a novice cannot explain.
- The alternative — "sticky per clip", the latch persisting so returning to a clip
  restores its editor — is better for a tune-several-vocals workflow and should be
  reconsidered **only** on user feedback, not on a reviewer's taste.

**And because opening is explicit, closing needs an explicit door too** (the roll
gets closing for free from deselection; this does not): a close affordance in the
pane header, `AppModel.closePitchEditor()`, and the state echoed by
`debug.pitchEditor` so a gate can prove the pane went away rather than assuming it.

⚠️ **What must NOT move with it:** `pianoRollWouldConsumeKey`,
`SelectAllMenuPolicy`, `ClipboardMenuPolicy.pasteMenuItem` and `DeleteMenuPolicy`
all ask NOTE questions. A pitch segment is not a note. Those four stay MIDI-only in
Increment A and B; DELETE and ⌘A inside the pitch editor are **interaction
questions and belong to §7**.

---

## 4. The prerequisite ladder — RE-MEASURED 2026-09-22, and it must be re-measured again

⚠️⚠️ **THIS TABLE MOVED TWICE DURING THE WRITING OF THIS DOCUMENT.** Two rungs I
recorded as unmet were met by concurrent agents within the hour (§2.1). **Do not
quote this table. Re-run the four probes in §4.1 before picking an item**, and if a
rung disagrees with what you find, the tree is right and this table is stale.

| Rung | State required | Status as measured 2026-09-22 | Probe |
|---|---|---|---|
| **R0** | `ProjectStore.detectClipPitch` works against a real engine | ✅ **DONE** (m23-ap-3) | `Sources/DAWCore/ProjectStore+PitchDetection.swift` |
| **R1** | `PitchEditSet` / `NoteSegment` / `PitchAutoCorrect` exist and are pure | ✅ **DONE** | `Sources/DAWCore/PitchCorrection.swift` |
| **R2** | The `Clip`-rebuild sites carry `pitchEdits` through **verbatim** | ✅ **DONE** — landed mid-session | `Tests/DAWCoreTests/PitchEditCarryTests.swift`; census `grep -rn "pitchEdits: " Sources/` |
| **R4** | The render path reads the curve and a pitch-edited clip leaves the identity bypass | ✅ **DONE** — landed mid-session | `StretchRenderCache.needsRender` == `!clip.isStretchIdentity \|\| clip.hasPitchEdits` |
| **R3** | **A store op writes `pitchEdits` under `performEdit`, with a wire verb and an MCP tool** | ⛔ **NOT DONE — THE ONLY REMAINING STRUCTURAL GAP** | No assignment outside `Clip.init` / `ClipDocument` / `Params`; no `clip.autoCorrectPitch` in `Commands.swift` |
| **Q1** | E2 — a human has listened to curve-driven correction on a **real voice** | ⛔ **UNRUN** (`m23-ap-5`), needs the user's dry vocal | `Tests/DAWEngineTests/M23QE2RenderTests.swift`, env-gated |

### 4.1 The four probes, so this table can be falsified rather than trusted

```
# R2 — census the carry sites BY FUNCTION, never by count
grep -rn "pitchEdits: " Sources/ --include="*.swift"

# R4 — does a pitch-edited clip leave the identity bypass?
grep -n "needsRender" -A 3 Sources/DAWEngine/Stretch/StretchRenderCache.swift

# R3 — is there a WRITER yet? (a carry `pitchEdits: clip.pitchEdits` is NOT one)
grep -rn "pitchEdits = " Sources/ --include="*.swift"
grep -n "autoCorrectPitch\|clearPitchEdits" Sources/DAWControl/Commands.swift

# Q1 — has anyone listened?
grep -n "m23-ap-5" docs/ROADMAP.md
```

⚠️ Each of these is a grep whose **emptiness you intend to interpret**. Never pair
one with `2>/dev/null`, and positive-control the pattern against something you know
exists before believing a zero. `grep -c` exits 1 on zero.

### 4.2 What the ladder now means for each increment

- **Increment A (§5, the read-only view) needs R0 + R1 only.** Both are done. It
  writes nothing, so R2/R3/R4 cannot bite it. **It is unblocked today and remains
  the right first item** — not because the others are impossible, but because it is
  the whole visible surface and it is independent of the interaction model.
- **Increment B (§6, presets) needs R3, and R3 alone.** This is a much better
  position than the one I started writing from: the render path is live, so a store
  op that writes a `PitchEditSet` produces **audible** correction. §6 specifies that
  operation completely.
- **Q1 is a QUALITY gate, not a structural one, and it must not be conflated with
  R4.** The code ships without it; what does not ship without it is the *claim* that
  it sounds good on a voice. ⛔ **Do not tick a roadmap box that says "sounds
  natural" on the strength of a sine.** That is the precise mistake
  `m23-q` §4.2 records the M5 decision having already made once, on a polysynth.
- **Increment C (§7) needs all of the above plus the video.**

### 4.3 ⚠️ Two live inconsistencies the render integration left behind

Named here because both are invisible and both will mislead somebody:

1. **A DELIBERATE SECOND HOME FOR AN IDENTITY RULE.**
   `StretchRenderCache.swift:95-107` says so itself: *"A DELIBERATE, TEMPORARY
   SECOND HOME FOR AN IDENTITY RULE … when the model folds it in, this collapses to
   `!clip.isStretchIdentity`."* `paramsIdentityAgreesWithNeedsRender` pins the two
   against each other so they cannot drift silently. **It is correctly flagged and
   correctly pinned — but it is still a second home, and it stays open until
   `Clip.isStretchIdentity` folds in `hasPitchEdits`.** Whoever does that fold must
   expect the byte gates that pin today's behaviour to move with it.
2. **STALE PROSE IN `Model.swift`.** Both `pitchEdits` (`:631`) and `hasPitchEdits`
   (`:729`) still say render integration has not happened. It has. §2.1.

## 5. INCREMENT A — the read-only note view. **Ships first. Buildable from this doc alone.**

### 5.1 What it is, in one sentence a novice would understand

> **Open a vocal recording and SEE the notes you sang — drawn over the waveform,
> lined up against a piano keyboard — without changing anything.**

Nothing is draggable. Nothing is saved. Nothing sounds different. It is a
microscope, and the user asked for the microscope's glass before its focus knob.

### 5.2 Why this is the right first increment

- It needs neither R2 nor R4, so it cannot ship data loss and cannot ship silence.
- It is the **entire left-hand two-thirds of the TUNE X screen** — waveform, blobs,
  piano ruler, contour. The video changes what happens when you *touch* it, not
  what it *looks* like.
- **A UI phase is not done until someone looked at it.** This one is nothing but
  looking, so it is the increment most likely to produce real feedback, and the
  user's own rule is that their reaction IS the feedback.
- It makes `clip.detectPitch` — which shipped in August and has had no human-facing
  door since — reachable by a person for the first time.

### 5.3 The data path, end to end

```
user opens the editor on an audio clip (explicit act, §3.6)
  → AppModel.openPitchEditor(clipID:)         [sets pitchEditorRequestedClipID + selectedClipID]
  → PitchEditorModel.load(clip:tempoMap:)     [main actor, @Observable]
      → await store.detectClipPitch(clipId:)  [async; the SAME call clip.detectPitch makes]
      → PitchDetectionResult { frames: [ClipPitchFrame], frameRateHz }
      → PitchAutoCorrect.voicedRuns(in: frames, frameRateHz:) -> [VoicedRun]   [pure, DAWCore]
      → model.blobs / model.contour                                            [derived, cached]
  → PitchEditorView draws
```

**Zero persistence. `Clip.pitchEdits` is neither read nor written.** The detection
result lives in the model for the life of the pane and dies with it. ⚠️ Do not
"optimise" this by caching into the clip — that is R3, and it arms §2.2.

`detectClipPitch` is **not result-cached** (`ClipPitchAnalyzer`'s header says why),
so re-opening the same clip re-detects. On a 3-minute vocal that is ~11,250 frames.
**Measure it before adding a cache; do not assume it is slow.** If it is, the cache
belongs in the model keyed by `(clipID, startOffsetSeconds, sourceWindowSeconds)`,
not on the clip.

### 5.4 `PitchEditorModel` — `Sources/DAWAppKit/PitchEditorModel.swift`

`@MainActor @Observable final class`, on the `EQCurveEditorModel` pattern: **all
math here, none in the view.** `DAWApp` has no test target; this is the only place
the geometry can be tested.

**Inputs (plain values, injected — the view and the model are both previewable):**

| Input | Type | Note |
|---|---|---|
| `clipID` | `UUID` | ⚠️ **ID, NEVER track-and-index** — m23-q §7.5/F11, condition 4, so take lanes work from day one. |
| `sourceWindowStartSeconds` | `Double` | `clip.startOffsetSeconds` |
| `sourceWindowSeconds` | `Double` | `clip.sourceWindowSeconds(tempoMap:)` (`Model.swift:746`) |
| `startBeat`, `lengthBeats` | `Double` | the clip's project-timeline span |
| `tempoMap` | `TempoMap` | for beat↔second (`TempoMap.seconds(from:to:)`, `beat(atSecondsFromZero:)`) |
| `pixelsPerBeat` | `CGFloat` | from a persisted zoom slot (§5.8) |
| `midiRange` | `ClosedRange<Double>` | the visible pitch window, §5.6 |
| `rowHeight` | `CGFloat` | pixels per semitone |

**THE ONE COORDINATE HOME.** The editor's x-axis is **PROJECT BEATS**, because the
playhead, the arrange and the user's mental model are all in bars — but the DATA is
in **SOURCE-FILE SECONDS**. Exactly two functions convert, and nothing else in the
app may:

```
func x(forSourceSecond s: Double) -> CGFloat
func sourceSecond(forX x: CGFloat) -> Double
```

⚠️ **Phase 3 (per-note timing) is where these stop being a simple affine.** Today
`stretchRatio` is constant over the clip so the mapping is one multiply; with
per-segment time deltas the source→output schedule becomes piecewise. **Keeping
both directions in these two functions is what makes Phase 3 a change to one file.**
Write that sentence into the source. Do not inline the arithmetic at a draw site.

**Y-axis:** `y(forMidi: Double) -> CGFloat` and `midi(forY:) -> Double`.
⚠️ **`Double`, not `Int`** — this is the single largest divergence from
`PianoRollModel` and the reason `KeyboardSidebar` cannot be reused (§3.5).

**Derived outputs (all pure, all testable):**

- `blobs: [NoteBlob]` — one per `VoicedRun`: `{ id, startSeconds, endSeconds,
  centreMidi, medianConfidence, frameCount }`.
- `contourSegments: [[CGPoint]]` — the per-frame pitch line, **broken into separate
  polylines at every hole.** See §5.5.
- `rulerKeys: [(midi: Int, isBlack: Bool, label: String?)]`.

### 5.5 ⛔ THE FIVE HONESTY RULES — measured, not stylistic

`Sources/DAWCore/PitchCorrection.swift`'s header documents five measurements that
constrain what this UI is allowed to draw. **Every one of them is a way this
surface could tell a confident lie.** They are repeated here because a drawing
agent will not read a DSP file.

1. **A HOLE IS THE SIGNAL. NEVER BRIDGE ONE.** `ClipPitchFrame.frequencyHz` is
   `nil` on an unvoiced frame, with a `precondition` behind it. The contour is
   drawn as **N separate polylines**, one per voiced run, with visible gaps. A
   single `Path` that `addLine`s across a hole invents pitch where none was
   measured. `voicedRuns` already ends a run at a hole *and* at any frame gap
   larger than 1.5 frame periods — mirror that in the drawing.
2. **NO SMOOTHING OF THE CONTOUR.** SwiftF0's output is an argmax over 256
   log-spaced bins = **25.79 cents per bin**. The contour has a visible staircase.
   That staircase is the instrument's real resolution. Smoothing it draws a
   precision the detector does not have.
3. **ANY CENTS READOUT MUST RESPECT A ±12.90 CENT FLOOR.** Half a bin. Display
   whole numbers at most (`-31 cents`), never a decimal. (The transposer used to
   add a second error, **+5.45 cents at +2 st, +3.95 at −2 st**, until p2-acc's
   vendored patch on 2026-09-25; it now lands within 0.5 c for |shift| ≤ 3 st.
   This floor never depended on it.) The honest product claim,
   from the same header: *"pulls a note's centre onto the scale, to roughly the
   detector's own resolution."*
4. **CONFIDENCE IS VOICING, NOT ACCURACY.** A 440 Hz sine reads 437.55 Hz — 9.7
   cents flat — at confidence ≥ 0.985. If confidence is shown at all (blob
   opacity is the natural encoding), its label is **"how sure we are you were
   singing here"**, never "how accurate". It must never gate a tolerance.
5. **`vibratoScale` IS A KEEP/FLATTEN LEVER AND MUST NEVER BE A DEPTH SLIDER.**
   Measured: vibrato comes back **1.06× at 1 Hz, 1.15× at 5 Hz, 1.20× at 8 Hz**
   deeper than asked. Good enough to correct through, **not** good enough to shape
   with. A "Vibrato depth: 120%" control would be a number the engine cannot
   honour. This binds §7 too — **the video cannot overrule a measurement.**

A sixth, from `PitchDetection.swift`: **`levelDbfs` is `nil` for exact digital
silence** and `absence` carries one of `belowConfidence` / `belowLevel` /
`outOfRange`. A stretch of `belowLevel` is a *rest*; a stretch of `belowConfidence`
is *we could not tell*. Those are different facts and the UI may show them
differently, but must not merge them into "no note".

### 5.6 What is on screen (dark glass cockpit, `docs/DESIGN-LANGUAGE.md`)

Bottom to top, one `ZStack`, three `Canvas` layers plus chrome:

1. **Waveform layer.** `WaveformPeaks` via `WaveformStore`, drawn full-height and
   **dim** (it is context, not the subject) — `DAWTheme.textDim` at low opacity,
   honouring the m25-e `normalize` / `verticalZoom` slots so it matches the arrange.
2. **Pitch grid layer.** Horizontal hairlines per semitone, brighter at each C,
   dim SF Mono note names at the left. Redraws on size/zoom change only.
3. **Blob layer.** One rounded rect per `VoicedRun`: x from `startSeconds`/
   `endSeconds`, y centred on `centreMidi`, height ≈ 0.8 × `rowHeight`. Fill =
   neutral raised panel; **no accent at rest** (Rule 3: an accent is earned by
   state, not by inviting a click). Each blob carries its note name (`A3`) in SF
   Mono when there is room. Opacity encodes `medianConfidence`, labelled per §5.5.4.
4. **Contour layer.** The per-frame line, drawn **through** the blobs, bloom-under-core
   (the house glow recipe: wide faint stroke, then bright narrow core — copy
   `AutomationLaneEditor.drawPolyline`). **Cyan is FORBIDDEN here** — cyan means
   playback/activity and nothing else (Rule 3). Use `DAWTheme.textPrimary` for the
   core. **No violet:** a detected contour is a measurement, not AI-generated
   content (Rule 3 again).
5. **Playhead.** The cyan line, from `store.transport.positionBeats` mapped
   clip-local via `PianoRollPlayhead` — **the same source the arrange consumes, no
   second ticker.** Off-clip shows `OffClipEdgeCue`, as the roll does.
6. **`PitchRulerSidebar`** down the left: a dark piano keyboard, one row per
   semitone, every key named (copy `KeyboardSidebar`'s `keyLabel` density
   decision), **house dark tokens — NOT the `…OnWhite` set** (§3.5).
7. **Header strip.** Clip name, a plain-language status line, and (Increment B) the
   preset chips.

**Vertical range.** Default: the detected pitch range padded by ±4 semitones,
clamped to a sane vocal window, **never the full 128** — a 128-row view makes a
vocal an invisible ribbon. If no pitch was detected, fall back to a fixed
comfortable range and say so in words. Vertical scroll reveals the rest.

### 5.7 ⭐ THE FOUR STATES THIS SURFACE MUST RENDER HONESTLY

A read-only view whose empty state is indistinguishable from its broken state is
the exact failure this project keeps paying for. **All four get drawn prose, not a
spinner and not silence.** Use `PanelRefusalLine` (`Sources/DAWApp/Components/`),
the house component for exactly this.

| State | Cause | What the user sees (beginner-readable) |
|---|---|---|
| **Analysing** | `detectClipPitch` in flight | The waveform, dimmed, with a shimmer (the `ClipShimmer` recipe) and **"Listening to your vocal…"** |
| **No notes found** | `voicedRuns` returned `[]` | **"We could not hear any sung notes here. This works best on one voice singing on its own — not on drums, chords or a full mix."** |
| **Engine unavailable** | `ProjectError.engineUnavailable` (headless, or the capability is missing) | **"The audio engine is not running, so we cannot analyse this clip yet."** ⚠️ Never fabricate a detection — the `analyzeAudioContent` precedent. |
| **Refused** | MIDI clip, or `audioFileURL` missing on disk | The editor does not open at all; the door is hidden, not offered-then-errored (§6.2). If reached by the wire, the store's own teaching error text is shown verbatim. |

⚠️ **"No notes found" and "engine unavailable" must be visibly different.** A tool
that never ran and a tool that ran and found nothing must not produce the same
screen. This is the project's standing rule, applied to pixels.

### 5.8 Zoom, follow and density

- **Horizontal zoom**: a new persisted `PanelLayoutStore` slot `pitchEditorPPB`,
  the `pianoRollPPB` twin. ⌘+/⌘−/⌘0 route to it **only** through
  `EditorSurfaceRouter.resolve` (§3.6) — never through a raw
  `openPitchEditorClip != nil`.
  ⚠️ **TIER: `debug.panelLayout`, NOT `view.panelLayout`.** `view.panelLayout`
  accepts exactly two keys and **explicitly rejects `pianoRollPPB` and every other
  chrome slot**, on the stated rule that it owns only what determines *what a
  capture can see*. `pitchEditorPPB` *"changes what an eye prefers, not what exists
  to be seen"*, so it joins `pianoRollPPB` in the debug tier. Sending it to
  `view.panelLayout` must be a rejected unknown key, on purpose.
- **Follow playhead**: reuse `FollowPlayheadModel` and the ONE `layout.followPlayhead`
  flag both surfaces already read. Follow during **playback only** (m23-c2's rule:
  a seek must not scroll the editor out from under an edit).
- **Simple/Pro density: NO CHIP.** `docs/DESIGN-LANGUAGE.md` "Panels": *"every
  other panel's Simple and Pro modes COINCIDE by design and must never grow a
  do-nothing toggle — a toggle that changes nothing is worse than none."* Increment
  A has one mode. If Increment C's tool set makes the modes genuinely differ, it
  earns a chip then, and the verdict is recorded in
  `docs/research/simple-pro-inventory.md` §"Density adoption status" — which is the
  procedure, not an optional nicety.

### 5.9 Real-time safety

**Nothing in this increment touches the render thread, and that is structural, not
careful.** `detectClipPitch` → `AudioEngine.detectPitch` → `Task.detached` →
`ClipPitchAnalyzer` (`nonisolated`, documented as crossing the detached boundary).
The model is `@MainActor`. The Canvas closures are `@Sendable` value captures.
`WaveformStore` reads files on `Task.detached(priority: .utility)`.

⛔ **m23-q §7.6 / condition 5 is absolute: no pitch DSP on the render thread, ever.**
And its named future temptation is **live audition while dragging**: the answer is
already decided — **cached offline render + the existing 250 ms debounce, never
signalsmith on the render thread.** signalsmith allocates, uses `std::function`,
and is bursty by design (`splitComputation` exists because of it). **Flag any
Increment-C proposal that says otherwise.**

---

## 6. INCREMENT B — the preset surface. **Fully specified; independent of the video; gated on R3 ALONE (§4).**

⭐ **The render path is LIVE as of 2026-09-22 (§2.1/§4).** A store op that writes a
`PitchEditSet` now produces audible correction through `StretchRenderCache`'s curve
path. **This increment is one store operation, one wire verb and one MCP tool away
from being real** — it is no longer gated behind a user-dependent listening leg.
What the listening leg (Q1) still gates is the *claim* that it sounds good.

This is the half for *"someone who never opens the editor"* — which is most people,
most of the time, and is `PitchCorrectionPresets.swift`'s own stated reason to exist.

### 6.1 The four actions, as they already exist in `Sources/DAWCore/PitchCorrectionPresets.swift`

| Preset | `displayName` | `summary` (the shipped novice line) | strength | retuneMs | preserveVibrato |
|---|---|---|---|---|---|
| `.gentle` | Gentle | "Pulls notes halfway to pitch. Slides, scoops and vibrato stay." | 0.5 | 200 | true |
| `.natural` | Natural | "Every note lands in tune, and it still sounds like singing." | 0.85 | 110 | true |
| `.tight` | Tight | "Notes snap into tune the moment they start." | 1.0 | 40 | true |
| `.hardTune` | Hard Tune | "Replaces your pitch with the exact note. The robot effect." | 1.0 | 30 (`engineMinimumRetuneMs`) | **false** |

**Use these strings verbatim.** They are already written for a novice and already
reviewed. ⚠️ Their doc comment warns the milliseconds are *"STARTING POINTS, NOT
MEASURED TASTE"* — provisional until a person listens. The UI must not present them
as calibrated, and the listening round (§12) is how they stop being provisional.

⚠️ **The ladder is three, not four.** `PitchCorrectionPreset.ladder` is
`[.gentle, .natural, .tight]` and excludes `hardTune` deliberately: *"it is not a
stronger `tight`, it is a different algorithm, and a UI that presents all four as
one slider would be lying about what the last stop does."* **So the preset surface
is FOUR BUTTONS, never a four-stop slider.** Hard Tune is visually separated —
below a hairline, or set apart — because it is a different kind of thing.

### 6.2 Where they live — three doors, one store call

**Door 1 — the clip context menu. THE PRIMARY DOOR.**
`Sources/DAWApp/Timeline/TimelineLanesView.swift`, `ClipBlock.contextMenu` (:3958).

Follow the **"Chop to Pads"** precedent — its gate at `:4015`, its button at `:4017` — exactly, including its gate and
its reasoning (*audio only, and hidden rather than offered-then-errored — the
"Quantize…" / "Convert Voice…" rule*):

```
if !clip.isMIDI, clip.audioFileURL != nil {
    Divider()
    Menu("Tune Vocal") {
        Button("Gentle")    { onTuneVocal(.gentle) }
        Button("Natural")   { onTuneVocal(.natural) }
        Button("Tight")     { onTuneVocal(.tight) }
        Divider()
        Button("Hard Tune") { onTuneVocal(.hardTune) }
        Divider()
        Button("Open Note Editor…") { onOpenPitchEditor() }
        Button("Remove Tuning")     { onClearPitchEdits() }   // only when pitchEdits != nil
    }
}
```

⚠️ **OUTSIDE the `if pro` block**, on the same argument "Chop to Pads" and "Delete"
both won: *"an operation reachable by only one route is an operation that goes
missing"*, and tuning a vocal is not expert chrome. Each `Button` label carries
`.help(preset.summary)`.

**Door 2 — the pitch editor's own header.** The same four as house chips, with
`summary` rendered as **drawn prose** under them rather than a tooltip — a tooltip
is invisible to `view.capture`, so a captured gate cannot tell a correct caption
from a missing one (the `EQCurveEditor.help` lesson, verbatim).

**Door 3 — the wire / MCP.** §9.

**All three call ONE store method.** No second policy, no second default, no second
scale resolution.

### 6.3 The store operation — `Sources/DAWCore/ProjectStore+PitchCorrection.swift`

```
@MainActor extension ProjectStore {
    @discardableResult
    public func autoCorrectClipPitch(clipId: UUID,
                                     preset: PitchCorrectionPreset,
                                     scale: PitchCorrectionScale? = nil) async throws -> PitchEditSet
    public func clearClipPitchEdits(clipId: UUID) throws
}
```

Five things this method must get right:

1. **⚠️ `performEdit` IS SYNCHRONOUS** (`ProjectStore.swift:7764` —
   `func performEdit<T>(_ label:key:_ body: () throws -> T) rethrows -> T`).
   Detection is `async`. **Detect first, outside; then enter `performEdit` with the
   set already computed.** An `await` inside the body is not expressible, and
   trying is how this becomes a second edit path.
2. **Re-locate the clip by id AFTER the await.** The `analyzeClipAudio` /
   `detectClipPitch` precedent — the clip may have moved, been trimmed or been
   deleted during detection. If it is gone, throw `clipNotFound`; do not write to a
   stale index.
3. **Scale defaults honestly.** `PitchCorrectionScale.chromatic` is the only honest
   default when nobody has said the key. ⭐ There is a free improvement available
   and it should be taken: `PitchCorrectionScaleMode`'s raw values are *"exactly
   `KeyEstimate.mode`'s two strings, so a future 'default the scale to the clip's
   detected key' is a direct construction rather than a translation table."*
   If the project or clip already carries a detected key, use it and **say so in
   the UI** ("in G minor"); otherwise chromatic and say that too.
4. **Undo label and key.** `label: "Tune '<clip name>' (Natural)"`,
   **`key: nil`** — an auto-correct pass is a structural edit. §8.
5. **It must refuse rather than pretend.** MIDI clip → the existing
   `pitchDetectionRequiresAudioClip`. Missing file → the existing teaching
   `invalidClipEdit`. Headless → `engineUnavailable`. **Reuse
   `detectClipPitch`'s refusals; do not write a second set of them.**
6. ⚠️ **APPLYING A PRESET TO A CLIP THAT ALREADY HAS EDITS IS A RE-DETECT AND
   REPLACE, AND §8.3 SAYS IT MUST WARN.** m23-q §7.4: re-detection *"is one undoable
   edit that replaces the whole set, and it must warn when it would discard existing
   edits rather than silently dropping them."* **In Increment B this is harmless**
   — the only way to have edits is a previous preset, so replacing one preset with
   another is exactly what the user asked for. **In Increment C it is load-bearing**:
   re-running a preset over HAND edits silently throws away the user's work.
   So: `autoCorrectClipPitch` takes an explicit `replaceExisting: Bool` (default
   true) and the UI asks first once hand-editing exists. **Decide it now, in the
   signature, so C is not a breaking change to a shipped verb.**

### 6.4 ⛔ THE AUDIBILITY GATE THIS INCREMENT MUST PASS — now runnable, because the render path is live

This tree has recorded **five** planted defects that passed `audible=true`, and one
loudness gate that passed a render clipping at +1.5 dBTP. So:

- **A preset action is not "shipped" until a render of a corrected clip differs
  from a render of the uncorrected clip *in the predicted direction*.** Identical
  bytes prove the axis did nothing; **distinct bytes prove nothing at all.** The
  assertion is on the physics: measure f0 of the rendered output at a segment's
  centre and assert it moved toward the scale degree, by roughly the predicted
  cents, within the ±12.90 floor of §5.5.3 — and assert an INVARIANCE control
  alongside it (`strength: 0` renders byte-identically; `.gentle` moves strictly
  less than `.tight` on the same source).
- **Check TRUE PEAK, not just loudness.** A meter does not look up.
- The harness already exists: `M23QComparisonPair.render(...)` in
  `Tests/DAWEngineTests/M23QCurveHarness.swift` renders constant-vs-curve pairs
  from any float32 source. It is test-target only, deliberately.

### 6.5 What the preset surface must NOT do

- ⛔ **No "tuning strength" slider in v1.** Four named results. The four presets
  exist precisely so a novice does not have to understand strength × retune speed.
  A slider is a Pro-density question for a later item, and §10 defers it.
- ⛔ **No vibrato depth control.** §5.5.5. Measured, not stylistic.
- ⛔ **No auto-application on import or record.** Tuning is a choice.
- ⛔ **No preset chip on a MIDI clip**, even greyed. Hidden, per the menu's own rule.

---

## 7. INCREMENT C — the interaction model. ✅ **SPEC RECEIVED 2026-09-23**

The user supplied six frames of SLIMZ TUNE X plus a written brief. §7.1's forks
are answered below. ⚠️ **Two of the answers contradict things §7.2 recorded as
settled, and one of them cannot be built at all in the current representation.
Both are called out rather than absorbed — see §7.5.**

### 7.1 THE USER'S BRIEF, VERBATIM

> "in editor, I should be able to drag the segments like note to higher or lower
> or make the narrower or expand, split the segment into smaller nonte segments
> and manipulate them similarly, zoom in/out, in each segment it should have more
> detailed curve that I should be able to smoth or add more cycles or pull tops
> or bottoms up or down, change the curve with mouse, not just some dots, but
> with say CMD + mouse I can change the shape the way I want."

### 7.2 WHAT IS OBSERVED IN THE FRAMES — and what is inference

⭐ **THE DISCIPLINE THAT MATTERS HERE: fluent prose about a picture is not a look
at the picture.** This tree shipped a viz caption saying "the octave rulers run
horizontally… same height" onto 44 videos when the rulers ran left-to-right. So
each line below is marked **[SEEN]** — legible in a frame — or **[INFERRED]** —
a reading of what the frames imply. Only [SEEN] lines may be treated as fact.

**Layout**
- [SEEN] Notes are purple rounded rectangles on pitch rows, dark background,
  faint horizontal semitone lines and vertical time gridlines.
- [SEEN] The detected pitch contour is a **white line that runs THROUGH and
  BEYOND the blob** — it is not clipped to the blob's bounds. In frame 5 the
  vibrato excursions extend well above and below the rectangle.
- [SEEN] A single small **filled dot sits at the top-centre** of each blob.
- [SEEN] Time ruler marks `10`, `10.2`, `10.3` — seconds, one decimal.
- [SEEN] Top right: a `1/16` chip and a `C#` chip, side by side.
- [SEEN] A persistent **horizontal tool palette along the bottom**, 9 slots:
  pointer, scissors, pencil, a note-ish glyph, a horizontal double arrow `↔`,
  a bar-chart glyph, a slider glyph, a gear, and a waveform glyph.
- [SEEN] The palette answers §7.1 fork 2: **IT IS A TOOL PALETTE, not one
  contextual tool.** The pointer slot is highlighted in frames 1 and 2.
- [SEEN] In frames 3–6 a **separate rounded purple button carrying the waveform
  glyph floats above the palette**, near the time ruler, clearly active.
- [INFERRED] That floating button is the engaged tool's indicator, detached from
  the palette; its position near the cursor suggests it follows the work area.

**The shape tool**
- [SEEN] Frame 4 shows a **large glowing CIRCLE centred on the contour inside the
  blob**, roughly one third of the blob's width across.
- [INFERRED] That circle is a **brush radius** — the region of the contour a drag
  affects — not a selection lasso; nothing in the frames shows it selecting.
- [SEEN] Frames 5 and 6 show a tooltip beside the cursor reading
  **`Vibrato 5.5 Hz ±93 c`** and **`Vibrato 7.8 Hz ±32 c`** respectively.
- [SEEN] Between those two frames the contour changes from FEWER, DEEPER cycles
  (5.5 Hz, ±93 c) to MORE, SHALLOWER cycles (7.8 Hz, ±32 c).
- [INFERRED] Therefore one drag controls both axes: **rate on one axis, depth on
  the other.** Which axis is which is NOT legible — the cursor sits in a similar
  place in both frames. **Pick one, make it discoverable, do not claim the video
  said so.**
- [SEEN] Frames 2 and 3 show the same note with a visibly FLATTER, smoother
  contour than frame 1 — consistent with a smoothing action having been applied.
- [INFERRED] Smoothing and vibrato-adding are the same tool in opposite
  directions, or two states of it. Not legible which.

**Not visible in any frame, and therefore still open**
- Double-click behaviour (§7.1 fork 3) — never shown.
- Multi-select (fork 4) — never shown; no marquee, no multiple highlights.
- Merge (fork 5) — the scissors implies split; nothing implies merge.
- What the top-centre dot DOES. It is drawn in every frame and never dragged.
- Keyboard (fork 7) — no key is pressed in any frame.

### 7.2b ⚠️ CORRECTION — THE FRAMES ARE ONE CONTINUOUS EDIT OF ONE NOTE

The user confirmed: *"this images are sequence of editing the segment."* Read as
a sequence rather than six independent screenshots, three of §7.2's inferences
change, and one of them changes what gets BUILT.

**The sequence, by timestamp:**
1. `10.11.31` — the note as sung: ~5 moderate vibrato cycles.
2. `10.12.16` — **the same note, contour now FLAT.** Cursor is down at the
   palette, on the waveform glyph.
3. `10.12.26` — still flat; the waveform tool is now ACTIVE (floating button).
4. `10.12.35` — the glowing circle appears on the contour. Still flat.
5. `10.12.45` — deep slow vibrato. `Vibrato 5.5 Hz ±93 c`.
6. `10.13.02` — more cycles, shallower. `Vibrato 7.8 Hz ±32 c`.

**⭐ WHAT THIS CORRECTS**

- **FLATTEN AND ADD ARE ONE TOOL, ONE CONTINUOUS RANGE.** §7.2 listed this as an
  inference; the sequence makes it the obvious reading — the same note goes
  sung → flat → synthesised within one session with one tool engaged.
- **⛔⛔⛔ THE GLOWING CIRCLE IS THE SCREEN RECORDER'S CLICK HIGHLIGHT. IT IS NOT
  PART OF THE PRODUCT AT ALL.** The user said so directly. **I read it as a
  product feature TWICE and designed from it both times** — first as a brush
  radius, then, after the sequence correction, as a grab affordance on a per-note
  control. Both readings are retracted. They are left visible here rather than
  edited away because the failure is the instructive part.
  ⭐⭐ **THE LAW: A SCREEN RECORDING'S OWN CHROME IS NOT THE UI BEING RECORDED.**
  Click halos, cursor rings, keypress overlays and zoom-follow are the capture
  tool's, and they are the most confident-looking pixels in the frame because
  they are drawn last and brightest. When a reference is a recording, the
  question "would this element exist if a person were sitting at the machine?"
  has to be asked of every glowing thing before it becomes a requirement.
  **What survives, and it is still useful:** the click landed ON THE CONTOUR
  LINE, left-of-centre inside the blob — so the tool is engaged by grabbing the
  curve itself, not a handle and not the blob body.
- **The per-note conclusion stands on its own evidence, not on the circle.** In
  frames 5 and 6 the new vibrato spans the WHOLE blob although the click was at
  one point inside it. A region-limited edit cannot do that. So
  `Vibrato 5.5 Hz ±93 c` is a property OF THE NOTE — Melodyne's Pitch Modulation
  tool, not a freehand pencil.
- **Rate and depth move together on one gesture** (5.5→7.8 Hz while 93→32 c).
  Which pointer axis drives which is STILL not legible; cursor travel between
  those frames is small and mostly vertical. **Still a choice to make, not a
  fact to read off.**

**⛔ AND THE USER'S WORDS ASK FOR SOMETHING THE FRAMES DO NOT SHOW.** *"change
the curve with mouse, not just some dots, but with say CMD + mouse I can change
the shape the way I want"* is FREEHAND, REGIONAL editing — a pencil over part of
a contour. The frames show a per-note parametric control. **These are two
different features and both were asked for.** Build them as two:

- **C5a — per-note vibrato** (rate + depth, one handle, the readout). What the
  frames show. Needs the generator.
- **C5b — freehand contour drawing** (⌘+drag reshapes the curve under the
  pointer). What the sentence asks for. Needs a per-note contour override, which
  is a bigger representation than rate+depth — it is a curve, not two numbers.

Do not let C5a's readout imply C5b exists, or vice versa.

### 7.3 THE BUILD ORDER

| | What | Depends on |
|---|---|---|
| **C1** | Blob drag: vertical = pitch. Snap to scale, ⌥ for free. | Increment A |
| **C2** | Blob edges: drag to narrow/expand. **§7.5 conflict 1.** | C1 |
| **C3** | Scissors: split a segment; the halves behave as C1/C2. | C1 |
| **C4** | Zoom in/out, both axes. | Increment A |
| **C5a** | Per-note vibrato: one handle, rate + depth, flatten↔add. **§7.5 conflict 2.** | C1 |
| **C5b** | Freehand ⌘+drag contour reshaping — a curve override, NOT two numbers. | C5a |

C1, C3 and C4 are buildable today against the shipped representation. C2 and C5
are not — see below.

### 7.4 What §7.2's old text got RIGHT and keeps

- No pitch DSP on the render thread. The brush must be cached-render + debounce.
- No bridged holes, no sub-13-cent readouts. ⚠️ **The `±93 c` and `±32 c` readouts
  in the frames are FINE** — those are depths of an excursion, not a claim to
  resolve a 13-cent difference.
- Clips addressed by id.
- **One `performEdit` on gesture END** (§8.2). A brush drag is the worst possible
  case for per-tick commits: it re-keys the render cache at pointer rate and the
  vocal goes silent for the whole gesture.

### 7.5 ⛔⛔ TWO CONFLICTS THE USER SHOULD SEE BEFORE EITHER IS BUILT

**CONFLICT 1 — "make the narrower or expand" is per-note TIMING, which §10 puts
in Phase 3.** `NoteSegment.timeStartDeltaSeconds`/`timeEndDeltaSeconds` already
exist and are deliberately untouched by Phase 2. This is not a technical
objection — it is a scope one, and the user can simply move it. What it costs:
per-note time-stretch is a DIFFERENT operation from pitch (it moves audio in
time, so it interacts with clip length, neighbouring notes, and the stretch
ratio the render already applies). Cheap to draw, not cheap to render.

**CONFLICT 2 — ⛔⛔ "add more cycles" CANNOT BE EXPRESSED BY `vibratoScale`, AND
THIS IS A REPRESENTATION GAP, NOT A UI GAP.** `NoteSegment.vibratoScale` is a
MULTIPLIER on the detected contour. Multiplying a contour changes how deep its
existing wobble is; it cannot change the RATE, and on a note sung with no vibrato
it produces nothing however large it gets — `0 × anything = 0`.

The frames show `5.5 Hz ±93 c` becoming `7.8 Hz ±32 c`: **the rate changed.**
That is synthesis, not scaling. Delivering it needs new fields on `NoteSegment`
(a vibrato rate in Hz and a depth in cents, absolute rather than relative), a
decision about whether synthesised vibrato REPLACES or ADDS TO the sung contour,
and a renderer that can generate it. §5.5.5's "keep/flatten, never a calibrated
depth" was the right call FOR A MULTIPLIER and stops being the right call for a
generator — it does not block this, it describes a different mechanism.

⚠️ **AND THE EXISTING MEASUREMENT STILL BITES:** `vibratoScale` was measured
returning **1.06×–1.20× deeper than asked**. A generator must be measured the
same way before any number is printed next to a cursor, or the `±93 c` readout
is decoration.

## 8. Undo — how a drag coalesces, measured against the mechanism

### 8.1 The mechanism as it actually works (read, not assumed)

`Sources/DAWCore/UndoJournal.swift`:

- Coalescing is a **sliding time window**: `static let coalescingWindow: Duration =
  .milliseconds(800)`, measured from `UndoEntry.lastMergedAt`, which is refreshed on
  **every** absorbed edit (`:134-137`). So a continuous drag coalesces indefinitely;
  an 800 ms pause starts a new entry even with the same key.
- Merging requires **the stack top's key to equal the incoming key**. A different
  key pushes a new entry, which is why per-segment keys give per-note undo for free.
- `key == nil` never coalesces.
- A `coalescingBarrier` is set after undo/redo, so the first edit after an undo
  never merges onto a restored top.
- `ProjectStore.performEdit` (`:7764`) journals **only when `captureEditState()`
  actually changed** — a no-op edit is silent, and `editEventSeq` still ticks for
  coalesced edits so a debounced subscriber never misses one.
- ⚠️ `performEdit` is **synchronous**. §6.3.1.

### 8.2 The two in-tree drag precedents disagree — pick one, and know why

| Precedent | Commit cadence | Consequence |
|---|---|---|
| `AutomationLaneEditor` (`Timeline/AutomationLaneEditor.swift:441-456`) | `onCommit` on **every drag tick**, plus a final commit on end | Relies entirely on the store's 800 ms key coalescing to make a drag one undo step. Live value is always in the store, so any observer sees it. |
| `PianoRollView` | *"the draft is submitted through `onCommit` on gesture END only (never per tick)"* | One store call per gesture. Nothing observes the intermediate state. |

**DECISION for the pitch editor: the `PianoRollView` cadence — a local `draft` in
the observable model, ONE `performEdit` on gesture END.**

⭐⭐ **THIS REVERSES MY FIRST ANSWER, AND THE THING THAT REVERSED IT IS THE REASON
TO WRITE IT DOWN.** I initially chose the `AutomationLaneEditor` per-tick cadence
because "the 250 ms render debounce wants a settled value". **That argument is
exactly backwards, and `PlaybackGraph` says so in its own words.** Read directly:

> `StretchResolution` … `case pending` — *"Render in flight (or failed): the clip is
> **SKIPPED** — honest silence, never wrong-speed audio (spec §5)."*
> (`Sources/DAWEngine/PlaybackGraph.swift:78-83`, consumed at `:953` as
> `case .pending, nil:`)

And `ClipKey` now carries `pitchEditSetHash` — deliberately, because without it
*"a correction the user made, rendered correctly, and never heard"*. Put those two
facts together:

> **Per-tick commits would re-key the clip at pointer rate. The render would never
> be ready during the gesture. `.pending` skips the clip. So the vocal would go
> SILENT for the entire duration of every drag.**

Gesture-end commit keeps the previous render playing until release, then re-keys
once. That is the only cadence that is audible during a drag.

**Why the two counter-arguments do not survive:**

- *"The value must be visible while dragging."* It is — but not via the store.
  `PitchEditorModel` is `@Observable` and lives in DAWAppKit, so the readout, the
  blob and any `debug.pitchEditor` echo all read the **draft**. This is precisely
  where `PianoRollView` differs and why its comparison misleads: its draft is
  `@State private` inside a View, unreachable from a menu or an echo. **Ours is not
  a View's private state. That single structural difference removes the only real
  advantage per-tick commits had.**
- *"`AutomationLaneEditor` does it and ships."* It does — and **there is no offline
  render behind an automation lane.** A breakpoint drag changes a gain value that
  takes effect immediately. A pitch drag changes a cache key that invalidates an
  audio file. The precedent does not transfer, and this is the same "mechanism ≠
  cause" trap that makes a shared shape look like a shared argument.

**Coalescing still does its job**: two successive drags on the SAME segment inside
800 ms fold into one undo entry via `PitchCorrectionUndoKey.segment`, and a drag of
a different segment starts a new one. The keys in §8.3 are unchanged by this
reversal — only the number of times they are submitted changes.

⚠️ **This decision is REVISITABLE, and §7 is where it gets revisited**, because it
is entangled with live audition: if the video shows scrubbing that must be heard
mid-gesture, the answer is still **not** per-tick commits — it is the
cached-render + debounce policy m23-q §7.6 already decided, and **never** signalsmith
on the render thread (§5.9). Neither Increment A nor B has a drag, so nothing ships
on this decision before it can be re-examined with the video in hand.

### 8.3 The keys

`Sources/DAWCore/PitchCorrection.swift:551` already supplies exactly three:

```
PitchCorrectionUndoKey.segment(clipID:segmentID:)   // "pitch.segment:<clip>:<segment>"
PitchCorrectionUndoKey.drift(clipID:segmentID:)
PitchCorrectionUndoKey.vibrato(clipID:segmentID:)
```

| Operation | Key | Result |
|---|---|---|
| Drag one note's pitch | `.segment(clipID:segmentID:)` | Whole drag = one undo step. Dragging a **different** note starts a new step, because the key differs. |
| Drag drift / vibrato | `.drift` / `.vibrato` | Same, independently — so correcting pitch then flattening drift on one note is two undo steps, which is right: they are two decisions. |
| Apply a preset (§6) | **`nil`** | Never coalesces. Precedent: `ProjectStore.swift:1669` — *"the track-chain rule: a deliberate on/off is its own edit"*. |
| Clear all pitch edits | **`nil`** | Same. Returns to byte-identical playback. |
| Re-run detection | **`nil`**, and ⚠️ **it must WARN when it would discard existing edits**, not silently drop them (m23-q §7.4). |
| Split / merge a segment | **`nil`** | Structural. |

### 8.4 ⛔ THE GAP: multi-select has no key, and cannot get one from a guess

m23-q §7.4 requires *"Multi-select edits are **one** entry over N segments (the
m23-g2 `clip.moveMany` group-verb precedent), not N entries."*
**`PitchCorrectionUndoKey` provides no group key.** Three per-segment keys cannot
express it: N segments dragged together would push N entries, and undo would peel
them off one at a time — the exact failure §7.4 names.

**Whether multi-select exists at all is a §7.1 question the video settles.** So:

- **If multi-select ships**, `PitchCorrectionUndoKey` gains a fourth constructor —
  `group(clipID:selectionToken:)` — where `selectionToken` is stable for the life
  of one selection, so a second drag of the *same* selection coalesces and a drag
  of a *different* selection does not. Add it to `PitchCorrectionUndoKey`, not to
  the view: that enum is the one home, and a key string spelled at a call site is
  the divergence it exists to prevent.
- **Until then, do not add it speculatively.** An unused constructor with no caller
  is a claim nothing checks.

---

## 9. Command surface — every capability gets a wire verb, an MCP tool and a test

CLAUDE.md's invariant, and m23-q §7.7's: **UI and the control protocol both converge
on `ProjectStore`. Additive only — no existing verb renamed or repurposed.**

### 9.1 New verbs

| Verb | Increment | Params | Notes |
|---|---|---|---|
| `clip.autoCorrectPitch` | B | `clipId`, `preset` (`gentle`/`natural`/`tight`/`hardTune`), `scale?` `{tonic, mode}` | m23-q §7.7's phase-1 headline, now preset-shaped. Async, like `clip.transcribe`. Returns the resulting segment count + the scale actually used. |
| `clip.clearPitchEdits` | B | `clipId` | One undo entry; returns to byte-identical playback. |
| `clip.getPitchEdits` | B | `clipId` | Read the stored set. Needed so an agent can verify its own write — a setter's return is not proof it took. |
| `view.openPitchEditor` | A | `clipId` | The production-tier door, `view.selectClip`'s sibling. Response `{clipId, trackId, opened, reason, workspace}`. ⚠️ Handler lives in `Sources/DAWApp/ViewUIWireSurface.swift` (it needs SwiftUI state); the typed seam lives in `Sources/DAWControl/ViewUISurface.swift` — DAWControl must stay headless-testable. |
| `debug.pitchEditor` | A | — (read) / staging keys | The echo: **reports what was DRAWN** — open clip id, blob count, the visible midi range, the four-state status, the resolved header prose. §12. |

Per-note verbs (`clip.setNotePitch`, `clip.splitNote`, `clip.mergeNotes`) are
**Increment C** and their exact shape follows the interaction model. Naming is
reserved here so nothing else claims it.

### 9.2 ⛔ `view.selectClip` starts lying, and the fix is additive

§2.6. `audio-clip-has-no-editor` is pinned in `Tests/DAWControlTests/ViewSurfaceCommandTests.swift`,
`mcp-server/test/view-surface.test.ts`, `mcp-server/src/server.ts` **and the shipped
`claude-plugin/server/index.mjs`**. The decision:

- **Do NOT change the string.** Every pin stays green, and the plugin bundle the
  user's agents actually load does not have to be regenerated for a correctness fix
  it is not the cause of.
- **Keep `editorOpen` meaning "the piano roll is on screen"** — it is derived from
  `openEditorClip`, which is that question's one home.
- **Add** `pitchEditorOpen: Bool` to the response and a fifth reason value
  `pitch-editor-open` for the case where the selected audio clip is the one the
  pitch editor is open on. `view.selectClip` still does **not** open the pitch
  editor (§3.6: explicit act); `view.openPitchEditor` does.
- **Update the PROSE** — the MCP tool description's *"audio has no note editor …
  use clip_analyze_audio or clip_transcribe for audio"* becomes *"audio has no NOTE
  editor; open the pitch editor with `view_open_pitch_editor`"*. Prose is not a
  pinned value.
- ⚠️ **The plugin bundle is a separate artifact from the source tree.** A "shipped"
  claim must be checked against `claude-plugin/server/index.mjs`, and `/plugin update`
  is the **user's** action. Do not tick a roadmap box on the source tree alone.

### 9.3 MCP tools

One tool per verb, mechanical naming (`clip_auto_correct_pitch`,
`clip_clear_pitch_edits`, `clip_get_pitch_edits`, `view_open_pitch_editor`).
`debug.*` is **not** exposed as an MCP tool (the standing tier rule).

⚠️ **Payload arithmetic, from `PitchDetection.swift`'s own header:** SwiftF0 emits
62.5 frames/s, so a 3-minute window is ~11,250 frames ≈ **659 KB of JSON**. That
already applies to `clip.detectPitch`. `clip.getPitchEdits` returns **segments**
(~450 for a 3-minute vocal, ~200 bytes each ≈ 90 KB) — an order of magnitude
smaller, and it must **not** carry the contour. The contour is regenerable analysis
and m23-q §7.8 forbids persisting it.

⚠️ **Do not quote a tool or command count from memory.** `node scripts/gates/doc-count-drift.mjs`
is the pin; `grep -c 'registerTool('` lies.

---

## 10. What is NOT in scope for Phase 2 — stated plainly

By §11.2's own instruction: *"Treat the number as covering an editor with the
operations listed and nothing more."*

**Out of scope, deferred to a named later phase:**

1. **Per-note TIMING.** `timeStartDeltaSeconds` / `timeEndDeltaSeconds` stay at 0
   and stay untouched. **Phase 3.** Even if the TUNE X video shows horizontal
   dragging — that is a Phase-3 capability appearing in a Phase-2 reference, and
   it does not promote itself.
2. **Per-note FORMANT and GAIN.** `formantOffsetSemitones`, `amplitudeDb`. **Phase 4.**
3. **Vibrato SHAPING** (as opposed to keep/flatten). **Phase 4**, and §5.5.5 says
   the engine cannot honour it today regardless.
4. **Word boundaries from `clip.transcribe` feeding segmentation.** **Phase 4**, and
   it carries a sequencing trap worth remembering now: `clip.transcribe` refuses a
   clip with `stretchRatio != 1` (`ProjectStore+Transcription.swift:50-52`), so word
   boundaries must be fetched **before** any Phase-3 timing edit.

**Out of scope, no phase — explicitly not planned:**

5. **Live / real-time pitch correction.** m23-q §7.6, §11.3. Offline only.
6. **Polyphonic separation** (Melodyne DNA). Different problem class, never asked for.
7. **Editing pitch on a COMPED clip and having it flow back to lanes.** m23-q §7.5
   defers this as a two-way binding; edits after `take.flatten` live on the
   flattened clip.
8. **A free strength/retune slider.** §6.5. Four named results in v1.
9. **A Simple/Pro density chip.** §5.8, unless Increment C's modes genuinely differ.
10. **ARA hosting.** `m23-dh` is in DEEP BACKLOG on the user's explicit call and
    re-enters only on a user decision. Do not pick it up as "the natural companion".
11. **Any second home:** no second stretch facade, no second render cache, no second
    cache-key derivation, no second whole-clip pitch path, no second onset detector,
    no sidecar for detection, no persisted f0 contours in `.dawproj`. m23-q §7.8.

---

## 11. Failure modes — how this surface breaks, and the mitigation

| # | Failure | Why it is likely here | Mitigation |
|---|---|---|---|
| **P1** | **A preset writes an edit set that makes no sound, and the tick says SHIPPED.** | It was the live risk when this doc opened (R4 unmet) and R4 has since landed — which is exactly why nobody should assume it. The write path *looks* successful either way. Identical shape to `drumKit` without `kind`. | §4.1's probes, re-run rather than quoted; §6.4's physics-asserting gate with its invariance control; **never `audible=true` as the whole gate — five planted defects have passed it.** |
| **P2** | **Data loss on split/trim/move/flatten — and the ⭐ SHARPER FORM: a carry that REBASES rather than copies.** | The rebuild sites are hand-maintained argument lists the compiler cannot check, and `windowedGainEnvelope`/`windowedControllerLanes` sit three lines above every one of them doing exactly the re-anchoring that would be WRONG here. | ✅ Disarmed — `Tests/DAWCoreTests/PitchEditCarryTests.swift` pins the LITERAL second values, not mere presence. ⚠️ **A nil-check would pass against a rebased carry, which leaves a healthy-looking non-nil set in place.** Any NEW `Clip(...)` rebuild site needs a leg in that suite; census by function, never by quoting the site count — it already moved from six to seven. |
| **P3** | **The contour is drawn across holes and invents pitch.** | A single `Path` is the obvious implementation and it is wrong. | §5.5.1; a test asserting `contourSegments.count == voicedRuns.count` on a fixture with a planted hole. |
| **P4** | **"No notes found" is indistinguishable from "the engine is not running".** | Both render as an empty editor if nobody writes the prose. | §5.7's four-state table; `debug.pitchEditor` echoes the state string; a capture gate photographs both. |
| **P5** | **A cents readout implies precision the chain does not have.** | Doubles format to 4 decimals by default. | §5.5.3: whole cents, ±12.90 floor documented at the formatter. |
| **P6** | **A third `.onKeyPress` claimant starts a focus fight.** | m23-al measured exactly this between the arrange and the roll: a coin flip. | §7.1.7 — route through the existing policy homes; never add a raw handler. |
| **P7** | **`openEditorClip`'s census reddens and someone "fixes" it by bumping the number.** | Adding a pitch pane touches neighbouring code. | §3.6 — the new accessor must not mention `openEditorClip`. If the census moves, that is the finding, not the obstacle. |
| **P7b** | ⭐ **THE VOCAL GOES SILENT FOR THE WHOLE DRAG.** | Committing per drag tick re-keys `ClipKey.pitchEditSetHash` at pointer rate, the render is never ready, and `StretchResolution.pending` **SKIPS the clip** (`PlaybackGraph.swift:78-83`, `:953`). The per-tick cadence looks right because `AutomationLaneEditor` uses it — but automation has no offline render behind it. | §8.2: ONE `performEdit` on gesture END; the live readout comes from the `@Observable` draft, not from the store. **I made this mistake in the first draft of this doc.** |
| **P8** | **Someone proposes live pitch preview on the render thread for drag feedback.** | It is the obvious way to make a drag feel good. | §5.9 / m23-q §7.6 (F12) — forbidden, with the reasons. **Flag it.** |
| **P9** | **The editor is opened on a drum loop or a full mix and draws confident nonsense.** | SwiftF0 is monophonic and will report *something*. | §3.6 (explicit open, never auto); §5.7's "no notes found" copy names the limit in plain words; low median confidence dims the blobs. |
| **P10** | **A 4-minute vocal re-renders whole on every note tweak.** | `StretchRenderCache` renders the ENTIRE source by design (`:9-14`). | Accepted for v1 by m23-q §10.3. **`ClipShimmer` makes it visible rather than mysterious**, and the 250 ms debounce + latest-wins keeps it from piling up. Measure and publish the cost (m23-q leaves it explicitly unmeasured). |
| **P11** | **A rename orphans something.** | The lane-orphan lesson: automation lanes are NAME-keyed and a rename orphans saved automation. | `NoteSegment` is **UUID-keyed** and edits are keyed by segment id, so this class of failure does not apply — recorded so nobody re-derives it as a risk. |

---

## 12. Test strategy

⚠️ **`DAWApp` has no test target.** That single fact drives the whole strategy:
anything that can be tested must live in `DAWAppKit` or `DAWCore`, and anything
that cannot must be reachable by a wire echo or a capture. **A spy gate beats a
source-shape gate**, every time.

Run with `./scripts/test.sh`, never bare `swift test`.

### 12.1 `Tests/DAWAppKitTests/PitchEditorModelTests.swift` — the bulk

Pure, headless, no store, no engine, no actor where possible.

- **Geometry round-trips.** `sourceSecond(forX: x(forSourceSecond: s)) ≈ s` across
  the clip window, at several zoom levels and a non-trivial tempo map.
  `midi(forY: y(forMidi: m)) ≈ m` across the range, on `Double` inputs — including
  non-integer ones, which is the assertion that would fail against
  `PianoRollModel`'s integer mapping and is therefore the pin for §3.3.1.
- **Blob derivation** from a synthetic `[ClipPitchFrame]`: N voiced runs in ⇒ N
  blobs out, centres at the median, sub-`minimumNoteSeconds` (0.06 s) runs dropped.
- **⭐ THE HOLE TEST, with a positive control.** A contour with a planted unvoiced
  stretch yields **two** polylines, not one; and the control — the same contour
  with the hole filled — yields **one**. *An absence that confirms the hypothesis
  must be positive-controlled.*
- **The 1.5-frame-period gap rule** ends a run even with no explicit `nil` frame.
- **Vertical range defaulting**: detected range + padding; the all-unvoiced case
  falls back rather than producing an empty or 128-row range.
- **State classification**: the four §5.7 states are a total function of
  (in-flight, error, run count), and the prose strings are asserted **by value**,
  not by "non-empty" — a placeholder passes a non-empty check.

### 12.2 `Tests/DAWCoreTests/` — the store leg (Increment B)

- `autoCorrectClipPitch` writes a non-empty `pitchEdits`; `clearClipPitchEdits`
  returns it to `nil` (**nil, not empty** — `Clip.init` normalises empty to nil so
  the two states cannot round-trip into each other).
- Each preset produces the documented `(strength, retuneMs, preserveVibrato)`, and
  `hardTune` alone flips `preserveVibrato`.
- **Undo**: one preset application = exactly one journal entry with `key == nil`;
  two applications = two entries (no coalescing). Assert via `lastEditEvent.seq`
  and `UndoHistory.undo`.
- **Refusals**, each by its exact error case: MIDI clip, missing file, headless.
- **✅ R2 REGRESSION — ALREADY SHIPPED as `Tests/DAWCoreTests/PitchEditCarryTests.swift`; keep it green and do not write a second one.** It asserts **the literal second values are unchanged**, not that a set is present — §2.2.2 — because a nil-check passes against a rebased carry and a rebased carry is the more likely bug. ⚠️ **If a new `Clip(...)` rebuild site is added anywhere in `Sources/DAWCore`, it needs a leg in that suite.** Census by function (`grep -rn "pitchEdits: " Sources/`), never by quoting its site count — that count already moved once.
- **Persistence**: a project with no pitch edits saves **byte-identically** to a
  pre-m23-ap save (the `gainEnvelope` omit-when-empty rule). ⚠️ **A byte gate over
  a SAVE is blind to a `Codable` decode default — this tree proved it by planting
  one.** So pair it with a value assertion: save → reopen → the set is equal
  field-for-field, through **`ClipDocument` and both `ClipDocument`→`Clip`
  reconstructions** (`ProjectDocument.runtimeState` **and**
  `TakeGroupDocument.takeGroup`).

### 12.3 `Tests/DAWControlTests/` + `mcp-server/test/`

- Each new verb: happy path, every refusal, unknown-key rejection
  (`rejectUnknownKeys` **first**, before the `guard let viewUI` — the shipped
  ordering law).
- `view.selectClip`'s four existing pins stay green (§9.2). The **new** reason and
  the new boolean get their own rows.
- MCP: one tool per verb, and the command/tool bijection audit stays green.

### 12.4 The looked-at leg — because a UI phase is not done until someone looked

1. `debug.pitchEditor` echoes **what was drawn**: open clip id, blob count, visible
   midi range, the state string, the resolved header prose. ⭐ **Resolve those at
   ONE home in `AppModel` and pass them in as plain values** — the `EQCurveEditor.help`
   / `EffectHonestyNote` law, so the echo reports the value the view drew rather
   than a re-derivation that could agree with itself and with nothing on screen.
2. `view.capture` a real vocal clip in all four states. **Look at the PNGs.**
3. ⚠️ **`debug.captureUI` is ~3.5 fps and cannot film motion.** If a drag is ever
   demonstrated, record with `scripts/video/screenrec/`, never stills on a timer.

### 12.5 The listening leg (Increment B) — and how to ask for it

The preset numbers are provisional by their own doc comment. The user's standing
rule: **ship 3–4 options differing on ONE axis each, never one result — their pick
IS the feedback.** So the listening round is:

> The same vocal phrase, four renders, one per preset, in ladder order with Hard
> Tune last, each labelled with its `summary` line and nothing else.

⚠️ **Never ship a sound demo without checking it can BE heard**, and check **true
peak**, not only loudness (§6.4). And the user is not a musician: their words
describe, they do not diagnose.

⛔ This leg needs a dry vocal. **It is the same asset R4/m23-ap-5 needs, so ask
once and use it for both.**

---

## 13. Xcode, entitlements, signing — nothing here needs them

Explicitly, because the constitution asks for this to be flagged:

- **No full-Xcode dependency in any increment.** `swift build` + `./scripts/test.sh`
  + `swift run DAWApp` cover it.
- **No entitlements.** No microphone, no sandbox exception, no network.
- **No AUv3, no code signing.** m23-q §8.2 already established the milestone needs
  none.
- **No new dependency of any kind.** ONNX Runtime and SwiftF0 are already vendored
  and shipping; this is UI over calls that already work.
- ⚠️ The one packaging note that IS real: the app bundle and the
  `claude-plugin/server/index.mjs` bundle are **separate artifacts from the source
  tree**, and `/plugin update` is the user's action (§9.2).

---

## 14. Open questions that need the USER'S word — offer, never assume

1. ⏸ **The TUNE X video.** Volunteered, not yet sent. Blocks §7 only; two
   increments are unblocked in front of it. A nudge, not a ruling.
2. ⛔ **A dry vocal, 10–30 s, for E2 (`m23-ap-5`).** ⚠️ **Re-scoped by §4: this no
   longer blocks code.** The render path landed without it. What it gates is the
   QUALITY CLAIM — whether curve-driven correction sounds natural on a real voice,
   which `m23-q` §11.4 calls the milestone's largest unknown and which cannot be
   delegated to an assertion. It doubles as §12.5's listening source and `m10-p-6`'s
   gate. **Still the highest-leverage single ask, and now a lower-stakes one:** it
   validates shipped code rather than unblocking unwritten code.
3. **Does "preset actions" mean the four presets, or something else?** This doc
   reads the phrase as `PitchCorrectionPreset`'s four. If the user meant something
   nearer "one button that tunes the vocal", `.natural` is the one-button answer and
   the other three become a submenu. **Offer both shapes; do not pick.**
4. **Should the editor open on a take LANE clip?** m23-q condition 4 makes it free
   at the model layer (`TakeLane.clip` IS a `Clip`, addressed by id). The UI door
   from the take-lane surface is m23-q's Phase 4 §7.5 item. Cheap to add, but it is
   a product decision about where the vocal workflow starts.

---

## 15. Implementation order — the concrete item list

| Item | Increment | Needs | Route | Files |
|---|---|---|---|---|
| **p2-a** | A | R0, R1 | `swift-app-engineer` | `Sources/DAWAppKit/PitchEditorModel.swift` + `Tests/DAWAppKitTests/PitchEditorModelTests.swift`. **Headless model only, no view.** Ships with §12.1's full suite including the positive-controlled hole test. |
| **p2-b** | A | p2-a | `ui-design-engineer` | `Sources/DAWApp/PitchEditor/PitchEditorView.swift`, `PitchRulerSidebar.swift`; the pane branch + `openPitchEditorClip` in `DAWProApp.swift`/`ContentView.swift`; `EditorSurface.pitchEditor` + a new case on **each** of the two `Reason` enums + the router's third term (`Sources/DAWAppKit/EditorSurfaceRouter.swift`, `Tests/DAWAppKitTests/EditorSurfaceRouterTests.swift`). ⚠️ **Census the `EditorSurface` readers by BUILDING, not by grepping — §3.6 shows the naive pattern over-counts ≈ 6×.** |
| **p2-c** | A | p2-b | `mcp-integration-engineer` | `view.openPitchEditor` + `debug.pitchEditor` + the MCP tool + §12.3/§12.4 gates. **Then look at the captures.** |
| ~~p2-d~~ | — | — | — | **✅ R2 — ALREADY DONE**, landed mid-session by a concurrent agent (`PitchEditCarryTests.swift`). Retained in this table only so nobody re-files it. |
| **p2-e** | B | **R3 only** — R4 is done (§4) | `swift-app-engineer` | `Sources/DAWCore/ProjectStore+PitchCorrection.swift` (`autoCorrectClipPitch` / `clearClipPitchEdits` / `getClipPitchEdits`), the context-menu door, `clip.autoCorrectPitch` + `clip.clearPitchEdits` + `clip.getPitchEdits` + MCP tools, §6.4's physics gate. **Now independent of the user.** |
| **p2-g** | Q1 | a dry vocal from the user | `qa-test-engineer` + a human | Run E2 (`m23-ap-5`) and §12.5's four-preset listening round off the SAME asset. **Quality gate — it does not block p2-e from shipping, it blocks the CLAIM.** |
| **p2-f** | C | all + the video | re-brief `daw-architect` first | §7 is unfilled by design. **Do not start from a guess.** |

**p2-a → p2-b → p2-c is a complete, shippable, user-visible slice that needs
nothing from the user and nothing from the DSP lane.** Start there. ⭐ **And p2-e is
now a close second rather than a distant one** — the render integration that used to
gate it landed mid-session, so the four preset actions the user asked for are one
store operation away.

---

## 16. Sources — all read directly, 2026-09-22

**The requirement:** `docs/research/m23-q-pitch-correction-design.md` §3.1–3.7,
§7.1–7.8, **§11.2 (lines 804–810, quoted verbatim in §1)**, §11.3, §12 conditions
1–6, "Deliberately left unresolved" ·
`docs/research/m23-q-phase0-curve-experiment.md:7,19,27,259,282-296` (E2 unrun; the
measured bounds) · `docs/ROADMAP.md:1561,1562,1570,1988,2000,2007,2010,2031,3533`
(m23-ap-1…5, m35-c) · `docs/DESIGN-LANGUAGE.md:35` (Panels/density), `:350-356` (Rules 1–6).

**The model:** `Sources/DAWCore/PitchCorrection.swift` (header's five measured
bounds; `NoteSegment`, `PitchEditSet`, `PitchCorrectionScale`,
`PitchCorrectionCurve.make`, `PitchAutoCorrect.voicedRuns`/`editSet`,
`PitchCorrectionUndoKey:551-566`, `engineMinimumRetuneMs:436`,
`retuneMsRange:440`, `currentAnalysisVersion:444`) ·
`Sources/DAWCore/PitchCorrectionPresets.swift` (all four presets, `ladder:99`) ·
`Sources/DAWCore/PitchDetection.swift:1-110` (`ClipPitchFrame`, the honest-absence
precondition, the 659 KB payload arithmetic) ·
`Sources/DAWCore/ProjectStore+PitchDetection.swift` (full — read-only, uncached,
every refusal) · `Sources/DAWCore/Model.swift` (the uncommitted `Clip.pitchEdits`
and its six-site census; `sourceWindowSeconds:746`) ·
`Sources/DAWCore/TempoMap.swift:181,190,201`.

**Undo:** `Sources/DAWCore/UndoJournal.swift:71-141` (`coalescingWindow:91` = 800 ms,
sliding from `lastMergedAt`, the barrier) · `Sources/DAWCore/ProjectStore.swift:1-40`
(`EditEvent`) and `:7764-7786` (`performEdit`, **synchronous**).

**UI precedents:** `Sources/DAWApp/Timeline/AutomationLaneEditor.swift` (full — the
draft/onCommit cadence, `DrawContext`, the glow recipe, the three-claimant DELETE
history) · `Sources/DAWApp/Mixer/EQCurveEditor.swift:1-110` (the layered-Canvas +
headless-model law; the "tooltips are invisible to capture" lesson) ·
`Sources/DAWApp/Timeline/ClipWaveform.swift` (full) ·
`Sources/DAWApp/PianoRoll/PianoRollView.swift:1-120` (commit-on-end;
the store-free value-input contract) · `Sources/DAWApp/PianoRoll/KeyboardSidebar.swift:1-60`
(the one light surface; the integer-pitch coupling) ·
`Sources/DAWAppKit/PianoRollModel.swift:260-270` · `Sources/DAWApp/Mixer/EffectEditorOverlay.swift:1-75`
and `Sources/DAWApp/ContentView.swift:415-500` (the overlay mould) ·
`Sources/DAWApp/ContentView.swift:755-860,1640-1790` (the pane mount,
`selectedMIDIClip`, `selectedAudioClip`) ·
`Sources/DAWApp/Timeline/TimelineLanesView.swift:3958-4030` (the clip context menu
and the "Chop to Pads" audio-only gate), `:3273,4203` (`ClipShimmer`).

**Surface routing:** `Sources/DAWAppKit/EditorSurfaceRouter.swift` (full) ·
`Sources/DAWApp/DAWProApp.swift:3155-3225` (`openEditorClip`, `activeEditorSurface`,
`openEditorSurface`) · `Tests/DAWAppKitTests/EditorSurfaceOwnershipSiteTests.swift:545-648`
(**the census pinned at 14**).

**Wire:** `Sources/DAWControl/Commands.swift:372-442,566-569,777,4783-4848,8171-8320`
· `Sources/DAWApp/ViewUIWireSurface.swift:21,153-185` ·
`Tests/DAWControlTests/ViewSurfaceCommandTests.swift:258-284` ·
`mcp-server/test/view-surface.test.ts:158,195` · `mcp-server/src/server.ts:5905` ·
`claude-plugin/server/index.mjs:46533` (the shipped bundle).

**E2:** `Tests/DAWEngineTests/M23QE2RenderTests.swift` (untracked; env-gated,
needs a real vocal) — and `M23QComparisonPair.render(...)` in
`Tests/DAWEngineTests/M23QCurveHarness.swift`.

**⭐ Landed DURING this doc's writing, re-read at 2026-09-22 before §2.1/§4 were
corrected:** `Sources/DAWEngine/Stretch/StretchRenderCache.swift:32-107,201-202,341-355`
(`Params.pitchEdits` + `pitchEditSetHash`, the widened `needsRender`, the digest in
the on-disk key, the curve subsuming `params.semitones`) ·
`Sources/DAWEngine/Stretch/StretchCurvePlan.swift:1-25,117` (the ONE output-frame ↔
source-second home and the cache digest) ·
`Sources/DAWEngine/PlaybackGraph.swift:60-75` (`ClipKey.pitchEditSetHash` — without
it, *"a correction the user made, rendered correctly, and never heard"*) ·
`Tests/DAWCoreTests/PitchEditCarryTests.swift:1-40` (seven rebuild sites; the
identity-not-presence assertion; the `CompFlattener.flatten` correction to §7.5) ·
`Sources/DAWCore/Model.swift:699,721-738,810` · `Sources/DAWCore/Takes.swift:259` ·
`Sources/DAWCore/AudioQuantize.swift:320` · `Sources/DAWCore/ProjectDocument.swift:266,1476,1512,1536,1643`.

**⚠️ Not re-derived here, deliberately:** the wire command total and the MCP tool
total. `node scripts/gates/doc-count-drift.mjs` is the pin; a `grep -c` on
`registerTool(` lies. Any item landing a verb re-measures rather than quoting.

---

## 17. Addendum 2026-09-24: automatic note splitting has no owner (item p2-seg)

> **STATUS 2026-09-24: SHIPPED in `109b483`** (S1, R1, L, S2, S2-close). Everything below is the
> filing record; the design, results and follow-ups (p2-seg-F-detect, F-tail, F-metric) live in
> `docs/design/2026-09-24-pitch-note-splitting.md` (§15 L, §16 S2-close).

**Found by measurement on the user's own take**, not by review. The busy-line check
(2026-09-24, audio-dsp-engineer; the vibrato doc §18.5 has the full record) found the detector
honest on this take and found the Hard Tune risk in SEGMENTATION instead.

**The mechanism** [READ]. `PitchAutoCorrect.voicedRuns` (`PitchCorrection.swift:1605-1699`) makes
one note of each unbroken voiced run. Its own doc comment says this is deliberate and temporary:
it "does NOT split a legato phrase where the singer changes note without stopping", and it is
"THE SEAM PHASE 2 REPLACES". Hard Tune then flattens the whole run to its snapped median
(`:1721`, `shapeScale = 0` at strength 1).

**What it does on the user's take** [MEASURED in two renders, exact YIN: the handoff page's
`pitch-04-hard-tune.mp3` and the rebuilt bundle's `livelook-hardtune.wav`]. A slide into a held note
becomes ONE note pinned near the middle of the slide. At 22.61–23.22 s a D#2→B2 slide is pinned to G#2: the start moves
+4.97 st and the held tail −2.23 st on average. 4 of 42 notes move more than 3 st and 11 more
than 2 st, up to 5.06 st. Gentle, Natural and Tight shift each run by one constant, so they are
not affected in the same way.

**Why it is unowned.** m23-q §11.2 puts "segmentation into notes" inside Phase 2 (1.5–2 weeks),
and m23-q F1 says this is where Melodyne-class tools actually fail. §10 above does NOT defer it.
But §7.3's build order (C1–C5b) and §15's item list (p2-a…p2-g) are all manual editing. The
manual route exists today: cut the note with C3's scissors (`clip.splitNote`) and drag each half.

### p2-seg — split a voiced run where the singer changes note

- **Route:** `daw-architect` first, for a SHORT design (skeleton on disk first, a read budget,
  one decision per section), then `audio-dsp-engineer` for the DAWCore work.
- **Inputs, from m23-q F1:** f0 stability and `detectTransients` onsets. Word boundaries stay
  Phase 4 (§10 item 4).
- **Constraints already paid for:**
  - no second onset detector (§10 item 11);
  - holes stay note ends and are never bridged (§5, P3);
  - DAWCore stays pure.
- **Both failure directions are real.** F1 names over-splitting too ("a legato slide split into
  three notes", "a vibrato peak read as a neighbour note"). A splitter that fixes the 22.6 s slide
  by chopping every wobble is not a fix.
- **The design question the architect must answer, not assume:** what Hard Tune should do to the
  slide itself. There are at least three shapes: (a) the slide becomes its own short note or a
  transition into the held note (the Melodyne shape); (b) every frame snaps to its nearest scale
  note, making a staircase (the classic hard auto-tune sound); (c) today's median pin. Behaviour
  the user hears is theirs to pick. Render the candidates on their own take and ask ONE listening
  question (one axis, 3–4 options), per the listening rule.
- **Gates:**
  - the physics on the user's take: under Hard Tune, the held tail at ~23.05–23.2 s must read
    a note NEXT TO what was sung there (sung A#2+41 c, so A#2 or B2, each ±30 c) in the RENDER,
    with an independent tracker. G#2 or anything further away fails.
    **RED BASELINE, measured 2026-09-24:** it reads G#2+9 c (sung A#2+41 c), and the 16.8–17.0 s
    held note, sung ≈ D3 (product frames D3−1 c, wobbling ±85 c; an earlier "C#3+13 c" was a
    tracker-mask artefact, p2-seg design §11.4), reads A#2−11 c: about 4 st low. Scripts: session scratchpad `busyline/physics-ht-*.py`;
  - the invariance control: a run with no note change must give the SAME segment as today's
    `voicedRuns`, byte for byte, on the existing fixtures. The boring control catches the bug;
  - an over-split fixture: a steady note with a ±40 c, 5.5 Hz wobble stays ONE note;
  - the existing test that pins today's legato behaviour is REWRITTEN on purpose and named in
    the report, never silently deleted.
- **Stored edits:** a changed splitter changes segment boundaries for NEW passes only. It must never re-segment a clip that already has stored edits (the C-F3
  `replaceExisting` rule and the hand-edit stamp stay in force).

## ERRATUM — 2026-10-04: Hard Tune's summary overclaimed
The preset table above (line ~754) gives Hard Tune's summary as "Replaces your pitch with the exact note. The robot
effect." and says to use the strings verbatim. Measured on 2026-10-04 (W7-TTM3, real detector + render + an
independent tracker), a held note under Hard Tune keeps about two thirds of its vibrato (±36 → ±23 c); the preset's own
notes record a 49–68 % cut. Nothing is "replaced" and nothing is "exact". The product string is now **"Holds each note
in tune, with less vibrato. The robot effect."** (`Sources/DAWCore/PitchCorrectionPresets.swift`), pinned by
`presetSummariesNeverOverclaim`. The table above is left as written, as a dated record.
