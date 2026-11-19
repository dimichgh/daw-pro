# p2-sing-pr-words — edit the words on notes, right in the piano roll

Design study W9-PRW-D (daw-architect, read-only), 2026-10-12. Roadmap item `(p2-sing-pr-words)`, `docs/ROADMAP.md:3559`
(user-suggested and user-approved 2026-10-12: "add it as soonest one after this wave").

Evidence key: **READ** = I read it at `file:line` on 2026-10-12 (other lanes are editing the pitch files, so line
numbers can drift; the cited symbol is the anchor). **MEASURED** = someone ran it; I say who and how. I ran nothing
(read-only lane). **INFERRED** = my reasoning, not checked by running anything. **[A]** = an assumed default a
listening/look round may change.

Nothing in this design touches the render thread: lyrics are not render material (`ClipLyrics.swift:15-20`, READ).
Nothing here needs full Xcode (no entitlements, no AUv3, no signing).

---

## 0. The decisions, in one table

| # | Decision | Kind |
|---|---|---|
| D1 | The clip's TEXT stays the only truth. Words are drawn from the one derivation; nothing new is stored per note. | Architecture (settled) |
| D2 | Words are drawn in a **Words lane** under the note grid (aligned to the notes, always visible). Whether words ALSO appear on the note blocks is the user's pick from three looks. | Measurable default + taste question |
| D3 | The lane shows by itself when the clip has words; a **WORDS** header chip shows/hides it; never on a drum track or in Steps mode. | Measurable default |
| D4 | Three ways to start typing: **click a word in the lane**, **double-click a note** (while words show), **Return** with a note selected (a sixth key class on the app's key monitor). | Measurable default |
| D5 | The field reuses the Sing sheet's field model. Return saves, Tab / ⇧Tab walk the tune, Escape cancels, clicking away saves. Any outside change to the clip closes the field without writing. | Measurable default |
| D6 | ONE writer: `ProjectStore.setClipLyrics` (via `setNoteWord`). A word edit never goes through the roll's note `commit(`, so it can never fold into a note edit's undo step. | Architecture (settled) |
| D7 | Re-sing is NOT automatic. The lane says when the words changed since the vocal was sung and offers **Sing again**, which re-uses that take's seed/voice/height so only the changed lines are re-sung. | Measurable default; "replace the old take" needs the user's word |
| D8 | Phase 1 needs **no new wire verb**. Phase 2 (paste a whole line as ONE undo step) needs one additive verb, `clip.setNoteWords`. | Architecture |
| D9 | vf-2 is **fixed, not retired**: the Sing sheet's strip adopts the lane's layout function. | Measurable default |

---

## 1. Census (what exists today)

### 1.1 Where the words live — text only, derived every time

- A MIDI clip carries `lyrics: ClipLyrics?` = `{text, language?}` (`ClipLyrics.swift:69-79`, READ). **Which word sings
  which note is never stored**; it is derived from the text, the notes and the tempo map
  (`ClipLyrics.swift:6-13`, READ). The derivation is `SingPlanner.assignment(for:tempoMap:)`, documented as **THE ONE
  DERIVATION** used by the clip split, the sing plan and `clip.getLyrics` (`SingPlanner.swift:314-323`, READ).
- The derivation's rules: words go onto the monophonic melody (one note per onset: highest pitch wins, notes past the
  clip end drop out — `SingPlanner.swift:339-369`), grouped in breath phrases; line-per-phrase when the text has as many
  lines as phrases, else words flow; W > N is **refused**, which means **no word is placed at all**
  (`LyricNoteAssigner.swift:199-260`, `:289-300`, READ).
- The tempo map is used ONLY for the "squeezed word" warning (rule 7, `LyricNoteAssigner.swift:355-358`, READ). Word
  PLACEMENT does not depend on tempo.
- A clip without lyrics carries nothing (`ClipLyrics.normalized`, `:113-116`); `Clip.init` drops lyrics from non-MIDI
  clips (`Model.swift:945`, READ).

### 1.2 Typing one word = an edit of the text, through one writer

- `LyricTextEdit.apply(_:to:tempoMap:)` turns "type W on note N" into a new TEXT, then re-derives and checks that every
  other word still sings exactly the notes it sang (the round trip), else refuses `unstable`
  (`LyricTextEdit.swift:116-272`, READ). `"+"`, `"+~"` or empty = "the word before holds onto this note"
  (`:276-301`). Every refusal has a novice sentence (`LyricEditRefusal.sentence`, `:67-102`).
- `ProjectStore.setNoteWord(clipId:noteId:word:dryRun:)` calls it and stores through
  `setClipLyrics(... undoLabel: "Type Word")` (`ProjectStore+LyricTextEdit.swift:121-134`, READ).
- `setClipLyrics` is documented as **THE one write path for a clip's text** (`ProjectStore+LyricTextEdit.swift:33-37`);
  both overloads end in `writeLyrics` → `performEdit(undoLabel) { tracks[t].clips[c].lyrics = … }` with **no coalescing
  key** (`:101-107`, READ). It refuses a comp member (`clipInTakeGroup`) and a non-MIDI clip (`:136-143`).
- Callers today: the Sing sheet's note field (`SingSheetExpansion.swift:469-488`) and the wire `clip.setNoteWord`
  (`Commands.swift:11787-11801` → `SingWire.setNoteWord`), READ. `clip.setLyrics` reaches the same `setClipLyrics`
  ("Set Lyrics", `SingWire.swift:822-850`, READ).

### 1.3 Undo: a word edit cannot fold into a note edit — by construction

- The roll's note commit is `ProjectStore.setClipNotes`, journaled with `key: "clip.notes:<id>"`
  (`ProjectStore.swift:4641-4642`, READ). `UndoJournal.recordEdit` folds an edit into the top entry ONLY when both keys are
  non-nil and equal and the top merged within `coalescingWindow` = 800 ms (`UndoJournal.swift:98`, `:134-147`, READ).
- `writeLyrics` passes no key (above), so: note drag → word edit → note drag inside 800 ms gives **three** undo steps.
  This is the `fillDrumPattern` rule (`ProjectStore+DrumPattern.swift:231-236`, READ) holding for free. It must still be
  pinned by a test with a plant (§6), because one "harmless" key added to `writeLyrics` would silently break it.
- Each typed word is its own undo step ("Type Word"); a Tab walk over 8 notes is 8 steps. That matches the Sing sheet
  today. Phase 2's line paste is ONE step (§2.8).

### 1.4 What happens to the words when notes change (none of these touch the text)

READ: a grep of `.lyrics` writes across `Sources/DAWCore` finds only the `Clip` init/codable, the project document, and
the three CLIP-rebuild sites (`ProjectStore.swift:5165-5166` split, `:6778` bar insert, `:6810` bar delete, and
`Takes.swift:181-197` comps). No NOTE verb writes lyrics. Positive control: the same grep finds those rebuild sites.

| Edit | What happens to the words | Source |
|---|---|---|
| Move a note (time or pitch), resize, quantize, humanize, velocity | Text unchanged; words re-derive in time order. A note dragged PAST its neighbour swaps which word each sings (the word stays in its text position). Quantizing two notes onto one onset makes a "chord" place → only the top note is sung → one fewer melody note (INFERRED from `SingPlanner.swift:347-367`). | `setClipNotes` `ProjectStore.swift:4573-4659`; `quantizeClipNotes` `ProjectStore+Quantize.swift:116`; `humanizeClipNotes` `+Humanize.swift:185` |
| Delete a note (⌫, Edit ▸ Delete, context menu, Cut) | Text unchanged → **every later word in that line slides one note earlier**; if a line now has more words than notes, the whole derivation is REFUSED and no word is placed anywhere in the clip. | `deleteNonce` handler `PianoRollView.swift:993-997` → `commit()` → `setClipNotes` |
| Add a note (double-click) mid-line | Text unchanged → later words slide one note later; the line's last word (or a long unmarked word) holds the spare note (rule 5.2). | `PianoRollView.swift:2925-2944`; rules `LyricNoteAssigner.swift:234-236` |
| Paste notes (roll) | Pasted notes get words by time position; words after them slide. Words never travel with copied notes (the text belongs to the clip). | `pasteNotes` `ProjectStore+Paste.swift:297` |
| Roll bar delete (−) = `deleteTimeRange` | Text unchanged, even for notes the cut DROPPED. | `ProjectStore.swift:4722-4776` (no lyrics line) |
| Arrange `deleteBars` through the clip | Words whose notes were ALL deleted are removed from the text, same undo step (the 2026-10-05 ruling). | `ClipLyrics.distributeAfterDelete` `ClipLyrics.swift:241-313`, called `ProjectStore.swift:6810` |
| Split a clip / insert bars / comp | Words go with the notes they start on (`WordPlacement`). | `ClipLyrics.swift:145-237` |
| Duplicate / paste / trim a CLIP | Text kept exactly. | `ClipLyrics.swift:36-39` |
| Split one NOTE | No such verb in the roll (note split exists only in the pitch editor, on audio). | grep `splitNote` → `PitchEditor*` only |

