// scripts/gate-baseline-write.mjs — m25-q: the ONE HOME for every write to
// scripts/gate-corpus-baseline.json (or any CORPUS_BASELINE/STALENESS_BASELINE
// override of it).
//
// ══ WHY THIS EXISTS ═══════════════════════════════════════════════════════
// The baseline is gitignored (.gitignore:43) and generated — deliberately
// NOT versioned, because tracking it would report false-CURRENT on a fresh
// checkout and churn the diff on every gate run. But that means running a
// gate OVERWRITES the only record of its prior verdict, and `git show HEAD:`
// cannot recover it: "did this gate used to pass?" becomes unanswerable
// after any run, which is exactly the question every regression triage asks
// first (m25-q, filed off `m23c2-follow-playhead.mjs`'s prior record being
// overwritten twice in one day with no way to check whether it used to be
// green).
//
// FIX: an APPEND-ONLY JSONL history file, sibling to the baseline
// (`<baseline path>.history.jsonl`) — so every existing CORPUS_BASELINE /
// STALENESS_BASELINE override redirects the history for free, no third env
// var needed, and a test pointed at a scratch baseline structurally cannot
// touch the real history either. One line per write event, JSON per line,
// NEVER rewritten or rotated by this module.
//
// ══ THREE WRITERS, NOT ONE — WHY THIS HAD TO BE ONE MODULE ═════════════════
// Three call sites mutate the baseline, and each owns DIFFERENT facts:
//   1. scripts/gates/_verdict.mjs        — every direct/spawned gate run.
//      Writes sha256+ranAt ONLY — it deliberately never writes `kind`
//      (PASS/FAIL/…): it cannot know the corpus runner's EXPECTED_RED table,
//      and recording a verdict here would be a classification the runner
//      never made. It DOES know `ran`/`failed` (verdict()'s own arguments),
//      so the history line records those even though the baseline record
//      itself does not carry them.
//   2. scripts/gate-corpus-staleness.mjs — prunes REMOVED baseline records
//      (a gate file that no longer exists). This is a DELETION, not a new
//      verdict — the history line here preserves the outgoing record
//      (whatever sha256/ranAt/kind/secs it had) before it is dropped, which
//      is the only place that data would otherwise be lost for good.
//   3. scripts/gate-corpus-run.mjs       — the bulk corpus pass. THE ONLY
//      SOURCE OF `kind` (PASS/FAIL/EXPECTED-RED/UNEXPECTED-GREEN/TIMEOUT) in
//      the entire system — `_verdict.mjs` never writes it (see above). A
//      history that only hooked writers 1 and 2 would faithfully record
//      hashes and timestamps and never once record whether a gate passed —
//      exactly the thing this item exists to preserve. This writer used to
//      be a bare top-level `writeFileSync`, not even atomic (no temp+rename)
//      — routing it through this module's `writeJSONAtomic` fixes that as a
//      side effect: a non-atomic bulk rewrite of ~94 records was a torn-file
//      hazard the other two writers were already hardened against.
//
// Each caller passes the array of history records THIS call is responsible
// for — never a snapshot of the whole baseline object, which would
// duplicate every untouched record on every single write and make the
// history unreadable within days.
//
// History append is BEST-EFFORT and NEVER THROWS. `_verdict.mjs` already
// wraps its whole call in its own try/catch (recordCoverage() must never be
// able to change a gate's own PASS/FAIL result), but `gate-corpus-
// staleness.mjs`'s prune call is BARE — an uncaught throw from history
// bookkeeping would crash the reporter over a problem that has nothing to do
// with staleness. So a failure to append is reported on stderr only and
// never affects the primary JSON write's own success/failure.
//
// The primary JSON write keeps the exact atomicity contract every existing
// caller already relied on: write to a `${pid}-${random}` temp file, then
// `renameSync` — POSIX-atomic on the same filesystem, so a process killed
// mid-write leaves the ORIGINAL baseline untouched and an orphaned temp file
// behind, never a torn live baseline.

import { writeFileSync, renameSync, unlinkSync, appendFileSync } from "node:fs";
import { randomBytes } from "node:crypto";

/** The sibling JSONL history path for a given baseline JSON path. */
export function historyPathFor(baselinePath) {
  return `${baselinePath}.history.jsonl`;
}

function appendHistory(baselinePath, records) {
  if (!records || records.length === 0) return;
  try {
    const lines = records.map((r) => JSON.stringify(r)).join("\n") + "\n";
    appendFileSync(historyPathFor(baselinePath), lines);
  } catch (e) {
    process.stderr.write(
      `⚠️ gate-baseline-write: could not append history for ${baselinePath} ` +
      `(${e.message}) — the baseline write itself is unaffected.\n`
    );
  }
}

/**
 * Atomically overwrite `path` with `obj`, then best-effort append
 * `historyRecords` (plain objects, one per gate this call is
 * recording/removing) to the sibling `.history.jsonl` file.
 *
 * The atomic write itself is NOT wrapped in try/catch here — callers that
 * need the previous "let it throw" behaviour (e.g. `_verdict.mjs`'s own
 * outer try/catch) keep it unchanged; only the history append is
 * unconditionally non-throwing (see file header).
 *
 * @param {string} path
 * @param {object} obj
 * @param {object[]} [historyRecords] - defaults to none.
 */
export function writeJSONAtomic(path, obj, historyRecords = []) {
  const tmp = `${path}.tmp-${process.pid}-${randomBytes(4).toString("hex")}`;
  writeFileSync(tmp, JSON.stringify(obj, null, 1) + "\n");
  try {
    renameSync(tmp, path);
  } catch (e) {
    try { unlinkSync(tmp); } catch { /* best effort */ }
    throw e;
  }
  appendHistory(path, historyRecords);
}
