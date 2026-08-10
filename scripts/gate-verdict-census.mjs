// m23-fa-1 — the VERDICT-SITE CENSUS.
//
// THE AXIS: m23-fa found 58 verdict sites across 57 of the 72 non-harness
// gates that exit 0 after running ZERO checks — every hand-rolled idiom in
// this corpus is vacuous on an empty run (`fail ? 1 : 0`, `pass ===
// checks.length`, `failed.length ? 1 : 0`, …, 8 spellings of the identical
// hole). This script classifies EVERY verdict site in the corpus into one of:
//   VACUOUS   — still one of the 8 vacuous idioms, not migrated
//   GUARDED   — a hand-rolled idiom that already carries an inline length
//               guard (the m23-ee-2c-3 fix shape: `X.length > 0 && X.every(…)`)
//               — safe today, but NOT routed through the one-home primitive
//   MIGRATED  — routed through `verdict({ran, failed})` from `_verdict.mjs`,
//               with no `allowEmpty` escape hatch
//   EXEMPTED  — routed through `verdict(...)` WITH an `allowEmpty` reason
//
// ⚠️⚠️ `migrated` and `exempted` ARE REPORTED AS TWO NUMBERS, NEVER SUMMED.
// A single "N/N migrated" total is exactly how the escape hatch would hide a
// still-vacuous gate behind a trustworthy-looking number during a 50-file
// migration (m23-fa-2's own filed trap). Read both; do not add them.
//
// WHY A REAL PARSER AND NOT A GREP: same reasoning as `every-vacuity-census.mjs`
// (read that script first — this one follows its conventions on purpose,
// right down to the ACORN_DIR indirection and the "no bare verdict, one row
// per site" stance). A regex over `process.exit(` cannot tell a verdict
// ternary from an ABORT literal (`process.exit(2)`) or from the unrelated
// `clean === ITERS ? 0 : 4` shape in m16a-poison-recipe.mjs — see the
// UNCLASSIFIED bucket below for why that last one is reported, not silently
// dropped.
//
// ⚠️ THIS SCRIPT ASSERTS ITS OWN INSTRUMENT HEALTH AND HARD-FAILS IF IT
// CANNOT CLASSIFY ITS OWN FIXTURES (m23-gb). It used to pin a positive
// control to three REAL corpus sites that were already GUARDED
// (m23ag-explain-capture-origin.mjs:477, m23f-arrange-drop.mjs:362,
// m23cf-delete-key.mjs:561) — m23-fa-2 migrated all three ON PURPOSE, so
// GUARDED is now 0 corpus-wide, permanently, BY DESIGN: no real file can
// ever exercise that branch again. A control drawn from a population its own
// project is eliminating must break on success, so pinning it to a
// *different* real site would only delay the identical failure. m23-gb
// replaced it with SYNTHETIC self-test fixtures below — one inline snippet
// each for VACUOUS / GUARDED / MIGRATED / EXEMPTED — plus a separate corpus
// non-vacuity assertion the synthetic fixtures cannot cover: a census whose
// synthetic self-tests all pass but which scanned ZERO real files would
// still exit 0 reporting a clean bill of health about nothing measured —
// exactly the vacuity defect this whole milestone exists to eliminate,
// sitting inside the instrument that measures it, so it gets its own check.
//
// EXIT CODES (distinct on purpose — a bare "exit 1" cannot tell "instrument
// broken" from "corpus unreachable"):
//   0 — normal: real files were scanned, real sites were classified, and
//       every synthetic self-test passed.
//   1 — SELF-TEST FAILED: the classifier misclassifies one of its own
//       synthetic VACUOUS/GUARDED/MIGRATED/EXEMPTED fixtures. NO count below
//       may be trusted.
//   2 — CORPUS ASSERTED NOTHING: zero files were scanned or zero verdict
//       sites were classified. Borrows `_verdict.mjs`'s phrasing ("this run
//       proves nothing") because it reads correctly to a human.
//       ⚠️ BUT THE TWO EXIT-2s ARE NOT THE SAME THING, AND NOTHING SHOULD BE
//       WRITTEN THAT TREATS THEM AS INTERCHANGEABLE. A *gate* exiting 2 is a
//       FINDING: that gate ran and asserted nothing, which is a true discovery
//       about the corpus and is worth surfacing. This script exiting 2 is a
//       FAILED MEASUREMENT: the instrument could not look, so there is no
//       finding at all — the opposite claim. They are safe to share a number
//       today only because NOTHING invokes this script programmatically
//       (verified m23-gb: the corpus runner globs `scripts/gates/` and this
//       file lives in `scripts/`, and the only repo-wide references to it are
//       two comments in `_verdict.mjs`). ⭐ IF YOU EVER WIRE THIS INTO
//       AUTOMATION, GIVE IT ITS OWN CODE FIRST — otherwise a "measured
//       nothing" gets counted as a "found something".
//   (an `acorn`/`acorn-walk` module-resolution failure below exits 1 too,
//   via Node's own uncaught-exception default, with Node's own
//   "Cannot find module" text — see RUNNING IT below for the fix.)
//
// RUNNING IT. Needs `acorn` + `acorn-walk`, DELIBERATELY NOT a repo dependency
// (this is a periodic audit, not part of any gate):
//
//     mkdir -p /tmp/vac2 && cd /tmp/vac2 && npm i acorn acorn-walk
//     ACORN_DIR=/tmp/vac2/node_modules node scripts/gate-verdict-census.mjs
//
// Prints a human-readable summary to stderr (so `> census.json` on stdout
// stays clean JSON) and the full classified row set as JSON to stdout.