**Why this matters for this item (the biggest UX hazard).** Today the slide is invisible: nobody sees words on notes
outside the Sing sheet. Once the roll draws them, a novice who deletes one note mid-line will SEE every later word jump
one note left, and a single extra word can blank the whole clip's words. The design does not change these semantics in
this item (D1); it makes them honest on screen (§2.4 refused state) and files the fix as a ruling (F1, §7.4).

### 1.5 How the roll draws, selects and edits

- The roll is store-free: it receives the `clip` VALUE and closures (`PianoRollView.swift:19-299`, READ). It already
  receives `clip.lyrics` (it is a field of `Clip`) but draws nothing from it. **Proved, not assumed:**
  `grep -i lyric` over `Sources/DAWApp/PianoRoll/` and `Sources/DAWAppKit/PianoRollModel.swift` returns 0 lines;
  positive control `grep -c -i lyric Sources/DAWCore/ClipLyrics.swift` = 65. The two "word" hits in `PianoRollView.swift`
  (`:90`, `:449`) are prose about refusal messages.
- Notes are drawn in one `Canvas` (`PianoRollGrid`, `:4498-4591`), `Equatable` on model identity + scalars so a transport
  tick never redraws it (`:4519-4525`). Each lit pill carries its PITCH NAME ("C#4", m25-i) when it fits, suppressed —
  never truncated — otherwise (`:4750-4793`; rule `PianoRollNoteLabel.swift:150-200`). MEASURED by the m25-i author:
  8 pt SF Mono advance = 5.0 pt, so a 2-glyph name needs 15 pt = exactly an eighth note at the default 32 pt/beat
  (`PianoRollNoteLabel.swift:170-180`; default zoom `PianoRollZoomModel.swift:25`, row 14 pt `:100`).
- One `gridDrag` (`DragGesture(minimumDistance: 0)`) owns every press: note click/move/resize, rubber band, group
  scale, playhead grab (`:720-801`, `beginGesture :3691-3760`, `endGesture :4170-4305`). Pinch and the double-tap are
  `.simultaneousGesture`s (`:2921-2945`).
- **The double-tap ALWAYS adds a note**, wherever it lands: `SpatialTapGesture(count: 2)` → `model.addNote(...)` with
  no hit test (`PianoRollView.swift:2925-2944`; `PianoRollModel.swift:502-513`, READ). So double-clicking an existing
  note today adds a second note at the snapped start (a stacked duplicate when the note sits on the grid) — INFERRED,
  not run; the build must measure it before repurposing the gesture (§2.5).
- All note edits submit through ONE funnel `commit(extendToCover:)` → `onCommit` → `setClipNotes`
  (`:1604-1631`), which is also engagement funnel R6.
- External changes reseed the draft via `.onChange(of: clip)` → `reseedFromExternalMutation`, which compares NOTES and
  LENGTH only (`:1151`, `:1495-1530`; `PianoRollModel.needsReseed :273-276`). A lyrics-only change therefore does not
  reseed and does not clear the selection (INFERRED from that comparison; good for this item).
- The header already has a **SING** chip that opens the Sing sheet (`onOpenSing`, `:122-124`, `:2536-2551`), hidden on
  `isDrumKit` (`:1843-1845`).

### 1.6 Keys and focus — what a text field inside the roll will meet

- **SwiftUI `.onKeyPress` on the roll is unreliable** in this app, MEASURED by earlier items: ⌫ never fired through
  `.onKeyPress(.delete)` (m23-cf-3, cited at `DAWProApp.swift:3806-3813`), and 7 of 7 real Escapes missed the roll's
  mount with the roll maximized (m23-ap I7b, `EscapeKeyMonitorRouting.swift:14-20`).
- So five key classes ride ONE app-wide key-down monitor, `AppModel.handleKeyDownEvent`: space, ⌫/⌦, arrows, Escape,
  musical typing (`DAWProApp.swift:3785-3797`, `:3814-3831`, READ). **Every one refuses when a text field holds
  focus** (`.textEditing`): `DeleteKeyMonitorRouting.swift:194`, `ArrowNudgeMonitorRouting.swift:214`,
  `EscapeKeyMonitorRouting.swift:159`, `MusicalTypingRouting.swift:627`, `TransportKeyModel.swift:47` (READ). The
  classifier is `transportKeyResponder`: `NSText` or `NSTextInputClient` first responder = text editing
  (`DAWProApp.swift:3993-3998`). A SwiftUI `TextField` puts the shared field editor (an `NSText`) first, so a word field
  is covered by all five refusals (INFERRED from that classifier; it is how the track/marker rename fields work today).
- The ⌫ route through the roll's own mount also refuses: `handleDeleteKey`'s policy reads
  `isArrangeTextEditingFocused`, computed from the LIVE first responder of the content window
  (`DAWProApp.swift:2456-2470`, `:2865`), so a word field anywhere in the window is covered.
- **Return is unclaimed** in the main window: no `.onKeyPress(.return)`, no key code 36 handler; `.defaultAction`
  appears only on cards/sheets (`TemplatePickerCard.swift:300`, `TemplatePickerSaveSheet.swift:166`,
  `SingVoiceRecorderView.swift:202`), READ by grep. The template picker is counted in `isModalPresented`
  (`DAWProApp.swift:2557`), so `escapeIsOwnedElsewhere` (`:2596-2598`) already covers it.
- ⌘Z is the STORE's undo app-wide (`EditCommands.swift:23-30`, `CommandGroup(replacing: .undoRedo)`), so inside a word
  field ⌘Z almost certainly undoes the last project edit, not the typing (INFERRED; shared with the rename fields;
  measure in LOOK). ⌘A in a field selects text, not notes (`SelectAllMenuPolicy.swift:95-107`, READ).
- Precedent for an inline field: the track rename field — focus on appear, Return commits (`onSubmit`), Escape cancels
  through `.onKeyPress(.escape)` with a `KeyPressProbe` first statement, focus loss commits
  (`TrackListView.swift:1065-1085`, READ).
- `.onKeyPress` matches the event's CHARACTERS, not the key (the m23-fk ⌫ trap, `PianoRollView.swift:856-862`). ⇧Tab
  on macOS normally carries the back-tab character U+0019, not U+0009 — so `.onKeyPress(.tab)` will probably NOT see
  ⇧Tab (INFERRED; the build must measure and list both).

### 1.7 The engagement funnels and the pins the build will move

`EditorSurfaceOwnershipSiteTests` (READ, `Tests/DAWAppKitTests/EditorSurfaceOwnershipSiteTests.swift`):
- `onEngage()` calls in `PianoRollView.swift` = **13** (R1–R11; `:269-323`).
- `commit(` occurrences = **8** (7 callers + definition; `:325-429`). A word write must NOT become a ninth.
- Gesture attachments under `Sources/DAWApp/PianoRoll/` = **9**, Swift files = **7** (`:431-504`).
Each pin carries a standing instruction ("a NEW gesture … must decide whether it ENGAGES … then update this number").
Expected moves are listed in §6.2.

### 1.8 The Sing sheet's strip today (vf-2)

