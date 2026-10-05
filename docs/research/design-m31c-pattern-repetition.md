# m31-c — Pattern repetition on the write surface

**Status:** design, ready to implement. **Route:** store + wire spec below is
tight enough for `mcp-integration-engineer` (sonnet) to execute; the store
method itself is the risky half and should be reviewed by `daw-architect`
before merge.
**Author:** daw-architect, 2026-08-28.
**Roadmap:** `docs/ROADMAP.md:1853` (m31-c).

---

## 1. The decision

**Build BOTH halves. They are complementary, not competing.**

**(A) Ship a new narrow verb `clip.repeatNotes` / MCP `clip_repeat_notes`.**
Literal, time-shifted, optionally chromatically-transposed copies of a
clip-relative note window, written back into the SAME clip in ONE
uncoalesced undo step, returning **counts only — never a note array**.

**(B) Re-document the SMF path as the first-class bulk-composition route.**
`project.importMIDI` / `clip.importMIDI` (MCP `clip_import_midi`) are today
described as "import someone else's file". That framing is the reason the
dogfood agent found the 45 KB-vs-330 KB win by accident rather than by
reading the tool description. This is a documentation change, no new wire
surface, and it is the **cheaper and higher-value half** — do it first.

Neither half subsumes the other, and the honest reason is that **they solve
different problems**:

| | what it eliminates | what it still costs |
|---|---|---|
| SMF import | the **transport** cost of a large note set (binary, ~7x denser than JSON) | the agent still **generates** every note; needs a client-side SMF writer + a writable filesystem path |
| `repeatNotes` | the **generation** cost of the repeated part — the agent emits the pattern once | nothing for non-repetitive material |

The measured numbers make the split concrete. The twelve-bar blues is the
`repeatNotes` case almost exactly: drums are 149 notes / 9.2 KB that are one
bar (~13 notes, ~0.8 KB) repeated twelve times; guitar is 144 notes / 8.9 KB
that are one riff over a I–IV–V map. Expressed as pattern + repeat those
become roughly **1 KB each, a ~9x reduction, and the agent never has to
*think* the other eleven bars.** The jazz arrangement is the SMF case: 5,248
notes of which the walking bass and the solo are **not** repetitive at all —
`repeatNotes` would help the comping and the ride pattern and do nothing for
the rest, while SMF already took the whole thing from ~330 KB to 45 KB in one
call per part.

So: **repetition is a write-surface primitive; bulk is a file-transport
problem.** Building only (A) leaves the jazz case unserved. Building only (B)
— which is a defensible answer and was seriously considered — leaves the
*common* case, "lay down a groove", paying full price for material the agent
already knows is identical, and it forces every composing agent through a
filesystem round-trip for a four-bar hi-hat.

### 1.1 The "build nothing" case, stated fairly

The strongest argument against (A) is that SMF **already works**, is shipped,
is tested, and returns an exact per-part note count. Against that:

- SMF cannot **add to** an existing clip. `clip.importMIDI` replaces notes
  **wholesale** and explicitly **never changes the clip's length**
  (`Sources/DAWControl/Commands.swift:1533-1577`). Extending a groove you
  already placed means re-authoring and re-writing the whole file.
- SMF requires the agent to hold a MIDI encoder and a writable path. That is
  a real dependency, and it is exactly the dependency the control protocol
  exists to remove.
- The generation-side cost is the one that "arrives sooner, because composing
  is mostly writing" (the item's own framing). SMF does not touch it.

I judge that decisive, but **I am flagging it as the single most
second-guessable call in this document.** If the reviewing human would rather
ship the documentation half alone and re-measure after a dogfood round, that
is a coherent position and the cost of deferring (A) is low — the design
below stays valid.

### 1.2 What is explicitly OUT of scope for v0

- **"Apply this rhythm to this chord sequence"** in the harmonic sense —
  voicing, diatonic mapping, chord-symbol parsing. Not built. See §2.3 for
  the deliberately-weaker thing that IS built.