const ACORN_DIR = process.env.ACORN_DIR || "./node_modules";
const acorn = await import(`${ACORN_DIR}/acorn/dist/acorn.mjs`);
const walk = await import(`${ACORN_DIR}/acorn-walk/dist/walk.mjs`);
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const GATES = process.env.VC_GATES || "/Users/dsemenov/Views/daw-pro/scripts/gates";

const src = (n) => readFileSync(path.join(GATES, n), "utf8");
const txt = (code, node) => code.slice(node.start, node.end).replace(/\s+/g, " ");

// ── Which local names, in THIS file, are bound to the `verdict` primitive? ──
// Only via a static `import { verdict [as X] } from "./_staging.mjs" | "./_verdict.mjs"`
// — a function some OTHER gate happens to also call "verdict" must not be
// mistaken for the primitive. Returns a Set of local identifier names.
function verdictImportNames(ast) {
  const names = new Set();
  for (const stmt of ast.body) {
    if (stmt.type !== "ImportDeclaration") continue;
    if (!/_staging\.mjs$|_verdict\.mjs$/.test(stmt.source.value)) continue;
    for (const spec of stmt.specifiers) {
      if (spec.type === "ImportSpecifier" && spec.imported.type === "Identifier" &&
          spec.imported.name === "verdict") {
        names.add(spec.local.name);
      }
    }
  }
  return names;
}

// A single BinaryExpression conjunct that genuinely bounds a receiver's
// `.length` away from zero. Mirrors `every-vacuity-census.mjs`'s
// `countPinInStmt` reasoning: `> 0` / `>= 1` / `=== N` (N > 0) are guards;
// `>= 0` and `=== 0` are not (`=== 0` is an EMPTINESS assertion, the inverse
// of a guard, not a guard misspelled).
function isLengthGuardClause(node) {
  if (node.type !== "BinaryExpression") return false;
  const isLen = (n) => n.type === "MemberExpression" && !n.computed && n.property?.name === "length";
  const lit = (n) => n.type === "Literal" && typeof n.value === "number";
  let lenSide = null, litSide = null;
  if (isLen(node.left) && lit(node.right)) { lenSide = node.left; litSide = node.right; }
  else if (isLen(node.right) && lit(node.left)) { lenSide = node.right; litSide = node.left; }
  if (!lenSide) return false;
  const n = litSide.value;
  if (node.operator === ">") return n >= 0;
  if (node.operator === ">=") return n >= 1;
  if (node.operator === "===" || node.operator === "==") return n > 0;
  return false;
}

