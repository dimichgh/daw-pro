# m23-o1 Step 2 — the instrument frequency reference table (CONTENT)

**Research pass, 2026-07-28 · research-analyst · input to `Sources/DAWCore/InstrumentFrequencyReference.swift`.**
Governed by `docs/research/design-m23o1-instrument-frequency-reference.md` §7 (the four rules) and §7's validator table V1–V8, plus the coordinator's **source-grade** requirement (2026-07-28).
Every number below is transcribed mechanically. **Nothing here requires a judgement call from the implementer** — where a choice was made, it was made here and the arithmetic that justifies it is printed inline.

---

## 0. Headline

| | |
|---|---|
| **Rows shipped** | **13** (design proposed 20) |
| **Rows DELETED** | 7 — `electricPiano`, `violin`, `viola`, `cello`, `trumpet`, `trombone`, `flute` (§7.0) |
| **Rows marked `ADMISSION-DOUBTFUL`** | **3** — `kick`, `snare`, `tom` (fundamental rests on a PRACTICE source; §7.1) |
| **Rows marked `FILTER-WEAK`** | **3** — `piano`, `rideCymbal`, `crashCymbal` (required HP corner rests on a tier-C or class-level source; §7.2) |
| **Percussion families** | all 6 survive → **`coveredNotes` stays 17** (staging leg S8's literal is unchanged) |
| **`InstrumentFamily.allCases.count`** | **13** — C1's literal moves 20 → 13 |
| **`melodicProgramFamilies`** | 128 entries, **18 non-nil / 110 nil** (§5) |
| **Citations shipped** | 69, carried by **~60 distinct quote strings** (some rows reuse one source sentence — W1 covers three rows, Z3 two, M1's cymbal sentences two roles each) |
| **Fundamentals graded PHYSICS** | **10 of 13** |
| **Quote verification** | **COMPLETE AT THE QUOTE LEVEL — every distinct quote string shipped here was reproduced from the live page during this pass** (§8). Three rounds, 22 fetches. **Verification is tracked PER QUOTE, not per source**: an earlier draft of this table ticked sources and thereby hid four unverified `snare`/`tom` quotes behind one verified `kick` quote on the same page. |
| **Quotes CORRECTED by verification** | **2** — Z1's `50–100` (ASCII hyphen → U+2013) and S7's `electricGuitar` LP (restored its leading `For example, `). Both would have failed a close-out spot-check as originally drafted. |
| **Forum / retail citations** | **ZERO.** No gearspace, gearslutz, dogsonacid, ebay, amazon or walmart URL is cited anywhere. They appeared only inside `WebSearch` result *lists*; none was fetched for content and none is a source. |
| **Sources rejected as uncitable** | Sweetwater (HTTP 403), iZotope *EQ Cheat Sheet* (fetcher refuses to reproduce), HyperPhysics (HTTP 502), tune-bot PDF (unreadable binary) — §7.4 G |

---

## 1. Conventions the implementer must know before transcribing

### 1.1 Source grades (coordinator requirement, 2026-07-28)

Every citation carries a grade. The rule I applied, and why:

> **The `fundamental` field must be P1 or P2. Bands and filter corners are PR by construction.**
>
> This is not a loosening — it is what the design already says. §2 admission rule 3 ("citable as physics, not convention") governs **the fundamental range**: *"The fundamental range must be a published property of the instrument."* §5 D4 classifies the other two quantities explicitly: fundamental = **"PHYSICS"**, bands and HP/LP = **"ENGINEERING OPINION"**. There is no physics source for "high-pass a kick at 35 Hz" because it is not a physical fact; it is a mixing decision, and the design's defence against a *bad* one is arithmetic (V2a/V2b/V3), not authority.

| Grade | Meaning |
|---|---|
| **P1** | **Physics — acoustics reference.** Instrument-acoustics research site (UNSW Music Acoustics is the model), acoustics/audio-engineering textbook, standards body, peer-reviewed source, or a manufacturer's own spec table. |
| **P2** | **Physics — spec/tuning + arithmetic.** The citation states the instrument's standard tuning or key compass as note names; Hz is **derived**, not quoted, via `f = 440·2^((m−69)/12)`. That formula is itself anchored to UNSW Music Acoustics, *Note names, MIDI numbers and frequencies* (https://newt.phys.unsw.edu.au/jw/notes.html), which states verbatim: `m for the note A4 is 69 and increases by one for each equal tempered semitone` and `By convention, A4 is often set at 440 Hz.` |
| **P2\*** | **Tuning/arithmetic claim from a PRACTICE-tier publisher, self-verifying.** The quote states a tuning fact *with* its frequency, and the frequency matches the equal-temperament derivation to better than 1%. Used only where the cleanest encyclopedic sentence carries markup that would break a mechanical string match (§3.9). Flagged per row. |
| **PR** | **Practice.** Mixing tutorials, vendor "learn" blogs, magazine technique articles. Expected and appropriate for bands and filter corners. |

**One grade needs its rationale stated, because it carries three rows.** **W1 (Wikipedia, *Cymbal*) is graded P2 without a tuning derivation.** The P2 definition above is written around the tuning-plus-arithmetic route, which W1 does not use — there is no range to derive from "indefinite pitch". It is graded P2 because it is an **encyclopedic statement of a physical property of the instrument** (inharmonicity), which is the same *kind* of claim as a compass or a tuning, and because **no P1 alternative was reachable**: UNSW Music Acoustics publishes no cymbal page, and HyperPhysics' drum and cymbal pages both return HTTP 502. If a reviewer rejects this grade, the three rows it carries (`hiHat`, `rideCymbal`, `crashCymbal`) lose their fundamental citation and become `ADMISSION-DOUBTFUL`; they do **not** become deletable, because `.inharmonic` is the correct value either way.

**`ADMISSION-DOUBTFUL`** = the row's **fundamental** is PR-only. **`FILTER-WEAK`** = the row's required HP corner rests on a tier-C publisher or on class-level (not instrument-named) guidance. Both are printed in the row header so the implementer cannot miss them and the reviewer can reject on sight.

### 1.2 Quote mechanics

1. **`quote` is a contiguous verbatim SUBSTRING of the page**, never stitched, never elided. Substrings are how every quote stays ≤ 200 characters. No `...`, no `…`, no `[]`. **Several quotes deliberately begin mid-sentence at a lowercase word** (`snare` HP and boxiness, `electricBass` body and harshness, `acousticGuitar` presence). That is legal and intentional — each was confirmed as a contiguous span of a longer sentence, and the leading lowercase letter is the page's own.
2. **Character fidelity.** Sound On Sound renders some hyphens as **U+2011 NON-BREAKING HYPHEN** (`‑`); iZotope and eMastered use **U+2013 EN DASH** (`–`) in ranges; Wikipedia's New Grove quote uses **primes and en dashes**, and its double-bass quote uses **U+2248 (≈)**. Quotes are printed as the page renders them, with `[U+2011]` / `[U+2013]` markers in the row note.
   **⚠ The hyphen CLASS on Sound On Sound quotes is uncertain and must not be used to reject a row.** Across this pass the fetcher reported *different* classes for the same construction on the same publisher — it flagged non-ASCII hyphens in the `kick` HP quote and then reported plain ASCII hyphens in the `acousticGuitar` quote, which is the same page family. The markdown conversion may be normalising. **Rule for the close-out check: a mismatch in hyphen/dash CLASS is a rendering artifact — correct the character from the live page. A mismatch in WORDS or NUMBERS is a content failure — delete the field.** (§8 restates this as the operative instruction.)
3. **⚠⚠ LEADING WORDS ARE THE HAZARD OF THIS PASS. A summarising fetcher drops them, and it did so TWICE, on two different publishers.**
   - **E1 (eMastered), `piano` presence.** Asked whether the string appeared, the fetcher answered "exact match found" and reproduced the sentence **without its leading `However,`**. A follow-up asking for *the first five words* proved `However,` is present and capitalised.
   - **S7 (Sound On Sound), `electricGuitar` LP.** Asked to reproduce the sentence **"from its FIRST character"**, the fetcher returned `most guitar amp cabinets don't…`. A follow-up asking for the first five words proved the page actually reads **`For example, most guitar amp cabinets don't…`**. *The explicit "from its first character" instruction was not sufficient.*
   - **The two cases differ in consequence, which is why you cannot skip the check.** Trimming `However,` off E1's sentence would have produced `If you want…` — **invalid**, because the page's `if` is lowercase mid-sentence. Trimming `For example,` off S7's leaves `most guitar…` — **still valid**, because `most` is lowercase either way. **You cannot tell which case you are in without asking.** Both quotes now ship in their full, separately-confirmed form.
   - **Operative rule: verify a quote with "state the exact first five words of that sentence." Nothing weaker is reliable.** Round 3 used this method on every remaining quote, which is how `tom`'s `For example, a 16 inch floor tom…` was confirmed intact rather than assumed.
4. **`retrieved` is `"2026-07-28"` on every citation, and that date is real** — every URL in §2 was fetched during this pass, today.
5. **The parenthetical character counts are approximate (±3)**, hand-counted as a V7 sanity check, not a machine count. **The only quote within 10 characters of the 200 limit is `kick`'s fundamental at 198 (exact, recounted three times).** If the implementer's build asserts V7 it will pass; if it prints counts they may differ from these by a few.

### 1.3 Number mechanics

6. **Hz → MIDI bridge.** Where a source states a tuning in Hz, the row prints the bridge. Rule: **nearest MIDI note; ties (within 0.1 Hz) break outward.**
7. **⚠⚠ V3 AND V5 ARE NON-STRICT (`≤`). FOUR SHIPPED FIELDS SIT AT EXACT EQUALITY. A strict `<` rejects all four and fails a correct table.** This is the single most likely mechanical-transcription failure in this document, so it is stated as a rule and not left in a row note:

   | Row | Check | Value at equality |
   |---|---|---|
   | `snare` | V3 | `100 ≤ min(100, 4000)` — HP corner equals the `body` band's low edge |
   | `femaleVocal` | V3 | `100 ≤ min(100, 2000, 7000)` — same shape |
   | `hiHat` | V3 | `300 ≤ min(300, 10000)` — same shape |
   | `acousticGuitar` | V5 | `20000 ≤ 20000` — `air` band's high edge is the audible ceiling itself |

   These are not accidents: three of them are the deliberate result of putting the corner exactly at the bottom of the instrument's own cited body region (§7.3 C-4 explains the hi-hat case). **Related: `rideCymbal` carries exactly 3 distinct sources, which is V8's floor, not a margin above it.** Deleting any one of its citations fails V8.
8. **`highest` is cited, never invented.** For the two basses the citation names all four open strings, so both endpoints are cited; `highest` is the **open G string** and fretted/stopped notes go higher — the row says so and nothing above it is invented.
9. **Overlapping bands are deliberate** (`tom` body 80–250 vs mud 150–200; `maleVocal` body 100–400 vs mud 300–400). Both are cited; the region genuinely carries warmth *and* bloat. Do not "fix" the overlap.
10. **Roles** are the design's enum only: `body`, `presence`, `attack`, `air` (desirable) / `rumble`, `mud`, `boxiness`, `harshness`, `sibilance` (problem). **No dB amounts ship** as advice (D4); `effect` says *where* and *what it does*. The dB figures that appear inside `rationale` strings are **attenuation arithmetic**, not boost/cut advice, and each was computed from the Butterworth magnitude `|H(f)| = (f/fc)^n / sqrt(1 + (f/fc)^(2n))` with `n = 2` for 12 dB/oct and `n = 4` for 24 dB/oct — the design's own formula (§1 F1). They are recomputable; they were recomputed before shipping.

### 1.4 Citation scope rule (this produced the deletions in §7.0)

> A band or filter citation must be attributable to the row's instrument **by name** — inside the quote, or in the section heading immediately above it, which is then named in the `source` field. Guidance addressed to an **ensemble or section** ("Orchestral Strings", "Orchestral Brass") does **not** qualify for a single-instrument row.

**The one place this rule is applied with a stated exception is `electricGuitar` (§3.9). The exception is narrow and the reasoning is printed there**, because a reviewer comparing it against the deleted `trumpet` row will otherwise see an inconsistency.

### 1.5 Reference arithmetic (recompute if you doubt it)

`hz(m) = 440 · 2^((m−69)/12)`; `2^(1/3) = 1.2599210499`

| MIDI | Note | Hz | MIDI | Note | Hz |
|---|---|---|---|---|---|
| 21 | A0 | 27.5000 | 43 | G2 | 97.9989 |
| 28 | E1 | 41.2034 | 47 | B2 | 123.4708 |
| 31 | G1 | 48.9994 | 53 | F3 | 174.6141 |
| 39 | D#2 | 77.7817 | 55 | G3 | 195.9977 |
| 40 | E2 | 82.4069 | 67 | G4 | 391.9954 |
| 41 | F2 | 87.3071 | 76 | E5 | 659.2551 |
| 42 | F#2 | 92.4986 | 79 | G5 | 783.9909 |
| | | | 108 | C8 | 4186.0090 |

Note names via `KeyEstimate.pitchClassesSharp`, octave `m/12 − 1` (C11's pins 28→E1, 60→C4, 69→A4 are consistent with every value above).

---

## 2. Sources used, with grade

**Every row below was fetched during this pass, and EVERY QUOTE it carries was reproduced character-for-character from the live page.** The count in the status column is the number of *distinct shipped quote strings* confirmed on that page — not a source tick.

| # | Source | URL | Grade | Quotes confirmed |
|---|---|---|---|---|
| **U1** | **UNSW Music Acoustics (Joe Wolfe), *Voice acoustics: an introduction*** | https://newt.phys.unsw.edu.au/jw/voice.html | **P1** | ✅ **1/1** (R1 #10) — serves both vocal rows |
| **U2** | **UNSW Music Acoustics, *Note names, MIDI numbers and frequencies*** | https://newt.phys.unsw.edu.au/jw/notes.html | **P1** | ✅ **2/2** (R2) — anchors the arithmetic, §1.1 |
| W1 | Wikipedia, *Cymbal* | https://en.wikipedia.org/wiki/Cymbal | **P2** (rationale in §1.1) | ✅ **1/1** (R1 #7) — serves three rows |
| W2 | Wikipedia, *Bass guitar* (New Grove tuning) | https://en.wikipedia.org/wiki/Bass_guitar | **P2** | ✅ **1/1**, reproduced twice identically (R1 #5) |
| W3 | Wikipedia, *Double bass* | https://en.wikipedia.org/wiki/Double_bass | **P2** | ✅ **1/1** (R2) |
| W4 | Wikipedia, *Piano* | https://en.wikipedia.org/wiki/Piano | **P2** | ✅ **1/1** (R2) — note names carry **no** markup |
| S1 | Sound On Sound, *Mixing DI Bass Guitar* | https://www.soundonsound.com/techniques/mixing-di-bass-guitar | PR | ✅ **1/1** (R1 #4) |
| S2 | Sound On Sound, *Mixing Bass* (Mike Senior) | https://www.soundonsound.com/techniques/mixing-bass | PR | ✅ **3/3** (R1 #6, R2) |
| S3 | Sound On Sound, *Mix Tips For Kick & Bass* | https://www.soundonsound.com/techniques/mix-tips-kick-bass | PR | ✅ **2/2** (R1 #2) |
| S4 | Sound On Sound, *Tricks To Make Your Drums Sparkle* | https://www.soundonsound.com/techniques/tricks-make-your-drums-sparkle | PR | ✅ **4/4** (R1 #3, #9) |
| S5 | Sound On Sound, *Mixing Multitracked Drums* | https://www.soundonsound.com/techniques/mixing-multitracked-drums | PR | ✅ **4/4**, **UN-PRIMED** (R2) |
| S6 | Sound On Sound, *Mixing Essentials* ("Mixing EQ Cookbook") | https://www.soundonsound.com/techniques/mixing-essentials | PR | ✅ **12/12** (R2) |
| S7 | Sound On Sound, *EQ: What Do All Those Knobs Do?* | https://www.soundonsound.com/sound-advice/eq-what-do-all-those-knobs-do | PR | ✅ **3/3** (R2), **1 corrected** on a first-five-words re-check (§1.2 note 3) |
| S8 | Sound On Sound, *How To Make Your Vocals Twice As Good! Part 2* | https://www.soundonsound.com/techniques/how-make-your-vocals-twice-good-part-2 | PR | ✅ **2/2** + male-voice scope confirmed (R2) |
| D1 | iDrumTune (Dr Rob Toulson), *Guide To Mixing Drums* | https://www.idrumtune.com/mixing-drums-know-your-drum-frequencies/ | PR | ✅ **5/5** (R1 #1 for `kick`; **R3 for the four `snare`/`tom` quotes**) |
| Z1 | iZotope, *Ultimate guide: How to EQ vocals* | https://www.izotope.com/en/learn/how-to-eq-vocals | PR | ✅ **3/3** (R1 #11 — 1 **corrected**; **R3 for `rumble`**) |
| Z2 | iZotope, *How to Mix Hi-Hats* | https://www.izotope.com/community/blog/how-to-mix-hi-hats | PR | ✅ **1/1**, en dash (R2) |
| Z3 | iZotope, *How to EQ acoustic guitar in a mix* | https://www.izotope.com/en/learn/acoustic-guitar-eq.html | **P2\*** for tuning, PR otherwise | ✅ **1/1**, lowercase `hz` intact (R2) — serves both guitar rows |
| P1s | Production Expert, *5 Hi-Hat Mixing Tips* | https://www.production-expert.com/production-expert-1/5-hi-hat-mixing-tips | PR | ✅ **1/1** (R1 #8) |
| M1 | Musical U, *Percussion Frequencies Part 2 – Cymbals* | https://www.musical-u.com/learn/percussion-frequencies-part-2-cymbals/ | PR | ✅ **3/3** (R2) — each sentence serves two roles |
| E1 | eMastered, *How to EQ Piano* | https://emastered.com/blog/piano-eq | PR | ✅ **4/4** + leading-words re-check (R2) |
| E2 | eMastered, *How to EQ Toms* | https://emastered.com/blog/floor-toms-eq | PR | ✅ **3/3**, **UN-PRIMED** (R2) |
| C1s | Stock Music Musician, *How to EQ Piano* | https://www.stockmusicmusician.com/blog/tips-for-eqing-piano | PR (tier C) | ✅ **1/1**, en dash (R2) |
| C2s | Music Guy Mixing, *Cymbal EQ Guide* | https://www.musicguymixing.com/cymbal-eq/ | PR (tier C) | ✅ **2/2** (R2) |

**Tier-C publishers carry exactly three fields in the whole table**: `piano` HP (C1s), `rideCymbal` HP and `crashCymbal` HP (C2s). All three rows are flagged `FILTER-WEAK`. **The flag is about publisher TIER, not about verification** — all three quotes are confirmed verbatim.

---

## 3. THE ROWS (13)

Field order matches the `InstrumentFrequencyReference` struct.

---

### 3.1 `kick` — ⚠ `ADMISSION-DOUBTFUL`

> **What's missing:** no P1/P2 source states a kick drum's fundamental. A kick's pitch is a **tuning choice**, not a constant of the instrument, so the shipped range is "typical tunings per a practice source", not a published physical property. §7.1 names the manufacturer table that would fix this and why I could not lift it.

- **displayName**: `"Kick drum"`
- **fundamental**: `.pitched(lowestMIDINote: 31, highestMIDINote: 42)` → 48.999 Hz (G1) … 92.499 Hz (F#2)
  - Bridge: *as low as 50 Hz* → MIDI 31 (48.999, Δ1.00 vs MIDI 32's Δ1.91); *as high at 80 or 90 Hz* → MIDI 42 (92.499, Δ2.50 vs MIDI 41's Δ2.69).
- **fundamentalCitation** — **grade PR** ⚠
  - source `"iDrumTune (Dr Rob Toulson), Guide To Mixing Drums"` · url `https://www.idrumtune.com/mixing-drums-know-your-drum-frequencies/`
  - quote: `Kick drums can be tuned to have a fundamental frequency as low as 50 Hz and as high at 80 or 90 Hz depending on the drum size, the type of drumheads used and the style of music that is being played.` (**198 — exact; the longest quote in the table and the only one near V7's limit**) — *"as high at" is the page's own wording; do not correct it.*
- **HP**: `.corner(hz: 35, slopeDbPerOct: 24, rationale: "The kick's own lowest tuning sits near 49 Hz; 35 Hz clears room rumble and stand thump beneath it while costing that fundamental only about 0.3 dB. Do NOT follow the common 'high-pass everything at 80 Hz' advice here — at 80 Hz this drum loses about 17 dB of its own fundamental.")` — citation **grade PR** (expected: engineering opinion)
  - S3 · quote: `Applying a low‑cut (high‑pass) filter to anything below 30-40Hz will help to keep this under control.` (100) **[hyphen class in `low‑cut`/`high‑pass` reported as U+2011 by the checker; the `30-40Hz` hyphen is ASCII. See §1.2 note 2 — class mismatch is not grounds to delete.]**
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "A kick's beater click lives at 2–4 kHz and useful content continues above it; anything higher is cymbal spill, which is a gating and balance decision, not cleanup.")`
- **bands** (3) — all **grade PR**

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `body` | 70 | 90 | "The low-end weight you feel in the chest rather than hear." | S4 · `If the kick needs more low-end weight, you can EQ it after gating it, by applying some boost in the 70-90Hz region` (113) |
| `boxiness` | 150 | 200 | "Cardboard hollowness that makes the drum sound like a box instead of a drum." | S4 · `you may also find that cutting in the 150-200Hz region reduces any tendency for the kick drum to sound boxy` (106) |
| `attack` | 2000 | 4000 | "The beater click that lets the kick be heard on small speakers." | S4 · `dedicated kick-drum mics on the market that have tailored frequency response curves to accentuate the 70-90Hz thump, as well as the 2-4kHz beater click` (151) |

- **Validators**: V1 `0 ≤ 31 ≤ 42 ≤ 127` ✅ · V2a `35 ≤ 48.999 × 1.259921 = 61.735` ✅ · V2b `35 ≥ 12.250` ✅ · V3 `35 ≤ min(70, 2000) = 70` ✅ · V4 `35 ∈ 20…1000`, slope 24 ✅ · V5 ✅
- **Rationale arithmetic** (n = 4): at fc 35 Hz, 48.999 Hz → **−0.28 dB**; at fc 80 Hz, 48.999 Hz → **−17.1 dB**.

---

### 3.2 `snare` — ⚠ `ADMISSION-DOUBTFUL`

> **What's missing:** same as `kick` — the fundamental is a tuning choice from a PR source. The cited range is one drum size (14-inch), narrower than the family.

- **displayName**: `"Snare drum"`
- **fundamental**: `.pitched(lowestMIDINote: 53, highestMIDINote: 55)` → 174.614 Hz (F3) … 195.998 Hz (G3)
  - Bridge: *170 Hz* → MIDI 53 (Δ4.61 vs 52's Δ5.19); *200 Hz* → MIDI 55 (Δ4.00 vs 56's Δ7.65).
  - **Deliberately narrow**: the cited tuning of a standard 14-inch snare, not every snare ever built. Piccolo and deep snares sit outside; v1 does not widen an uncited range.
- **fundamentalCitation** — **grade PR** ⚠ · D1 · quote: `A standard 14 inch snare drum can usually be tuned sound great at a fundamental frequency of 170 Hz and also tiger up at 200 Hz too.` (132) — *"tuned sound great" and "tiger up" are the page's own typos; verbatim means verbatim.* **[R3-confirmed: first five words are `A standard 14 inch` — sentence-initial, no dropped clause.]**
- **HP**: `.corner(hz: 100, slopeDbPerOct: 24, rationale: "A close snare mic hears the kick as much as the snare. 100 Hz sits well below the drum's own ~175 Hz fundamental and removes the kick bleed and stand rumble that muddy the middle of the kit.")` — **PR** · D1 · quote: `if our snare is tuned to 200 Hz, we know we can safely set a low-cut EQ on the snare channel at, say 100 Hz` (105) **[R3-confirmed: the sentence's own first words are `if our snare is` — the lowercase `if` is the PAGE'S, not a truncation. Do not capitalise it.]**
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "The snare's crack and wire rattle run past 8 kHz; a corner low enough to matter would dull the drum, and anything gentler is a taste move.")`
- **bands** (3) — all **PR**

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `body` | 100 | 150 | "The weight of the shell — makes a thin snare sound like a real drum." | S5 · `you can add more body to the sound by applying a cautious amount of EQ boost at 100 to 150Hz` (91) |
| `boxiness` | 300 | 350 | "The edge overtone that rings on after the hit and distracts from the drum's pitch." | D1 · `by applying some attenuation at the snare drum's edge overtone frequency, which will usually be at around 300-350 Hz` (115) **[R3-confirmed as a mid-sentence SUBSTRING; the full sentence begins `We can manipulate this with EQ therefore…`. The shipped span is contiguous and starts at the page's own lowercase `by`.]** |
| `attack` | 4000 | 8000 | "The crisp snap that makes the backbeat cut through a dense mix." | S5 · `If the snare needs any extra crispness, then try a little high EQ at between 4 and 8kHz` (86) |

- **Validators**: V1 ✅ · V2a `100 ≤ 174.614 × 1.259921 = 220.000` ✅ · V2b `100 ≥ 43.654` ✅ · **V3 `100 ≤ min(100, 4000) = 100` ✅ — EQUALITY, see §1.3 note 7; a strict `<` fails this row** · V4 ✅ · V5 ✅

---

### 3.3 `hiHat` — INHARMONIC

- **displayName**: `"Hi-hat"`
- **fundamental**: `.inharmonic(reason: "Hi-hat cymbals have no single fundamental — their partials are not harmonically related, so any stated pitch range would be invented.")`
- **fundamentalCitation** — **grade P2** (encyclopedic statement of a physical property; no range to derive — grading rationale in §1.1) · W1 · quote: `The majority of cymbals are of indefinite pitch, although small disc-shaped cymbals based on ancient designs (such as crotales) sound a definite note.` (148)
- **HP**: `.corner(hz: 300, slopeDbPerOct: 12, rationale: "A hat mic hears kick and snare bleed plus pedal and stand thump. 300 Hz is the top of the range published practice puts the corner in; the gentle 12 dB/oct slope is chosen because the corner sits right at the bottom edge of the hat's own body region, so a steeper cut would start eating it.")` — **PR**, instrument-named ✅
  - P1s · quote: `Set the cutoff frequency just below the point at which it starts to alter the sound significantly as you raise it, which will likely be somewhere between 200 and 400Hz.` (168)
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "A hi-hat's usefulness IS its top end — cited content runs to 17 kHz. Any corner low enough to matter would remove the instrument.")`
- **bands** (3) — all **PR**

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `body` | 300 | 3000 | "The 'chick' — the substance of the closed hat, without which it becomes a hiss." | M1 · `Typical hi-hats are usually between 300-3000 Hz dominant frequencies, and can extend up to 10-17k Hz for crispness` (113) |
| `harshness` | 4000 | 8000 | "Ringing resonances that make busy hat patterns tiring over a whole song." | Z2 · `Pro-tip: remember that some resonances exist in a lower part of the spectrum, between 4–8 kHz.` (93) **[U+2013 — confirmed en dash]** |
| `air` | 10000 | 17000 | "Crispness and sparkle — the shimmer that sits above the rest of the kit." | M1 · `Typical hi-hats are usually between 300-3000 Hz dominant frequencies, and can extend up to 10-17k Hz for crispness` (113) |

- **Validators**: V2 N/A (inharmonic) · **V3 `300 ≤ min(300, 10000) = 300` ✅ — EQUALITY, §1.3 note 7** · V4 `300 ∈ 20…1000`, slope 12 ✅ · V5 `17000 ≤ 20000` ✅ · **V6 two desirable bands** ✅

---

### 3.4 `tom` — ⚠ `ADMISSION-DOUBTFUL`

> **What's missing:** same as `kick`/`snare`. The only per-drum tom tuning statement I could quote covers a **16-inch floor tom**, the lowest drum in the family.

- **displayName**: `"Tom-tom"`
- **fundamental**: `.pitched(lowestMIDINote: 39, highestMIDINote: 47)` → 77.782 Hz (D#2) … 123.471 Hz (B2)
  - Bridge: *80 Hz* → MIDI 39 (Δ2.22 vs 40's Δ2.41); *120 Hz* → MIDI 46 and 47 sit within 0.012 Hz of each other, tie breaks **outward** → MIDI 47.
  - **Design §4 offered a 3-way tom split "if the research pass finds three citable ranges". It did not.** `tom` stays one family; the note map is unchanged.
- **fundamentalCitation** — **grade PR** ⚠ · D1 · quote: `For example, a 16 inch floor tom can feasibly be tuned to have a fundamental frequency at 80 Hz or at 120 Hz.` (108) **[R3-confirmed: first five words are `For example, a 16` — the leading clause IS the page's and IS shipped. This is the same construction the fetcher silently dropped from S7's sentence, which is why it was re-checked rather than assumed.]**
- **HP**: `.corner(hz: 60, slopeDbPerOct: 12, rationale: "Toms are the kit's biggest rumble source between hits — the shells resonate with the kick. 60 Hz is the top of the published starting range and still sits under the lowest floor-tom fundamental near 78 Hz.")` — **PR** · E2 · quote: `Start with a gentle high-pass filter, rolling off everything below 40–60 Hz.` (75) **[U+2013]**
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "Stick definition lives at 4–8 kHz and cymbal spill above it is a balance decision made with the overheads, not a filter decision on the tom.")`
- **bands** (4) — all **PR**

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `body` | 80 | 250 | "The tom's own note — where each drum's pitch and sustain live." | S5 · `experiment with frequencies between 80Hz and 250Hz to try to pick out the resonance of each tom` (94) |
| `mud` | 150 | 200 | "Bloat that makes a tom fill sound heavy and slow." | E2 · `A gentle cut around 150–200 Hz can clean things up.` (50) **[U+2013]** |
| `boxiness` | 400 | 600 | "The cardboard tone that makes close-miked toms sound cheap." | E2 · `The 'cardboard' or 'boxy' sound tends to live between 400–600 Hz.` (64) **[U+2013]** |
| `attack` | 4000 | 8000 | "Stick definition — the tom's front edge in a busy fill." | S5 · `a high‑end boost between 4 and 8kHz can add definition to the attack of a sound` (78) **[hyphen class uncertain — §1.2 note 2]** |

- **Validators**: V1 ✅ · V2a `60 ≤ 77.782 × 1.259921 = 97.999` ✅ · V2b `60 ≥ 19.445` ✅ · V3 `60 ≤ min(80, 4000) = 80` ✅ · V4 ✅ · V5 ✅

---

### 3.5 `rideCymbal` — INHARMONIC · ⚠ `FILTER-WEAK`

> **What's weak:** the required HP corner comes from a tier-C publisher and is **class-level** (addressed to "cymbals", not the ride). The fundamental and both bands are fine. **All three quotes are verbatim-confirmed** — the flag is about publisher tier, not verification.

- **displayName**: `"Ride cymbal"`
- **fundamental**: `.inharmonic(reason: "A ride cymbal is of indefinite pitch — its partials are inharmonic, so there is no fundamental to state.")`
- **fundamentalCitation** — **P2** · W1 · quote as §3.3 (148)
- **HP**: `.corner(hz: 200, slopeDbPerOct: 12, rationale: "A ride mic mostly hears the rest of the kit below 200 Hz. Cutting there removes kick and snare bleed while leaving the cymbal's 300–600 Hz body intact; pushing the corner higher starts thinning the cymbal itself.")` — **PR (tier C, class-level)** ⚠
  - C2s · quote: `In the case of cymbal EQ, there's nothing below 200Hz that we need, so set your high pass filter here as a starting point.` (121) **[straight apostrophe, confirmed]**
  - Admitted under §1.4 because a ride **is** a cymbal (the guidance names the object class of the row) and both band citations name the ride explicitly. **If the parent prefers a harder bar, delete `rideCymbal` + `crashCymbal` and set notes 49/51/57/59 to uncovered — `coveredNotes` drops 17 → 13 and S8's literal must move.**
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "The ride's sheen and air run to the top of the audible band; a corner low enough to matter would remove the wash that identifies the instrument.")`
- **bands** (2) — **PR**, both instrument-named ✅

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `body` | 300 | 600 | "The weight behind the stick hit — cut too much and the ride turns into a hiss." | M1 · `So where does a ride cymbal live Hz wise? Typically between 300-600 Hz, all the way up to 4-6k Hz for upper sheen.` (112) |
| `presence` | 4000 | 6000 | "Upper sheen — the sustained shimmer that carries the pattern under a vocal." | M1 · same quote (112) |

- **Validators**: V2 N/A · V3 `200 ≤ min(300, 4000) = 300` ✅ · V4 ✅ · V5 ✅ · **V6** ✅ · ⚠ **V8: exactly 3 distinct sources (W1, C2s, M1) — the floor, not a margin. Removing any citation on this row fails V8** (§1.3 note 7).

---

### 3.6 `crashCymbal` — INHARMONIC · ⚠ `FILTER-WEAK`

> Same weakness as `rideCymbal`: tier-C, class-level HP. All quotes verbatim-confirmed.

- **displayName**: `"Crash cymbal"`
- **fundamental**: `.inharmonic(reason: "A crash cymbal is of indefinite pitch — its partials are inharmonic, so there is no fundamental to state.")`
- **fundamentalCitation** — **P2** · W1 · quote as §3.3 (148)
- **HP**: `.corner(hz: 200, slopeDbPerOct: 12, rationale: "Same reasoning as the ride: below 200 Hz a crash mic is hearing the rest of the kit. The crash's own body starts around 400 Hz, so 200 Hz leaves a comfortable margin.")` — **PR (tier C, class-level)** ⚠ · C2s · quote: `Begin by high passing around 200Hz to remove unwanted bleed and create space for the bass and kick.` (98)
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "A crash is almost entirely high-frequency content; its sheen is cited to 12 kHz and beyond. Cutting the top removes the instrument.")`
- **bands** (3) — **PR**

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `body` | 400 | 500 | "The low clang of a big crash — what makes it feel large rather than thin." | M1 · `A typical crash can be any where from 400-500 Hz (or lower) all the way up to 10k-12k Hz for sheen` (97) — *"any where" is the page's own spelling.* |
| `harshness` | 3000 | 6000 | "The brash edge that makes repeated crashes painful over a whole song." | S4 · `harshness can be reduced by cutting in the 3-6kHz region where cymbals tend to be at their most brash` (100) |
| `air` | 10000 | 12000 | "Sheen — the bright wash that opens the top of the mix on a hit." | M1 · same quote as `body` (97) |

- **Validators**: V2 N/A · V3 `200 ≤ min(400, 10000) = 400` ✅ · V4 ✅ · V5 ✅ · **V6** ✅

---

### 3.7 `electricBass` ★ mandatory spot-check row

- **displayName**: `"Electric bass guitar"`
- **fundamental**: `.pitched(lowestMIDINote: 28, highestMIDINote: 43)` → 41.203 Hz (E1) … 97.999 Hz (G2)
  - **Both endpoints are stated by the citation** (E1 lowest string, G2 highest string). Hz is **derived** from the note names, not quoted. Fretted notes go above G2; v1 invents no upper bound.
  - **5-string decision, stated because V2a depends on it**: `lowest` is **E1 (4-string)**, not B0. The 30 Hz corner was chosen so it passes V2a **under either reading** — against B0 (30.868 Hz) the bound is 38.89 and 30 still clears it. A 5-string player loses about **2.8 dB** at B0 with this corner and slope.
- **fundamentalCitation** — **grade P2** ✅ · W2 · url `https://en.wikipedia.org/wiki/Bass_guitar`
  - quote: `Electric bass guitar, usually with four heavy strings tuned E1'–A1'–D2–G2.` (73) **[primes and U+2013 en dashes are the page's own; this is the inner New Grove quotation, which carries no italics markup — the surrounding sentence does]**
  - **Corroboration (not shipped, PR grade)**: S1 states `The fundamental of the bottom E on a four‑string bass is 41Hz` — 41 Hz vs the derived 41.203 Hz, agreement to 0.5%.
- **HP**: `.corner(hz: 30, slopeDbPerOct: 12, rationale: "Nothing musical exists below the low E's 41.2 Hz, but stage rumble, handling noise and DI thump do — and they eat headroom in the loudest part of the mix. The 12 dB/oct slope is the shallower of the two the cited source names and the only one of them this DAW can execute (its other option, 18 dB/oct, does not exist here). This corner is deliberately NOT the folklore 80 Hz: at 80 Hz the low E loses about 12 dB even at this gentle slope, and about 23 dB at 24 dB/oct.")` — **PR**, instrument-named ✅
  - S1 · quote: `So slope it off with a 30Hz high‑pass filter (HPF) at 12 or 18 dB per octave.` (76) **[hyphen class in `high‑pass` reported as U+2011 — §1.2 note 2]**
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "String and fret noise and amp fizz run past 6 kHz and are part of how a bass reads on small speakers. A low-pass here is an arrangement decision, not cleanup.")`
- **bands** (3) — **PR**, all instrument-named ✅

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `body` | 40 | 80 | "The bottom octave — the weight the bass shares with the kick drum." | S2 · `you'll want to give the bass as much room in the 40-80Hz region as you can without completely losing the weight of the kick` (122) |
| `presence` | 220 | 300 | "The instrument's essential character — where a bass stops being a rumble and starts being an instrument." | S3 · `you'll probably identify that part of the sound that gives the bass its essential character somewhere in the 220‑300 Hz region` (125) **[hyphen class in `220‑300` uncertain — §1.2 note 2]** |
| `harshness` | 3000 | 6000 | "Hiss, amp fuzz, pick noise and filter whistle — where a boosted bass starts fighting the vocal." | S2 · `nor sends too much hiss, amp fuzz, pick noise or filter whistle into a mix's 3-6kHz presence/harshness band` (106) |

- **Validators**: V1 ✅ · V2a `30 ≤ 41.203 × 1.259921 = 51.913` ✅ (and `30 ≤ 38.89` against a 5-string B0) · V2b `30 ≥ 10.301` ✅ · V3 `30 ≤ min(40, 220) = 40` ✅ · V4 `30 ∈ 20…1000`, slope 12 ✅ · V5 ✅
- **Rationale arithmetic**: fc 80 Hz on 41.203 Hz → **−11.8 dB (n=2)**, **−23.1 dB (n=4)**. fc 30 Hz on B0 30.868 Hz → **−2.77 dB (n=2)**.
- **Staging-gate note (S3/B1)**: corner 30 Hz at 12 dB/oct costs **0.67 dB** at band 0's observation window (≈46.9 Hz @ 48 kHz) — inside S3's 6 dB bar with 5+ dB margin. It also **confirms §8.2's decision to fix S4 at 100 Hz / 24 dB/oct**: `2 × hp = 60 Hz` at 12 dB/oct costs only **5.7 dB** at the window — under the 6 dB bar, so a computed `2 × hp` control leg would have failed while S3 was green.

---

### 3.8 `uprightBass`

- **displayName**: `"Upright (double) bass"`
- **fundamental**: `.pitched(lowestMIDINote: 28, highestMIDINote: 43)` → 41.203 Hz (E1) … 97.999 Hz (G2)
  - `highest` = the open G string (the citation's tuning sentence on the same page states E–A–D–G); a fretless fingerboard has no countable upper limit to cite, so none is invented.
  - A C-extension or 5-string reaches C1 (32.703) or B0 (30.868); the 35 Hz corner clears V2a against **both** (bounds 41.20 and 38.89).
- **fundamentalCitation** — **grade P2** ✅ · W3 · quote: `The lowest note of a double bass is an E1 (on standard four-string basses) at approximately 41 Hz or a C1 (≈33 Hz), or sometimes B0 (≈31 Hz), when five strings are used.` (169) — states the note **and** the Hz; the derived 41.203 Hz agrees. **[U+2248 ≈ confirmed as the page's own symbol]**
- **HP**: `.corner(hz: 35, slopeDbPerOct: 12, rationale: "Slightly above the electric bass's corner on purpose: an upright's body resonance and stage rumble sit lower and louder than a DI'd electric, and the kick drum owns the bottom octave in most arrangements.")` — **PR**, instrument-named ✅ · S2 · quote: `Kick drum will naturally tend to dominate over acoustic bass in the bottom octave, so try high-pass filtering the latter from around 35Hz.` (136) **[ASCII hyphen in `high-pass`, explicitly confirmed]**
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "Bow and finger noise carry the instrument's identity; cutting the top makes an upright sound like a synth bass.")`
- **bands** (2) — **PR**

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `body` | 40 | 80 | "The bottom octave the upright shares with the kick drum." | S2 · `you'll want to give the bass as much room in the 40-80Hz region as you can without completely losing the weight of the kick` (122) — ⚠ says "the bass" (article-level; the article covers acoustic bass explicitly), not "double bass". |
| `presence` | 400 | 800 | "Articulation — where the note's start becomes audible instead of just felt." | S7 · `a gentle boost somewhere in the 400 to 800 Hz region can help a double bass to sound more articulate and present in the mix` (121) |

- **Validators**: V1 ✅ · V2a `35 ≤ 51.913` ✅ · V2b `35 ≥ 10.301` ✅ · V3 `35 ≤ min(40, 400) = 40` ✅ · V4 ✅ · V5 ✅
- ⚠ **Admission-rule-2 tension, reported not resolved**: identical fundamentals to `electricBass`, corners 1/6 of an octave apart (35/30 = 1.167 < 1.26), so §2 rule 2 would merge them. **I did not merge** — the enum is fixed by the design, merging would *widen* a GM mapping (forbidden to a research pass), and the band content differs and is separately cited. A v2 design call.

---

### 3.9 `electricGuitar`

- **displayName**: `"Electric guitar"`
- **fundamental**: `.pitched(lowestMIDINote: 40, highestMIDINote: 76)` → 82.407 Hz (E2) … 659.255 Hz (E5)
- **fundamentalCitation** — **grade P2\*** · Z3 · quote: `Depending on the tuning, the low E string of an acoustic guitar sounds at around 82 hz, while the 12th fret of the high E string plays around 659 Hz.` (147) — **[lowercase `hz` in the first instance is the page's own; confirmed. Do not normalise it.]**
  - **Self-verifying**: E2 derives to 82.407 Hz (quote says 82) and E5 to 659.255 Hz (quote says 659) — agreement to 0.05%. That is why this is P2\* and not PR.

  - ⚠ **The quote names the ACOUSTIC guitar, and this is the table's one stated exception to §1.4. The reasoning, because a reviewer will compare it against the deleted `trumpet` row:**

    > **`trumpet` was deleted for a NUMBER mismatch; `electricGuitar` has a NAME mismatch on an invariant property. These are not the same failure.**
    >
    > Trumpet's quote states a **written** F♯, which sounds E3 on a B♭ instrument — so the MIDI field (52) would have disagreed with the pitch named in its own quote (F♯3 = 54). A transposition step sat between the quote and the field, and `lowest` is V2a's input, so the disagreement was load-bearing. **The numbers were wrong.**
    >
    > Here the numbers match exactly — 82 → MIDI 40, 659 → MIDI 76, both to 0.05% — and only the instrument *name* differs. The property being cited is **standard tuning**, which is identical on an acoustic and an electric guitar; it is a property of the string set and the fretboard, not of the body. §1.4 exists to stop *EQ guidance* crossing between instruments, because EQ guidance depends on the resonating body and genuinely does differ. Tuning does not.
    >
    > **Scope of the exception: it covers TUNING claims only, and it is used exactly once.** Nothing else in the table crosses an instrument name.

  - **Cleaner P2 alternative the implementer may prefer**: Wikipedia *Guitar tunings* (https://en.wikipedia.org/wiki/Guitar_tunings) renders `In scientific pitch notation, the guitar's standard tuning consists of the following notes: E2–A2–D3–G3–B3–E4.` — **but in the fetched markdown every note letter carries bold markup and "notes" carries a hyperlink**, so a mechanical string match against the plain-text form is unreliable. Not shipped for that reason; §7.4 G records the class of problem.
  - **Checked and does NOT resolve this**: Wikipedia *Electric guitar* (https://en.wikipedia.org/wiki/Electric_guitar) was fetched during this pass specifically to close the name gap. It states only that a six-string guitar `is usually tuned E, A, D, G, B, E, from lowest to highest strings` — **no octave numbers, therefore no derivable Hz**, so it cannot serve as the P2 citation. The exception above stands rather than being replaced.
- **HP**: `.corner(hz: 80, slopeDbPerOct: 24, rationale: "A guitar cabinet produces boom below the low E that no listener needs, and distorted chords generate a lot of it. 80 Hz sits just under the low E's 82.4 Hz fundamental — as high as this corner may legally go. The widely repeated 'high-pass guitars at 150 Hz' advice is rejected here: at 150 Hz the open low E loses about 21 dB.")` — **PR**, instrument-named by heading ✅ · S6 (Electric Guitar section) · quote: `Cut below 80Hz to reduce unnecessary bassy cabinet boom.` (56)
- **LP**: `.corner(hz: 6000, slopeDbPerOct: 12, rationale: "A guitar amp cabinet rolls off on its own above about 6 kHz; anything above that is amp fizz, cymbal spill or DI buzz rather than guitar.")` — **PR** · S7 · quote: `For example, most guitar amp cabinets don't produce a great deal of sound above 6kHz or so.` (90) **[straight apostrophe. ⚠ SHIP THIS FULL FORM. A round-2 fetch asked for this sentence "from its FIRST character" and returned it WITHOUT `For example, `; a follow-up asking for the first five words proved the page reads `For example, most guitar`. The shortened form would still have been a valid substring here (lowercase `most`), but it is not what the page's sentence is — §1.2 note 3.]**
- **bands** (3) — **PR**; each bullet is its own line under S6's **Electric Guitar** heading

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `mud` | 150 | 300 | "Thickness that turns into fog when several guitars are layered." | S6 · `Muddy at 150 to 300 Hz.` (23) |
| `presence` | 800 | 3000 | "The bite that lets a guitar be heard next to a vocal." | S6 · `Biting at 800Hz to 3kHz.` (24) |
| `harshness` | 5000 | 10000 | "Fizz from the amp's distortion — the region that makes long listens tiring." | S6 · `Fizzy at 5 to 10 kHz.` (21) |

- **Validators**: V1 ✅ · V2a `80 ≤ 82.407 × 1.259921 = 103.828` ✅ (**tightest pass in the table**, margin 23.8 Hz) · V2b `80 ≥ 20.602` ✅ · V3 `80 ≤ min(800) = 800` ✅ **and** corner LP `6000 ≥ max(3000) = 3000` ✅ · V4 `80 ∈ 20…1000`, `6000 ∈ 1000…20000`, slopes 24/12 ✅ · V5 ✅
- **Rationale arithmetic** (n = 4): fc 150 Hz on 82.407 Hz → **−20.9 dB**.
- **The only row with a corner low-pass** — the one instrument where a source states an instrument-level top-end limit inside `EQParams.lowPassFreqRange`.

---

### 3.10 `acousticGuitar`

- **displayName**: `"Acoustic guitar"`
- **fundamental**: `.pitched(lowestMIDINote: 40, highestMIDINote: 76)` → 82.407 Hz (E2) … 659.255 Hz (E5)
- **fundamentalCitation** — **grade P2\*** · Z3 · quote: `Depending on the tuning, the low E string of an acoustic guitar sounds at around 82 hz, while the 12th fret of the high E string plays around 659 Hz.` (147) — names the instrument **and** states both endpoints; self-verifying against the arithmetic (§3.9). **No §1.4 exception needed on this row.**
- **HP**: `.corner(hz: 70, slopeDbPerOct: 12, rationale: "The low E fundamental sits at 82 Hz; what lies beneath it on a close-miked acoustic is foot-tap, mic-stand and handling noise. 70 Hz clears that without touching the string. Keep the slope gentle: the same source that gives this fundamental explicitly warns against reflexively filtering an acoustic guitar, because room information and low body are part of the sound.")` — **PR**, instrument-named ✅
  - S7 · quote: `The fundamental frequency of the lowest note played on the acoustic guitar might be 80Hz or so, whereas most of the sound picked up from the foot-taps will be at lower frequencies.` (180) **[the checker reported `foot-taps` as an ASCII hyphen here while reporting U+2011 elsewhere on the same publisher — §1.2 note 2 applies; a class mismatch is not grounds to delete]**
  - **Scope, flagged not hidden**: the quote states the *placement rationale* (fundamental ~80 Hz, noise below it), not the literal 70. The corner is this row's engineering choice inside that statement, bounded by V2a at 103.83 Hz.
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "The source that measured this instrument found useful content well above 10 kHz and argued explicitly against low-passing it; string detail is what an acoustic guitar contributes to a mix.")`
- **bands** (4) — **PR**, under S6's **Acoustic Guitar** heading

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `mud` | 80 | 150 | "Boom from the body cavity — pleasant alone, cloudy in a full mix." | S6 · `Boomy at 80 to 150 Hz.` (22) |
| `boxiness` | 150 | 300 | "The hollow, boxed-in tone of a close mic pointed at the soundhole." | S6 · `Boxy at 150 to 300 Hz.` (22) — ⚠ this exact string ALSO appears under S6's **Drums** heading; a checker must read the heading. |
| `presence` | 2500 | 4000 | "Where the pick and the string meet — the guitar's front edge." | S6 · `Presence at 2.5 to 4 kHz.` (25) |
| `air` | 8000 | 20000 | "String shimmer and room detail — openness rather than brightness." | S6 · `Airy above 8 kHz.` (17) — upper edge is V5's audible ceiling, not a cited number. |

- **Validators**: V1 ✅ · V2a `70 ≤ 103.828` ✅ · V2b `70 ≥ 20.602` ✅ · V3 `70 ≤ min(2500, 8000) = 2500` ✅ · V4 ✅ · **V5 `20000 ≤ 20000` ✅ — EQUALITY, §1.3 note 7; a strict `<` fails this row**

---

### 3.11 `piano` — ⚠ `FILTER-WEAK`

> **What's weak:** the required HP corner is the only field in the table sourced from a tier-C publisher with no corroboration. The fundamental is P2 and the four bands are from a mainstream vendor blog. **All six quotes on this row are verbatim-confirmed** (round 2, §8) — the flag is about publisher tier, not verification.

- **displayName**: `"Acoustic piano"`
- **fundamental**: `.pitched(lowestMIDINote: 21, highestMIDINote: 108)` → 27.500 Hz (A0) … 4186.009 Hz (C8)
- **fundamentalCitation** — **grade P2** ✅ · W4 · quote: `Most modern pianos have 52 white keys and 36 black keys, for a total of 88 keys (seven octaves plus a minor third, from A0 to C8).` (129) **[confirmed: `A0` and `C8` carry NO markup — safe for a mechanical match, unlike the guitar-tunings sentence]**
  - **Corroboration (not shipped, PR)**: E1 states `To give you some perspective, the piano's frequency range extends from 27.5 Hz to 4186 Hz.` — exactly the derived A0/C8 values.
  - **Scope note for GM program 2** (see §5 and §7.0 X7): this compass is an 88-key acoustic grand's. It is also applied to "Electric Grand Piano", whose real instruments are shorter — tolerated deliberately, and the reasoning is in §5.
- **HP**: `.corner(hz: 30, slopeDbPerOct: 12, rationale: "The bottom key of an 88-note piano sounds at 27.5 Hz, so the room to work in is tiny: any corner above 34.6 Hz starts eating the instrument's own lowest note. 30 Hz removes pedal thump, floor rumble and HVAC without touching A0. Every other piano high-pass number this pass found in the wild (60, 70, 80 Hz) would cost A0 at least 14 dB, and up to 37 dB at the steeper slope.")` — **PR (tier C)** ⚠
  - C1s · quote: `Very gentle high-pass at 30–40Hz (rumble only), minimal cutting.` (63) **[U+2013 in `30–40` — explicitly confirmed as an en dash]**
  - **The number chosen is the BOTTOM of the cited range on purpose**: `40 Hz` — the top of the same range — **fails V2a** (`40 > 27.5 × 1.259921 = 34.648`). The table's clearest worked example of V2a operating *inside* a single citation.
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "A piano's harmonics run to the top of the audible band and are most of what makes it read as a piano rather than an electric keyboard.")`
- **bands** (4) — **PR**, all naming the piano inside the quote ✅

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `body` | 75 | 250 | "Depth and richness — the wood and the soundboard." | E1 · `With warmth, the goal here is to add a little extra depth and richness to the piano recording, which usually lies between 75Hz and 250Hz.` (135) |
| `boxiness` | 350 | 400 | "The boxed-in honk of a lid-down or close-miked piano." | E1 · `When mixing piano, this boxy frequency range usually sits around 350Hz to 400Hz.` (79) |
| `presence` | 3000 | 4000 | "Cut-through for a lead piano line without making it brittle." | E1 · `However, if you want your piano to cut through the mix, especially for leads, I usually reach for a little boost between 3-4kHz.` (126) **[the leading `However,` IS on the page and IS capitalised — separately confirmed by a first-five-words check; see §1.2 note 3]** |
| `air` | 9000 | 11000 | "Hammer and damper detail — the transient sparkle that reads as a real instrument." | E1 · `These sounds typically sit in the 9-11kHz range, and they're crucial if you want your piano to punch through the mix.` (117) |

- **Validators**: V1 ✅ · V2a `30 ≤ 27.5 × 1.259921 = 34.648` ✅ (**tightest ratio in the table**, 1.0909×) · V2b `30 ≥ 6.875` ✅ · V3 `30 ≤ min(75, 3000, 9000) = 75` ✅ · V4 ✅ · V5 ✅
- **Rationale arithmetic** on A0 = 27.5 Hz: fc 60 Hz → **−13.7 dB (n=2)** / **−27.1 dB (n=4)**; fc 80 Hz → **−18.6 dB (n=2)** / **−37.1 dB (n=4)**.

---

### 3.12 `maleVocal`

- **displayName**: `"Male voice"`
- **fundamental**: `.pitched(lowestMIDINote: 41, highestMIDINote: 67)` → 87.307 Hz (F2) … 391.995 Hz (G4)
- **fundamentalCitation** — **grade P1** ✅ (UNSW Music Acoustics — the coordinator's named model source) · U1 · url `https://newt.phys.unsw.edu.au/jw/voice.html`
  - quote: `Men's singing voice ranges are typically about an octave lower than women's (conservatively, about F2 to G4 and F3 to G5, respectively).` (134) — **one sentence states BOTH vocal rows' endpoints**; Hz derived, not quoted.
- **HP**: `.corner(hz: 80, slopeDbPerOct: 24, rationale: "Deliberately the LOW end of the published 50-100 Hz window, because the conservative male floor F2 sounds at 87.3 Hz: a 100 Hz corner would cost that note about 6 dB, and a bass singer below F2 more. 80 Hz still removes proximity-effect boom, plosive thump and stand rumble. Steep slope, because everything under the corner on a vocal track is noise.")` — **PR** · Z1 · quote: `remove everything from anywhere between 50–100 Hz and below` (59) **[U+2013 in `50–100`; the ASCII-hyphen form of this string returned NO on re-check — one of the two quotes in this table CORRECTED by verification]**
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "Vocal intelligibility and air live at the top; any corner low enough to matter would dull the voice. Use a de-esser for sibilance instead.")`
- **bands** (4) — **PR**

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `rumble` | 20 | 80 | "Room rumble, handling noise and mic bleed — none of it is the singer." | Z1 · `What lives below 80 Hz in a vocal recording is most often low frequency room rumble, microphone handling noise, microphone bleed from unintended sources, or inherent equipment noise.` (182) **[R3-confirmed: first five words are `What lives below 80` — sentence-initial, no dropped clause. Second-longest quote in the table.]** |
| `body` | 100 | 400 | "The main body and warmth — where the voice's own fundamentals sit." | Z1 · `The fundamental frequencies of a vocal are typically found between 100 and 400 Hz.` (81) |
| `mud` | 300 | 400 | "Where the voice piles up with guitars and keys and everything gets muddy." | S8 · `One common problem is excess energy around 300-400 Hz. Because many instruments produce energy in this range, the sounds can 'pile up' and sound muddy.` (151) **[straight quotes around `pile up`, confirmed]** |
| `presence` | 2500 | 4500 | "Upper mids — the difference between a vocal that sits back and one that fronts the track." | S8 · `If the vocal still sits too far back in a busy track, focus on the upper mids, using a parametric EQ boost, typically in the 2.5-4.5 kHz range.` (141) |

- **Validators**: V1 ✅ · V2a `80 ≤ 87.307 × 1.259921 = 109.994` ✅ · V2b `80 ≥ 21.827` ✅ · V3 `80 ≤ min(100, 2500) = 100` ✅ (`rumble` is not desirable, so it does not enter V3) · V4 ✅ · V5 ✅
- **Rationale arithmetic** (n = 4): fc 100 Hz on 87.307 Hz → **−5.98 dB**.
- S8 states it is written about the **male voice** — confirmed on the live page: `For the male voice (which is primarily what I work with)`. That is why its two quotes are on this row and not the female one.
- **Fundamental-vs-body note** (the same disclosure as §3.13, milder here): the `body` band's citation puts vocal fundamentals at 100–400 Hz while this row's `fundamental` is 87.3–392.0 Hz. They roughly agree; the 13 Hz gap at the bottom is the difference between a generic figure and UNSW's conservative male floor. No action needed.

---

### 3.13 `femaleVocal`

- **displayName**: `"Female voice"`
- **fundamental**: `.pitched(lowestMIDINote: 53, highestMIDINote: 79)` → 174.614 Hz (F3) … 783.991 Hz (G5)
- **fundamentalCitation** — **grade P1** ✅ · U1 · quote: `Men's singing voice ranges are typically about an octave lower than women's (conservatively, about F2 to G4 and F3 to G5, respectively).` (134)

  > ⚠ **DISCLOSURE — this row carries two cited, incompatible statements about the same quantity, and that is deliberate.**
  >
  > The `fundamental` field says the female singing range is **F3–G5 (174.6–784.0 Hz)**, from UNSW (P1, female-specific). The `body` band below cites iZotope: `The fundamental frequencies of a vocal are typically found between 100 and 400 Hz.` — whose **lower edge sits 75 Hz BELOW this row's own fundamental floor**.
  >
  > They are not reconcilable as stated, and I did not force them to be. The iZotope figure is **generic-vocal** — one number covering male and female singers together — so its bottom edge is really the male floor. UNSW's is **female-specific and conservative**. Both are correctly transcribed from their sources.
  >
  > **The band is deliberately left extending below the row's fundamental floor**, because `body` describes *where the engineer works*, not where the voice's fundamentals lie, and the cited source puts vocal body there. **V3 is unaffected** (it constrains the HP corner against the band's low edge, and 100 ≤ 100 holds). **An implementer must NOT "fix" this by raising the band to 174 Hz** — that number would be uncited, and the resulting advice would be wrong for a low female voice whose chest register genuinely reaches under the conservative floor.
  >
  > On `maleVocal` the same two claims roughly agree (87.3 vs 100 Hz), so this is a female-row issue only.

- **HP**: `.corner(hz: 100, slopeDbPerOct: 24, rationale: "The TOP of the same published 50-100 Hz window the male row takes the bottom of — the conservative female floor sits an octave above the male one (174.6 Hz), so 100 Hz is pure cleanup with 74 Hz of margin. This is the design's own worked example of a legitimate dense-mix vocal corner.")` — **PR**, instrument-named by heading ✅ · S6 (Vocals section) · quote: `Most voices have little below 100Hz so use low cut to remove unwanted bass frequencies.` (86)
- **LP**: `.noneRecommended(reason: .notRecommendedForThisSource, explanation: "Air and intelligibility live at the top of a vocal; a corner low enough to matter would dull the voice. Use a de-esser for sibilance instead.")`
- **bands** (4) — **PR**

| role | lowHz | highHz | effect | citation |
|---|---|---|---|---|
| `body` | 100 | 400 | "The main body and warmth — where the voice's own fundamentals sit." | Z1 · `The fundamental frequencies of a vocal are typically found between 100 and 400 Hz.` (81) — see the disclosure above |
| `boxiness` | 800 | 1500 | "Nasal, honky quality — the 'talking through a tube' region." | S6 (Vocals) · `Nasal at 800Hz to 1.5kHz.` (25) |
| `presence` | 2000 | 4000 | "Penetration — where the voice cuts through a dense arrangement." | S6 (Vocals) · `Penetrating at 2 to 4 kHz.` (26) |
| `air` | 7000 | 12000 | "Openness and breath — the sheen that makes a vocal sound expensive." | S6 (Vocals) · `Airy at 7 to 12 kHz.` (20) |

- **Validators**: V1 ✅ · V2a `100 ≤ 174.614 × 1.259921 = 220.000` ✅ · V2b `100 ≥ 43.654` ✅ · **V3 `100 ≤ min(100, 2000, 7000) = 100` ✅ — EQUALITY, §1.3 note 7** · V4 ✅ · V5 ✅

---

## 4. Per-family grade summary (coordinator's requested report)

| Family | Fundamental grade | Filter/band grade | Flag |
|---|---|---|---|
| `kick` | **PR** | PR | ⚠ **ADMISSION-DOUBTFUL** |
| `snare` | **PR** | PR | ⚠ **ADMISSION-DOUBTFUL** |
| `tom` | **PR** | PR | ⚠ **ADMISSION-DOUBTFUL** |
| `hiHat` | **P2** | PR (instrument-named) | — |
| `rideCymbal` | **P2** | PR (tier C, class-level HP) | ⚠ **FILTER-WEAK** |
| `crashCymbal` | **P2** | PR (tier C, class-level HP) | ⚠ **FILTER-WEAK** |
| `electricBass` | **P2** | PR (instrument-named) | — |
| `uprightBass` | **P2** | PR (one band article-level) | — |
| `electricGuitar` | **P2\*** | PR (instrument-named) | — (§1.4 exception, stated in §3.9) |
| `acousticGuitar` | **P2\*** | PR (instrument-named) | — |
| `piano` | **P2** | PR (tier C HP) | ⚠ **FILTER-WEAK** |
| `maleVocal` | **P1** | PR (instrument-named) | — |
| `femaleVocal` | **P1** | PR (instrument-named) | — (fundamental/body disclosure in §3.13) |

**10 of 13 fundamentals are P1/P2/P2\*.** The three that are not are the three the coordinator predicted: kick, snare and tom, where "fundamental" is a tuning choice.

---

## 5. `melodicProgramFamilies` — the explicit 128-entry mapping

**Narrowed from the design's sketch (§2 line 134). Never widened.** 18 non-nil, 110 nil.

| Programs | Family | GM name(s) | `category(forProgram:)` |
|---|---|---|---|
| 0, 1, 2, 3 | `.piano` | Acoustic Grand / Bright Acoustic / Electric Grand / Honky-tonk | "Piano" |
| 24, 25 | `.acousticGuitar` | Acoustic Guitar (nylon), (steel) | "Guitar" |
| 26, 27, 28, 29, 30 | `.electricGuitar` | Electric Guitar (jazz), (clean), (muted), Overdriven, Distortion | "Guitar" |
| 32 | `.uprightBass` | Acoustic Bass | "Bass" |
| 33, 34, 35, 36, 37 | `.electricBass` | Electric Bass (finger), (pick), Fretless, Slap Bass 1, Slap Bass 2 | "Bass" |
| 43 | `.uprightBass` | Contrabass | "Strings" |
| **all others** | **`nil`** | — | — |

> **Why program 2 ("Electric Grand Piano") maps to `.piano` while programs 4/5 ("Electric Piano 1/2") map to `nil` — stated because §7.0 X7's deletion reasoning otherwise looks self-contradictory.**
>
> An **electric grand** (Yamaha CP-70/80 and its GM descendants) is a real strung, hammered piano with a pickup — **the same sound-production mechanism as an acoustic piano**, so `.piano`'s bands and its high-pass reasoning transfer. A **Rhodes** (struck tines) and a **Wurlitzer** (struck reeds) do not have strings at all; that is why `electricPiano` was deleted rather than folded into `.piano`.
>
> **The honest cost, stated not hidden**: an electric grand is typically 73 keys, so the A0–C8 compass this row ships **overstates its bottom end**. It is tolerated because the consequence is bounded — **V2a still passes comfortably** against a real CP-70's low E1 (41.2 Hz → bound 51.9 Hz, versus the shipped 30 Hz corner), so the advice remains safe. If a reviewer prefers strictness, **narrow `2 → nil` and the non-nil count becomes 17**, which the implementer pins.

**Changed vs the design's sketch** (all narrowings, each forced by a §7.0 deletion):

| Program(s) | Sketch | Ship | Why |
|---|---|---|---|
| 4, 5 | `electricPiano` | `nil` | `electricPiano` deleted |
| 40 | `violin` | `nil` | `violin` deleted |
| 41 | `viola` | `nil` | `viola` deleted |
| 42 | `cello` | `nil` | `cello` deleted |
| 56, 59 | `trumpet` | `nil` | `trumpet` deleted |
| 57 | `trombone` | `nil` | `trombone` deleted |
| 73 | `flute` | `nil` | `flute` deleted |

**Complete allowed-GM-category sets for C9's consistency sweep** (the design says "and so on"; here is the whole thing, so nothing is invented):

```
piano           → { "Piano" }
acousticGuitar  → { "Guitar" }
electricGuitar  → { "Guitar" }
electricBass    → { "Bass" }
uprightBass     → { "Bass", "Strings" }        // 32 → Bass, 43 → Strings
kick, snare, hiHat, tom, rideCymbal, crashCymbal, maleVocal, femaleVocal → { }   // EMPTY
```

⚠ **The sweep must tolerate an EMPTY allowed set** — eight of thirteen families are reachable only by percussion note or by the `family` argument. A sweep asserting "every family has ≥ 1 allowed category" would fail on a correct table.

**C9's pins**: `33 → electricBass` ✅, `43 → uprightBass` ✅, **`40 → nil`** (was `violin`), `48 → nil` ✅, `96 → nil` ✅.

---

## 6. GM percussion note map (unchanged — all 6 percussion families survived)

**17 notes. S8's literal stays 17.**

| Family | Notes | GM Level 1 spec names to ship |
|---|---|---|
| `kick` | 35, 36 | 35 "Acoustic Bass Drum", 36 "Bass Drum 1" |
| `snare` | 38, 40 | 38 "Acoustic Snare", 40 "Electric Snare" |
| `hiHat` | 42, 44, 46 | 42 "Closed Hi Hat", 44 "Pedal Hi-Hat", 46 "Open Hi-Hat" |
| `tom` | 41, 43, 45, 47, 48, 50 | 41 "Low Floor Tom", 43 "High Floor Tom", 45 "Low Tom", 47 "Low-Mid Tom", 48 "Hi-Mid Tom", 50 "High Tom" |
| `rideCymbal` | 51, 59 | 51 "Ride Cymbal 1", 59 "Ride Cymbal 2" |
| `crashCymbal` | 49, 57 | 49 "Crash Cymbal 1", 57 "Crash Cymbal 2" |

Everything else → `.unresolved(.percussionNoteNotCoveredInV1)` and **ships no name** (design §4). Explicitly uncovered: 37 side stick, 39 hand clap, 52 china, 53 ride bell, 54 tambourine, 55 splash, 56 cowbell. **C10's pins hold as written.**

---

## 7. DELETIONS AND FINDINGS

### 7.0 The seven deletions

Per §7 rule 3: **the case is DELETED, its GM entries become `nil`, and nothing is guessed.**

| # | Deleted family | Killed by | Detail |
|---|---|---|---|
| X1 | **`cello`** | **V2a** | The only fetchable low-cut guidance reaching a cello is section-level ("Orchestral Strings: possible low end to be cut: below 100 Hz"). Open C2 = **65.406 Hz** → V2a bound **82.41 Hz**. A 100 Hz corner fails by 21%. No cello-specific corner exists in any source I could fetch; a lower one would be invented. → deleted. GM 42 → nil. |
| X2 | **`trombone`** | **V2a** | Same shape. Only brass guidance is section-level ("Orchestral Brass: … below 150 Hz"). Tenor trombone low E2 = **82.407 Hz** → bound **103.83 Hz**. 150 Hz fails by 45%. → deleted. GM 57 → nil. |
| X3 | **`trumpet`** | **quote↔field correspondence** | Wikipedia states the range as a **written** pitch: "Using standard technique, the lowest note is the written F♯ below middle C." On a B♭ trumpet that **sounds E3**, so the MIDI field (52) would not match the number in its own quote (F♯3 = 54). `lowest` is the V2a input; a transposition step between quote and field is exactly the mismatch the spot-check exists to catch. → deleted. GM 56, 59 → nil. **Contrast this with `electricGuitar`'s retained name mismatch — the distinction is stated in §3.9 and it is the difference between a wrong NUMBER and a wrong LABEL on an invariant property.** |
| X4 | **`flute`** | **no citable EQ guidance at all** | UNSW's flute-acoustics page discusses C4/B3 fingerings but states no consolidated range, and **no** fetchable source states a flute-specific high-pass corner or flute-specific bands. `recommendedHighPass` is REQUIRED; the row cannot ship. → deleted. GM 73 → nil. |
| X5 | **`violin`** | **citation scope (§1.4)** | Fundamental cleanly citable (Wikipedia: "The lowest note of a violin, tuned normally, is G3, or G below middle C (C4)."). But **every** actionable field would come from ensemble-level "Orchestral Strings" bullets that never name the violin — and those bullets live on the iZotope *EQ Cheat Sheet*, which the fetcher **refuses to reproduce**, so they are unverifiable at spot-check too. → deleted. GM 40 → nil. |
| X6 | **`viola`** | same as X5 | Fundamental cleanly citable (Wikipedia: "The strings from low to high are typically tuned to C3, G3, D4, and A4."). Actionable fields would be byte-identical to violin's and ensemble-sourced — §2 rule 2 ("merging would change the advice") is not satisfied for the fields that matter. → deleted. GM 41 → nil. |
| X7 | **`electricPiano`** | **searched, nothing found** | No fetchable source states a Rhodes/Wurlitzer fundamental range **or** electric-piano-specific EQ guidance. Every hit generalised from acoustic piano, whose A0–C8 compass is wrong for a 73-key Rhodes. → deleted. GM 4, 5 → nil. **This reasoning does NOT extend to GM 2 "Electric Grand Piano", which stays `.piano`: an electric grand is a strung, hammered piano and a Rhodes/Wurlitzer is not. Full argument and its honest cost in §5.** |

**Reason class:** X1, X2, X3, X5, X6 = **searched, sources found, rejected by a stated rule**. X4, X7 = **searched, no source found**. **None** were "did not reach it in budget."

**Downstream:** `allCases.count` **20 → 13** (C1's literal) · `melodicProgramFamilies` non-nil **27 → 18** (nil 101 → 110, count still 128) · **`coveredNotes` UNCHANGED at 17** · the entire orchestral group is absent from v1, so an agent with a violin track gets `.unresolved(.gmProgramNotCoveredInV1)` plus remedy and the family index — the honest-nil path D2 was built for · wire/MCP/catalog counts unaffected.

### 7.1 The three `ADMISSION-DOUBTFUL` rows, and the source that would fix them

`kick`, `snare` and `tom` are `.pitched` because the design mandates it (§1 F3: *"Kick, snare and toms do have a published tuning range and stay `.pitched`"*) and because **V2a's protection depends on it** — an `.inharmonic` kick would have no `lowestHz`, so nothing would stop a future edit shipping the folklore 80 Hz corner. But a drum's fundamental is a **tuning choice**, and the shipped ranges rest on a PRACTICE source.

**I found the right source and could not lift it.** Overtone Labs (manufacturer of the tune-bot drum tuner) publishes a *Drum-Set Tuning Guide* stating drum **fundamental notes** alongside lug frequencies — manufacturer spec data, i.e. **P1**:

- `https://tune-bot.com/tuning-guide/` renders tables implying bass-drum fundamentals of **C1 (32.7 Hz, 24")** and **F1 (43.7 Hz, 20")**, a 14-inch snare at **G3/A3 (196/220 Hz)**, and toms from **73.4 Hz (D2, 16")** to **147 Hz (D3, 10")**.
- Two blockers: (a) the numbers live in **table cells** and I could not extract a contiguous verbatim sentence a mechanical string search would find; (b) the canonical PDF (`https://tune-bot.com/tunebottuningguide.pdf`) returns **unreadable binary through the fetcher**, so a citation to it would fail the spot-check by construction.
- It also **disagrees** with the shipped PR source on the kick: C1 = 32.7 Hz vs "as low as 50 Hz". Reconciling that is real work, not transcription.
- **A third hazard, if a future pass retries this**: the guide states **lug frequencies** and **fundamental notes** in adjacent columns. Lifting a lug frequency as a fundamental would be worse than the current PR citation — it would be a confidently-cited wrong number. Any retry must show, inside the quoted span, which quantity it is quoting.

**Recommendation**: keep the three rows with the flag (they are the highest-value rows in the table) and file a follow-up. **If the parent prefers the harder bar, deleting all three drops `allCases` 13 → 10 and `coveredNotes` 17 → 7 (only 42, 44, 46, 49, 51, 57, 59 survive), and S8's literal must move.**

### 7.2 The three `FILTER-WEAK` rows

`piano`, `rideCymbal`, `crashCymbal` — their **required** HP corner is the only field in the table from a tier-C publisher (and for the cymbals, class-level rather than instrument-named). Everything else on those rows is stronger.

**All quotes on all three rows are verbatim-confirmed against the live page** (round 2, §8). The flag records **publisher tier**, which no amount of verification changes. A reviewer rejecting these rows should reject them on the tier argument, not on citation integrity.

### 7.3 Where sources CONTRADICT each other, and how I chose

| # | Conflict | Resolution |
|---|---|---|
| C-1 | **Acoustic guitar HP.** SOS: the lowest fundamental is ~80 Hz and foot-taps are *below* it. iZotope, same instrument: *"Does this mean you should high-pass around 80 and low-pass above 1 kHz? Absolutely not!"* | Both are right about different things — SOS removes non-instrument noise below the fundamental; iZotope argues against filtering *at* it and against low-passing at all. Shipped **HP 70** and **`.noneRecommended` LP**, satisfying both. The iZotope objection is quoted in the LP explanation. |
| C-2 | **Kick HP: 30–40 Hz (SOS) vs 50 Hz (iDrumTune) vs "70–80 Hz" (widespread).** | Shipped **35**. The 50 Hz figure comes from the same page that says the kick's fundamental can be *as low as 50 Hz* — a corner sitting exactly on the instrument's lowest fundamental (V2a permits it; it costs 3 dB for no benefit). 70–80 Hz is folklore V2a rejects outright. |
| C-3 | **Piano HP: 30–40 vs 60–80 vs 70 Hz** — and **the 70 Hz recommendation is on the very page that states the piano's range begins at 27.5 Hz.** | Shipped **30**. V2a's bound is 34.65, so **only the 30–40 source survives, and only at its lower end**. The best illustration that a recommendation can contradict physics stated three paragraphs above it, and only arithmetic catches it. |
| C-4 | **Hi-hat HP: 150 vs ~300 vs 200–400 vs 500 Hz.** | Shipped **300 / 12 dB per octave**. Two independent sources converge on 200–400; 300 is inside both and equals the bottom edge of the hat's own cited body region, so V3 holds with zero margin — hence the gentle slope. |
| C-5 | **Bass HP slope: source says "12 or 18 dB per octave"; our EQ offers 12 or 24.** | Shipped **12** — the option the quote names that we can execute. Recorded in the rationale so nobody "upgrades" it to 24 and breaks quote↔field correspondence. |
| C-6 | **Drum fundamentals: iDrumTune (kick 50–90 Hz) vs Overtone Labs (kick C1 = 32.7 Hz).** | **Unresolved, and reported rather than papered over** (§7.1). Shipped the quotable PR source and flagged the row. |
| C-7 | **Female vocal fundamental: UNSW F3–G5 (174.6–784 Hz) vs iZotope "100 and 400 Hz" for vocal fundamentals generally.** | **Both shipped, on the same row, with the incompatibility disclosed in §3.13 rather than averaged away.** The `fundamental` takes the female-specific P1 figure; the `body` band keeps the generic PR figure and its sub-floor lower edge, because `body` is where the engineer works, not where the fundamentals are. **Do not reconcile these by editing a number** — one of them would then be uncited. |

### 7.4 Places the design's own sketch turned out wrong or uncitable

| # | Design says | Reality |
|---|---|---|
| A | §2 line 134: `4–5 → electricPiano`, `40 → violin`, `41 → viola`, `42 → cello`, `56/59 → trumpet`, `57 → trombone`, `73 → flute` | **All become `nil`** (§7.0). A narrowing, which §2 permits. |
| B | §1 F3: kick/snare/tom "have a published tuning range and stay `.pitched`" | **Half-right.** They stay `.pitched`, but "published" turned out to mean *a mixing blog*, not a spec — hence three `ADMISSION-DOUBTFUL` flags. A reasonable premise that did not survive the source hunt. |
| C | §4: "if it finds three genuinely different tuning ranges with citations, `tom` splits into three cases" | **It did not.** `tom` stays one family; the note map is unchanged. |
| D | §7: "For each of the 20 families…" | **13.** |
| E | §2's category sweep, sketched with "and so on" | **Incomplete for a table where 8 of 13 families have no melodic program.** Complete set in §5, including the requirement that an **empty** allowed set be legal — left as-is, an implementer would plausibly write a sweep that fails on a correct table. |
| F | §5 response example: `electricBass` `lowestMidiNote: 28, highestMidiNote: 67` | `28` ✅. **`67` does not ship** — Wikipedia's *Bass guitar* article states **no fret count**, so `highest` is the open G string, **43**, which the New Grove tuning quote states directly. The design labelled that block "SHAPE ONLY", so this is not an error — but an implementer copying the example would ship an uncited number. |
| G | §7 rule 2: *"`url` … must RESOLVE to a page that STATES the claim"* | **Resolving is not sufficient.** Four sources resolve but cannot be quote-checked: **Sweetwater** 403s the fetcher; the **iZotope EQ Cheat Sheet** fetches but the fetcher **refuses to reproduce it** on copyright grounds; **HyperPhysics** 502s; the **tune-bot PDF** returns unreadable binary. Wikipedia's *Guitar tunings* resolves and states the claim, but the note names carry bold/link markup that breaks a mechanical match. **A source is citable only if the fetcher will reproduce a contiguous span of it.** This single fact removed the last citable numbers for `violin`/`viola` (X5/X6) and blocked the drum upgrade (§7.1). |
| H | §7 rule 1 assumes a quote can be checked by asking whether the string appears | **It cannot — and asking for the sentence "from its first character" is ALSO not enough.** The fetcher dropped a leading clause **twice, on two different publishers**: E1's `However,` and S7's `For example,`. The second was dropped *despite* the explicit first-character instruction. Consequences differ and cannot be predicted: trimming `However,` yields `If you want…`, which is **invalid** (the page's `if` is lowercase); trimming `For example,` yields `most guitar…`, which is **still valid**. **The only reliable check is "state the exact first five words of that sentence."** Both quotes now ship in full. Two other round-2 checks were run fully **un-primed** (I supplied a deliberately wrong string and asked for the page's own frequency sentences) and the pages returned this table's shipped wording independently — the strongest form of confirmation available here. |
| I | §7's spot-check is specified per ROW ("5 rows including kick…") | **Per-row and per-source sampling both under-cover, because one page can carry quotes for several rows.** An earlier draft of this document ticked D1 as "verified" on the strength of one `kick` quote while **four `snare`/`tom` quotes on the same page were unchecked** — including two of the three `ADMISSION-DOUBTFUL` fundamentals. **Track verification per QUOTE STRING.** Round 3 exists solely because of this. |

### 7.5 The folklore this table refuses, stated so it is not re-added

| Folklore | V2a verdict | Row |
|---|---|---|
| "High-pass everything at 80 Hz" | Kick: `80 > 61.74` **FAILS** (kick loses ~17 dB of its own fundamental) | `kick` ships 35 |
| "High-pass everything at 100 Hz" | Electric bass `100 > 51.91` **FAILS**; upright bass **FAILS**; piano **FAILS** | 30 / 35 / 30 |
| "High-pass guitars at 150 Hz" | Electric guitar `150 > 103.83` **FAILS** (open low E loses ~21 dB) | `electricGuitar` ships 80 |
| "Cut strings below 100 Hz" (ensemble advice) | Violin ✅ / viola ✅ / **cello `100 > 82.41` FAILS** | cello deleted |
| "Cut brass below 150 Hz" (ensemble advice) | Trumpet ✅ / **trombone `150 > 103.83` FAILS** | trombone deleted |
| "High-pass piano at 60–80 Hz" | `> 34.65` **FAILS by a factor of 2** against A0 | `piano` ships 30 |

**Every one of these is a real published recommendation.** Four of six would have shipped if the table had been written from the same sources without V2a.

---

## 8. Quote verification (design §7 gate step, performed during this pass)

Design requires **5 rows including `kick`, `electricBass`, and one `.inharmonic` row**. **I ran three rounds and finished at 100% AT THE QUOTE LEVEL** — every distinct quote string shipped in §3 was reproduced from the live page. 22 verification fetches. **Two quotes were CORRECTED as a result** (Z1's en dash; S7's leading `For example,`), which is the point of the exercise.

### Round 1 — 11 quote groups across 6 rows (includes all three mandatory rows)

| # | Row | Quote checked | URL | Verdict |
|---|---|---|---|---|
| 1 | **`kick`** ★ | fundamental (`…as low as 50 Hz and as high at 80 or 90 Hz…`) | idrumtune.com | ✅ **PASS** — reproduced verbatim including the "as high at" wording |
| 2 | **`kick`** ★ | HP (`Applying a low‑cut (high‑pass) filter to anything below 30-40Hz…`) | soundonsound.com/…/mix-tips-kick-bass | ✅ **PASS** — checker flagged non-ASCII hyphens, which is why §1.2 note 2 exists |
| 3 | **`kick`** ★ | 2 bands (`…boost in the 70-90Hz region`; `…150-200Hz region … sound boxy`) | soundonsound.com/…/tricks-make-your-drums-sparkle | ✅ **PASS** (both) |
| 4 | **`electricBass`** ★ | HP (`So slope it off with a 30Hz high‑pass filter (HPF) at 12 or 18 dB per octave.`) | soundonsound.com/…/mixing-di-bass-guitar | ✅ **PASS** — page also returned the preceding sentence, confirming context |
| 5 | **`electricBass`** ★ | fundamental (`Electric bass guitar, usually with four heavy strings tuned E1'–A1'–D2–G2.`) | en.wikipedia.org/wiki/Bass_guitar | ✅ **PASS** — reproduced identically on two independent fetches, primes and en dashes intact |
| 6 | **`electricBass`** ★ | 2 bands (`…40-80Hz region…`; `…3-6kHz presence/harshness band`) | soundonsound.com/techniques/mixing-bass | ✅ **PASS** (both) |
| 7 | **`hiHat`** ★ (inharmonic) | fundamental (`The majority of cymbals are of indefinite pitch…`) | en.wikipedia.org/wiki/Cymbal | ✅ **PASS** |
| 8 | **`hiHat`** ★ (inharmonic) | HP (`Set the cutoff frequency just below the point…between 200 and 400Hz.`) | production-expert.com | ✅ **PASS** — in the article's "Filtering And EQ" section |
| 9 | **`crashCymbal`** | band (`harshness can be reduced by cutting in the 3-6kHz region…`) | soundonsound.com/…/tricks-make-your-drums-sparkle | ✅ **PASS** |
| 10 | **`maleVocal` / `femaleVocal`** | fundamental (`Men's singing voice ranges are typically about an octave lower than women's…F2 to G4 and F3 to G5…`) | newt.phys.unsw.edu.au/jw/voice.html | ✅ **PASS** |
| 11 | **`maleVocal` / `femaleVocal`** | HP + body (`remove everything from anywhere between 50–100 Hz and below`; `The fundamental frequencies of a vocal…100 and 400 Hz.`) | izotope.com/en/learn/how-to-eq-vocals | ⚠ **PASS WITH CORRECTION** — the **ASCII-hyphen** form of quote 1 returned **NO**; the page uses **U+2013**. The shipped quote was corrected to the en-dash form. Quote 2 passed as-is. |

### Round 2 — the remaining 13 sources, 8 further rows

Run because round 1's coverage was thinnest **exactly on the rows this document tells the reviewer to sample first** (§7.2). Method changed per §7.4 H.

| Source | Quotes | Rows | Verdict |
|---|---|---|---|
| S6 | **12** | `electricGuitar` (HP + 3 bands), `acousticGuitar` (4 bands), `femaleVocal` (HP + 3 bands) | ✅ **12/12 PASS**, all exact |
| S5 | 4 | `snare` (body, attack), `tom` (body, attack) | ✅ **PASS, UN-PRIMED** — I supplied a deliberately wrong string and asked for the page's own snare/tom frequency sentences; it returned this table's shipped wording independently |
| E2 | 3 | `tom` (HP, mud, boxiness) | ✅ **PASS, UN-PRIMED** — same method; the page returned `Start with a gentle high-pass filter, rolling off everything below 40–60 Hz` unprompted |
| E1 | 4 | `piano` (4 bands) | ✅ **PASS** + a first-five-words check confirming the leading `However,` (§7.4 H) |
| C1s | 1 | `piano` HP — **the single weakest field in the table** | ✅ **PASS**, en dash explicitly confirmed |
| C2s | 2 | `rideCymbal` HP, `crashCymbal` HP | ✅ **PASS**, straight apostrophes confirmed |
| M1 | 3 | `hiHat` (2 bands), `rideCymbal` (2 bands), `crashCymbal` (2 bands) | ✅ **PASS**, including the page's own "any where" misspelling |
| S7 | 3 | `uprightBass` presence, `electricGuitar` LP, `acousticGuitar` HP | ⚠ **PASS WITH CORRECTION** — the LP quote came back missing its leading `For example, ` even though I asked for the first character; a first-five-words follow-up proved the page reads `For example, most guitar`. **Shipped quote corrected to the full form.** Other two exact. |
| S2 | 1 | `uprightBass` HP (the 35 Hz quote) | ✅ **PASS**, ASCII hyphen confirmed |
| S8 | 2 + scope | `maleVocal` (mud, presence) | ✅ **PASS**, straight quotes; male-voice scope confirmed on the page |
| Z2 | 1 | `hiHat` harshness | ✅ **PASS**, en dash confirmed |
| Z3 | 1 | `electricGuitar` + `acousticGuitar` fundamental | ✅ **PASS**, lowercase `hz` confirmed as the page's own |
| W3 | 1 | `uprightBass` fundamental | ✅ **PASS**, ≈ confirmed |
| W4 | 1 | `piano` fundamental | ✅ **PASS**, and `A0`/`C8` confirmed to carry **no markup** |
| U2 | 2 | the arithmetic anchor (§1.1) | ✅ **PASS** (both) |

### Round 3 — the per-quote sweep that per-source ticking had hidden (§7.4 I)

Rounds 1–2 tracked sources. Two pages ship more quotes than were checked: **D1 (5 quotes, 1 checked)** and **Z1 (3 quotes, 2 checked)**. Four of the five gaps were on `snare` and `tom` — **two of the three `ADMISSION-DOUBTFUL` rows a reviewer samples first**. All five were checked with the first-five-words method.

| Source | Quote | Row · field | Verdict |
|---|---|---|---|
| D1 | `A standard 14 inch snare drum…tiger up at 200 Hz too.` | `snare` fundamental | ✅ **PASS** — first words `A standard 14 inch`; both page typos intact |
| D1 | `if our snare is tuned to 200 Hz…say 100 Hz` | `snare` HP | ✅ **PASS** — the sentence's own first words are `if our snare is`; **the lowercase `if` is the page's**, not a truncation |
| D1 | `by applying some attenuation at the snare drum's edge overtone frequency…300-350 Hz` | `snare` boxiness | ✅ **PASS** — confirmed a contiguous mid-sentence substring; full sentence begins `We can manipulate this with EQ therefore…` |
| D1 | `For example, a 16 inch floor tom…80 Hz or at 120 Hz.` | `tom` fundamental | ✅ **PASS** — first words `For example, a 16`; **the leading clause survived**, unlike S7's |
| Z1 | `What lives below 80 Hz in a vocal recording…inherent equipment noise.` | `maleVocal` rumble | ✅ **PASS** — first words `What lives below 80` |

### What to do if the close-out check disagrees with a quote

**Distinguish three failures — they have different remedies:**

1. **Words or numbers differ** → the citation does not support the field. **Delete the field** (and if it is the required HP, delete the row). This is the `trumpet` failure mode.
2. **Only a hyphen/dash/apostrophe CLASS differs** → a rendering artifact of the fetch pipeline, not a content error. **Correct the character from the live page and keep the field.** §1.2 note 2 documents why: this pass observed the checker report different hyphen classes for the same construction on the same publisher.
3. **The check returns the sentence MISSING its leading clause** → **do not conclude the quote is wrong.** Re-ask for *the exact first five words*. This pass saw the fetcher silently drop `However,` and `For example,` from two different publishers' sentences (§7.4 H). Both shipped quotes are correct as printed.

**Do not reword a quote to make it match.** That is the one repair that destroys the property the rule exists to protect.

---

## 9. Actionable takeaways

### ROADMAP
1. **`(m23-o1)` ships 13 families, not 20.** Update the item line and record the 7 deletions so a future cycle does not "restore" them from the design sketch without doing the citation work. Adding a family later is additive and needs no wire change (design §11). **⚠ A Step-1 agent building `InstrumentFamily` from the design will write 20 cases — reconcile to 13 before the gate runs, not at it.**
2. **File: "lift the Overtone Labs drum tuning table" (§7.1).** It is the P1 source that clears the `ADMISSION-DOUBTFUL` flag on `kick`/`snare`/`tom`. Acceptance criteria: a contiguous quotable span; a reconciliation of the kick disagreement (C1 = 32.7 Hz vs 50 Hz); and **proof inside the quoted span that the number is a fundamental, not a lug frequency** — the guide prints both in adjacent columns.
3. **File: "orchestral + electric-piano families".** The blocker is source availability, not effort — note that Sweetwater 403s and the iZotope cheat sheet cannot be reproduced.
4. **`m23-o2` (pixels) is unaffected in shape** but must be told that an EQ card for a violin/cello/flute/E-piano track resolves `.unresolved`. The honest-nil path is now the **common** case for melodic tracks, not the edge — design it first, not last.

### ARCHITECTURE / design doc
5. **C1's literal → 13.** The design already anticipated this ("that is the pin working, not a break").
6. **Amend §2's category sweep** with §5's complete table **including the empty-set case** — as sketched, a correct sweep implementation would fail on a correct table.
7. **State that V3 and V5 are NON-STRICT** (§1.3 note 7). Four shipped fields sit at exact equality and a `<` implementation rejects all four. Also note `rideCymbal` sits exactly at V8's 3-source floor.
8. **Add a fifth rule to §7**: *a source is citable only if the fetcher will reproduce a contiguous span of it* (§7.4 G).
9. **Add a sixth rule to §7**: *verify a quote by asking for the exact first five words of its sentence.* Neither "does this string appear" nor "reproduce it from its first character" is sufficient — both returned sentences missing a leading clause during this pass, on two different publishers (§7.4 H).
10. **Add a seventh rule to §7**: *track verification per QUOTE STRING, not per row and not per source* (§7.4 I). Per-source ticking hid four unverified quotes on two flagged rows inside this very document until round 3.
11. **Record the grading scheme (§1.1) in the design**: fundamental = P1/P2 required; bands and filters = PR by construction, defended by V2a/V2b/V3 rather than by authority. **Include the W1 rationale** — an encyclopedic statement of a physical property is P2 even with no range to derive, or three inharmonic rows lose their grade.
12. **Record the §1.4 exception explicitly** (§3.9): the scope rule blocks EQ guidance crossing instrument names, but **not** tuning claims, because tuning is a property of the strings and not the body. Without this the `electricGuitar` row and the deleted `trumpet` row look inconsistent.
13. **Record the GM-2 electric-grand decision** (§5): mechanism, not marketing name, decides family membership — a strung hammered piano is `.piano`, a tine/reed instrument is not. The alternative (`2 → nil`, non-nil 17) is one line away if a reviewer prefers strictness.
14. **`recommendedLowPass` is `.noneRecommended` on 12 of 13 rows** — only `electricGuitar` ships a corner (6 kHz). If m23-o2 plans UI showing an LP suggestion per instrument, expect nothing to show.
15. **`.belowHouseEQRange` is used by NO shipped row.** Every honest "no" here is `.notRecommendedForThisSource`. Keep the case, but **do not let a test require it to be exercised.**
16. **Record the `uprightBass`/`electricBass` rule-2 tension** (§3.8) as a v2 decision: identical fundamentals, corners 1/6 of an octave apart. Merging is a *design* call because it would widen a GM mapping, which a research pass is forbidden to do.
17. **`femaleVocal` ships two incompatible cited claims about vocal fundamentals, on purpose** (§3.13, C-7). Put the disclosure in the design so a later cleanup pass does not "fix" the band to 174 Hz and thereby ship an uncited number.

### Gate
18. **S8's `17` covered notes is unchanged** — do not "fix" it downward. It changes only if the parent acts on §7.1 (→ 7) or §3.5 (→ 13).
19. **S3/B1 with the shipped `electricBass` row**: corner 30 Hz at 12 dB/oct costs **0.67 dB** at band 0's observation window (≈46.9 Hz @ 48 kHz) — inside the 6 dB bar with 5+ dB margin. This also **confirms §8.2's decision to fix S4 at 100 Hz / 24 dB/oct**: `2 × hp = 60 Hz` at 12 dB/oct costs only **5.7 dB** at the window, under the 6 dB bar, so a computed `2 × hp` control leg would have failed while S3 was green.
20. **A gate that re-checks quotes must implement §8's three-remedy rule** (content mismatch → delete; character-class mismatch → correct the character; missing leading clause → re-ask for the first five words). A gate that deletes on any mismatch will delete correct rows, because neither the fetch pipeline's hyphen normalisation nor its sentence-boundary handling is stable across calls.