- **Cross-clip repetition.** A copy always lands in the same clip as its
  source. Clip-level repetition is `clip.duplicate`'s job.
- **A live/parametric "loop region"** that re-renders when the source
  changes. `repeatNotes` bakes copies as ordinary notes. A parametric pattern
  object is a model change (a new `Clip` field, a new persistence version, a
  new engine window rule) and is a milestone, not a verb.
- **`periodBars`.** Deferred and additive — see §4.

⚠️ **Naming disambiguation:** `transport.setLoop` already exists and means
*transport looping*. The verb is `repeatNotes`, never `loop*`, so an agent
cannot confuse "repeat these notes" with "loop the transport". Verified: the `allCommands`
array (`Sources/DAWControl/Commands.swift:211`) has **no** verb containing
`repeat` or `pattern`, and the only `loop` entry is `transport.setLoop`
(checked with a positive control on `clip.setNotes` / `clip.getNotes`).

⚠️ **Do not quote a command COUNT from this document.** My first scan produced
"247" and it was **contaminated** — the window ran past the array's end into
the case arms, so comment and `case` references were counted as entries
(`transport.setLoop` matched four times for one array slot). The array's own
comment at `Commands.swift:297` says the pin is deliberately spelled
`all.count == N` so that no absolute index or count is written down anywhere
else. **Read the current number from the `Reference commands` suite.**

---

## 2. The two candidate shapes, reconciled

### 2.1 REJECTED — a `repeat` argument on `clip_add_midi`

Loses on three independent counts, of which the first two are each
sufficient on their own:

1. **Creation-time only.** You cannot extend a groove you already placed, or
   repeat something you imported. Half the useful cases are unreachable by
   construction.
2. **It cannot layer.** "Kick every bar, hi-hat every beat" is two different
   periods over two different note subsets in one clip. One `repeat` argument
   on a creation call can express exactly one period, so the layered case
   still needs a second mechanism — and once that mechanism exists, the
   argument is redundant.
3. **The return shape is awkward, though NOT fatal.** `clip.addMIDI` returns
   `try JSONValue(encoding: midiClip)` — the whole encoded clip, including its
   full note array (`Commands.swift:2573-2577`) — so a 12x repeat would send
   13 notes up and bring 149 back down.
   ⚠️ **Weigh this honestly: it is a weaker objection than it first appears.**
   `clip_add_midi` **already accepts `returnNotes: false`**
   (`mcp-server/src/server.ts:3614-3631`, the m30-g / m31-b mechanism), which
   strips the array before it reaches the agent. The expansion would still be
   materialised on the localhost control socket, but **the agent-context cost
   — the cost this item is actually about — is already avoidable.** So this
   is a tidiness argument, not a decisive one. Counts #1 and #2 carry the
   rejection.

A separate verb also sits more comfortably with m31-b's direction (note arrays
becoming opt-out), but that is a consequence of the choice, not a reason for
it.

### 2.2 CHOSEN — a separate `clip.repeatNotes` verb

A separate verb gets to **design its return from scratch** (counts only),
works on any existing MIDI clip whatever created it, composes with itself for
layering, and adds nothing to any live verb's parameter set. It is additive
in the strictest sense: no existing command or tool changes shape.

### 2.3 The one place I go beyond "literal copies": `transposeSemitones`

⚠️ **This is a deliberate, flagged extension and the reviewer should push back
if unconvinced.**

An optional `transposeSemitones` — either a single `Int` applied to every
copy, or an `[Int]` of length exactly `count`, one per copy — is included in
v0. Without it, the *measured* twelve-bar-blues guitar case is **not served**:
twelve identical bars is the wrong answer for a I–IV–V map, so the agent
falls back to three or twelve calls and most of the win evaporates.

What it is: **literal chromatic transposition**, `pitch + n`, clamped by
`MIDINote.init` as every other note write is.

What it is **not**, and the tool description must say so in these words: it is
not diatonic, not key-aware, and not voice-leading. A blues riff moved I→IV is
a parallel chromatic move and comes out right; a diatonic melody moved +2 comes
out in the wrong mode. **An agent that wants harmonic correctness must author
the pitches itself.** Stating the limitation is what keeps this from being a
silent-wrong-answer feature, which is this tree's characteristic failure mode.

