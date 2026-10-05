# Pitch editor: the interaction batch (hear, zoom, cut line, select, playhead, bigger editor, clear)

Design and implementation plan, 2026-09-24, daw-architect. **Status: DESIGN. Nothing here is shipped.**

## 0. How to read this document

- **Scope.** The seven INTERACTION asks from the 2026-09-24 hands-on feedback (I1–I7), plus inputs for C2
  (§14). Out of scope, and owned by a second architect: undetected notes, the gentle presets,
  correct-to-MIDI, and the top-centre dot. Settled designs are NOT reopened:
  `2026-09-22-pitch-editor-ui.md` (UI), `2026-09-24-pitch-editor-timing-and-freehand.md` (C2, C5b, C-0) and
  `2026-09-24-pitch-editor-vibrato-handle.md` (C5a).
- **Marks.** [READ] means I opened the code at the cited place. [INFERRED] means derived, not run.
  [REPORTED] means quoted from someone else. Nothing was built or run: another agent is building in this
  tree.
- **Census counts are not quoted.** Where a list of sites matters, the method is given and the
  implementer re-runs it.
- **The user's words describe; they do not diagnose.** Each item quotes them and then designs from the
  code.
- **Wording.** "Note" means a `NoteSegment` (a blob). Drawn text uses the user's own words: "clear",
  "cut", "playhead".

## 1. Decisions at a glance

| # | Decision | § |
|---|---|---|
| D0 | **Build one viewport seam, once.** It has scroll offset readers, a programmatic scroll writer, and a zoom anchor re-pin on both axes. It also holds the ONE press router (`PitchEditorGestureRouter`, vibrato doc §4.2) and an app-held `PitchEditorInteractionBridge`. I2, I5 and I6 all consume it. | 3 |
| D1 | **Hear the note, with no live DSP.** On press, the note plays as it sounds NOW. During the drag it stays silent ("Let go to hear it"). On release, it plays from the fresh render once that lands. Nothing plays while the transport runs. The engine gets a static audition lane; the wire gets `clip.auditionNote` and MCP `clip_audition_note`. Hearing it mid-drag is a follow-up, gated on a measurement. | 4 |
| D2 | **Trackpad pinch zooms TIME**, anchored at the pointer, as in the arrange and the roll. Pitch zoom stays on buttons. No ⌘-scroll here alone, because no surface has it. | 5 |
| D3 | **A full-height cut line** whenever Split is engaged. ONE verdict function serves both the hover and the knife. It turns amber, with "too close to the edge", on hover, before any click. | 6 |
| D4 | **Persistent selection on the house rules.** Clicks use `PianoRollGridPress`, the band uses `PianoRollMarquee`, and ⌘A gets a new `SelectAllMenuPolicy` surface. One Escape ladder serves both editors. A group pitch drag uses `PitchCorrectionUndoKey.group`. **⌫ is routed to this pane BEFORE selection ships.** | 7 |
| D5 | **A frozen time ruler** reuses `PianoRollScrubRulerBand`. Click or drag seeks (1/16 grid, ⌥ free), and ⌘-click on empty space seeks too. Follow runs during playback. The wire is the existing `transport.seek`. | 8 |
| D6 | **Maximize** gets a header toggle and an Escape mount (state and wire already exist). **Autoscroll** works on both axes through one 1-D rule hoisted from `PianoRollAutoScroll`. Vertically, it GROWS the pitch window. | 9 |
| D7 | **Clear is `NoteSegment.isCleared`**, the ONE silencing home, applied in the OFFLINE render; `amplitudeDb` is level, never silence (§17). ONE mask home applies both through the one output↔source mapping, keyed by ONE marker-gated digest block in slot (5). When only level bends the set, the render skips the stretcher and every sample outside the mask stays bit-exact. Doors: `clip.setNoteCleared` + MCP, and the ONE selection-based Clear/Restore menu. | 10, 17 |
| D8 | **C2 inputs:** push-neighbours = ⇧ held during a sideways drag; the whole-note slide gets its own bottom-centre handle; ⌘ on an edge zone starts the edge drag. | 14 |

**Render thread.** Only D1 adds anything to playback: a player node attached at graph build and
scheduled from the main actor. D7 changes only the offline render. Nothing allocates, locks or blocks on the
render thread. **Xcode:** nothing here needs full Xcode, entitlements, signing or AUv3.

## 2. Findings

Read 2026-09-24 while another agent edits `Sources/`. Lines drift: re-find by symbol before editing.

- **F1 [READ] Two tools,** Move and Split (`PitchEditorTool`, `PitchEditorModel.swift:953-987`). Move's
  help (`:983`) mentions neither edges nor ⌘.
- **F2 [READ] One modifier.** Only ⌥, read per drag tick (`PitchEditorView.swift:1164-1168`). There is no
  ⌘/⇧/⌃, no `.contextMenu`, no `.onKeyPress` and no cursor code. (That grep returns 0; `onContinuousHover`
  in the same file returns 1.)
- **F3 [READ] No selection.** One `DragGesture(minimumDistance: 0)` (`:1525-1528`); a press on empty space
  does nothing (`:1157-1163`). The model stores `drag`, `tool` and `refusal`, and no selection
  (`PitchEditorModel.swift:1145-1288`).
- **F4 [READ] One commit per gesture.** It leaves through `emit` (`:1860-1867`) as `notePitch` or
  `splitNote` (`:1057-1071`). `commitPitchNoteEdit` (`PitchCorrectionStaging.swift:175-206`) applies it
  through `setClipNotePitchOffset` (key `.segment`) or `splitClipNoteSegment` (`structuralKey`; the left
  half keeps the parent id; `ProjectStore+PitchNoteEdits.swift:65-165`). There is no group undo key
  (`PitchCorrection.swift:895-923`); UI design §8.4 reserved one.
- **F5 [READ] A cut preview exists and is easy to miss.** `PitchEditorCutPreview`
  (`PitchEditorView.swift:756-773`) is 1 pt wide and about 19 pt tall at the default 14 pt row
  [INFERRED], shown only while the hover hits a note (`:1143-1150`). The amber "too close" text appears only
  after a click (`PitchEditorModel.swift:1836-1852`; `PanelRefusalLine`, `PitchEditorView.swift:801-803`).
  The user's bundle (built 10:50) is newer than the view (03:58) [READ]; that they missed the line is
  [INFERRED].
- **F6 [READ] Zoom is buttons and ⌘± only** (`PitchEditorView.swift:1264-1317`, `DAWProApp.swift:6315-6341`,
  on `PianoRollZoom`). House pinch zooms TIME at the pointer: the arrange (`TimelineLanesView.swift:1080-1090`,
  `DAWProApp.swift:6413-6439`) and the roll (`PianoRollView.swift:2202-2231`, time only per
  `PianoRollZoomModel.swift:180-181`). No surface zooms on the scroll wheel; the only `.scrollWheel` monitor
  is the EQ's (`EQCurveEditor.swift:871-911`).
- **F7 [READ] No scroll seam.** Nested scroll views with no offset reader, no `ScrollViewReader` and no
  re-pin (`PitchEditorView.swift:1479-1545`). The seam grep matches one comment here (`:48`) and 29 lines in
  the roll. [INFERRED] So zoom jumps about the clip start, and anchored pinch, autoscroll and follow are
  impossible. The roll's seam: `PianoRollView.swift:3085-3106`, `:2569-2760`; `FollowPlayhead.swift:352`.
- **F8 [READ] The playhead is drawn but cannot be moved** (`PitchEditorView.swift:593-616`); follow is
  unwired (`:44-52`). The roll's `scrubStrip`/`scrubDrag` (`PianoRollView.swift:3108-3185`) draws the
  reusable `PianoRollScrubRulerBand` and seeks through `store.seek(toBeats:)` (`ContentView.swift:847`); a
  ⌘-click on empty grid seeks (`PianoRollGridRelease.swift:37-124`); `transport.seek` and `transport_seek`
  exist (`Commands.swift:249`, `server.ts:243`).
- **F9 [READ] Geometry.** x = (beat − startBeat) × ppb (`PitchEditorModel.swift:652-661`). The content is
  exactly `midiRange`'s rows (`:720-722`), and a drag is clamped to it (`:1768-1788`). `midiRange` opens at
  the note centres ±4 st, 12 to 36 st tall (`:117-190`). `autoFitMidiRange` runs only on detection and on a
  transpose that strands a note (`:1460`, `:1589`).
