#!/usr/bin/env node
// m23-er — census the SWIFT SETTER CALL GRAPH for the ambient panel stores.
//
// WHY THIS EXISTS. Every prior survey of "who writes the panel stores" was keyed on
// the store's own WIRE VERB (`debug.panelLayout`, `debug.panelDensity`) and therefore
// under-counted, because a STORE IS MUTATED BY VERBS THAT DO NOT BEAR ITS NAME.
// m23-dv-1 concluded "EXACTLY TWO gates left a non-default value behind" after
// surveying gates that touch `debug.panelLayout`; `m17b-arrange-zoom` leaves TWO
// non-default values and calls that verb ZERO times. It was not missed by
// carelessness — it was outside the census's definition. Three items were mis-scoped
// this way (m23-dv-1, m23-en, m23-eq), which is why this is an instrument and not a
// grep.
//
// GROUND TRUTH IS THE SETTER CALL SITE. `panelLayout.set*` / `panelDensity.set*` are
// what actually mutate persisted state; the wire verb is merely one caller among many.
//
// WHAT THIS INSTRUMENT CANNOT SEE — stated up front, because a census that hides its
// blind spots is how the last three under-counts happened:
//   (1) Reachability is computed to a bounded call depth (default 3). A setter reached
//       through a longer chain is reported as UNREACHED, not as absent.
//   (2) Dispatch through closures, protocol witnesses, or `@objc` selectors is invisible.
//   (3) It reads Swift as text, not as an AST. Comment stripping is heuristic (see
//       stripComments) — a `//` inside a string literal on a line with no other quote
//       pairing could over-strip. Every count is therefore reported alongside the raw
//       grep count so the two can be compared.
// A site this tool cannot classify lands in UNRESOLVED and is never silently dropped —
// that bucket is the whole reason the 9th verdict idiom surfaced in m23-fa-1.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = "/Users/dsemenov/Views/daw-pro";
const SRC = join(ROOT, "Sources");
const MAX_DEPTH = Number(process.env.CENSUS_DEPTH ?? 3);

// The ambient stores whose leakage changes a gate's VERDICT (m23-et's class), not
// merely its pixels. ProjectStore is deliberately excluded: it is project data the
// user owns, not ambient machine state a gate can silently inherit.
const STORES = ["panelLayout", "panelDensity", "layoutStore", "densityStore"];

// ── file walk ────────────────────────────────────────────────────────────────
function swiftFiles(dir) {
  const out = [];
  for (const e of readdirSync(dir)) {
    const p = join(dir, e);
    const st = statSync(p);
    if (st.isDirectory()) out.push(...swiftFiles(p));
    else if (e.endsWith(".swift")) out.push(p);
  }
  return out;
}

// ── comment stripping ────────────────────────────────────────────────────────
// Heuristic and deliberately conservative: only strips `//` when it is NOT preceded
// by an odd number of unescaped double quotes on that line. Block comments are
// handled with a running flag. Documented as a blind spot above.
function stripComments(text) {
  const out = [];
  let inBlock = false;
  for (const raw of text.split("\n")) {
    let line = raw;
    if (inBlock) {
      const end = line.indexOf("*/");
      if (end === -1) { out.push(""); continue; }
      line = line.slice(end + 2);
      inBlock = false;
    }
    for (;;) {
      const start = line.indexOf("/*");
      if (start === -1) break;
      const end = line.indexOf("*/", start + 2);
      if (end === -1) { line = line.slice(0, start); inBlock = true; break; }
      line = line.slice(0, start) + line.slice(end + 2);
    }
    const idx = line.indexOf("//");
    if (idx !== -1) {
      const before = line.slice(0, idx);
      const quotes = (before.match(/(?<!\\)"/g) || []).length;
      if (quotes % 2 === 0) line = before;
    }
    out.push(line);
  }
  return out;
}

// ── enclosing-function attribution ───────────────────────────────────────────
// Brace-depth tracking with a stack of (name, depthAtDeclaration). Good enough for
// this corpus's style; anything it cannot attribute becomes "<file-scope>" and is
// reported rather than dropped.
function attributeFunctions(lines) {
  const owner = new Array(lines.length).fill("<file-scope>");
  const stack = [];
  let depth = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const m = line.match(/\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)/);
    const opens = (line.match(/\{/g) || []).length;
    const closes = (line.match(/\}/g) || []).length;
    if (m) stack.push({ name: m[1], depth });
    owner[i] = stack.length ? stack[stack.length - 1].name : "<file-scope>";
    depth += opens - closes;
    while (stack.length && depth <= stack[stack.length - 1].depth) stack.pop();
  }
  return owner;
}

