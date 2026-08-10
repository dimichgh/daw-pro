#!/usr/bin/env node
// scripts/gate-corpus-staleness.mjs — m23-ep-3: a fast, pure-static reporter that
// answers a question the "make it periodic" route (the roadmap item's own
// stated method) cannot safely answer on this machine. That route is REJECTED
// this cycle, measured: 73 of the 74 non-harness gates import `_staging.mjs`
// and launch a real windowed `DAWApp` (only `m23fa3-verdict-enforcement.mjs`
// is pure-static), and there is no headless/no-audio mode anywhere in the tree
// (`DAW_HEADLESS`/`DAW_NO_AUDIO`/`DAW_STAGING` all grep empty, positive-
// controlled against `DAW_CONTROL_PORT`, which is present). A wall-clock timer
// would therefore launch a windowed DAW 73 times unattended on the machine the
// user records music on. So: no launchd plist, no cron entry, no git hook —
// this is a fast check that runs during a `/dev-cycle` a human/agent is
// already attending, not a scheduled job.
//
// ══ WHY THIS LIVES IN scripts/, NOT scripts/gates/ ═════════════════════════════
// Putting it in scripts/gates/ would (a) make it join the very corpus it
// measures on the next `gate-corpus-run.mjs` sweep, and (b) subject it to
// m23-fa-3's verdict-enforcement census — a circularity nobody wants. It stays
// pure-static and fast (<2s): no `_staging.mjs`, no port, no windowed app.
//
// ══ THE FIVE BUCKETS ════════════════════════════════════════════════════════════
//   NEVER-RUN  — gate file exists, no baseline record. NAMED ALWAYS, but
//                ADVISORY — does not count toward `failed` (see EXIT CODE).
//   DRIFTED    — record exists, but the file's sha256 no longer matches: the
//                gate changed since it last ran, so its last verdict says
//                nothing about the code sitting in the tree right now.
//   STALE      — record exists, hash matches, but `ranAt` is older than the
//                threshold (STALENESS_THRESHOLD_DAYS, default 14).
//   CURRENT    — record exists, hash matches, ran recently. The only quiet state.
//   REMOVED    — baseline record with no corresponding gate file. Reported,
//                then pruned from the baseline (unless --no-prune) — a stale
//                key for a deleted gate is noise nobody needs kept.
//
// Naming the gates is the deliverable, not the count — a count with no names
// is a line every operator learns to skip. NEVER-RUN and DRIFTED are always
// named (capped display only past ~20, and the true total is always printed
// even when capped — a silent cap is the exact shape this milestone keeps
// catching).
//
// ⚠️ NEVER-RUN IS ADVISORY, NOT FAILING (m23-ep-3 round 2). `verdict()`
// (`scripts/gates/_verdict.mjs`) is now a SECOND feed into the baseline —
// every direct `node scripts/gates/m23xx.mjs` run records its own coverage —
// but the corpus runner's bulk pass is still forbidden to run in full, so on
// day one (and for a long stretch after) most of the corpus is uncredited
// through no fault of the code under test. If NEVER-RUN failed the exit code,
// this reporter would be red almost permanently — an exit code nobody reads
// is exactly the "mechanism whose only correct state gets learned past" shape
// the periodic-timer route was rejected over. DRIFTED is the sharper signal
// (the gate's last recorded verdict is DEMONSTRABLY stale, not just absent)
// and is what actually fails. The seven `m23-fa-3`-exempted gates (owned by
// the still-open `m23-fa-4`/`m23-fa-5`) never call `verdict()` at all and so
// can NEVER leave NEVER-RUN through this route — expected, not a bug here.
//
// ══ EXIT CODE ═══════════════════════════════════════════════════════════════════
// Routed entirely through `verdict()` (scripts/gates/_verdict.mjs), imported
// directly — this file has no staging lifecycle, so no reason to go through
// `_staging.mjs`'s re-export of the same function:
//   - corpus dir unreadable, OR no baseline file, OR baseline JSON that fails
//     to parse OR parses to something that isn't a plain object (`null`, an
//     array, a string, a number) -> ran=0 -> exit 2, "this run proves
//     nothing" (the exact meaning `_verdict.mjs` already gives that code
//     elsewhere, and the SAME meaning here: without a readable baseline there
//     is nothing to compare against). Each ran=0 cause prints a DIFFERENT
//     message so an operator can tell "gates directory moved" from "never
//     initialised" from "baseline file is corrupt" apart — "no baseline at
//     all" is deliberately its own loud state, distinct from "old" (STALE,
//     which lands in `failed` -> exit 1) and distinct from "clean" (exit 0).
//     `verdict()` only offers 0/1/2, so this is the only code left to reuse,
//     on purpose.
//   - ran = total gate count, failed = DRIFTED + STALE (NEVER-RUN excluded,
//     see above). REMOVED is baseline hygiene, not corpus health, and is also
//     deliberately excluded — folding either into `failed` risks
//     `failed > ran`, which `_verdict.mjs` itself throws on (its own counters
//     would disagree with each other).
//
// ══ TESTING ═════════════════════════════════════════════════════════════════════
// STALENESS_GATES / STALENESS_BASELINE / STALENESS_THRESHOLD_DAYS override the
// three inputs so this can be exercised against scratch fixtures — per project
// law (m23-gb) this must never be tested by editing a real gate.
//
// --no-prune: report REMOVED without rewriting the baseline. Used by
// `gate-corpus-run.mjs`'s startup summary, which must be a strictly read-only,
// advisory call (see that file's own comment at the call site) — the
// standalone CLI invocation (a human/agent running this directly) still
// prunes by default, which is the brief's literal "report it, and prune it".

