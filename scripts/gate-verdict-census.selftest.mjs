// m23-gd-1 — self-test for `gate-verdict-census.mjs`'s exit-3
// dependency-resolution-failure path.
//
// ⛔ DELIBERATELY NOT in scripts/gates/ — that directory is the gate corpus
// (a pinned count several other checks depend on: 94 `.mjs` = 19 harness +
// 75 non-harness). This tests a TOOL, not a gate, and must never change that
// denominator.
//
// TWO INDEPENDENT LEGS. Both must pass; a skipped green leg counts as FAILED,
// not as a pass and not as a quiet skip.
//
//   LEG A (missing dep) — point ACORN_DIR at a fresh empty directory and run
//   the census. Assert: exit 3; stdout is 0 bytes; stderr has ZERO
//   stack-trace lines (no `^\s*at ` frames, no `ERR_MODULE_NOT_FOUND` text —
//   a raw Node stack trace is exactly what makes a missing prerequisite look
//   like a crash); the "INSTRUMENT COULD NOT LOOK" banner is present; the
//   string "ASSERTED NOTHING" is ABSENT (that phrase is the corpus's
//   reserved alarm for a *gate* that ran and found nothing — m23-gh is filed
//   about exactly this defect in other instruments; this script must not
//   commit it while fixing it).
//
//   LEG B (present dep) — ensure real `acorn` + `acorn-walk` are installed
//   at the default ACORN_DIR (`scripts/node_modules`, already covered by the
//   repo-root `.gitignore`'s `node_modules/` line — CONFIRMED below via
//   `git check-ignore`, not assumed) and run the census with no ACORN_DIR
//   override. Assert exit 0, valid JSON on stdout, and real row counts. This
//   is the ONLY proof the try/catch added around the two dynamic imports did
//   not also swallow a genuinely successful parse.
//
//   If acorn cannot be installed (no network, no npm, …), Leg B is UNMEASURED
//   and this self-test FAILS — it does not skip quietly and does not let a
//   missing leg read as a pass.
//
// Run: node scripts/gate-verdict-census.selftest.mjs

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, existsSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(SCRIPT_DIR, "..");
const CENSUS = path.join(SCRIPT_DIR, "gate-verdict-census.mjs");
const SCRIPTS_NODE_MODULES = path.join(SCRIPT_DIR, "node_modules");

let failures = 0;
function report(name, ok, detail) {
  console.error(`  ${ok ? "✔" : "✘"} ${name}${detail !== undefined ? `  — ${detail}` : ""}`);
  if (!ok) failures++;
  return ok;
}

// ── LEG A: missing dependency ────────────────────────────────────────────
console.error("── LEG A: missing dependency (ACORN_DIR → fresh empty dir) ──");
{
  const emptyDir = mkdtempSync(path.join(tmpdir(), "gate-verdict-census-selftest-empty-"));
  try {
    const r = spawnSync("node", [CENSUS], {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, ACORN_DIR: emptyDir },
    });
    const stdout = r.stdout ?? "";
    const stderr = r.stderr ?? "";

    report("exits 3", r.status === 3, `actual status=${r.status}`);
    report("stdout is empty (0 bytes)", stdout.length === 0, `actual ${stdout.length} bytes`);
    report("zero stack-trace frames (no `^\\s*at ` lines)", !/^\s*at /m.test(stderr));
    report("zero `ERR_MODULE_NOT_FOUND` text", !stderr.includes("ERR_MODULE_NOT_FOUND"));
    report("banner present (\"INSTRUMENT COULD NOT LOOK\")", stderr.includes("INSTRUMENT COULD NOT LOOK"));
    report("banner omits the reserved alarm phrase", !stderr.includes("ASSERTED NOTHING"));
    report("prints resolved ACORN_DIR", stderr.includes("ACORN_DIR resolved to:"));
    report("prints acorn version line (UNKNOWN, since nothing installed)", /acorn version: UNKNOWN/.test(stderr));

    if (failures) {
      console.error("  --- captured stderr ---");
      console.error(stderr.split("\n").map((l) => "  | " + l).join("\n"));
      console.error(`  --- captured stdout (${stdout.length} bytes) ---`);
    }
  } finally {
    rmSync(emptyDir, { recursive: true, force: true });
  }
}