Cost: roughly ten lines in the store method and one schema field. If the
reviewer prefers strict literal copies for v0, drop this field — everything
else in the design is unaffected and the field stays additive later.

---

## 3. The undo story (the hard part)

### 3.1 The trap, named

The obvious implementation is `getNotes` → append copies → `setClipNotes`.
**That implementation is wrong, and it passes the obvious test.**

`ProjectStore.setClipNotes` journals with `key: "clip.notes:<id>"`
(`Sources/DAWCore/ProjectStore.swift:3668`). `UndoJournal.recordEdit` folds a
fresh edit into the current top entry whenever **both** keys are non-nil and
equal and the top last merged inside `UndoJournal.coalescingWindow` —
**800 ms**. Consequences:

- A `repeatNotes` landing within 800 ms of a note drag on the same clip
  **folds into the drag's undo entry, and one ⌘Z undoes both.**
- Two rapid repeats fold into one.
- A note drag immediately *after* a repeat folds into the repeat.

A test that repeats once into a quiet clip **passes while never seeing any of
this.** This is not hypothetical: it is documented, at length, as the entire
reason `ProjectStore.pasteNotes` exists as a separate method
(`Sources/DAWCore/ProjectStore+Paste.swift:219-295`). That banner is the
primary source for this section and the implementing agent must read it.

### 3.2 The fix — `pasteNotes`' shape, verbatim

**A new store method in a NEW file `Sources/DAWCore/ProjectStore+RepeatNotes.swift`.**
(New file, not an addition to the 7.4k-line `ProjectStore.swift`.)

- **ONE `performEdit`, with NO `key:`.** `recordEdit` requires *both* keys
  non-nil to merge, so a keyless edit never folds into what came before it and
  nothing folds into it afterwards. Repeat is always its own undo entry.
- **No-coalescing is semantically correct here, not just safe.** Unlike a
  quantize-strength scrub (`quantizeClipNotes`, which coalesces under
  `clip.quantize:<id>` deliberately), **repeat compounds on re-run**: calling
  it twice produces twice the copies. That is `applyAudioQuantize`'s situation,
  and `applyAudioQuantize` likewise takes no key.
- **WHY NOT a defaulted parameter on `setClipNotes`.** Same reason
  `pasteNotes` gives: the coalescing key is derived from `clipID` and a Swift
  default expression cannot reference another parameter. A separate method is
  the clean version and is purely additive — `setClipNotes` and every one of
  its callers (the wire's `clip.setNotes`, the piano roll's `commit()`, MIDI
  import) are untouched.
- **Auto-extend rides INSIDE the same `performEdit`.** If copies land past the
  clip end and `extendClip` is true, the clip grows in the same edit, so a
  repeat that both adds notes and lengthens the clip is **one ⌘Z**. Policy
  comes from `ClipAutoExtend.coverage` / `ClipAutoExtend.outcome`, ceiling
  from `trailingHeadroom(trackIndex:clipIndex:)` — never a local calculation.
  `performEdit` is **not re-entrant** (it captures before-state and journals
  unconditionally, with no depth counter), so the new length is written by
  mutating `tracks` in place, **not** by calling `trimClip` /
  `fitClipToContent` / `applyTrimWindow`. `applyTrimWindow` in particular
  DROPS notes starting past the new length, which on a capped grow is exactly
  the legal-but-latent data m18-f promises to keep.
- **`extendToCover` is the set of FRESHLY-MINTED copy ids, and that is the
  safety.** Each copy gets a `UUID()`, so the set is **disjoint from every
  pre-existing note by construction** — the same guarantee paste gets from
  `PasteAnchorPolicy.translatedNotes`. Deriving the grow span from *all* notes
  would let a forgotten latent note at bar 20 stretch the clip when the user
  repeated two bars.
