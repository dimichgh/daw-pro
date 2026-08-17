// _verdict.mjs — the ONE home for a gate's final pass/fail decision (m23-fa-1).
//
// ══ WHY THIS EXISTS ═════════════════════════════════════════════════════════
// m23-fa: 57 of 72 non-harness gates in this directory exit 0 after running
// ZERO checks. Every hand-rolled verdict idiom in the corpus is vacuous on an
// empty run — `process.exit(fail ? 1 : 0)` (fail starts at 0), `pass ===
// checks.length` (0 === 0 is true), `failed.length ? 1 : 0` (an empty array's
// `.length` is falsy), and five more spellings of the identical hole. A gate
// that silently stopped asserting is CURRENTLY INDISTINGUISHABLE from one that
// passed. This function makes that distinction structural instead of
// per-author: every migrated gate gets it for free, and there is exactly one
// place left to get it wrong.
//
// ══ WHY ITS OWN FILE, NOT JUST A NEW EXPORT INSIDE _staging.mjs ════════════
// Two of the 72 gates (`m23aq-data-dir-leak.mjs`, `m23aw-prepare-headroom.mjs`)
// are pure static analysis — no staging app, no port, no lifecycle. Forcing
// them to `import` 728 lines of staging launch/teardown machinery just to get
// a verdict would be exactly backwards: one home for the invariant should not
// mean one entanglement for everyone who wants it. `_staging.mjs` re-exports
// `verdict` so the other 70 gates see no difference in where it comes from.
//
// ══ THE CONTRACT, EACH CLAUSE LOAD-BEARING ═════════════════════════════════
//
// 1. Callers pass an EXPLICIT { ran, failed } SHAPE, never a raw array or a
//    boolean. A gate holding an array of check records computes it inline:
//        verdict({ ran: checks.length, failed: checks.filter(c => !c.ok).length });
//    Explicit and dumb beats a polymorphic API that has to guess what "ran"
//    means for a caller holding a counter instead of an array.
//
// 2. Exits NON-ZERO when zero checks ran, and the message together with the
//    EXIT CODE make "asserted nothing" impossible to misread as "checks
//    failed" — those are different diagnoses of a broken gate and a scrolled-
//    past operator must be able to tell them apart from the code alone:
//        ran === 0            -> exit 2  ("this run proves nothing")
//        ran > 0, failed > 0  -> exit 1  ("this run proves the feature broke")
//        ran > 0, failed === 0 -> exit 0 ("this run proves the feature works")
//    Exit 2 deliberately REUSES the meaning `_staging.mjs` already gives it —
//    `assertStagingPort` and `buildOrAbort` both exit 2 for "this run cannot
//    speak to its subject", never for "the subject misbehaved". A zero-check
//    run is the exact same class of non-finding, just discovered at the other
//    end of the gate instead of the front.
//
// 3. ⚠️⚠️ `process.exit()` HAPPENS INSIDE THIS FUNCTION. It is NOT a pure
//    function that returns a code for the caller to hand to its own
//    `process.exit()`. This is deliberate and must not be "cleaned up":
//    m23-es is an open finding that `process.exit()` skips every pending
//    `try/finally` across a 27-gate class (a SIGINT handler calling
//    `process.exit()` mid-run leaves a staging app orphaned because the
//    `finally` that would have torn it down never gets to run). The ONLY
//    place a future fix — "release what needs releasing, THEN exit" — could
//    ever land as a SINGLE point instead of 58 separate call sites is here,
//    inside this function, immediately before each `process.exit()` call.
//    Returning a code forecloses that fix permanently: by the time a caller's
//    own `process.exit(code)` runs, this function's stack frame and any
//    resource it could have released before exiting are already gone. Do not
//    refactor this into `export function verdictCode({ran,failed}) { return
//    ...; }` — the impurity is the point.
//
// 4. `allowEmpty` is an ESCAPE HATCH for a gate whose every leg can
//    legitimately skip on a given machine/run (rare — most gates should never
//    reach for this). Its reason is ENFORCED NON-EMPTY AT RUNTIME (a throw,
//    not a lint rule someone can forget to run) and taking it is VISIBLE at
//    the call site — `scripts/gate-verdict-census.mjs` reads the reason
//    straight out of the AST, so it can report `exempted` as a count that is
//    NEVER SUMMED with `migrated`. A single "N/N migrated" total is exactly
//    how an escape hatch would hide a still-vacuous gate behind a trustworthy-
//    looking number — see that census's own header for why this split is
//    load-bearing, not decorative.
//
// Usage (the two shapes every caller needs):
//     import { verdict } from "./_staging.mjs";      // the 70 gates with a staging lifecycle
//     import { verdict } from "./_verdict.mjs";      // the 2 pure-static gates
//
//     verdict({ ran: checks.length, failed: checks.filter(c => !c.ok).length });
//     verdict({ ran: legsTotal, failed: legsTotal - legsPassed },
//              { allowEmpty: "every leg probes optional hardware that may be entirely absent" });
//
// ══ COVERAGE RECORDING (m23-ep-3, round 2) ═════════════════════════════════
// `gate-corpus-staleness.mjs` can only report what `scripts/gate-corpus-
// baseline.json` knows, and the runner (`gate-corpus-run.mjs`) is the only
// thing that used to write to it — but normal work runs gates DIRECTLY
// (`node scripts/gates/m23xx.mjs`), which never touches the runner at all.
// A baseline with exactly one feed that's forbidden to run in bulk (~31.5
// min, ~54 GB of ACE checkpoints) has a steady state of "almost everything
// NEVER-RUN" — the same "mechanism whose only correct state gets learned
// past" shape the periodic-timer route was rejected over, one layer up. So
// `verdict()` ITSELF is now the second feed: every real gate that reaches
// this function records its own coverage.
//
// TWO WRITERS, RESOLVED BY ASYMMETRY, NOT PRECEDENCE. The runner knows things
// this function cannot — `TIMEOUT` never reaches `verdict()` (a timed-out
// gate gets killed before it ever calls this), and the `EXPECTED_RED` table
// lives only in the runner's own source. A direct run of an expected-red gate
// reaching `verdict({failed: >0})` would have no way to know that failure is
// pinned and expected — recording `kind: FAIL` here would be a lie the runner
// never told. So this function writes ONLY `sha256` + `ranAt` for the gate it
// was invoked from, and MERGES rather than replaces: any existing `kind`/
// `secs` a previous runner pass wrote are preserved untouched. Staleness only
// ever reads hash + timestamp (`kind` is decoration for a human skimming the
// baseline file) — so there is no conflict and no false record possible.
//
// ⚠️ "TWO WRITERS" ABOVE IS SCOPED TO THE BASELINE *RECORD* (this function +
// the runner) — do NOT read it as the count for the append-only JSONL
// HISTORY m25-q added alongside the baseline (scripts/gate-baseline-
// write.mjs). The history has THREE writers: this function, `gate-corpus-
// staleness.mjs`'s prune path (preserves an outgoing record before deleting
// it), and the runner's bulk upsert (the only writer of `kind`). See that
// module's own header for the full contract before assuming "two" covers it
// — an earlier draft of this exact item's brief made precisely that
// mistake, sourced from this section.
//
// KEYING: the invoking file must be a real gate — `scripts/gates/*.mjs`,
// not `_`-prefixed — determined from `process.argv[1]` (the script node was
// actually started with), never from "does the call site literally say
// `verdict(`". `gate-verdict-census.mjs` and `gate-corpus-staleness.mjs`
// itself both import `verdict` too and must NEVER get a baseline record for
// doing so — they are not gates, they live in `scripts/`, not `scripts/
// gates/`, and that path shape is the entire test.
//
// NEVER ALLOWED TO CHANGE THE GATE'S OWN RESULT. Reading/writing a shared
// file that up to 74 processes may touch (sequentially or from separate
// terminals/agents) is inherently more failure-prone than anything else this
// function does, and it must never be able to turn a passing gate red or a
// failing gate's message into something else. The whole coverage-recording
// step is therefore wrapped in its own try/catch, entirely separate from the
// ran/failed validation above; any failure (unwritable path, a directory
// where a file was expected, a corrupt existing baseline) is swallowed and
// reported on STDERR ONLY, never stdout — the channel this gate's own PASS/
// FAIL line goes through stays byte-identical either way. The corrupt-
// baseline case degrades to "treat it as if nothing was ever recorded" (an
// empty object) rather than crashing; that is lossy — a corrupted file that a
// direct run repairs starts over from zero rather than preserving whatever
// other gates' records it can't parse — but it converges: as gates run again
// the baseline re-fills, and a torn write can no longer happen in the first
// place because the write itself is temp-file-then-`rename()`, which POSIX
// guarantees is atomic on the same filesystem — a process killed mid-write
// leaves an orphaned temp file, never a half-written live baseline.
//
// WHAT THIS CANNOT DO. Seven `m23-fa-3`-exempted gates (`m16a`, and the six
// others tracked by the still-open `m23-fa-4`/`m23-fa-5`) never call
// `verdict()` at all — they can never gain a coverage record through this
// route no matter how much direct-run work happens, and will show as
// permanently NEVER-RUN in the staleness report. That is NOT a bug in this
// mechanism; those two open items already own crediting them, by whatever
// means fits each one's own vacuous-idiom shape. Do not "fix" it here.

import { existsSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, basename, join, resolve } from "node:path";
import { writeJSONAtomic } from "../gate-baseline-write.mjs";

const ROOT = "/Users/dsemenov/Views/daw-pro";
const GATES_DIR = join(ROOT, "scripts/gates");
const DEFAULT_BASELINE_PATH = join(ROOT, "scripts/gate-corpus-baseline.json");

// The file node was actually started with — NOT "does the caller mention
// verdict() in its source". A gate run BY the runner (`spawnSync("node",
// [join(GATES, g)], ...)`) or run directly (`node scripts/gates/m23xx.mjs`)
// both leave this pointed at the gate file itself, regardless of how many
// modules it imports `verdict` through on the way. Returns null for anything
// whose directory isn't exactly `scripts/gates/` or whose name is `_`-
// prefixed — the entire membership test this feature depends on.
function invokingGateFile() {
  const entry = process.argv[1];
  if (!entry) return null;
  let resolved;
  try {
    resolved = resolve(entry);
  } catch {
    return null;
  }
  if (dirname(resolved) !== GATES_DIR) return null;
  const base = basename(resolved);
  if (!base.endsWith(".mjs") || base.startsWith("_")) return null;
  return base;
}

// Anything that isn't a plain object — missing file, unparseable JSON, or
// JSON that parses fine but is `null`/an array/a string/a number — is
// treated as "nothing recorded yet", never as a crash. See the header for
// why this is a deliberate, lossy self-heal rather than an attempt at
// partial-JSON recovery.
function readBaselineObjectOrEmpty(path) {
  if (!existsSync(path)) return {};
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return {};
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return {};
  return parsed;
}

