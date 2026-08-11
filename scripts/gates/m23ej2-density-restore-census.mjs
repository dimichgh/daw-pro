// m23-ej-2 static corpus gate — every gate that WRITES `debug.panelDensity`
// with a `mode:` must also install `panelDensityGuard` (_staging.mjs) so the
// prior gets restored. Non-harness tier: no staging, no build, no socket —
// pure source-text census, so it runs in well under a second and can gate a
// commit the way `_exitpaths.py`/`_classify.py` already do for their classes.
//
// WHY A CENSUS AND NOT JUST "wire the 27 and move on". Two gates
// (`m23ek-clipboard`, `m23ek-pianoroll-marquee`) joined the density-writing
// class during m23-ek and nothing noticed — the class grew from 25 to 27
// silently. A COUNT alone would not have caught that: it would pass equally
// whether 27 stayed 27 by coincidence or by the two joiners each dropping an
// existing wired gate. This asserts an EMPTY SYMMETRIC DIFFERENCE against a
// PINNED name list instead, so both "a new gate joined the class" and "a gate
// left it" are distinguishable failures, not a number that happens to match.
//
// FOUR SELF-INFLICTED FALSE-PASSES THIS GUARDS AGAINST (each measured against
// this very file or its neighbours before being written):
//   1. THE CENSUS MATCHES ITSELF — this file's own source contains the
//      literal string `debug.panelDensity` (in this comment, if nowhere
//      else). Excluded by name below, not by a predicate that could rot.
//   2. `_staging.mjs` NOW CONTAINS THE STRING TOO — inside `panelDensityGuard`
//      itself. Excluded because it is harness (leading `_`), same convention
//      `_exitpaths.py`/`_classify.py` already use.
//   3. COMMENTS. `m23b-piano-gutter.mjs:143` has a comment reading `debug.
//      panelDensity {panel:"pianoRoll", mode:"pro"} and never puts it back —`
//      — a naive line grep counts that as a write. A dumb `grep -c
//      "panelDensity.*mode"` across this exact corpus, run during this item's
//      own measurement, returned 63 for that reason (m23b alone reads 4
//      instead of 3); the comment-stripped count is 62. Comments are
//      stripped below before matching, for exactly this reason.
//   4. THE PIN GATE ITSELF. `m23ej-panel-density-forms.mjs` writes
//      `debug.panelDensity {mode:...}` four times, by design (it pins the
//      wire-parsing forms directly) — it already clears both its synthetic
//      probe panels on every exit path (see its own header) and is
//      deliberately EXEMPT, by name, with this comment. Not a silent
//      predicate: a future reader must be able to see why it's missing from
//      PINNED without reverse-engineering a filter.
//
// Usage: node scripts/gates/m23ej2-density-restore-census.mjs
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
// The subject of check 4. Importing `_staging.mjs` here is safe and does NOT
// launch anything: `startStaging`/`connect` are only invoked when CALLED, and
// this gate calls neither. `panelDensityGuard` takes its `call` as a parameter,
// so its whole contract is testable against a fake with no app and no socket.
// `verdict` (m23-fa-4a): this gate is NOT one of the two pure-static
// exceptions `_verdict.mjs`'s own header names (`m23aq`, `m23aw`) — it
// already imports `_staging.mjs` for `panelDensityGuard`, so it gets
// `verdict` through the same re-export, same as the other 70 staged gates.
import { panelDensityGuard, verdict } from "./_staging.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SELF = "m23ej2-density-restore-census.mjs";
const EXEMPT_BY_NAME = new Set([
  "m23ej-panel-density-forms.mjs", // the pin gate — see header note 4 above
]);