// ── LEG B: present dependency ────────────────────────────────────────────
console.error("\n── LEG B: present dependency (real acorn + acorn-walk at scripts/node_modules) ──");
{
  const haveAcorn = () =>
    existsSync(path.join(SCRIPTS_NODE_MODULES, "acorn")) &&
    existsSync(path.join(SCRIPTS_NODE_MODULES, "acorn-walk"));

  const PKG_JSON = path.join(SCRIPT_DIR, "package.json");
  const PKG_LOCK = path.join(SCRIPT_DIR, "package-lock.json");

  let installDetail;
  let installOk = haveAcorn();
  if (installOk) {
    installDetail = "already present at scripts/node_modules";
  } else {
    // `--no-save`, mirroring the RUNNING IT recipe in gate-verdict-census.mjs
    // itself: scripts/ deliberately has no package.json (m23-gd-2 territory,
    // not this task), and a bare `npm i <pkg>` in a directory without one
    // would have npm 7+ auto-create a minimal one — a defensive rmSync
    // fallback still runs below in case some npm version ignores the flag.
    const hadPkgJsonBefore = existsSync(PKG_JSON);
    const hadPkgLockBefore = existsSync(PKG_LOCK);
    console.error("  scripts/node_modules/{acorn,acorn-walk} not found — installing (npm i --no-save acorn acorn-walk)…");
    const inst = spawnSync("npm", ["i", "--no-save", "acorn", "acorn-walk"], {
      cwd: SCRIPT_DIR,
      encoding: "utf8",
    });
    installOk = inst.status === 0 && haveAcorn();
    installDetail = installOk
      ? "installed just now via npm i --no-save"
      : `npm i FAILED — status=${inst.status} error=${inst.error?.message ?? "none"} ` +
        `stderr=${(inst.stderr || "").trim().slice(0, 300)}`;
    if (!hadPkgJsonBefore && existsSync(PKG_JSON)) rmSync(PKG_JSON);
    if (!hadPkgLockBefore && existsSync(PKG_LOCK)) rmSync(PKG_LOCK);
  }
  report("acorn + acorn-walk available at scripts/node_modules", installOk, installDetail);
  report("no package.json left behind by the install (m23-gd-2 territory, not this task)", !existsSync(PKG_JSON));

  // Confirm the default ACORN_DIR target is actually gitignored, not
  // assumed. NOTE: `git check-ignore` on a directory-only pattern
  // (`node_modules/`) needs the path to EXIST on disk to know it is a
  // directory — checked here, after install, rather than before, for
  // exactly that reason (verified: it reports "not ignored" for an absent
  // path even though the pattern matches once the directory is there).
  if (existsSync(SCRIPTS_NODE_MODULES)) {
    const gi = spawnSync("git", ["check-ignore", "scripts/node_modules"], { cwd: ROOT, encoding: "utf8" });
    report("`git check-ignore scripts/node_modules` exits 0 (IS ignored, .gitignore:10)",
      gi.status === 0, `actual status=${gi.status}`);
  } else {
    report("`git check-ignore scripts/node_modules` exits 0 (IS ignored, .gitignore:10)",
      false, "scripts/node_modules does not exist — cannot confirm");
  }

  if (!installOk) {
    console.error(
      "\n✘✘✘ LEG B UNMEASURED — acorn could not be installed, so the ONLY " +
      "proof that the exit-3 try/catch did not also break the genuine " +
      "successful-parse path was never obtained. This is reported as a " +
      "FAILURE, not a skip: an untested leg is not a passed leg."
    );
    // failures already incremented by report() above.
  } else {
    const envNoOverride = { ...process.env };
    delete envNoOverride.ACORN_DIR;
    const r = spawnSync("node", [CENSUS], {
      cwd: ROOT,
      encoding: "utf8",
      env: envNoOverride,
    });
    const stdout = r.stdout ?? "";
    const stderr = r.stderr ?? "";

    report("exits 0", r.status === 0, `actual status=${r.status}`);
    report("prints resolved ACORN_DIR", stderr.includes("ACORN_DIR resolved to:"));
    report("prints a real acorn version (not UNKNOWN)", /acorn version: (?!UNKNOWN)\S/.test(stderr));

    let parsed = null;
    try {
      parsed = JSON.parse(stdout);
    } catch (e) {
      report("stdout is valid JSON", false, `JSON.parse threw: ${e.message}`);
    }
    if (parsed) {
      report("stdout is valid JSON", true);
      report("filesScanned > 0", (parsed.filesScanned ?? 0) > 0, `filesScanned=${parsed.filesScanned}`);
      const totalRows = (parsed.vacuous ?? 0) + (parsed.guarded ?? 0) + (parsed.migrated ?? 0) +
        (parsed.exempted ?? 0) + (parsed.unclassified ?? 0);
      report("classified verdict sites > 0", totalRows > 0,
        `vacuous=${parsed.vacuous} guarded=${parsed.guarded} migrated=${parsed.migrated} ` +
        `exempted=${parsed.exempted} unclassified=${parsed.unclassified}`);
      report("census's own internal self-test passed", parsed.selfTest?.ok === true);
      console.error(
        `  row counts: filesScanned=${parsed.filesScanned} vacuous=${parsed.vacuous} ` +
        `guarded=${parsed.guarded} migrated=${parsed.migrated} exempted=${parsed.exempted} ` +
        `unclassified=${parsed.unclassified}`
      );
    }

    if (r.status !== 0) {
      console.error("  --- captured stderr ---");
      console.error(stderr.split("\n").map((l) => "  | " + l).join("\n"));
    }
  }
}