- **F10 [READ] Maximize** already sizes this pane (`ContentView.swift:778-780`). Only the roll has the
  toggle (`PianoRollView.swift:2493-2522`) and an Escape mount (`:795-796`, which calls
  `handleEditorEscape`, `DAWProApp.swift:2465-2471`). The wire and MCP tool exist (`Commands.swift:8809`,
  `server.ts:6103`), and the splitter already resizes the pane (`ContentView.swift:974`).
- **F11 [READ] Autoscroll is time-only:** `PianoRollAutoScroll.nextOffset` (1-D math under x names,
  `PianoRollAutoScroll.swift:65-158`) and `PianoRollEdgeRepeat` (`PianoRollEdgeRepeat.swift:92-220`).
- **F12 [READ] The selection rules are pure DAWAppKit:** `ArrangeClickIntent` (⇧ or ⌘ means toggle,
  `ArrangeSelection.swift:55-92`); `PianoRollGridPress.release`, UUID-typed (`PianoRollGridRelease.swift:102-110`);
  `PianoRollMarquee` (`PianoRollMarquee.swift:62-126`). A toggle on a `Set` is "a three-line idiom, not a
  rule" (`ArrangeSelection.swift:44-49`). The roll's context menu acts on the selection (it gets no click
  location) and needs `.contentShape` (`PianoRollView.swift:2705-2725`, `:2800-2811`).
- **F13 [READ] ⌘A is refused by name here** (`SelectAllMenuPolicy.swift:189-199`), and `DeleteMenuPolicy`
  has no pitch surface (`:363-365`). ⚠️ The pane's clip IS the arrange selection (`DAWProApp.swift:3235`),
  so ⌫ routes to `.arrangeClips` and deletes the vocal clip (`:2646-2676`) [INFERRED, not run].
- **F14 [READ] Audition is MIDI-only.** Homes: `AuditionController` (`Audition.swift:36-80`) and
  `auditionPitches` (`ProjectStore.swift:2117`); the roll sounds the note on every move tick
  (`PianoRollView.swift:3665-3670`). One switch, `auditionEnabled` (`PanelLayoutModel.swift:289`); outcomes
  are `AuditionOutcome` (`EngineProtocol.swift:606-624`); the verbs are `note.audition` and `note.play`.
  **No audio-region preview exists;** the nearest precedent is the reference lane
  (`PlaybackGraph.swift:2178-2216`, `:2263-2322`).
- **F15 [READ] The render** covers the whole source (`StretchCurvePlan.swift:22-26`) after a 250 ms
  debounce (`StretchRenderCache.swift:203`) and offers `onRenderComplete` (`:212`). A pending clip is skipped
  (`PlaybackGraph.swift:75-83`). The one output↔source home is `StretchCurvePlan.sourceSecond(forOutputFrame:)`
  (`:58-61`). The app polls render status at 10 Hz (`DAWProApp.swift:4201-4230`). A whole-file render takes
  under 1 s on the user's take [REPORTED].
- **F16 [READ] Per-note gain.** `amplitudeDb` is carried and unread (`PitchCorrection.swift:435-437`), yet
  in `isIdentity` (`:524-530`) and hashed inline (`StretchCurvePlan.swift:204`). `Clip.gainDbRange` is
  −72…24 (`Model.swift:728`). The digest's suffix blocks are marker-gated in a fixed slot order
  (`StretchCurvePlan.swift:214-261`). `ClipRenderSignature` compares note bytes (`:88-140`), and
  `rendersThroughStretchCache` is `!isStretchIdentity || hasPitchEdits` (`Model.swift:778-780`). A ratio-1
  stretch is not its own input (`PitchCorrection.swift:518-522`).
- **F17 [READ] Clip gain envelopes** are in clip beats and bake at schedule time (`Model.swift:222-240`,
  `PlaybackGraph.swift:2784-2821`, `clip.setGainEnvelope` at `Commands.swift:392`).

## 3. I0: the foundation (viewport seam and interaction bridge)

**Why first.** F7: a pointer-anchored pinch (I2), a following playhead and a pinned ruler (I5), and
autoscroll (I6) each need to READ and WRITE the scroll offsets, and the pane can do neither. Building the
seam once also cures today's zoom jump (F7).

**What gets built. Every piece copies a shipped roll idiom; none is invented.**
1. **`PitchEditorViewport`** (DAWAppKit, a pure value): `offset: CGPoint`, `viewportSize`, `contentSize`,
   `local(_:)`, `maxOffset`. Every I2/I5/I6 policy takes it as an argument, so all are headless-testable.
2. **Readers:** the roll's `gridScrollReader` idiom (`PianoRollView.swift:3085-3106`), one per axis, a
   background `GeometryReader` reading `frame(in: .named(…)).minX` (horizontal scroller) and `.minY`
   (vertical); each writes only on change and is never hit-tested.
3. **Writers:** the roll's marker idiom: a `ScrollViewReader` per scroller, a clear marker at the target
   offset, `scrollTo(id, anchor: .leading/.top)` re-issued on a fresh main-actor turn (the m17-b durability
   rule, `:2728-2737`). The vertical reader wraps only the vertical scroller (`:2590`).
4. **Re-pin on zoom,** hung on the SLOT change as the roll does, so buttons, ⌘± and pinch are all covered.
   `pitchEditorPPB`: `ArrangeZoom.offsetPreservingAnchor`, anchored at the pointer for a pinch, else
   `PianoRollZoom.anchorScreenX` (the playhead if visible, else the centre), measured at the OLD scale
   (`:2118-2135`). `pitchEditorRowHeight`: `PianoRollZoom.rowZoomOffset` (the centre row, `:2167-2177`).
5. **`PitchEditorGestureRouter.route(tool:modifiersAtPress:hit:) -> PitchEditorPressKind`** (DAWAppKit). The
   vibrato doc §4.2 names it and says whichever item lands first builds it; this batch lands first. Kinds
   now: `noteDrag(id)` (Move on a note), `band` (Move on empty space, promoted past
   `PianoRollMarquee.dragSlop`), `cut` (Split), `none`; C2-5, C5a-4 and C5b-4 add `edge`, `wobble`, `brush`.
   A press released within the slop goes to `PianoRollGridPress.release(noteID:modifiers:)` (§7). The view
   asks once, on the first tick, and never re-decides.
6. **`PitchEditorInteractionBridge`** (DAWAppKit, app-held, the `PianoRollNoteSelectionBridge` shape). OUT:
   `hasNoteSelection` (the ⌫/⌘A predicates) and a surface report for the echo. IN: nonces for clear,
   select-all and escape, plus debug-tier staged steps (hover point, press/drag/release with a chord,
   ruler x), because nothing in this tree can drive a real pointer (m23-g1, `PianoRollAutoScroll.swift:4-8`).

**Wire/MCP:** none; this is view plumbing. `debug.pitchEditor` gains `viewport {offsetX, offsetY,
viewportW, viewportH, contentW, contentH}` from the bridge, never re-derived.

