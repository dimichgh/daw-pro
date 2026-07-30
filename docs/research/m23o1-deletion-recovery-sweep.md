# m23-o1 — P1 recovery sweep over the seven deleted families

**2026-07-28 · research-analyst · addendum to `m23o1-frequency-reference-table.md` §7.0.**
Commissioned to test one specific worry: that "UNSW publishes no cymbal page" had been over-generalised into "UNSW has nothing", causing orchestral families to be deleted when a P1 source existed.

> **VERDICT: the worry was HALF RIGHT, and the outcome does not change. All seven stay deleted. `allCases` stays 13, `coveredNotes` stays 17, the summary table in the main document is UNCHANGED and remains the authority.**
>
> UNSW **does** have flute, brass and violin pages I had not fully mined, and this sweep **recovered two genuine P1 facts** I did not previously have. But recovering a fundamental never mattered, because **the binding blocker on every one of the seven is the REQUIRED `recommendedHighPass` field** — and that was confirmed absent at primary sources today.

---

## 1. The structural finding that decides all seven

**`recommendedHighPass` is a required field. A family cannot ship without it. No reproducible source states an instrument-specific high-pass corner for ANY of the seven deleted families.** Two primary-source confirmations, both obtained today:

| Confirmed today | Consequence |
|---|---|
| **UNSW's flute and brass pages give NO EQ or high-pass recommendation.** Asked directly, both answered no. (The flute page *does* use the phrase "high pass filter" — but as a description of what an open tone-hole array physically does, not as a mixing recommendation. A token search would produce a false positive here.) | UNSW can supply *physics*, never a *corner*. It can never, by itself, make one of these rows shippable. |
| **S6 (Sound On Sound, "Mixing EQ Cookbook") — my one fully-reproducible practice source — has exactly FIVE headings: Vocals, Electric Guitar, Bass Guitar, Acoustic Guitar, Drums.** No strings, brass, woodwind or piano section exists. | The 13 shipped families are, almost exactly, *the set of instruments the reproducible practice literature covers*. That is not a coincidence and it is the real shape of this dataset. |

The only source that *does* carry orchestral EQ guidance is the **iZotope EQ Cheat Sheet**, and its bullets are ensemble-level ("Orchestral Strings", "Orchestral Brass") **and** the fetcher refuses to reproduce the page on copyright grounds — so they fail §1.4 (scope) and §7.4 G (reproducibility) independently.

---

## 2. Per-family result

| # | Family | Result | Why |
|---|---|---|---|
| X1 | `cello` | **STAYS DELETED** | **UNSW has no cello page** (site map checked directly: no cello, no viola, no piano, no cymbals). Original V2a failure stands and is arithmetic, not sourcing: open C2 = **65.406 Hz** → bound **82.41 Hz**; the only guidance reaching a cello is the 100 Hz ensemble bullet, which fails by 21%. A P1 fundamental would have *reinforced* this rejection, not lifted it. |
| X2 | `trombone` | **STAYS DELETED** | UNSW's brass page yields a clean P1 sentence — `The lowest normal note for this position is Bb2 at about 116 Hz – the second peak on the graph.` (first five words `The lowest normal note`, confirmed). **But it says "for this position"** — first position. A tenor trombone reaches **E2 in 7th position**, so shipping Bb2 as `lowest` would state a floor the instrument goes below. **That is the exact error class that killed `trumpet`**, and it would make V2a *more permissive than reality* — the dangerous direction. The 150 Hz ensemble number fails V2a under **both** readings (bound 103.83 from E2; 146.83 from Bb2). And UNSW gives no corner. |
| X3 | `trumpet` | **STAYS DELETED** | The brass page very likely **does** state sounding pitch (`written C4 = sounding Bb3`), which is precisely what my original deletion reason needed. **But two fetches would not reproduce that sentence consistently** — the second returned different, garbled candidate sentences and could not confirm it. Under §7.4 G (*a source is citable only if the fetcher will reproduce a contiguous span of it*) it is not citable today. **Even if it were, there is no trumpet HP corner anywhere reproducible.** This is the closest of the seven to recoverable, and the fundamental is the *easier* half. |
| X4 | `flute` | **STAYS DELETED** | **Reason CONFIRMED at the primary source**, which is the strongest possible outcome for a deletion. My original blocker was "no citable HP corner, and HP is required"; UNSW's flute page — the most detailed flute-acoustics page on the web — **explicitly gives no EQ or high-pass recommendation**, and S6 has no woodwind section. **Genuine gain: the low end is now P1-citable** — `B3 is the lowest note on the flute, so there are no open tone holes and therefore no cut-off frequency.` (first five words `B3 is the lowest note`). ⚠ **Single fetch, NOT double-confirmed** — the fetcher first offered a pronoun fragment ("The latter is…") before producing this form, so it needs a first-five-words re-check before anyone ships it. No highest note is stated anywhere on the page, so `highest` would still be uncited (§1.3 rule 8 forbids inventing it). |
| X5 | `violin` | **STAYS DELETED** | **The premise did not survive contact.** UNSW's `violintro.html` was fetched and asked directly for open-string tuning or frequencies: **it states NO string tuning and no frequencies** — it mentions "the E to A to D to G strings" only to discuss string thickness, with no pitches. So there is no P1 tuning-derivation route at UNSW for the violin, despite the violin pages existing. The fundamental was never the problem anyway (Wikipedia's `The lowest note of a violin, tuned normally, is G3…` is cleanly P2). **The problem is the HP corner**, and S6's cookbook has no strings section. |
| X6 | `viola` | **STAYS DELETED** | **UNSW has no viola page at all** (site map). Identical HP blocker to violin. |
| X7 | `electricPiano` | **STAYS DELETED** | One attempt made, as instructed. A 73-key **E1–E7** compass surfaced for the *Vintage Vibe Marquis 73*. Rejected on three counts: it is a **different instrument** from a Fender Rhodes (whose compass this row would need); it appeared on a **product/retail listing**, not a manufacturer spec *table*, and retail listings are excluded outright; and the HP blocker is unchanged — no electric-piano EQ section exists in any reproducible source. |