- **The grow never eats a neighbour.** `trailingHeadroom` is the ceiling,
  because a grow routes through `resolvingOverlaps` and that choke point
  resolves an overlap by trimming or deleting the *stationary* clip. With no
  room, copies past the end simply stay latent — and are **reported**
  (`latentNotesPastClipEnd`), never swallowed.
- **Nothing to write → NO MUTATION AT ALL.** Not an empty `performEdit`:
  `performEdit` journals only when captured state changed, but entering it
  still calls `markDirty()`, so a fully-refused repeat would mark an untouched
  project dirty. Return the report and touch nothing. (`pasteClips`' rule,
  `ProjectStore+Paste.swift:156-160`.)

### 3.3 Note stacking — measured, and it has no choke point

⚠️ **Verified: there is no note-level equivalent of `resolvingOverlaps`.**
Clips have a no-silent-overlap choke point; **notes do not.** Two notes of the
same pitch at the same beat are legal in the model and will both play.

Therefore `repeatNotes` **cannot** rely on the store to protect it, and v0
takes the honest position rather than an invented policy:

- **It writes copies as-is and never dedupes or trims.** A dedupe policy is a
  guess about intent (stacked unisons are legitimate).
- **It reports what it stacked onto**, so the caller can see it happened:
  `preExistingNotesInSpan` (notes already present in the written span before
  the write) and `copiesOverlapEachOther` (true when `periodBeats` is smaller
  than the pattern span, so copy *n* overlaps copy *n+1*).
- `periodBeats <= 0` is a hard error. A zero period would stack `count` copies
  on the source.

---

## 4. The tempo / meter map

**v0 is `periodBeats` — an explicit beat offset, meter-blind by construction,
and it says so.**

A naive "repeat every bar" silently breaks across a meter change, which the
item correctly flags. The mitigation is not to guess: it is to make the
parameter *be* beats (so there is nothing to silently mis-infer) and to
**report** when the written span crosses a meter change.

- The note window and every copy offset are **clip-relative beats**, the same
  frame as a note's `startBeat` and the same frame `clip.getNotes` uses
  (`Commands.swift:2605-2612`). The window is **half-open `[fromBeat,
  toBeat)`** — `clip.getNotes`' rule, matched exactly so the two verbs cannot
  disagree about what a range means.
- **`meterChangesInSpan`** is computed by walking
  `transport.meterMap` over the **timeline** span
  `[clip.startBeat + firstCopyOffset, clip.startBeat + lastCopyEndOffset)` and
  counting `MeterMap.Change` entries strictly inside it. Note space is
  clip-relative; the meter map is absolute; the `+ clip.startBeat` conversion
  is the one place they meet and the implementing agent must not skip it.
  `MeterMap.beatsPerBar(atBeat:)` and `MeterMap.barBeat(atBeat:)` are the
  lookups (`Sources/DAWCore/TempoMap.swift:435,443`).
- When `meterChangesInSpan > 0` the copies are **still exact beat
  translations** — the verb does not re-bar anything. The report tells the
  caller its offsets are no longer bar-aligned past the change, which is
  actionable (issue two repeats, one either side).

**`periodBars` is deferred, and here is why it is not simply "the nicer
version":** a 1.5-bar pattern repeated "every bar" across a 4/4 → 3/4 boundary
has no single defensible meaning — the pattern's own length is expressed in
beats, the period in bars, and they diverge at the change. Getting that wrong
silently is worse than not offering it. It remains cleanly additive: a future
`periodBars` field resolves to a per-copy beat offset via
`MeterMap.beat(ofBar:)` before reaching the same store method.

⚠️ **What I am unsure of:** whether agents will reliably read
`meterChangesInSpan` rather than ignoring it. Reporting is weaker than
refusing. I chose reporting because refusing would block the legitimate case
of a groove that deliberately runs through a meter change. If a later dogfood
round shows agents ignoring the field, the correct escalation is a **warning
string** in the report (the `applyBreathContour` bend-range-mismatch
precedent), not a refusal.

---

## 5. Return shape — counts only