**Tests:** `PitchEditorViewportTests` (re-pin arithmetic on the roll's literal fixtures);
`PitchEditorGestureRouterTests` (the full truth table). Planted, shown red: a re-pin measured at the NEW
scale; a router that re-decides mid-gesture. **Looked-at:** zoom in three steps with the playhead mid-view;
the line stays put.

**Size M · route `swift-app-engineer`.**

## 4. I1: hear the note while editing it

> "when we move vocal segment, it should play it like we do notes or when we change its properties pull or
> compress or modify the curve"

**Now:** audition is MIDI-only; the roll sounds the pitch from the first drag tick (F14). The pane has no
audio voice, and a commit silences the clip until its render lands (F15).

| Option | Latency | Real-time safety | Verdict |
|---|---|---|---|
| **(a)** On release, play the note from the fresh render. | 250 ms debounce + whole-file render (< 1 s on the user's take [REPORTED]) ≈ 0.3–1.3 s [INFERRED]; grows with take length (UI design P10). | Safe: a buffer on a static player; no DSP on the render thread. | Exact, but silent while dragging. |
| **(b)** While dragging, shift the ORIGINAL through a live voice. | About one I/O buffer, 5–20 ms [INFERRED]. | signalsmith: FORBIDDEN (UI design P8, m23-q condition 5). `AVAudioUnitTimePitch` or varispeed: safe by Apple's contract [INFERRED], but still pitch DSP on the render thread. | **Loses on honesty.** You would hear shifter X mid-drag and shifter Y after release (ours measured +5.45 c sharp at +2 st before p2-acc's 2026-09-25 fix, `PitchEditorModel.swift:88-92`); varispeed also changes speed and formants. The audio twin of the C-0 defect. |
| **(c)** Hybrid with no live DSP. | Press: tens of ms [INFERRED]. Release: as (a). | As (a). | **CHOSEN.** |

**The decision, (c):**
- **Press** on a note: it plays AS IT SOUNDS NOW (the render if ready, else the source). This is the roll's
  first-tick sound.
- **Drag:** silent; the readout says "Let go to hear it" (timing doc §5.6).
  **SUPERSEDED 2026-09-25 (I1-F1 + I1 UI hooks):** the drag is HEARD — each change of the draft's offset asks
  `ProjectStore.previewClipNotePitchDraft`, which span-renders the draft with the exact pitch and level the
  commit would store (latest wins; a free ⌥ drag keeps one render in flight plus the newest). The "Let go to
  hear it" readout was never built, so there was nothing to remove. One refinement, MEASURED in staging: a
  sung note is almost never on the grid, so a snapped drag's first tick snaps it onto its OWN row (−6 c, −1 c
  on the look's take) and asking for that restarted the note for nothing — a SNAPPED step that lands within
  `PitchEditorReadout.centsResolutionFloor` (12.9 c) of what was last asked for asks nothing. A note far off
  the grid still snaps audibly and is heard; ⌥ free steps are never thinned (`requestDragAudition`).
- **Release:** after the one commit, wait for that clip's `onRenderComplete` (F15; not the 10 Hz poll),
  then play the edited notes.
- **Which commits trigger it:** every commit that changes the sound (C1, I4, I7 with 0.3 s of context;
  later C2, C5a, C5b). A split changes nothing and triggers nothing.
- **Latest wins,** and a wait over 8 s is dropped.
- **Span:** the notes ±60 ms, capped at 6 s, with 5 ms fades. All three are PICKS.
- **Transport running or recording:** nothing plays, and transport start stops a sounding audition. The
  transport plays the result in context once the render lands; a voice on top would double the vocal.
- **The switch:** `panelLayout.auditionEnabled` gates the UI doors at the call site (the roll's rule,
  `ContentView.swift:923-928`). The wire ignores it.

**Engine (DAWEngine):**
- `PlaybackGraph` attaches `clipAuditionPlayer → clipAuditionMixer → mainMixerNode` in the reference
  lane's builder (`PlaybackGraph.swift:2178-2216`): fresh nodes, before start (the m16-h class), static.
- `AudioEngineControlling` gains `auditionClipSpan(trackID:clipID:startSourceSeconds:endSourceSeconds:)
  -> AuditionOutcome` and `stopClipSpanAudition()`. Defaults are `.unsupported` and no-op
  (`EngineProtocol.swift:1534-1539`).
- **The file comes from the resolver playback uses** (`stretchResolver`, `PlaybackGraph.swift:75-83`,
  `:594`), never a second key derivation. A pending render answers `.inaudibleNotReady`.
- **Frames go through `StretchCurvePlan` only.** Add `outputFrame(forSourceSecond:)` beside `:58-61`, so
  C2-3 makes both directions W-aware in one place.
- A detached task reads and fades the buffer. The main actor does `stop`/`scheduleBuffer`/`play` behind
  `withObjCExceptionBarrier` (`:2303-2313`).
- **Level:** clip gain × fader. A muted track answers `.inaudibleMuted`.
- **Stops on:** transport start, graph rebuild, `stopAllAudition()` (`ProjectStore.swift:2280`).
- **Named cost:** the voice skips the track's inserts. The MCP text says so.

**Store, wire, MCP:**
- `ProjectStore.auditionClipNotes(clipId:segmentIds:contextSeconds:)` returns `{outcome, startSeconds,
  endSeconds, source, reason?}`. It resolves from the STORED table (no pane needed) and refuses with
  `transport-running`.
- Policy home: `ClipNoteAuditionController` (DAWCore, the `AuditionController` shape). It owns latest-wins,
  waiting for the render, expiry and the transport cancel.
- **Verb `clip.auditionNote {clipId, segmentIds, contextSeconds?}`** and **MCP `clip_audition_note`**
  ("plays notes once as they sound now; `inaudibleNotReady` means still rendering, call again").

**Tests:**
- The controller, against a fake engine: plays on press; plays once after the matching render; a second
  commit cancels; the transport refuses; expiry; the switch.
- Planted, shown red: a ratio-2 mapping and a stale key.
- **Physics:** after a +2 st drag, an independent tracker reads the audition's output at the new pitch
  ±30 c.
- Commit→complete latency is MEASURED on the user's take.

**Follow-up I1-F1: hear it DURING the drag.** Off-thread note-span renders of the draft set, through the
one render loop (a second entry, never a copy), played per snapped step. It ships only on two
MEASUREMENTS: p95 step latency < 150 ms, and span-vs-whole-file RMS difference < −40 dB.

**Size M · `audio-dsp-engineer` (lane, resolver, mapping), `mcp-integration-engineer` (verb, tool),
`swift-app-engineer` (UI hooks).**

## 5. I2: pinch-to-zoom

> "zoom UI controls work, but we need gesture support which is more natural for zooming"

**Now:** buttons and ⌘± only (F6). Both house surfaces pinch-zoom TIME, anchored at the pointer, and no
surface zooms on the scroll wheel.

**Decision:**
- A `MagnifyGesture`, attached as `.simultaneousGesture`, in the roll's `gridPinch` shape
  (`PianoRollView.swift:2202-2231`).
- The first tick captures `(ppb, offsetX, anchorScreenX = startLocation.x − offsetX)`. Every tick writes
  only `layout.setPitchEditorPPB(PianoRollZoom.clamp(base.ppb × magnification))`. I0's slot re-pin moves
  the scroll, and `onEnded` drops the base.
- It calls `onEngage()` (m23-al), so ⌘± follows the pinch here.
- A pinch is two-finger, so it never fights the note drag.
- **Pitch axis:** stays on the PITCH −/+ buttons. A pitch pinch (for example ⌥-pinch) is follow-up
  **I2-F1**, for both editors at once, because neither has one (`PianoRollZoomModel.swift:180-181`).
- **Mouse wheel:** ⌘-scroll here alone would be a third convention. It is follow-up **I2-F2**, for all
  three surfaces together (§13). Plain scrolling keeps scrolling.
- **Drawn help:** the zoom cluster reads "Pinch to zoom time", drawn, never a tooltip.

**Wire/MCP:** none new. Zoom is `debug.panelLayout`-tier by design (UI design §5.8), and that verb already
sets and echoes `pitchEditorPPB` (`DAWProApp.swift:5725`, `:5831`).

**Tests** (`PitchEditorViewportTests`): the base is captured once; magnification is cumulative; the
pointer's beat holds within 0.5 px. Planted, shown red: an anchor re-derived per tick, the drift the roll's
doc names (`PianoRollView.swift:389-397`).

**Size S · after I0 · `swift-app-engineer`.**

**AMENDED 2026-09-25 (orchestrator, from source, after I2-1…I2-5 landed and were verified):**
- **The route:** the pinch does NOT write `layout.setPitchEditorPPB` from the pane. The pane pins "no slot writes"
  (`PitchEditorInteractionSiteTests`), so it goes through `onZoom(.timeScale)` to
  `AppModel.setPitchEditorTimeScale` (`DAWProApp.swift` ~:6664). That one writer then calls
  `panelLayout.setPitchEditorPPB`.
- **The anchor math** lives in `PitchEditorPinch.tick` (`PitchEditorViewport.swift` ~:300): the gesture-start scale
  × the cumulative magnification, with the anchor captured once, as decided above.
- **The staged seam is the `pinch` act** of the interaction bridge (`PitchEditorInteractionBridge.swift` ~:136). The
  `debug.pitchEditor` echo carries a `pinch` block.
- **The gate is `scripts/gates/m23ap-i2-pitch-pinch.mjs`: 28/28** on the orchestrator's own build. The anchored beat
  held within 1 pt through the sweep, and the negative control drifted up to 320 pt.
- **One gap remains:** a real trackpad pinch is not driven by anything in this tree (m23-g1). The user trying it on
  the next build is the positive control.
- ⚠️ **Known caveat (L2a finding):** after a scroll, zooming out past fit leaves I0's scroll reader at the old offset.
  The ruler uses `shownOffsetX`, but the pinch anchor still reads the raw offset. That is the I6b/I0 owner's to fix
  at the root.

## 6. I3: the cut line

> "when I activate cut mode, it should provide a vertical line for visual feedback when I want to cut it"

**Now:** a 1 pt, ~19 pt line appears only over a note's hit rect. The amber sentence appears only after a
click (F5).

**Decision: ONE verdict.** `PitchEditorModel.cutVerdict(at:) -> PitchEditorCutVerdict`, one of
`.cut(segmentID, atSourceSecond, leftMs, rightMs)`, `.tooCloseToEdge(segmentID, atSourceSecond, minimumMs)`
or `.noNote`. `splitNote(at:)` becomes a `switch` over it, so the hover and the knife are one function's
answer (the one-resolver rule, `PitchEditorView.swift:1143-1146`; `PianoRollGridPress.placesPlayhead`). The
floor stays `PitchAutoCorrect.minimumNoteSeconds`; there is no second constant.

**Drawn while Split is engaged and the pointer is on the surface** (`PitchEditorCutPreview`, rewritten):
- **A content-height hairline** at the pointer x, in `textSecondary` at 40 %.
- **Over the note, a 2 pt segment** (blob ±6 pt) with the house glow: `signal` for `.cut`, the
  `PanelRefusalLine` **amber** for `.tooCloseToEdge`, the colour of the refusal it predicts, earned by state
  (Rule 3).
- **A label at the line's top** (SF Mono 9): "Cut · 240 ms | 310 ms", or "Too close to the edge", or nothing
  for `.noNote` (the dim hairline alone then says "move onto a note").
  **AMENDED 2026-09-24 (I3 lane, from source; the orchestrator's ruling):** the label sits JUST ABOVE THE NOTE,
  not at the content top. The pane scrolls vertically with no readable offset and its content is usually taller
  than the viewport, so a top-anchored label is often scrolled out of view. The label text is unchanged. A note
  at the top edge must not clip its label.
- **Cursor:** `CursorKind.crosshair`, the existing "precise place" family (`CursorModel.swift:27-29`).

**The click is unchanged:** `.tooCloseToEdge` still puts today's amber sentence in the palette
(`PitchEditorModel.swift:1846-1848`). The hover amber is a prediction on the line, not a `PanelRefusalLine`;
nothing is refused until the click (`PitchEditorView.swift:1341-1346`).

**Wire/MCP:** none new; the capability is `clip.splitNote` / `clip_split_note` (`Commands.swift:461`,
`server.ts:9105`). `debug.pitchEditor` gains `cutPreview {visible, x, sourceSecond, verdict}`; a staged hover
through I0's bridge drives it for captures.

**Tests:** the `cutVerdict` truth table (inside a note, each edge ± the 60 ms floor, off-note, within the
slop); **preview and knife agree** (across 200 points, `splitNote` emits exactly when the verdict is `.cut`,
at the same second). Planted, shown red: a second floor constant used by the preview. **Looked-at:** captures
of all three verdicts.

**Size S · no dependency (the hover point exists today) · `ui-design-engineer`.**

## 7. I4: selection

> "when I select segment, it should stay selected and I should also be able to do mutiselect with mouse
> clicking or drawing rectangle, select all, basically the same functionality we have in note editor"

**Now:** no selection (F3). ⌘A is refused by name, and ⌫ would delete the whole clip (F13).

**Reuse the RULES; each model owns its Set** (the house ruling, F12):
- **Model.** `PitchEditorModel.selection: Set<UUID>` plus `selectionToken`, re-minted on every change.
  Mutators mirror `PianoRollModel`'s; `selectAll` takes every blob in the window. Pruning to live ids happens
  in `syncStoredNoteTable`/`apply` (the roll's `survivors`, `PianoRollModel.swift:244-255`). A split keeps
  the left id (F4) and, when the parent was selected, also selects the right half.
- **One home for band arithmetic:** hoist the roll's `additive ? base.union(hits) : hits`
  (`PianoRollModel.swift:782-792`) into `PianoRollMarquee.selection(base:hits:additive:)`; both models call it.
- **One hit-rect producer:** `PitchEditorModel.hitRects()` returns exactly the rects `blob(at:)` tests
  (`hitSlop`-inflated, `PitchEditorModel.swift:1709-1727`). The click and the band both read it (the marquee
  law, `PianoRollMarquee.swift:28-47`).
- **Presses go through I0's router.** A no-travel release goes to `PianoRollGridPress.release` verbatim:
  plain on a note selects only it; ⇧ or ⌘ on a note toggles it; plain on empty deselects; ⌘ on empty seeks
  (I5); ⇧ on empty does nothing. Travel past `dragSlop` on empty draws a band (⇧ or ⌘: additive). Travel on
  a note drags the selection's pitch; an unselected note is selected first (alone, or added with ⇧).
- **Drawn:** selected blobs wear a `signal` outline and a 14 % fill (an accent earned by state); the band
  looks like the roll's; the status line adds "3 notes selected".

**Group pitch drag:**
- The pressed note snaps as today; every other selected note takes the SAME landed delta, so intervals are
  kept, and ⌥ frees them all. The clamp is the TIGHTEST member's: no note may leave the window (the data-loss
  rule, `PitchEditorModel.swift:1768-1773`). The draft line moves every member (`rebuildDraftLine`); the
  overlay draws every moving blob.
- New commit kind `.notePitches` → `ProjectStore.setClipNotePitchOffsets(clipId:offsets:seedIfAbsent:undoKey:)`:
  ONE `performEdit("Tune Notes")` under `PitchCorrectionUndoKey.group(clipID:selectionToken:)`, UI design
  §8.4's key, whose condition (a caller) is now met. A one-note drag still commits `.notePitch` under
  `.segment`, byte-identical to today.

**Keys, each through an app policy, never a raw handler (UI design P6):**
- ⭐ **LANDED EARLY AS p2-del (2026-09-24, orchestrator's interim ruling; `DeleteMenuPolicy.swift`):** while the pane is
  OPEN, ⌫ / ⌦ / Edit ▸ Delete are REFUSED BY NAME (`DeleteMenuRefusal.pitchEditorOpen`, the ⌘A spelling), the key is
  SWALLOWED (`consumesKeystroke`), and the pane's refusal line reads `DeleteMenuPolicy.pitchEditorOpenHint`. The guard
  sits after the roll and automation arms, before the arrange's. The routing sweep grew 144 → 288 states. **I4 therefore
  EXTENDS it: the `pitchEditorNotes` arm lands IN FRONT of the `if pitchEditorOpen` guard (open AND notes selected →
  route to the notes); the refusal keeps every other open-pane case.** ⌘X / Edit ▸ Cut get the same treatment in
  p2-del-2. The clip's right-click Delete/Cut stay the deliberate escape hatch.
- **⌫ is wired BEFORE any selection is drawn.** `DeleteMenuPolicy` gains `pitchEditorNotes`, live when the
  pane is open AND the bridge reports a note selection (the `pianoRollWouldConsumeKey` shape,
  `DAWProApp.swift:1435`; never engagement or focus). The clip is never deleted while notes are selected.
  Its action is §13's answer; until then the pane consumes ⌫ with a refusal line ("Delete won't remove the
  clip while notes are selected"), which names "Right-click ▸ Clear" once I7b ships the menu.
  **RED FIRST:** on that fixture the routing test resolves `.arrangeClips` today (F13 made a measurement)
  and `.pitchEditorNotes` after; the 144-state `DeleteKeyRoutingTests` sweep stays green.
- **⌘A:** `SelectAllSurface.pitchEditorNotes`. The `.pitchEditorOpen` arm (`SelectAllMenuPolicy.swift:189-199`)
  becomes live on the openness verdict (the m34-d ruling), with a new `emptyPitchEditor` refusal. The pinned
  refusal is REWRITTEN on purpose and named in the close; the title stays "Select All".
- **Esc:** one pure ladder, `EditorEscapeLadder.resolve(gestureLive:hasSelection:maximized:blocked:) →
  cancelGesture | clearSelection | exitMaximize | pass`, used by BOTH editors. ⚠️ The roll goes straight to
  maximize today (`PianoRollView.swift:795-796`); it now clears a selection first, a named behaviour change
  on a shipped surface.

**Wire/MCP:** selection is view state (the roll stages its own via `debug.pianoRollMarquee`, off MCP). The
agent capability is the group edit: **`clip.setNotePitches {clipId, notes:[{segmentId, cents}]}`**, an additive
batch verb (the `clip.moveMany` precedent) with absolute cents like `clip.setNotePitch`; MCP **`clip_set_note_pitches`**. `debug.pitchEditor` gains
`selection {ids, count, token}` plus staged press and band steps.

**Tests:** the press truth table through the reused `PianoRollGridPress`; band hits equal click hits (an
inset-rect plant goes red); the group delta and the tightest-member clamp; forty ticks make zero commits and
a release makes ONE commit with N offsets and ONE journal entry; ⌫ routing red-first; ⌘A; the Esc ladder table.

**Size M-L · after I0 · `swift-app-engineer` (verb: `mcp-integration-engineer`).**

## 8. I5: the playhead

> "we should be able to position playhead there as well and be able to move it"

**Now:** the line is drawn, but there is no ruler, no seek gesture, and no follow (F8).

**Decision:**
- **A frozen 18 pt time ruler** (`PianoRollScrubRuler.height`) pinned to the top of the viewport, in the
  roll's `scrubStrip` shape (`PianoRollView.swift:3137-3158`): the band is a BACKGROUND of the hit area,
  drawn by the reusable `PianoRollScrubRulerBand`; the pane's x is the roll's clip-local x (F9) and `scrollX`
  comes from I0's reader. It shows in every state (`PitchEditorView.swift:1488-1493`), and the surface gains
  an 18 pt top inset so the ruler never hides the top row.
- **Click jumps, drag scrubs,** stopped or playing (`PianoRollView.swift:3115`), through ONE producer,
  `PitchEditorModel.placementBeat(atContentX:snapBypassed:)`: 1/16 (`SnapResolution.sixteenth`, never
  `ClipSnap`: timing doc F21), combined with the app snap's OFF via `SnapResolution.effective`; ⌥ is free
  (the 2026-08-13 ruling). C2-5's chip later owns this division; its default already agrees.
- **⌘-click on empty space seeks** (`PianoRollGridPress` `.positionPlayhead`, via I4). The ⌘ hover cursor
  and the ruler cursor are both `.verticalBar`, the transport family (`CursorModel.swift:30-44`), not the
  roll's legacy `resizeLeftRight`.
- **Follow during playback:** an app-held `pitchEditorFollow: FollowPlayheadModel`, the `pianoRollFollow`
  twin, which survives the pane's `.id` rebuild. It reads the ONE `layout.followPlayhead` flag (whose doc
  widens to three surfaces), turns pages through I0's writer, stands down on a manual scroll (`reportOffset`)
  and runs only while playing (m23-c2). This retires the "not wired" note (`PitchEditorView.swift:44-52`).

**Wire/MCP:** none new; `transport.seek` / `transport_seek` (F8). `debug.pitchEditor` gains
`playhead {positionBeats, x, insideClip, follow {enabled, suspended}}`; a staged ruler x drives the seek.

**Tests:** the placement truth table (snap on/off, ⌥, clamp to the clip, x 0 = the clip start); a seek spy
(one seek per tick, carrying the placement value); follow reuses `FollowPlayhead`'s pinned policy, and the
pane wiring is a looked-at capture during playback. Planted, shown red: the scroll offset added on the grid
path (the roll's warning, `PianoRollView.swift:3268-3273`).

**Size M** (ruler S, follow M) **· after I0 · `swift-app-engineer`.**

**AMENDED 2026-09-25 (the I5 lane, from source and staging measurements):**
- **A sibling row, not a pinned overlay with an 18 pt inset.** The ruler is a row ABOVE the scrollers
  (`editorBody` = `rulerRow` over `editorScrollers`), with a 52 pt `panelRaised` corner over the pitch-name
  column. There is no inset, and the captures show the top pitch row fully visible in every state. An overlay
  would need its inset kept in step with I0's vertical reader and I6c's fill height; a row outside the
  scroller needs neither.
- **The ruler's offset is `PitchEditorViewport.shownOffsetX`, not I0's raw reading.** MEASURED: scroll to 900
  at 160 pt/beat, zoom out until the clip fits (1083 pt content in a 1364 pt box), then press TIME − again. The
  reader then holds 900 while the grid draws at 0. A ruler drawn with the reading showed bar 8 over the clip's
  first bar, and its click landed 28 beats late. `shownOffsetX` clamps to the scroller's real range; both the
  band's `scrollX` and `rulerTick` use it. The root (a `scrollTo` issued while the content fits) is not fixed.
- **The snap needs density `.pro`.** `SnapResolution.effective(appSnap:density: .pro, picked: .sixteenth)`,
  because the Simple density locks placement to whole beats (a planted `.simple` went red). The snap is taken
  in CLIP-LOCAL beats; the gate's clip starts at beat 3.1 so that a project-space snap is caught.
- **⌘-click does not seek on a surface that draws no notes** (analysing, no notes found, refused): the router
  answers `.inert` there, so no click happens. "It shows in every state" is true of the RULER, which places
  the playhead in all of them; it is not true of ⌘-click.
- **⌥ means "free" twice:** on the ruler and on ⌘-click it bypasses the 1/16 snap; on a note drag it is the
  existing free-pitch modifier.
- **Wiring:** the pane takes `appSnap` (the app's `effectiveClipSnap`), `onSeek` (installed on the MODEL; the
  view never calls it; the app's closure calls `store.seek(toBeats:)`), `follow` and `isPlaying`. Follow's
  `followDrives` includes "no pinch in progress", and the manual-scroll detector reads that same predicate, so
  a pinch neither turns the page nor suspends follow.
- **Echo and staged step:** `playhead {positionBeats, x, screenX, insideClip, rulerScrollX, placementCount,
  lastPlacementBeat, follow {enabled, suspended}}`; `{act: "ruler", x, option?}` takes a RULER-LOCAL x.
- **The ruler numbers are clip-local** (the band's documented convention), so for a clip that does not start
  on a bar line, the transport's bar.beat and the ruler's differ by the clip's start. Recorded, not changed.
- **Drifted cites:** the line numbers in this section (`PianoRollView.swift:3137-3158`, `:3115`, `:3268-3273`,
  `PitchEditorView.swift:1488-1493`, `:44-52`) had moved before I5 was built. Cite by name: `scrubStrip`,
  `scrubDrag`, the view's banner.
- **The follow capture:** `captureUI` cannot film motion, and `scripts/video/screenrec` matched the staging
  window but captured 0 frames. The gate's follow legs are the evidence instead: no page turn while a pinch
  is live, a page turn once it ends, suspension on a manual scroll, and clearing on rearm.

**AMENDED 2026-09-25, later (I5-F1: the ruler and the snap use the SONG's bars).** This supersedes the line above
that reads "The ruler numbers are clip-local … Recorded, not changed", and the clip-local half of "The snap is
taken in CLIP-LOCAL beats".
- **Why:** looked at on staging (`i5-4-ruler-default-ppb32.png`, vocal at beat 3.1), the transport read 4.4 and the
  arrange line sat just before bar 5, while this ruler's handle sat near "4.1¾". A beginner reads one song and one
  set of bars.
- **Numbers:** the ruler names the SONG's bars (`PitchEditorSongRuler.ticks`): a tick at every whole song beat inside
  the clip, placed at `(beat − clip start) × pt/beat`; bars and labels from the project's `MeterMap.barBeat` (the
  arrange ruler's and the transport readout's own call, with the arrange's `beatInBar < 0.001` bar test); labels
  thinned on the song's bar index. Never a hard-coded 4/4 or a `beatsPerBar` scalar: a meter change inside the
  clip re-spaces the ticks where the arrange does.
- **Snap:** `placementBeat` snaps the PROJECT beat to the song's 1/16 (0.25 beat from beat 0; song bars always
  start on whole beats), then clamps to the clip. At the clip's edges the clamp wins, so an edge can be off the
  grid: x 0 on a clip at 3.1 snaps to 3.0 and clamps back to 3.1. The ⌘-click and the ghost line share the one
  producer, so they moved too.
- **Tempo:** no change needed, and none made. This pane's x axis is beats, like the arrange's; the tempo map only
  places the audio on it. A tempo change inside the clip moves the notes against the ruler and moves no tick
  (pinned with a two-segment map).
- **Why the roll's clip-local reason does not apply here:** the roll draws bar lines on its note grid counting from
  the clip's first beat, and its ruler must agree with them. This pane draws no time grid (its lines are pitch
  rows), so the ruler's ticks are the only bar lines on screen.
- **The band:** `PianoRollScrubRulerBand` gains `songMeter: MeterMap?` (default `nil`). Set, it draws an `Equatable`
  song canvas through the same renderer (`RulerCanvas.draw`); `nil` is the roll's call, whose inputs and pixels are
  unchanged. ~~The piano roll's ruler, grid emphasis, `BAR n` readout and scrub snap are still clip-local~~ →
  **Superseded 2026-09-25 by I5-F2:** the roll passes `songMeter` too, and all four of its sites move together:
  the ruler; the grid's bar lines (`PianoRollSongGrid.forEachLine`); the header's `BAR n`
  (`PianoRollBarOps.targetBar`, song bar, with the insert/delete range on that same bar); and `placementLocalBeat`
  (the song beat snapped, then clamped to the clip). The snap SIZE stays the roll's `effectiveSnap`; only where the
  grid starts moved. **Open, as I5-F3 (in progress 2026-09-25):** note add/move/resize/scale/paste still snap
  clip-locally, so an off-grid clip can place notes between the drawn lines. I5-F3 moves them onto the song grid and
  refuses, in words, a delete of a bar that lies only partly inside the clip.
- **Echo:** `debug.pitchEditor` `playhead` gains `transportReadout` (the transport bar's own string) and
  `ruler {numbering: "song", labels: [{x, text, isBar}]}`, computed through `PitchEditorSongRuler.ticks` from the
  pane's geometry and `transport.meterMap`. The gate's snap legs now assert the song grid (and that the placement is
  OFF the clip-local grid); new legs assert the first bar label ("2" at 0.9 beat), a click on "5" reading "5.1",
  and the ruler's bar under the playhead matching the transport's.

## 9. I6: a bigger editor, and autoscroll

> "we should be able to expand the editor window and when we drag up or down, it should autoscroll"

**Now:** maximize already sizes this pane, but the pane has no toggle and no Escape mount (F10). Its content
is exactly the pitch window, and a drag is clamped to that window (F9). Autoscroll exists for time only (F11).

**I6a, bigger (S):** a maximize toggle beside the close button, reusing `EditorMaximize.toggleSymbol/
toggleHelp/toggleAccessibilityLabel` and `layout.setEditorMaximized` (the roll's button,
`PianoRollView.swift:2493-2522`). `.onKeyPress(.escape)` on the pane goes to I4's ladder, then
`handleEditorEscape`. The wire already exists (F10); `debug.pitchEditor` echoes `maximized`.

**I6b, autoscroll: one rule, both axes (M):**
- **Hoist, don't copy.** Move `PianoRollAutoScroll.nextOffset`'s 1-D body to
  `EdgeAutoScroll.nextOffset(pointer:offset:viewport:content:)`; the roll's function forwards to it, so its
  pinned literals stay green. The pane calls it per axis with I0's viewport: pitch drags use y, bands use x
  and y, C2's drags will use x.
- **Vertical means GROWTH, not only scroll** (F9): a viewport showing the whole window has nowhere to
  scroll. When the target sits at the window edge and the pointer is in the band,
  `PitchEditorRange.grown(_:towards:by:)` adds a semitone per step, clamped to `fullMidiRange`; this relaxes
  the clamp as the user pushes, and the seam keeps the pointer's row visible. `userAdjustedMidiRange` stops
  `autoFitMidiRange` shrinking a window the user grew, as the model's own note asks
  (`PitchEditorModel.swift:1689-1691`); the pane's `.id` rebuild resets it.
- **Held pointer:** `PianoRollEdgeRepeat`'s clock (16 ms tick, 200 ms hold) with its recompute rule
  (`local + observedOffset` per axis, never integrated) and its three teardowns
  (`PianoRollEdgeRepeat.swift:43-64`).

**Tests:** `EdgeAutoScrollTests` (the roll's fixtures, both axes); growth stops at 0 and 127;
`autoFitMidiRange` keeps a grown window; `PianoRollAutoScrollTests` untouched and green. Planted, shown red:
integrating instead of recomputing.

**Route `swift-app-engineer`; I6b comes after I0 and I4.**

## 10. I7: clear a note

> "remove/clear while maitaining position of other vocals by selecting segment and then right click and
> remove/clear from menu, this could help reomve some unwanted sounds or not detected notes"

**Now:** no clear exists, and no context menu (F2). `amplitudeDb` is unread (F16).

**Storage: `NoteSegment.isCleared: Bool`.** Codable key `cleared`, read with `decodeIfPresent` (default
false) and written only when true, so saves stay byte-identical. Two alternatives lose:
- **The clip gain envelope** (F17): it lives in clip beats, so it will not follow the note through C2's W;
  its −72 dB floor is not silence; the editor would infer cleared notes from envelope shapes (a second home);
  and Remove Tuning would not restore it.
- **`amplitudeDb` at −72 as silence:** −72 dB is a level (the shared `Clip.gainDbRange` floor renders as
  10^(−72/20) on a clip), and a Restore would overwrite the note's own level. The ruling is §17, which also
  retracts this doc's stale-key objection to READING the field (the census found no writer).

**Model:**
- `isIdentity` gains `&& !isCleared` (`PitchCorrection.swift:524-530`); `hasPitchEdits`,
  `rendersThroughStretchCache`, `isEdited` and `ClipRenderSignature` follow with no second predicate.
- **ONE mask home**, `PitchEditSet.gain(atSourceSecond:)`: 1 outside notes; inside a note, 0 when cleared,
  else 10^(amplitudeDb/20). ONE 10 ms raised-cosine ramp constant (a PICK, clamped to half the note), placed
  INSIDE the note so a neighbour is never touched. It reads `amplitudeDb` now (§17); never a second stage.
- A split carries the flag through the Codable round trip (`reidentified`, `ProjectStore+PitchNoteEdits.swift:210-223`).

**Render (DAWEngine, offline only):**
- The output loop multiplies each frame by `gain(sourceSecond(forOutputFrame:))`, through the one mapping
  (F15), which C2-3 makes W-aware.
- **Level-only path** (B's name): `isPitchIdentity` is `isIdentity` without the two level terms. When every
  segment has it and ratio and transpose are identity, `performRender` writes source × mask and never runs
  the stretcher. A ratio-1 stretch is not its own input (F16); clearing one breath must not recolour the take.
- **Digest:** slot (5), the LEVEL block (§17), marker-gated on any `isCleared` or non-zero `amplitudeDb`,
  carrying every segment's flag; never inline (inline changes every existing digest). B's origin block is
  slot (6). `digestCoversEveryStoredField` goes red until the block exists; `layoutVersion` stays 1.
- **Re-key chain:** flag → `isIdentity` false → the block → `pitchEditSetHash` → a new `renderKeys` key →
  cache miss → render after the 250 ms debounce. Meanwhile `ClipKey` changes, the clip is `.pending` (silent)
  until the render lands, and `ClipRenderSignature`'s byte compare starts the shimmer poll. Known cost: the
  Bool adds struct padding, which that type's doc accepts as at most a spare poll
  (`ClipRenderSignature.swift:40-49`).

**Store, wire, MCP:** `ProjectStore.setClipNotesCleared(clipId:segmentIds:cleared:seedIfAbsent:)` makes ONE
`performEdit` ("Clear Notes" / "Restore Notes") under `structuralKey` (a deliberate on/off never coalesces,
UI design §8.3), one `tracksDidChange`, and shares the per-note setters' refusals. **Verb `clip.setNoteCleared
{clipId, segmentIds, cleared}`**; **MCP `clip_set_note_cleared`** ("silences notes in place, moving nothing
else; `cleared: false` brings them back at their own level"). `clip.getPitchEdits` gains `cleared`.

**UI (I7b, after I4):**
- **A selection-based context menu** (F12's shape): "Clear Note" / "Clear 3 Notes", plus "Restore" when any
  selected note is cleared; shown but disabled with nothing selected. Titles come from a pure
  `PitchEditorNoteMenu`. `.contentShape` is already on the surface (`PitchEditorView.swift:1522`).
- ⌫ does the same if §13 is answered yes.
- **Drawn:** a cleared note stays drawn and selectable (hollow, dashed, labelled "cleared"), its line hidden
  and the waveform under it dimmed. After the commit, I1 plays the span with context.

**Tests:**
- **Physics gate:** every sample between the ramps is numerically `== 0` (§17.5); a −72 dB plant (2.5e-4)
  must fail it. Outside the note, the level-only render is BYTE-IDENTICAL to the source (the invariance
  control); a stretched clip's neighbours stay within 0.1 dB of the uncleared render; no click at the ramps.
- One journal entry for N notes, and undo restores. The save omits the key when false (byte gate), AND a
  reopen compares field for field through `ClipDocument` and both reconstructions (UI design §12.2).
- Planted, shown red: the flag missing from `isIdentity`; the block written inline; the level-only path skipped.

**Scope:** B's U-A/U-B turn sounds between notes into selectable `.unpitched` segments (find sounds →
select → Clear), so clearing a GAP needs no special case (§17).

**Size M.** **I7a** (model, render, digest, store, wire): `audio-dsp-engineer`, then
`mcp-integration-engineer`. **I7b** (menu, drawing, ⌫ action): `swift-app-engineer`, after I4.

## 11. Render thread, Xcode, and failure modes

**Render thread.**
- I1's lane is the ONLY change on the playback path. Its player node is attached at graph build and
  scheduled from the main actor; buffers are read and faded off the render thread; start sits behind the
  ObjC barrier.
- I7 changes only the offline render.
- I0 and I2–I6 are main-actor UI.
- ⛔ Any proposal to shift pitch mid-drag ON the render thread (option b) stays forbidden (UI design P8).
  I1-F1 is off-thread by construction.

**Xcode:** none. `MagnifyGesture`, `onKeyPress`, `contextMenu` and `NSCursor` all work on macOS 14 under
Command Line Tools.

| # | Failure | Mitigation |
|---|---|---|
| 1 | ⌫ deletes the vocal clip while notes look selected (F13) | ⌫ routing lands before selection is drawn; the routing test runs red-first (I4). |
| 2 | The preview sounds unlike the result | No live DSP. The audition plays the file playback resolves (I1). |
| 3 | A late audition surprises after a long render | Latest wins; an 8 s expiry; silent while the transport runs (I1). |
| 4 | The hover line and the knife disagree | One verdict function, plus the agreement test (I3). |
| 5 | The band and the click disagree | One hit-rect producer (I4). |
| 6 | A group drag strands a note off-window | The tightest member sets the clamp; vertical growth (I4, I6). |
| 7 | Clearing one note recolours the take | The level-only path; outside bytes are identical (I7). |
| 8 | A clear plays stale audio | The `isIdentity` term, the slot-(5) level block, the reflection test (I7, §17). |
| 9 | Zoom and follow fight over the scroll | Re-pin hung on the slot; follow only while playing (I0, I5). |
| 10 | The roll's Esc changes | Named in the close; the ladder table test (I4). |

## 12. Implementation order, sizes and routes

| Order | Item | Size | Depends on | Route |
|---|---|---|---|---|
| 1 | **I3** the cut line | S | none | `ui-design-engineer` |
| 1 | **I6a** maximize toggle + Escape mount | S | none (Esc calls `handleEditorEscape` until I4's ladder lands) | `swift-app-engineer` |
| 2 | **I0** viewport seam, press router, bridge | M | none | `swift-app-engineer` |
| 2 | **I7a** clear, MERGED with B's U-C (§17): field, the one level mask, level-only render, slot-(5) block, store, `clip.setNoteCleared`, MCP | M | S2 (the same files) | `audio-dsp-engineer`, then `mcp-integration-engineer` |
| 3 | **I4** selection: ⌫ routing (red first), ⌘A, Esc ladder, band, group drag, `clip.setNotePitches` + MCP | M-L | I0 | `swift-app-engineer` (+ `mcp-integration-engineer`) |
| 4 | **I7b** the ONE Clear/Restore menu (notes and sounds), the cleared look, the level readout, Remove Tuning's help line, the ⌫ action (§17) | S | I4, I7a | `swift-app-engineer` |
| 5 | **I1** hear the note: lane, resolver, mapping, controller, `clip.auditionNote` + MCP, UI hooks | M | I4, for group spans (single notes work earlier) | `audio-dsp-engineer`, `mcp-integration-engineer`, `swift-app-engineer` |
| 6 | **I2** pinch | S | I0 | `swift-app-engineer` |
| 7 | **I5** ruler + ⌘-click seek, then follow | M | I0, I4 | `swift-app-engineer` |
| 8 | **I6b** autoscroll, window growth, held repeat | M | I0, I4 | `swift-app-engineer` |

**Parallel lanes:** I3, I6a and I0 can run together; the DSP lane (I7a) joins them once S2 lands.

**Every item:**
- Run `./scripts/test.sh`, never bare `swift test`.
- Each planted defect is applied, shown red, and reverted.
- One looked-at capture per item (`view.capture`; a drag is filmed with `scripts/video/screenrec/`).
- **New verbs, all additive:** `clip.auditionNote`, `clip.setNotePitches`, `clip.setNoteCleared`, each with a
  tool. Re-measure the totals with `node scripts/gates/doc-count-drift.mjs`; never quote them.
- The plugin bundle is a separate artifact, and `/plugin update` is the user's action.
- Tick `docs/ROADMAP.md`'s `(m23-ap-p2)` block per item.

## 13. What needs the user's word

**Asked once, with a recommendation:**
1. **Should the Delete key (⌫) clear the notes you selected in this editor,** the way it deletes selected
   notes in the note editor? *Recommended: yes.* It is undoable, and it does the same as right-click ▸
   Clear. Whatever the answer, I4 already stops ⌫ from deleting the whole vocal clip while notes are
   selected; until the answer arrives, ⌫ only shows a hint line.
   **ANSWERED 2026-09-25 00:41Z (db `handoff/pitch-2026-09-24b`, `delete-clears = yes`):** I4 builds ⌫ as
   "clear the selected notes" (one undo step, the same as right-click ▸ Clear). With no note selected, ⌫ keeps
   p2-del's refusal and hint. p2-del has landed uncommitted and is in `dist/DAWPro-next.app`.

**Decided here, not asked** (each is the house rule or a measurement gate):
- Pinch zooms time only.
- No mouse-wheel zoom until all three surfaces get it together (I2-F2). Ask only if the user says they
  zoom with a mouse.
- Nothing plays while the transport runs.
- Hearing a note DURING the drag waits on I1-F1's two measurements.
- The roll's Esc also clears a selection first.
- Cleared notes stay visible so they can be restored.

## 14. Addendum: inputs for C2 (timing), recorded and not designed

The user chose to build C2 LATER. Nothing below redesigns it; these are asks to fold in when C2-5 starts.

**Modifier census for the Move tool** (code: F2; designs: timing §3.8/§5.5, vibrato §4.1-4.2; house: F12):

| Key | Already means | Free for a sideways drag? |
|---|---|---|
| ⌥ | Free pitch (C1, in code); snap off (C2); fine control (C5a) | No |
| ⌘ | C5b brush on a note; ⌘-click toggles selection (I4); ⌘-click on empty seeks (I5) | No |
| ⌃ | macOS secondary click: the context menu opens on press, before any drag | No |
| ⇧ | At press only: toggle on a click, additive band on empty space | **Yes.** A ⇧-drag that starts on an edge or the slide handle has no meaning |

**(a) "push other segments… if special button is being pressed" → ⇧.**
- Hold ⇧ during an edge drag or a whole-note slide, and every note beyond the moved edge shifts by the
  same Δ instead of the gap absorbing it.
- ⇧ is read per tick, like ⌥, so it can join mid-drag.
- Pushed notes keep their lengths. The far gap (up to the next boundary, or the file end) absorbs the
  change, under C2 §3.7's clamps. C2's architect owns the W math.

**(b) The whole-note slide (answered "yes"): C-F5 is promoted.**
- It gets its own handle: a small ↔ tab under the note's bottom-centre, outside the blob.
- The body stays pitch-only, and neither the top-centre dot (the second architect's) nor the edge zones
  are touched.
- New router kind `slide`, one commit per gesture.

**(c) "I could not drag the note by edge, it does not activate when I press command button".** Move's help
never mentions edges or ⌘ (F1), so the user guessed. C2 A6's modifier-free edge zones stay. Add three
things:
- (i) the router lets an edge zone beat ⌘, so a ⌘-press on an edge drags the edge;
- (ii) grip marks at both ends of a hovered or selected note;
- (iii) Move's help names the edges.

**For C5b-4.** A ⌘-press on a note becomes a brush stroke only past `PianoRollMarquee.dragSlop`. Released
inside the slop, it is I4's toggle click. The stroke still begins at the press point.

## 15. Sources

Everything is cited inline and was read on 2026-09-24. The session brief is `briefs/user-feedback-2026-09-24.md`.
The designs are the three named in §0. The roadmap block is `docs/ROADMAP.md:1589-1598`.

## 17. Reconciliation with the unpitched-notes design

B's `2026-09-24-unpitched-notes-presets-midi-targets.md` (§0 U6, §1.8, §6 U-C/U-D/U-E) silences a note via
`clip.setNoteGain` at −72 dB, read as exact silence. ONE home is required; §1 D7, §10, §11, §12 are amended to match.

**17.1 The ruling: merged.**
- **Silence is `NoteSegment.isCleared`:** one field, one verb `clip.setNoteCleared {clipId, segmentIds, cleared}`,
  one tool `clip_set_note_cleared`, one menu (I7b), one ⌫ route (I4's `DeleteMenuPolicy.pitchEditorNotes`).
- **Level is `amplitudeDb`** (B's per-note gain), rendered NOW by the same stage; −72 dB means −72 dB, as on a clip.
- **Render and key are B's U-C machinery, extended to both fields.** One mask home,
  `PitchEditSet.gain(atSourceSecond:)` = `isCleared ? 0 : 10^(amplitudeDb/20)` inside a note, with ONE 10 ms
  ramp constant inside the note (B's 10 over my 8: one PICK, not two). One bypass predicate, B's
  `isPitchIdentity` (`isIdentity` minus both level terms), guards `StretchCurvePlan.make` and the stretcher
  skip. One digest block, slot (5) "level", gated on `segments.contains { $0.isCleared || $0.amplitudeDb != 0 }`,
  carries each segment's cleared byte; `amplitudeDb` stays hashed inline (`StretchCurvePlan.swift:204`), since
  moving it would re-key every set. B's origin block stays slot (6).
- A cleared note KEEPS its place in the pitch curve, so neighbours render exactly as before (§10's gate).

**17.2 Why.**
1. **Existing stored values: no writer exists.** Every `NoteSegment.amplitudeDb` line in `Sources/` (an unrelated
   `AudioContentAnalyzer.amplitudeDb(_:)` aside) is the declaration (`PitchCorrection.swift:437`), the identity
   term (`:529`), init default and clamp (`:592`, `:628-629`), CodingKeys, decode (`:664`), omit-when-0 encode
   (`:702`), the inline digest, or the `getPitchEdits` echo (`Commands.swift:13863`): no assignment, no builder.
   No wire verb decodes a `NoteSegment` or `PitchEditSet` (the four `JSONDecoder` sites decode `JSONValue`,
   `AutomationTarget`, `AutomationPoint`, `CompSegment`, `:9466`, `:12296`, `:12320`, `:12773`;
   `clip.setNotePitch` takes only `clipId, segmentId, cents`, `:5229`). A split copies the parent's value
   (`ProjectStore+PitchNoteEdits.swift:223`); MCP only echoes it, "unread by any renderer today, always 0"
   (`server.ts:8924`, `:9054`). **No project the product wrote carries a non-zero value** (only hand edits and
   fixtures can [INFERRED]), so reading it changes no existing project's sound.
2. **Stale key.** Today a non-zero value is hashed but ignored, so reading it under an unchanged key would
   serve a stale render. B's slot-(5) block, gated on non-zero, re-keys exactly those sets (the time-warp F7
   precedent); landing the read and the block together closes it for good. **§10's objection was a fear, not a
   measurement: retracted.**
3. **`isIdentity`** already carries `amplitudeDb == 0` (`PitchCorrection.swift:529`), pinned on purpose by
   `everyEditFieldBreaksIdentity` (`PitchCorrectionTests.swift:947-958`: "it breaks on the day phase 4 starts
   rendering them"). `isCleared` costs one term, a 9th row (the pin `cases.count == 8`, `:990`), one
   `digestCoversEveryStoredField` entry and one split-carry row. Point 4 is what that buys.
4. **Silence is a flag, not the −72 floor.** (a) The field shares `Clip.gainDbRange` by design
   (`PitchCorrection.swift:435-436`), and a clip at −72 renders `pow(10, gainDb/20)` = 2.5e-4 with no floor rule
   (`PlaybackGraph.swift:1778-1779`, `Model.swift:876`; a DAWEngine grep for `-72`/`gainDbRange.lowerBound`
   found nothing while the scan found both conversion sites). B's "exactly 0 at −72" gives one constant two
   meanings. (b) Restore must return the note's own level; a floor-as-silence Restore writes 0 dB and destroys
   it. The house keeps mute beside level (`Track.isMuted` beside `volume`, `Model.swift:1355-1359`; `Clip` has no
   mute), and so does Melodyne: "Double-clicking with the Amplitude Tool on one or more selected notes mutes
   them", "A further double-click unmutes the muted notes", shown as "Only the outline of the blobs" [VERIFIED
   2026-09-24 at B's §7 link; that unmuting keeps the level is INFERRED from the toggle]. (c) An agent reads
   `cleared: true` instead of decoding a magic number.
5. **Keep the door open for per-note level (Melodyne's Amplitude tool): yes.** The field was carried for it,
   one function reading both costs one `pow`, and agents can tame a breath the day U-D lands.

**17.3 What B's rows change** (B or docs-scribe applies them; this task edits only this doc).
- **U-C: merged with I7a** into ONE `audio-dsp-engineer` item after S2 (B was right; my §12 said "none"). Drop
  "exactly 0 at −72" and its test; add `isCleared`; `isPitchIdentity` excludes both terms; slot (5) is the level
  block; the ramp is 10 ms. Tests: a cleared span is zero between the ramps (17.5); a −72 dB plateau equals
  source × 10^(−72/20) (PLANT: a floor special-cased to 0 goes red); outside bytes identical. I7a's MCP step
  edits `server.ts:8924`/`:9054` in the same landing, because "unread by any renderer" becomes false.
- **U-D keeps** `setClipNoteGain`, `clip.setNoteGain` and `clip_set_note_gain` as the LEVEL verb (S, after U-C),
  so the render never reads a field nothing can write. Drop "Remove sets −72 / Restore sets 0". Its MCP text
  says −72 is the quietest level, not silence, and names `clip_set_note_cleared`; it drops "always 0" from both
  echo texts. A level is never invisible: I7b's readout shows "Level −6 dB" when non-zero.
- **U-E keeps** drawing sounds (hatched, faint), §1.7's readout, relative snap, the Wobble refusal and "Find
  sounds"; remove/restore moves to I7b. It waits for U-A, I4 and I7b, not U-D. Its looked-at gate includes a
  cleared `.unpitched` sound: B's hatch plus I7b's hollow-dashed outline, one composed look.
- **B's §0 U6, §1.4 (slot (5) → level block), §1.8, §6 and owed ARCHITECTURE entry** ("−72 dB is silence",
  "(5) gain") change to match. Counts stay (B +2, this doc +3); re-measure with `doc-count-drift.mjs`.

**17.4 One menu, one word, one verb name.**
- I7b's selection menu is the ONLY one, for notes and sounds: "Clear" / "Restore", nouns from
  `PitchEditorNoteMenu` ("Clear Note", "Clear 3 Notes", "Clear Sound"; "Clear 3 Selected" if mixed); ⌫ takes I4's route.
- "Clear", not B's "Remove": "Remove Tuning" (`TimelineLanesView.swift:4112`) wipes the whole set (the
  `clip.clearPitchEdits` capability), clears included, so its help adds "also brings back 3 cleared notes".
- `clip.setNoteCleared`, not `clip.clearNotes`: `clip.setNotes/getNotes/repeatNotes/patchNotes` are the MIDI
  family (`Commands.swift:382-385`) and `clip.clearPitchEdits` means "wipe" (`:851`). It pairs with
  `setNoteGain` (same params, another value) and keeps the user's word.

**17.5 The exact-zero gate.** `x × 0.0` is `-0.0` for negative `x`, so a byte compare fails on correct code: the
gate is numeric, `sample == 0` between the ramps. A literal-zero fill loses (the stretched path multiplies too;
one mask, applied one way). Outside a note the mask is the literal `1.0`, so byte-identity stands there.

**17.6 The user's word: nothing new.** "Remove/clear … while maintaining position" does not choose between mute
and level; the house and Melodyne precedents do. A drag-to-level tool is a follow-up nobody has asked for, not a
question. §13's ⌫ question stands, and a yes clears selected sounds too.