// Classify the TEST half of `process.exit(TEST ? A : B)`. Returns one of:
//   "GUARDED"                — already carries an inline length guard
//   "VACUOUS-IDENTIFIER"     — bare `fail ? 1 : 0`
//   "VACUOUS-EQ-ZERO"        — `fail === 0 ? 0 : 1` / `failed === 0 ? 0 : 1` / …
//   "VACUOUS-EQ-LENGTH"      — `pass === checks.length ? 0 : 1`
//   "VACUOUS-LENGTH-TRUTHY"  — `failed.length ? 1 : 0` / `bad.length ? 1 : 0`
//   "VACUOUS-EVERY"          — bare `x.every(pred) ? 0 : 1` (the PRE-fix shape
//                              of the two sites m23-ee-2c-3 already patched —
//                              zero live instances expected, kept for
//                              completeness/regression-catching)
//   null                     — not a recognized verdict-idiom shape at all
//                              (e.g. `clean === ITERS`) — reported separately,
//                              never silently folded into "not a site".
function classifyVerdictTest(test) {
  if (test.type === "LogicalExpression" && test.operator === "&&") {
    if (isLengthGuardClause(test.left) || isLengthGuardClause(test.right)) return "GUARDED";
  }
  if (test.type === "Identifier") return "VACUOUS-IDENTIFIER";
  if (test.type === "CallExpression" && test.callee.type === "MemberExpression" &&
      /^(every|some)$/.test(test.callee.property?.name)) {
    return "VACUOUS-EVERY";
  }
  if (test.type === "BinaryExpression" && /^(===|==)$/.test(test.operator)) {
    const isZero = (n) => n.type === "Literal" && n.value === 0;
    const isLen = (n) => n.type === "MemberExpression" && !n.computed && n.property?.name === "length";
    const isIdent = (n) => n.type === "Identifier";
    // m23k4b-midi-drop.mjs:293 — `bad.length === 0 ? 0 : 1` — caught by a live
    // run of THIS census, not by the roadmap's own premise measurement (which
    // was keyword/variable-name-based and missed this 9th spelling entirely).
    // Same defect as VACUOUS-LENGTH-TRUTHY, just an explicit equality instead
    // of a truthy check — an empty `bad` array has `.length === 0` too.
    if (isLen(test.left) && isZero(test.right)) return "VACUOUS-LENGTH-EQ-ZERO";
    if (isLen(test.right) && isZero(test.left)) return "VACUOUS-LENGTH-EQ-ZERO";
    if (isIdent(test.left) && isZero(test.right)) return "VACUOUS-EQ-ZERO";
    if (isIdent(test.right) && isZero(test.left)) return "VACUOUS-EQ-ZERO";
    if (isIdent(test.left) && isLen(test.right)) return "VACUOUS-EQ-LENGTH";
    if (isIdent(test.right) && isLen(test.left)) return "VACUOUS-EQ-LENGTH";
  }
  if (test.type === "MemberExpression" && !test.computed && test.property?.name === "length") {
    return "VACUOUS-LENGTH-TRUTHY";
  }
  return null;
}

// Classify a call to the `verdict` primitive itself: MIGRATED (no escape
// hatch) vs EXEMPTED (an `allowEmpty` reason present in the SECOND argument
// object literal, read straight from source text — this is the "visibly
// recorded" half of `_verdict.mjs`'s own contract; the runtime throw is the
// other half, and this script cannot see a value that isn't a literal, which
// is fine: a non-literal reason still counts as EXEMPTED, just without a
// captured reason string).
function classifyVerdictCall(node, code) {
  const second = node.arguments[1];
  if (!second || second.type !== "ObjectExpression") return { kind: "MIGRATED", reason: null };
  for (const prop of second.properties) {
    if (prop.type !== "Property" || prop.computed) continue;
    const key = prop.key.type === "Identifier" ? prop.key.name
      : prop.key.type === "Literal" ? prop.key.value : null;
    if (key !== "allowEmpty") continue;
    const reason = prop.value.type === "Literal" && typeof prop.value.value === "string"
      ? prop.value.value
      : `<non-literal: ${txt(code, prop.value).slice(0, 60)}>`;
    return { kind: "EXEMPTED", reason };
  }
  return { kind: "MIGRATED", reason: null };
}