// The atomic write + history append now live in one shared module
// (scripts/gate-baseline-write.mjs, m25-q) — imported above as
// `writeJSONAtomic`. See that module's header for the full "three writers"
// contract; this file is writer #1 of 3.

// COVERAGE FACTS ONLY — see the header's "TWO WRITERS" section for the full
// contract. Never throws: any failure here must be invisible to the gate's
// own pass/fail result (stdout stays byte-identical either way).
//
// `ran`/`failed` are threaded in from `verdict()`'s own arguments (m25-q):
// this is the one place in the system that knows a gate's raw ran/failed
// counts WITHOUT the runner's EXPECTED_RED reclassification, so the history
// line records them even though the baseline record itself still carries
// only sha256+ranAt (see gate-baseline-write.mjs's header for why `kind` is
// deliberately never written here).
function recordCoverage(ran, failed) {
  const gate = invokingGateFile();
  if (!gate) return; // not a real gate invocation — nothing to record
  try {
    const baselinePath = process.env.CORPUS_BASELINE || DEFAULT_BASELINE_PATH;
    const sha256 = createHash("sha256").update(readFileSync(join(GATES_DIR, gate))).digest("hex");
    const baseline = readBaselineObjectOrEmpty(baselinePath);
    const existing = baseline[gate] || {};
    const ranAt = new Date().toISOString();
    // Spread `existing` FIRST so any `kind`/`secs` a runner pass already
    // wrote survive untouched; only `sha256`/`ranAt` are ever set here.
    baseline[gate] = { ...existing, sha256, ranAt };
    writeJSONAtomic(baselinePath, baseline, [
      { recordedAt: ranAt, source: "verdict", gate, sha256, ranAt, ran, failed },
    ]);
  } catch (e) {
    process.stderr.write(
      `⚠️ verdict(): could not record baseline coverage (${e.message}) — ` +
      `this gate's own PASS/FAIL result is unaffected.\n`
    );
  }
}

/**
 * Render and exit on a gate's final verdict. See the file header for the
 * full contract — every clause there is load-bearing, not incidental.
 *
 * @param {{ ran: number, failed: number }} counts
 * @param {{ allowEmpty?: string, subject?: string }} [opts]
 * @returns {never} always calls process.exit(); this function does not return.
 */
