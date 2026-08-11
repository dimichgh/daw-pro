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
import { mkdtempSync, rmSync, existsSync } from "node:fs";
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
    report("banner does NOT contain \"ASSERTED NOTHING\"", !stderr.includes("ASSERTED NOTHING"));
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

console.error(`\n${failures === 0 ? "✔✔✔ ALL CHECKS PASSED" : `✘✘✘ ${failures} CHECK(S) FAILED`}`);
process.exit(failures === 0 ? 0 : 1);
