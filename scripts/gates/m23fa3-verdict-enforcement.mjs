// m23fa3-verdict-enforcement.mjs — THE ENFORCEMENT GATE for the ONE-home
// verdict primitive (m23-fa-3).
//
// ══ WHAT THIS ASSERTS ═══════════════════════════════════════════════════════
// m23-fa found 58 hand-rolled verdict idioms across 57 gates that all shared
// one hole: they exit 0 after running ZERO checks. m23-fa-1 built the fix
// (`verdict({ran, failed})` in `_verdict.mjs`) and m23-fa-2 migrated the bulk
// of the corpus onto it. Neither step is CHECKABLE by itself — a migration is
// a one-time act; without something that runs every pass and objects when a
// NEW gate lands without `verdict()`, the corpus drifts back exactly the way
// it accumulated 58 sites in the first place: one un-reviewed gate at a time.
// This script is that check.
//
// ══ SPEC, PER m23-ga (supersedes the original m23-fa wording) ═════════════
// Key on the ABSENCE of a `verdict()` call, never on the presence of any
// particular vacuous idiom. Presence-matching under-counted by three real
// sites before this milestone closed them (`m23p2`'s implicit fall-through
// exit 0, `m23a2`'s `teardown(code)` indirection, `m16a`'s already-equivalent
// inline `ITERS < 1` guard) — the absence formulation would have caught all
// three, and it catches every future shape nobody has thought of yet, which
// is the entire point of an ENFORCEMENT gate as opposed to a one-time sweep.
//
// ══ WHY NO PARSER ═══════════════════════════════════════════════════════════
// `scripts/gate-verdict-census.mjs` is the periodic, by-hand audit tool, and
// its own header explains why it is allowed an external `acorn` dependency:
// nothing in automation depends on it being installed. This script is the
// opposite kind of thing — it has to run unattended, every pass, as ordinary
// corpus membership, so it cannot depend on anything outside this repo
// (m23-gb: the acorn scratch install used to verify that census has already
// once vanished between cycles). An import-aware regex — which local name, if
// any, is bound to `verdict` from `./_staging.mjs` or `./_verdict.mjs`, then
// does THAT name get called — is enough for the question this gate asks
// ("does this file call the primitive"), verified against the corpus below.
// It does NOT attempt the census's VACUOUS/GUARDED classification; that is a
// harder, different question this gate does not need to answer.
//
// ══ THE EXEMPTION LIST IS A CLOSED SET THIS GATE POLICES ═══════════════════
// Each entry names the item that will CLEAR it — m23-fx's attribution law: an
// exemption's owner is the item that REMOVES it, never the one that caused
// it. If an exempt file GAINS a `verdict()` call, that is a failure too: the
// exemption has rotted and must be DELETED, not silently kept alongside a
// gate that no longer needs it — see the "ROTTED" branch below for the exact
// wording, chosen so the first person to migrate one of these six reads a
// correct gate as telling them to update THIS FILE, never as a regression in
// the gate they just fixed.
const EXEMPTIONS = {
  // m23-fa-2's six deliberately deferred gates. The last four are SIDECAR
  // gates: migrating them means running them, and running them means loading
  // models (the ACE sidecar alone holds ~75 GB while RSS reports ~1 GB) — so
  // migration was deferred rather than done blind. Owner: m23-fa-4.
  "m23aw-prepare-headroom.mjs": "m23-fa-4",
  "m23ej2-density-restore-census.mjs": "m23-fa-4",
  "m17h-generation-card.mjs": "m23-fa-4",
  "m18g-sketchpad-honesty.mjs": "m23-fa-4",
  "m23bb1-vc-stop-honesty.mjs": "m23-fa-4",
  "m23fo-conversion-stability.mjs": "m23-fa-4",
  // m16a already has EQUIVALENT protection by another route (`:205-208`,
  // `if (ITERS < 1) { … process.exit(5); }`, added at m23-fj) — it is not
  // vacuous, it just does not spell its guard as `verdict()`. Consolidating
  // it onto the one home is bookkeeping, not a bug fix. Owner: m23-fa-5.
  "m16a-poison-recipe.mjs": "m23-fa-5",
};

import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { verdict } from "./_verdict.mjs";

// Overridable for the synthetic redden leg (m23-gb's law: never edit a real
// gate to test an instrument — point the instrument at scratch fixtures
// instead). Defaults to this script's own directory, i.e. the real corpus.
const GATES = process.env.M23FA3_GATES
  || path.resolve(new URL(".", import.meta.url).pathname);