// Scan one source file's (or synthetic snippet's) text, returning the rows it
// contributes. Pulled out of the corpus loop so the SAME codepath can also run
// against two synthetic self-test snippets below — a classification branch
// with zero observations is indistinguishable from a broken one, and until
// this census migrates a real EXEMPTED site, the corpus alone can never
// exercise that branch at all.
function scanSource(label, code, { synthetic = false } = {}) {
  const localRows = [];
  let ast;
  try {
    ast = acorn.parse(code, { ecmaVersion: "latest", sourceType: "module", locations: true });
  } catch (e) {
    // A file that did not parse is UNMEASURED, not clean. Recorded loudly,
    // same stance as every-vacuity-census.mjs.
    if (!synthetic) parseFails.push(`${label}: ${e.message}`);
    return localRows;
  }

  const verdictNames = synthetic
    ? new Set(["verdict"]) // synthetic snippets below always import it as `verdict`
    : verdictImportNames(ast);

  walk.simple(ast, {
    CallExpression(node) {
      // `process.exit(TEST ? A : B)` — a verdict-idiom candidate.
      if (node.callee.type === "MemberExpression" && !node.callee.computed &&
          node.callee.object.type === "Identifier" && node.callee.object.name === "process" &&
          node.callee.property.name === "exit") {
        const arg = node.arguments[0];
        if (!arg || arg.type !== "ConditionalExpression") return; // e.g. bare process.exit(2) — a different axis (m23-fg)
        const shape = classifyVerdictTest(arg.test);
        if (!shape) {
          localRows.push({
            file: label, line: node.loc.start.line, site: "process.exit(cond ? : )",
            kind: "UNCLASSIFIED",
            detail: `unrecognized test shape: ${txt(code, arg.test).slice(0, 70)}`,
          });
          return;
        }
        localRows.push({
          file: label, line: node.loc.start.line, site: "process.exit(cond ? : )",
          kind: shape === "GUARDED" ? "GUARDED" : "VACUOUS",
          idiom: shape,
          detail: txt(code, arg).slice(0, 90),
        });
        return;
      }

      // `verdict({ran, failed}, opts?)` — the primitive itself.
      if (node.callee.type === "Identifier" && verdictNames.has(node.callee.name)) {
        const cls = classifyVerdictCall(node, code);
        localRows.push({
          file: label, line: node.loc.start.line, site: "verdict(...)",
          kind: cls.kind,
          reason: cls.reason,
          detail: txt(code, node).slice(0, 90),
        });
      }
    },
  });
  return localRows;
}

// m23-gb: a WRONG path is the single most likely way this census ends up with
// nothing to measure — and it used to be the one case that did NOT reach the
// exit-2 "asserted nothing" report below. `readdirSync` threw ENOENT uncaught,
// so the reader got a raw Node stack trace and exit 1, indistinguishable from a
// classifier defect, while the exit-2 message itself advises "check the
// `GATES`/`VC_GATES` path". Advice printed only on the paths where it does not
// apply is worse than no advice. Caught here so a bad path lands on the same
// exit-2 vocabulary as an empty one: both mean "this run asserted nothing".
let files;
try {
  files = readdirSync(GATES).filter((f) => f.endsWith(".mjs") && !f.startsWith("_")).sort();
} catch (e) {
  console.error(
    `\n✘✘✘ CORPUS UNREADABLE (exit 2) — could not list the gate corpus at \`${GATES}\`.\n` +
    `    ${e?.message ?? String(e)}\n` +
    `    This run asserted NOTHING about the corpus. Set \`VC_GATES\` to a real ` +
    `directory of gate \`.mjs\` files, or unset it to use the default.`
  );
  process.exit(2);
}
const rows = [];
const parseFails = [];

for (const f of files) {
  rows.push(...scanSource(f, src(f)));
}

// ── SELF-TEST: exercise all four verdict-site kinds directly, not just in
// theory. A hard failure of the instrument — a branch this census has never
// once observed firing is exactly as untrustworthy as a branch it
// misclassifies. VACUOUS and GUARDED (m23-gb) sit alongside the original
// MIGRATED/EXEMPTED pair as the retired positive control's replacement: both
// fragments are copied VERBATIM from the real idioms that control used to
// pin to (see the file header) — the GUARDED shape is the exact
// `X.length > 0 && X.every(pred) ? 0 : 1` guard m23-fa-2 migrated away from
// all three real sites, and the VACUOUS shape is the plainest of the 8
// vacuous idioms this whole census exists to find.
const SELF_TEST_VACUOUS_SRC =
  `let fail = 0;\n` +
  `process.exit(fail ? 1 : 0);\n`;
const SELF_TEST_GUARDED_SRC =
  `const checks = [{ ok: true }];\n` +
  `process.exit(checks.length > 0 && checks.every((c) => c.ok) ? 0 : 1);\n`;
