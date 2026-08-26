// scripts/gate-baseline-write.selftest.mjs — m25-q self-test for the shared
// baseline writer (scripts/gate-baseline-write.mjs).
//
// ⛔ DELIBERATELY NOT in scripts/gates/ — that directory is the pinned gate
// corpus (94 `.mjs`, 19 `_`-prefixed helpers + 75 real gates). This tests a
// TOOL, not a gate, and must never change that denominator.
//
// ══ WHAT THIS PROVES, AND WHY THREE LEGS ═══════════════════════════════════
// THREE call sites mutate scripts/gate-corpus-baseline.json, and each is the
// ONLY source of some fact the other two never write:
//   LEG A — scripts/gates/_verdict.mjs      — the only source of `ran`/
//           `failed` in the history (the baseline record itself never
//           carries them either — see that file's own comment for why).
//   LEG B — scripts/gate-corpus-staleness.mjs (prune path) — the only place
//           an outgoing record is preserved before deletion.
//   LEG C — scripts/gate-corpus-run.mjs      — the ONLY source of `kind`
//           (PASS/FAIL/EXPECTED-RED/UNEXPECTED-GREEN/TIMEOUT) anywhere in
//           the system. `_verdict.mjs` deliberately never writes it.
//
// Each leg's assertions are scoped to fields ONLY that writer produces
// (LEG A: `source:"verdict"` + numeric `ran`/`failed`; LEG B:
// `source:"staleness-prune"` + the preserved outgoing record; LEG C:
// `source:"corpus-run"` + a `kind` field). A version of the code that hooks
// history into only one or two of the three writers passes some legs and
// FAILS the others — that discrimination, not just "did anything get
// written", is the whole point of running all three here rather than one.
//
// Every leg redirects the baseline (and therefore the history, which is
// always the sibling `<baseline>.history.jsonl` — see `historyPathFor`) to a
// throwaway path under a fresh tmpdir. NONE of this ever touches the real
// scripts/gate-corpus-baseline.json or its history (m23-gb: never test by
// touching real state) — verified below by asserting the real baseline's
// mtime/content are unchanged across the whole run.
//
// Run: node scripts/gate-baseline-write.selftest.mjs