// ── collect ──────────────────────────────────────────────────────────────────
const files = swiftFiles(SRC);
const setterSites = [];          // {file,line,store,setter,fn}
const funcBodies = new Map();    // fn -> Set(identifiers called)
const verbHandlers = new Map();  // "debug.x" -> {file,line,fn}
let rawGrepCount = 0;

const setterRe = new RegExp(`\\b(${STORES.join("|")})\\.(set[A-Za-z0-9_]*)`, "g");

for (const f of files) {
  const text = readFileSync(f, "utf8");
  rawGrepCount += (text.match(setterRe) || []).length;
  const lines = stripComments(text);
  const owner = attributeFunctions(lines);
  const rel = relative(ROOT, f);

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    for (const m of line.matchAll(setterRe)) {
      setterSites.push({ file: rel, line: i + 1, store: m[1], setter: m[2], fn: owner[i] });
    }
    for (const m of line.matchAll(/case\s+"(debug\.[A-Za-z0-9_]+)"/g)) {
      if (!verbHandlers.has(m[1])) verbHandlers.set(m[1], { file: rel, line: i + 1, fn: owner[i] });
    }
    // crude call collection: bare identifiers followed by "("
    const fn = owner[i];
    if (!funcBodies.has(fn)) funcBodies.set(fn, new Set());
    for (const m of line.matchAll(/\b([a-z][A-Za-z0-9_]*)\s*\(/g)) funcBodies.get(fn).add(m[1]);
  }
}

// ── verb -> reachable functions, bounded depth ───────────────────────────────
// The verb's own handler body is depth 0.
function reachableFrom(startFn, maxDepth) {
  const seen = new Set([startFn]);
  let frontier = [startFn];
  for (let d = 0; d < maxDepth; d++) {
    const next = [];
    for (const fn of frontier) {
      for (const callee of funcBodies.get(fn) || []) {
        if (!seen.has(callee) && funcBodies.has(callee)) { seen.add(callee); next.push(callee); }
      }
    }
    frontier = next;
    if (!frontier.length) break;
  }
  return seen;
}

