# The `every()`-vacuity census — method and findings

**Method snapshot dated 2026-08-09.** Instrument: `scripts/every-vacuity-census.mjs` (acorn AST, not grep).

**To get current figures:** `node scripts/every-vacuity-census.mjs --json`, then read the `notCleared` field.

⚠️ **That bare form works only once `acorn`/`acorn-walk` exist at `scripts/node_modules/`, which is
GITIGNORED and NOT tracked** — so it is present on a machine where someone installed it and ABSENT on a
fresh clone. Deliberately so: acorn is not a repo dependency (see the script's own header). **If it is
missing, use the OUT-OF-TREE recipe the script's header already documents** — install to a scratch dir and
pass an ABSOLUTE `ACORN_DIR` — rather than adding packages under `scripts/`. The default lookup is
otherwise CWD-INDEPENDENT: verified by running the bare command from an unrelated working directory.

> ⛔ **`ACORN_DIR` IS A TRAP FOR RELATIVE PATHS — MEASURED 2026-08-11 at the m23-gq close, because the
> line that used to sit here (`ACORN_DIR=<dir-with-acorn> node …`) DID NOT RUN.** The variable is
> consumed as ``await import(`${ACORN_DIR}/acorn/dist/acorn.mjs`)``, and a dynamic import with a
> relative specifier resolves **against the importing module's own URL — `scripts/` — not your shell's
> cwd.** So `ACORN_DIR=./scripts/node_modules` from the repo root becomes `scripts/scripts/node_modules`
> and dies with `ERR_MODULE_NOT_FOUND`. **Only set `ACORN_DIR` when acorn is genuinely out of tree, and
> then give it an ABSOLUTE path** (verified working). ⭐ This is why a documented command has to be RUN
> and not merely read: the old line looked more careful than the bare one, and was the broken one.

> ⚠️ **Why this document does not cite counts:**
>
> The per-site coordinate table that originally lived at lines 95–118 contained line numbers like
> `m23ak:305` and `m23ak:553`. Those coordinates drifted during subsequent fixes (now at 313 and 561).
> A stale pair was copied into `scripts/every-vacuity-census.mjs`'s header comment, where it persisted
> until roadmap item m23-gp re-measured those lines and found unrelated code. **This incident proves that
> a snapshot's numbers can rot faster than its method.** This document carries METHOD and REASONING;
> the instrument reports its own numbers on demand and will not grow stale.

> ## Triage: `notCleared` is not actionable
>
> ⭐ **The tool now reports the count itself** (`notCleared` field). Consumers were
> deriving counts by hand, and a consumer that guesses the field name wrong gets a confident
> **`0`** — a filter that never matched, indistinguishable from a clean corpus.
> - ⚠️ **`notCleared` is not the ACTIONABLE count.** A receiver that is a helper *parameter* is an
>   interprocedural question and clears by inspection, not by this tool. Actionable =
>   `notCleared` − those.
> - ⚠️ If you do filter by hand, the predicate is **`r.cleared === false`**, and check
>   **`parseFails.length === 0`** in the same breath — a sibling field rendering blank is the
>   tell that your field names are wrong.

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

A positive `.some()` is its own emptiness guard. **So treating every `.every`/`.some` occurrence as one at-risk population OVERSTATES the problem** — the self-defending polarities have to come out first, and they are a large fraction of the total. (The original snapshot put that fraction at about a third; the number is not reproduced here because only the instrument can tell you today's.)

## Grep vs parser, reconciled exactly

⚠️ **There are TWO distinct gaps here and merging them loses both.**

**Gap 1 — grep occurrences vs parser code sites.** A raw text grep finds MORE occurrences than the parser
finds code sites, and at the ee-1 measurement the difference was accounted for exactly, per-file, with every
excess hit landing in **comment prose**. ⭐ **The prose contaminating the grep is the fix's own comment
documenting the defect** — i.e. the better a defect is documented in-line, the more the naive grep
over-counts. No file had a grep hit the parser missed, and that per-file reconciliation is the check worth
repeating, not the difference it produced.

**Gap 2 — lines vs occurrences.** ⚠️ `grep -c` counts **LINES**, not occurrences, and it under-reads
whenever a single line carries more than one site (several do). Use `grep -o | wc -l` when the number is
meant to be an occurrence count.

## At-risk candidates: what makes a site flagged

⚠️ **Flagged sites are CANDIDATES, not confirmed defects.** Each needs the same question m23-bj asked of
`m23c2`: *can this collection actually be empty on a run that should otherwise pass?* A candidate
whose collection is non-empty by construction is a false positive; the fix cycle clears it by adding a
guard rule or count-pin.

The candidate patterns include:
- Receivers built with `?? []` (literal fallback to empty)
- Receivers returned by a locally-declared arrow-function helper whose own body can yield `[]`
  — e.g. `devicesOf(r)` where `const devicesOf = (r) => r.result?.devices ?? []`. ⚠️ It is the
  RECEIVER's provenance that matters, never the callback passed to `.every()`/`.some()` — every
  such call has a callback, so that could not distinguish anything.
- Accumulators initialised to `[]` and filled where the bound is not provably fixed
- `.filter(…)` results, whose size is runtime-derived by definition
- Awaited values, where the collection arrives from the wire

## Already cleared by inspection

- **Helper-parameter receivers** — When the receiver is a function **parameter**, its emptiness is an
  **INTERPROCEDURAL question** and cannot be resolved at the declaration site. The scanner reports such
  sites as UNKNOWN, and the question can only be settled by READING EVERY CALL SITE. In the ee-1 case
  there was exactly one caller and it passed a fixed-size array literal, so that site was a false
  positive. ⛔ **DO NOT generalise that into "a flagged helper parameter is a false positive" — it is
  a false positive only once its call sites have actually been read, and a helper with a caller that
  can pass an empty collection is a REAL find.** The durable rule is narrower: lumping "unresolvable"
  in with "runtime-derived" is the same population-mixing that polarity already corrected once, so
  these sites belong in their own bucket — not cleared, not counted as actionable.

## The shape worth reading first

Several flagged sites build their collection with `?? []` (e.g. `r.result?.undo ?? []`, `snap.tracks ?? []`,
`(floor.mixerFader ?? []).slice(…)`). That idiom does not merely *permit* an empty array — it
**manufactures one** the moment the field is absent or renamed. A wire rename would turn the leg green
rather than red, which is the exact inversion this axis is about.

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