const SELF_TEST_MIGRATED_SRC =
  `import { verdict } from "./_staging.mjs";\n` +
  `const checks = [{ ok: true }, { ok: false }];\n` +
  `verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });\n`;
const SELF_TEST_EXEMPTED_SRC =
  `import { verdict } from "./_staging.mjs";\n` +
  `verdict({ ran: 0, failed: 0 }, { allowEmpty: "self-test fixture" });\n`;
const selfTestVacuousRows = scanSource("<self-test:vacuous>", SELF_TEST_VACUOUS_SRC, { synthetic: true });
const selfTestGuardedRows = scanSource("<self-test:guarded>", SELF_TEST_GUARDED_SRC, { synthetic: true });
const selfTestMigratedRows = scanSource("<self-test:migrated>", SELF_TEST_MIGRATED_SRC, { synthetic: true });
const selfTestExemptedRows = scanSource("<self-test:exempted>", SELF_TEST_EXEMPTED_SRC, { synthetic: true });
const selfTestResults = [
  { name: "VACUOUS snippet classifies as VACUOUS", ok: selfTestVacuousRows.length === 1 && selfTestVacuousRows[0].kind === "VACUOUS" },
  { name: "GUARDED snippet classifies as GUARDED", ok: selfTestGuardedRows.length === 1 && selfTestGuardedRows[0].kind === "GUARDED" },
  { name: "MIGRATED snippet classifies as MIGRATED", ok: selfTestMigratedRows.length === 1 && selfTestMigratedRows[0].kind === "MIGRATED" },
  { name: "EXEMPTED snippet classifies as EXEMPTED with its reason captured",
    ok: selfTestExemptedRows.length === 1 && selfTestExemptedRows[0].kind === "EXEMPTED" &&
        selfTestExemptedRows[0].reason === "self-test fixture" },
];
const selfTestOk = selfTestResults.every((r) => r.ok);

// ── CORPUS NON-VACUITY — the assertion the synthetic self-tests above
// CANNOT cover (m23-gb, Part 2). The self-tests above are entirely
// synthetic: they exercise the classifier on hand-written snippets and can
// ALL pass even if the corpus scan itself found nothing — a broken
// `readdirSync`, a wrong `GATES`/`VC_GATES` path, or a genuinely empty
// directory would each leave `files` and `rows` empty while every synthetic
// self-test still passes, exiting 0 with a "clean bill of health"
// (`VACUOUS 0 · GUARDED 0 · MIGRATED 0 · EXEMPTED 0`) that measured NOTHING.
// That is precisely the vacuity defect this whole milestone exists to
// eliminate, sitting inside the instrument that measures it — so it gets a
// hard, first-class, separately-exit-coded assertion here, not a note an
// alert reader might catch by noticing four suspicious zeroes.
const corpusNonVacuousOk = files.length > 0 && rows.length > 0;

// ── Aggregate. `migrated` and `exempted` are printed as SEPARATE fields and
// are NEVER added together anywhere in this file — see the header. ──
const vacuous = rows.filter((r) => r.kind === "VACUOUS");
const guarded = rows.filter((r) => r.kind === "GUARDED");
const migrated = rows.filter((r) => r.kind === "MIGRATED");
const exempted = rows.filter((r) => r.kind === "EXEMPTED");
const unclassified = rows.filter((r) => r.kind === "UNCLASSIFIED");

// ── RETIRED POSITIVE CONTROL — the lesson kept, the dead code removed (m23-gb) ──
//
// This census used to pin a positive control to three REAL corpus sites,
// matched by (file, a fragment of the site's own source text), NOT by a
// pinned line number — because line numbers drift under unrelated edits.
// Measured live while first writing this census: `m23cf-delete-key.mjs`'s
// guarded site moved 561 -> 568 -> 644 across about two minutes, because
// another agent was actively editing that file at the time (m23-cf-3, adding
// a handler-level delete seam) — three separate re-checks, three different
// line numbers, same byte-identical guard expression each time. A
// line-pinned control would have reported "census broken" on every one of
// those saves, which is exactly the false alarm this project's own path/
// line-rot law warns about, just applied to a positive control instead of a
// grep. The control's actual job was "does the classifier recognize THIS
// SHAPE in THIS FILE", not "is the file frozen" — so it matched on content
// and reported line drift as INFORMATION, never as failure.
//
// m23-fa-2 then migrated all three of those real sites ON PURPOSE, so
// GUARDED is now 0 corpus-wide, permanently, BY DESIGN — the control could
// never pass again, and re-pinning it to a different real site would only
// delay the identical failure, because by design there are no GUARDED real
// sites left and there never will be again. The synthetic GUARDED self-test
// above (`SELF_TEST_GUARDED_SRC`) asserts the identical claim — "does the
// classifier recognize a length-guarded ternary as GUARDED" — without
// depending on any real file continuing to hold one. The "match by content,
// report drift as information, never as failure" technique above remains
// correct for any FUTURE line-pinned corpus control; it is recorded here so
// it is not lost along with the code that used it.

