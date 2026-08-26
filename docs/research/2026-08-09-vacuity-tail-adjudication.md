# Adjudicating the 15 "actionable" vacuity sites — 12 are FALSE POSITIVES

**Measured 2026-08-09** during m23-ee-2c-1, by READING every site rather than trusting the census.
Companion to `2026-08-09-every-vacuity-census.md` (the instrument's own output, which this
document corrects).

> ## The headline
>
> Of the **15 sites** the census called actionable, **12 are already defended** and need no gate
> edit at all. Roughly **2–3** are real, and two of those sit on a *different axis* than the one
> the item was chasing.
>
> **The census's false-positive rate here is ~80 %, and that is a fact about the SCANNER, not
> about the gates.** Every defence it missed is real, deliberate, and in several cases documented
> in prose by the gate's own author.

## The general law

**A census that can only see ONE SCOPE will systematically flag well-defended code**, because the
defence usually lives in the fixture, one leg up, or one function over. Its false-positive rate
is a function of how *well* the corpus is written — which inverts the usual reading that a noisy
scanner means sloppy code. **When a scanner's hit list is dominated by careful gates, suspect the
scanner.**

## Two strengths of "defended" — do not conflate them

- **STRENGTH A — "cannot be empty."** Length fixed at authoring time by an unconditional fill over
  a literal bound. The vacuous case is **unreachable**.
- **STRENGTH B — "pinned-visible."** The receiver *can* be empty and the flagged leg really would
  pass vacuously — but a sibling leg pins the collection, so that leg goes **red in the same run**
  and the emptiness cannot be *overlooked*.

**Verified, not assumed:** `check()` in every gate examined does `checks.push({name, ok, detail})`
and returns — no `throw`, no `process.exit` — so execution genuinely continues past a failed pin.
That is what makes strength B "impossible to overlook" rather than "impossible".

⭐ **A corollary the census does not model: for strength B the pin may FOLLOW the site.** The
verdict is the whole fail-list, not the execution order, so a later pin is just as visible.
`m23e:212` is defended this way.

## The adjudication

| # | site | receiver | verdict | why |
|---|---|---|---|---|
| 1 | `m23al:517` | `onTrue` | **FP** (B) | `I0` at `:501` asserts `iRows.some(P)`, same predicate |
| 2 | `m23al:518` | `onFalse` | **FP** (B) | same, `sawFalse` |
| 3 | `m23ak:305` | `after` | **FP** (A) | `starts(ids)` = `ids.map(…)`; arg is the literal `[a0,a1,a2]` |
| 4 | `m23ak:553` | `afterL5` | **FP** (A) | same helper over `L5.clips`; `fixture()` fills 3 unconditionally |
| 5 | `m23g1:306` | `clips` | **FP** (A) | `for (const t of tracks)`, unconditional |
| 6 | `m23g1:392` | `restored` | **FP** (A) | `tracks.map(…)`; `tracks` from `for (const n of ["G1a","G1b","G1c"])` |
| 7 | `m23g1:411` | `clips` | **FP** (A) | as #5 |
| 8 | `m23am:257` | `aIDs` | **FP** (A) | `for (let i = 0; i < N_A; i++)` with `const N_A = 8` |
| 9 | `m23v:363` | `hintsOf(e)` | **FP** (B) | `E4` at `:360` pins `…join() === "0,3"` — satisfiable only by 2 elements |
| 10 | `m23e:212` | `clipsOf(…)` | **FP** (B) | `:215` asserts `ov.tracks.some(t => t.id === instId)` — a **following** pin |
| 11 | `m23m3c:147` | `st.plannedFiles` | **FP** (B) | `:145` asserts `eq(st.plannedFiles, STEMS)` — deep-equality to a fixed list |
| 12 | `m23m3c:197` | `onDisk` | **FP** (B) | `:193` asserts `eq(onDisk, [...promised].sort())` |
| 13 | `m23k4b:226` | `inst4` | **REAL** | `ov.tracks.filter(t => t.kind === "instrument")`, nothing pins it non-empty |
| 14 | `m23ag:474` | `results` | **DIFFERENT AXIS** | see below |
| 15 | `m23f:359` | `checks` | **DIFFERENT AXIS** | see below |

⚠️ **#13 also hides a SECOND, nested vacuity** the census does not flag: the inner
`t.clips.every(c => …)` passes for any track with no clips. Fixing the outer receiver without the
inner one only half-closes it.

## #14 and #15 are not assertions — they are the VERDICT

```js
process.exit(results.every((r) => r.ok) ? 0 : 1);   // m23ag:474
process.exit(checks.every((c) => c.ok) ? 0 : 1);    // m23f:359
```

This is the gate's exit code, not a claim about the product. Vacuous exactly when the gate ran
**zero checks** — in which case it exits **0** and reports success having measured nothing. Same
family as the CHANGELOG's 2026-07-30 finding (*"one check could never have reported a failure at
all"*).

⚠️ **A PRE-RECORDED DECISION THAT WAS WRONG.** When ee-2c-3 was filed, the intent was recorded as
*"prefer (a) CONVERT each to a real `check(` leg with a detail argument"*, with (b) pin-in-place
as the fallback. **Reading the code inverts that: there is no leg to convert, because these are
not legs.** The correct fix is (b) and it is not a fallback:

```js
process.exit(checks.length > 0 && checks.every((c) => c.ok) ? 0 : 1);
```

`m23ag` is additionally defended by its own `catch`, which pushes an `ok:false` row before this
line — so it is the weaker of the two candidates. **This is the "check an item's premise before
executing its method" law applying to a decision I recorded one hour earlier.**

## The scanner blind spots this exposes

Rules 1–4 were briefed and fixed during this cycle. **5–8 are newly found here and are NOT yet
implemented:**

| # | blind spot | motivating site | status |
|---|---|---|---|
| 1 | `for-of` over an array literal | `m23g1:205` | fixed |
| 2 | transitive fixed-bound (for-of over a cleared accumulator) | `m23g1:221` | fixed |
| 3 | a preceding `.some(P)` pin where receiver is `SRC.filter(P)` | `m23al` I0 | fixed |
| 4 | interprocedural | `m23ak` `starts()` | **not solved on purpose** → `HELPER-RETURN` class |
| 5 | numeric `for` whose bound is a const identifier (`i < N_A`) | `m23am:257` | **open** |
| 6 | pin expressed as equality on a derived join/string | `m23v:363` | **open** |
| 7 | pin that FOLLOWS the site (order is irrelevant to visibility) | `m23e:212` | **open** |
| 8 | pin via deep-equality against a fixed expected list (`eq(x, LIST)`) | `m23m3c:147`/`:197` | **open** |

⭐ Blind spot 4 was deliberately left unsolved: instead of guessing, the census now emits a
**`HELPER-RETURN`** provenance naming the helper, plus a `notClearedByProvenance` breakdown, so
those rows read "a human must read ONE function". **When a tool cannot answer, make it report
that** — the same lesson as the `notCleared` field added one cycle earlier.