import { existsSync, readdirSync, readFileSync, writeFileSync, renameSync, unlinkSync } from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import { join } from "node:path";
import { verdict } from "./gates/_verdict.mjs";

const ROOT = "/Users/dsemenov/Views/daw-pro";
const GATES_DIR = process.env.STALENESS_GATES || join(ROOT, "scripts/gates");
const BASELINE_PATH = process.env.STALENESS_BASELINE || join(ROOT, "scripts/gate-corpus-baseline.json");
const THRESHOLD_DAYS = Number(process.env.STALENESS_THRESHOLD_DAYS || 14);
const CAP = 20;
const prune = !process.argv.includes("--no-prune");

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

// Same atomicity contract as `_verdict.mjs`'s own writer (m23-ep-3 round 2):
// temp-file-then-`rename()` so a process killed mid-write never leaves a
// truncated baseline for the NEXT reader (this script or `verdict()`) to trip
// over — a torn write here would otherwise land on the exact "parses as valid
// JSON but isn't an object" / "fails to parse" paths this round hardened.
function writeJSONAtomic(path, obj) {
  const tmp = `${path}.tmp-${process.pid}-${randomBytes(4).toString("hex")}`;
  writeFileSync(tmp, JSON.stringify(obj, null, 1) + "\n");
  try {
    renameSync(tmp, path);
  } catch (e) {
    try { unlinkSync(tmp); } catch { /* best effort */ }
    throw e;
  }
}

function printList(label, items) {
  console.log(`  ${label}: ${items.length}`);
  const shown = items.slice(0, CAP);
  for (const line of shown) console.log(`      ${line}`);
  if (items.length > CAP) console.log(`      … +${items.length - CAP} more (${items.length} total — list capped at ${CAP})`);
}

console.log(`── gate corpus staleness ──────────────────────────────────────`);
console.log(`  gates dir        ${GATES_DIR}`);
console.log(`  baseline         ${BASELINE_PATH}`);
console.log(`  stale threshold  ${THRESHOLD_DAYS} day(s)`);

// ── corpus dir ──────────────────────────────────────────────────────────────
let files;
try {
  files = readdirSync(GATES_DIR).filter((f) => f.endsWith(".mjs") && !f.startsWith("_")).sort();
} catch (e) {
  console.log(`\n✘✘✘ CORPUS UNREADABLE (exit 2) — could not list gates at \`${GATES_DIR}\` (${e.message}).`);
  console.log(`    This run asserted NOTHING about staleness. Check STALENESS_GATES / the gates directory.`);
  verdict({ ran: 0, failed: 0 });
}
console.log(`  total gates      ${files.length}`);