console.error("\n── SELF-TEST (VACUOUS / GUARDED / MIGRATED / EXEMPTED — synthetic fixtures; GUARDED can no longer be exercised by the corpus AT ALL, see above) ──");
for (const r of selfTestResults) console.error(`  ${r.ok ? "✔" : "✘"} ${r.name}`);

console.error("\n── CORPUS NON-VACUITY (this run must have scanned SOMETHING real — synthetic self-tests above cannot prove this) ──");
console.error(`  ${corpusNonVacuousOk ? "✔" : "✘"} files.length > 0 && rows.length > 0  (files=${files.length}, rows=${rows.length})`);

console.error("\n── SUMMARY ──");
console.error(`files scanned: ${files.length}   parse failures: ${parseFails.length}`);
console.error(`total verdict sites classified: ${rows.length}`);
console.error(`  VACUOUS       (needs migration):        ${vacuous.length}`);
console.error(`  GUARDED       (safe, not on primitive):  ${guarded.length}`);
console.error(`  MIGRATED      (on primitive, no escape): ${migrated.length}`);
console.error(`  EXEMPTED      (on primitive, allowEmpty):${exempted.length}`);
console.error(`  UNCLASSIFIED  (exit-ternary, unknown shape — a DIFFERENT axis, not silently dropped): ${unclassified.length}`);
console.error(`⚠️  migrated (${migrated.length}) and exempted (${exempted.length}) are reported SEPARATELY on purpose — do not sum them.`);
if (unclassified.length) {
  console.error(`  unclassified sites (inspect by hand — may be a genuine 9th idiom, e.g. m16a's "clean === ITERS"):`);
  for (const r of unclassified) console.error(`    ${r.file}:${r.line}  ${r.detail}`);
}
if (parseFails.length) {
  console.error(`⚠️ PARSE FAILURES (unmeasured, not clean):`);
  for (const p of parseFails) console.error(`  ${p}`);
}

console.log(JSON.stringify({
  rows,
  parseFails,
  filesScanned: files.length,
  vacuous: vacuous.length,
  guarded: guarded.length,
  migrated: migrated.length,
  exempted: exempted.length,
  unclassified: unclassified.length,
  corpusNonVacuous: { ok: corpusNonVacuousOk, files: files.length, rows: rows.length },
  selfTest: { ok: selfTestOk, results: selfTestResults },
}, null, 1));

// ── EXIT CODES — distinct on purpose (m23-gb). See the file header for the
// full vocabulary; both checks below are independent and both hard-fail. ──
if (!corpusNonVacuousOk) {
  console.error(
    "\n✘✘✘ CORPUS ASSERTED NOTHING (exit 2) — this run scanned " +
    `${files.length} file(s) and classified ${rows.length} verdict site(s). ` +
    "A census that scans zero files, or classifies zero sites, would pass " +
    "every synthetic self-test above and still exit 0 reporting a clean " +
    "bill of health about nothing measured. Check the `GATES` / `VC_GATES` " +
    "path and that the corpus directory is not empty before trusting " +
    "anything else this script printed."
  );
  process.exit(2);
}
if (!selfTestOk) {
  console.error(
    "\n✘✘✘ SELF-TEST FAILED (exit 1) — this census cannot correctly classify " +
    "one of its OWN synthetic VACUOUS/GUARDED/MIGRATED/EXEMPTED fixtures. " +
    "NO COUNT ABOVE MAY BE TRUSTED until this passes — a branch that has " +
    "never fired correctly is exactly as dangerous as one that fires wrong."
  );
  process.exit(1);
}