import { spawnSync } from "node:child_process";
import {
  mkdtempSync, rmSync, existsSync, writeFileSync, readFileSync, statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { historyPathFor } from "./gate-baseline-write.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(SCRIPT_DIR, "..");
const VERDICT_MJS = path.join(SCRIPT_DIR, "gates", "_verdict.mjs");
const STALENESS_MJS = path.join(SCRIPT_DIR, "gate-corpus-staleness.mjs");
const CORPUS_RUN_MJS = path.join(SCRIPT_DIR, "gate-corpus-run.mjs");
const REAL_BASELINE = path.join(ROOT, "scripts", "gate-corpus-baseline.json");
const REAL_HISTORY = historyPathFor(REAL_BASELINE);

// A REAL, existing, pure-static gate: no `_staging.mjs`, no port, no
// windowed app — confirmed by reading its imports (`readdirSync`,
// `readFileSync`, `path`, `verdict` from `./_verdict.mjs` only) and by
// timing a direct run at <0.3s. Must be a real file under scripts/gates/
// because `_verdict.mjs`'s `invokingGateFile()` keys on `dirname(argv[1])
// === scripts/gates` exactly — a fixture gate living anywhere else (e.g. a
// tmpdir) would make `recordCoverage()` return early and record NOTHING,
// which is why this can't be faked the way other selftests fake a gate.
const REAL_PURE_STATIC_GATE = "m23fa3-verdict-enforcement.mjs";

let failures = 0;
function report(name, ok, detail) {
  console.error(`  ${ok ? "✔" : "✘"} ${name}${detail !== undefined ? `  — ${detail}` : ""}`);
  if (!ok) failures++;
}

function readJSON(p) {
  return JSON.parse(readFileSync(p, "utf8"));
}

function readJSONL(p) {
  if (!existsSync(p)) return [];
  return readFileSync(p, "utf8")
    .split("\n")
    .filter((l) => l.trim().length > 0)
    .map((l) => JSON.parse(l));
}

function snapshotRealBaselineState() {
  return {
    baselineExisted: existsSync(REAL_BASELINE),
    baselineText: existsSync(REAL_BASELINE) ? readFileSync(REAL_BASELINE, "utf8") : null,
    historyExisted: existsSync(REAL_HISTORY),
    historyText: existsSync(REAL_HISTORY) ? readFileSync(REAL_HISTORY, "utf8") : null,
  };
}

const before = snapshotRealBaselineState();
const workDir = mkdtempSync(path.join(tmpdir(), "gate-baseline-write-selftest-"));

try {
  // ── LEG A — scripts/gates/_verdict.mjs, direct gate run ──────────────────
  console.error("── LEG A: _verdict.mjs (direct real-gate run) ──────────────────");
  {
    const baselinePath = path.join(workDir, "leg-a-baseline.json");
    const r = spawnSync("node", [path.join(SCRIPT_DIR, "gates", REAL_PURE_STATIC_GATE)], {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, CORPUS_BASELINE: baselinePath },
    });
    report("leg A: gate itself exits 0", r.status === 0, `actual status=${r.status}, stderr=${(r.stderr || "").slice(0, 300)}`);
    report("leg A: baseline file was created", existsSync(baselinePath));
    let baselineRec;
    if (existsSync(baselinePath)) {
      const baseline = readJSON(baselinePath);
      baselineRec = baseline[REAL_PURE_STATIC_GATE];
      report("leg A: baseline has a record for the gate", !!baselineRec, JSON.stringify(baseline));
      if (baselineRec) {
        report("leg A: baseline record has sha256+ranAt, NO kind (writer #1 never sets it)", typeof baselineRec.sha256 === "string" && typeof baselineRec.ranAt === "string" && baselineRec.kind === undefined, JSON.stringify(baselineRec));
      }
    }
    const lines = readJSONL(historyPathFor(baselinePath));
    const verdictLines = lines.filter((l) => l.source === "verdict" && l.gate === REAL_PURE_STATIC_GATE);
    report("leg A: history file has >=1 source:\"verdict\" line for this gate", verdictLines.length >= 1, `lines=${JSON.stringify(lines)}`);
    if (verdictLines.length) {
      const l = verdictLines[verdictLines.length - 1];
      report(
        "leg A: history line carries numeric ran/failed (the fact ONLY this writer contributes)",
        Number.isInteger(l.ran) && l.ran > 0 && Number.isInteger(l.failed) && l.failed === 0,
        JSON.stringify(l)
      );
      report("leg A: history line has NO kind field (that's writer #3's job, not this one's)", l.kind === undefined, JSON.stringify(l));
    }
  }

  // ── LEG B — scripts/gate-corpus-staleness.mjs, prune path ────────────────
  console.error("── LEG B: gate-corpus-staleness.mjs (prune path) ───────────────");
  {
    const gatesDir = mkdtempSync(path.join(workDir, "leg-b-gates-"));
    const baselinePath = path.join(workDir, "leg-b-baseline.json");
    const outgoingRecord = {
      sha256: "deadbeef00000000000000000000000000000000000000000000000000000",
      ranAt: "2020-01-01T00:00:00.000Z",
      kind: "PASS",
      secs: 1.2,
    };
    writeFileSync(baselinePath, JSON.stringify({ "fake-removed-gate.mjs": outgoingRecord }, null, 1) + "\n");
    const r = spawnSync("node", [STALENESS_MJS], {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, STALENESS_GATES: gatesDir, STALENESS_BASELINE: baselinePath },
    });
    report("leg B: staleness reporter ran (status is a number)", typeof r.status === "number", `stderr=${(r.stderr || "").slice(0, 300)}`);
    const baselineAfter = existsSync(baselinePath) ? readJSON(baselinePath) : {};
    report("leg B: the removed gate's record was pruned from the baseline", baselineAfter["fake-removed-gate.mjs"] === undefined, JSON.stringify(baselineAfter));
    const lines = readJSONL(historyPathFor(baselinePath));
    const pruneLines = lines.filter((l) => l.source === "staleness-prune" && l.gate === "fake-removed-gate.mjs");
    report("leg B: history file has exactly 1 source:\"staleness-prune\" line for the removed gate", pruneLines.length === 1, `lines=${JSON.stringify(lines)}`);
    if (pruneLines.length) {
      const l = pruneLines[0];
      report(
        "leg B: history line PRESERVES the outgoing record's own fields (sha256/ranAt/kind/secs) before deletion",
        l.sha256 === outgoingRecord.sha256 && l.ranAt === outgoingRecord.ranAt && l.kind === outgoingRecord.kind && l.secs === outgoingRecord.secs,
        JSON.stringify(l)
      );
    }
  }

  // ── LEG C — scripts/gate-corpus-run.mjs, the bulk upsert (ONLY source of `kind`) ──
  console.error("── LEG C: gate-corpus-run.mjs (bulk upsert, --only= one real gate) ──");
  {
    const baselinePath = path.join(workDir, "leg-c-baseline.json");
    const outDir = path.join(workDir, "leg-c-out");
    const r = spawnSync("node", [CORPUS_RUN_MJS, `--only=${REAL_PURE_STATIC_GATE}`], {
      cwd: ROOT,
      encoding: "utf8",
      timeout: 60_000,
      env: { ...process.env, CORPUS_BASELINE: baselinePath, CORPUS_OUT: outDir },
    });
    report("leg C: runner exits 0 for a single passing gate (--only= is not a bulk run)", r.status === 0, `actual status=${r.status}, stdout tail=${(r.stdout || "").slice(-500)}, stderr=${(r.stderr || "").slice(0, 300)}`);
    report("leg C: baseline file was created", existsSync(baselinePath));
    let baselineRec;
    if (existsSync(baselinePath)) {
      const baseline = readJSON(baselinePath);
      baselineRec = baseline[REAL_PURE_STATIC_GATE];
      report("leg C: baseline has a record for the gate", !!baselineRec, JSON.stringify(baseline));
      if (baselineRec) {
        report("leg C: baseline record has kind:\"PASS\" — the fact ONLY this writer ever sets", baselineRec.kind === "PASS", JSON.stringify(baselineRec));
        report("leg C: baseline record has a numeric secs", typeof baselineRec.secs === "number", JSON.stringify(baselineRec));
      }
    }
    const lines = readJSONL(historyPathFor(baselinePath));
    const runLines = lines.filter((l) => l.source === "corpus-run" && l.gate === REAL_PURE_STATIC_GATE);
    report("leg C: history file has >=1 source:\"corpus-run\" line for this gate", runLines.length >= 1, `lines=${JSON.stringify(lines)}`);
    if (runLines.length) {
      const l = runLines[runLines.length - 1];
      report(
        "leg C: history line carries kind:\"PASS\" — the ONE fact neither leg A nor leg B's writer can ever produce",
        l.kind === "PASS",
        JSON.stringify(l)
      );
    }
    // A version hooked into only writers #1/#2 would have written the
    // baseline via a bare, non-atomic `writeFileSync` with NO history append
    // at all — this leg's assertions above would all fail against that
    // version while legs A and B still pass, which is the discrimination
    // this self-test exists to provide.
  }

  // ── never touched the real machine state ──────────────────────────────────
  console.error("── cross-check: real baseline/history untouched by this run ────");
  const after = snapshotRealBaselineState();
  report("real baseline existence unchanged", before.baselineExisted === after.baselineExisted);
  report("real baseline content unchanged", before.baselineText === after.baselineText);
  report("real history existence unchanged", before.historyExisted === after.historyExisted);
  report("real history content unchanged", before.historyText === after.historyText);
} finally {
  rmSync(workDir, { recursive: true, force: true });
}

console.error(`\n${failures === 0 ? "VERDICT: all legs passed." : `VERDICT: ${failures} check(s) FAILED.`}`);
process.exit(failures === 0 ? 0 : 1);
