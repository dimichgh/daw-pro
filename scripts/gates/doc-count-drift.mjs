#!/usr/bin/env node
// m31-j GATE — the documentation-drift tripwire.
//
// ══ WHY THIS EXISTS ════════════════════════════════════════════════════════
// `docs/ARCHITECTURE.md` carries a prose sentence stating how many control
// commands exist. That sentence has now been WRONG FIVE SEPARATE TIMES
// (168 / 171 / 175 / 183 twice), each time discovered by accident. The file
// already documents a correct recipe for re-deriving the number, and the
// fifth rot happened anyway. Its own text says why:
//
//     "the recipe only helps if someone RUNS it"
//
// That is the whole bug. A recipe is not a gate. This IS the gate.
//
// ⭐ THE GENERAL SHAPE, because it is not really about counting:
// this repo has strong gates for CODE correctness and almost none for
// REGISTRY correctness — the places where a human writes a number or a name
// that has to agree with the source. Measured on one day (2026-08-28), SIX
// live instances of the same shape were found: the MCP server process serving
// stale code, `dist/` four days behind the tree, ARCHITECTURE.md's count,
// the wire reference's count, an agent's prose promising a tool its allowlist
// withheld, and a shipped tool no agent could call. All six are
// "the record says X, the source says Y, and nothing compares them."
//
// ══ WHAT IT DOES ═══════════════════════════════════════════════════════════
//   1. Derives the command total from `Sources/DAWControl/Commands.swift` by
//      TWO INDEPENDENT ROUTES and requires them to agree:
//        (a) the `allCommands` array body, `//` comments stripped LINE BY LINE
//            first — ⚠️ a naive quoted-string count reads text out of a
//            COMMENT inside the array and returns a wrong number; this has
//            produced at least two different wrong answers historically
//            (174 and 172), so "the" trap value is not a reliable tell.
//        (b) every `rejectUnknownKeys([…], verb: "…")` site — a route that
//            never reads the array at all.
//      Disagreement, or a non-empty symmetric difference in EITHER direction,
//      is a hard failure: it means the wire and its own guard have drifted.
//   2. SELF POSITIVE-CONTROLS before trusting (a) clean run. It plants a fake
//      verb into the array body IN MEMORY and asserts the cross-check catches
//      it. ⭐ A gate that has never been shown to fail is not evidence. If the
//      control does not fire, this exits 3 WITHOUT scoring anything, because a
//      green result from a blind checker is worse than no result.
//   3. Scans the documentation files for prose stating a total, and reports
//      every claim that disagrees with the measured value.
//
// ══ WHAT IT DELIBERATELY DOES NOT DO ═══════════════════════════════════════
// It does not check the MCP TOOL count. Tools do not map 1:1 to commands
// (three call a provider directly and have no backing command), and
// `grep -c 'registerTool('` is a NAIVE COUNT THAT LIES in this repo. The real
// tool pin is MCP's own bijection test. Asserting a tool number here from a
// method I cannot defend would ship exactly the false confidence this gate
// exists to prevent. Commands are checkable; tools are pinned elsewhere.
//
// It also only reads HISTORICAL numbers as prose. A dated "RE-MEASURED …"
// trail legitimately contains old values — those are records, not claims.
// Only sentences matching the CURRENT-CLAIM patterns below are scored.
//
// ══ USAGE ══════════════════════════════════════════════════════════════════
//   node scripts/gates/doc-count-drift.mjs            # score, exit 1 on drift
//
// There is deliberately NO --selftest flag: the positive control in step 2
// runs on EVERY invocation, which is strictly stronger than an opt-in mode
// nobody remembers to use. (An earlier draft of this header advertised such a
// flag and did not implement it — the precise defect this gate exists to
// catch, committed inside the gate itself. Left recorded rather than quietly
// deleted, because that is the joke and also the lesson.)
//
// Exit codes:  0 clean · 1 documentation drift · 2 wire self-disagreement
//              3 positive control failed (nothing was scored)

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const COMMANDS_SWIFT = resolve(REPO, "Sources/DAWControl/Commands.swift");