// ⚠️ ATTRIBUTION MUST FOLLOW THE CALL GRAPH, NOT LINE PROXIMITY. The first version of
// this instrument attributed a setter to "the last `case` textually above it" and
// reported that `debug.settingsState` writes EVERY slot — an artifact, caught only
// because the answer was implausibly uniform. The setters live in
// `func setPanelLayout` (DAWProApp.swift:4206), which is CALLED from :3871 inside
// `case "debug.panelLayout"`; `debug.settingsState` (:4015) merely happens to be the
// nearest preceding case. Line proximity and call reachability are different
// relations, and in a big dispatch switch they disagree almost everywhere.
//
// A verb's depth-0 callee set is the identifiers called between its `case` line and
// the next `case` line in the same file; that set is then expanded through funcBodies.
const verbCallees = new Map(); // verb -> Set(fn names reachable within MAX_DEPTH)
{
  const perFile = new Map();
  for (const [verb, h] of verbHandlers) {
    if (!perFile.has(h.file)) perFile.set(h.file, []);
    perFile.get(h.file).push({ verb, line: h.line });
  }
  for (const [file, arr] of perFile) {
    arr.sort((a, b) => a.line - b.line);
    const lines = stripComments(readFileSync(join(ROOT, file), "utf8"));
    for (let i = 0; i < arr.length; i++) {
      const from = arr[i].line;
      const to = i + 1 < arr.length ? arr[i + 1].line : Math.min(from + 60, lines.length);
      const direct = new Set();
      for (let l = from - 1; l < to - 1 && l < lines.length; l++) {
        for (const m of lines[l].matchAll(/\b([a-z][A-Za-z0-9_]*)\s*\(/g)) direct.add(m[1]);
      }
      const seen = new Set(direct);
      let frontier = [...direct];
      for (let d = 1; d < MAX_DEPTH; d++) {
        const next = [];
        for (const fn of frontier)
          for (const callee of funcBodies.get(fn) || [])
            if (!seen.has(callee) && funcBodies.has(callee)) { seen.add(callee); next.push(callee); }
        frontier = next;
        if (!frontier.length) break;
      }
      verbCallees.set(arr[i].verb, seen);
    }
  }
}

// ── classify ─────────────────────────────────────────────────────────────────
const slots = new Map(); // "store.setter" -> {viaOwnVerb:Set, viaOtherVerb:Set, unresolved:[]}
for (const s of setterSites) {
  const key = `${s.store}.${s.setter}`;
  if (!slots.has(key)) slots.set(key, { viaOwnVerb: new Set(), viaOtherVerb: new Set(), unresolved: [] });
  const rec = slots.get(key);
  const ownVerb = `debug.${s.store === "layoutStore" ? "panelLayout" : s.store === "densityStore" ? "panelDensity" : s.store}`;
  let attributed = false;
  for (const [verb, reach] of verbCallees) {
    if (!reach.has(s.fn)) continue;
    attributed = true;
    if (verb === ownVerb) rec.viaOwnVerb.add(verb); else rec.viaOtherVerb.add(verb);
  }
  if (!attributed) rec.unresolved.push(`${s.file}:${s.line} (fn ${s.fn})`);
}

// ── report ───────────────────────────────────────────────────────────────────
const rows = [...slots.entries()].sort();
let onlyOwn = 0, alsoOther = 0, unresolvedSlots = 0;
console.log(`\npanel-store writer census (m23-er) — SETTER CALL GRAPH, not wire verb\n`);
console.log(`  swift files scanned:      ${files.length}`);
console.log(`  raw grep hits (w/ comments): ${rawGrepCount}`);
console.log(`  setter sites (code only):    ${setterSites.length}`);
console.log(`  debug.* verb handlers found: ${verbHandlers.size}`);
console.log(`  call-graph depth limit:      ${MAX_DEPTH}\n`);

for (const [slot, rec] of rows) {
  const others = [...rec.viaOtherVerb].sort();
  const tag = others.length ? "⚠️  ALSO-OTHER-VERB" : "    own-verb-only  ";
  if (others.length) alsoOther++; else onlyOwn++;
  if (rec.unresolved.length) unresolvedSlots++;
  console.log(`${tag} ${slot}`);
  if (rec.viaOwnVerb.size) console.log(`      own:   ${[...rec.viaOwnVerb].join(", ")}`);
  if (others.length) console.log(`      OTHER: ${others.join(", ")}`);
  for (const u of rec.unresolved) console.log(`      UNRESOLVED: ${u}`);
}

console.log(`\n  slots writable ONLY through their own verb: ${onlyOwn}`);
console.log(`  slots ALSO writable through another verb:  ${alsoOther}   <- the m23-er class`);
console.log(`  slots with at least one UNRESOLVED site:    ${unresolvedSlots}`);
console.log(`\n  ⚠️  "unresolved" means this tool could not attribute the site to a verb —`);
console.log(`      NOT that no verb reaches it. Never read UNRESOLVED as "safe".\n`);

process.exit(0);
