#!/usr/bin/env node
// m23-ep — the periodic full-corpus gate runner.
//
// WHY THIS EXISTS. Every cycle runs only the gates it touches. The one sweep that
// re-ran 27 gates it had no reason to touch found TWO already red. The corpus is
// where cross-gate interaction lives and nothing looks there.
//
// ══ THE DESIGN DECISION THAT MAKES THIS TRACTABLE ══════════════════════════════
// m23-ep's own brief warns that the corpus has NINE distinct leg/tally formats
// (`PASS x` at column 0, indented `  PASS x`, `  ok   x`, `ORCH_GATE pass=24 fail=0`,
// `38/38 legs passed`, …), so there is no single "did this gate pass" line to grep.
// TRUE — and irrelevant, because we should never have been reading stdout.
//
// THE EXIT CODE IS THE UNIVERSAL SIGNAL, and it is a real convention, measured
// across the corpus at m23-fm: exit(0) 8 sites · exit(1) 11 · exit(2) 94 · exit(3) 6
// · exit(4) 1 · exit(5) 1. `_staging.mjs` sources the 2 (LIVE-PORT refusal, build
// failure, watchdog) and `_verdict.mjs` formalises the rest:
//     0 = ran and passed · 1 = ran and failed · 2 = could not speak to its subject
// So this runner classifies on `status`, never on prose. A gate that changes its
// tally wording does not break it.
//
// ══ WHAT IT REFUSES TO DO ══════════════════════════════════════════════════════
// NO PARALLELISM. Every staging gate binds the ONE port 17695, so concurrent runs
// are mutually exclusive BY CONSTRUCTION — and m23-fa-1 measured that running them
// together does not merely serialise, it INVENTS red legs (`TIMEOUT
// debug.arrangeZoom`, `masterCapture start failed`) that then get blamed on whatever
// changed. Parallelism here would make the runner actively misleading. Port
// parameterisation is the prerequisite and it is NOT this item.
//
// ══ THE EXPECTED-FAILURE LIST IS TWO-SIDED ═════════════════════════════════════
// A runner that goes red on the first known-red gate gets ignored within a week, so
// known reds are pinned. But a stale allowlist is its own rot, so an EXPECTED RED
// THAT STARTS PASSING IS ALSO A FAILURE. Every entry carries the item id that owns
// it — an unattributed exemption is how a real regression hides.

