#!/usr/bin/env node
// plugin-bundle-parity — the gate whose absence shipped a false capability claim.
//
// WHY THIS EXISTS (2026-09-20, law §2026-09-20s):
//   "Shipped" has TWO referents that drift apart silently: the SOURCE TREE, and the
//   ARTIFACT THE USER LOADS. Every gate we had scored the source. The released plugin
//   bundle was 4 effect kinds and 4 drum tools behind, AND its own agent prose named
//   two kinds its own bundled server rejects — so a released agent reaching for them
//   got refused. Nothing compared the agent markdown against the bundle beside it.
//
// TWO CHECKS, DELIBERATELY DIFFERENT SEVERITY:
//   A. PROSE-vs-BUNDLE (HARD FAIL) — the released sound-designer/agent docs must never
//      instruct an agent to use an effect kind the released bundle cannot add. This is
//      user-facing breakage and is a defect no matter what is queued.
//   B. BUNDLE-vs-SOURCE (REPORT) — drift here is EXPECTED between a feature landing and
//      the release, so it prints loudly and does NOT fail. Regenerating the bundle is
//      deliberately the LAST step before a commit.
//
// SELF-POSITIVE-CONTROL: this gate exits 3 WITHOUT SCORING if its own extractors come
// back empty or implausible. A parser that silently matches nothing and a codebase with
// nothing to find produce identical output — that confusion has cost this project
// repeatedly, so an unverified extractor is never allowed to report "clean".

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const ROOT = new URL("../..", import.meta.url).pathname;
// Path overrides exist ONLY so this gate can be positive-controlled against COPIES.
// A gate that can fail but has never been shown to pass is half a measurement, and
// planting into the real tree to prove it risks leaving the plant behind (which has
// already happened here once, when `set -e` killed a restore step mid-way).
const BUNDLE = process.env.PBP_BUNDLE || join(ROOT, "claude-plugin/server/index.mjs");
const SRC = process.env.PBP_SRC || join(ROOT, "mcp-server/src/server.ts");
const AGENT_DIR = process.env.PBP_AGENT_DIR || join(ROOT, "claude-plugin/agents");

const EXIT_OK = 0, EXIT_FAIL = 1, EXIT_CONTROL = 3;

function die(code, msg) {
  console.error(msg);
  process.exit(code);
}

function read(p) {
  if (!existsSync(p)) die(EXIT_CONTROL, `plugin-bundle-parity: CONTROL FAILED — missing ${p}`);
  return readFileSync(p, "utf8");
}

// The master-chain kind list is the one place both files enumerate every built-in kind.
// ⚠️ In the TS source it is a MULTI-LINE STRING CONCATENATION, so a single-line regex
// reads zero kinds and "everything is missing from src" — a broken pattern, not a
// finding. Stitch the `" +\n  "` joins out before matching.
function kindsOf(text, label) {
  const flat = text.replace(/"\s*\+\s*\n\s*"/g, "");
  const m = flat.match(/pick one of ([a-zA-Z|]+)\)/);
  if (!m) die(EXIT_CONTROL, `plugin-bundle-parity: CONTROL FAILED — no master-chain kind list in ${label}`);
  const set = new Set(m[1].split("|").filter(Boolean));
  if (set.size < 10) {
    die(EXIT_CONTROL,
      `plugin-bundle-parity: CONTROL FAILED — only ${set.size} kinds parsed from ${label}; ` +
      `the extractor is broken, not the codebase (we have shipped >=18 for months)`);
  }
  return set;
}

