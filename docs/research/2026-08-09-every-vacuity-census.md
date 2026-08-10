# The `every()`-vacuity census (m23-ee-1)

**Measured 2026-08-09.** Instrument: `scripts/every-vacuity-census.mjs` (acorn AST, not grep).
Reproduce: `ACORN_DIR=<dir-with-acorn> node scripts/every-vacuity-census.mjs`.

> ## ⚠️ STATUS — the per-site table below is the ee-1 SNAPSHOT and is now PARTLY SUPERSEDED
>
> **Re-measured 2026-08-09 at the m23-ee-2b close: 130 sites, 16 not-cleared, 15 actionable.**
> Six of the original 22 at-risk sites are FIXED and now report cleared:
> `m20d:272`, `m20e:1257`, `m23bp:852` (ee-2a) and `m17b:140`, `m23a2:366`, `m23k4a:183` (ee-2b).
> Line numbers in the table below are **pre-fix**; the fixes added explanatory comments and
> shifted them. The remaining 15 are carried as **m23-ee-2c**, grouped there by fix shape
> (empty-literal accumulators / `.filter()` results / awaited values / helper-returned).
>
> **Do not read a count off this table — re-run the instrument and read its `notCleared` field.**
> - ⭐ **The tool now reports the count itself** (added at the ee-2b close). Consumers were
>   filtering `rows` by hand, and a consumer that guesses the field name wrong gets a confident
>   **`0`** — a filter that never matched, indistinguishable from a clean corpus. That happened:
>   a query for `r.atRisk` (there is no such field; it is `r.cleared`) printed
>   `"AT-RISK TOTAL: 0"` when the true answer was **16**. The instrument knows its own schema,
>   so the instrument counts.
> - ⚠️ If you do filter by hand, the predicate is **`r.cleared === false`**, and check
>   **`parseFails.length === 0`** in the same breath — a sibling field rendering blank is exactly
>   the tell that your field names are wrong.
> - ⚠️ **`notCleared` is not the ACTIONABLE count.** A receiver that is a helper *parameter* is an
>   interprocedural question and clears by inspection, not by this tool. Actionable =
>   `notCleared` − those. Reconcile from two directions before recording it.
>
> `m23do:163` counts as not-cleared but is **not** actionable — its receiver is a helper
> **parameter**, cleared by inspection. That is why 16 not-cleared is 15 actionable, and it
> reconciles from both directions: 22 − 6 = 16, and 21 − 6 = 15.

## The axis

`[].every(fn)` returns **`true`**. An assertion of the form `ck("… in EVERY sample", coll.every(…))`
over a runtime-derived collection therefore passes **vacuously** when that collection is empty —
the gate goes green having measured nothing. m23-bj found the first instance (`m23c2` L1/L2) and
fixed it; this is the sweep of the rest.

⚠️ **Polarity is half the axis.** On an empty collection `[].every(f)` is `true` but `[].some(f)`
is `false`, so the danger is not "uses `.every`/`.some`" — it is whether the empty-value equals the
value the assertion *wants*:

| shape | value on `[]` | verdict |
|---|---|---|
| `every(…)` | `true` | ⚠️ vacuous pass |
| `!every(…)` | `false` | ✅ self-defending — reddens |
| `some(…)` | `false` | ✅ self-defending — reddens |
| `!some(…)` | `true` | ⚠️ vacuous pass |

A positive `.some()` is its own emptiness guard. Counting all sites as one population overstates
the problem by about a third.

## Grep vs parser, reconciled exactly