// The 27 gates measured (m23-ej-2, 2026-08-09) to write `debug.panelDensity`
// with a `mode:` and have NO restore before this item. A file entering or
// leaving this list is exactly what the symmetric-difference check below
// exists to catch — do NOT edit this list to make a red census green; widen
// or shrink it only when the CORPUS has genuinely changed, and say so.
//
// m23-ep-2 (2026-08-10) AUDIT: the first full gate-corpus baseline run found
// `m23cf-delete-key.mjs` writing `debug.panelDensity{mode:}` and NOT in this
// list — 27 -> 28. This is a stale pin, not a leak: the SAME run's check-1
// leg (`PASS every density-writing gate installs panelDensityGuard`) already
// showed it correctly wired. Added below, alphabetically, per the sort() this
// list is already declared with.
const PINNED = [
  "m17f-resize-sweep.mjs",
  "m19g-setnotes-ghost.mjs",
  "m22g-reference-panel.mjs",
  "m23a-mixer-strip-layout.mjs",
  "m23a2-insert-slot-reserve.mjs",
  "m23ag-explain-capture-origin.mjs",
  "m23ah-hint-glyphs.mjs",
  "m23ak-note-selection-drop.mjs",
  "m23ax-strip-reserves.mjs",
  "m23b-piano-gutter.mjs",
  "m23c1-offclip-cue.mjs",
  "m23c2-follow-playhead.mjs",
  "m23cf-delete-key.mjs",
  "m23e-empty-lane-create.mjs",
  "m23ek-clipboard.mjs",
  "m23ek-pianoroll-marquee.mjs",
  "m23f-arrange-drop.mjs",
  "m23g1-arrange-multiselect.mjs",
  "m23g2-group-drag.mjs",
  "m23g3-marquee.mjs",
  "m23k4b-midi-drop.mjs",
  "m23o2-guide-smoke.mjs",
  "m23r3-insert-spectrum.mjs",
  "m23r3b-live-layers.mjs",
  "m23s-insert-labels.mjs",
  "m23t-baroperand.mjs",
  "m23v-empty-lane-hint.mjs",
  "m23x-arrow-nudge.mjs",
].sort();

/** Blank line comments and block comments, keeping line count stable (ports
 * the `_exitpaths.py`/`_classify.py` `strip_comments` idiom to JS; protects
 * `ws://` from being eaten by the line-comment scan, matching `_classify.py`). */