// Which local name, in ONE file's text, is bound to the `verdict` primitive
// via a static `import { verdict [as X] } from "./_staging.mjs" |
// "./_verdict.mjs"`? Mirrors `gate-verdict-census.mjs`'s `verdictImportNames`,
// minus the AST: `[^}]*` spans the multi-line import lists this corpus
// actually uses (e.g. `m23ac2c-session-lock.mjs` imports `verdict` as one
// name inside an eight-line brace list) — a negated character class matches
// newlines even without the regex `s` flag. A line-oriented tool (`grep -E`
// over this file's text one line at a time, used only to sanity-check the
// arithmetic while writing this gate) CANNOT see these at all: nine of the
// 66 real compliant files use a multi-line import list, and `grep` read each
// of them as "no match" simply because the `import` keyword and the
// `verdict` specifier never share a line. That is a property of a
// line-oriented grep, not of a single-line JS `RegExp` — this file's own
// `IMPORT_RE`, which is what actually runs, read all 66 correctly on its
// first version, because `[^}]*` was already multi-line-safe. Recorded here
// only so a future reader does not mistake a grep artifact for a defect in
// the regex this gate actually uses.
// `g` flag deliberately: a gate could split its imports across two
// statements — `import { buildOrAbort, startStaging } from "./_staging.mjs"`
// on one line, `import { verdict } from "./_verdict.mjs"` on another. A
// non-global match only ever sees the FIRST such import statement; if that
// first one happens not to carry the `verdict` specifier, a correctly
// migrated gate would be reported non-compliant despite calling the
// primitive — a false FAIL, and precisely the "a correct gate reads as a
// fresh failure" hazard this item's own roadmap entry warns about one level
// up. No real corpus file currently has this split shape (verified: this
// change does not move the 74/74 real-corpus count), so this is
// future-proofing, not a fix for an observed miss.
const IMPORT_RE = /import\s*\{([^}]*)\}\s*from\s*["'](\.\/_staging\.mjs|\.\/_verdict\.mjs)["']/g;

function verdictLocalName(text) {
  for (const m of text.matchAll(IMPORT_RE)) {
    const specs = m[1].split(",").map((s) => s.trim()).filter(Boolean);
    for (const spec of specs) {
      const [imported, local] = spec.split(/\s+as\s+/).map((s) => s.trim());
      if (imported === "verdict") return local || "verdict";
    }
  }
  return null;
}

// Strip `/* … */` and `// …` comments before ANY regex looks at a file's
// text — both the import detection and the call detection below. Found by
// the advisor reviewing this gate, with a fixture proving it (kept at
// `fa3-fixtures/scenario-e-comment-only` in the QA session that built this):
// a file that imports `verdict` in its brace list (the `m23ac2c` shape — an
// eight-line list) and mentions `verdict(` only inside a `// TODO: migrate
// onto verdict(...)` comment, never actually calling it, was reported
// COMPLIANT before this fix — a permissive false green inside the one gate
// whose entire job is refusing permissive false greens. Confirmed live: the
// fixture passed (exit 0) before this function existed, failed (exit 1,
// correctly) after.
//
// Deliberately NOT a tokenizer: the trailing-`//` strip skips a match whose
// preceding character is `:` so `"https://…"` inside a string literal
// survives (its `//` is always colon-preceded). This can still over-strip —
// e.g. a `//` inside a string that is NOT preceded by `:` would wrongly be
// treated as a comment start — but that errs toward a false FAIL (a real
// `verdict()` call gets hidden), never toward the false PASS this function
// exists to close. That asymmetry is why a heuristic is acceptable here
// where the "why no parser" note above already explains the cost of a real
// one for the corresponding question one level up.
function stripComments(text) {
  return text
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/^[ \t]*\/\/.*$/gm, " ")
    .replace(/([^:])\/\/.*$/gm, "$1");
}

function hasVerdictCall(cleanText) {
  const local = verdictLocalName(cleanText);
  if (!local) return false;
  const callRe = new RegExp(`\\b${local.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*\\(`);
  return callRe.test(cleanText);
}

// ── read the corpus — a PRE-FLIGHT abort, before any check exists, the same
// class as m23a2's own two (`:64`, `:92`): this run cannot even reach its
// subject, so it exits directly rather than through `verdict()`, which is
// reserved for a run that DID reach its subject and has an opinion about it.
let files;
try {
  files = readdirSync(GATES).filter((f) => f.endsWith(".mjs") && !f.startsWith("_")).sort();
} catch (e) {
  console.error(`GATES UNREADABLE (exit 2) — could not list \`${GATES}\`: ${e?.message ?? e}`);
  process.exit(2);
}

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}${detail ? `\n        ${detail}` : ""}`);
};

for (const file of files) {
  const text = stripComments(readFileSync(path.join(GATES, file), "utf8"));
  const called = hasVerdictCall(text);
  const owner = EXEMPTIONS[file];

  if (called && owner) {
    check(
      `${file}: exemption has ROTTED`,
      false,
      `this file now calls verdict(), so its exemption (owner ${owner}) is stale — ` +
      `delete this exemption from fa-3 (the EXEMPTIONS list in ` +
      `scripts/gates/m23fa3-verdict-enforcement.mjs). A correctly migrated gate must ` +
      `not be misread as a regression in the gate you just fixed.`
    );
  } else if (called) {
    check(`${file}: routed through verdict()`, true, null);
  } else if (owner) {
    check(`${file}: exempt, owner ${owner}`, true, `no verdict() call, and that is EXPECTED — see ${owner}`);
  } else {
    check(
      `${file}: NO verdict() call and no exemption`,
      false,
      `migrate this gate onto verdict({ran, failed}) from _staging.mjs/_verdict.mjs, or add a ` +
      `named exemption to EXEMPTIONS in this file carrying the item id that will clear it — an ` +
      `exemption with no owner is a permanent hole wearing a TODO's clothes.`
    );
  }
}

console.log(`\nm23-fa-3 verdict-enforcement gate: ${checks.filter((c) => c.ok).length}/${checks.length} compliant`);
// `ran === 0` here means "scanned zero files" (an empty or misconfigured
// GATES dir) — verdict() itself refuses that as "this run proves nothing"
// (exit 2), which is exactly the self-refuting green this gate must not
// produce (m23-gb's lesson, applied to this gate about itself — Part 2
// requirement 4: this is the one script where a zero-check green would be
// self-refuting).
verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