A raw text grep finds **133** occurrences; the parser finds **130** code sites. The gap is **exactly 3**, all in
`m23c2`: two on `:370` (``// m23-bj: EVERY leg below is an `s.every(…)`, and `[].every(fn)` is `true`.``) and one
on `:443`. ⭐ **The prose contaminating the grep is m23-bj's own comment documenting the fix** — i.e. the
better a defect is documented in-line, the more the naive grep over-counts. Reconciled per-file; no file has a
grep hit the parser missed.

⚠️ Note `grep -c` counts **lines**, not occurrences (it reads 125 here because six lines carry two sites each).
Use `grep -o | wc -l` when the number is meant to be an occurrence count.

## Scope, re-derived

The filed scope (115 occurrences / 39 gates / 67 non-harness) had **rotted** — the corpus has grown.
Measured now: **71 non-harness gates**, and a raw text grep finds 133 occurrences across 42 files.
That grep counts **comment prose**, which is why this uses a parser: the real figure is
**130 code sites across 42 gates**, 0 parse failures.

## Result

**130 sites → 108 cleared by the scanner, 22 flagged; 1 cleared by inspection at ee-1 → 21 ACTIONABLE candidates across 16 gates.**

### Cleared, by reason

| clearing reason | sites |
|---|---|
| inline .length conjunct | 37 |
| literal receiver | 30 |
| polarity (some is false on empty — reddens instead) | 21 |
| leading count-pin leg | 18 |
| inline .length conjunct (via source `busSeen`) | 2 |

`.filter(…).length === 0` — the extension the item suggested — has **zero** instances in the corpus.

### At-risk: the 22 candidates

⚠️ **These are CANDIDATES, not confirmed defects.** Each needs the same question m23-bj asked of
`m23c2`: *can this collection actually be empty on a run that should otherwise pass?* A candidate
whose collection is non-empty by construction is a false positive; the fix cycle clears it with a
reason, not a re-grep.

| gate | line | shape | receiver | why it is a candidate |
|---|---|---|---|---|
| `m17b-arrange-zoom` | 125 | `every` | `r.result?.undo ?? []` | receiver is an expression: r.result?.undo ?? [] |
| `m20d-project-rate` | 262 | `every` | `devicesOf(r)` | ArrowFunctionExpression: r => r.result?.devices ?? [] |
| `m20e-flip-path` | 1251 | `every` | `devicesOf(r)` | ArrowFunctionExpression: r => r.result?.devices ?? [] |
| `m23a2-insert-slot-reserve` | 360 | `every` | `(floor.mixerFader ?? []).slice(0, 3)` | receiver is an expression: (floor.mixerFader ?? []).slice(0, 3) |
| `m23ag-explain-capture-origin` | 474 | `every` | `results` | empty-literal accumulator, fill NOT provably fixed-bound |
| `m23ak-note-selection-drop` | 305 | `every` | `after` | awaited: await starts([a0, a1, a2]) |
| `m23ak-note-selection-drop` | 553 | `every` | `afterL5` | awaited: await starts(L5.clips) |
| `m23al-editor-surface` | 517 | `every` | `onTrue` | call: iRows.filter(...) |
| `m23al-editor-surface` | 518 | `every` | `onFalse` | call: iRows.filter(...) |
| `m23am-refusal-anchor` | 257 | `every` | `aIDs` | empty-literal accumulator, fill NOT provably fixed-bound |
| `m23bp-held-note` | 846 | `every` | `devicesOf(r)` | ArrowFunctionExpression: r => r.result?.devices ?? [] |
| `m23do-menubar` | 163 | `every` | `needle` | `needle` not declared in-file (param/import) |
| `m23e-empty-lane-create` | 212 | `!some` | `clipsOf(ov, instId)` | ArrowFunctionExpression: (ov, trackId) => (ov.tracks.find((t) => t.id === trackId)?.c |
| `m23f-arrange-drop` | 359 | `every` | `checks` | empty-literal accumulator, fill NOT provably fixed-bound |
| `m23g1-arrange-multiselect` | 306 | `every` | `clips` | empty-literal accumulator, fill NOT provably fixed-bound |
| `m23g1-arrange-multiselect` | 392 | `every` | `restored` | call: tracks.map(...) |
| `m23g1-arrange-multiselect` | 411 | `every` | `clips` | empty-literal accumulator, fill NOT provably fixed-bound |
| `m23k4a-midi-export` | 176 | `every` | `snap.tracks ?? []` | receiver is an expression: snap.tracks ?? [] |
| `m23k4b-midi-drop` | 226 | `every` | `inst4` | call: ov.tracks.filter(...) |
| `m23m3c-stems-dialog` | 147 | `!some` | `st.plannedFiles` | awaited: await cmd(ws, "debug.exportDialog", { open: true }) |
| `m23m3c-stems-dialog` | 197 | `!some` | `onDisk` | call: listing(...) |
| `m23v-empty-lane-hint` | 363 | `every` | `hintsOf(e)` | ArrowFunctionExpression: (e) => e.emptyLaneHints ?? [] |

### Progress

- **m23-ee-2a (2026-08-09): the three `devicesOf` sites are FIXED** — `m20d:262`, `m20e:1251`, `m23bp:846`.
  Re-running the census confirms all three now clear via the inline `.length` conjunct. **22 flagged → 19;
  21 actionable → 18.** Refresh this table by re-running the scanner rather than editing it by hand.

### Already cleared by inspection (do not re-litigate in ee-2)

- **`m23do:163`** — `needle.every(…)` inside the helper `hasConsecutiveRun(haystack, needle)`. The scanner
  reports it UNKNOWN, not RUNTIME: `needle` is a **function parameter**, so its provenance does not live at
  the declaration at all — it lives at the call sites. There is exactly one caller (`:257`) and it passes
  `importExportBlock`, a 4-element array literal. Not reachable-empty. **FALSE POSITIVE.**
  ⚠️ The general rule: a helper parameter's emptiness is an INTERPROCEDURAL question, and lumping
  "unresolvable" in with "runtime-derived" is the same population-mixing that polarity already corrected once.

### The shape worth reading first

Six of the 22 build their collection with `?? []` (`r.result?.undo ?? []`, `snap.tracks ?? []`,
`(floor.mixerFader ?? []).slice(…)`, and the three `devicesOf(r)` helpers). That idiom does not
merely *permit* an empty array — it **manufactures one** the moment the field is absent or renamed.
A wire rename would turn the leg green rather than red, which is the exact inversion this axis is about.

## The fix shape (settled at m23-bj; copy, do not re-derive)

A leading count-pin leg in the same block:

```js
check("L1 samples: the run produced enough frames to mean anything",
      s.length >= 5, `${s.length} samples`);
check("L1 arrange: the playhead is in frame in EVERY sample",
      s.every((x) => lineX(x.aRuler) != null), …);
```

The corpus also uses an inline conjunct — `bundlePaths.length > 0 && bundlePaths.every(…)`. Both
are recognised by the census; either is acceptable.

## What licensed this instrument

Four known answers, all reproduced before any new result was believed:

1. **pre-fix `m23c2`** (`65fa395`, the defect m23-bj found) → flagged at-risk ✓
2. **post-fix `m23c2`** (current tree) → cleared by its leading count pin ✓
3. **`m23ay:353`, `m23p2:102`** (the documented inline-guard idiom) → cleared ✓
4. **`m23s`** (recorded CLEAN by m23-bj) → agrees, 0 at-risk ✓

Each control failure taught the instrument something it was missing, and every one of them would
have produced a confidently wrong census:

- **(2) failed first** — the scanner knew only the inline conjunct, so it re-flagged all four legs
  m23-bj had already fixed. There are **two** clearing idioms, not one.
- **(4) failed next, twice** — `m23s`'s accumulators are filled by a `for (let n = 1; n <= 4; n++)`
  loop with unconditional pushes (fixed-bound: always 4 elements), and its `ints`/`steps` are guarded
  by `busSeen.length >= 2` — **a guard on the SOURCE collection**, not the receiver. Without those two
  rules the census would have "found" 8 defects in a gate that has none.

⚠️ **And a bug the controls caught that no test would have:** inserting a block between
`else if (decl)` and its `else` silently re-bound the `else`, so every successfully-resolved receiver
was overwritten with "not declared in-file" and counted at-risk. It surfaced only because the at-risk
count **rose** (32 → 37) immediately after two *clearing* rules were added — an impossible direction.
A dangling `else` does not fail; it just makes everything look at-risk.