function stripComments(src) {
  src = src.replace(/\/\*[\s\S]*?\*\//g, "");
  return src.split("\n").map((line) => {
    const guarded = line.replace(/:\/\//g, "\x00");
    const idx = guarded.indexOf("//");
    const cut = idx === -1 ? guarded : guarded.slice(0, idx);
    return cut.replace(/\x00/g, "://");
  }).join("\n");
}

// A `debug.panelDensity` call whose params object contains a `mode` key —
// either `mode: value` or the ES6 shorthand `{panel, mode}`. All real call
// sites in this corpus are single-line (verified by hand at m23-ej-2), so a
// per-line match is sufficient and does not need brace-balancing across
// lines. This alone is NOT enough to detect the class post-migration: a
// wired gate calls `guard.set(panel, mode)` instead, which contains neither
// the string `debug.panelDensity` nor a `mode:` key, so the raw-write signal
// legitimately disappears the moment a gate is correctly wired. See
// GUARD_WIRED below for the signal that persists after migration.
const MODE_WRITE = /debug\.panelDensity["'`]\s*,\s*\{[^}]*\bmode\b(?:\s*[:,}]|\s*$)/;

// The identifier a gate bound `panelDensityGuard(...)` to — covers both
// `const guard = panelDensityGuard(…)` and the deferred-assignment shape
// `let guard = null; … guard = panelDensityGuard(…);` (m23a2's TDZ-safe
// pattern for a watchdog callback declared before connect). Matching on
// `IDENT = panelDensityGuard(` alone catches both: the `const`/`let` keyword,
// if present, is not required by the pattern.
const GUARD_CTOR = /(\w+)\s*=\s*panelDensityGuard\s*\(/;

/**
 * A gate counts as WIRED only if it (a) constructs a `panelDensityGuard` and
 * (b) actually calls `.set(` AND `.restore(` on THAT SAME identifier — not
 * merely importing the helper (which would pass on a dead import) and not
 * matching some unrelated `.set(`/`.restore(` elsewhere in the file (a Map,
 * for instance) that happens to share the method name.
 */
function guardWired(code) {
  const m = GUARD_CTOR.exec(code);
  if (!m) return false;
  const ident = m[1];
  // `\??` — several gates declare `let guard = null` ahead of a watchdog
  // callback (the TDZ-safe shape) and so call `guard?.set(...)`/
  // `guard?.restore(...)` with optional chaining everywhere, not just inside
  // the watchdog itself. Both `guard.set(` and `guard?.set(` must count.
  const setRe = new RegExp(`\\b${ident}\\??\\.set\\s*\\(`);
  const restoreRe = new RegExp(`\\b${ident}\\??\\.restore\\s*\\(`);
  return setRe.test(code) && restoreRe.test(code);
}

// ── ordering check: restore() must run before ws.close() on EVERY exit path ─
// m23-ej-2 LIVE VERIFICATION (2026-08-09) found `guard.restore()` needs the
// socket OPEN — it round-trips `debug.panelDensity` over `req`/`cmd`, so a
// `ws.close()` placed first strands the write until the guard's own 3s
// internal timeout, and the restore never lands. This bit 7 of the 27 wired
// gates (m23k4b, both m23ek's, m23g2, m23g3, m23ak, m23x) at wiring time —
// ALL SEVEN passed `guardWired` above (it only proves `.set(`/`.restore(` are
// CALLED somewhere, not that they are reachable before the socket dies) and
// all seven were GREEN on their own leg counts, because the guard's failure
// is a loud `console.error`, not a thrown exception — nothing fails the run.
// This check exists so a reintroduction of the same ordering bug is a RED
// census, not a green one with a log line nobody reads.
//
// Heuristic, not a real control-flow analysis: text order approximates
// execution order for this corpus's flat async/await style (verified true for
// all 27 by hand at m23-ej-2), and a `} catch (` / `finally {` boundary resets
// the "have we seen a restore yet" flag because it starts a DIFFERENT
// execution path than whatever preceded it. `teardown()`-style wrappers
// (m23a2, m23ak, m23x) are resolved by scanning the wrapper's own body for a
// `guard?.restore(` call and, if found, treating a bare call to that
// identifier as restore-capable too.
//
// ⚠️ SELF-CAUGHT BUG WHILE WRITING THIS: an earlier version excluded only the
// wrapper's DEFINITION line from the scan, not its whole BODY. The wrapper's
// body necessarily CONTAINS `guard?.restore(` (that's how it's recognised as
// a wrapper) — so the main top-to-bottom scan hit that line first, set the
// flag true, and it stayed true for the rest of the file, including a
// `ws.close()` hundreds of lines later that hadn't executed yet at that point
// in the SOURCE. A positive-control probe (buggy teardown() shape) caught it
// before this file ever ran against the real corpus — see
// `positive-control-ordering.mjs` in the m23-ej-2 verification scratchpad.
// The fix: track each wrapper's [defLine, bodyEnd] range and skip BOTH the
// direct-restore and wrapper-call checks for every line inside it.
function findWrapperBodies(lines, guardIdent) {
  const defRe = /\basync\s+function\s+(\w+)\s*\(|(?<!async\s)\bfunction\s+(\w+)\s*\(|\b(?:const|let)\s+(\w+)\s*=\s*async\b/g;
  const defLineByIdent = new Map();
  lines.forEach((line, i) => {
    defRe.lastIndex = 0;
    let mm;
    while ((mm = defRe.exec(line))) {
      const ident = mm[1] || mm[2] || mm[3];
      if (ident) defLineByIdent.set(ident, i);
    }
  });
  const guardRestoreRe = new RegExp(`\\b${guardIdent}\\??\\.restore\\s*\\(`);
  const wrappers = [];   // { ident, defLine, bodyEnd }
  for (const [ident, defLine] of defLineByIdent) {
    if (ident === guardIdent) continue;
    let bodyEnd = Math.min(lines.length - 1, defLine + 60);
    let bodyContainsRestore = false;
    for (let i = defLine; i <= bodyEnd; i++) {
      if (i > defLine && /^\}/.test(lines[i])) { bodyEnd = i; break; }
      if (guardRestoreRe.test(lines[i])) bodyContainsRestore = true;
    }
    if (bodyContainsRestore) wrappers.push({ ident, defLine, bodyEnd });
  }
  return wrappers;
}

function orderingViolations(code, guardIdent) {
  const lines = code.split("\n");
  const wrappers = findWrapperBodies(lines, guardIdent);
  // Inclusive of `defLine` itself: a definition line like `function teardown()`
  // or `const teardown = async (` textually CONTAINS `teardown(`, which would
  // otherwise false-match the wrapper-call regex at the definition and mark
  // "restored" before the try block below it has run at all (a second
  // self-caught bug — see the header note above).
  const inWrapperBody = (i) => wrappers.some((w) => i >= w.defLine && i <= w.bodyEnd);
  const directRestoreRe = new RegExp(`\\b${guardIdent}\\??\\.restore\\s*\\(`);
  const wrapperCallRegexes = wrappers.map((w) => new RegExp(`\\b${w.ident}\\s*\\(`));
  const CLOSE_RE = /\bws\??\.close\s*\(/;
  let sawRestoreSinceBoundary = false;
  const violations = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/}\s*catch\s*\(/.test(line) || /\bfinally\s*\{/.test(line)) sawRestoreSinceBoundary = false;
    if (!inWrapperBody(i)) {
      if (directRestoreRe.test(line)) sawRestoreSinceBoundary = true;
      for (const re of wrapperCallRegexes) {
        if (re.test(line)) { sawRestoreSinceBoundary = true; break; }
      }
    }
    if (CLOSE_RE.test(line) && !sawRestoreSinceBoundary) {
      violations.push({ line: i + 1, text: line.trim() });
    }
  }
  return violations;
}

const files = readdirSync(HERE)
  .filter((f) => f.endsWith(".mjs"))
  .filter((f) => !f.startsWith("_"))
  .filter((f) => f !== SELF)
  .sort();

// Anti-vacuity: a broken glob/readdir that silently found nothing (wrong
// cwd, directory moved, extension filter typo'd) must fail LOUDLY rather
// than pass with zero violations found — a census over zero files and a
// census that found zero problems must not look the same.
if (files.length <= 20) {
  console.log(`FAIL anti-vacuity: only ${files.length} .mjs files seen under ${HERE} `
    + `(expected > 20) — the glob is almost certainly broken, not the corpus shrunk`);
  // m23-fa-4a: this genuinely IS "the census measured nothing" — a broken
  // glob means every check below never had real corpus data to run against,
  // so it maps onto verdict()'s ran==0 vacuous path. Same exit code (2) as
  // the direct process.exit(2) this replaces.
  verdict({ ran: 0, failed: 0 });
}
console.log(`filesSeen=${files.length} (> 20, anti-vacuity OK)`);

const writesDensity = [];   // files IN the class: a raw unmigrated write, OR a wired guard
const wired = [];
const unwired = [];
const orderingBad = [];   // { file, violations } — wired, but restore() unreachable before ws.close()

for (const f of files) {
  if (EXEMPT_BY_NAME.has(f)) continue;
  const raw = readFileSync(join(HERE, f), "utf8");
  const code = stripComments(raw);
  const hasRawWrite = code.split("\n").some((l) => MODE_WRITE.test(l));
  const isWired = guardWired(code);
  if (!hasRawWrite && !isWired) continue;   // not in the class at all
  writesDensity.push(f);
  if (isWired) wired.push(f);
  else unwired.push(f);
  if (isWired) {
    const ctorMatch = GUARD_CTOR.exec(code);
    const ident = ctorMatch ? ctorMatch[1] : "guard";
    const violations = orderingViolations(code, ident);
    if (violations.length) orderingBad.push({ file: f, violations });
  }
  // A file with BOTH is not a violation by itself (e.g. a bare FORM-2 read
  // alongside a guard is normal) but a raw MODE write surviving next to a
  // wired guard is worth a human's eyes — flag it, don't fail the gate over
  // it alone, since `guardWired` already proves the restore machinery exists.
  if (hasRawWrite && isWired) {
    console.log(`  NOTE ${f}: has BOTH a raw debug.panelDensity{mode:} write AND `
      + `a wired guard — confirm the raw write is intentional (e.g. a FORM-2 `
      + `read that only LOOKS like a write), not a leftover unmigrated call site`);
  }
}

console.log(`\ngates writing debug.panelDensity{mode:} (comment-stripped): ${writesDensity.length}`);
for (const f of writesDensity) {
  console.log(`  ${wired.includes(f) ? "wired  " : "UNWIRED"}  ${f}`);
}

let fail = 0;

// ── check 1: every writer is wired ──────────────────────────────────────
if (unwired.length > 0) {
  fail++;
  console.log(`\nFAIL ${unwired.length} gate(s) write debug.panelDensity{mode:} `
    + `WITHOUT panelDensityGuard: ${unwired.join(", ")}`);
} else {
  console.log(`\nPASS every density-writing gate installs panelDensityGuard`);
}

// ── check 2: the detected class is EXACTLY the pinned class ────────────
const detected = [...writesDensity].sort();
const pinnedSet = new Set(PINNED);
const detectedSet = new Set(detected);
const newlyJoined = detected.filter((f) => !pinnedSet.has(f));
const noLongerPresent = PINNED.filter((f) => !detectedSet.has(f));
if (newlyJoined.length || noLongerPresent.length) {
  fail++;
  console.log(`\nFAIL the density-writing class has DRIFTED from the pinned list of ${PINNED.length}:`);
  if (newlyJoined.length) console.log(`  NEW (write density but not in PINNED — add + wire them): ${newlyJoined.join(", ")}`);
  if (noLongerPresent.length) console.log(`  MISSING (in PINNED but no longer write density — re-check, then shrink PINNED): ${noLongerPresent.join(", ")}`);
} else {
  console.log(`PASS the density-writing class is exactly the pinned ${PINNED.length}`);
}

// ── check 3: restore() must be reachable BEFORE ws.close() on every path ───
// This is the check that would have caught the m23k4b-class bug at wiring
// time instead of at live-run time — see the header comment on
// `orderingViolations` above for exactly what it does and does not prove.
if (orderingBad.length > 0) {
  fail++;
  console.log(`\nFAIL ${orderingBad.length} wired gate(s) have a ws.close() reachable `
    + `before any guard.restore() on the same execution path — the restore write `
    + `will strand behind a closed socket and only surface as a loud console.error, `
    + `never as a failing leg:`);
  for (const { file, violations } of orderingBad) {
    for (const v of violations) console.log(`  ${file}:${v.line}  ${v.text}`);
  }
} else {
  console.log(`PASS every wired gate's guard.restore() precedes ws.close() on every path`);
}

// ── check 4: THE GUARD'S OWN CONTRACT ──────────────────────────────────────
// Checks 1-3 all verify that gates CALL the guard. None of them verifies that
// the guard WORKS. 28 gates now depend on one function (27 at m23-ej-2,
// +1 at m23-ep-2 — see the PINNED comment above), and its two load-bearing
// branches were only ever exercised incidentally, by gates that happened to
// hit them. If someone "simplifies" the read to `?.stored ?? null`, every
// gate keeps passing and all 28 restores degrade to the m23-dv-1 defect
// simultaneously — a silent no-op wearing a green run.
//
// These are PURE unit legs: `panelDensityGuard` takes the caller's `call`
// function, so a fake one exercises every branch with no app, no staging, no
// socket. That is the whole reason the helper takes `call` as a parameter.
const contract = [];
const c = (label, cond, detail) => {
  contract.push({ label, cond });
  console.log(`  ${cond ? "PASS" : "FAIL"} ${label}${detail !== undefined ? "  :: " + JSON.stringify(detail) : ""}`);
  if (!cond) fail++;
};

console.log(`\n── guard contract (pure, no staging) ──`);

/** Records every call and replies with `reply(params)`. */
function fakeCall(reply) {
  const seen = [];
  const fn = async (command, params = {}) => { seen.push({ command, params }); return reply(params); };
  fn.seen = seen;
  return fn;
}

// C1 — non-null prior is restored as a MODE write, and the prior is the one
// read at FIRST touch (not re-read later, which would read back our own write).
{
  const call = fakeCall(() => ({ result: { panel: "p", mode: "pro", stored: "pro" } }));
  const g = panelDensityGuard(call);
  await g.set("p", "simple");
  await g.set("p", "simple");          // second touch must NOT re-read
  await g.restore("c1");
  const reads = call.seen.filter((s) => !("mode" in s.params) && !("clear" in s.params));
  const last = call.seen[call.seen.length - 1];
  c("C1 prior read exactly ONCE (first touch only)", reads.length === 1, reads.length);
  c("C1 non-null prior restored as {mode: prior}", last.params.mode === "pro" && !("clear" in last.params), last.params);
}

// C2 — THE BRANCH THAT COULD NOT EXIST BEFORE ej-1: a never-set panel must be
// CLEARED, not written back as "simple". Writing the default leaves an explicit
// key where there was none, which reads as deliberate to the next gate.
{
  const call = fakeCall(() => ({ result: { panel: "p", mode: "simple", stored: null } }));
  const g = panelDensityGuard(call);
  await g.set("p", "pro");
  await g.restore("c2");
  const last = call.seen[call.seen.length - 1];
  c("C2 null prior restored with {clear:true}, NOT mode:'simple'",
    last.params.clear === true && !("mode" in last.params), last.params);
}

// C3 — THE HIGHEST-VALUE LEG. An envelope with no `stored` key anywhere must
// THROW. `stored: null` is the legitimate never-set value; "the field isn't
// there" is a broken read. If those collapse into one branch, a real prior is
// silently lost on restore — m23-dv-1, verbatim, times 27.
{
  const call = fakeCall(() => ({ ok: true, result: { panel: "p", mode: "pro" } })); // no `stored`
  const g = panelDensityGuard(call);
  let threw = null;
  try { await g.set("p", "simple"); } catch (e) { threw = e.message; }
  c("C3 a read envelope with NO 'stored' key THROWS (never treated as never-set)",
    threw !== null && /stored/.test(threw), threw ?? "DID NOT THROW");
}

// C3b — discrimination: C3 must be failing on the MISSING KEY, not on any
// falsy value. An explicit `stored: null` through the same shape must NOT throw.
{
  const call = fakeCall(() => ({ ok: true, result: { panel: "p", mode: "pro", stored: null } }));
  const g = panelDensityGuard(call);
  let threw = null;
  try { await g.set("p", "simple"); } catch (e) { threw = e.message; }
  c("C3b explicit stored:null does NOT throw (presence, not truthiness)", threw === null, threw);
}

// C4 — idempotence. Gates call restore() from the normal path AND from error
// handlers; a second call must not re-write (it would clobber a state the app
// legitimately changed after the first restore).
{
  const call = fakeCall(() => ({ result: { stored: "pro" } }));
  const g = panelDensityGuard(call);
  await g.set("p", "simple");
  await g.restore("first");
  const afterFirst = call.seen.length;
  await g.restore("second");
  c("C4 restore() is idempotent — the second call issues no further writes",
    call.seen.length === afterFirst, { afterFirst, afterSecond: call.seen.length });
}

// C5 — a per-panel failure must not abort the remaining panels. A gate touching
// three panels must not lose two of them because the first write rejected.
{
  // ⚠️ The fixture must arm ONLY for the restore phase. My first version threw
  // on "the first write", but `set()` writes too — so it blew up during setup
  // and took the whole gate down with an uncaught error instead of testing
  // anything. A fixture that fails before the thing under test runs is not a
  // failing leg, it is no leg at all.
  let restoring = false, failures = 0;
  const call = async (command, params = {}) => {
    const isWrite = "mode" in params || "clear" in params;
    if (restoring && isWrite && failures++ === 0) throw new Error("boom");
    return isWrite ? {} : { result: { stored: "pro" } };
  };
  const g = panelDensityGuard(call);
  await g.set("a", "simple"); await g.set("b", "simple"); await g.set("c", "simple");
  restoring = true;
  const r = await g.restore("c5");
  c("C5 one panel's restore failing does not abandon the other two",
    r.results.length === 3 && r.results.filter((x) => x.ok).length === 2
      && r.results.filter((x) => !x.ok).length === 1, r.results);
}

const contractPass = contract.filter((x) => x.cond).length;
console.log(`  guard contract: ${contractPass}/${contract.length}`);

console.log(`\n=== m23ej2-density-restore-census: ${wired.length}/${writesDensity.length} wired, `
  + `class drift ${(newlyJoined.length + noLongerPresent.length) === 0 ? "NONE" : "DETECTED"}, `
  + `ordering ${orderingBad.length === 0 ? "CLEAN" : "VIOLATED"}, `
  + `guard contract ${contractPass}/${contract.length} ===`);

// m23-fa-4a: `fail` already counts EXACTLY one increment per failing check —
// checks 1-3 each add at most 1 (one `fail++` per census-level assertion,
// regardless of how many files trip it) and the contract's `c()` helper adds
// at most 1 per leg — so `fail` is a true failed-count, not just a boolean,
// and matches `ran` (3 census checks + every contract leg) 1:1. This is the
// SAME mechanical mapping `m23aq-data-dir-leak.mjs` uses (legsTotal /
// legsTotal - legsPassed): no leg here has an m23aw-style pre-existing
// exit-code scheme to reconcile, so there is nothing to decide beyond the
// counts themselves.
const ran = 3 + contract.length;
verdict({ ran, failed: fail });
