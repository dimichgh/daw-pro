// _skip-tally.mjs — the ONE home for parsing a gate log's SKIP signal (m23-fv).
//
// ══ WHY THIS EXISTS ═════════════════════════════════════════════════════════
// `gate-corpus-run.mjs` classifies every gate on EXIT CODE alone (m23-ep's own
// design decision, see that file's header) — which is correct for pass/fail
// but BLIND TO SKIPS BY CONSTRUCTION: a gate that skips 4 of its legs and
// passes the rest still exits 0, so a run reporting "65 PASS" can be quietly
// sitting on 28 unmeasured legs across 11 of those "PASS" gates. m23-az
// established that a skip is neither a pass nor a fail — a well-behaved gate
// skips LOUDLY and still exits 0 — so the fix is not a new exit code, it is a
// second, parallel signal the runner reports alongside the verdict.
//
// ══ WHY NOT `verdict({ran, failed, skipped})` — DECIDED, DO NOT RE-OPEN ═══════
// The tempting shape is threading `skipped` through `_verdict.mjs`. Rejected:
// 65 call sites would each have to either supply the count or default it, and
// a defaulted/omitted `skipped` at a gate that DOES skip reports FALSELY —
// that is a brand-new silently-wrong shape, exactly the class of bug
// `_verdict.mjs` itself exists to eliminate (see ITS header, "a gate that
// silently stopped asserting is indistinguishable from one that passed"), and
// it would need its own enforcement gate to police, the same way
// `gate-verdict-census.mjs` polices `allowEmpty`. It would also re-open
// m23-fa-2's safety argument (that the `_verdict.mjs` migration diverged from
// the pre-migration behaviour on EXACTLY ONE input, `ran === 0`) for no gain —
// widening the signature is a second divergence surface with nothing bought.
// That is strictly worse than parsing output the gates ALREADY emit truthfully
// today. So: `verdict()` stays exactly `{ran, failed}`, and this module is a
// SEPARATE, ADDITIVE report that never touches pass/fail classification.
//
// ══ THE TWO SIGNALS, AND WHY BOTH ═══════════════════════════════════════════
// Gates that skip legs say so in two independent ways, and neither alone is
// trustworthy enough to ship on its own:
//
//   1. A SELF-REPORTED TALLY — the gate's own count, in one of (at least) six
//      spellings observed live: `(2 skipped)` · `(+0 measurements, 2 skipped)`
//      · `, 4 skipped` · `skipped=3` · `(3 honest skips)` ·
//      `(9 observations, 1 skipped)`. Authoritative where present, but only 13
//      of 73 gates print one at all.
//
//   2. SKIP ANNOUNCEMENT LINES — `--  SKIP <title>` (inline) or
//      `SKIP <title>: <reason>` (trailing summary). Gates that print BOTH
//      forms for the same skip double-count under a naive line-count — the
//      first pass at this measurement got 38 where the truth is 28, caught
//      only because `m23cf-delete-key` self-reported 3 while a raw grep said
//      6. Dedup on the title UP TO THE FIRST COLON reproduces 28 exactly
//      across three independent corpora (pre-fa-2, ep-2, post-fa-2).
//
// ⭐⭐ THE CROSS-CHECK BETWEEN THE TWO SIGNALS IS THE FEATURE, NOT A NICETY.
// This whole design is "parse the prose a gate happens to print" — fragile by
// nature, and this item's own brief says so. What makes it acceptable is that
// the two signals independently corroborate each other: where a gate
// publishes both, `parseSkipSignals` compares them and flags a disagreement.
// That is not decoration — it is the exact mechanism that caught the 38-vs-28
// error above. A comparator that has never been observed to disagree is not a
// proven check (this project's own law); exercise it with a deliberately
// corrupted log before trusting it on real ones.
//
// ══ EXCLUSIONS — TWO SHAPES THAT LOOK LIKE SKIPS AND ARE NOT ═══════════════
//   • `[clip-envelope-skipped]` — a NOTICE TOKEN some gates print inline
//     (e.g. `m16a-poison-recipe`, 10x in one log). It never starts a line, so
//     the line-anchored announcement patterns below never see it. A bare
//     case-insensitive `/skip/` match would catch this and inflate the count.
//   • Prose like `PASS B5 the audio track is SKIPPED with a reason, not an
//     error` (`m23k4a-midi-export`) — a PASS line that happens to use the word
//     "skipped" while describing what it verified. It does not start with
//     `SKIP` or `--  SKIP`, so it is excluded by the same anchoring.
// Anchoring both announcement patterns to the START of the line (after
// optional leading whitespace) is what keeps both of these out without a
// denylist — a bare case-insensitive `skip` match reads 73 lines across the
// corpus where the true count is 38 raw / 28 deduped.
//
// ══ THE COVERAGE FACT — NON-NEGOTIABLE ═════════════════════════════════════
// Only 13 of 73 gates in the corpus emit ANY skip signal at all (11 report
// skipped>0, 2 — `m20e-flip-path`, `m23bp-held-note` — affirmatively report
// `skipped=0`, which STILL COUNTS AS REPORTING: the distinction between "this
// gate measured zero skips" and "this gate never measures skips" is the whole
// point). The other 60 (55 logged-but-silent + up to 5 sidecar gates with no
// log at all in an excluded pass) are UNKNOWN, not zero. Reporting "N legs
// skipped" without also stating how many gates that N could even have come
// from is a silent cap — forbidden in this project — because a reader has no
// way to tell "we measured zero more skips" from "we never looked".