import { readdirSync, writeFileSync, mkdirSync, existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { verdict } from "./gates/_staging.mjs";
import { parseSkipSignals } from "./gates/_skip-tally.mjs";

const ROOT = "/Users/dsemenov/Views/daw-pro";
const GATES = join(ROOT, "scripts/gates");
const OUT = process.env.CORPUS_OUT || "/tmp/daw-corpus-run";
const TIMEOUT_MS = Number(process.env.GATE_TIMEOUT_MS || 900_000);
// m23-ep-3: tree-resident by default (NOT under OUT, which defaults to /tmp
// and dies with the session — a staleness check reading a vanished baseline
// would report "never run", indistinguishable from a broken check).
// ⚠️ "tree-resident" means it lives in the repo DIRECTORY — it is deliberately
// GITIGNORED, not tracked. It is LOCAL RUN STATE: `ranAt` asserts a gate ran on
// THIS machine, so a checked-in baseline would report CURRENT on a fresh
// checkout for gates that never ran there — a false green, the exact defect
// class this milestone exists to remove. (It also rewrites on every gate run.)
// CORPUS_BASELINE exists so tests can point this at a scratch fixture instead
// of mutating the real local file (m23-gb: never test by touching real state).
const BASELINE_PATH = process.env.CORPUS_BASELINE || join(ROOT, "scripts/gate-corpus-baseline.json");

// ── staleness summary (m23-ep-3) — at the START, so a partial run announces ──
// up front what it is not covering. STRICTLY ADVISORY: the child's exit code
// is intentionally never read (no `s.status` check anywhere below) and it is
// invoked with --no-prune, so this call cannot mutate the baseline file as a
// side effect of a --only= run, and cannot change this runner's own exit code
// (`verdict({ran, failed})` at the bottom stays exactly what it was).
{
  const stalenessEnv = { ...process.env };
  if (process.env.CORPUS_BASELINE && !process.env.STALENESS_BASELINE) {
    stalenessEnv.STALENESS_BASELINE = process.env.CORPUS_BASELINE;
  }
  const s = spawnSync("node", [join(ROOT, "scripts/gate-corpus-staleness.mjs"), "--no-prune"], {
    encoding: "utf8",
    env: stalenessEnv,
  });
  process.stdout.write((s.stdout || "") + (s.stderr || ""));
  process.stdout.write("\n");
}

// ── known reds: gate -> the roadmap item that OWNS the failure ────────────────
// An entry here is a PROMISE that someone is on it. No entry without an id.
const EXPECTED_RED = {
  "m23c2-follow-playhead.mjs": "m23-eo (red 42/46 in the tree, PRE-EXISTING, cause unknown)",
  // m23-ep-2 (2026-08-10): fails "W1 allCommands still holds 173 verbs :: 174".
  // The pin is CORRECT for HEAD, not stale — measured precisely: the working
  // tree has 174 (`vc.importVoiceModel`, owner m23-di-2a, already closed, MCP
  // parity `vc_import_voice_model` present) appended at index 173, but that
  // work is UNCOMMITTED and commits in this repo are user-authorised only,
  // with no authorisation in hand. Do NOT bump the gate's pin to 174 — that
  // would encode unratified work into a tracked fixture ahead of the commit
  // that's supposed to justify it. This entry self-clears: once m23-di-2a's
  // change is committed and the gate's own pin is bumped to 174, this gate
  // starts passing and the runner's UNEXPECTED-GREEN classification will fire
  // on the stale exemption, exactly as designed.
  // ⚠️ OWNER CORRECTED at the m23-ep-2 close. This was first attributed to
  // m23-di-2a — the item that ADDED the verb — but that item is CLOSED, so the
  // list's own contract ("a PROMISE that someone is on it") would not have held:
  // a closed item cannot be on anything. m23-fx is open and owns exactly the
  // follow-up action this entry is waiting for. Attributing an exemption to the
  // item that CAUSED it, rather than to one that will CLEAR it, is how an
  // exemption outlives the condition that justified it.
  "m23t-baroperand.mjs": "m23-fx (wire pin correctly reads HEAD@173; the 174th verb, vc.importVoiceModel, from the closed m23-di-2a, is uncommitted — bump this gate's own pin AND remove this entry together, only after that commit lands)",
  // m23cf-delete-key.mjs: CLOSED at m23-ft (2026-08-10). K2's funnel conjunct
  // was rewritten (it asserted an ACTION invariant against an ARRIVAL
  // counter) and a new leg K2arrival now pins the correct post-m23-fk
  // behaviour (funnelSeq +1 across a refused key) as a permanent
  // self-explaining assertion. Measured green: pass=30 fail=0 total=30
  // skipped=3. Entry removed — see `m23cf-delete-key.mjs` K2/K2arrival for
  // the detail this comment used to carry.
};

// ── argument handling ────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const only = args.find((a) => a.startsWith("--only="))?.slice(7);
const limit = Number(args.find((a) => a.startsWith("--limit="))?.slice(8) || 0);
const dryRun = args.includes("--dry-run");
// m23-ep-2: comma-separated substrings. FOUR gates in this corpus drive a heavy
// sidecar; two of them (m17h, m18g) cold-boot ~54 GB of ACE checkpoints. Running
// them inside the bulk pass leaves every LATER gate under that memory pressure —
// which is the same contention m23-fa-1 measured INVENTING red legs. They are also
// mutually order-dependent (see below), so they are run by hand, not by this loop.
const exclude = (args.find((a) => a.startsWith("--exclude="))?.slice(10) || "")
  .split(",").map((s) => s.trim()).filter(Boolean);

const all = readdirSync(GATES)
  .filter((f) => f.endsWith(".mjs") && !f.startsWith("_"))
  .sort();
let gates = all;
if (only) gates = gates.filter((g) => g.includes(only));
if (exclude.length) gates = gates.filter((g) => !exclude.some((x) => g.includes(x)));
if (limit > 0) gates = gates.slice(0, limit);

// NO SILENT CAPS. A runner that quietly drops gates reads as "covered everything"
// when it did not — that is the blind spot m23-ep was filed about in the first place.
const dropped = all.filter((g) => !gates.includes(g));
if (dropped.length) {
  console.log(`⚠️ ${dropped.length} of ${all.length} gate(s) NOT run in this pass — this is a PARTIAL corpus:`);
  for (const g of dropped) console.log(`      skipped  ${g}`);
}

if (!gates.length) {
  console.log(`no gates matched (--only=${only ?? ""}); refusing to report success on an empty run`);
  process.exit(2);
}

mkdirSync(OUT, { recursive: true });
console.log(`corpus run — ${gates.length} gate(s), SEQUENTIAL (one staging port), timeout ${TIMEOUT_MS / 1000}s each`);
if (dryRun) {
  for (const g of gates) console.log(`  would run  ${g}${EXPECTED_RED[g] ? "   [expected red: " + EXPECTED_RED[g] + "]" : ""}`);
  console.log(`\ndry run — nothing executed, and nothing is claimed about these gates.`);
  process.exit(0);
}

// ── run ──────────────────────────────────────────────────────────────────────
const results = [];
for (const [i, g] of gates.entries()) {
  const started = process.hrtime.bigint();
  process.stdout.write(`[${i + 1}/${gates.length}] ${g} … `);
  const r = spawnSync("node", [join(GATES, g)], {
    cwd: ROOT,
    encoding: "utf8",
    timeout: TIMEOUT_MS,
    env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
  });
  const secs = Number(process.hrtime.bigint() - started) / 1e9;
  const status = r.status;
  const timedOut = r.error && r.error.code === "ETIMEDOUT";
  const log = join(OUT, g.replace(/\.mjs$/, "") + ".log");
  const text = (r.stdout || "") + (r.stderr || "");
  writeFileSync(log, text);

  const expectedRed = Object.prototype.hasOwnProperty.call(EXPECTED_RED, g);
  const green = status === 0 && !timedOut;
  let kind;
  if (timedOut) kind = "TIMEOUT";
  else if (green && expectedRed) kind = "UNEXPECTED-GREEN";   // stale allowlist — also a failure
  else if (green) kind = "PASS";
  else if (expectedRed) kind = "EXPECTED-RED";
  else kind = "FAIL";

  // m23-fv: a PARALLEL signal to `kind` above, never a substitute for it — see
  // `_skip-tally.mjs`'s header for why `verdict()`/`kind` stay exit-code-only.
  // This never affects PASS/FAIL/EXPECTED-RED/TIMEOUT classification.
  const skip = parseSkipSignals(text);

  results.push({ gate: g, status, secs: Number(secs.toFixed(1)), kind, log, skip });
  console.log(`${kind} (exit ${status ?? "—"}, ${secs.toFixed(1)}s)`);
}

// ── report ───────────────────────────────────────────────────────────────────
const by = (k) => results.filter((r) => r.kind === k);
console.log(`\n── corpus result ──────────────────────────────────────────────`);
for (const k of ["PASS", "EXPECTED-RED", "FAIL", "UNEXPECTED-GREEN", "TIMEOUT"]) {
  const rows = by(k);
  if (!rows.length) continue;
  console.log(`  ${k.padEnd(16)} ${rows.length}`);
  if (k !== "PASS") for (const r of rows) console.log(`      ${r.gate}  exit=${r.status}  ${r.log}`);
}
// ── skip coverage (m23-fv) ──────────────────────────────────────────────────
// A skip is neither a pass nor a fail (m23-az) — this block is a REPORT, not
// a new verdict input; `verdict({ran, failed})` below stays untouched (see
// `_skip-tally.mjs`'s header for the full "why not `verdict({..., skipped})`"
// reasoning — that is a decided question, not re-litigated here).
//
// ⭐ THE DENOMINATOR IS THE POINT. Only a minority of gates in this corpus
// print a skip signal at all (measured at m23-fv: 13 of 73). Reporting the
// numerator ("N legs skipped") without also saying how many gates could even
// have contributed to it is a silent cap — forbidden in this project, because
// a reader cannot tell "we measured zero more skips" from "we never looked".
// `reporting` = every gate that emits ANY skip signal, INCLUDING a gate that
// affirmatively reports zero skips (e.g. `m20e-flip-path`) — that zero is a
// measurement, not silence, and belongs in the coverage denominator below.
// `withSkips` is the strict subset that actually skipped >=1 leg — that
// narrower count is what "N across M gate(s)" means; folding the zero-skip
// reporters into it would inflate the gate count for a fixed leg total.
//
// ⚠️ A gate that DISAGREES (self-report != deduped announcements) still
// contributes `selfReported` to `totalSkipped` — the self-report is the
// authoritative number where present, and the disagreement warning below is
// what makes trusting it (loudly, visibly) acceptable rather than silent.
// Same interaction the other way: a gate self-reporting `skipped=0` while
// still emitting >0 announcement titles is EXCLUDED from `withSkips` (its
// selfReported is 0, so it fails the `> 0` filter) even though it disagrees —
// that disagreement still surfaces below, it just is not double-counted into
// the leg total.
const reporting = results.filter((r) => r.skip.reports);
const withSkips = reporting.filter((r) => (r.skip.selfReported ?? r.skip.dedupCount) > 0);
const silent = results.filter((r) => !r.skip.reports);
const totalSkipped = withSkips.reduce((sum, r) => sum + (r.skip.selfReported ?? r.skip.dedupCount), 0);
const disagreements = results.filter((r) => r.skip.disagreement);
// `dropped` (defined above, before the run loop) is EVERY gate excluded from
// this pass entirely — via --only/--exclude/--limit — and so has no `results`
// entry and no `.skip` to inspect at all. Those are UNKNOWN in exactly the
// same sense a logged-but-silent gate is unknown (m23-fv measured both
// classes across the full 73-gate corpus: 55 logged-silent + 5 not-attempted
// = 60 UNKNOWN, not zero) — folding them into "silent" would undercount the
// denominator and re-create the exact silent-cap this block exists to forbid.
const unknown = silent.length + dropped.length;
console.log(`\n── skip coverage ──────────────────────────────────────────────`);
console.log(`  skipped legs      ${totalSkipped} across ${withSkips.length} gate(s)`);
console.log(
  `      ⚠️ skip coverage: ${reporting.length} of ${all.length} gates report skip status; ` +
  `${unknown} UNKNOWN, not zero (${silent.length} logged-but-silent` +
  (dropped.length ? ` + ${dropped.length} not attempted this pass — see PARTIAL corpus warning above)` : `)`)
);
if (disagreements.length) {
  console.log(`  ⚠️⚠️ SKIP SIGNAL DISAGREEMENT — self-report and announcement count disagree for ${disagreements.length} gate(s):`);
  for (const r of disagreements) console.log(`      ${r.gate}: ${r.skip.disagreement}`);
}

writeFileSync(join(OUT, "summary.json"), JSON.stringify({ results }, null, 1));
console.log(`  logs + summary.json under ${OUT}`);

// ── baseline upsert (m23-ep-3 Part 1) ───────────────────────────────────────
// Per-gate MERGE, never a whole-run snapshot: upsert a record for every gate
// that ACTUALLY RAN this pass (`results`, never `all`); every other record —
// including ones for gates this pass never touched — is left byte-for-byte.
// That is what makes a `--only=` run of ONE gate structurally immune to
// m23-fz's clobber class (the `summary.json` write two lines up, scoped to
// `OUT`, is NOT fixed here — that stays m23-fz's own open item; see that
// item and this file's own header for why this runner doesn't touch it).
let baseline = {};
if (existsSync(BASELINE_PATH)) {
  try {
    baseline = JSON.parse(readFileSync(BASELINE_PATH, "utf8"));
  } catch (e) {
    console.log(`⚠️ could not parse existing baseline at ${BASELINE_PATH} (${e.message}) — starting a fresh one`);
    baseline = {};
  }
}
const ranAt = new Date().toISOString();
for (const r of results) {
  const sha256 = createHash("sha256").update(readFileSync(join(GATES, r.gate))).digest("hex");
  baseline[r.gate] = { kind: r.kind, secs: r.secs, sha256, ranAt };
}
const sortedBaseline = Object.fromEntries(Object.keys(baseline).sort().map((k) => [k, baseline[k]]));
writeFileSync(BASELINE_PATH, JSON.stringify(sortedBaseline, null, 1) + "\n");
console.log(`  baseline: upserted ${results.length} record(s) at ${BASELINE_PATH}`);

// UNEXPECTED-GREEN is a failure on purpose: it means the allowlist above claims a
// gate is broken when it is not, and a stale exemption hides the next real regression.
const failed = by("FAIL").length + by("TIMEOUT").length + by("UNEXPECTED-GREEN").length;
verdict({ ran: results.length, failed });