/** Strip `//` line comments, line by line. NOT a block-comment parser: the
 *  array body uses `//` only, and a naive whole-file regex would eat `://`
 *  inside string literals such as URLs.
 *  ⚠️ ZP (2026-09-25): `Tests/DAWControlTests/ZeroParamVerbRejectionTests.swift`
 *  ports this exact function (`stripLineComments`, same split-cut-first-`//`
 *  rule) before its own two source scrapes. Keep both in sync — the whole
 *  point is that the two instruments never disagree on what counts as a
 *  comment again.
 *  GAP 2 (ZP-2, tracked, deliberately NOT fixed): the line above warns
 *  against a naive WHOLE-FILE regex eating a URL's `//` — a different risk
 *  from the one this line-by-line version still carries. This function is
 *  NOT string-literal-aware either: a `//` inside a same-line quoted string
 *  (e.g. a URL) is still cut as if it started a comment. Shared by both
 *  implementations, harmless today (no `rejectUnknownKeys` call site in
 *  Commands.swift contains such a literal), and out of scope for the ZP
 *  items that touched this file. */
const stripLineComments = (text) =>
  text.split("\n").map((l) => l.replace(/\/\/.*$/, "")).join("\n");

function measureWire(source) {
  const arrayMatch = source.match(/allCommands\s*:\s*\[(.*?)\n\s*\]/s);
  if (!arrayMatch) {
    console.error("ABORT: could not locate the `allCommands` array body.");
    console.error("       The anchor changed shape — fix this gate, do not skip it.");
    process.exit(2);
  }
  const fromArray = [...stripLineComments(arrayMatch[1]).matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  const fromVerbs = [
    ...stripLineComments(source).matchAll(
      /rejectUnknownKeys\(\s*\[[^\]]*\]\s*,\s*verb:\s*"([^"]+)"/gs
    ),
  ].map((m) => m[1]);
  const zeroParam = new Set(
    [...stripLineComments(source).matchAll(
      /rejectUnknownKeys\(\s*\[\s*\]\s*,\s*verb:\s*"([^"]+)"/g
    )].map((m) => m[1])
  );
  return { fromArray, fromVerbs, zeroParam };
}

const source = readFileSync(COMMANDS_SWIFT, "utf8");

// ── Step 2 FIRST: prove the cross-check can DETECT a discrepancy ────────────
// Deliberately ahead of scoring. A checker that cannot fail must not be
// allowed to report success.
const PLANT = '"zz.fakePlantedDocDrift",';
const anchorMatch = source.match(/\n(\s*)"[a-z]+\.[A-Za-z]+",/);
if (!anchorMatch) {
  console.error("ABORT: no anchor found to plant the positive control against.");
  process.exit(3);
}
const planted = source.replace(anchorMatch[0], `${anchorMatch[0]}\n${anchorMatch[1]}${PLANT}`);
if (planted === source) {
  console.error("ABORT: the positive-control plant did not apply — control is meaningless.");
  process.exit(3);
}
{
  const p = measureWire(planted);
  const onlyInArray = new Set(p.fromArray.filter((c) => !new Set(p.fromVerbs).has(c)));
  if (!onlyInArray.has("zz.fakePlantedDocDrift")) {
    console.error("ABORT: POSITIVE CONTROL FAILED — a planted verb was not detected.");
    console.error("       Nothing has been scored. A clean result from a blind checker");
    console.error("       is worse than no result, so this refuses to report one.");
    process.exit(3);
  }
}
console.log("positive control OK — a planted verb IS detected by the cross-check\n");

// ── Step 1: the two independent routes must agree ───────────────────────────
const { fromArray, fromVerbs, zeroParam } = measureWire(source);
const arraySet = new Set(fromArray);
const verbSet = new Set(fromVerbs);
const arrayOnly = [...arraySet].filter((c) => !verbSet.has(c)).sort();
const verbOnly = [...verbSet].filter((c) => !arraySet.has(c)).sort();