/**
 * Self-reported tally formats, tried IN THIS ORDER per line (first match
 * wins, mirroring the reference measurement — order matters because some
 * later patterns are strict supersets of earlier ones on certain inputs,
 * e.g. "(9 observations, 1 skipped)" also satisfies the plain ", N skipped"
 * pattern before the more specific "observations" one is ever reached; both
 * capture the same number, so which one fires is not a behavioural
 * difference, just a documentation nicety kept for readability).
 */
const TALLY_PATTERNS = [
  /\((\d+)\s+skipped\)/, // (2 skipped)
  /\+\d+\s+measurements,\s*(\d+)\s+skipped/, // (+0 measurements, 2 skipped)
  /,\s*(\d+)\s+skipped\b/, // , 4 skipped
  /\bskipped=(\d+)/, // skipped=3
  /\((\d+)\s+honest skips?\)/, // (3 honest skips)
  /\(\d+\s+observations,\s*(\d+)\s+skipped\)/, // (9 observations, 1 skipped)
];

// Announcement lines. Anchored at line-start (after optional leading
// whitespace) on purpose — see the exclusions note above.
const ANNOUNCE_INLINE = /^\s*--\s+SKIP\s+(.*)$/; // "  --  SKIP <title>"
const ANNOUNCE_TRAILING = /^\s*SKIP\s+(.*)$/; // "SKIP <title>: <reason>"

/**
 * Parse a single gate log's text for its skip signal.
 *
 * @param {string} text the gate's full captured stdout+stderr
 * @returns {{
 *   selfReported: number | null,   // sum of every self-reported tally found, or null if the gate never prints one
 *   dedupCount: number,             // distinct SKIP announcement titles (deduped up to the first colon)
 *   titles: string[],               // those titles, for debugging/evidence
 *   reports: boolean,               // true iff this log emits ANY skip signal (a self-report of 0 counts)
 *   agree: boolean | null,          // null when there is nothing to compare (no self-report); else selfReported === dedupCount
 *   disagreement: string | null,    // human-readable mismatch description, or null
 * }}
 */
export function parseSkipSignals(text) {
  const lines = typeof text === "string" ? text.split("\n") : [];

  let selfReported = null;
  for (const line of lines) {
    for (const rx of TALLY_PATTERNS) {
      const m = line.match(rx);
      if (m) {
        selfReported = (selfReported ?? 0) + Number(m[1]);
        break; // first matching pattern per line, same as the reference measurement
      }
    }
  }

  const titles = new Set();
  for (const line of lines) {
    const inline = line.match(ANNOUNCE_INLINE);
    if (inline) {
      titles.add(inline[1].split(":")[0].trim());
      continue;
    }
    const trailing = line.match(ANNOUNCE_TRAILING);
    if (trailing) {
      titles.add(trailing[1].split(":")[0].trim());
    }
  }
  const dedupCount = titles.size;

  const reports = selfReported !== null || dedupCount > 0;

  let agree = null;
  let disagreement = null;
  if (selfReported !== null) {
    agree = selfReported === dedupCount;
    if (!agree) {
      disagreement =
        `self-reported tally says ${selfReported} skipped, but ${dedupCount} distinct ` +
        `SKIP announcement title(s) were found — these two signals should never diverge; ` +
        `treat this gate's skip count as UNTRUSTED until reconciled`;
    }
  }

  return {
    selfReported,
    dedupCount,
    titles: [...titles],
    reports,
    agree,
    disagreement,
  };
}