`SingWordStrip` (`SingSheetView.swift:319-425`, READ) squeezes the WHOLE clip into the sheet's width with no scroll
(`:338-346`) and draws each word as a `Capsule` chip at least **18 pt** wide, 16 pt tall, `lineLimit(1)`
(`:377-394`). On a long clip with short notes every chip is floored to an 18 × 16 capsule — a near-circle — and
neighbours overlap; text is truncated. That is vf-2's "overlapping truncated circles" (mechanism INFERRED from the code;
not re-captured). The same strip also hosts the Expression card's note pick (`tapNote` → `expression.toggleNote`,
`SingSheetExpansion.swift:413-419`), styled-note dots and the playback glow (`:677-690`).

### 1.9 Findings outside this item (file separately)

- **F1 — two rules for "a cut removed this word's notes".** The roll's bar delete keeps every word
  (`ProjectStore.swift:4722-4776`); the arrange's bar delete removes them (`:6784-6810`, the 2026-10-05 ruling). Same
  user intent, two outcomes. `distributeAfterDelete` already handles a lone surviving piece (`ClipLyrics.swift:258-260`),
  so the roll's verb can call it inside its own `performEdit`. Route: swift-app-engineer, DAWCore + store test.
- **F2 — the SING chip and the singer disagree about drums.** The chip hides on `isDrumKit` (`PianoRollView.swift:1843`,
  the MIDI-export predicate, which answers "no" for our `pads` drum machine per `:258-262`, `:627-629`) while the planner
  refuses on `ProjectTranspose.isDrumTrack` (`SingPlanner.swift:391-393`). On a `pads` clip the chip opens a sheet that
  then refuses. One home: pass the planner's predicate.
- **F3 — double-click on a note stacks a duplicate** (§1.5, INFERRED). This item repurposes that gesture while words
  show; whether to change it when words are hidden is a separate call.

---

## 2. Interaction design

### 2.1 D1 — the text stays the only truth

**Decision.** No per-note word storage. The roll draws the words that `SingPlanner.assignment` derives (exactly what
`clip.getLyrics` answers, `SingWire.swift:946-971`), and every edit goes through `LyricTextEdit` + `setClipLyrics`.

**Alternatives that lose.**
- *Store a word on each note* (the Vocaloid / Synthesizer V model: the lyric is a field of the note, so it moves and
  deletes with it). Loses: it creates a second truth beside the text, the exact "stored record that disagrees with the
  thing it describes" the base design forbade (`ClipLyrics.swift:6-13`, design §8 F16), and it would need a migration
  for every saved song, the wire's `clip.setLyrics` box semantics, the line/phrase rules and the clip-split rules
  (`WordPlacement`) rebuilt per note. All of `LyricTextEdit`'s round-trip safety would be thrown away.
- *Hybrid: store note ids next to the text as a "pin" cache.* Loses: two stores that must agree; every note verb (8+
  sites in §1.4) would have to maintain it, and the first one that forgets is silent.

**Failure modes we accept, and show.** Words re-flow when notes are added, deleted or reordered (§1.4). The design makes
that visible and recoverable (the refused state in §2.4, undo restores both), and files the "delete takes its word"
behaviour as a ruling (§7.4), not a silent change inside this item.

### 2.2 D2 — where the words are drawn: a Words lane

**Decision (measurable default).** A **Words lane**, 30 pt tall [A], directly under the note grid and above the
velocity lane (Pro), in BOTH densities (words are content, not edit chrome — the m25-i "both densities" call for pitch
names, `PianoRollView.swift:4764-4767`). Its 54 pt gutter cell reads `WORDS` in the `VEL` label style
(`:4388-4392`). Each word sits at its first note's onset, aligned to the grid's x; a held word draws a line across the
notes it holds. The lane is outside the editor's vertical scroll, so the words are visible wherever the pitch view is.

**Why a lane, from measurements, not taste.** A word on the note block does not fit at the default zoom for ordinary
singing: MEASURED, 8 pt mono needs 15 pt for TWO glyphs, an eighth note is 16 pt at 32 pt/beat, and the pill's height
is 11 pt of a 14 pt row (§1.5). "twinkle" on an eighth note cannot be drawn without truncation, and truncation is what
the user called unreadable in vf-2. The lane also gives the field a fixed place to open, a place to state a refusal, and
a place for the "sung vocal is out of date" notice.

**Alternatives that lose (as the DEFAULT; two of them are offered to the user as looks, §7.3).**
- *Word on the note block only* (what the user saw in vocal-synth editors). Loses at default zoom (above); would also
  evict the pitch name the user asked for (m25-i). Vocal synths can do it because their notes are ~20 px tall and
  their default zoom is wide.
- *Word in the row ABOVE the note.* Loses: a melody stepping up by a semitone puts the next note exactly in that row,
  right after this one, so the word overlaps the next note. Vertical scroll can also hide it.

**Taste question for the user (one axis, three looks, ship all three to the LOOK capture):**
(a) lane only; (b) lane + the word ALSO on the note block when it fits in full (pitch name moves after it or is hidden
for that note); (c) lane + the word REPLACES the pitch name on sung notes. The lane stays in every option because it is
where typing happens. Their pick is the feedback (listening-feedback rule). For looks (b) and (c) the words reach the
note Canvas, so `GridSnapshot` and `PianoRollGrid.==` (`PianoRollView.swift:4519-4545`) must carry them, or a word edit
never redraws the pill.

### 2.3 D3 — when the lane shows

- **Eligible clip** = MIDI clip, `editorMode == .notes`, and NOT a drum track by the singer's own rule
  `ProjectTranspose.isDrumTrack(track)` (`SingPlanner.swift:391-393`). The caller resolves it (the view is store-free),
  passed as `wordsEligible: Bool` beside `isDrumKit` (`ContentView.swift:973`). Not `isDrumKit` (F2).
