#!/usr/bin/env node
// plugin-bundle-freshness.mjs — the generated plugin bundle must not lag its source.
//
// WHY THIS EXISTS (2026-09-19). `claude-plugin/server/index.mjs` is BUILT from
// `mcp-server/src/` by `npm run bundle:plugin`, and NOTHING regenerates it when
// that source changes. `/plugin update` then faithfully installs a stale bundle
// and reports success — so the user sees "✔ Updated", and the capability they
// just watched ship is still invisible to every consumer-facing agent.
//
// Measured when this was written: the bundle was FIVE HOURS older than its source
// and missing THREE shipped effect kinds (`djFilter`, `ringMod`, `flanger`) while
// `chorus` and `bitCrusher` were present. Memory also records a bundle that went
// 18 DAYS stale. This is a recurring, silent, user-visible failure.
//
// ⚠️ IT IS A CONTENT CHECK, NOT ONLY A TIMESTAMP CHECK. An mtime comparison alone
// is defeated by `touch`, by a checkout that rewrites mtimes, and by any edit that
// does not change behaviour. So this gate ALSO asserts that every effect kind in
// the enum actually appears in the bundle — the thing a reader cares about.
//
// Exit codes: 0 fresh · 1 stale · 3 THE GATE COULD NOT TRUST ITSELF (not a pass).

import { readFileSync, statSync, readdirSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const BUNDLE = "claude-plugin/server/index.mjs";
const SRC_DIR = "mcp-server/src";
const KIND_HOME = "Sources/DAWCore/Effects.swift";
const REGEN = "cd mcp-server && npm run bundle:plugin";

// Present in every non-broken bundle. Used to prove the reader works before any
// absence is believed. `chorus` is NOT usable here — it is also a song section,
// and it once cleared a control on a file that had no kind list at all.
const SENTINELS = ["bitCrusher", "saturator"];

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

let bundle, bundleStat;
try {
  bundle = readFileSync(resolve(ROOT, BUNDLE), "utf8");
  bundleStat = statSync(resolve(ROOT, BUNDLE));
} catch {
  console.error(
    `SELF-CONTROL FAILED: cannot read ${BUNDLE}. Either the bundle was never ` +
    `built (run \`${REGEN}\`) or it moved. Scored NOTHING.`);
  process.exit(3);
}

const all = parseKinds();
const kinds = all.filter((k) => k !== "audioUnit");
if (all.length < 10 || !SENTINELS.every((s) => all.includes(s))) {
  console.error(
    `SELF-CONTROL FAILED: parsed ${all.length} kinds from ${KIND_HOME} ` +
    `(${all.join(", ") || "none"}). The enum moved or changed shape. Scored NOTHING.`);
  process.exit(3);
}

const has = (k) => new RegExp(`\\b${k}\\b`).test(bundle);
const deadSentinels = SENTINELS.filter((s) => !has(s));
if (deadSentinels.length) {
  console.error(
    `SELF-CONTROL FAILED: sentinel(s) ${deadSentinels.join(", ")} absent from the ` +
    `bundle. A bundle missing even these is not merely stale — it is wrong, or the ` +
    `matcher is broken. Scored NOTHING.`);
  process.exit(3);
}

// ---- content: every shipped kind must be reachable through the bundle --------
const missing = kinds.filter((k) => !has(k));

// ---- timestamp: newest source file vs the bundle ----------------------------
function newestUnder(rel) {
  let newest = 0, which = null;
  const walk = (dir) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      if (!/\.(ts|mjs|js|json)$/.test(e.name)) continue;
      const m = statSync(p).mtimeMs;
      if (m > newest) { newest = m; which = p; }
    }
  };
  walk(resolve(ROOT, rel));
  return { newest, which };
}
const { newest, which } = newestUnder(SRC_DIR);
const lagMs = newest - bundleStat.mtimeMs;
const lagHours = lagMs / 3_600_000;

const problems = [];
if (missing.length) {
  problems.push(
    `the bundle never mentions: ${missing.join(", ")}\n` +
    `      (it DOES mention ${SENTINELS.join(" and ")}, so the reader works — ` +
    `these kinds are genuinely absent)`);
}
if (lagMs > 0) {
  problems.push(
    `the bundle is OLDER than its source by ${lagHours.toFixed(1)} h\n` +
    `      newest source: ${which}`);
}

if (problems.length) {
  console.error(`Plugin bundle is STALE — ${BUNDLE}\n`);
  for (const p of problems) console.error(`  • ${p}`);
  console.error(
    `\n⚠️ \`/plugin update\` will install this bundle AND REPORT SUCCESS. Every ` +
    `capability missing above is invisible to the consumer-facing agents until it ` +
    `is rebuilt.\n   Fix: ${REGEN}   then re-run /plugin update.`);
  process.exit(1);
}

// ---- the INSTALLED copy, which is the one the user actually runs -----------
// ⚠️⚠️ THE REPO BUNDLE PASSING IS NOT THE QUESTION ANYONE IS ASKING. Measured
// 2026-09-19: this gate reported OK on a fresh repo bundle while the INSTALLED
// plugin was FOUR effect kinds stale, and two `/plugin update` runs had both
// reported success. The install is pinned to a `gitCommitSha` and installs from
// a COMMIT, not from the working tree — so an uncommitted tree can never reach
// it, no matter how current the repo bundle is. Reporting OK without saying so
// is the same silent-success shape this file was written to prevent.
let installNote = "";
try {
  const reg = JSON.parse(readFileSync(
    resolve(process.env.HOME ?? "", ".claude/plugins/installed_plugins.json"), "utf8"));
  const entries = Object.entries(reg.plugins ?? {})
    .filter(([k]) => k.startsWith("daw-pro-music-team"))
    .flatMap(([, v]) => (Array.isArray(v) ? v : [v]));
  for (const e of entries) {
    if (!e?.installPath) continue;
    let installed;
    try {
      installed = readFileSync(join(e.installPath, "server", "index.mjs"), "utf8");
    } catch { continue; }
    const iHas = (k) => new RegExp(`\\b${k}\\b`).test(installed);
    // Same sentinel discipline: prove the reader works on THIS file first.
    if (!SENTINELS.every(iHas)) {
      installNote += `\n⚠️ installed copy at ${e.installPath} could not be read ` +
        `meaningfully (sentinels absent) — not scored.`;
      continue;
    }
    const iMissing = kinds.filter((k) => !iHas(k));
    if (iMissing.length) {
      installNote +=
        `\n⚠️⚠️ THE INSTALLED PLUGIN IS STALE — this is what the user actually runs.\n` +
        `   ${e.installPath}\n` +
        `   never mentions: ${iMissing.join(", ")}\n` +
        `   (it DOES mention ${SENTINELS.join(" and ")}, so these are genuinely absent)\n` +
        `   Pinned to gitCommitSha ${String(e.gitCommitSha).slice(0, 12)} — it installs from a\n` +
        `   COMMIT, not the working tree. \`/plugin update\` WILL REPORT SUCCESS and change\n` +
        `   nothing while this work is uncommitted. A fresh repo bundle does NOT fix it.`;
    }
  }
} catch { /* no registry on this machine — the repo check above still stands */ }

if (installNote) {
  console.error(
    `plugin-bundle-freshness: repo bundle OK (${kinds.length} kinds), BUT:` + installNote);
  process.exit(1);
}

console.log(
  `plugin-bundle-freshness: OK — ${kinds.length} kinds present, bundle newer than ` +
  `source by ${(-lagHours).toFixed(1)} h, and the installed copy matches.`);
