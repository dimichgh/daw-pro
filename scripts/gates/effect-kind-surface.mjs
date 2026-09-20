#!/usr/bin/env node
// effect-kind-surface.mjs — every shipped effect kind must reach every surface
// that is CONTRACTUALLY a complete list of kinds.
//
// WHY THIS EXISTS (m39-i, 2026-09-19). `.djFilter` shipped and was invisible in
// three consumer-facing lists: the `sound-designer` agent's own description (the
// text that ROUTES a user to the agent that builds insert chains), that agent's
// body, and two rows of the MCP server's README. Nothing compared those lists to
// the enum. `.bassEnhancer` and `.bitCrusher` had been missing from the same
// lists since they shipped — so this is drift, not a one-off, and it had gone
// unnoticed across three separate effect kinds.
//
// ⚠️ WHY WHOLE-FILE PRESENCE AND NOT A SMARTER PROXIMITY SCAN. The first draft
// of this gate scanned a sliding window for "lines that look like a kind list"
// and reported `djFilter` missing from `ProjectDocument.swift` — which is FALSE:
// it is wired at all six sites, and the `CodingKeys` list simply wrapped across
// the window boundary. A gate whose first run cries wolf gets deleted. Whole-file
// presence cannot produce that false positive. It is deliberately weaker than a
// per-list check (adding a kind to one of a file's two lists satisfies it) and it
// is still exactly strong enough for the failure that actually happened three
// times: THE KIND NEVER REACHED THE FILE AT ALL.
//
// Exit codes: 0 pass · 1 a surface is missing a kind · 3 THE GATE COULD NOT
// TRUST ITSELF (parse or self-control failed) — 3 is NOT a pass.

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const KIND_HOME = "Sources/DAWCore/Effects.swift";

// Surfaces that are a COMPLETE list of kinds by contract. Each carries the
// reason it is on this list, because a surface with no stated reason is one a
// future reader will delete or, worse, satisfy with a drive-by mention.
const SURFACES = [
  ["claude-plugin/agents/sound-designer.md",
   "the agent that OWNS building insert chains — its description is what routes a user here"],
  // ⛔ NOT a surface, and the reason is worth keeping: this gate's first run
  // demanded all 12 kinds in `claude-plugin/skills/daw-wire-reference/SKILL.md`
  // and reported five missing. That demand was WRONG — the wire reference is 17
  // sections of TRAPS, not an enumeration, and it documents `djFilter` precisely
  // because that kind has a trap. Requiring a complete list there would have made
  // the gate demand noise. A surface belongs here only if being complete is its
  // JOB.
  ["mcp-server/README.md",
   "the MCP tool table: fx_add's kind list and fx_describe's per-kind gloss"],
  ["mcp-server/src/server.ts",
   "fx_add's kind enum and the tool descriptions an agent reads before calling it"],
  ["Sources/DAWCore/ProjectDocument.swift",
   "the HAND-WRITTEN EffectDescriptor mirror — a kind missing here is SILENT DATA LOSS on save"],
  ["Sources/DAWApp/Mixer/MixerStripView.swift",
   "addableEffectKinds — a kind missing here is invisible in the mixer's + menu"],
];

// Known-present sentinels. If the gate cannot find THESE in a surface, the
// gate's own reading is broken and it must not report an all-clear about
// anything else.
//
// ⚠️ THE SENTINEL WAS `chorus` AND IT PASSED FOR THE WRONG REASON. The wire
// reference above has no kind list at all, yet cleared the control — because
// `chorus` is ALSO the name of a song section, and line 881 says "`lo-fi` is
// Loop A/Loop B rather than verse/chorus". A control that a file passes by
// accident is not a control. Both sentinels below are camelCase or effect-only
// words with no natural-language meaning in this domain: `gate` (a noise gate,
// but also "gated", "gating"), `delay`, `reverb` and `chorus` are all unusable
// for exactly this reason.
const SENTINELS = ["saturator", "bitCrusher"];