function toolsOf(text, label) {
  // Anchored: an unanchored /registerTool\(/ also matches prose and wrapper plumbing.
  const m = text.match(/^server\.registerTool\($/gm);
  const n = m ? m.length : 0;
  if (n < 10) {
    die(EXIT_CONTROL,
      `plugin-bundle-parity: CONTROL FAILED — ${n} anchored registerTool sites in ${label}; ` +
      `extractor broken (expected dozens)`);
  }
  return n;
}

function toolNames(text) {
  return new Set([...text.matchAll(/"(instrument_[a-z_]*drum[a-z_]*|fx_[a-z_]+)"/g)].map((x) => x[1]));
}

const bundleText = read(BUNDLE);
const srcText = read(SRC);

const bundleKinds = kindsOf(bundleText, "released bundle");
const srcKinds = kindsOf(srcText, "source");
const bundleTools = toolsOf(bundleText, "released bundle");
const srcTools = toolsOf(srcText, "source");

// ---- extractor positive control -------------------------------------------------
// Prove the kind matcher can report BOTH presence and absence, using names we know
// ship and a name we know never will. An extractor that cannot fail cannot pass.
//
// ⚠️ THE CORE SET IS NOT DECORATION — IT CAUGHT A REAL WEAKNESS IN THIS GATE.
// Checking a single sentinel ('reverb') was not enough: corrupting the enum did not
// BLIND the parser, it made it MIS-SPLIT, fusing a prefix onto the first entry. The
// set still had 18 plausible members and still contained 'reverb', so the gate sailed
// past its control and reported `eq` as "absent from the bundle" — a bundle that has
// had `eq` since day one. A mis-split is indistinguishable from a real finding unless
// you assert against names that CANNOT legitimately be missing. These six have shipped
// since the first release; if any one is absent, the PARSER is broken, not the bundle.
const CORE = ["gain", "eq", "compressor", "limiter", "reverb", "delay"];
for (const k of CORE) {
  if (!bundleKinds.has(k)) {
    die(EXIT_CONTROL,
      `plugin-bundle-parity: CONTROL FAILED — core kind '${k}' absent from the bundle's list. ` +
      `That kind has shipped since the first release, so this is a PARSER failure (likely a ` +
      `mis-split of the enum), not a finding. Refusing to score.`);
  }
  if (!srcKinds.has(k)) {
    die(EXIT_CONTROL,
      `plugin-bundle-parity: CONTROL FAILED — core kind '${k}' absent from the SOURCE list; extractor broken.`);
  }
}
if (bundleKinds.has("definitelyNotAnEffectKind")) {
  die(EXIT_CONTROL, "plugin-bundle-parity: CONTROL FAILED — matcher reports a nonexistent kind as present");
}

// ---- CHECK A: released prose must not name a kind the released bundle rejects ----
if (!existsSync(AGENT_DIR)) die(EXIT_CONTROL, `plugin-bundle-parity: CONTROL FAILED — missing ${AGENT_DIR}`);
const agentFiles = readdirSync(AGENT_DIR).filter((f) => f.endsWith(".md"));
if (agentFiles.length === 0) {
  die(EXIT_CONTROL, "plugin-bundle-parity: CONTROL FAILED — no agent .md files found to score");
}

const violations = [];
let proseKindMentions = 0;
for (const f of agentFiles) {
  const text = readFileSync(join(AGENT_DIR, f), "utf8");
  for (const kind of srcKinds) {
    // Only count a DELIBERATE reference: the kind name in backticks.
    if (!text.includes("`" + kind + "`")) continue;
    proseKindMentions++;
    if (!bundleKinds.has(kind)) violations.push({ file: f, kind });
  }
}

// Control: if the prose scan found no kind references at all, the scan is broken —
// these agent docs are built around naming effect kinds.
if (proseKindMentions === 0) {
  die(EXIT_CONTROL,
    "plugin-bundle-parity: CONTROL FAILED — scanned " + agentFiles.length +
    " agent docs and found ZERO backticked kind references; the prose scan is broken");
}

// ---- CHECK B: bundle-vs-source drift (reported, never fatal) --------------------
const missingKinds = [...srcKinds].filter((k) => !bundleKinds.has(k)).sort();
const srcToolNames = toolNames(srcText);
const bundleToolNames = toolNames(bundleText);
const missingTools = [...srcToolNames].filter((t) => !bundleToolNames.has(t)).sort();

console.log("plugin-bundle-parity");
console.log(`  released bundle : ${bundleTools} anchored tools, ${bundleKinds.size} effect kinds`);
console.log(`  current source  : ${srcTools} anchored tools, ${srcKinds.size} effect kinds`);
console.log(`  prose scanned   : ${agentFiles.length} agent docs, ${proseKindMentions} backticked kind references`);

if (missingKinds.length || missingTools.length) {
  console.log("");
  console.log("  DRIFT (expected until the bundle is regenerated — NOT a failure):");
  if (missingKinds.length) console.log(`    kinds in source, absent from bundle: ${missingKinds.join(", ")}`);
  if (missingTools.length) console.log(`    tools in source, absent from bundle: ${missingTools.join(", ")}`);
  console.log("    release chain: regenerate bundle LAST -> COMMIT (needs the user's word) -> /plugin update");
}

if (violations.length) {
  console.error("");
  console.error("plugin-bundle-parity: FAIL — released agent prose names kinds its own bundle REJECTS.");
  console.error("  A released agent reaching for these today gets refused by fx_add:");
  for (const v of violations) console.error(`    ${v.file}: \`${v.kind}\``);
  console.error("  Fix by regenerating the bundle, or by removing the claim from the prose.");
  process.exit(EXIT_FAIL);
}

console.log("");
console.log("  OK — every effect kind the released prose names is addable by the released bundle.");
process.exit(EXIT_OK);