// ── BEHAVIOURAL GUARD: the reserved alarm phrase never leaks from a
// NON-GATE reporter, and the matcher itself is proven live (m23-gj) ────────
//
// m23-gd-1's own brief forbade the phrase and only ONE banner in this file's
// target was checked, missing a second ~140 lines away
// (`gate-verdict-census.mjs`'s own exit-2 CORPUS-UNREADABLE path). Enforcing
// a rule at one call site in a file is not enforcing it on the file. Source-
// grepping cannot close that gap either: this very file legitimately
// CONTAINS the literal string above, in its own assertion — a static scan
// cannot tell "prints it" from "mentions it". So this drives each non-gate
// reporter into its zero/failure state for real and inspects the actual
// combined stdout+stderr, case-insensitively (a literal-case-only check is
// exactly the kind of narrow match that missed site ① in the first place).
//
// The guard is ALSO its own positive control: a matcher that can only ever
// report "clean" is worthless, so it first proves it can fire at all by
// driving a REAL true-positive — `_verdict.mjs`'s own default (no
// `subject`) ran==0 path, which is SUPPOSED to say the phrase and must keep
// saying it (m23-gj does not touch that site).
console.error("\n── BEHAVIOURAL GUARD: reserved-phrase leak, driven live, not grepped ──");
{
  const RESERVED_PHRASE_RE = /asserted\s+nothing/i;
  const combined = (r) => `${r.stdout ?? ""}\n${r.stderr ?? ""}`;
  const guardDir = mkdtempSync(path.join(tmpdir(), "gate-verdict-census-selftest-guard-"));
  try {
    // ── positive control: prove the matcher DOES fire on a real gate's
    // ran==0 banner before trusting any "clean" result below. ──
    const VERDICT_MJS = path.join(SCRIPT_DIR, "gates", "_verdict.mjs");
    const posCtrlFixture = path.join(guardDir, "pos-ctrl.mjs");
    // Lives in a tmpdir, NOT scripts/gates/, so `_verdict.mjs`'s own
    // `invokingGateFile()` keying (directory must be exactly
    // scripts/gates/) returns null and `recordCoverage()` never touches the
    // real scripts/gate-corpus-baseline.json — verified by reading that
    // function before relying on it here.
    writeFileSync(
      posCtrlFixture,
      `import { verdict } from ${JSON.stringify(VERDICT_MJS)};\n` +
      `verdict({ ran: 0, failed: 0 });\n`
    );
    const pc = spawnSync("node", [posCtrlFixture], { encoding: "utf8" });
    report("positive control: verdict({ran:0,failed:0}) (no subject) exits 2", pc.status === 2, `actual status=${pc.status}`);
    report("positive control: matcher DOES fire on a real gate's ran==0 banner (④ — must stay firing)", RESERVED_PHRASE_RE.test(combined(pc)));

    // ── site ①: census vacuous mode — VC_GATES points at an empty dir, so
    // zero files are scanned and corpusNonVacuousOk is false. ──
    const emptyGatesDir = mkdtempSync(path.join(guardDir, "empty-gates-"));
    const cv = spawnSync("node", [CENSUS], {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, VC_GATES: emptyGatesDir },
    });
    report("census vacuous mode (VC_GATES=<empty dir>) exits 2", cv.status === 2, `actual status=${cv.status}`);
    report("census vacuous mode: combined output has NO case-insensitive match for the reserved phrase", !RESERVED_PHRASE_RE.test(combined(cv)));

    // ── site ②: census CORPUS-UNREADABLE mode — VC_GATES points at a path
    // that was NEVER created, so `readdirSync` THROWS (ENOENT), a different
    // codepath from the empty-but-existing directory above: an empty dir
    // returns `[]` and takes the site-① branch, it never reaches the
    // try/catch that guards site ②. This is the exact distinction whose
    // absence let site ② go unfixed at m23-gd-1 — verified live (not
    // trusted from memory) that this leg does NOT overlap the ① leg above. ──
    const neverCreatedGatesDir = path.join(guardDir, "never-created-gates-dir");
    const cu = spawnSync("node", [CENSUS], {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, VC_GATES: neverCreatedGatesDir },
    });
    report("census corpus-unreadable mode (VC_GATES=<never-created dir>) exits 2", cu.status === 2, `actual status=${cu.status}`);
    report("census corpus-unreadable mode: combined output has NO case-insensitive match for the reserved phrase", !RESERVED_PHRASE_RE.test(combined(cu)));

    // ── census dependency-failure mode — ACORN_DIR points at an empty dir.
    // Already covered case-sensitively/stderr-only by LEG A above; repeated
    // here with the SAME case-insensitive, combined-stream matcher used for
    // every other leg of this guard, for one uniform instrument. ──
    const emptyAcornDir = mkdtempSync(path.join(guardDir, "empty-acorn-"));
    const cd = spawnSync("node", [CENSUS], {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, ACORN_DIR: emptyAcornDir },
    });
    report("census dependency-failure mode (ACORN_DIR=<empty dir>) exits 3", cd.status === 3, `actual status=${cd.status}`);
    report("census dependency-failure mode: combined output has NO case-insensitive match for the reserved phrase", !RESERVED_PHRASE_RE.test(combined(cd)));

    // ── staleness reporter, no-baseline mode — STALENESS_BASELINE points at
    // a path that was never created, so it hits the "NO BASELINE" branch and
    // calls `verdict({ran:0,failed:0}, {subject:"staleness report"})`
    // (m23-gh's already-shipped fix — this leg is a live regression guard on
    // it, not a new fix). ──
    const STALENESS = path.join(SCRIPT_DIR, "gate-corpus-staleness.mjs");
    const nonexistentBaseline = path.join(guardDir, "nonexistent-baseline.json"); // deliberately never created
    const st = spawnSync("node", [STALENESS], {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, STALENESS_BASELINE: nonexistentBaseline },
    });
    report("staleness reporter no-baseline mode (STALENESS_BASELINE=<nonexistent>) exits 2", st.status === 2, `actual status=${st.status}`);
    report("staleness reporter no-baseline mode: combined output has NO case-insensitive match for the reserved phrase", !RESERVED_PHRASE_RE.test(combined(st)));

    // ── staleness reporter, corpus-unreadable mode — STALENESS_GATES points
    // at a path that was never created, hitting its OWN separate `readdirSync`
    // catch block (a different `verdict({...},{subject})` call site than the
    // no-baseline leg above). Cheap second leg on the same reporter; the
    // remaining two `subject` branches (unparseable baseline JSON,
    // valid-JSON-but-not-an-object) are NOT exercised here — see the report. ──
    const neverCreatedStalenessGates = path.join(guardDir, "never-created-staleness-gates");
    const su = spawnSync("node", [STALENESS], {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, STALENESS_GATES: neverCreatedStalenessGates },
    });
    report("staleness reporter corpus-unreadable mode (STALENESS_GATES=<never-created dir>) exits 2", su.status === 2, `actual status=${su.status}`);
    report("staleness reporter corpus-unreadable mode: combined output has NO case-insensitive match for the reserved phrase", !RESERVED_PHRASE_RE.test(combined(su)));
  } finally {
    rmSync(guardDir, { recursive: true, force: true });
  }

  // ── STATIC BACKSTOP, scoped to the census file only (m23-gj) ──────────────
  // The behavioural legs above can only cover banners we can DRIVE. The census
  // has at least one we cannot easily drive — its exit-1 "SELF-TEST FAILED"
  // banner, which needs the internal classifier to misclassify its own
  // fixtures. Enumerating banners is exactly the failure this item exists to
  // close: m23-gd-1 forbade the reserved phrase, one banner was checked, and a
  // second ~140 lines away in the SAME FILE kept printing it for a whole
  // milestone. ENFORCING A RULE AT ONE SITE IN A FILE IS NOT ENFORCING IT ON
  // THE FILE.
  //
  // So: in `gate-verdict-census.mjs`, the reserved phrase may appear ONLY on
  // comment lines — never inside a printed string literal. That is checkable
  // statically and catches any NEW banner, driveable or not.
  //
  // ⚠️ This rule is deliberately scoped to the census and NOT applied
  // tree-wide. `_verdict.mjs:315` must contain the phrase in a literal (it is
  // the TRUE POSITIVE), and this very self-test holds it in an assertion
  // literal at the `report(...)` call above. A tree-wide static scan cannot
  // separate "prints it" from "mentions it" — which is why the legs above are
  // behavioural. This backstop works only because the census has no legitimate
  // reason to print it at all.
  const censusSrc = readFileSync(CENSUS, "utf8").split("\n");
  const offenders = censusSrc
    .map((line, i) => ({ n: i + 1, line }))
    .filter(({ line }) => RESERVED_PHRASE_RE.test(line))
    .filter(({ line }) => {
      const s = line.trimStart();
      return !(s.startsWith("//") || s.startsWith("*")); // not a comment => a literal
    });
  report(
    "census source: reserved phrase appears ONLY in comments, never in a printed literal",
    offenders.length === 0,
    offenders.length ? offenders.map((o) => `line ${o.n}: ${o.line.trim().slice(0, 60)}`).join(" | ") : undefined
  );
  // Positive control for the backstop itself: the rule must be capable of
  // FIRING. A synthetic non-comment line carrying the phrase has to be caught,
  // or "0 offenders" above means nothing. (m23-gf paid for this: a positive
  // control that cannot fire is not a control.)
  const syntheticOffender = '    "\\n✘✘✘ CORPUS ASSERTED NOTHING (exit 2) — planted",';
  report(
    "census source backstop POSITIVE CONTROL: a planted non-comment line IS caught",
    RESERVED_PHRASE_RE.test(syntheticOffender) &&
      !(syntheticOffender.trimStart().startsWith("//") || syntheticOffender.trimStart().startsWith("*"))
  );
}

console.error(`\n${failures === 0 ? "✔✔✔ ALL CHECKS PASSED" : `✘✘✘ ${failures} CHECK(S) FAILED`}`);
process.exit(failures === 0 ? 0 : 1);