**The response contains no note array and no id array, ever, under any
parameter.** This is m31-b's direction taken to its conclusion rather than
merely made compatible with it: a verb whose purpose is to avoid materialising
N notes in the agent's context must not then materialise them in its own
response. A caller that needs the resulting ids reads them with
`clip.getNotes`, which already windows by beat and pitch and already reports
`totalNotes` vs `returnedNotes`.

```
{
  "clipId":                  "<uuid>",
  "copiesMade":              11,
  "sourceNoteCount":         13,
  "notesAdded":              143,
  "totalNotes":              156,
  "patternSpanBeats":        4.0,
  "firstCopyStartBeat":      4.0,      // clip-relative
  "lastCopyEndBeat":         48.0,     // clip-relative
  "clipLengthBeats":         48.0,
  "extended":                true,
  "extendRefusal":           null,     // e.g. "no room before the next clip"
  "latentNotesPastClipEnd":  0,
  "meterChangesInSpan":      0,
  "preExistingNotesInSpan":  0,
  "copiesOverlapEachOther":  false,
  "pitchesClamped":          0
}
```

`extendRefusal` is composed by the store's **one** `autoExtendRefusalMessage`,
so repeat, paste and note-edit cannot describe the same obstacle three
different ways.

⚠️ **`pitchesClamped` exists because `MIDINote.init` clamps pitch to 0...127,
and a transposed copy that clamps yields a SILENTLY WRONG INTERVAL** — the
note is still there, still audible, just at the wrong pitch. That is exactly
this tree's characteristic failure mode (a result that looks like a valid
answer). Report it, do not refuse it — the same stance §4 takes on meter
crossings. Zero when `transposeSemitones` is absent.

---

## 6. Implementation plan

### Step 1 — documentation half (B). Do this first; it ships value alone.

- `mcp-server/src/server.ts`: rewrite the descriptions of `clip_import_midi`
  and `project_import_midi` to lead with **bulk composition**, not "import
  someone else's file". Must state, with the measured number: *writing an SMF
  and importing it is the supported path for large parts; a 5,248-note
  arrangement is ~45 KB of SMF against ~330 KB of JSON.* Must repeat that
  `clip_import_midi`'s `atBeat` is **clip-relative** and that it **replaces
  notes wholesale and never changes clip length**.
- Mirror the framing in `Sources/DAWControl/Commands.swift:1533` and
  `:1579`'s doc comments.
- `docs/ARCHITECTURE.md`: record the settled decision (see §9).
- No wire change. No new tool. `allCommands` **unchanged** (step 1 adds no
  verb; the count pin must not move for this half).

### Step 2 — `Sources/DAWCore/ProjectStore+RepeatNotes.swift` (NEW FILE)

```swift
public struct NoteRepeatReport: Equatable, Sendable { /* §5 fields */ }

@MainActor
extension ProjectStore {
    @discardableResult
    public func repeatNotes(
        clipID: UUID,
        fromBeat: Double? = nil,        // clip-relative; nil = 0
        toBeat: Double? = nil,          // clip-relative; nil = clip length
        noteIDs: Set<UUID>? = nil,      // explicit selection; XOR with the window
        periodBeats: Double,
        count: Int,
        firstCopyAtBeat: Double? = nil, // clip-relative start of copy 1;
                                        // nil = source window start + periodBeats
        transposeSemitones: [Int] = [], // [] | [n] | exactly `count` entries
        extendClip: Bool = true
    ) throws -> NoteRepeatReport
}
```

Validation, **all before the edit opens**, in this order:

1. `locateClip(clipID)` → `clipNotFound`.
2. `requireNotCompMember(trackIndex:clipIndex:)` → `clipInTakeGroup`.
   (Comp geometry is rebuilt from the take group on every comp edit; a length
   written here would be silently overwritten.)
