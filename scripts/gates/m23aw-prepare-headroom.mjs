// m23-aw GATE — the AU-prepare headroom tripwire.
//
// Design: docs/research/design-m23aw-headroom-tripwire.md (§5.3, §6.1, §7.3).
//
// ══ WHY THIS LIVES OUTSIDE THE SWIFT SUITE ═════════════════════════════════
// `SoundBankHostingTests` T1's prepare wall time is ~99.98% main-actor/
// `dlsBankQueue` QUEUEING (isolated median 0.00078 s vs a loaded 30 s), so it
// is a measurement of the TEST HARNESS'S OWN AMBIENT LOAD, not of the AU.
// §2.5 of the design proves BY EXHAUSTION that no per-run `#expect` on that
// quantity has a value that is simultaneously (i) never red on an
// already-observed green-but-loaded run (49.311 s, measured) and (ii) useful
// lead before the hard 60 s `#require(.ready)` — the admissible interval is
// EMPTY. A worst-of-N statistic over a validity-checked CAMPAIGN does have a
// solution (§6.1); a single-run Swift assertion structurally cannot, so the
// statistic is re-homed here rather than "tuned" into the suite.
//
// ══ WHAT THIS GATE DOES ═════════════════════════════════════════════════════
//   1. Runs `./scripts/test.sh` N times SEQUENTIALLY (default 5; `--runs N`
//      to override; `--from-logs <dir-or-file>` to re-score an existing
//      campaign without re-running anything — this is also how `--selftest`
//      scores its five static fixtures).
//   2. Parses, from EVERY run: `[measured] GM bank prepare-to-ready wall
//      time` (`SoundBankHostingTests.swift`) and `[measured] m19-e contended
//      prepares` (`AUPrepareRenegotiationStressTests.swift`) — both extended
//      ADDITIVELY at m23-aw with a `horizon` field (the GM line also gained
//      `margin`). Reformatting EITHER prefix blinds this gate silently; Leg D
//      of `MainActorOccupancySiteTests` pins both prefixes so that cannot
//      happen quietly.
//   3. Rejects the WHOLE CAMPAIGN — not just the offending run — if ANY run
//      contains a `✘` line. `./scripts/test.sh` exits 0 on a failed run, so
//      exit status is never evidence; only `grep -c '^✘' > 0` is. Dropping
//      just the bad run and scoring the survivors would silently shrink N
//      below the statistic's design point — refusing the whole campaign is
//      the deliberate, stated choice (design §7.3).
//   4. CAMPAIGN VALIDITY leg (anti-contamination): median run wall time must
//      be <= 120 s. Measured (design): normal campaigns 93.4-101.3 s,
//      adversarial 156.7 s. A campaign run on a busy machine is not a
//      normal-population campaign and must not be scored as one. Exit 2,
//      distinct from a threshold failure (exit 1) — this is what actually
//      buys the 36 s threshold its safety: the derivation in §6.1 uses the
//      adversarial run ONLY as a same-run-channel COEFFICIENT, never as an
//      admissible campaign observation, and this leg is what enforces that
//      exclusion mechanically. ⚠️ The 120 s limit and the 36 s threshold are
//      re-derived TOGETHER (design §6.1) — loosening one without the other is
//      the same class of edit as raising the horizon.
//   5. ANTI-CIRCUMVENTION leg: the parsed `horizon` must be EXACTLY 60.0
//      seconds, on EVERY run, in BOTH printed channels (GM line AND m19-e
//      line — both read `AUHostRegistry.defaultPrepareTimeout`, so a real
//      edit to `testPrepareTimeout` moves both, and requiring agreement is
//      strictly more coverage for zero cost). If someone raises
//      `testPrepareTimeout`, the margin would silently improve and this gate
//      would go green on the forbidden move without this leg. Exit 1, and the
//      message must never be mistaken for the threshold leg's — this is
//      DESIGN'S OWN SINGLE MOST VALUABLE LEG, per §5.3.
//   6. THE THRESHOLD: worst-of-campaign GM prepare time (T1) must be
//      <= HEADROOM_LIMIT_SECONDS (36, derived `floor(60 / 1.591)`, design
//      §6.1 — re-derivation rule lives there, not here: DO NOT invent a fresh
//      constant without re-running that derivation). Exit 1.
//   7. On PASS: prints the full campaign table (population idiom) for T1, and
//      PRINTS — NEVER ASSERTS — the m19-e `max` column, so the design's §1.3
//      two-channel comparison stays reproducible from this gate's own output.
//
// ONE THRESHOLD, not two: there is no "warn" tier that exits 0. A warn tier
// that exits 0 is documentation with a shebang.
//
// ══ RE-DERIVATION RULE (design §6.1 — do not invent a fresh constant) ══════
// Re-measure T1 across >= 5 green FULL-SUITE runs (NORMAL population — never
// adversarial) plus ONE adversarial run (m23-ab-2 protocol). Recompute
// `adversarialInflation = adversarialT1 / worstNormalT1`, cross-check against
// the same ratio on the m19-e `max` column, and set
// `HEADROOM_LIMIT_SECONDS = floor(60 / adversarialInflation)`. The result
// must retain >= 1.10x headroom over the worst normal observation. If it
// cannot, STOP — do not lower the ratio and do not raise
// `AUHostRegistry.testPrepareTimeout`. That state means an ordinary loaded
// machine is inside one bad run of the horizon, and the correct response is
// load reduction (m23-aw-1) or a roadmap-approved, argued change of horizon —
// never a quiet edit to either constant below.
//
// Never touches control port 17600/17695 — pure `./scripts/test.sh` +
// text parsing, no staging app involved.
//
// Usage:
//   node scripts/gates/m23aw-prepare-headroom.mjs                # 5 runs, ~9 min — BACKGROUND THIS
//   node scripts/gates/m23aw-prepare-headroom.mjs --runs 3
//   node scripts/gates/m23aw-prepare-headroom.mjs --from-logs <dir-or-file>
//   node scripts/gates/m23aw-prepare-headroom.mjs --selftest      # scores the 5 static fixtures, no test.sh runs

import { execFileSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const GATES_DIR = path.dirname(fileURLToPath(import.meta.url));

// ── ONE HOME for these two constants (design §5.5): the Swift side owns only
// the horizon constant itself (`AUHostRegistry.testPrepareTimeout`, already
// pinned in two places); the campaign statistics below live ONLY here. ──
const HORIZON_SECONDS = 60.0;
const HEADROOM_LIMIT_SECONDS = 36; // design §6.1: floor(60 / 1.591), >= 1.10x over 30.994 measured worst
const CAMPAIGN_VALIDITY_MAX_MEDIAN_WALL_SECONDS = 120; // design §6.1: paired with the limit above, re-derive together
const DEFAULT_RUNS = 5;

const GM_LINE_RE =
  /\[measured\] GM bank prepare-to-ready wall time: ([\d.]+) seconds, horizon ([\d.]+) seconds, margin ([\d.]+)/;
const M19E_LINE_RE =
  /\[measured\] m19-e contended prepares: n=(\d+), min ([\d.]+) s, median ([\d.]+) s, p90 ([\d.]+) s, max ([\d.]+) s, under1s (\d+), horizon ([\d.]+) seconds/;
const SUMMARY_RE = /Test run with (\d+) tests? in (\d+) suites? (passed|failed) after ([\d.]+) seconds/;

// ── Parsing: a "run" boundary is the swift-testing summary line. A blob of
// text may contain MANY run blocks concatenated (the --selftest fixtures,
// each a synthetic multi-run campaign in one file) or exactly one (a live
// `./scripts/test.sh` invocation, or one file under `--from-logs <dir>`).
// The same function handles both shapes uniformly. ──
function parseRuns(text) {
  const lines = text.split("\n");
  const runs = [];
  let blockLines = [];
  for (const line of lines) {
    blockLines.push(line);
    const m = line.match(SUMMARY_RE);
    if (m) {
      const blockText = blockLines.join("\n");
      const hasRed = blockLines.some((l) => l.trim().startsWith("✘"));
      const gm = blockText.match(GM_LINE_RE);
      const m19e = blockText.match(M19E_LINE_RE);
      runs.push({
        testsCount: Number(m[1]),
        suitesCount: Number(m[2]),
        outcome: m[3],
        wallSeconds: Number(m[4]),
        hasRed,
        gmPrepareSeconds: gm ? Number(gm[1]) : null,
        gmHorizonSeconds: gm ? Number(gm[2]) : null,
        gmMargin: gm ? Number(gm[3]) : null,
        m19eMax: m19e ? Number(m19e[5]) : null,
        m19eHorizonSeconds: m19e ? Number(m19e[7]) : null,
      });
      blockLines = [];
    }
  }
  return runs;
}

function median(nums) {
  const sorted = [...nums].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function stat(arr) {
  const n = arr.length;
  const min = Math.min(...arr);
  const max = Math.max(...arr);
  const mean = arr.reduce((a, b) => a + b, 0) / n;
  const spread = min > 0 ? max / min : Infinity;
  return { n, min, max, mean, spread };
}

// ── THE SCORER — pure function over parsed runs, no I/O. This is what
// --selftest exercises directly against static fixture text, and what a real
// campaign's parsed runs are scored by too, so the two paths cannot drift. ──
function scoreCampaign(runs) {
  if (runs.length === 0) {
    return {
      code: 2,
      leg: "NO_RUNS_PARSED",
      message: "no run boundaries (\"Test run with N tests in M suites …\") were found — nothing to score.",
    };
  }

  const redRuns = runs.filter((r) => r.hasRed);
  if (redRuns.length > 0) {
    return {
      code: 2,
      leg: "RED_RUN",
      message:
        `campaign REFUSED: ${redRuns.length}/${runs.length} run(s) contained a '✘' line. ` +
        `A red run is never scored — exit status is not evidence (./scripts/test.sh exits 0 on a ` +
        `failed run); detection is grep -c '^✘' > 0. The whole campaign is refused rather than ` +
        `dropping the bad run(s) and scoring the survivors, which would silently shrink N below ` +
        `the statistic's design point.`,
    };
  }

  const missingGM = runs.filter((r) => r.gmPrepareSeconds === null);
  const missingM19e = runs.filter((r) => r.m19eMax === null);
  if (missingGM.length > 0 || missingM19e.length > 0) {
    return {
      code: 2,
      leg: "MISSING_MEASURED_LINE",
      message:
        `campaign REFUSED: ${missingGM.length}/${runs.length} run(s) had no parseable GM line and ` +
        `${missingM19e.length}/${runs.length} had no parseable m19-e line. Either the suites did not ` +
        `run (a --filter/--skip campaign is not a full-suite campaign) or a print was reformatted — ` +
        `see MainActorOccupancySiteTests Leg D, which pins both prefixes for exactly this reason.`,
    };
  }

  const wallTimes = runs.map((r) => r.wallSeconds);
  const medianWall = median(wallTimes);
  if (medianWall > CAMPAIGN_VALIDITY_MAX_MEDIAN_WALL_SECONDS) {
    return {
      code: 2,
      leg: "CAMPAIGN_INVALID_WALLTIME",
      message:
        `campaign INVALID: median full-suite wall time ${medianWall.toFixed(1)}s exceeds the ` +
        `${CAMPAIGN_VALIDITY_MAX_MEDIAN_WALL_SECONDS}s validity limit — this machine was contended ` +
        `during the campaign (design: normal campaigns read 93.4-101.3s; the m23-ab-2 adversarial ` +
        `protocol reads ~156.7s). Re-run on an otherwise-idle machine. Do NOT lower this limit to make ` +
        `a loaded run pass — it is paired with the ${HEADROOM_LIMIT_SECONDS}s threshold and the two are ` +
        `re-derived together or not at all (design §6.1).`,
    };
  }

  const badHorizon = runs.filter(
    (r) => r.gmHorizonSeconds !== HORIZON_SECONDS || r.m19eHorizonSeconds !== HORIZON_SECONDS
  );
  if (badHorizon.length > 0) {
    const seen = [...new Set(badHorizon.flatMap((r) => [r.gmHorizonSeconds, r.m19eHorizonSeconds]))];
    return {
      code: 1,
      leg: "ANTI_CIRCUMVENTION_HORIZON",
      message:
        `ANTI-CIRCUMVENTION FAILURE (this is NOT the threshold leg): the printed horizon was not ` +
        `exactly ${HORIZON_SECONDS} seconds in both channels on every run (saw: ${seen.join(", ")}). ` +
        `AUHostRegistry.testPrepareTimeout must NEVER be raised to fix a headroom-gate failure — that ` +
        `silently improves the margin and would make this gate green on the forbidden move (m23-at, ` +
        `m23-aw). If this fires, something changed the constant; revert it.`,
    };
  }

  const gmSeconds = runs.map((r) => r.gmPrepareSeconds);
  const worst = Math.max(...gmSeconds);
  if (worst > HEADROOM_LIMIT_SECONDS) {
    return {
      code: 1,
      leg: "THRESHOLD_EXCEEDED",
      message:
        `THRESHOLD FAILURE: worst-of-${runs.length} GM prepare-to-ready wall time is ${worst.toFixed(3)}s, ` +
        `over the ${HEADROOM_LIMIT_SECONDS}s campaign limit (${(worst / HEADROOM_LIMIT_SECONDS).toFixed(3)}x). ` +
        `Per m23-at/m23-aw: do NOT raise AUHostRegistry.testPrepareTimeout — that is the same move as ` +
        `raising the 10s production wall, one regime over, and both the Swift pin ` +
        `(AUPrepareTimeoutPolicyTests.testTimeoutIsSixtySeconds) and this gate's own horizon leg will ` +
        `catch it independently. The permitted response is m23-aw-1 (reduce the harness's main-actor ` +
        `load) or a roadmap-approved re-derivation of this limit per design §6.1's rule — never a bigger ` +
        `number chosen to make today's run pass.`,
    };
  }

  const gmStats = stat(gmSeconds);
  const m19eValues = runs.map((r) => r.m19eMax);
  const m19eStats = stat(m19eValues);
  return {
    code: 0,
    leg: "OK",
    message:
      `PASS: worst-of-${runs.length} T1 = ${worst.toFixed(3)}s <= ${HEADROOM_LIMIT_SECONDS}s ` +
      `(${(worst / HEADROOM_LIMIT_SECONDS).toFixed(3)}x of limit, ` +
      `${(HEADROOM_LIMIT_SECONDS / worst).toFixed(3)}x cushion). Horizon confirmed ` +
      `${HORIZON_SECONDS}s in both channels, every run. Median campaign wall ${medianWall.toFixed(1)}s ` +
      `(validity limit ${CAMPAIGN_VALIDITY_MAX_MEDIAN_WALL_SECONDS}s).`,
    stats: { gm: gmStats, m19e: m19eStats, gmRows: gmSeconds, m19eRows: m19eValues, medianWall },
  };
}

function printCampaignTable(result, runs) {
  if (!result.stats) return;
  const { gm, m19e, gmRows, m19eRows } = result.stats;
  console.log("");
  console.log("  channel                          n   min      max      mean     spread");
  console.log(
    `  T1 GM prepare (THIS campaign)    ${gm.n}   ${gm.min.toFixed(3)}   ${gm.max.toFixed(3)}   ` +
      `${gm.mean.toFixed(3)}   ${gm.spread.toFixed(3)}x`
  );
  console.log(`    rows: ${gmRows.map((v) => v.toFixed(3)).join("  ")}`);
  console.log("");
  console.log("  m19-e `max` column — RECORDED, NEVER ASSERTED (design §1.3/§5.3.6):");
  console.log(
    `    n=${m19e.n}  min ${m19e.min.toFixed(3)}  max ${m19e.max.toFixed(3)}  mean ${m19e.mean.toFixed(3)}  ` +
      `spread ${m19e.spread.toFixed(3)}x`
  );
  console.log(`    rows: ${m19eRows.map((v) => v.toFixed(3)).join("  ")}`);
}

// ── Executing a real campaign ──

function runOnce(label, logDir, index) {
  console.log(`\n── running ./scripts/test.sh (${label}) ──`);
  let output;
  try {
    output = execFileSync("./scripts/test.sh", {
      cwd: REPO_ROOT,
      encoding: "utf8",
      maxBuffer: 128 * 1024 * 1024,
    });
  } catch (err) {
    // Documented to exit 0 even on a failed run — but capture stdout/stderr
    // either way in case something upstream (a build) hard-fails.
    output = (err.stdout || "") + (err.stderr || "");
  }
  const summaryLine = output.split("\n").find((l) => l.includes("Test run with"));
  console.log(`  ${summaryLine ?? "(no summary line found — see saved log)"}`);
  if (logDir) {
    const logPath = path.join(logDir, `run-${index}.log`);
    fs.writeFileSync(logPath, output);
    console.log(`  raw log: ${logPath}`);
  }
  return output;
}

function executeCampaign(n) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const logDir = path.join(os.tmpdir(), `DAWPro-test-m23aw-campaign-${stamp}`);
  fs.mkdirSync(logDir, { recursive: true });
  console.log(`Campaign logs: ${logDir}`);
  const texts = [];
  for (let i = 1; i <= n; i++) {
    texts.push(runOnce(`run ${i} of ${n}`, logDir, i));
  }
  return texts.flatMap((t) => parseRuns(t));
}

function readRunsFromLogs(target) {
  const resolved = path.isAbsolute(target) ? target : path.join(REPO_ROOT, target);
  const st = fs.statSync(resolved);
  const files = st.isDirectory()
    ? fs
        .readdirSync(resolved)
        .filter((f) => !f.startsWith("."))
        .sort()
        .map((f) => path.join(resolved, f))
    : [resolved];
  return files.flatMap((f) => parseRuns(fs.readFileSync(f, "utf8")));
}

// ── --selftest: five static fixtures, no test.sh runs (§7.3). ──

// ⚠️ `.txt`, not `.log`: this repo's root `.gitignore` has a blanket `*.log`
// rule (real campaign/test-run logs are never meant to be committed), which
// would silently un-track these INTENTIONAL fixtures — `git status` would
// never even list them as untracked. `.txt` sidesteps that collision without
// fighting the ignore rule or force-adding.
const FIXTURES = [
  { file: "_m23aw-fixture-green.txt", expectedCode: 0, expectedLeg: "OK" },
  { file: "_m23aw-fixture-slow.txt", expectedCode: 1, expectedLeg: "THRESHOLD_EXCEEDED" },
  { file: "_m23aw-fixture-raised-horizon.txt", expectedCode: 1, expectedLeg: "ANTI_CIRCUMVENTION_HORIZON" },
  { file: "_m23aw-fixture-loaded.txt", expectedCode: 2, expectedLeg: "CAMPAIGN_INVALID_WALLTIME" },
  { file: "_m23aw-fixture-red-run.txt", expectedCode: 2, expectedLeg: "RED_RUN" },
];

function runSelftest() {
  console.log("m23-aw gate self-test — five static fixtures, no ./scripts/test.sh runs.\n");
  let allOK = true;
  const observed = [];
  for (const fixture of FIXTURES) {
    const filePath = path.join(GATES_DIR, fixture.file);
    const runs = parseRuns(fs.readFileSync(filePath, "utf8"));
    const result = scoreCampaign(runs);
    const codeOK = result.code === fixture.expectedCode;
    const legOK = result.leg === fixture.expectedLeg;
    const ok = codeOK && legOK;
    allOK = allOK && ok;
    observed.push({ file: fixture.file, code: result.code, leg: result.leg, ok });
    console.log(`${ok ? "✔" : "✘"} ${fixture.file}`);
    console.log(`    expected: exit ${fixture.expectedCode}, leg ${fixture.expectedLeg}`);
    console.log(`    observed: exit ${result.code}, leg ${result.leg}`);
    console.log(`    message:  ${result.message}`);
    if (!ok) {
      console.log(`    ⚠️ MISMATCH — the leg identifier is what §7.3 requires checking, not just the code.`);
    }
  }
  console.log(`\nobserved exit codes: ${observed.map((o) => o.code).join(", ")}`);
  console.log(allOK ? "SELFTEST PASSED — all five fixtures scored as designed." : "SELFTEST FAILED.");
  process.exit(allOK ? 0 : 1);
}

// ── Entry point ──

function main() {
  const args = process.argv.slice(2);
  if (args.includes("--selftest")) {
    runSelftest();
    return;
  }

  let runs;
  const fromLogsIdx = args.indexOf("--from-logs");
  if (fromLogsIdx !== -1) {
    const target = args[fromLogsIdx + 1];
    if (!target) {
      console.log("✘ --from-logs requires a path");
      process.exit(2);
    }
    runs = readRunsFromLogs(target);
  } else {
    const runsIdx = args.indexOf("--runs");
    const n = runsIdx !== -1 ? Number(args[runsIdx + 1]) : DEFAULT_RUNS;
    if (!Number.isInteger(n) || n < 1) {
      console.log("✘ --runs must be a positive integer");
      process.exit(2);
    }
    runs = executeCampaign(n);
  }

  const result = scoreCampaign(runs);
  console.log(`\n${result.code === 0 ? "✔" : "✘"} ${result.message}`);
  printCampaignTable(result, runs);
  console.log(result.code === 0 ? "\nGATE PASSED." : `\nGATE FAILED (leg: ${result.leg}).`);
  process.exit(result.code);
}

main();