console.log(`allCommands array body    : ${fromArray.length} entries, ${fromArray.length - arraySet.size} dupes`);
console.log(`rejectUnknownKeys sites   : ${fromVerbs.length} sites,   ${fromVerbs.length - verbSet.size} dupes`);
console.log(`verbs taking NO parameters: ${zeroParam.size}`);

if (arrayOnly.length || verbOnly.length) {
  console.error("\n✘ WIRE SELF-DISAGREEMENT — the array and its own guard have drifted.");
  if (arrayOnly.length) console.error(`  advertised but UNGUARDED : ${arrayOnly.join(", ")}`);
  if (verbOnly.length) console.error(`  guarded but UNADVERTISED : ${verbOnly.join(", ")}`);
  console.error("  This is a REAL WIRE DEFECT, not a documentation problem.");
  console.error("  An advertised command with no rejectUnknownKeys accepts typo'd params silently.");
  process.exit(2);
}

const TOTAL = fromArray.length;
console.log(`\nMEASURED COMMAND TOTAL: ${TOTAL}  (both routes agree, symmetric difference empty both ways)\n`);

// ── Step 3: score the documentation ─────────────────────────────────────────
// Each pattern must capture the number in group 1. Anchored tightly enough
// that a dated historical "RE-MEASURED … 182 → 183" trail is NOT scored.
const CLAIMS = [
  { file: "docs/ARCHITECTURE.md", re: /\*\*(\d+) commands\*\* verified against/g, what: "namespace headline" },
  { file: "docs/ARCHITECTURE.md", re: /\*\*ALL (\d+) commands\*\* reject unknown/g, what: "wire-contract headline" },
  { file: "docs/ARCHITECTURE.md", re: /yields \*\*(\d+) distinct verbs/g, what: "recipe cross-check" },
  { file: "docs/ARCHITECTURE.md", re: /Of the (\d+), \*\*\d+\*\* take \*\*no\*\* parameters/g, what: "no-param denominator" },
  { file: "claude-plugin/skills/daw-wire-reference/SKILL.md", re: /\*\*(\d+) commands\*\*/g, what: "wire-reference command count" },
  // ⚠️ This entry was RE-ANCHORED 2026-08-28, hours after the gate was written,
  // because the sentence was legitimately reworded by a concurrent edit and the
  // original pattern stopped matching. That is not a flaw in either change — it
  // is the reason a MATCHED-NOTHING result is scored as FAILURE above rather
  // than skipped. A gate that silently passes when its anchor moves is worse
  // than no gate: it reports green precisely when it has gone blind. If you are
  // here because this pattern stopped matching, RE-ANCHOR IT — do not delete it
  // and do not relax it into something that matches anything.
];

let drift = 0;
for (const { file, re, what } of CLAIMS) {
  let text;
  try {
    text = readFileSync(resolve(REPO, file), "utf8");
  } catch {
    console.error(`✘ ${file} — UNREADABLE. A missing file is not a pass.`);
    drift++;
    continue;
  }
  const found = [...text.matchAll(re)];
  if (found.length === 0) {
    console.error(`✘ ${file} — pattern for "${what}" MATCHED NOTHING.`);
    console.error(`    Either the sentence was reworded or it was deleted. Both mean this`);
    console.error(`    gate is now blind to that claim, which is a failure, not a pass.`);
    drift++;
    continue;
  }
  for (const m of found) {
    const claimed = Number(m[1]);
    if (claimed !== TOTAL) {
      console.error(`✘ ${file} — ${what} claims ${claimed}, measured ${TOTAL}`);
      drift++;
    } else {
      console.log(`✔ ${file} — ${what} agrees (${claimed})`);
    }
  }
}

if (drift) {
  console.error(`\n✘ ${drift} documentation claim(s) disagree with the measured wire.`);
  console.error(`  Fix the PROSE, not this gate. The measurement above is derived from`);
  console.error(`  source by two independent routes and is positive-controlled.`);
  process.exit(1);
}
console.log("\n✔ every scored documentation claim agrees with the measured wire.");