// ── baseline: "no baseline at all" is its own loud state ────────────────────
if (!existsSync(BASELINE_PATH)) {
  console.log(`\n✘✘✘ NO BASELINE (exit 2) — ${BASELINE_PATH} does not exist.`);
  console.log(`    Nothing has ever been recorded. That is a DIFFERENT state from "old" or`);
  console.log(`    "clean" and gets its own loud exit rather than reading as either. Create one`);
  console.log(`    by running the corpus runner at least once, e.g.:`);
  console.log(`        node scripts/gate-corpus-run.mjs --only=<gate-substring>`);
  console.log(`    (it upserts scripts/gate-corpus-baseline.json for every gate that ran.)`);
  verdict({ ran: 0, failed: 0 });
}

let baseline;
try {
  baseline = JSON.parse(readFileSync(BASELINE_PATH, "utf8"));
} catch (e) {
  console.log(`\n✘✘✘ NO BASELINE (exit 2) — ${BASELINE_PATH} exists but is not valid JSON (${e.message}).`);
  console.log(`    Treated the same as missing: recreate it via`);
  console.log(`        node scripts/gate-corpus-run.mjs --only=<gate-substring>`);
  verdict({ ran: 0, failed: 0 });
}
// Valid JSON that isn't a plain object — `null`, an array, a string, a
// number — is a DIFFERENT failure than a parse error but must land on the
// same loud path, not throw when the classify loop below does `baseline[f]`
// (m23-ep-3 round 2, test (c): a `null` baseline used to crash with a stack
// trace instead of reporting anything).
if (baseline === null || typeof baseline !== "object" || Array.isArray(baseline)) {
  const shape = baseline === null ? "null" : Array.isArray(baseline) ? "an array" : `a ${typeof baseline}`;
  console.log(
    `\n✘✘✘ NO BASELINE (exit 2) — ${BASELINE_PATH} parses as valid JSON but is ${shape}, ` +
    `not an object of gate records.`
  );
  console.log(`    Treated the same as missing: recreate it via`);
  console.log(`        node scripts/gate-corpus-run.mjs --only=<gate-substring>`);
  verdict({ ran: 0, failed: 0 });
}

// ── classify ─────────────────────────────────────────────────────────────────
const now = Date.now();
const thresholdMs = THRESHOLD_DAYS * 24 * 60 * 60 * 1000;
const fileSet = new Set(files);

const neverRun = [];
const drifted = [];
const stale = [];
const current = [];

for (const f of files) {
  const rec = baseline[f];
  if (!rec) { neverRun.push(f); continue; }
  const hash = sha256(readFileSync(join(GATES_DIR, f)));
  if (hash !== rec.sha256) { drifted.push(f); continue; }
  const ranAtMs = Date.parse(rec.ranAt);
  if (!Number.isFinite(ranAtMs) || now - ranAtMs > thresholdMs) {
    stale.push(`${f}  (ran ${rec.ranAt ?? "?"})`);
    continue;
  }
  current.push(f);
}

const removed = Object.keys(baseline).filter((k) => !fileSet.has(k)).sort();

printList("NEVER-RUN (advisory — named, not counted toward pass/fail)", neverRun);
printList("DRIFTED", drifted);
printList("STALE", stale);
console.log(`  CURRENT: ${current.length}`);
if (removed.length) {
  printList("REMOVED (baseline record, no matching gate file)", removed);
  if (prune) {
    const kept = { ...baseline };
    for (const k of removed) delete kept[k];
    const sorted = Object.fromEntries(Object.keys(kept).sort().map((k) => [k, kept[k]]));
    writeJSONAtomic(BASELINE_PATH, sorted);
    console.log(`      pruned ${removed.length} removed record(s) from the baseline`);
  } else {
    console.log(`      --no-prune: baseline left untouched`);
  }
}

// NEVER-RUN is advisory (named above, never counted — see the file header's
// "NEVER-RUN IS ADVISORY" section) and REMOVED is baseline hygiene, not
// corpus health (also excluded — folding either in risks failed > ran, which
// _verdict.mjs itself throws on). Only DRIFTED + STALE fail this check: both
// mean a record exists and demonstrably no longer describes reality, which
// NEVER-RUN alone does not claim.
const failed = drifted.length + stale.length;
verdict({ ran: files.length, failed });