**Score: 0 recovered, 7 confirmed deleted. Two new P1 facts banked (flute B3; trombone Bb2/116 Hz), neither sufficient to ship its row.**

---

## 3. What changed in my understanding (worth carrying forward)

1. **I had over-generalised, but not in the way that mattered.** "UNSW has no cymbal page" was true; extending a *pessimism* about UNSW to the orchestral families was sloppy, and this sweep found real UNSW content for flute, brass and violin that I had not fully mined. **But the deletions were never resting on that pessimism** — they rest on the missing HP corner, which this sweep confirmed at the primary source rather than overturned.
2. **The reason to re-check was sound even though nothing changed.** Confirming X4's blocker directly at UNSW is worth more than the original inference; and the `trombone` result surfaced a *new trap* — a P1 sentence that would have shipped a wrong `lowest` if taken at face value, because "for this position" is easy to skim past.
3. **A "physics-grade" source and a "shippable row" are different things.** UNSW gives fundamentals and never corners. The design's data shape requires both. **A family is shippable only where the acoustics literature and the mixing literature overlap** — and that overlap is currently 13 instruments wide.

---

## 4. Actionable takeaways

1. **No change to the main table.** `allCases` **13**, `coveredNotes` **17**, 7 deletions, `melodicProgramFamilies` 18 non-nil. C1's and S8's literals are unaffected. The summary table in `m23o1-frequency-reference-table.md` remains the authority.
2. **Amend the roadmap follow-up "orchestral + electric-piano families"** with what this sweep established, so a future cycle does not re-run it blind: *the fundamentals are largely obtainable (UNSW brass/flute, Wikipedia for strings); the blocker is a per-instrument high-pass corner, which neither UNSW nor Sound On Sound's cookbook supplies.* The acceptance criterion for that item should be **"find a reproducible source of per-instrument HP corners for orchestral instruments"**, not "find physics sources".
3. **`trumpet` is the best single candidate for recovery** — its fundamental is probably one successful extraction away. It still needs an HP corner.
4. **Add to the design's §7 rules**: *when a quoted range is qualified by a playing condition ("for this position", "in first position", "on a C foot instrument"), it is not the instrument's range.* The trombone Bb2 case is a live example that would have shipped a floor the instrument plays below.
5. **Do not let a future pass token-search UNSW's flute page for "high pass"** — the phrase is present as a description of tone-hole physics, and would produce a false positive for a mixing recommendation. (This is the project's standing *a token search finds the token, not the behaviour* law, appearing in a research context.)
