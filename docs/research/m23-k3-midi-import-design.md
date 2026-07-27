# m23-k3 — Standard MIDI File import onto the project

**Status: DECISIONS SETTLED, VERIFIED BY A SECOND ARCHITECT PASS. Implementation
not started.**
Architect read required by the `m23-k3` roadmap line. A second, independent
architect read (2026-07-26) verified every load-bearing claim against the tree,
attacked the decisions, and left its findings in the "Verification pass" section
immediately below — **read that first; it replaces two gate legs and two
rationales in the body, and the body has been edited to agree with it.** Route
after this doc: `swift-app-engineer`.

## Verification pass (second architect read)

**2026-07-26. A second `daw-architect` pass, independent of the first, run against
the tree before any code was written.**

**Verdict: the design survives. All 12 load-bearing claims CONFIRMED (two with
corrected citations — in one case the corrected citation makes the argument
*stronger*). Two GATE LEGS were MEASURED VACUOUS and are replaced. Four attacked
decisions SURVIVED, two of them with their rationale replaced by a better one.
Seven gaps closed. No row of §1's verdict table changed its verdict.**

### V.1 Claim-by-claim verification

| # | Claim as the document states it | Verdict | Evidence | Correction / note |
|---|---|---|---|---|
| **1** | `beatsPerBar`/`beatUnit` is the time signature **as written** and is user-facing (the claim §1.3's reversal rests on) | **CONFIRMED** — and the chain is stronger than the document had it | `Sources/DAWAppKit/TempoLaneModel.swift:145-157`; `Sources/DAWControl/Commands.swift:4287-4288`; **`Sources/DAWCore/ProjectStore.swift:625-626`**; `Sources/DAWControl/Commands.swift:5032` | Sites 1 and 2 are exact: `meterEdited` builds `MeterMap.Change(startBeat:beatsPerBar:beatUnit:)` from the user's typed pair, and `parseMeterMap` from the wire's pair, both verbatim. Site 3 was cited loosely — `Commands.swift:5032` formats `store.transport.timeSignature`, which is a `TimeSignature` (`Model.swift:1603-1611`), **not** a `MeterMap.Change`. The link the document was missing, and which actually closes the argument, is `applyTempoMap` at **`ProjectStore.swift:625-626`**, which copies `newMeterMap.changes[0].beatsPerBar` / `.beatUnit` **verbatim** into `transport.timeSignature`. So an adopted `Change(6, 8)` *becomes* `transport.timeSignature = 6/8`, which is exactly the pair `:5032` hands the AI as the string `"6/8"`. **§1.3's reversal is correct and the verbatim mapping is the only self-consistent choice.** |
| **2** | `importGeneration`'s empty-project predicate is `tracks.contains { !$0.clips.isEmpty }` | **CONFIRMED** verbatim | `Sources/DAWCore/ProjectStore+Generation.swift:61` | Note `:62` as well — `let wantsTempo = setProjectTempo ?? !projectHasClips`. The shipped importer already has D1's exact "explicit parameter overrides the auto predicate" shape. D1 is that pattern with a name, not a new idea. |
| **3** | `maxControllerLanesPerClip = 16` and `maxControllerPointsPerLane = 16384` both **throw** past the cap | **CONFIRMED**, with two nuances H7 must respect | declared `ProjectStore.swift:4741`, `:4745`; points throw `:4776-4779`; lanes throw `:4787-4789` | (a) The **lane** cap fires only when adding a *new* type (`!hasType` at `:4787`) — replacing an existing lane at the cap is legal. (b) The **point** cap is checked on the **raw** `points.count`, *before* `MIDIControllerLane.init` canonicalizes and dedupes. Since k3 builds `Clip` values offline and appends them, **neither guard ever runs** — `Clip.init` heals lanes through `canonicalControllerLanes` (`Model.swift:631`) and `canonicalPoints`' own doc says "NO size cap here" (`Model.swift:409-412`). G12's claim that the mapper is the program's only enforcement of these caps is CONFIRMED. |
| **4** | CC 64 (sustain) is the ONLY CC DAW Pro's built-in instruments act on | **CONFIRMED** verbatim | `Sources/DAWCore/Model.swift:237-238` | "Built-in instruments honour CC 64 (sustain); every other CC is forwarded to hosted Audio Units (design-m16b §4.3)." H7's priority head is engine-aware, as claimed. |
| **5** | k1 splits format 0 by channel but does **not** split a multi-channel format-1 `MTrk` | **CONFIRMED** — both halves, including the format-1 half that drives the decision | `StandardMIDIFileReader.swift:90-92`: `format == .singleTrack ? rawTracks.flatMap(splitByChannel) : rawTracks.map(wholeTrack)`. `wholeTrack` (`:494-497`) passes `channels: raw.channels` through **whole**. `SMFTrack.channel` is nil unless `channels.count == 1` (`StandardMIDIFile.swift:193-195`). | §3.1's uniform `(sourceTrackIndex, channel)` split is the right fix. **Format 2 takes the same `wholeTrack` branch**, so D4′ inherits the split as well — worth stating, since a format-2 chunk is even more likely to be multi-channel. |
| **6** | `MIDIControllerLane` allows at most one lane per type per clip (H5's data-loss argument) | **CONFIRMED**, and the loss mechanism is exact | `Model.swift:373-374`; dedupe rule `Model.swift:408` and `:428-430` | Merging ch 0's and ch 1's `cc(11)` puts two values on one beat, and `canonicalPoints`' equal-beat **last-wins** dedupe silently eats the earlier one. The data loss is not hypothetical. |
| **7** | Reader specifics (vel-0 note-off; `0xC0` and `0xA0` parsed-and-discarded; the anti-conjure comment) | **CONFIRMED**, all four | vel-0 → note-off `StandardMIDIFileReader.swift:361-374`; `0xA0` `:380-389` with the comment at **`:383-385`**; `0xC0` `:401-409` | Bonus finding that **strengthens H6c**: a *dangling* note-on is closed with `lengthTicks = max(0, resolvedEndTick - pending.tick)` (`:466`), which is **0** whenever the dangling onset sits at or past `endTick`. H6c therefore has two producers (same-tick note-off, and a dangling onset at/past end-of-track), not one. |
| **8** | A CC-only MIDI clip (no notes, some controllers) is supported | **CONFIRMED** | `Model.swift:533-535`: "A CC-only clip is legal as `notes: []` + lanes." | The document cited `:534`; the sentence spans `:533-535`. D4's content discriminator is right. |
| **9** | Controller lanes ride the `ClipKey` that drives schedule rebuilds | **CONFIRMED** verbatim | `ProjectStore.swift:4797-4799` | The `tracksDidChange` requirement in §6 Step 2 is real and is not catchable by a model-level test. |
| **10** | `decode(contentsOf:)` exists; `importSampleLibrary` checks `FileManager.fileExists` before decoding | **CONFIRMED**, with an **order** correction | `StandardMIDIFileReader.swift:27-29` (`contentsOf:`) and `:36` (`Data`); `ProjectStore+SampleLibraries.swift:50` | The precedent's order is **extension check first (`:41-49`), existence second (`:50`)** — the reverse of what §6 Step 2 said. Corrected below, so a non-existent `.txt` says "not a MIDI file" exactly as the shipped importer does. Also confirmed and worth pinning: `dryRun` returns at `:69` **before** the `noPlayableZones` refusal at `:70-72`, so §3.3b's "a dry run never refuses on this ground" is the precedent, not an invention. |
| **11** | `TempoMap.beat(atSecondsFromZero:)` exists and is the SMPTE path's function | **CONFIRMED** | `Sources/DAWCore/TempoMap.swift:201` | |
| **12** | `setTempoMap` refuses while recording; `applyTempoMap` is the internal core that bypasses that guard | **CONFIRMED** | refusal `ProjectStore.swift:567-569`; core `:611`; `meterMap: nil` leaves the meter untouched `:623` | D1″'s up-front `transport.isRecording` check is necessary, and §2.5's meter-only reasoning is exact. |

**Supporting counts, re-measured today with the house recipe** (`registerTool` with the
name possibly on the next line; the quoted names inside the `allCommands` array literal):
`allCommands` = **154**, tail `… reference.compare, note.audition, track.reorder`;
MCP `registerTool` names = **157**, of which **0** carry a `daw_` prefix. §4's
154 → 156 / 157 → 159 arithmetic and the no-prefix rule are CONFIRMED.

### V.2 Measured results — the part of this pass that cannot be re-derived from the document

All three run as IEEE-754 `double` in C at `-O2`, which is the same arithmetic
Swift's `Double` performs. Scripts were scratchpad-only; the numbers are below so
they never have to be re-run to be believed.

#### M1 — **G1 as written is VACUOUS, and §2.1's rationale is false for every division a MIDI file actually uses**

| Test | Result |
|---|---|
| `Double(k·t) * (1.0/Double(t)) == Double(k)` for t ∈ {1, 24, 48, 96, 120, 128, 192, 240, 256, 360, 384, 480, 500, 960, 1000, 1024, 1920, 3840, 7680, 15360}, k ∈ [1, 10⁶] | **0 failures at every one of those t.** The reciprocal-multiply never misses an integer beat at any real-world division. |
| the same, swept over t ∈ [1, 4000], k ∈ [1, 20000] | 985 of 4000 t values fail *somewhere*. First is **t = 49, failing at k = 1**; then 75, 77, 91, 93, 98, 99, 103, 105, 107, 117, 123 … **None of the divisions SMF files use is in that set.** |
| t = 480, positions on the 1/1, 1/2, 1/3, 1/4, 1/6, 1/8, 1/12, 1/16, 1/24 and 1/32-beat grids, k ∈ [0, 10⁵] | **0 divergence on every grid, triplets included.** |
| t = 480, **every** tick in [0, 2·10⁶] | **185,753 divergent (≈ 9.3 %), first at tick 23.** |

The reciprocal-multiply differs from the correctly-rounded quotient **only at
unquantized ticks** — never at an integer beat, never at a quantized musical
position. So G1's stated leg (`beats(k·t) == Double(k)` for t ∈ {480, 96, 15360, 1})
**cannot fail**, and its stated justification — "the reciprocal-multiply rounds
twice and can miss an integer beat by 1 ulp" — is false at every division that
matters. "Nothing else in the gate catches it" was catching nothing either.

**The rule is kept, its argument and its leg are replaced.** The single division
is the correctly-rounded answer *by definition*, it is the shorter code, and at
import scale (a control-plane parse of tens of thousands of events, never the
render thread) hoisting a reciprocal buys nothing measurable. That is the honest
case for it — not an audible-fidelity claim. See §2.1 and G1a/G1b.

#### M2 — **G2's stated example is numerically false; the leg needs a non-dyadic length**

§2.1's prose claimed "sixteen identical eighth-notes at sixteen different
positions can come out with three different `lengthBeats` values."

| t | `lengthTicks` | in beats | endpoint-subtraction divergence on the 1/16 grid (20,001 positions) | over every tick (200,001) |
|---|---|---|---|---|
| 480 | **160** (t/3, triplet eighth) | 1/3 | **19,998** | 199,882 |
| 480 | 240 (plain eighth) | 1/2 | **0** | 1,205 (first at tick 4) |
| 480 | 120 (sixteenth) | 1/4 | **0** | 667 |
| 96 | 32 (t/3) | 1/3 | **19,998** | 199,975 |
| 120 | 40 (t/3) | 1/3 | **19,996** | 199,969 |

The document's own example measures **0 of 20,001** — a leg written from it would
be vacuous. The discriminator is a length whose beat value is **not a dyadic
rational**; `t/3` is the canonical choice. G2 is respecified and the false prose
deleted.

#### M3 — **D2's exactness claim CONFIRMED, and now exhaustive rather than argued**

| Test | Result |
|---|---|
| `Int((60e6 / (60e6/Double(µ))).rounded()) == µ` for **every** µ ∈ [150000, 3000000] — all 2,850,001 values | **0 failures.** |
| worst absolute error of the recovered µ over that window | **4.65661 × 10⁻¹⁰, at µ = 2,807,175** — inside the document's argued ≤ 6.7 × 10⁻¹⁰ bound (which is itself correct: µ·2·2⁻⁵³ at µ = 3·10⁶ is 6.66 × 10⁻¹⁰), and three orders of magnitude under the 0.5 rounding threshold. |
| the same over the full 24-bit µ domain [1, 16777215] **with** the `Segment.init` clamp applied | 13,927,214 failures, first at µ = 1 — **exactly the complement of the clamp window**, i.e. exactly the set H1 reports. |

**"H1 and D2 close each other" is now a verified theorem over the whole 24-bit
domain, not an argument.** G3 gains µ = 2,807,175 as a named input: no sampling
scheme finds the extremum, so a sampled leg that omits it is weaker than it looks.

### V.3 Decisions and legs I CHANGED

1. **G1 → G1a (invariant) + G1b (discriminator)**, and §2.1's rationale rewritten. Cause: M1. The integer-beat identity is genuinely valuable — it is what makes `note.startBeat == 4.0` assertable — but it holds under *both* implementations, so it is labelled an invariant and can never be re-promoted to a discriminator by a future reader. G1b is stated as **both halves** (`== Double(23)/Double(480)` **and** `!= Double(23) * (1.0/Double(480))`) because a one-sided equality invites `let expected = 23.0 * recip`, which passes under either implementation and re-opens the vacuity.
2. **G2 respecified to `lengthTicks = 160` at t = 480, and scoped metrical-only.** Cause: M2, plus the SMPTE scoping gap in V.3.4. Under a non-constant project tempo map, equal `lengthTicks` at different positions *should* produce different `lengthBeats`; a bit-identity leg on the SMPTE path would be asserting a bug.
3. **§2.3 step 2 (the re-sort) DELETED.** `StandardMIDIFileReader.swift:85-88` already returns `tempoChanges` and `timeSignatures` sorted by `(tick, sourceTrackIndex)`. Re-sorting is not merely redundant: **Swift's `sorted(by:)` is documented as NOT guaranteed stable**, so a second sort on the same key would shuffle the relative order of two events sharing a `(tick, sourceTrackIndex)` — destroying the only tie-break H3 has left. The mapper must consume the array **in the order it arrives** and keep the first at each distinct tick.
4. **§2.2 gains the SMPTE note-length rule, and R3's prohibition is scoped to metrical.** The document specified SMPTE *position* (R9–R11) and never said how a note's *length* is computed there. There is no `t` on the SMPTE path, so `lengthBeats` **must** be `beats(tick + lengthTicks) − beats(tick)` — precisely the endpoint subtraction R3 forbids. Left unscoped, R3 and §2.2 contradict each other on day one.
5. **§2.3 gains a malformed-tempo step (µ ≤ 0), mirroring §2.4's malformed-meter step.** `FF 51 03 00 00 00` is a well-framed event k1 accepts (`:292` requires only `length == 3`), and `60_000_000.0 / 0.0` is `+infinity`. It survives `Segment.init`'s clamp as 400 BPM and would be reported by H1 as "requested BPM inf" — a sentence no user should read. Drop it, report it, and keep `droppedMalformedTempoEvents` **distinct from** `fileCarriedNoTempoMap`: a file whose only tempo events were malformed did assert a map, it just asserted an unusable one, and that is not H4c.
6. **§2.4's barline test now uses `MeterMap.init` itself as the oracle** instead of re-implementing the formula. `MeterMap.barlineEpsilon` is **private** (`TempoMap.swift:375`), so "copy the epsilon verbatim" would create a second home for a constant the design's own ONE-home doctrine forbids. `try MeterMap(changes: accepted + [candidate])` *is* the model's validation, cannot disagree with it, and — because the last successful call constructs exactly the array step 7 returns — removes the "must not `try!`" worry for the meter map entirely.
7. **H7's decimation runs on the CANONICAL point list.** `MIDIControllerLane.init` canonicalizes on construction (equal-beat last-wins dedupe, `Model.swift:408`), so a raw stream of 20,000 CC events that dedupes to 9,000 distinct beats needs **no** decimation at all. Decimating first throws away data the cap never objected to, and makes G12's post-condition approximate instead of exact.
8. **D1′ SURVIVES but its rationale is REPLACED — the stated one is factually weak.** "Offsetting a tempo map by `atBeat` would require synthesizing a leading segment … and would almost always violate `MeterMap`'s barline rule" does not hold up: `TempoMap` has **no** barline rule, so the tempo half of an offset adoption is trivially constructible; and the meter half is fine whenever `atBeat` is itself a barline, which is exactly where a UI drop would land it. The correct argument is structural: **`adopt` is defined as a wholesale REPLACE** (`applyTempoMap`, `ProjectStore.swift:611-628`), and an offset adoption is a **MERGE** — a different operation with its own unanswered questions (what becomes of the project's existing segments past `atBeat`? does re-importing the same file at a different beat produce a different map?). Refusing a self-contradictory *explicit* request beats silently performing a third operation under the name of the first. A `tempoPolicy: "merge"` is purely additive later.
9. **H3 SURVIVES but its rationale is TIGHTENED, and its report field upgraded.** "Lowest `sourceTrackIndex` is the conductor track for format 1" is stated as a fact; it is a **spec convention** (SMF 1.0 designates the first `MTrk` of a format-1 file as the tempo map track) that most but not all writers honour. Restated as such. And `conflictingDuplicateTempoEvents` / `…MeterEvents` are changed from `Int` to `[String]`: a bare count tells a user with the odd file shape (conductor **not** at chunk 0, plus a competing default at the same tick in a lower chunk) nothing actionable, and naming tick/beat/winner/loser costs one line. The report *is* the safety net for the one shape first-wins gets wrong.
10. **§3.2 gains one prohibition.** It tells the implementer to follow `importGeneration`'s shape, and that path sets `isAIGenerated = true` on **both** the track and the clip (`ProjectStore+Generation.swift:87`, `:90`). A MIDI import is not AI-generated, and "violet always means AI-generated" is a design-language rule. Copy the *structure*, not that field.
11. **§7.2's fixture set cut from seven new byte fixtures to ONE.** Six of the seven encode **mapping** decisions, not **parsing** claims, and the mapper's input is a `StandardMIDIFile` value — so a hand-built IR is the correct, cheaper, one-hazard-per-case input. **This scopes the ONE HAZARD PER FIXTURE law, it does not relax it**, and it comes with the rule that makes it safe: *every hand-built IR must be one the reader can actually produce, and where reachability is itself the claim, use bytes.* Only `hazard-type1-multichannel.mid` carries a genuine parsing claim (that k1 yields a format-1 `SMFTrack` with `channels.count == 2`), and it is also the most structural decision in the document — it stays bytes and stays Apple-validated.
12. **G7's journal leg gets a real seam.** "Compare a `project.snapshot` before/after" does not observe the undo journal. `store.undoHistory()` does (`ProjectStore.swift:147`, `UndoJournal.swift:115`), and it is exposed on the wire as `edit.history` (`Commands.swift:3678-3696`). Assert the `undo` label list is **identical** across a `dryRun`.
13. **§6 Step 2's file-check order reversed to match its own precedent** (extension, then existence — `ProjectStore+SampleLibraries.swift:41-50`).
14. **§3.3b's condition made operational**: `tracksCreated == 0 && tempoSegmentsAdopted == 0 && meterChangesAdopted == 0`, measured from the report — not from the requested policy, which can resolve to a no-op adoption (H4c) and would otherwise let a genuinely empty import return `ok: true`.

### V.4 Decisions I ATTACKED that SURVIVED

Stated as such because a surviving attack is evidence.

1. **§0's spine — "beats are affine in ticks; tempo is not in the loop." SURVIVES for metrical files, on every path.** I walked R2 (note start), R3 (note length), R4 (controller points), R5 (`clip.startBeat = atBeat`, user-supplied), R6 (`clip.lengthBeats` from `endTick`), R7 and R8. No tempo value enters any of them. The one place a sibling importer *does* pull tempo in — `importGeneration`'s `finalTempoMap.beat(from:elapsedSeconds:)` at `ProjectStore+Generation.swift:77-78` — is there because **audio is seconds-native**; MIDI is not, and the analogous line simply does not exist. The claim is not merely true, it is true *because* the IR is tick-native. **The SMPTE carve-out is genuine and was under-specified, not wrong** — see V.3.4.
2. **H4's (b)-versus-(c) distinction. SURVIVES**, and the argument for it is sharper than the document's. The sharpest attack is that the SMF spec defines the *default* tempo as 120 BPM and the default meter as 4/4, so a file with zero `FF 51` events "is" a 120 BPM file by the same rule that lets case (b) synthesize a 120 prefix — making (b) and (c) the same spec rule applied at two points, and the split arbitrary. The answer is that the discriminator is **"did the file assert anything about tempo at all?"**: the spec default is invoked only to *complete a map the file started*, never to *manufacture one it never began*. That line is coherent, it is the same line for meter, and it is what stops an `adopt` from stomping a user's 90 BPM project with a number their file never contained. The residual asymmetry — case (b) *does* overwrite the project's tempo for the span before the file's first event — is correct, because there the user asked to adopt a map that the spec says begins at 120.
3. **H3's first-wins with `(tick, sourceTrackIndex, index)`. SURVIVES.** The shape that breaks it is real but doubly rare: a format-1 file whose conductor track is **not** chunk 0 *and* which stamps a competing tempo at the same tick into a lower-numbered chunk. Last-wins loses to the common shape (every chunk carrying a default `FF 51 500000`, which would override a real conductor); a "prefer the chunk with no notes" refinement trades this failure for another (writers that put a marker note in the conductor track). First-wins is the spec's own tie-break and is right. Rationale tightened and the report upgraded to name the conflict — see V.3.9.
4. **`MIDIImportPlan.init` being `fileprivate`. The MECHANISM SURVIVES; the CLAIM MADE FOR IT DOES NOT.** The mechanism is sound and I checked the three holes: an explicit `init` **suppresses** the synthesized memberwise initializer (which would otherwise be `internal` and reachable from anywhere in DAWCore); `Equatable` and `Sendable` synthesize no initializer; and `fileprivate` genuinely means "this file only", so co-locating `SMFProjectMapper` makes `map` the single producer. **One load-bearing constraint must be written down or the hole reopens: `MIDIImportPlan` must NEVER gain `Codable`** — a public `Codable` struct synthesizes a public `init(from:)`, which is a second producer that no `fileprivate` can stop. But the *claim* the document makes for it — "k4's UI drag-drop path will want to just quickly work out where this lands, and the type must make that impossible" — **is not achieved**. Nothing about a `fileprivate` plan initializer prevents a k4 view from writing `Double(tick) / 480.0`. `ResolvedDropBeat` works because the *conversion* has one named home that downstream is typed on; here the conversion is free-floating arithmetic inside the mapper. Fix in §6 Step 1: give the conversion a home (`SMFTickClock`) and make it the only public way to turn a tick into a beat.

### V.5 Genuinely open — the user's call, not mine

Beyond §11's four (all of which I agree are the user's and all of whose defaults I would ship unchanged):

5. **The §1.3 × H2 interaction is a real user-visible consequence and I am choosing to accept it, but the user may not want to.** Because `beatsPerBar` is stored as the numerator and `MeterMap.init` divides by `beatsPerBar` to test the barline rule (`TempoMap.swift:402`), **any meter change after a non-4 denominator will usually be dropped by H2** — a 6/8 file with a 4/4 change at its own bar 2 (tick 1440 at 480 tpqn = beat 3) computes `bars = 3/6 = 0.5` and is dropped. The alternatives are worse (translating for the accept-test alone builds an array `MeterMap.init` itself rejects; translating for storage ships the numerator-12 bug into k4), so the drop stands, reported with a reason string that names the cause. But this is the most likely "why did my time signature change disappear" report the feature will generate, and it is a direct consequence of the ARCHITECTURE §8 entry-2 defect. If the user would rather the *bar-length* fix land before import ships, that reorders the roadmap — it is not a k3 decision.

---

Inputs read for this document. **Every line reference below was independently
re-checked by the second pass on 2026-07-26; two were imprecise and are corrected
in V.1 (rows 1 and 10). Files the second pass added to the evidence base:**
`Sources/DAWCore/GMProgramCatalog.swift` (`standardDrumKit` :120, `name(forProgram:)` :132),
`Sources/DAWCore/SoundBanks.swift` (`SoundBankConfig` :47-62),
`Sources/DAWCore/UndoJournal.swift` (`undoLabels` :115 — G7's real seam),
`Sources/DAWCore/MediaImporting.swift` (`ProjectError.transportBusy` :54).

| File | What it decided |
|---|---|
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/StandardMIDIFile.swift` | the tick-native IR (k1) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/StandardMIDIFileReader.swift` | what the reader keeps and discards (`0xA0` :380, `0xC0` :401) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/TempoMap.swift` | `Segment.init` bpm clamp (:41), `MeterMap` barline rule (:403), both maps' duplicate/first-at-zero rules (:77-81, :392-406) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/Model.swift` | `MIDINote` clamps (:128-131), `MIDIControllerType`/`Lane` (:234-454), `TimeSignature` (:1603) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore.swift` | `setTempoMap` (:566), `applyTempoMap` (:611), `addMIDIClip` (:3000), `setControllerLane` + caps (:4741-4802) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore+Generation.swift` | the atomicity precedent (`importGeneration`, whole file) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/SampleLibraries/SampleLibraryMapper.swift` | the report-type precedent (`SampleLibraryImportReport` :50) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/SampleLibraries/ProjectStore+SampleLibraries.swift` | the `dryRun`/`force` store precedent |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWControl/Commands.swift` | `tempo.setMap` (:475), `parseMeterMap` (:4274), `instrument.importSampleLibrary` (:886), `allCommands` tail |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWAppKit/TempoLaneModel.swift` | `meterEdited` (:145) — the UI's meter producer |
| `/Users/dsemenov/Views/daw-pro/Tests/DAWCoreTests/Fixtures/SMF/README.md` | fixture doctrine + the existing expectation table |

---

## 0. The spine: beats are AFFINE IN TICKS, and tempo is not in the loop

For a metrical file (`division == .ticksPerQuarterNote(t)`):

```
beats(tick) = Double(tick) / Double(t)
```

**No tempo value appears in that expression.** DAW Pro's beat is a quarter note
everywhere (`MeterMap`'s own doc: "a beat is a quarter-note duration unit
everywhere"), and SMF's metrical division is ticks per quarter note. Tempo maps
seconds onto beats; it never maps ticks onto beats.

This single fact decides the shape of the whole item:

- **Every tempo hazard (H1, H3, H4, D1, D2) is a PLAYBACK-SPEED hazard, never a
  NOTE-POSITION hazard.** A tempo clamped from 60,000,000 BPM to 400 leaves every
  note on exactly the beat the file said. That is why the verdicts below are
  "accept-lossily + report" rather than "refuse": the notes — the thing the user
  actually cares about — are never at risk.
- **The gate's headline claim ("notes land on the right BEATS") is testable with
  zero tempo involvement.** Do not let a gate leg couple the two.
- **The one carve-out is SMPTE division** (§2.2). There, ticks are absolute time,
  beats are derived through the project tempo map, and a clamped BPM *does* move
  notes — and note **lengths** are derived by endpoint subtraction, because no
  `t` exists to divide by (§2.2, R12). State the carve-out wherever the invariant
  is quoted, and scope every rule that depends on affinity — R3, G2 — to metrical
  files explicitly.

---

## 1. Verdict table

Verdict vocabulary: **refuse** = the command throws, nothing is mutated;
**warn** = the operation proceeds and the loss is named in the returned
`MIDIImportReport` (§5); **accept-lossily** without a warn qualifier is never
used — every loss in this design is reported.

### 1.1 The seven measured hazards

| # | Hazard | Verdict | Rule | Rationale (one line) |
|---|---|---|---|---|
| **H1** | `TempoMap.Segment.init` silently clamps bpm to 20…400 | **warn** | **First drop any event with `µsPerQuarter <= 0`** (§2.3 step 3.5) — it is malformed, not merely extreme, and `60_000_000.0 / 0.0` is `+infinity`, which survives the clamp as 400 BPM and would print to the user as "requested BPM inf". Then compute `bpm = 60_000_000.0 / µsPerQuarter` and compare against `TransportState.tempoRange` BEFORE constructing the segment; if outside, still build it (the clamp applies) and add one `clampedTempoEvents` entry naming tick, beat, requested BPM and effective BPM. | Notes are tick-affine, so a clamped tempo changes only playback speed; refusing an otherwise-good file over one absurd `FF 51` is hostile, and silence is the only unacceptable option. |
| **H2** | `MeterMap` refuses a change that is not on a barline of the meter accumulated before it | **warn** (drop the change) | Walk the file's meter changes in tick order, maintaining the accepted-so-far `MeterMap`. A change whose beat is not within `1e-9` of a barline of the accepted prefix is **dropped** and reported (`droppedMeterChanges`, with tick, beat and the meter it declared). The accumulation is over the POST-DROP prefix, so the rule is well-defined and order-dependent by construction. | Snapping would silently move the downbeat grid to a place the file never named; synthesizing a pickup bar would invent a meter change no other program shows. Dropping changes only the bar *numbering*, never a note, and it is the one option the report can state exactly. |
| **H3** | Both maps throw on duplicate `startBeat`; format-1 files routinely carry several `FF 51` at the same tick in different tracks | **warn** (first wins) | Consume `file.tempoChanges` / `file.timeSignatures` **IN THE ORDER THEY ARRIVE** and keep the **FIRST** at each distinct tick. **DO NOT re-sort** — k1 already returns both arrays sorted by `(tick, sourceTrackIndex)` (`StandardMIDIFileReader.swift:85-88`), and Swift's `sorted(by:)` is *not* documented stable, so a second sort on the same key would shuffle the relative order of two events sharing a `(tick, sourceTrackIndex)` and destroy the only remaining tie-break. Report a duplicate ONLY when the discarded event's value differs from the winner's (`conflictingDuplicateTempoEvents` / `…MeterEvents`, each an ARRAY of sentences naming tick, beat, the winning value and the discarded one). | SMF 1.0 designates the FIRST `MTrk` of a format-1 file as the tempo-map track, so lowest `sourceTrackIndex` is the **spec's own tie-break**, not a heuristic of ours — and for format 0 there is only one chunk. This is the rule that defeats the real-world failure mode: exporters that stamp a default `FF 51 500000` into EVERY chunk would, under last-wins, override a conductor track that says 90 BPM. The shape first-wins gets wrong — a conductor that is NOT chunk 0, plus a competing event at the same tick in a lower chunk — is doubly rare, and the named report entry is its safety net, which is why the field is a `[String]` and not a count. Identical duplicates are noise, not loss, so they are not reported. |
| **H4** | The first segment/change must start at beat 0 | **warn** when synthesized, **no-op** when absent | Three cases, kept distinct: (a) ≥1 event and the first is at tick 0 → use as-is. (b) ≥1 event and the first is at tick > 0 → **prepend** the SMF default (`bpm 120` / `4/4`) at beat 0 and report it (`synthesizedLeadingTempo` / `…Meter`). (c) **ZERO events of that kind → the file has NO map of that kind.** `fileTempoMap` / `fileMeterMap` is `nil`; adoption of that map becomes a no-op and is reported. | Case (c) is the trap: synthesizing 120 BPM for a file with no tempo events and then "adopting" it would stomp a user's 90 BPM project with a number the file never contained. **The discriminator is "did the file ASSERT anything about tempo at all?" — the spec default is invoked only to COMPLETE a map the file started, never to MANUFACTURE one it never began.** (This is the answer to the obvious attack, that SMF defines 120 BPM / 4/4 as the default so (b) and (c) are the same rule at two points. They are not: in (b) the user asked to adopt a map, and 120-before-the-first-event is that map's spec-defined content.) **A fourth case is NOT case (c):** if every event of a kind was DROPPED as malformed (§2.3 step 3.5 / §2.4 step 3), the file did assert a map — an unusable one. `fileTempoMap` is nil, but `fileCarriedNoTempoMap` stays **false** and `droppedMalformedTempoEvents` carries the reason. |
| **H5** | `MIDINote` carries no channel and no release velocity | **channel: PRESERVED by splitting** (structural). **Release velocity: warn** | (a) **Confirmed your reading, and it does not go far enough.** k1 splits format 0 by channel, but a format-**1** `MTrk` may also carry several channels (`SMFTrack.channels` is an array and `channel` is nil when count ≠ 1) and k1 does NOT split those. k3 therefore splits **uniformly**: the DAW track set is the enumerated set of `(sourceTrackIndex, channel)` pairs, regardless of format. See §3. (b) Release velocity has no home in `MIDINote`; report the count of notes whose `releaseVelocity ∉ {0, 64}` as `notesWithDroppedReleaseVelocity`. | Merging channels into one DAW track would (i) point one mono-timbral instrument at several parts and (ii) **destroy controller data**: `MIDIControllerLane` allows at most one lane per type per clip, so `cc(11)` on channel 0 and `cc(11)` on channel 1 would collide and the equal-beat last-wins dedupe would eat one of them. Splitting is the only mapping the model can represent. 0 and 64 are the two conventional "no information" release velocities (0 is also what a `9n`-velocity-0 note-off produces), so reporting them would make the field noise on every ordinary file. |
| **H6** | `MIDINote` clamps `velocity`, `startBeat`, `lengthBeats` | **velocity: structurally impossible. startBeat: structurally impossible. lengthBeats: warn** | (a) `SMFNote.velocity` is 1…127 by construction (velocity 0 IS a note-off — reader :367), so the 1…127 clamp can never fire. (b) SMF delta times are unsigned VLQs, so absolute ticks are monotone non-decreasing from 0, and the clip origin is file tick 0 (§3.3), so clip-relative beats are ≥ 0 by construction. (c) `lengthBeats = Double(lengthTicks)/Double(t)` CAN land under `MIDINote.minLengthBeats` (0.001) — a 0-tick note, or any note under `t/1000` ticks. **Zero-tick notes have TWO producers, not one:** a note-off at the note-on's tick, and a DANGLING note-on at or past `endTick`, which k1 closes with `lengthTicks = max(0, resolvedEndTick - pending.tick)` (`StandardMIDIFileReader.swift:466`) — the second also raises an `SMFWarning.danglingNoteOn`, so the two are distinguishable in the report. Report `notesStretchedToMinimumLength` with the count and the shortest requested length. | (a) and (b) are worth *stating* precisely because a future reader will otherwise add a defensive warning that can never fire — a vacuous report field is worse than none. (c) is real: at 15360 tpqn a 1-tick note is 0.000065 beats and is stretched ~15×. Sonically it is 0.5 ms at 120 BPM (nothing), but it is a fidelity claim and it breaks k4's tick round-trip at high divisions, so it must be counted. |
| **H7** | `ProjectStore.maxControllerLanesPerClip = 16` (throws past the cap); `maxControllerPointsPerLane = 16384` (throws past the cap) | **warn** (both) | **Lanes:** rank by the fixed priority list `[pitchBend, channelPressure, cc64, cc1, cc11, cc7, cc10]`, then remaining CCs by `(pointCount descending, controller ascending)`. Keep the first 16; drop the rest and report each by `wireKey` with the point count dropped (`droppedControllerLanes: [String: Int]`). **Points:** measure and decimate the **CANONICAL** point list, not the raw event stream — `MIDIControllerLane.init` canonicalizes on construction (equal-beat last-wins dedupe, `Model.swift:408`), so 20,000 raw CC events that dedupe to 9,000 distinct beats need no decimation at all, and decimating first would discard data the cap never objected to. A canonical lane over 16384 points is **decimated** — keep every `ceil(n/16384)`-th point, always keeping the first and the last — and reported (`decimatedControllerLanes`). Re-canonicalizing the decimated set is idempotent, so `lane.points.count <= 16384` holds exactly (G12). | Refusing an import over a controller cap sacrifices the notes to protect a CC lane. A pure "most points" rule would drop CC 64 (sustain, often a handful of points) in favour of dense controller spam — and CC 64 is the **only** CC DAW Pro's built-in instruments act on (`MIDIControllerType` doc: "built-in instruments honour CC 64 (sustain); every other CC is forwarded to hosted Audio Units"), so the priority head is engine-aware, not arbitrary. Lanes are stepwise, so decimation coarsens a ramp; truncating the tail would leave a stuck value. |

### 1.2 The four already-named decisions

| # | Decision | Verdict | Rule | Rationale |
|---|---|---|---|---|
| **D1** | Tempo-map conflict policy | **`auto` (default) / `adopt` / `ignore`. `ask` is NOT a core policy.** | Wire param `tempoPolicy`, default `auto`. `auto` resolves to `adopt` **iff** `!tracks.contains { !$0.clips.isEmpty }` — the EXACT predicate `importGeneration` uses (`ProjectStore+Generation.swift:61`) — else `ignore`. `adopt` replaces both maps through `applyTempoMap` **inside the import's single `performEdit`**. `ignore` leaves both untouched. The report always echoes the RESOLVED policy. | Reusing `importGeneration`'s predicate verbatim keeps ONE definition of "is this project empty enough to adopt into"; a novel refinement (also requiring an untouched tempo) would make two shipped importers disagree about the same question. **`ask` is deliberately absent from the core and the wire**: a headless, agent-driven command must never block on a human. k4's UI may show a dialog whose two buttons send `adopt` or `ignore` — the UI chooses between the two policies the core implements, it is not a third one. |
| **D1′** | `adopt` × non-zero `atBeat` | **refuse** (explicit) / resolve to `ignore` (auto) | Tempo and meter maps are ABSOLUTE (beat 0 of the project). An explicit `tempoPolicy:"adopt"` with `atBeat != 0` throws a teaching error naming the contradiction and both escapes. `auto` with `atBeat != 0` simply resolves to `ignore`. | **`adopt` is DEFINED as a wholesale REPLACE** (`applyTempoMap`, `ProjectStore.swift:611-628`). An offset adoption is a **MERGE** — a different operation, with its own unanswered questions: what becomes of the project's existing segments past `atBeat`, and why does re-importing the same file at a different beat give a different map? Refusing a self-contradictory explicit request beats silently performing a third operation under the first one's name. A `tempoPolicy: "merge"` is purely additive later. *(Note for anyone re-opening this: the tempting rationale "offsetting would violate `MeterMap`'s barline rule" is WEAK and was removed — `TempoMap` has no barline rule at all, and the meter half is perfectly constructible whenever `atBeat` is a barline, which is exactly where a UI drop lands it. The argument is structural, not arithmetic.)* |
| **D1″** | Import while recording | **refuse** (both commands, every policy) | Pre-check `transport.isRecording` at the top of both store methods and throw `ProjectError.transportBusy("cannot import a MIDI file while recording — stop first")`. | `setTempoMap` already refuses while recording, and the import folds tempo adoption *inside* its own `performEdit` (bypassing that guard, exactly as `importGeneration` bypasses `setTempo`'s multi-segment guard). Without an up-front check the behaviour would silently differ by policy. Refusing uniformly is one sentence to explain and has no half-state. |
| **D2** | BPM authority | **µs/quarter → BPM is the authoritative direction on import; `bpm: Double` is what the project stores; k4 exports by rounding the reciprocal.** | Import: `bpm = 60_000_000.0 / Double(microsecondsPerQuarterNote)` — a single IEEE-754 division, **no rounding, no snapping to "nice" values**. Export (k4, inherited): `µs = Int((60_000_000.0 / bpm).rounded())`. | The decision is forced for storage: `TempoMap.Segment` has one tempo field and adding a second (µs/qn) would create a second home for tempo and a disk-format change. Given that, full-precision division is the only choice that makes k4's inverse exact. **The round-trip is EXACT over every tempo the project can hold, and this is MEASURED, not argued** (V.2 M3): all 2,850,001 values of µ ∈ [150000, 3000000] (bpm 400…20, the clamp window) round-trip with **zero** failures, worst absolute error **4.65661e-10 at µ = 2,807,175** — matching the analytic bound (each division carries ≤ 0.5 ulp, so the recovered µ differs by ~µ·2.2e-16 ≤ 6.7e-10) and sitting three orders under the 0.5 rounding threshold. Over the full 24-bit µ domain with the clamp applied, the 13,927,214 failures are **exactly** the complement of the clamp window. **H1 and D2 close each other: the set of µ that does not round-trip IS the set the clamp reported — verified, not asserted.** |
| **D3** | Program change + poly aftertouch | **Program change: captured, reported, applied only on OPT-IN (`instruments:"gm"`; default `"none"` in k3). Poly aftertouch: warn (count only).** | k3 extends the IR additively (§6 Step 0): `SMFTrack.programChanges: [SMFProgramChangeEvent]` (tick, channel, program) and `SMFTrack.polyAftertouchEventCount: Int`, both defaulted so no existing call site or test changes. The mapper always reports the program a part asks for (`parts[i].programChange`, resolved as the FIRST program change on that part's channel; later ones reported as `droppedProgramChanges`). With `instruments:"gm"` it sets `InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(source: .generalMIDI, program: p, bankMSB: 121, bankLSB: 0, displayName: GMProgramCatalog.name(forProgram: p)))`, and **channel 9 (0-based) maps to `GMProgramCatalog.standardDrumKit` (bankMSB 120, program 0) regardless of any program change**. Poly aftertouch is never mapped; its count rides the report. | **The default is `"none"` and that is a deliberate, evidence-based retreat.** Nothing in the tree assigns sound-bank instruments in bulk and no per-prepare cost is recorded anywhere; the AU-hosting wedge in this project's history cost minutes on the main actor. Deciding k3's shipped default on one un-replicated timing taken during its own gate would be guessing. So k3 computes and reports the whole GM mapping (all the value, none of the risk) and k4 — which owns the UI, can show progress, and can measure on real files — flips the default. Poly aftertouch is explicitly deferred past v1 by `MIDIControllerType`'s own doc ("a different model shape"); k3 does not reopen that, it only stops the loss being silent. |
| **D4** | The conductor track | **skip** (report) | A part with `notes.isEmpty && controllers.isEmpty` produces **no DAW track**. It still appears in the report's `parts` array with `imported: false, skipReason: "no notes or controller data"`. | Its tempo/meter payload was already hoisted to file level by k1 and lands on `TempoMap`/`MeterMap`, so nothing is lost — an empty instrument track would be pure clutter. Note the discriminator is notes+controllers, **not** `channels.isEmpty`: they coincide today (only note/CC/bend/pressure events insert into `channels`) but the content test is the one that means what we want. A CC-only part (no notes, some controllers) IS content and IS imported — `Clip` supports CC-only MIDI clips (`Model.swift:534`). |
| **D4′** | Format 2 (`independentSequences`) | **warn** (treated as simultaneous) | Mapped exactly like format 1 — every part starts at `atBeat` — with a report line stating that the file declares independent sequences and DAW Pro laid them out simultaneously. | Format 2 is vanishingly rare and a sequential layout is a musical judgement with no third-party reference to check against. Simultaneous is deterministic, matches format 1, and the report tells the truth. A sequential option is additive later. |

### 1.3 One decision REVERSED during this read — meter numerator/denominator

My first pass mapped SMF `nn/2^dd` to `beatsPerBar = numerator·4/denominator`,
`beatUnit = denominator` (so 6/8 → `(3, 8)`), on the argument that
`MeterMap.Change.beatsPerBar` is what the bar-grid math divides by
(`TempoMap.swift:402`, `:448`) and is therefore in quarter-note units, and that
the pair stays invertible.

**That is wrong, and the tree says so.** `beatsPerBar` is NOT import-private:

- `Sources/DAWAppKit/TempoLaneModel.swift:145-157` (`meterEdited`) passes the
  user's typed `beatsPerBar`/`beatUnit` through verbatim.
- `Sources/DAWControl/Commands.swift:4287` (`parseMeterMap`) takes the wire's
  `beatsPerBar`/`beatUnit` verbatim.
- `Sources/DAWControl/Commands.swift:5032` formats the pair for the AI as
  `"\(sig.beatsPerBar)/\(sig.beatUnit)"` — i.e. **the pair IS the time signature
  as written.**

A translating importer would put two incompatible encodings of the same meter
into one model, distinguishable only by provenance, and k4's export of a
user-authored `(6,8)` would emit numerator `6·8/4 = 12` — shipping a bug into k4
as a direct consequence.

**SETTLED: `beatsPerBar = numerator` and `beatUnit = denominator`, verbatim.**
`6/8` imports as `(6, 8)`. Import agrees with hand-entry, k4's export is the
identity, and **the integrality/drop rule for non-4 denominators disappears
entirely** — 7/8, 5/8 and 6/16 all import cleanly with no report line.

What we give up: for any denominator ≠ 4 the bar grid is the wrong length —
`beat(ofBar:)` will treat 6/8 as six quarter notes. That is the **v1 meter
model's existing, uniform limitation**, identical for hand-entered meters, and
not something an importer should paper over on its own. Two consequences:

1. Two guards the mapper still needs: `denominatorPower` outside the
   representable range (`SMFTimeSignatureEvent.denominator == nil`, e.g. `dd =
   255`) and `numerator <= 0` are **dropped + reported** — those are malformed,
   not merely unrepresentable, and `Change.init`'s `max(1,…)` would silently turn
   `0/4` into `1/4`.
2. It is the genuine architectural finding of this read and goes in
   `docs/ARCHITECTURE.md` "Key future decisions" (§8).
3. **A consequence the first pass missed, and the single most likely support
   question this feature will generate.** `MeterMap.init` tests the barline rule
   by dividing by `beatsPerBar` (`TempoMap.swift:402`). With the verbatim
   mapping, `beatsPerBar` is the *numerator*, so for any denominator ≠ 4 the
   divisor is the wrong bar length — and **a meter change that sits exactly on
   the FILE's barline is off OUR barline and gets DROPPED by H2.** Worked
   example: `FF 58` 6/8 at tick 0, then 4/4 at the file's bar 2 (tick 1440 at 480
   tpqn = beat 3). We compute `bars = (3 - 0) / 6 = 0.5`, not a whole number, so
   the change is dropped. This is accepted, not fixed: translating for the
   accept-test alone would build an array `MeterMap.init` itself rejects, and
   translating for storage ships the numerator-12 bug into k4. What k3 owes the
   user is a **distinguishable reason string** in `droppedMeterChanges` — one
   that names the cause ("this file's 6/8 bars are 3 quarter notes long; DAW Pro
   v1 counts a 6/8 bar as 6 quarter notes, so the change at beat 3 is not on a
   barline of that grid") and points at the §8 entry-2 defect rather than reading
   as a parse failure. It needs **no new byte fixture** — it is a hand-built-IR
   mapper case (§7.2).

---

## 2. The tick → beat mapping rule

Precise enough to implement and to test against. This is the core of the read.

### 2.1 Metrical division — `SMFDivision.ticksPerQuarterNote(t)`

`t >= 1` is guaranteed: the reader throws `SMFDecodeError.invalidDivision` on 0.

```
beats(tick)  =  Double(tick) / Double(t)                       // (R1)
```

**R1 is a SINGLE DIVISION of two exactly-representable integers.** It must NOT be
implemented as `Double(tick) * reciprocal` with `reciprocal = 1.0/Double(t)`
hoisted out of a loop.

**The honest reason, corrected by measurement (V.2 M1) — the first pass's reason
was false.** It is *not* true that "the reciprocal-multiply can miss an integer
beat by 1 ulp": measured over t ∈ {1, 24, 48, 96, 120, 128, 192, 240, 256, 360,
384, 480, 500, 960, 1000, 1024, 1920, 3840, 7680, 15360} and k ∈ [1, 10⁶], the
reciprocal form hits every integer beat **exactly**, and at t = 480 it is
bit-identical on every 1/1 … 1/32-beat grid including triplets. (985 of the first
4000 integers *do* fail the integer-beat form — the smallest is t = 49, failing at
k = 1 — but no division a MIDI file uses is among them.) Where the two forms
differ is at **unquantized** ticks: at t = 480 they disagree at 185,753 of the
first 2,000,001 ticks, first at **tick 23**.

So the rule stands on three grounds, none of them audible fidelity: the single
division is the **correctly-rounded answer by definition**, so `beats` has one
right value and not two; it is the **shorter code**, since there is no reciprocal
to hoist or keep in sync; and it **costs nothing** — this is a control-plane parse
of tens of thousands of events, never the render thread, so the "optimisation"
buys no measurable time. The gate leg is split accordingly (§7, G1a invariant /
G1b discriminator): the integer-beat identity is a real and useful invariant but
**cannot** discriminate between the two implementations, and must never be
labelled as though it could.

`beats(k·t) == Double(k)` **exactly** for every integer `k` remains true and
assertable (it is what makes `note.startBeat == 4.0` a legal assertion) — it is
just an invariant of both forms, not a discriminator.

Derived quantities:

```
note.startBeat   = beats(smfNote.tick)                          // (R2) clip-relative
note.lengthBeats = Double(smfNote.lengthTicks) / Double(t)       // (R3)
point.beat       = beats(smfControllerEvent.tick)                // (R4) clip-relative
clip.startBeat   = atBeat                                        // (R5) timeline
clip.lengthBeats = max(beats(part.endTick), lastContentEndBeat)  // (R6)
tempoSegment.startBeat = beats(tempoEvent.tick)                  // (R7)
meterChange.startBeat  = beats(timeSigEvent.tick)                // (R8)
```

**R3 is load-bearing and is the second gate leg. It applies to METRICAL FILES
ONLY** — on the SMPTE path there is no `t` to divide by and endpoint subtraction
is the only available form (§2.2, R12). For a metrical file, length must come
from `lengthTicks` directly — NOT from `beats(tick + lengthTicks) - beats(tick)`.
The endpoint-subtraction form rounds twice at two different magnitudes, so the
same `lengthTicks` at different positions can yield different `lengthBeats`.

**The magnitude of the effect was measured (V.2 M2), and the first pass's own
example does not exhibit it.** At t = 480 a plain eighth note (240 ticks) is
bit-identical under both forms at all 20,001 tested 1/16-grid positions. What
diverges is a **non-dyadic** length: 160 ticks (t/3, a triplet eighth = 1/3 beat)
differs at **19,998 of 20,001** grid positions. G2 is written against t/3 for
exactly this reason; a leg written against an eighth note would be vacuous.
`SMFNote` already stores `lengthTicks`, so the correct form is also the shorter
one.

**R6**: `part.endTick` is authoritative for the part's length (k1: "it can sit
past the last note ... and never before it"), so trailing silence survives.
`lastContentEndBeat` is `max` over note ends and controller point beats, and is a
floor only for the degenerate case; if the result is 0 (impossible for an
imported part, which by D4 has content) use 1.

### 2.2 SMPTE division — `SMFDivision.smpte(framesPerSecond:ticksPerFrame:)`

**This is the carve-out where §0's invariant does not hold.** SMPTE ticks are
ABSOLUTE time; `FF 51` events do not govern the tick rate.

```
ticksPerSecond = fps' * Double(ticksPerFrame)                    // (R9)
   where fps' = (framesPerSecond == 29) ? 30000.0/1001.0 : Double(framesPerSecond)
seconds(tick)  = Double(tick) / ticksPerSecond                   // (R10)
beats(tick)    = resolvedTempoMap.beat(atSecondsFromZero: seconds(tick))   // (R11)
```

- `fps' = 30000/1001` for the spec's `-29`, which means 30-drop-frame at 29.97.
  24/25/30 are exact.
- `resolvedTempoMap` is the tempo map **after** the conflict policy resolves —
  i.e. the project's map, since:
- **A SMPTE file's `FF 51` events are IGNORED for map purposes.** `fileTempoMap`
  is forced to `nil` regardless of how many tempo events are present, and the
  report says so. Adopting a tempo map from a file whose clock does not depend on
  tempo would be meaningless. `tempoPolicy:"adopt"` on a SMPTE file resolves to
  `ignore` with a report line (it is not a refusal — the user asked for a policy,
  not for a contradiction).
- Consequence to state in the report and in the command docs: **for a SMPTE
  file, note beats depend on the project tempo, exactly like imported audio.** A
  later tempo change moves them relative to wall-clock. This is inherent, not a
  defect.
- **Note LENGTH on this path is endpoint subtraction, and must be** (R12):

```
note.lengthBeats = max(MIDINote.minLengthBeats,
                       beats(tick + lengthTicks) - beats(tick))   // (R12) SMPTE ONLY
```

  There is no `t` to divide by, so R3's prohibition does not and cannot apply
  here. Under a non-constant project tempo map the same `lengthTicks` at two
  different positions **should** produce different `lengthBeats` — that is the
  point of absolute time, not a defect — which is why G2 is scoped to metrical
  files. H6c applies unchanged.
- Meter events in a SMPTE file are still meaningful (meter is a display/bar-grid
  concept, not a clock) and are mapped normally through R8/R11. **State the
  consequence:** their beats are tempo-derived, so beyond the change at tick 0
  (which is always beat 0) they will almost never land on a barline and H2 will
  usually drop them. That is the correct outcome — an adopted meter change at a
  tempo-derived beat would silently move when the project tempo changed — but the
  report must say so rather than leaving it to look like a parse failure.

### 2.3 Tempo map construction (metrical files)

```
1. events := file.tempoChanges       (ALREADY sorted by (tick, sourceTrackIndex)
                                      -- reader :85-88)
2. DO NOT SORT. Swift's sorted(by:) is not documented stable, so re-sorting on
   the same key would shuffle ties within one (tick, sourceTrackIndex) and
   destroy the array-order tie-break H3 depends on.                  (V.3.3)
3. dedupe by tick, FIRST WINS, consuming in arrival order            (H3)
   - report a conflict only when a discarded µs value != the winner's
3.5 drop any event with µsPerQuarter <= 0 -> droppedMalformedTempoEvents.
    MUST precede step 6: 60e6/0 is +infinity, which the Segment clamp
    silently turns into 400 BPM. If this empties the array, fileTempoMap
    is nil but fileCarriedNoTempoMap stays FALSE -- the file asserted a
    map, it asserted an unusable one.                                (H4, V.3.5)
4. if events.isEmpty            -> fileTempoMap = nil, DONE          (H4c)
5. if events[0].tick != 0       -> prepend (tick 0, 500000 µs/qn), report  (H4b)
6. segments := events.map { Segment(startBeat: beats($0.tick),
                                    bpm: 60_000_000.0 / Double($0.µsPerQuarter)) }   (D2)
   - before constructing each: if the computed bpm is outside
     TransportState.tempoRange, record a clampedTempoEvents entry     (H1)
7. fileTempoMap = try TempoMap(segments: segments)
```

Step 7 cannot throw: step 3 guarantees strictly increasing ticks, `beats` is
strictly monotone in tick, step 5 guarantees the first is at beat 0, and the
array is non-empty. **The mapper must still handle a throw** — as a programmer
error surfaced honestly, never as a silent empty map. Wrap it and, if it ever
fires, throw a `midiImportInternalInconsistency` naming the map. (A `try!` here
would be a crash on a user's file.)

### 2.4 Meter map construction

```
1. events := file.timeSignatures     (ALREADY sorted -- reader :85-88)
2. DO NOT SORT; dedupe by tick, FIRST WINS, in arrival order         (H3, V.3.3)
3. drop malformed: denominator == nil, or numerator <= 0; report      (§1.3-1)
   (same "empties the array" rule as §2.3 step 3.5: fileMeterMap nil,
    fileCarriedNoMeterMap FALSE)
4. if events.isEmpty            -> fileMeterMap = nil, DONE           (H4c)
5. if events[0].tick != 0       -> prepend (tick 0, 4/4), report      (H4b)
6. map := try MeterMap(changes: [Change(0, n0, d0)])                 (§1.3 verbatim)
   for each remaining event e, in tick order:
       candidate := Change(startBeat: beats(e.tick),
                           beatsPerBar: e.numerator, beatUnit: e.denominator!)
       if let grown = try? MeterMap(changes: map.changes + [candidate]) {
           map = grown                                    // the model ACCEPTED it
       } else {
           report droppedMeterChanges(e, reason:)                      (H2)
       }
7. fileMeterMap = map          // already constructed; nothing left to build
```

**Step 6 uses `MeterMap.init` ITSELF as the accept oracle — it does NOT
re-implement the barline formula.** The first pass proposed copying the epsilon
and the formula "verbatim from `MeterMap.init(changes:)`", but
`MeterMap.barlineEpsilon` is **private** (`TempoMap.swift:375`), so that would
mint a second home for a constant this design's own ONE-home doctrine forbids —
and a second computation that can drift. Growing the map through its own throwing
initializer makes the mapper's accept test *identical to* the model's validation
by construction, and because the last successful call has already built exactly
the array step 7 returns, **there is no second construction and no `try!`
temptation left** (contrast §2.3, where the tempo map genuinely is built once at
the end and the "must not `try!`" note still applies). Cost is O(n²) in the number
of meter changes, which is a handful.

`reason:` distinguishes the three ways a change can be dropped, because they mean
different things to a user: **off-barline** (the file put a change mid-bar),
**malformed** (`dd` unrepresentable or `nn <= 0`), and **the v1 meter-model
consequence** (§1.3-3 — the change IS on the file's barline, and is off ours only
because a non-4 denominator makes our bar the wrong length).

### 2.5 Applying the maps

`ProjectStore.setTempoMap` requires BOTH maps together and replaces wholesale, so:

- adopt with `fileTempoMap != nil, fileMeterMap != nil` → `applyTempoMap(file
  tempo, meterMap: file meter)`.
- adopt with only one non-nil → pass the file's for that one and `nil` for the
  other (`applyTempoMap`'s `meterMap: nil` leaves the meter untouched — verified
  at `ProjectStore.swift:623`). For a nil tempo map with a non-nil meter map,
  pass the project's CURRENT `transport.tempoMap` as the tempo argument so the
  meter change lands without moving the tempo.
- `ignore` → `applyTempoMap` is not called at all.

`applyTempoMap` (not `setTempoMap`) is the entry point, called **inside** the
import's single `performEdit`, exactly as `importGeneration` calls
`applyTempoChange` inside its own (`ProjectStore+Generation.swift:95-103`). One
undo restores the tempo AND removes the tracks.

---

## 3. Mapping the file onto tracks and clips

### 3.1 The part set — the structural decision

**The DAW track set is the enumerated set of `(sourceTrackIndex, channel)`
pairs**, computed uniformly for every format:

```
for each SMFTrack st, in file order:
    if st.notes.isEmpty && st.controllers.isEmpty -> one skipped part (D4)
    else for each ch in st.channels, ascending:
        one part := (sourceTrackIndex: st.sourceTrackIndex,
                     channel: ch,
                     notes: st.notes.filter { $0.channel == ch },
                     controllers: st.controllers.filter { $0.channel == ch },
                     endTick: st.endTick,
                     name: st.name)
```

For format 0 this is a no-op relabelling of what k1 already split. For format 1
it is the fix for H5(a): a multi-channel `MTrk` becomes N DAW tracks instead of
one track whose controller lanes silently collide.

**Part index space:** parts are numbered `0..<n` over this **full** enumeration,
**including skipped ones**, which appear with `imported: false`. The `parts` wire
parameter (§4) indexes this list. Excluding skipped parts would make `parts:[0]`
mean different things in a dry run and a real run.

**Naming:**
- part is the only one from its `MTrk` → `st.name ?? "MIDI Track \(index+1)"`
- its `MTrk` split into several → `"\(base) (ch \(channel+1))"`, channel shown
  1-based (human convention; the stored value stays 0-based — the `R1` law from
  `GMProgramCatalog`).

### 3.2 Track construction

Tracks are built **offline as complete `Track` values** and appended in the single
`performEdit`, the `importGeneration` shape:

```
var t = Track(name: resolvedName, kind: .instrument)
t.instrument = <default, or the GM descriptor when instruments == "gm">   (D3)
t.clips = [clip]
```

**Do NOT loop over `store.setInstrument(...)`.** That path carries
`requireRoutingMutationAllowed` (`ProjectStore.swift:2661`) and would fire one
engine reconcile per track. One `engine?.tracksDidChange(tracks)` at the end of
the single `performEdit` is the whole engine interaction.

**Copy `importGeneration`'s STRUCTURE, not its `isAIGenerated` flag.** That path
sets `isAIGenerated = true` on both the track and the clip
(`ProjectStore+Generation.swift:87`, `:90`). A MIDI file import is not
AI-generated, and "violet always means AI-generated" is a design-language rule
(`docs/DESIGN-LANGUAGE.md`) — an imported file that shows up violet is a lie about
its provenance. Leave the flag at its default on both.

`kind: .instrument` is mandatory — MIDI clips live only on instrument tracks
(`ProjectStore.swift:3010`).

### 3.3 Clip construction

**One MIDI clip per DAW track.** No splitting at rests.

- `clip.startBeat = atBeat` for **every** part (R5). The clip origin is file tick
  0, so all parts stay aligned with each other and with the tempo/meter map;
  leading silence is preserved inside the clip and is visible.
- `clip.lengthBeats` per R6.
- `clip.notes` = the part's notes through `MIDINote(pitch:velocity:startBeat:lengthBeats:)`
  with R2/R3, then `MIDINote.canonicallyOrdered`.
- `clip.controllerLanes` = grouped by `MIDIControllerType`, each through
  `MIDIControllerLane(type:points:)` (which canonicalises), after the H7 lane
  selection and point decimation.
- `clip.name` = the track name.

Splitting at gaps is a musical judgement with no right answer and no third-party
reference to check against; one clip per part is predictable and the user can
split.

### 3.3b The zero-effect refusal

**A `project.importMIDI` that would create ZERO tracks AND adopt NO map is a
refusal, not an `ok: true` no-op.** The condition is measured off the REPORT, not
off the requested policy: `tracksCreated == 0 && tempoSegmentsAdopted == 0 &&
meterChangesAdopted == 0`. Reading it off the policy would let an
`adopt` of a file that carries no tempo or meter events at all (H4c — adoption
resolves to a no-op) return success having done nothing. This is `importSampleLibrary`'s
`noPlayableZones` rule (`ProjectStore+SampleLibraries.swift:70-72`, "never a
silent empty instrument") applied to the same shape of problem: a file whose only
part is a conductor track, imported with `tempoPolicy: "ignore"`, would otherwise
return success having done literally nothing — which reads to the user as "this
file was empty", a lie about their file.

The condition is deliberately the CONJUNCTION. Zero tracks **with** an adopted
tempo/meter map is a legitimate tempo-map import (importing a conductor track to
pick up its tempo map is a real workflow) and succeeds normally. `dryRun` never
refuses on this ground — the whole point of a dry run is to find out.

### 3.4 Track-count guard

**`SMFProjectMapper.maxImportedTracks = 32`.** A file whose selected part set
would create more than 32 tracks is **refused** with a teaching error naming the
count and `force: true` (the `SampleLibraryMapper.maxSampleBytes` precedent). A
dry run always computes the full report regardless, so the user can see exactly
what they would get and either pass `parts:[…]` or `force:true`.

Rationale: nothing in the model caps track count, `tracksDidChange` drives an
engine reconcile, and a 64-track orchestral file is an ordinary thing to be
handed. 32 is a policy number, not a physical limit; it is stated as a `public
static let` so it is one edit to move.

---

## 4. Wire shape

Both commands are **appended at the END** of `allCommands` (measured today:
**154** entries, tail `note.audition`, `track.reorder` → **156**). No live command
is renamed or reordered. MCP twins carry no `daw_` prefix and are the snake_case
mirror, preserving the `audit-tools` bijection: `project_import_midi`,
`clip_import_midi` (157 → 159 tools).

### 4.1 `project.importMIDI`

```
params:
  path         string   REQUIRED  absolute or ~-prefixed; .mid / .midi
  atBeat       number   optional  default 0, clamped >= 0 — timeline beat of file tick 0
  tempoPolicy  string   optional  "auto" (default) | "adopt" | "ignore"          (D1)
  instruments  string   optional  "none" (default) | "gm"                        (D3)
  parts        array    optional  ints indexing the report's parts array; omitted = all
  dryRun       bool     optional  default false — full report, project untouched
  force        bool     optional  default false — overrides the 32-track refusal (§3.4)

returns: { "report": <MIDIImportReport>, "applied": bool }
```

`rejectUnknownKeys(["path","atBeat","tempoPolicy","instruments","parts","dryRun","force"],
verb: "project.importMIDI")` — the F5 hardening rule; an unknown `policy` or
`tempo` key must never masquerade as an accepted default.

**Why an enum parameter and not a preview/confirm handshake:** a two-call
handshake would need server-side state keyed to a token, which is a new lifetime
to get wrong, and it would make the command non-idempotent. `dryRun` gives the
same information with no state: dry-run to read `parts` and the resolved
`tempoPolicy`, then call again for real. That composes with `parts` for
selective import and is the `instrument.importSampleLibrary` shape already
shipped (`Commands.swift:886-923`).

### 4.2 `clip.importMIDI`

```
params:
  clipId     string  REQUIRED  an existing MIDI clip
  path       string  REQUIRED  absolute or ~-prefixed
  part       number  optional  which part of the file (default: the lowest-indexed
                               part with notes; if none has notes, the lowest with
                               controllers)
  atBeat     number  optional  default 0, CLIP-RELATIVE offset for the content
  dryRun     bool    optional  default false

returns: { "report": <MIDIImportReport>, "applied": bool }
```

Semantics, deliberately narrow:

- **Replaces `notes` and `controllerLanes` wholesale** with the selected part's
  content (the `setClipNotes` / `setControllerLane` whole-array precedent).
- **NEVER touches tempo or meter.** A clip-level import must not move the project
  grid; that is `project.importMIDI`'s job. There is no `tempoPolicy` param.
- **NEVER changes `lengthBeats`.** Content past the clip end is imported and
  reported as `notesPastClipEnd` / `controllerPointsPastClipEnd`; the caller
  resizes with the existing `clip.fitToContent` if they want it.
  *(Rejected: growing the clip and folding through `resolvingOverlaps`. That
  would make an import destructively trim a NEIGHBOURING clip, dragging the m13-b
  overlap apparatus into a command whose job is one sentence. Composing with a
  shipped command is strictly better than a hidden side effect.)*
- `requireNotCompMember` and the `notAMIDIClip` guard apply, as for every other
  clip content edit.
- Undo label `"Import MIDI into Clip"`; `project.importMIDI`'s is
  `"Import MIDI File"`. Neither takes a coalescing key — one import is one step.

### 4.3 Error surface (both)

All via the existing `LocalizedError` mapping, no new plumbing:

| Condition | Error |
|---|---|
| not an absolute path | `ControlError("'path' must be an absolute path")` |
| wrong extension | new `MIDIImportError.notAMIDIFile(fileName:)` |
| missing/unreadable file | new `MIDIImportError.fileNotFound(path:)` |
| any `SMFDecodeError` | surfaced **verbatim** — k1's messages are already teaching-grade |
| recording | `ProjectError.transportBusy(…)` (D1″) |
| `adopt` + `atBeat != 0` | new `MIDIImportError.tempoAdoptionRequiresBeatZero` (D1′) |
| > 32 tracks without `force` | new `MIDIImportError.tooManyTracks(count:limit:)` naming `force` |
| **nothing would happen** — zero tracks created AND no map adopted | new `MIDIImportError.nothingToImport(fileName:)`, naming what the file DID contain |
| unknown `tempoPolicy`/`instruments` value | `ControlError` listing the legal values |

---

## 5. What the import returns — and the warning-channel question

**Decision: a NEW `MIDIImportReport` type in DAWCore. NOT `SMFWarning`.**

The reasoning, because the question was well posed:

- `SMFWarning` is about **the FILE** — what the bytes said, decided by the
  reader, identical for every consumer of the IR.
- H1–H7 are about **the MAPPING onto OUR model** — decided by the mapper, and
  entirely different against a different target model.
- Growing `SMFWarning` with `tempoClampedToProjectRange` or
  `controllerLaneDroppedAtCap` would drag `StandardMIDIFileReader` into knowing
  about `TempoMap` and `ProjectStore`'s lane cap. That is precisely the coupling
  k1's tick-native posture exists to prevent, and it would make k4's writer
  depend on it too.

The two are reconciled by **carrying the file's warnings inside the mapping
report**, so one object answers "what was odd about this import" end to end:

```swift
public struct MIDIImportReport: Codable, Sendable, Equatable {
    // --- what the file was
    public var format: Int                       // 0/1/2
    public var divisionDescription: String       // "480 ticks per quarter note" |
                                                 // "SMPTE 25 fps x 40 ticks/frame"
    public var isAbsoluteTime: Bool              // true for SMPTE (§2.2 carve-out)

    // --- per-part ledger; index space = §3.1, INCLUDING skipped parts
    public struct Part: Codable, Sendable, Equatable {
        public var index: Int
        public var name: String
        public var sourceTrackIndex: Int
        public var channel: Int?                 // 0-based; nil only for a skipped part
        public var noteCount: Int
        public var controllerLanes: [String]     // wireKeys actually imported
        public var programChange: Int?           // what the file asks for (D3)
        public var programName: String?          // GMProgramCatalog name, or drum kit
        public var imported: Bool
        public var skipReason: String?
        public var trackID: UUID?                // nil on dryRun
        public var clipID: UUID?
    }
    public var parts: [Part]

    // --- what landed
    public var tracksCreated: Int
    public var notesImported: Int
    public var controllerPointsImported: Int
    public var instrumentsAssigned: String       // "none" | "gm"

    // --- tempo/meter
    public var resolvedTempoPolicy: String       // "adopt" | "ignore" (never "auto")
    public var tempoSegmentsAdopted: Int
    public var meterChangesAdopted: Int
    public var adoptedTempoBPM: Double?          // segment 0 — importGeneration symmetry

    // --- the losses, one field per hazard, each ZERO on a clean file
    public var clampedTempoEvents: [String]                 // H1
    public var droppedMeterChanges: [String]                // H2 + malformed (§1.3-1)
    public var conflictingDuplicateTempoEvents: [String]    // H3 (V.3.9: NOT a count —
    public var conflictingDuplicateMeterEvents: [String]    //  name tick/beat/winner/loser)
    public var droppedMalformedTempoEvents: [String]        // §2.3 step 3.5 (µ <= 0)
    public var tempoAdoptionDegradedToIgnore: Bool          // §2.2 — SMPTE asked to adopt
    public var synthesizedLeadingTempo: Bool                // H4b
    public var synthesizedLeadingMeter: Bool                // H4b
    public var fileCarriedNoTempoMap: Bool                  // H4c — absence, not default.
    public var fileCarriedNoMeterMap: Bool                  //  FALSE when the events existed
                                                            //  but were all malformed (V.3.5)
    public var notesWithDroppedReleaseVelocity: Int         // H5b
    public var notesStretchedToMinimumLength: Int           // H6c
    public var shortestRequestedLengthBeats: Double?        // H6c
    public var droppedControllerLanes: [String: Int]        // H7  wireKey -> points dropped
    public var decimatedControllerLanes: [String: Int]      // H7  wireKey -> points kept
    public var droppedProgramChanges: Int                   // D3
    public var polyAftertouchEventsDropped: Int             // D3
    public var notesPastClipEnd: Int                        // clip.importMIDI only
    public var controllerPointsPastClipEnd: Int             // clip.importMIDI only

    // --- the two prose channels
    public var fileWarnings: [String]        // SMFWarning.description, VERBATIM (k1)
    public var degradations: [String]        // human sentences (SampleLibraryImportReport idiom)
}
```

**Every `[String]` loss field is CAPPED** at a stated maximum (32 entries is
ample) with a trailing `"… and N more"` element. A pathological file with ten
thousand off-barline meter changes must not mint a ten-thousand-element array
that rides the wire into an agent's context; the typed COUNTS stay exact.

`degradations` is the human-readable roll-up the UI and the copilot read; the
typed fields above it are what a test asserts on. That split is exactly
`SampleLibraryImportReport`'s (`skippedRegions`/`ignoredOpcodes` typed,
`degradations` prose), and it is why an agent can act on the report without
string-matching.

**H4c needs its own fields and they are NOT degradations.** `fileCarriedNoTempoMap`
/ `fileCarriedNoMeterMap` state a fact about the file (it declared no map of that
kind) and are the reason an `adopt` left that map alone. They are informational:
they must NOT push a line into `degradations`, because the spine fixture
`apple-type1.mid` sets `fileCarriedNoMeterMap == true` and G9 would then need an
exemption. `synthesizedLeadingTempo`/`…Meter` (H4b) ARE degradations — there the
importer invented a value the file did not carry.

**A clean file must produce an all-zero/empty loss section.** That is a gate leg
(§7, G9): `apple-type1.mid` imports with every loss field empty and
`degradations == []`, **with no exemption**. The `fileCarriedNoMeterMap` flag it
does set is informational and sits outside the loss section. Otherwise the report
becomes noise nobody reads.

---

## 6. Implementation plan

Ordered so each step is independently testable and Step 0 is cleanly cuttable.

### Step 0 — extend the IR (additive; the ONLY reopening of a shipped file)

- `Sources/DAWCore/StandardMIDIFile.swift`: add
  `public struct SMFProgramChangeEvent: Sendable, Equatable, Hashable { tick, channel, program }`;
  add to `SMFTrack` the stored properties `programChanges: [SMFProgramChangeEvent]`
  and `polyAftertouchEventCount: Int`, **both with defaults in `init`** so every
  existing call site and test compiles unchanged.
- `Sources/DAWCore/StandardMIDIFileReader.swift`: at `case 0xC0` (:401) record the
  program byte instead of discarding it (**still `channels.insert(channel)`? NO —
  see below**); at `case 0xA0` (:380) increment the count.
  - **A program change must NOT insert into `channels`.** k1's comment at :383-385
    is explicit that poly pressure must not "conjure an empty part out of a
    format-0 split", and the same argument applies verbatim to a bank/program
    stamp on an otherwise-silent channel. Keep both out of `channels`. A program
    change for a channel with no note/CC content is therefore reported as
    `droppedProgramChanges`, not as a phantom part.
- **The discriminator that this step is safe:** every existing test in
  `Tests/DAWCoreTests/StandardMIDIFileReaderTests.swift` (39 tests) and
  `StandardMIDIFileWriterTests.swift` (55 tests) must pass **unchanged, with no
  edits to those files**. If either needs editing, the change was not additive.
  **This is the right discriminator and it is stronger than it looks:** `SMFTrack`
  is `Equatable`, so adding a stored property changes its synthesized `==`. The
  94 tests stay green only because every existing construction site takes the new
  defaults on both sides of every comparison — which is precisely the property
  "additive" is supposed to mean. A test file that needed a one-line edit would be
  the signal that the equality semantics moved.
- **State the asymmetry this creates, and hand it to k4 explicitly.**
  `StandardMIDIFileWriter` (k2) will not emit `programChanges`, so a
  decode → encode round trip through the extended IR **loses them silently**. That
  is acceptable in k3 (k3 does not export) but it is a real obligation: **k4 must
  either emit `0xC0` events from `SMFTrack.programChanges` or state the drop in
  its own report.** Do not let it be discovered as a bug. `polyAftertouchEventCount`
  is a count, not events, so it is unrecoverable by construction and k4 owes it
  nothing beyond saying so.
- New tests: a fixture with program changes decodes them at the right ticks; a
  fixture with poly aftertouch counts them and still frames the following events
  correctly (the framing regression is the real risk).
- **Cut plan:** if this step goes sideways, drop it and set D3 to "program change
  and poly aftertouch are dropped; the report says so generically." Everything
  downstream still works; only `parts[].programChange` and the `instruments:"gm"`
  option disappear.

### Step 1 — the mapper (pure, headless, store-free) — **the ONE home**

New file: `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/StandardMIDIFileMapper.swift`

```swift
public struct MIDIImportOptions: Sendable, Equatable { atBeat, tempoPolicy, instruments, parts, force }
public enum   MIDITempoPolicy: String, Sendable, Codable { case auto, adopt, ignore }
public struct MIDIImportContext: Sendable, Equatable {   // what the mapper needs to know
    var projectHasClips: Bool                            // the D1 predicate, passed IN
    var currentTempoMap: TempoMap
    var currentMeterMap: MeterMap
}
public struct MIDIImportPlan: Sendable, Equatable {
    public let tracks: [PlannedTrack]                    // complete Track payloads
    public let tempoMap: TempoMap?                       // nil = do not adopt
    public let meterMap: MeterMap?
    public let report: MIDIImportReport
    fileprivate init(...)                                // <-- see below
}
public enum SMFProjectMapper {
    public static func map(_ file: StandardMIDIFile,
                           options: MIDIImportOptions,
                           context: MIDIImportContext) throws -> MIDIImportPlan
}
```

**`MIDIImportPlan.init` is `fileprivate`, so `SMFProjectMapper.map` is the only
producer in the program, and `ProjectStore`'s import is TYPED to consume one.**
The mechanism was checked and holds (V.4.4): an explicit `init` **suppresses** the
synthesized memberwise initializer, which would otherwise be `internal` and
reachable from anywhere in DAWCore; `Equatable` and `Sendable` synthesize no
initializer; and `fileprivate` really does mean "this file", so `SMFProjectMapper`
must be co-located in `StandardMIDIFileMapper.swift`.

**One constraint must be written down or the hole reopens: `MIDIImportPlan` must
NEVER conform to `Codable`.** A public `Codable` struct synthesizes a public
`init(from:)`, which is a second producer that no `fileprivate` can stop. If a
snapshot ever needs to show a plan, encode the `report` (which IS `Codable`), not
the plan.

**But the plan's initializer alone does NOT deliver what the first pass claimed
for it.** "k4's UI drag-drop path will want to just quickly work out where this
lands, and the type must make that impossible" — nothing about a `fileprivate`
plan initializer stops a k4 view writing `Double(tick) / 480.0`. `ResolvedDropBeat`
works because the **conversion** has one named home that everything downstream is
typed on. So give the conversion that home:

```swift
/// THE ONE producer of a beat from a tick. Every tick→beat conversion in the
/// program goes through this type; no caller divides by a division itself.
public struct SMFTickClock: Sendable, Equatable {
    public init(division: SMFDivision, tempoMap: TempoMap)   // tempoMap unused when metrical
    public var isAbsoluteTime: Bool                          // SMPTE (§2.2)
    public func beats(tick: Int) -> Double                   // R1 / R11

    /// R3 (metrical) or R12 (SMPTE), chosen by the clock, not by the caller.
    public func lengthBeats(tick: Int, lengthTicks: Int) -> Double {
        switch kind {
        case .metrical(let t):
            // `tick` IS NOT IN SCOPE inside this helper. Endpoint subtraction is
            // not "discouraged" here, it is UNWRITEABLE.
            return Self.metricalLength(lengthTicks: lengthTicks, ticksPerQuarter: t)
        case .absolute:
            return beats(tick: tick + lengthTicks) - beats(tick: tick)   // R12
        }
    }
    private static func metricalLength(lengthTicks: Int, ticksPerQuarter t: Int) -> Double
}
```

`lengthBeats` being a method rather than the caller's arithmetic is what makes
R3-vs-R12 a property of the clock instead of a rule each call site must remember —
and it is what G2 actually tests.

**The private helper's signature is load-bearing, not stylistic.** A single
`lengthBeats(tick:lengthTicks:)` body that branches inline would leave `tick`
in scope on the metrical path, where it is dead — and a dead parameter is exactly
the shape a later reader "cleans up" by using it, which is endpoint subtraction,
which is the bug G2 exists to catch. **Routing the metrical branch through a
helper that cannot see `tick` makes the bug unrepresentable rather than merely
tested against** — the same move as `ResolvedDropBeat`'s `fileprivate init`,
applied one level down. Do not collapse the helper.

Everything in §1, §2 and §3 lives in this file and nowhere else. It touches no
store, no engine, no `Foundation` beyond `Data`/`UUID`. Every hazard verdict is
unit-testable here with no `ProjectStore` at all.

### Step 2 — the store methods

New file: `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore+MIDIFile.swift`

```swift
@MainActor extension ProjectStore {
    @discardableResult
    public func importMIDIFile(path: String, atBeat: Double = 0,
                               tempoPolicy: MIDITempoPolicy = .auto,
                               instruments: MIDIImportInstruments = .none,
                               parts: [Int]? = nil,
                               dryRun: Bool = false, force: Bool = false) throws -> MIDIImportReport

    @discardableResult
    public func importMIDIIntoClip(clipID: UUID, path: String, part: Int? = nil,
                                   atBeat: Double = 0, dryRun: Bool = false) throws -> MIDIImportReport
}
```

Body shape (mirrors `importSampleLibrary` exactly):

1. Guards FIRST, before any file work: `transport.isRecording` (D1″); for the
   clip variant, `locateClip` + `requireNotCompMember` + `isMIDI`.
2. Extension / existence checks **before** any decode, in the precedent's own
   order: **extension first** (`ProjectStore+SampleLibraries.swift:41-49`),
   **`FileManager.fileExists` second** (`:50`). That order makes a non-existent
   `.txt` say "not a MIDI file", exactly as the shipped importer does. Both must
   precede the decode because `StandardMIDIFileReader.decode(contentsOf:)`
   (`StandardMIDIFileReader.swift:27-29`) wraps `Data(contentsOf:)` and would
   surface a raw Foundation error, not a teaching one. Then
   `StandardMIDIFileReader.decode(contentsOf: url)` (the shipped entry point;
   there is also `decode(_ data: Data)` at `:36` for tests).
3. `SMFProjectMapper.map(file, options:, context:)` — build `MIDIImportContext`
   from `tracks.contains { !$0.clips.isEmpty }` and `transport.tempoMap` /
   `transport.meterMap`.
4. `if dryRun { return plan.report }` — **nothing mutated, no journal entry, no
   engine reconcile.**
5. ONE `performEdit("Import MIDI File")`:
   - `if let m = plan.tempoMap { applyTempoMap(m, meterMap: plan.meterMap) }`
     (or the meter-only form, §2.5)
   - `tracks.append(contentsOf: plan.tracks.map(\.track))`
   - `engine?.tracksDidChange(tracks)`
6. Return `plan.report` with the real track/clip IDs filled in.

**`importMIDIIntoClip` needs the SAME `engine?.tracksDidChange(tracks)` inside
its own `performEdit`.** Both notes and controller lanes ride the `ClipKey` that
drives schedule rebuilds (`setControllerLane`'s own comment,
`ProjectStore.swift:4797`: "A ClipKey-affecting edit (the lanes ride the schedule
build): the engine must re-schedule"). Omit it and the imported content is silent
until some unrelated edit happens to trigger a reschedule — a bug no purely
model-level test catches.

**Atomicity is confirmed as the `importGeneration` model and needs no new
thinking** (`ProjectStore+Generation.swift:95-103`): tempo adoption folds into
the SAME `performEdit`, so a single undo restores the tempo along with removing
the tracks.

### Step 3 — the wire

`/Users/dsemenov/Views/daw-pro/Sources/DAWControl/Commands.swift`:
two `case` blocks with the full teaching comment block each command in this file
carries, `rejectUnknownKeys` first, and the two names **appended at the end** of
`allCommands` (154 → 156). Response `{report, applied}` via
`try JSONValue(encoding: report)` — the `instrument.importSampleLibrary` shape.

### Step 4 — MCP

`/Users/dsemenov/Views/daw-pro/mcp-server/src/server.ts`: `project_import_midi`
and `clip_import_midi`, descriptions naming the tempo policy and the `dryRun`
→ `parts` workflow explicitly (an agent that cannot discover `parts` will import
64 tracks). 157 → 159 tools; the `audit-tools` bijection test must stay green.

### Step 5 — the one fixture + tests (§7)

### Step 6 — docs

- `docs/ROADMAP.md`: tick `m23-k3`, close-out record with SHA-256 pins for every
  new fixture.
- `CHANGELOG.md`: **edit the existing `## In progress — MIDI file support (.mid)`
  block, tick its third box, expand its line. Do NOT add a dated entry** (the
  convention set at k1 and restated on the roadmap line).
- `docs/ARCHITECTURE.md`: the §8 entries below.
- `Tests/DAWCoreTests/Fixtures/SMF/README.md`: extend the expectation table with
  the new fixtures **and an explicit "Apple-confirmed / spec-asserted" column**
  (§7.2).

### Nothing here requires full Xcode

No entitlements, no AUv3, no code signing, no bundling. Pure `Data` parsing plus
model mutation plus wire plumbing; `./scripts/test.sh` covers all of it. The only
adjacent risk is D3's `instruments:"gm"` path touching AUSampler preparation —
and that is precisely why its default is `"none"` in k3.

---

## 7. The k3 gate

### 7.1 Gate legs

| # | Leg | Why it discriminates |
|---|---|---|
| **G1a** *(invariant, NOT a discriminator)* | For a set of `t` values including 480, 96, 15360 and 1: `beats(k·t) == Double(k)` **exactly** (`==`, not approximately) for `k` over a wide range. | A real and useful invariant — it is what makes `note.startBeat == 4.0` a legal assertion. **MEASURED to hold under BOTH the single-division and the reciprocal-multiply implementations (V.2 M1), so it discriminates NOTHING.** Labelled explicitly so no future reader re-promotes it. The first pass listed exactly this as the leg that catches the reciprocal; it does not. |
| **G1b** *(the actual discriminator)* | At t = 480, assert **BOTH halves**: `clock.beats(tick: 23) == Double(23) / Double(480)` **and** `clock.beats(tick: 23) != Double(23) * (1.0 / Double(480))`. | The second half IS the discriminator; the first pins the definition. **Write both** — a one-sided equality invites a test author to compute the expected value as `23.0 * recip`, which passes under either implementation and re-opens the vacuity. **Wire the positive control as a THIRD ASSERTION IN THIS LEG, not as prose**: `Double(49 * 1) * (1.0 / Double(49)) != Double(1)` — pure arithmetic, no mapper involved. Without it, nothing in the suite demonstrates that the arithmetic under test can diverge at all, and a future reader doubting G1b has no way to check short of re-running the measurement. With it, the G1a/G1b split is self-evidencing: the same form that is provably safe at every division a MIDI file uses provably fails at t = 49, k = 1 (985 of the first 4000 divisions fail somewhere — V.2 M1). |
| **G2** *(metrical files ONLY)* | At t = 480, two notes with `lengthTicks == 160` (t/3 — a triplet eighth, 1/3 beat) at different `tick`s produce **bit-identical** `lengthBeats`. | Fails the endpoint-subtraction implementation of R3 at **19,998 of 20,001** 1/16-grid positions (V.2 M2). **The length must be NON-DYADIC or the leg is vacuous:** the first pass's example — a plain eighth note, 240 ticks — measures **0 of 20,001** divergent and would catch nothing. **Scoped to metrical by construction:** on the SMPTE path (R12) equal `lengthTicks` at different positions SHOULD give different `lengthBeats` under a non-constant tempo map, so a bit-identity leg there would be asserting a bug. |
| **G3** | For µ across `150000...3000000`: `Int((60_000_000.0/(60_000_000.0/Double(µ))).rounded()) == µ`. | Pins D2's round-trip claim over exactly the window the clamp permits — the theorem k4's export inherits. **Sample, do not exhaust:** all 2,850,001 values run in a DEBUG test build, where this can cost seconds and be mistaken for the known `EQCurveEditorModelTests` perf flake. Take every 97th value plus both endpoints plus a dense ±2000 band around each endpoint and around 500000 and 666666 — same claim, ~40 k iterations. **Add µ = 2,807,175 as a NAMED input**: it is the measured worst case over the whole window (absolute error 4.65661e-10, V.2 M3), and no sampling scheme finds an extremum by luck. The exhaustive run has already been done once, in C, with **0 failures over all 2,850,001 values** — the Swift leg is a regression guard on the implementation, not a rediscovery of the theorem. |
| **G4** | `apple-type1.mid` (third-party) imports: 2 tracks created, notes at beats 0/1/2/3 with lengths 0.5, velocities 70/80/90/100 on part 1 and 48/50/52/54 pitches on part 2, CC 11 lanes at beats 0/0.5/1 with values 20/60/100 **on each track separately**; tempo map = 2 segments, `bpm(atBeat: 0) == 120`, and `bpm(atBeat: 4) == 60_000_000.0 / 666_666.0` **written as that expression, never as a decimal literal**; **the file carries NO `FF 58` at all, so by H4c `fileMeterMap == nil` and the project's meter is UNTOUCHED under both `adopt` and `ignore`, with `meterChangesAdopted == 0`**; part 0 skipped (D4). | The roadmap's headline claim, plus D4, plus **H4c-for-meter**, plus D2's lossy value — all on the one genuinely third-party fixture. **The decimal-literal trap:** `60_000_000/666_666 = 90.00009000009000009…` (= 90 + 10/111111), printing as `90.00009000009`. Both my first draft and the project memory index carry a WRONG transcription of these digits. Assert the expression; it is the same claim G3 proves in general. |
| **G5** | Conflict policy **in both directions on the same file**: `adopt` on an empty project changes `transport.tempoBPM` to 120 and installs a 2-segment override; `ignore` on the same project leaves `tempoBPM` at its prior value and `tempoMapOverride == nil`; `auto` on a project **with** clips resolves to `ignore` and says so in `resolvedTempoPolicy`; `auto` on an empty project resolves to `adopt`. | The roadmap names this explicitly. The `auto` legs are the ones that catch a predicate copied wrong. |
| **G6** | **Atomicity**: after an `adopt` import, ONE `edit.undo` both removes every created track AND restores the previous tempo/meter. | The `importGeneration` invariant. A two-`performEdit` implementation passes every other leg. |
| **G7** | `dryRun: true` produces an identical `report` (modulo nil `trackID`/`clipID`) to the real run, and leaves `tracks` and `transport` unchanged (`project.snapshot` before/after) **AND leaves the undo journal untouched — assert `store.undoHistory().undo` is an IDENTICAL label list** (`ProjectStore.swift:147`, `UndoJournal.swift:115`; on the wire, `edit.history` — `Commands.swift:3678-3696`). | The undo-journal leg is the one that catches a `performEdit` that ran and did nothing. **A `project.snapshot` does NOT observe the journal** — the first pass's stated seam could not have caught the bug the leg exists for. `undoHistory()` is the seam that does. |
| **G8** | Wire round-trip over the control port: `project.importMIDI` and `clip.importMIDI` on the staging port, response shape, `rejectUnknownKeys` rejects a typo'd `policy`, error text for each row of §4.3. | The roadmap names it. |
| **G9** | **Vacuity guard**: `apple-type1.mid` imports with EVERY loss field empty/zero and `degradations == []`. | Without this, a mapper that reports something on every file passes all the hazard legs and the report is noise. |
| **G10** | Per-hazard legs, **one per CASE in §7.2** (the one new byte fixture plus the seven hand-built-IR cases), each asserting the specific report field AND that the notes still land on the right beats. | The tick-affinity claim (§0) is what makes the second half of each leg meaningful. |
| **G11** | **Mutation legs** (the ONE-home law): (a) making `MIDIImportPlan.init` internal must break the build, **and adding `Codable` to `MIDIImportPlan` must be caught by review** — both assert by inspection, not by test (a public `Codable` struct synthesizes a public `init(from:)`, a second producer no `fileprivate` can stop); (b) a mutation that changes H3's dedupe from first-wins to last-wins must fail the tempo-duplicate case; (c) a mutation that merges format-1 channels into one track must fail `hazard-type1-multichannel` **on the controller lanes**, not only on the track count; (d) a mutation that re-sorts §2.3 step 1's array must fail the tempo-duplicate case (it is authored in reader order precisely so this is observable). | (c) is the important one: a track-count-only assertion passes a mapper that creates 2 tracks but puts both channels' CC 11 into one of them. |
| **G12** | **Cap post-conditions on the many-CC case** (§7.2): after import, `clip.controllerLanes.count <= ProjectStore.maxControllerLanesPerClip` and every lane's `points.count <= ProjectStore.maxControllerPointsPerLane`. | **The mapper is the ONLY enforcement of these caps in the program.** They live in `ProjectStore.setControllerLane` (:4776, :4787), NOT in `Clip.init` or `MIDIControllerLane.canonicalPoints` (whose doc says explicitly "NO size cap here"). Because k3 builds `Clip` values offline and appends them, that store boundary is bypassed entirely. A wrong priority-list implementation would otherwise produce a clip the store itself would have refused to create. |
| **G13** | A file whose only part is a conductor track, imported with `tempoPolicy:"ignore"`, **throws** `nothingToImport`; the SAME file with `tempoPolicy:"adopt"` **succeeds** with `tracksCreated == 0` and a non-zero `tempoSegmentsAdopted`. | §3.3b. The conjunction is the whole rule; a leg that only tested the refusal would pass an implementation that also refuses the legitimate tempo-map-only import. |
| **G14** | Suites + baselines: full Swift suite 0-warn on a **FORCED FULL rebuild** (`find Sources Tests -name '*.swift' -print0 \| xargs -0 touch` + the manifest; read SwiftPM's own `[n/N]`), npm suite, wire count 154 → 156 proven as an exact-PREFIX extension of HEAD's list, MCP tools 157 → 159, `audit-tools` bijection green. | The standing close-out contract. |

### 7.2 Fixtures — what serves and what is missing

**Existing, and what each serves:**

| Fixture | Serves |
|---|---|
| `apple-type1.mid` | **G4 — the spine.** Third-party, 480 tpqn, two channels in two `MTrk`s, a conductor track (D4), a tempo change at tick 1920 → beat 4, the 666666 µs/qn D2 value, and **NO `FF 58` at all — so H4c-for-meter (absence: `fileMeterMap == nil`, nothing synthesized), NOT H4b.** |
| `hazard-type0-multichannel.mid` | The format-0 channel split still lands as 3 tracks under the new uniform rule. |
| `hazard-controllers.mid` | Controller lanes of all three types map to `MIDIControllerLane`s at the right beats; pitch-bend 16383 survives to the lane's 0…16383 range. |
| `hazard-note-on-vel0.mid` | Velocities never reach the model as 0 (H6a is structurally impossible). |
| `hazard-vlq-multibyte.mid` | Large ticks (2,113,792 → beat 4403.7333…) map without precision loss; the R1 division at scale. |
| `hazard-smpte-division.mid` | **The §2.2 carve-out.** Note at tick 0, length 1000 ticks at 25 fps × 40 = 1000 ticks/s = 1.0 s → 2.0 beats at 120 BPM. `isAbsoluteTime == true`, `fileTempoMap` forced nil, `adopt` degrades to `ignore` with a report line. |
| `hazard-running-status.mid` | Carries the only existing `FF 58` — 4/4 at tick 0, a **null case** for meter (proves the identity path, not the hazard). |
| `malformed-*.mid` (5) | Every `SMFDecodeError` surfaces verbatim through both commands with nothing mutated. |
| `encode-*.mid` (3) | **Not inputs. Do not read them as import fixtures** — they are k2's expected-output pins. |

**Missing — ONE new byte fixture, plus six hand-built-IR mapper cases.**

The first pass called for seven new `.mid` files. **Six of them encode MAPPING
decisions, not PARSING claims** (and one of those six is better split into two
cases, giving seven) — and the mapper's input is a
`StandardMIDIFile` **value**, so a hand-built IR is the correct, cheaper,
one-hazard-per-case input for those. **This SCOPES the ONE HAZARD PER FIXTURE law,
it does not relax it**, and it carries the rule that makes it safe:

> **Every hand-built IR must be one the reader can actually produce. Where
> reachability is ITSELF the claim, use bytes.**

Byte fixtures exist to prove the parser reads *third-party* bytes correctly —
their value is that they were not written by us (the fixture README's "one rule").
A mapper verdict has no third party to appeal to: the decision is ours, and
routing it through 60 bytes of hand-authored SMF adds an unvalidated authoring
step between the hazard and the assertion without adding evidence. It also makes
the one-hazard rule *harder* to honour, since real bytes drag in a division, an
end-of-track, and a channel whether the case needs them or not.

Authoring cost drops from ~3–4 h (generator + seven files + Apple validation of
five) to ~1 h.

**The ONE new byte fixture** — because here reachability IS the claim:

| New fixture | Content | Gates | Third-party status |
|---|---|---|---|
| `hazard-type1-multichannel.mid` | format 1; conductor `MTrk` + **one** `MTrk` carrying notes on channels 0 and 1, each with its own CC 11 stream at different values | **H5a — the single most structural decision in this doc.** The claim it carries is a PARSING claim: that k1 really does hand k3 a format-1 `SMFTrack` with `channels.count == 2` and `channel == nil` (`StandardMIDIFileReader.swift:494-497`). No hand-built IR can prove that, because a hand-built IR is exactly what would be assumed. | Apple **confirms the bytes** (one `MusicTrack`, events on 2 channels). The SPLIT is our mapping decision and is spec/design-asserted. |

**The seven hand-built-IR mapper cases** (six table rows; the last row is two
cases) — a `StandardMIDIFile` literal in the test, one hazard each, no bytes, no
Apple round trip:

| Case | IR it constructs | Gates | Reachability note (the rule above) |
|---|---|---|---|
| tempo-late | `tempoChanges = [SMFTempoEvent(tick: 480, µ: 500000, src: 0)]` | H4b (`synthesizedLeadingTempo`) | k1 hoists tempo events verbatim; a first-event-at-480 array is exactly what it returns. |
| tempo-duplicate | two `SMFTempoEvent` at tick 0, `src: 0` (µ 666666) and `src: 1` (µ 500000), **in that array order** | **H3 — the real-world failure mode** (exporters stamping a default tempo into every chunk) | Matches the reader's `(tick, sourceTrackIndex)` hoist order (`:85-88`) — which is also what makes "do not re-sort" testable. |
| tempo-malformed | `SMFTempoEvent(tick: 0, µ: 0, src: 0)` | §2.3 step 3.5 (`droppedMalformedTempoEvents`, and `fileCarriedNoTempoMap == false`) | `FF 51 03 00 00 00` is well-framed; k1 accepts it (`:292` tests only `length == 3`). |
| meter-offbar | `4/4 @ tick 0`, `3/4 @ tick 720` (beat 1.5) | H2 (`droppedMeterChanges`, reason = off-barline) + notes still on their beats | |
| meter-eighths | `6/8 @ tick 0`; **plus a second change at tick 1440 (beat 3, the file's bar 2)** | **§1.3 verbatim mapping** — pins `(6, 8)` against a future "helpful" translation to `(3, 8)` — **and §1.3-3**, the drop of an on-the-file's-barline change with reason = v1-meter-model | This is the one case that carries two assertions, and they are two *readings of one decision*, not two hazards: the same verbatim mapping produces both. |
| many-cc + zero-length | **two separate cases.** (a) one channel, 20 distinct CC numbers, CC 64 with FEW points and two junk CCs with MANY. (b) one note with `lengthTicks == 0`, and one dangling-onset note at `endTick` | (a) **H7 priority list** — a naive most-populated rule visibly drops sustain; also G12's cap post-conditions. (b) H6c, both producers (`shortestRequestedLengthBeats == 0`) | (b)'s second half is reachable via `StandardMIDIFileReader.swift:466`. |

Two further mapper cases have no fixture at all and are pure `MIDIImportOptions`
plumbing: **`adopt` × `atBeat != 0` refuses** (D1′) and **`auto` resolves both
ways** (G5).

**Authoring cost, stated honestly:** k1's generator (`gen-smf-fixtures.py`) and
validator (`validate-smf.swift`) lived in a **session scratchpad and are gone**.
Both must be rewritten before the one new fixture is authored — but "a generator"
for a single file is a ~60-line script, not a framework. Budget roughly: script +
`hazard-type1-multichannel.mid` + its Apple validation ~1 h; the six IR cases are
ordinary Swift test code with no authoring step at all.
`AudioToolbox` appears in the validator only — **never** in `Sources/DAWCore`
(LAW L9). Then:

- extend the fixture `README.md` table with a new **"Apple-confirmed /
  spec-asserted"** column, filling it in for the existing rows too (the existing
  table's `hazard-smpte-division.mid` row already models the honest phrasing);
- add a SHA-256 pin for `hazard-type1-multichannel.mid` — the only new byte
  fixture — to the `m23-k3` close-out record in `docs/ROADMAP.md`. The hand-built
  IR cases need no pin: their input is Swift source under version control, which
  is a stronger integrity story than a hash of an opaque blob.

---

## 8. `docs/ARCHITECTURE.md` — "Key future decisions" entries to add

Two entries, both settled by this read. Written for the implementing agent to
paste (adjust prose to house style):

1. **MIDI file import mapping (m23-k3): SETTLED (2026-07-26; design
   `docs/research/m23-k3-midi-import-design.md`)** — beats are AFFINE IN TICKS
   (`beat = tick/tpqn`), so tempo never enters note placement and every tempo
   hazard is a playback-speed hazard, not a position hazard; SMPTE division is
   the one carve-out (absolute time → project tempo map). BPM is authoritative in
   the project and `bpm = 60e6/µs` round-trips exactly over the clamp window
   µ ∈ [150000, 3000000] (k4 exports `round(60e6/bpm)`). Tempo conflict policy is
   `auto` (= `importGeneration`'s empty-project predicate) / `adopt` / `ignore`;
   **`ask` is a UI choice between two core policies, never a core policy** — the
   wire must never block on a human. The DAW track set is the enumerated
   `(sourceTrackIndex, channel)` pairs for EVERY format (format 1's multi-channel
   `MTrk` splits too), because `MIDIControllerLane` has no channel dimension and
   merging would silently destroy CC data. Every mapping loss is reported in a
   separate `MIDIImportReport` (the `SampleLibraryImportReport` precedent) which
   carries the file's own `SMFWarning`s verbatim; `SMFWarning` stays about the
   FILE and never learns about `TempoMap`. `SMFProjectMapper` is the ONE home,
   with a `fileprivate` `MIDIImportPlan.init` so the store cannot compute a plan
   for itself, **and `SMFTickClock` as the ONE producer of a beat from a tick** so
   no later surface (k4's drag-drop especially) can re-derive one — the two halves
   of the `ResolvedDropBeat` law. `MIDIImportPlan` must never gain `Codable`: a
   public `Codable` struct synthesizes a public `init(from:)`, a second producer. Program change is captured and
   reported but applied only under `instruments:"gm"`, **default `"none"` in
   k3** — bulk sound-bank assignment is an unmeasured main-actor cost and belongs
   to k4, which can show progress.

2. **`MeterMap` conflates "the numerator" with "quarter notes per bar" — OPEN,
   found at m23-k3** — `MeterMap.Change.beatsPerBar` is both the number the UI
   and wire show as the time-signature numerator
   (`TempoLaneModel.meterEdited:145`, `Commands.parseMeterMap:4287`,
   `Commands.swift:5032` formats the pair as `"N/D"` for the AI) **and** the
   divisor the bar grid uses (`TempoMap.swift:402`, `:448`), while `beatUnit` is
   documented as cosmetic. For any denominator ≠ 4 the two readings disagree: a
   6/8 project gets bars of six quarter notes, twice the true length. m23-k3
   deliberately imports the numerator/denominator pair VERBATIM rather than
   translating, so import agrees with hand-entry and k4's export is the identity
   — the wrong bar length stays the model's existing, uniform limitation instead
   of becoming a new import-only behaviour. The fix is a separate bar-length
   quantity (quarter notes per bar, derived from the pair) that the grid math
   reads and the display does not; it touches `MeterMap.barsBefore`,
   `beat(ofBar:)`, `barBeat(atBeat:)`, `nearestBarline(toBeat:)` and the
   metronome's downbeat source, so it is its own item, not a k3 or k4 rider.

---

## 9. The two strongest alternatives to the overall shape, and why they lose

**Alternative A — map inside `ProjectStore`, no separate mapper type.** Fewer
files, no plan type, no `fileprivate` ceremony. It loses because every hazard
verdict in §1 then requires a `@MainActor` store, an undo journal and (for the
engine legs) a reconcile just to assert that a note landed on beat 3 — the
hazards become expensive to test and therefore under-tested. It also leaves the
door open for k4's drag-drop path to compute a landing beat itself, which is
exactly the divergence `ArrangeDropSnap` was built to make unrepresentable; the
m23-f measurement showed two computations agreeing *by luck* on one setting while
diverging on three others.

**Alternative B — a stateful two-call preview/confirm handshake instead of
`dryRun` + `parts`.** It reads nicer for a UI ("here is what I found, confirm?").
It loses because it introduces server-side state keyed to a token, with a
lifetime to get wrong (expiry, project mutated between the calls, two agents
racing), and because it makes the command non-idempotent — an agent that retries
after a dropped frame gets a different outcome. `dryRun` carries the same
information with zero state and is already the shipped shape
(`instrument.importSampleLibrary`).

---

## 10. Failure modes to watch during implementation

1. **The reciprocal-multiply "optimisation"** of R1 — caught by **G1b only**.
   G1a cannot catch it (measured, V.2 M1), and neither can a reviewer.
2. **Endpoint subtraction** for note length on a METRICAL file (G2 — and only
   with a non-dyadic length; measured, V.2 M2). Note the mirror hazard: applying
   R3's *prohibition* on the SMPTE path, where endpoint subtraction is the only
   correct form (R12).
3. **Merging format-1 channels**, passing a track-count assertion while
   colliding CC lanes (G11c is written specifically for this).
4. **`try!` on `TempoMap`/`MeterMap` construction** in §2.3/§2.4 — the invariants
   hold by construction, but a `try!` turns any future edit to the dedupe into a
   crash on a user's file.
5. **Looping `setInstrument`** instead of building `Track` values offline — N
   engine reconciles and `requireRoutingMutationAllowed` (§3.2).
6. **A `performEdit` that runs on `dryRun`** and mutates nothing but appends an
   undo entry (G7's journal leg).
7. **`applyTempoMap` called OUTSIDE the `performEdit`** — passes every functional
   leg, fails only G6.
7b. **Re-sorting §2.3/§2.4 step 1** — the arrays already arrive sorted, and
    Swift's `sorted(by:)` is not documented stable, so a "defensive" re-sort
    silently destroys H3's tie-break (G11d).
7c. **Decimating the RAW controller stream** instead of the canonical one, losing
    data the cap never objected to (H7).
7d. **Copying `importGeneration`'s `isAIGenerated = true`** along with its shape
    (§3.2) — an imported file rendered violet is a lie about its provenance.
8. **Reporting on a clean file** (G9). **Settled here, not deferred to
   gate-writing:** a file with NO `FF 58` is H4c (absence), so
   `synthesizedLeadingMeter` stays FALSE on `apple-type1.mid` and G9 needs **no
   exemption**. The flag that does fire there is `fileCarriedNoMeterMap`, which is
   informational and sits outside the loss section (§5). The remaining offender to
   watch is `notesWithDroppedReleaseVelocity`, which would fire on every
   Apple-written file if H5b's `{0, 64}` exemption is dropped.
9. **Treating H4c as H4b for meter.** The serious version of the above: a file
   with no `FF 58` at all is ABSENCE, not "the default at tick 0". Synthesizing
   4/4 there and then adopting it **stomps a user's 3/4 project with a meter their
   file never contained** — precisely the trap H4c exists to prevent. My own first
   draft of G4 made this mistake.
10. **`atBeat` leaking into note `startBeat`.** Notes are clip-relative; `atBeat`
    belongs on `clip.startBeat` only (R2 vs R5). A double-application puts every
    note at `2·atBeat`.

---

## 11. Explicitly the user's call, not mine — with the default I ship meanwhile

1. **Whether `instruments:"gm"` should be the default once k4 measures it.** I
   ship `"none"` in k3 and hand k4 the measurement. If the user would rather have
   correct GM instruments and accept a slower import, that is their preference to
   state; the code path is already there and it is a one-word default change.
2. **`maxImportedTracks = 32`.** A policy number protecting the main actor, not a
   physical limit. If the user routinely works with 64-track orchestral MIDI, the
   honest fix is to raise it (and measure), not to make them pass `force` every
   time.
3. **Whether an off-barline meter change should DROP (my default) or SNAP to the
   nearest barline.** Dropping preserves the file's bar grid up to that point and
   is reportable; snapping keeps a meter change the file asked for, at a beat it
   did not. I ship drop. A `meterPolicy: "drop" | "snap"` param is purely
   additive if the user prefers snap.
4. **Whether format 2 should lay out simultaneously (my default) or
   sequentially.** Vanishingly rare; I ship simultaneous + a report line.
5. **Added by the second read — whether the v1 meter-model defect should be fixed
   BEFORE import ships.** Because `beatsPerBar` is the numerator and
   `MeterMap.init` divides by it to test the barline rule, **any meter change
   after a non-4 denominator is usually dropped by H2** (§1.3-3: a 6/8 file with a
   4/4 change at its own bar 2 computes `bars = 0.5` and is dropped). Every
   alternative is worse — translating for the accept-test alone builds an array
   `MeterMap.init` itself rejects; translating for storage ships the numerator-12
   bug into k4 — so I ship the drop with a cause-naming reason string. But this is
   the likeliest "why did my time signature change disappear" report the feature
   will produce, and it is a direct consequence of the `docs/ARCHITECTURE.md` §8
   entry-2 defect. **Fixing the bar-length quantity first is a roadmap
   reordering, not a k3 decision** — it belongs to the user.

---

## RESOLVED AT IMPLEMENTATION (2026-07-27, orchestrator) — SMPTE × meter

§2.2 contradicted itself: it said `adopt` on a SMPTE file "resolves to ignore"
(a policy-level statement) while also saying meter events "are mapped normally".
Those pull opposite ways, and the implementer surfaced it rather than silently
picking one.

**Resolution: the implementer's reading stands — meter survives, and
`resolvedTempoPolicy` reports `"adopt"` on that path.** Grounds: `buildTempoMap`
already returns `nil` for an absolute-time clock *structurally*, so forcing the
policy to `ignore` would have changed nothing about tempo and exactly one thing
about meter — silently discarding it. A SMPTE file's "3/4 at tick 0" is a true
statement about the bar grid in a way "120 BPM" is not a true statement about its
clock, and §2.5's `(nil, meter?)` case exists precisely to adopt meter alone.

Recorded because the shipped fixture set carries no `FF 58` on a SMPTE file and
therefore **cannot arbitrate this** — the gate leg for it is a hand-built IR, and
a future reader who trusts §2.2's prose over the code would "fix" a deliberate
decision. If the design's literal reading is ever wanted instead, it is a one-line
revert plus two test edits.