function parseKinds() {
  const src = readFileSync(resolve(ROOT, KIND_HOME), "utf8").split("\n");
  const kinds = [];
  let inBlock = false;
  for (const line of src) {
    if (line.includes("public enum Kind: String")) { inBlock = true; continue; }
    if (!inBlock) continue;
    if (line.trim() === "}") break;
    const m = /^\s*case (\w+)\s*$/.exec(line);
    if (m) kinds.push(m[1]);
  }
  return kinds;
}

const all = parseKinds();
// `audioUnit` is a hosted plugin, not a built-in kind with a param table.
const kinds = all.filter((k) => k !== "audioUnit");

const extra = process.env.GATE_SELFTEST_EXTRA_KIND;
if (extra) kinds.push(extra);

// ---- self-control 1: the parse actually found the enum ----------------------
if (all.length < 10 || !all.includes("audioUnit") ||
    !SENTINELS.every((s) => all.includes(s))) {
  console.error(
    `SELF-CONTROL FAILED: parsed ${all.length} cases from ${KIND_HOME} ` +
    `(${all.join(", ") || "none"}). Expected >=10 including audioUnit and ` +
    `${SENTINELS.join(", ")}. ` +
    `The enum moved or its declaration changed shape — this gate scored NOTHING.`);
  process.exit(3);
}

const missing = [];
const controlFailures = [];

for (const [rel, why] of SURFACES) {
  let text;
  try {
    text = readFileSync(resolve(ROOT, rel), "utf8");
  } catch {
    controlFailures.push(`${rel}: could not be read (moved or renamed?) — ${why}`);
    continue;
  }
  const has = (k) => new RegExp(`\\b${k}\\b`).test(text);

  // ---- self-control 2: the matcher works against THIS file ------------------
  const absentSentinels = SENTINELS.filter((s) => !has(s));
  if (absentSentinels.length) {
    controlFailures.push(
      `${rel}: sentinel(s) ${absentSentinels.map((s) => `"${s}"`).join(", ")} not ` +
      `found. Either this file stopped being a complete kind list (remove it from ` +
      `SURFACES, WITH a reason) or the matcher is broken. Not scored.`);
    continue;
  }
  for (const k of kinds) if (!has(k)) missing.push({ rel, why, kind: k });
}

if (controlFailures.length) {
  console.error("SELF-CONTROL FAILED — this gate scored NOTHING:\n  " +
    controlFailures.join("\n  "));
  process.exit(3);
}

if (missing.length) {
  console.error(
    `Effect-kind surface drift: ${missing.length} missing mention(s).\n` +
    `Kinds (from ${KIND_HOME}): ${kinds.join(", ")}\n`);
  const byFile = new Map();
  for (const m of missing) {
    if (!byFile.has(m.rel)) byFile.set(m.rel, { why: m.why, kinds: [] });
    byFile.get(m.rel).kinds.push(m.kind);
  }
  for (const [rel, v] of byFile) {
    console.error(`  ${rel}`);
    console.error(`      is a complete list because: ${v.why}`);
    console.error(`      never mentions: ${v.kinds.join(", ")}`);
  }
  console.error(
    `\nA kind that ships but never reaches these files is invisible to the agent ` +
    `that would reach for it, and — for ProjectDocument.swift — is silently ` +
    `dropped when the user saves.`);
  process.exit(1);
}

console.log(
  `effect-kind-surface: OK — ${kinds.length} kinds x ${SURFACES.length} surfaces, ` +
  `sentinels ${SENTINELS.join("/")} found in all.` +
  (extra ? `  [self-test kind "${extra}" was injected and FOUND everywhere — ` +
           `that is itself a failure, see below]` : ""));
if (extra) {
  console.error(
    `\nSELF-TEST DID NOT FIRE. GATE_SELFTEST_EXTRA_KIND="${extra}" names a kind ` +
    `that should exist in no surface, yet every surface matched it. The matcher ` +
    `is too loose to detect a missing kind.`);
  process.exit(3);
}