export function verdict({ ran, failed } = {}, { allowEmpty, subject } = {}) {
  // Enforced at runtime, not by convention — a caller cannot pass
  // `{ allowEmpty: "" }` (or `true`, or forget the string entirely) and have
  // it silently do nothing. That is the exact shape of bug this escape hatch
  // exists to be dangerous about: it must cost something to reach for.
  if (allowEmpty !== undefined && (typeof allowEmpty !== "string" || allowEmpty.length === 0)) {
    throw new Error(
      `verdict({ran, failed}, {allowEmpty}) requires allowEmpty to be a non-empty ` +
      `reason string when given (omit the option entirely if every run of this ` +
      `gate must record at least one check); got ${typeof allowEmpty}: ` +
      `${JSON.stringify(allowEmpty)}`
    );
  }
  // `subject` SELECTS a template (m23-gh) — it does not accept caller prose.
  // A caller that could pass its own ran==0 wording could reintroduce the
  // corpus's reserved alarm phrase ("ASSERTED NOTHING") outside a gate
  // context, which is exactly the false-hit this option exists to prevent.
  // So this stays a short noun, validated the same way allowEmpty is: it
  // must cost something to reach for, not silently no-op on a typo.
  if (subject !== undefined && (typeof subject !== "string" || subject.length === 0)) {
    throw new Error(
      `verdict({ran, failed}, {subject}) requires subject to be a non-empty ` +
      `noun string when given (omit the option entirely to keep the default ` +
      `gate-corpus wording — every gate in scripts/gates/ must NOT pass this); ` +
      `got ${typeof subject}: ${JSON.stringify(subject)}`
    );
  }
  if (!Number.isInteger(ran) || ran < 0) {
    throw new Error(
      `verdict({ran, failed}) requires ran to be a non-negative integer — the ` +
      `caller counts, this function does not; got ${typeof ran}: ${JSON.stringify(ran)}`
    );
  }
  if (!Number.isInteger(failed) || failed < 0) {
    throw new Error(
      `verdict({ran, failed}) requires failed to be a non-negative integer; got ` +
      `${typeof failed}: ${JSON.stringify(failed)}`
    );
  }
  if (failed > ran) {
    throw new Error(
      `verdict({ran, failed}): failed (${failed}) exceeds ran (${ran}) — the ` +
      `caller's own counters disagree with each other, which means the counting ` +
      `is wrong, not the feature under test`
    );
  }

  // m23-ep-3 round 2: coverage bookkeeping, deliberately AFTER every
  // validation throw above (a malformed call never touches the baseline) and
  // BEFORE all three exit branches below (every real verdict — empty,
  // failed, or passed — counts as "this gate ran just now"). See the file
  // header's "COVERAGE RECORDING" section for the full contract.
  recordCoverage(ran, failed);

  if (ran === 0) {
    if (allowEmpty) {
      // Visibly recorded in TWO places on purpose: this console line is for a
      // human reading the run's own output; the `{allowEmpty: "..."}` object
      // literal at the call site is what `gate-verdict-census.mjs` actually
      // reads (it inspects the AST, not stdout) — the two must never be
      // allowed to drift, so neither is optional.
      console.log(`VERDICT: 0 checks ran — ALLOWED EMPTY (${allowEmpty})`);
      process.exit(0);
    }
    // m23-gh: a NON-GATE caller (`subject` given) gets a DIFFERENT ran==0
    // template that never contains the corpus's reserved alarm phrase
    // "ASSERTED NOTHING" — that string is what everyone in this milestone
    // greps for to mean "a gate in scripts/gates/ ran zero checks", and a
    // non-gate reporter landing the same phrase is a false hit that costs a
    // real investigation. The DEFAULT path (no `subject`) below is untouched
    // byte-for-byte — every one of the 75 gates still gets exactly this text.
    if (subject) {
      console.log(
        `VERDICT: ⚠️⚠️ 0 checks ran — this ${subject} produced ZERO rows and ` +
        `can say NOTHING about its subject from this run. That is NOT the ` +
        `same claim as "checks passed": nothing was measured, so nothing is ` +
        `known from this run. If every leg of this ${subject} can ` +
        `legitimately produce zero on some runs, that is a real case — pass ` +
        `{ allowEmpty: "<reason>" } to say so explicitly. Silence is not a ` +
        `licence; a reason is.`
      );
      process.exit(2); // same "this run proves nothing" meaning as _staging.mjs's own ABORT exits
    }
    console.log(
      `VERDICT: ⚠️⚠️ 0 checks ran — this gate ASSERTED NOTHING. That is NOT the ` +
      `same claim as "checks passed": nothing was tested, so nothing about the ` +
      `feature is known from this run. If every leg of this gate can ` +
      `legitimately skip on some runs, that is a real case — pass ` +
      `{ allowEmpty: "<reason>" } to say so explicitly. Silence is not a licence; ` +
      `a reason is.`
    );
    process.exit(2); // same "this run proves nothing" meaning as _staging.mjs's own ABORT exits
  }

  if (failed > 0) {
    console.log(`VERDICT: ${failed}/${ran} check(s) FAILED.`);
    process.exit(1);
  }

  console.log(`VERDICT: ${ran}/${ran} check(s) passed.`);
  process.exit(0);
}