- **Clip has words** → lane shown when the clip opens.
- **Clip has no words** → lane hidden; the header shows a **WORDS** chip (neutral chrome, Rule 3) next to SING. Clicking
  it shows the lane with an empty state: "No words on this tune yet." and a button **Add words…** that calls the existing
  `onOpenSing` (the Sing sheet's words box: ONE place to type a whole lyric). The chip hides the lane again.
- The WORDS chip toggles visibility for this OPEN (it is `@State` on a view mounted `.id(clip.id)`, so it resets on a
  clip switch — the `snap` precedent, `PianoRollView.swift:314-321`). Not persisted [A].
- Steps mode: no lane (the step grid replaces the whole editor stack, `:811-830`).

### 2.4 The lane, precisely (drawing spec)

**Inputs (one derivation, never per frame).** A DAWAppKit model `PianoRollWordsModel` (`@MainActor @Observable`,
owned by the roll as `@State`, recreated per clip by `.id(clip.id)`) holds `words: PianoRollWords`, derived by ONE pure
function `PianoRollWords.derive(clip:tempoMap:)` that calls `SingPlanner.assignment(for:tempoMap:)` and nothing else.
It re-derives ONLY when its inputs change: `(clip.notes, clip.lyrics, clip.lengthBeats, clip.startBeat, tempoMap)` via
`.onChange(of:initial:)`, and synchronously inside the word-commit funnel (so Tab opens the next note on fresh words —
the Sing sheet's `refresh()`-then-`beginNoteWord` order, `SingSheetExpansion.swift:481-485`). A `derivationCount` spy
exists for the "never per frame" test (`SingSheetModel.swift:556-562` precedent). `tempoMap` comes from ContentView
(`store.transport.tempoMap`) and is needed only for the squeeze warning (§1.1).

`PianoRollWords` (value, `Equatable, Sendable`):
`items: [Word]` with `{index, typed, parts, noteIDs, held, phrase}`; `unsungNoteIDs`; `refusal: String?` (the SAME
sentence `clip.getLyrics` reports as `problem`, `SingWire.swift:964-968`); `language`.

**Layout (pure, nonisolated, DAWAppKit `PianoRollWordLane.layout`).** Inputs: the words, the DRAFT's note rects by id
(`PianoRollModel.noteRects()`, the one rect producer, `PianoRollModel.swift:390-402`), `pixelsPerBeat`, and a text-width
table. Output: `[Item]` with `{wordIndex, noteID, text, kind (.word | .part | .dot), x, width, row (0|1), holdFromX?,
holdToX?, holdTickXs}`.
- Font: SF Pro 10 pt semibold [A] (labels are SF Pro; mono is for numbers — DESIGN-LANGUAGE Foundations).
- Widths are measured ONCE per derivation in the view layer (main actor) and passed in as a table; tests inject a fixed
  advance. Layout is arithmetic only, so re-laying-out on every drag frame or zoom step is allowed; DERIVING is not.
- Placement: a word's x = its first note's onset x + 2 pt. Try row 0, then row 1; a row is free when x ≥ that row's last
  end + 4 pt. If neither row is free the word becomes a **dot** (4 pt, neutral) at its onset.
  **Never truncate, never overlap** (the `PianoRollNoteLabel` "suppress, never truncate" law, applied to words). Zooming
  in turns dots back into words — density follows fit, not zoom thresholds (`PianoRollNoteLabel.swift:160-164`).
- Held word: a 1.5 pt line from the first note's onset to the last note's end, at the lane's bottom, with a 3 pt tick at
  each held note's onset. `+` typed by the user and rule-5.2 auto-holds look the same; the tooltip carries the warning
  sentence (`LyricWarning.heldWord.sentence`, `LyricNoteAssigner.swift:59-65`).
- Hyphenated word ("twin-kle"): each part is drawn on its own note (`.part`, from `AssignedLyricWord.word.parts`); notes
  past the parts are held (line).
- Chinese clip: one character per word (`LyricTokenizer` by language) — same layout, narrower widths.
- `unsungNoteIDs` (flow mode, fewer words than phrases): a faint dotted line under those notes, tooltip
  "No words reach this part of the tune yet." [copy PROVISIONAL]. Chord notes the singer drops get nothing.
- **Refused derivation** (W > N, not English, markup that does not fit): NO words drawn (never last-good words: that
  would be the tree's characteristic failure — a stale record that looks valid). The lane shows the refusal sentence in
  amber text (Rule 3: warning) with a button **Edit words…** (`onOpenSing`).
- **During a live drag**: positions come from the DRAFT's rects keyed by note id (words ride with their notes);
  WHICH word sits on which note is the last committed derivation; on commit the clip changes and the lane re-derives. If
  the drag changed the note order, the words visibly re-flow on release. That is the truth of D1; it is a LOOK item.
- **Scrolling**: the lane follows the grid's horizontal scroll by OFFSET, the scrub-ruler shape
  (`scrollX: gridScrollX`, `PianoRollView.swift:3380-3405`), NOT a second `ScrollView` (an independent scroller drifts
  from the grid on a manual scroll). It must put `.geometryGroup()` between the content-width `.frame` and the
  `.offset` — the WF law (`docs/DESIGN-LANGUAGE.md:416-423`), reference `PianoRollScrubRulerBand.scrolling`. Without it
  the lane can be re-rasterized on every Core Animation commit and starve the main thread.
- Width: `gridDrawnWidth` (`:710-712`), so the m18-f wide-window extension rides along. Past the clip end: words on
  ghost notes do not exist (ghost onsets are not sung, `SingPlanner.swift:339-345`).
- **Hit testing and tooltips.** The lane is ONE Canvas with ONE tap gesture and a pure x→item hit test. Never a
  `ForEach` of chip views with per-chip `.onTapGesture` (the sheet's shape, `SingSheetView.swift:377-393`): that moves
  the gesture pin by the word count, and many views sliding under a clipped offset is the WF hazard again. A Canvas
  carries no per-item `.help`, so tooltips come from the lane's own `.onContinuousHover` point resolved through the same
  hit test (the roll's one-hover-reader idea, `PianoRollView.swift:346-355`), or are deferred; the field always shows
  the full word.
- Colour: words are the user's content → `textPrimary` on a raised-glass chip ground (`panelRaised`, hairline). NOT
  violet: violet means AI-generated (DESIGN-LANGUAGE Foundations); the Sing sheet's violet chips mean "an AI will sing
  this", which the lane does not need to say. The open field and the note being edited take cyan (active state,
  Rule 3). A playhead "word now playing" glow is deferred (it needs a per-tick OFFSET overlay, never a per-tick Canvas
  redraw — the m10-e rule).

### 2.5 D4 — how to start typing

1. **Click a word (or a dot, or a part) in the lane** → the field opens on that word's FIRST note (a part redirects to
   the first note, which sidesteps the `noteInsideHyphenatedWord` sentence that points at "the words box",
   `LyricTextEdit.swift:90-92`). One new gesture on the lane (a `SpatialTapGesture` with a pure x→item hit test). It
   engages the roll like R1's selection-only click (`PianoRollView.swift:3692-3697`): new marker **m23-al R12**.
2. **Double-click a note while the lane is shown** → field on that note. The existing double-tap handler
   (`:2925-2944`) branches: `model.hitTest(point)` hits a note body AND the lane is shown → open the field (select the
   note); otherwise → add a note exactly as today. **A named behaviour change** (it was "add a stacked note", F3); with
   the lane hidden the gesture is byte-identical. No new gesture (still R4).
3. **Return (or keypad Enter) with notes selected and the lane shown** → field on the earliest selected melody note.
   Because `.onKeyPress` on the roll is measurably unreliable (§1.6), Return is a **sixth key class** on
   `AppModel.handleKeyDownEvent`, Escape-shaped:
   - `WordFieldKeyMonitorRouting.decide(keyCode:modifiers:isRepeat:responder:window:)` (new, DAWAppKit, pure): key codes
     36 and 76 only; refuse `.chord`, `.keyRepeat`, `.textEditing` (load-bearing: Return inside the field is the field's),
     `.secondaryWindow`; named refusals (the `EscapeKeyMonitorRefusal` rule, `EscapeKeyMonitorRouting.swift:92-113`).
   - `route(open:rollHasSelection:rollShowsWords:blocked:) -> Bool`: only `.rollOpen`, only with a reported selection
     AND the lane reported shown, and never when `blocked` = `escapeIsOwnedElsewhere` (`DAWProApp.swift:2596-2598`:
     modal, text field, explain mode — which already includes the template card's `.defaultAction`).
   - Hand-off: `PianoRollNoteSelectionBridge` gains `reportWordsShown(_:)` and `requestWordField()` /
     `wordFieldNonce` (the `escapeNonce` shape, `PianoRollNoteSelectionBridge.swift:104-129`); the roll's
     `.onChange(of: noteSelection.wordFieldNonce)` opens the field with its LIVE selection.
   - Swallow only when routed; otherwise return the event untouched (no behaviour change anywhere else).
   - Pin disjointness from space 49, ⌫/⌦ 51/117, Escape 53, arrows 123–126, and every musical-typing and pad key
     (`MusicalTypingRouting.allCaps`, `padAllCaps`) — the `escapeIsDisjointFromEveryOtherMonitorKey` precedent.

Opening the field selects its note in the grid (`model.selectOnly`), so the user sees which note they are naming; Tab
moves the selection with it.

### 2.6 D5 — the field

**Model: reuse, do not fork.** The field state is the Sing sheet's `SingNoteWordField` (`SingSheetExpansion.swift:20-39`)
and the opening rule is the sheet's (`:451-459`): first note of a word → the word's text; a held note → `+`; an unsung
note → open with the "This note isn't sung…" sentence; no stored words → never opens (the lane is in its empty state).
Extract the opening rule into one nonisolated function both surfaces call (`SingNoteWordField.opening(for:in:)`), so
the sheet and the roll cannot disagree about what a note's word "is".

**View.** A SwiftUI `TextField` overlaid on the lane at the word's x, clamped into the viewport; 140 × 22 pt [A];
placeholder `SingCopy.noteWordPlaceholder` ("Word on this note", `SingCopy.swift:211`); cyan 1 pt stroke (the rename
field idiom, `TrackListView.swift:1064`); a one-line hint under it in `textDim`: "Return saves · Tab next note · Esc
cancels" [copy PROVISIONAL]. A refusal shows under the field in amber, the store's sentence verbatim.

| Key / event | Behaviour |
|---|---|
| Return (`onSubmit`) | Commit; close. Unchanged text writes nothing (`draft == original`). |
| Tab | Commit; on success open the NEXT melody note (`SingPlanner.melody(of:)` order — the sheet's `noteAfter`, `SingSheetExpansion.swift:492-497`); on the last note, close. |
| ⇧Tab | Commit; open the PREVIOUS melody note. ⚠️ Must list BOTH U+0009-with-⇧ and U+0019 back-tab in the `.onKeyPress` key set until measured (the m23-fk character trap). |
| Escape | Cancel (no write), close, return focus to the roll. `.onKeyPress(.escape)` with `KeyPressProbe.pianoRollWordEscape += 1` as its first statement (the `TrackListView.swift:1071-1075` precedent). The app's Escape monitor passes it (`.textEditing`). |
| Click elsewhere (focus loss) | Commit (the rename-field rule, `TrackListView.swift:1076-1079`, guarded so Return/Escape cannot double-commit). A refusal here closes the field and flashes the sentence in the roll's amber notice bubble (the m25-a-2 `flashAutoExtendNotice` idiom, `PianoRollView.swift:2143-2169`). |
| A refused Return/Tab | The field stays open with the sentence; nothing is written. |
| The clip changes from outside while open (an agent, undo/redo, a note edit) | Close WITHOUT writing — the m18-i cancel rule. Mechanism in "Own-commit echo" below; it must not close the field Tab just opened. |
| ⌘Z | The store's undo (§1.6); the clip changes → the field closes (rule above). INFERRED; measure. |
| Space | Types a space. Phase 1: a word with a space is refused ("Type one word per note…", `LyricTextEdit.swift:78-79`). Phase 2: spreads the line (§2.8). |
| ⌫ / arrows / letters | Edit the text. Never delete a note, nudge a note, or play musical-typing notes: every monitor refuses `.textEditing` (§1.6). LOOK must confirm ⌫ with a note selected. |

**Commit funnel.** ONE private function in the roll, `commitWordField(advance:)`, used by Return, Tab, ⇧Tab, blur and
the debug seam. It calls the closure `onSetNoteWord(noteID, text) -> NoteWordOutcome` (wired in ContentView to
`store.setNoteWord(clipId:noteId:word:)`), re-derives synchronously, and engages the roll **only when the store reports
`changed`** — marker **m23-al R13**, the `applyStartFromBeat` rule (`PianoRollView.swift:689-697`: a funnel never
engages on a no-op). It NEVER calls `commit(`.

**Own-commit echo (load-bearing for Tab).** The store write changes the clip VALUE, and `.onChange` sees it on a LATER
body pass. Unguarded, that echo would (a) close the field Tab just opened on the next note and (b) derive a second time,
failing the "once per input change" spy. One rule fixes both, in the `needsReseed` idempotence shape
(`PianoRollModel.swift:273-276`): `PianoRollWordsModel` memoizes the inputs it last derived from. `commitWordField`
derives synchronously from the text the store RETURNED (`LyricNoteWordResult.text`, `ProjectStore+LyricTextEdit.swift:6-29`)
on the current notes and records those inputs; the `.onChange` path derives — and closes an open field — ONLY when the
incoming inputs differ from the memo. Test: Return-with-Tab leaves the field open on the next note after the echo lands,
and `derivationCount` moves by exactly 1 per commit.

### 2.7 D6 — the one writer

Every path that changes words ends in `ProjectStore.setClipLyrics` → `writeLyrics` → `performEdit` (key nil):
lane click / double-click / Return → field → `setNoteWord` ("Type Word"); Add words… → Sing sheet → `setClipLyrics`
("Set Lyrics"); agents → `clip.setNoteWord` / `clip.setLyrics`; phase 2 → `setNoteWords` → `setClipLyrics`
("Type Words"). No second writer: no store-array lyrics write (`].lyrics =`) outside `writeLyrics` (a site pin, §6.2;
local probe copies such as `SingSheetModel.swift:84` are not writes).

### 2.8 Phase 2 — type or paste a whole line across notes

**Decision.** In the field, text with several words (split on whitespace) + Return spreads them over this note and the
next melody notes, one word per note, as ONE undo step "Type Words". All or nothing.

- DAWCore: `LyricTextEdit.applyLine(words:startingAt:to:tempoMap:)` = successive `apply(.setWord)` on a working clip
  copy, each step round-trip-checked; refuses with the first failing step's sentence (naming the word), or a new
  `lineLongerThanNotes(words:notes:)`: "You typed 6 words but only 4 notes are left from here. Remove 2 words, or add
  notes." [copy PROVISIONAL].
- Store: `ProjectStore.setNoteWords(clipId:noteId:words:dryRun:)` → one `setClipLyrics(..., undoLabel: "Type Words")`.
- Wire (one command surface): additive verb `clip.setNoteWords {clipId, noteId, words: [String], dryRun?}` replying
  the `clip.setLyrics` shape, `rejectUnknownKeys`, plus MCP tool `clip_set_note_words`. Route:
  mcp-integration-engineer. The wire count moves +1 (`docs/ARCHITECTURE.md:61` says 288 as of 2026-10-12 — re-measure
  with `node scripts/gates/doc-count-drift.mjs` before quoting; `grep -c 'registerTool('` lies).
- Known limit v1: each pasted token takes ONE note, so a hyphenated token ("twin-kle") refuses unless its slot already
  spans enough notes (`markedWordDoesNotFit`). Selection does not change where the line goes; it only decides where
  the field opens.

**Alternatives that lose.** *N single-word writes from the UI*: one ⌘V becomes N ⌘Z, and a refusal halfway leaves half
a line written. *Compute the text in the app and write `clip.setLyrics`*: one undo step, but the app would hold logic
no agent can call — the one-command-surface invariant.

### 2.9 Exclusions and edge cases

- Drum track (singer's rule), Steps mode, audio clips: no lane, no Return route, double-click unchanged.
- Comp member clip: `setClipLyrics` refuses `clipInTakeGroup` (`ProjectStore+LyricTextEdit.swift:136-143`); the lane
  still DRAWS the words; the field shows the refusal sentence.
- A clip with lyrics but no notes: derivation refuses → amber line.
- Very long clips (hundreds of words): derivation is once per change; layout is O(words) arithmetic. INFERRED fine;
  the debug seam reports `derivationCount` so a gate can prove it.

---

## 3. Re-sing: what happens when words change on a clip that already has a sung vocal

### 3.1 What the code does today (READ)

- **Nothing automatic.** A sung vocal is an audio clip on its own violet track. Its record keeps the words it was sung
  from (`SungVocalProvenance.lyricsText`, `SungVocal.swift:61`), the source clip (`sourceClipId`, `:63`), the seed
  (`:73`), the voice, the octave and the part role (`:100-108`). Nothing compares `lyricsText` with the clip's current
  words after landing: a grep of `lyricsText` across `Sources` finds only the writers in `SingJobCoordinator.swift`
  (`:458`, `:725`, `:797`, `:856`, `:878`, `:1502`) and no reader (positive control: the same grep finds those writers).
  So after a word edit the old vocal keeps singing the old words, silently.
- **Singing again is a new job.** Its plan is split into units (runs of whole breath phrases, capped in length,
  `SingPlanner.swift:73-98`). Each unit's cache key is a sha256 of everything the render depends on: engine identity,
  voice (id + reference sha256 + prompt labels), the unit's notes AND words, lead/trail, **seed**, nSteps, cfg, output
  rate (`SingJobRequest.swift:275-292`, READ). A hit skips the render (`SingJobCoordinator.swift:1138-1150`, READ).
- **One changed word re-sings only its unit(s)** when everything else is equal: pinned by the test
  `phraseCacheThroughTheJob` — same take again renders 0 units; after `setLyrics` changes one line, `cachedUnits == 1 &&
  renderedUnits == 1` and the re-rendered unit is the edited line; a different seed renders everything
  (`Tests/AIServicesTests/SingJobCoordinatorTests.swift:829-852`, READ — a fake synthesizer, not a real engine; I did
  not run it). `LyricTextEdit` guarantees no OTHER word moves (§1.2), so a one-word edit changes only the unit(s) holding
  that word's notes (normally one; INFERRED for a phrase split past the unit cap).

### 3.2 The three caveats (each READ)

1. **Seed.** The sheet's **Sing it** sends no seed (`SingSheetModel.swift:504-506`), so it uses `firstTakeSeed`
   (`SingJobCoordinator.swift:720`, `SingJobRequest.swift:229`). **Try another take** draws a random seed
   (`SingTakeModel.swift:223-226`). If the vocal the user kept came from "Try another take", pressing Sing it after a
   word edit re-sings EVERY line, and the unchanged lines will sound different.
2. **Cache size.** LRU, 2 GB [A] (design `2026-09-27-p2-sing-integration.md` §4.3, `:946-949`); an old take's units can
   be evicted. An engine update changes every key. And a cache hit is a skip, not a determinism claim (`:951-953`).
3. **A NEW track every time.** Landing appends a new violet track and never replaces the old one
   (`ProjectStore+SungVocal.swift:342-344`, `:426-434`). After a re-sing the old and new vocals play together until the
   user mutes or deletes one. For a novice that is the real trap.

### 3.3 D7 — what this item does about it

- **Say it (phase 1).** When a track in the project has `sungVocalProvenance.sourceClipId == clip.id`, is the lead part
  (`partRole == nil || == "lead"`, `SungVocal.swift:107-108`), and its `lyricsText != (clip.lyrics?.text ?? "")`, the
  lane's trailing edge shows, in amber: "The words changed since this vocal was sung." with **Sing again…** [copy
  PROVISIONAL]. Pure check `SungWordsFreshness` (DAWAppKit). Home: ContentView passes a cheap VALUE,
  `SungWordsFreshness.leadLyrics(for: clip.id, in: store.tracks)` (the `lyricsText` of lead takes sung from this clip:
  an O(tracks) scan, no derivation — the same per-body-pass cost class as `isDrumKitTrack(ofClip:)` /
  `drumLaneMap(ofClip:)`, `ContentView.swift:973-977`, which already run on every body pass, and ContentView's body DOES
  re-evaluate per transport tick because it reads `positionBeats`, `:823`). `PianoRollWordsModel` folds it into its
  memoized inputs, so the comparison itself runs only when that value changes.
- **Re-sing only the changed lines (phase 1, small).** **Sing again…** opens the Sing sheet pre-set from the newest
  stale take's record: its voice, octave and **seed** (`SingJobRequest.seed`, `SingJobRequest.swift:164`, already on
  the wire as `sing.render {seed}`). With the same seed, voice, height and engine, every unchanged line is a cache hit
  (§3.1), so only the edited lines are sung and the rest is the very audio the user already heard — as long as the cache
  still holds them (caveat 2). Harmony parts: out of scope here; the notice names only the lead.
- **Replace the old vocal: needs the user's word.** Options to offer (one axis): (a) keep both, as today; (b) the new
  take mutes the old one (undoable, one step); (c) the new take replaces the old one on the same track. (b)/(c) need a
  landing change in `landSungVocal` and a wire parameter (`sing.render {replaceTrackId?}`) — a follow-up item, not this
  one.

**Alternatives that lose.** *Re-sing automatically on every word edit*: spends 10–60 s of a 6 GB engine per keystroke,
on a model the user may not have installed. *Tell the user nothing*: the old take silently sings words that are no
longer on screen — the tree's characteristic failure.

---

## 4. Wire, MCP and the staging seam

- **Phase 1 needs no new verb.** Reading words = `clip.getLyrics` (`Commands.swift:11706-11712`, the SAME derivation the
  lane uses); one word = `clip.setNoteWord` (`:11787-11801`, MCP `clip_set_note_word`, `mcp-server/src/server.ts:14294`);
  a whole text = `clip.setLyrics` (`:11682-11704`, MCP `clip_set_lyrics`, `server.ts:13920`). Showing/hiding the lane is
  view state with no domain effect (the m10-c/sp-b pure-view rule) — no verb. Re-sing uses `sing.render {seed}`.
- **Phase 2 adds one additive verb**, `clip.setNoteWords` + `clip_set_note_words` (§2.8). Never rename or reshape
  `clip.setNoteWord`.
- **Staging seam `debug.pianoRollWords`** (app tier, off `allCommands`/MCP/Copilot catalog, own file
  `Sources/DAWApp/PianoRoll/PianoRollWordsStaging.swift` in the `StepSequencerStaging.swift` shape, `:1-60`):
  - `{}` — READ-ONLY: `{eligible, shown, refusal|null, stale, derivationCount, reportSeq, items: [{wordIndex, noteId,
    text, kind, x, width, row, holdFromX, holdToX}], field: {noteId, draft, original, refusal}|null}` — what the lane
    DREW, reported by the view from its draw inputs (the echo-seam law; never re-derived by the seam).
  - `{act: "show" | "hide"}` — the WORDS chip's handler.
  - `{act: "open", noteId}` — the SAME `openWordField(noteID:)` the lane click / double-click / Return call.
  - `{act: "type", text}` — the field's binding setter.
  - `{act: "commit", advance: "none" | "next" | "previous"}` — `commitWordField(advance:)`, the Return/Tab/⇧Tab body.
  - `{act: "cancel"}` — the Escape body.
  - Return-key routing is exercised through the existing synthesized-event seam `debug.keySpace` (which runs
    `handleKeyDownEvent` with a synthesized event, `DAWProApp.swift:3766-3769`); if it cannot carry key code 36 today,
    extend it — never a second event synthesizer.
  - Bounded echo wait, 0.30 s, on `reportSeq` (the `awaitStepSequencerApplied` contract,
    `StepSequencerStaging.swift:20-32`). Staged acts do not resign an active field editor
    (`docs/ARCHITECTURE.md:371-379` staging laws) — gates normalise with `project.new`.

---

## 5. vf-2: fix the Sing sheet's strip, don't retire it

**Decision.** Keep the strip; replace its chip placement with `PianoRollWordLane.layout` (the same function, two
rows, dots, never truncate, never overlap), and let the strip scroll horizontally at a floor of 24 pt/beat [A] instead
of squeezing the whole clip into the sheet's width. Its note field, Expression-card note pick, styled dots and playback
glow stay as they are.

**Alternatives that lose.** *Retire the strip* and point to the roll: the sheet is a modal over the roll, and the strip
is also where the Expression card picks notes (`SingSheetExpansion.swift:413-419`) — retiring it removes that feature.
*Leave it*: vf-2 stays, and the app would have two word layouts that disagree about the same clip.

---

## 6. Tests

### 6.1 Headless (DAWAppKit / DAWCore), each with the plant that must turn it red

| Test | Asserts | Plant (must go red) |
|---|---|---|
| `PianoRollWordsDerivationTests` | `derive` == `SingPlanner.assignment` word-for-word (typed, noteIDs) on English, held, hyphenated, Chinese, flow-with-unsung fixtures; refused text → `refusal` == the `clip.getLyrics` problem sentence and NO items; no lyrics → empty, not refused; ineligible on `ProjectTranspose.isDrumTrack`. | derive from `clip.notes` instead of `SingPlanner.melody` (chord note gets a word) |
| `PianoRollWordsModel` spy | `derivationCount` moves once per input change, zero times across 100 layout calls and 100 draft-only changes. | call `derive` from `layout` |
| `PianoRollWordLaneLayoutTests` | no two items overlap in a row (property over random words/zooms); every drawn text equals the full word or part (never truncated); dot when neither row fits; held line = first onset → last end with a tick per held note; parts on their own notes; more ppb never yields fewer full words. | a `prefix(n) + "…"` fallback |
| `PianoRollWordFieldTests` | opening rule (word / `+` / unsung sentence) is the sheet's (shared function); part → first note; Tab/⇧Tab order = melody order skipping chord notes; Tab on last note closes; a refused Return keeps the field open with the sentence; blur refusal closes and returns the sentence; an outside change closes without a write (spy store). | drop the outside-change close |
| `WordFieldKeyMonitorRoutingTests` | decide table (36/76 eligible; chord, repeat, textEditing, secondaryWindow named); route only for open roll + selection + lane shown + not blocked; key set disjoint from space/⌫/⌦/Escape/arrows/`MusicalTypingRouting.allCaps`/pad caps. | route on `pianoRollEditorFocused` instead of the open surface |
| `SungWordsFreshnessTests` | stale only for lead takes of THIS clip whose `lyricsText` differs; harmony parts and other clips never. | compare `sourceClipId` to the track id |
| `LyricWordUndoFoldTests` (DAWCore store, injected clock) | `setClipNotes` then `setNoteWord` inside 800 ms = 2 undo entries; one ⌘Z restores only the word; reverse order too. | give `writeLyrics` `key: "clip.notes:<id>"` |
| Phase 2: `LyricTextEditLineTests`, store `setNoteWords` all-or-nothing + one undo step, `clip.setNoteWords` wire tests + MCP tool test | each pasted word on its note; refusal names the word; nothing written on refusal. | write the steps that succeeded before the refusal |
| F1 (if ruled): `deleteTimeRange` removes words whose notes all vanished, same undo step | — | — |

### 6.2 Site pins (read sources)

- New `PianoRollWordsSiteTests`: the lane has no `ScrollView(` and is fed `gridScrollX`; `.geometryGroup()` sits between
  the content-width `.frame` and `.offset` (the WF pin, `PianoRollScrubRulerSiteTests` shape); `PianoRollWords.derive`
  is called only from the `.onChange` handler and `commitWordField`; `commitWordField` contains no `commit(`; the store-array write needle `].lyrics =` occurs in
  `Sources/DAWCore/ProjectStore*.swift` ONLY inside `writeLyrics` (`ProjectStore+LyricTextEdit.swift:104`) and nowhere in
  `Sources/DAWApp` / `Sources/DAWAppKit` (positive control: the needle finds that one site). NOT a bare `.lyrics =`
  needle: `SingSheetModel.swift:84` already writes `probe.lyrics =` on a LOCAL copy, so a bare needle is red on day one
  and invites loosening. READ by grep 2026-10-12: `].lyrics =` across `Sources` hits `ProjectStore+LyricTextEdit.swift:104`
  and five LOCAL piece-array writes in `ClipLyrics.swift:234-310` (outside the pin's scope), and nothing in DAWApp or
  DAWAppKit — so the scoped pin is green today; the field's Escape handler's first statement is its
  `KeyPressProbe`; the field's key set lists both tab spellings (or the measured one, with the measurement cited).
- `EditorSurfaceOwnershipSiteTests`, moved WITH its standing instructions honoured (each new site checked against the
  rule, not waved through): `onEngage()` **13 → 15** (R12 lane click; R13 word commit, engaging only on `changed`);
  `commit(` **stays 8**; gesture attachments **9 → 10** (the lane's tap), Swift files under `Sources/DAWApp/PianoRoll/`
  **7 → 9** (`PianoRollWordLaneView.swift`, `PianoRollWordsStaging.swift`) [counts are what I EXPECT; the build
  re-measures]. Non-engagements, decided per the pin's standing instruction: the **WORDS** chip does NOT engage (it is a
  view toggle, the density and NOTES|STEPS precedent at `PianoRollView.swift:1815-1821`, not maximize's R10); **Add
  words… / Edit words… / Sing again…** do NOT engage (they open the Sing sheet, like the SING chip); opening the field
  by Return does NOT engage (a key routed by the OPEN surface, the Escape rule, `EscapeKeyMonitorRouting.swift:167-174`);
  a word commit engages ONLY when the store reports `changed` (R13).
- `DeleteKeySiteTests` / `EscapeKeyMonitorSiteTests`: unchanged; add a Return-branch order pin beside them.

### 6.3 LOOK checklist (a person, with captures; the user away)

1. A real song at default zoom: words readable; the stagger looks calm; dots are rare and discoverable; nothing truncated.
2. The three placement looks (§2.2) captured side by side on the same clip, for the user's pick.
3. Held word reads as "held"; hyphen parts read as one word.
4. Double-click a note → field; double-click empty grid → a note (unchanged); with the lane hidden, double-click on a
   note behaves exactly as before (measure what that is, F3).
5. Tab walk across a phrase; ⇧Tab back (record which character ⇧Tab delivered).
6. With a note selected: ⌫ in the field deletes a LETTER, never the note; arrows move the caret, never the note; letters
   never play musical-typing notes; space never starts playback.
7. Escape cancels the field; the next Escape clears the selection; the next leaves maximize (the ladder intact).
8. Return route works with the roll maximized and not focused (the I7b state).
9. Delete a note mid-line: the slide is visible; push a line over W > N: the amber line replaces all words, Edit words…
   opens the sheet.
10. Drag a note past its neighbour: the word rides, then re-flows on release — does it read as a bug? (feeds §7.4.)
11. Simple mode at the window floor: the 30 pt lane does not make the note grid unusable (the editor pane is capped at
    0.55, `PianoRollView.swift:486-488`).
12. Chinese clip; a comp-member clip (field shows the refusal).
13. Stale-vocal notice appears after a word edit; Sing again re-sings only the edited line (`sing.jobStatus` cached /
    rendered counts) — this one needs the singing engine: kill the sidecar pid-exact afterwards.
14. The Sing sheet strip (vf-2) on a long clip after lane D.
15. Main-thread health: with the lane shown and a render pending, the WF wedge gate (`scripts/gates/wedge-render-pending.mjs`)
    stays green.

---

## 7. Build lanes, effort, risks, and what needs the user's word

### 7.1 Lanes (order: A first; B after A's API is merged; D after A; E after B; C parallel to B)

**Lane A — swift-app-engineer (opus). The model, the routing, the wiring. Effort: M.**
Files:
- NEW `Sources/DAWAppKit/PianoRollWords.swift` — `PianoRollWords` value + `derive(clip:tempoMap:)`; `PianoRollWordsModel`
  (`@MainActor @Observable`, `derivationCount`); `SungWordsFreshness`.
- NEW `Sources/DAWAppKit/PianoRollWordLaneLayout.swift` — the pure `layout` (also used by lane D), `Item`, constants.
- NEW `Sources/DAWAppKit/WordFieldKeyMonitorRouting.swift` — `decide` + `route` (EscapeKeyMonitorRouting shape).
- EDIT `Sources/DAWAppKit/SingSheetExpansion.swift` — extract the field-opening rule into
  `SingNoteWordField.opening(for:in:)`; the sheet calls it (behaviour byte-identical, pinned by the existing
  `SingScreensExpansionTests`).
- EDIT `Sources/DAWAppKit/PianoRollNoteSelectionBridge.swift` — `reportWordsShown`, `requestWordField`, `wordFieldNonce`.
- EDIT `Sources/DAWApp/DAWProApp.swift` — the sixth branch in `handleKeyDownEvent` (after Escape's, documented as
  disjoint, never arbitration) with its own `…MonitorSeq`/`…RefusedBy` instruments (the ⌫ precedent, `:3842-3845`).
- EDIT `Sources/DAWApp/ContentView.swift` — new `PianoRollView` inputs: `wordsEligible`, `tempoMap`, `onSetNoteWord`,
  `staleSungWords`, `onSingAgain`.
- NEW tests: `PianoRollWordsDerivationTests`, `PianoRollWordLaneLayoutTests`, `PianoRollWordFieldTests`,
  `WordFieldKeyMonitorRoutingTests`, `SungWordsFreshnessTests` (DAWAppKitTests); `LyricWordUndoFoldTests` (DAWCoreTests).

**Lane B — ui-design-engineer (opus). The lane, the field, the look. Effort: M–L.**
- NEW `Sources/DAWApp/PianoRoll/PianoRollWordLaneView.swift` (the band view: Canvas + offset + `.geometryGroup()`, the lane
  tap, the empty / refused / stale states, the field overlay).
- EDIT `Sources/DAWApp/PianoRoll/PianoRollView.swift` — mount the band between `editor` and `velocitySection`; the WORDS
  chip in `header`; the double-tap branch; `openWordField`/`commitWordField`/`cancelWordField`; the
  `wordFieldNonce` handler; close-on-outside-change; R12/R13 markers.
- NEW `Sources/DAWApp/PianoRoll/PianoRollWordsStaging.swift` — `debug.pianoRollWords` (+ one dispatch line where the
  other `debug.*` seams dispatch).
- NEW `Sources/DAWAppKit/PianoRollWordsCopy.swift` — every sentence in §7.5.
- EDIT `Tests/DAWAppKitTests/EditorSurfaceOwnershipSiteTests.swift` (the pin moves, with the reasons written into the
  test like every earlier move); NEW `PianoRollWordsSiteTests`.
- The LOOK capture (§6.3) incl. the three placement looks for the user's pick, published to a decision page.

**Lane C — phase 2 line paste. Effort: M.** swift-app-engineer for `Sources/DAWCore/LyricTextEdit.swift`
(`applyLine`), `Sources/DAWCore/ProjectStore+LyricTextEdit.swift` (`setNoteWords`); mcp-integration-engineer (sonnet)
for `Sources/DAWControl/Commands.swift` + `Sources/DAWControl/SingWire.swift` (`clip.setNoteWords`),
`mcp-server/src/server.ts` (`clip_set_note_words`), wire + MCP tests, and the count docs (`docs/ARCHITECTURE.md:61`,
the `doc-count-drift.mjs` pin). Then Lane B wires the field's multi-word Return to it.

**Lane D — ui-design-engineer. vf-2. Effort: S.** EDIT `Sources/DAWApp/Sing/SingSheetView.swift` (`SingWordStrip`
uses `PianoRollWordLane.layout` + a horizontal scroll floor); capture before/after.

**Lane E — swift-app-engineer. Sing again with the take's seed. Effort: S.** EDIT `Sources/DAWAppKit/SingSheetModel.swift`
(an optional preset `{voiceID, octaveShift, seed}` the sheet opens with and passes into `SingJobRequest(seed:)`), the
`openSingSheet` entry in `DAWProApp.swift`; test: a preset sheet's request carries the take's seed; a fake-synth job
after a one-word edit reports `cachedUnits == units − 1` (the `SingJobCoordinatorTests` harness).

### 7.2 Risks

| Risk | Mitigation |
|---|---|
| ⇧Tab arrives as U+0019 and `.onKeyPress(.tab)` never sees it (the m23-fk shape) | list both characters; measure in LOOK; site pin |
| The roll's `.focusable()` + `.onAppear { isFocused = true }` (`PianoRollView.swift:834-835`, `:903`) fights the field's focus | field takes focus on appear (rename precedent); measure "first keystroke lands in the field" in LOOK |
| Return swallowed somewhere it should not be (a card's `.defaultAction`) | `blocked` = `escapeIsOwnedElsewhere`; route only for an OPEN roll with a selection and the lane shown; disjointness pin |
| The lane re-rasterizes per CA commit (the WF wedge) | `.geometryGroup()` + site pin + the wedge gate |
| A note edit blanks every word (W > N) and reads as data loss | amber sentence + Edit words…; undo restores; F1 / §7.4 ruling |
| Repurposing double-click surprises someone used to stacking notes | only while the lane shows; named behaviour change; LOOK item 4 |
| 30 pt less note grid in Simple mode at the window floor | lane hidden on clips without words; measure at the floor |
| Text-width measurement cost on huge lyrics | once per derivation, cached; the seam's `derivationCount` |
| Agents and the UI disagree | none possible: same derivation (`getLyrics`), same writer (`setNoteWord` / `setClipLyrics`) |

### 7.3 Needs the user's word (taste) vs measurable defaults

**The user's word (offer options, one axis each; ship captures, their pick is the feedback):**
1. Word placement: (a) lane only / (b) lane + word on the note when it fits / (c) lane + word replaces the pitch name.
2. After re-singing: (a) keep both vocals / (b) the new one mutes the old / (c) the new one replaces the old.

**Measurable defaults (decided here, revisit only on measurement):** lane height 30 pt and two rows; SF Pro 10 pt
semibold; dot fallback; neutral word colour, cyan for the active field; lane auto-shown only when the clip has words;
Tab = next melody note; commit on blur; close-on-outside-change; Return route conditions; Sing again re-uses the take's
seed/voice/height; strip floor 24 pt/beat.

### 7.4 Follow-ups (ruling, not this item's build)

- **Delete a sung note → its word goes too?** Options: (a) status quo, words slide; (b) the ROLL's delete (⌫, menu,
  cut) removes words whose notes ALL vanished, in the same undo step, through a store verb with an explicit id list
  (`deleteNotes(clipID:noteIDs:)` + an additive wire twin) — extends the orchestrator's 2026-10-05 `deleteBars` ruling;
  (c) make `setClipNotes` do it for every caller — **rejected**: an agent that replaces a clip's notes with fresh ids
  (an ordinary regenerate) would erase every word. This is an extension of an orchestrator ruling, so the orchestrator
  can rule it; it is not taste.
- **F1** (roll bar delete keeps words, arrange removes them) and **F2** (SING chip drum predicate) — small fixes.
- **F3** double-click on a note with the lane hidden.

### 7.5 Copy (novice; every string PROVISIONAL, one home `PianoRollWordsCopy`)

- Header chip: `WORDS` (help: "Show the words sung on each note").
- Gutter label: `WORDS`.
- Empty lane: "No words on this tune yet." · button **Add words…**
- Refused: the store's own sentence (e.g. "This line has 5 words but the tune has 4 notes. Each note sings one word, so
  remove 1 word or add 1 note.") · button **Edit words…**
- Field placeholder: "Word on this note" (shared `SingCopy.noteWordPlaceholder`); hint: "Return saves · Tab next note ·
  Esc cancels".
- Dot tooltip: the word itself; held tooltip: `LyricWarning.heldWord.sentence`; unsung: "No words reach this part of the
  tune yet."
- Stale: "The words changed since this vocal was sung." · button **Sing again…**
- Line too long (phase 2): "You typed 6 words but only 4 notes are left from here. Remove 2 words, or add notes."

---

## 8. Proposed `docs/ARCHITECTURE.md` "Key future decisions" entry

This lane is read-only, so it does not edit ARCHITECTURE.md; the build lane (A) adds this entry when the item lands:

> - **Words on notes in the piano roll (SETTLED 2026-10-12, design W9-PRW-D; item p2-sing-pr-words).** The clip's
>   lyrics TEXT stays the only truth: the roll draws the one derivation (`SingPlanner.assignment`, the same answer
>   `clip.getLyrics` gives) in a Words lane under the note grid, and every edit goes through `LyricTextEdit` and
>   `ProjectStore.setClipLyrics` (via `setNoteWord`), journaled with no coalescing key, so a word edit never folds into a
>   note edit. Note edits do not rewrite the text, so words re-flow in time order when notes are added, deleted or
>   reordered; the lane shows that honestly (a refused derivation draws no words, never stale ones). Return-to-type is a
>   sixth key class on the app's key monitor (`WordFieldKeyMonitorRouting`), refused under text editing like the other
>   five. Rejected: per-note word storage (a second truth beside the text, base design F16) and words drawn only on note
>   blocks (MEASURED: an eighth note at the default zoom fits two 8 pt glyphs). Open: the user's placement pick, and
>   whether deleting a sung note removes its word (ruling).

---

## 9. One-paragraph summary for the orchestrator

The roll gets a Words lane under its notes that draws exactly what the singer will sing (the one derivation), with three
ways to type (click a word, double-click a note, Return) and Tab / ⇧Tab to walk the tune; every write goes through the
existing `setNoteWord` → `setClipLyrics` writer, which cannot fold into note undo. No wire verb is needed for phase 1;
phase 2's one-step line paste needs `clip.setNoteWords`. Re-singing is not automatic: one changed word re-sings only
its line ONLY when the seed, voice, height and engine match, and the sheet's Sing it uses the first-take seed while
"Try another take" does not — so the lane's "words changed" notice opens Sing again with the take's own seed. Every
re-sing lands a new track beside the old one; whether it should replace or mute the old one, and the word placement
look, are the user's picks. vf-2 is fixed by sharing the lane's layout. The biggest risk is the visible word slide when
notes are deleted; it is shown honestly and filed as a ruling, not changed silently.