3. `notes != nil` → `notAMIDIClip(clipID, verb: "repeat")`.
4. `periodBeats > 0`, `count >= 1`, `count <= 512` (a ceiling, named in the
   error, so a typo'd `count: 100000` fails loudly instead of allocating).
5. `noteIDs` and (`fromBeat`/`toBeat`) are **mutually exclusive** → a
   field-named error. `fromBeat < toBeat` else field-named error.
6. `transposeSemitones` is `[]`, one element, or exactly `count` → field-named
   error naming both lengths.
7. Selection empty (window matched no notes, or `noteIDs` matched nothing) →
   **return a zeroed report, mutate nothing.**

Body:

1. Select source notes: window is **half-open on `startBeat`**, `>= fromBeat
   && < toBeat`, matching `clip.getNotes`.
2. `patternSpanBeats = max over selection of (startBeat + lengthBeats) -
   min startBeat`.
3. For copy `i` in `1...count`: offset `= firstCopyAtBeat + (i-1) *
   periodBeats - sourceWindowOrigin`; build each note through
   **`MIDINote.init`** (fresh `UUID()`, `pitch + transpose[i]`,
   `startBeat + offset`) so every field is re-clamped. ⚠️ `MIDINote.init`
   floors `startBeat` at 0 **per note** — a negative resolved offset would
   silently weld copies onto beat 0, so **reject a negative resolved offset
   with a field-named error** rather than letting the clamp eat it.
4. `MIDINote.canonicallyOrdered(existing + copies)`.
5. Compute `ClipAutoExtend.coverage(of: ordered, ids: freshIDs)` →
   `ClipAutoExtend.outcome(..., beatsPerBar: transport.meterMap
   .beatsPerBar(atBeat: clip.startBeat), maxLengthBeats:
   trailingHeadroom(...))`. Set `lastAutoExtendOutcome` (cleared **before**
   the guards, per `setClipNotes`' m25-a-2 rule). Skip entirely when
   `extendClip == false`.
6. `performEdit("Repeat Notes ×\(count)")` — **NO `key:`** — writes
   `notes`, writes `lengthBeats` if grown, runs `resolvingOverlaps` on the
   grow (belt and braces; `trailingHeadroom` has already made it a no-op),
   then `engine?.tracksDidChange(tracks)`.
7. Build and return the report.

### Step 3 — `Sources/DAWControl/Commands.swift`

- Add `"clip.repeatNotes"` to `allCommands`. Additive only; no existing entry
  renamed or removed. ⚠️ **The count pin moves by exactly +1 from whatever the
  `Reference commands` suite currently pins — read that number FROM THE SUITE,
  never from this document.** (See §1: my own scan of the array produced a
  contaminated figure.)
- New `case "clip.repeatNotes":` next to `clip.setNotes`, with
  `rejectUnknownKeys(["clipId","fromBeat","toBeat","noteIds","periodBeats",
  "count","firstCopyAtBeat","transposeSemitones","extendClip"], verb:
  "clip.repeatNotes", hint: "beats here are CLIP-relative, like
  clip.getNotes")`.
- Encode `NoteRepeatReport` directly. **No `notes` key in the response.**

### Step 4 — `mcp-server/src/server.ts`

- `registerTool("clip_repeat_notes", …)` — snake_case mirror, **no `daw_`
  prefix**, so the `audit-tools` command↔tool bijection stays green.
- ⚠️ **`.strict()` on the top-level schema AND on every nested object.** The
  M30 finding was that the gap was **17 schemas, not 2** — a nested object
  without `.strict()` silently accepts a typo'd field.
- Description must state, in order: beats are **clip-relative**; the window is
  **half-open**; **no notes are returned — read them with `clip_get_notes`**;
  `transposeSemitones` is **chromatic, not diatonic**; repeat **compounds** on
  re-run (undo, don't re-call); and it is **one undo step**.
- Guard against the `"undefined"` string coercion (M30).

### Step 5 — `claude-plugin/server/index.mjs`

**Generated.** Regenerate with `cd mcp-server && npm run bundle:plugin`. Never
hand-edit — the file's own first line says so. Bump the plugin version in
`claude-plugin/` manifest so `/plugin update` sees it.

### Step 6 — pins that change deliberately

- `Tests/DAWControlTests/` **`Reference commands`** suite: the `allCommands`
  count pin moves **+1 from its current value** — read the current value from
  the suite source, do not take a number from this document. This is an
  **expected, deliberate** change in the same PR, not a pin to be silenced.
  ⚠️ `grep -c 'registerTool('` is a naive count that lies, and a `grep -o` over
  the source array counts comment and `case` references too; the real pins are
  that suite and MCP's bijection test.
- `mcp-server/test/` bijection test: +1 tool.

### Step 7 — roadmap + changelog

Tick m31-c, note both halves, name what was deferred (`periodBars`, chord
mapping, parametric loop regions).

---

## 7. Test plan

**Swift, `Tests/DAWCoreTests/RepeatNotesTests.swift`:**

1. ⭐ **The coalescing regression — the one the naive implementation passes by
   never seeing it.** Drag/edit a note via `setClipNotes`, then call
   `repeatNotes` on the same clip **within the 800 ms window**, and assert the
   undo journal holds **TWO** entries and one ⌘Z restores the pre-repeat notes
   while leaving the drag applied. Then the reverse order (repeat, then a note
   edit within 800 ms) — also two entries. **Falsifiability check: this test
   must be shown to go RED when `key: "clip.notes:\(clipID)"` is planted on
   the `performEdit`.** A test that cannot be made to fail proves nothing.
2. Two rapid `repeatNotes` calls on the same clip = two undo entries.
3. **One ⌘Z undoes copies AND the length extension together** (assert both
   `notes` and `lengthBeats` restored by a single undo).
4. Copy geometry: `count: 11`, `periodBeats: 4` from a 4-beat window →
   `notesAdded == 11 * sourceNoteCount`, every copy's onset exact to
   floating-point tolerance, canonical ordering preserved.
5. ⭐ **Meter change.** Build a project with `MeterMap` 4/4 → 3/4 at bar 4,
   place the clip so the repeat span crosses the change, assert (a) offsets
   are still exact beat translations, (b) `meterChangesInSpan == 1`. Also
   assert `== 0` for the same repeat entirely before the change — **the
   negative control**, without which the field could be hardcoded to 1.
6. **Capped grow:** place a neighbouring clip so `trailingHeadroom` is
   insufficient, assert the clip grows only to the headroom, the neighbour is
   **not** trimmed or removed, `latentNotesPastClipEnd > 0`, and
   `extendRefusal` is non-nil.
7. `extendClip: false` → length unchanged, `latentNotesPastClipEnd` counts the
   copies past the end, notes still stored (m18-f legal-but-latent).
8. **Nothing to write** (empty window) → zeroed report, `isDirty` unchanged,
   undo journal depth unchanged. (Assert the dirty flag specifically — that is
   the failure `pasteClips`' rule exists to prevent.)
9. Guards: comp member → `clipInTakeGroup`; audio clip → `notAMIDIClip`;
   `periodBeats: 0` / `count: 0` / `count: 10000` / both `noteIds` and
   `fromBeat` / `transposeSemitones` length mismatch / negative resolved
   offset — each a distinct, field-named error.
10. `preExistingNotesInSpan` and `copiesOverlapEachOther` each with a
    positive **and** a negative case.
11. Transpose: scalar form, per-copy array form, and pitch clamping at 0/127
    — assert `pitchesClamped` counts the clamped notes, **with a negative
    control** (an untransposed repeat reports 0).

**Swift, `Tests/DAWControlTests/`:** wire round-trip; `rejectUnknownKeys`
rejects a typo'd key with the hint; the response JSON has **no `notes` key**
(assert the absence explicitly); the `allCommands` count pin updated to its
current value **+1**.

**TypeScript, `mcp-server/test/`:** bijection; schema `.strict()` rejects an
extra field **at the nested level too**; `"undefined"` string coercion.

**End-to-end (the one that proves the point):** compose a twelve-bar blues
drum part on **staging port 17695** as one bar + one `clip_repeat_notes` call,
then `clip_get_notes` and assert 149-ish notes at the expected onsets.
Measure the request+response bytes and record them against the 9.2 KB
baseline. ⚠️ **Port 17600 is the user's live app — never bind, contact or kill
it.**

---

## 8. Cost, risk, routing

**Cost:** roughly 250–350 lines of Swift (store method + report type + command
arm), ~120 lines of TypeScript, ~350 lines of tests. Call it **one focused
day** for the (A) half. The (B) documentation half is **one to two hours** and
should land first and separately.

**RT-safety:** none of this is on the render thread. The only engine contact is
the existing `engine?.tracksDidChange(tracks)` restart seam inside
`performEdit`, on the main actor, exactly as every other note verb does it. No
allocation, lock or dispatch is added to the render path.

**Full Xcode:** not required. No entitlements, no AUv3, no signing. Pure
`swift build` / `./scripts/test.sh` territory.

**Routing:**
- **(B) documentation** → `docs-scribe`, reviewed by `mcp-integration-engineer`
  for tool-description accuracy.
- **(A) store method** → this is the half with the undo trap in it. Spec above
  is written to be executable without judgment calls, so
  `mcp-integration-engineer` (sonnet) can build it — **but the coalescing test
  (#1, including its plant-and-redden falsifiability step) is the gate, and
  `daw-architect` should review the `performEdit` call before merge.** If the
  implementing agent reaches for `setClipNotes`, the design has been lost.
- **(A) wire + MCP + plugin regen** → `mcp-integration-engineer`.
- **Tests** → `qa-test-engineer`, briefed that #1 and #5 are the load-bearing
  ones and that #5 needs its negative control.

**Standing constraints for whoever builds this:** commits only on the user's
word; staging is 17695 and 17600 is the live app; `./scripts/test.sh`, never
bare `swift test`; never `git checkout`/`stash`/`restore`/`clean`; the wire is
additive-only.

---

## 9. What I am unsure of

Named rather than smuggled:

1. **Whether (A) is worth building at all** given SMF works. §1.1. The
   strongest counter-position is "document SMF, re-measure next dogfood
   round". I recommend building, but this is the call I would most want a
   second opinion on.
2. **`transposeSemitones`.** §2.3. It is the difference between serving and
   not serving the measured twelve-bar-blues case, but it is also the one
   field that goes beyond "literal copy" and the one an agent can most easily
   misuse (chromatic vs diatonic). Droppable without affecting anything else.
3. **Reporting the meter crossing instead of refusing it.** §4. Reporting is
   weaker. I do not know whether agents will read the field.
4. **The `count <= 512` ceiling is a judgment call**, not a measured limit. It
   exists so a typo fails loudly. If someone has a legitimate 1,000-copy case,
   raise it — but raise it deliberately.
5. **I have not measured** how often the dogfood arrangements were *actually*
   exactly-repetitive versus near-repetitive (a groove with a fill in bar 4).
   If near-repetition dominates, `repeatNotes` gets used and then immediately
   patched with `clip_set_notes`, and the saving is smaller than the 9x this
   document claims. **The e2e test in §7 is the cheapest way to find out, and
   its byte measurement should be recorded, not just asserted.**

---

## 10. For `docs/ARCHITECTURE.md` — "Key future decisions"

> **Pattern repetition on the write surface (m31-c, settled 2026-08-28).**
> Repetition is a write-surface primitive (`clip.repeatNotes` — literal
> time-shifted copies into the same clip, one uncoalesced undo step,
> counts-only response); **bulk composition is a file-transport problem**
> (`project.importMIDI` / `clip.importMIDI`, now documented as the
> bulk-composition path). The two are complementary and neither replaces the
> other. Rejected: a `repeat` argument on `clip.addMIDI` — that verb returns
> the whole encoded clip, so the expanded note array comes straight back
> across the wire, which is the cost the feature exists to remove. Deferred:
> `periodBars` (a fractional-bar pattern across a meter change has no
> defensible meaning), chord/voicing mapping, and parametric loop regions
> (a model change, not a verb).

