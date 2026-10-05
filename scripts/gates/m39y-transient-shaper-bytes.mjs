#!/usr/bin/env node
// m39y-transient-shaper-bytes.mjs — the `.transientShaper` demo sets did
// something, and what they did was PUNCH rather than VOLUME.
//
// WHY THIS EXISTS AS A SEPARATE SCRIPT. Until 2026-09-20 the demo harness's own
// byte-identity check was a `console.error` WARNING that touched nothing setting
// the exit code, so a demo set whose axis did NOTHING exited 0 and read as a
// pass. That is the `.modulation` shape exactly: m39-e shipped an LFO on
// `.volume`/`.pan` that was completely inert, live AND offline, with 24 unit
// tests green, and the byte check is what caught it — by being READ by a human.
// The harness's check is now a hard failure, which covers "the axis did not
// take". This gate covers the question the harness cannot ask: did the axis
// move the right THING?
//
// ⛔⛔ THE IDENTITY HALF DELIBERATELY DOES NOT LIVE HERE, AND THAT IS A CHANGE
// FROM THE DESIGN. `docs/design/2026-09-20-transient-shaper.md` §7.3 specifies a
// `shaper-default` variant that renders BYTE-IDENTICAL to `no-shaper`, asserted
// here, and says the harness "will print a warning… that warning is EXPECTED".
// MEASURED 2026-09-20: that is no longer true. `render-variants.mjs:813-818`
// now EXITS 1 on any identical pair and states outright that there is
// "deliberately NO spec-level opt-out", because an escape hatch would be used to
// silence exactly the defect the check exists to find. A demo set containing the
// identity pair therefore cannot render at all. The identity claim is instead
// proven where it is PROVABLE MORE STRONGLY — `TransientShaperTests` L4 compares
// FLOAT BIT PATTERNS, sample for sample, over a fixture carrying signed zeros
// and subnormals, which a sha256 of a WAV cannot distinguish from a tolerance
// match. ⛔ Do NOT "fix" this by perturbing the default to make the pair
// non-identical: that would break the bit-exact-dry rule (6.0.7) itself.
//
// Exit codes: 0 pass · 1 an assertion failed · 3 THE GATE COULD NOT TRUST
// ITSELF (missing/unparseable input, a failed render, a missing hash) — 3 is
// NOT a pass, it means NOTHING WAS SCORED.

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SETS = [
  {
    dir: "scripts/demos/out/transient-shaper-attack",
    axis: "attackDb",
    // Ordered by the axis. Punch RAISES peaks at constant loudness, so true
    // peak must rise monotonically along this order.
    order: ["attack-minus-9", "no-shaper", "attack-plus-4", "attack-plus-9"],
    peakDirection: +1,
  },
  {
    dir: "scripts/demos/out/transient-shaper-sustain",
    axis: "sustainDb",
    // Body RAISES the tail at constant loudness, which LOWERS the peak — the
    // opposite sign, and that opposition is itself evidence the two axes act on
    // different parts of the sound.
    order: ["sustain-minus-9", "no-shaper", "sustain-plus-4", "sustain-plus-9"],
    peakDirection: -1,
  },
];

// §9.3: every variant within this many LU of its set's median. A listener
// reliably picks whichever version is loudest, so an unmatched set measures
// preference for volume and calls it preference for punch.
const LOUDNESS_TOLERANCE_LU = 1.0;

const selfControlFailures = [];
const failures = [];
const loaded = [];

// ── self-control: the gate can read its own input ───────────────────────────
for (const set of SETS) {
  const path = resolve(ROOT, set.dir, "manifest.json");
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    selfControlFailures.push(
      `${set.dir}/manifest.json could not be read or parsed (${e.message}). ` +
      `Run: node scripts/demos/render-variants.mjs scripts/demos/specs/` +
      `${set.dir.split("/").pop()}.json`);
    continue;
  }
  // ⛔⛔ **FRESHNESS, AND IT IS A SELF-CONTROL, NOT A NICETY — ADDED 2026-09-20
  // AFTER THIS GATE PASSED A PLANTED, COMPLETELY INERT SHAPER.**
  // This gate SCORES A MANIFEST; it does not render. I planted
  // `shapedFraction → 0` (the shaper never shapes), rebuilt `DemoRender`, and
  // ran the gate: it reported the PREVIOUS run's numbers — loudness ±0.00 LU,
  // 8.8 dB of crest travel — and exited 0. Every figure it printed was true of
  // a binary that no longer existed. That is this tree's characteristic
  // failure in gate form: the record says X, the source says Y, and nothing
  // compares them.
  //
  // The manifest already carried `buildSha256`, the hash of the `DemoRender`
  // that produced it. Comparing it against the binary on disk NOW costs one
  // hash and turns a stale pass into an honest "cannot score" (exit 3 — the
  // `doc-count-drift.mjs` shape: refuse to score rather than score wrongly).
  const binPath = manifest.binaryPath
    ? resolve(ROOT, manifest.binaryPath)
    : resolve(ROOT, ".build/debug/DemoRender");
  if (!manifest.buildSha256) {
    selfControlFailures.push(
      `${set.dir}/manifest.json carries no buildSha256 — its provenance cannot be ` +
      `checked, so its numbers cannot be trusted. Re-render with the current harness.`);
    continue;
  }
  if (!existsSync(binPath)) {
    selfControlFailures.push(
      `${set.dir}: the DemoRender binary named by the manifest is gone (${binPath}); ` +
      `nothing can confirm these numbers came from the code in this tree.`);
    continue;
  }
  const liveSha = createHash("sha256").update(readFileSync(binPath)).digest("hex");
  if (liveSha !== manifest.buildSha256) {
    selfControlFailures.push(
      `${set.dir}: STALE MANIFEST — rendered by DemoRender ${manifest.buildSha256.slice(0, 12)}…, ` +
      `but the binary on disk is ${liveSha.slice(0, 12)}…. These numbers describe a ` +
      `different build. Re-render: node scripts/demos/render-variants.mjs ` +
      `scripts/demos/specs/${set.dir.split("/").pop()}.json`);
    continue;
  }

  const variants = manifest.variants ?? [];
  if (variants.length < 4) {
    selfControlFailures.push(
      `${set.dir}: ${variants.length} variant(s), expected >= 4`);
    continue;
  }
  for (const v of variants) {
    if (v.ok !== true) {
      selfControlFailures.push(`${set.dir}: variant '${v.name}' has ok=${v.ok}`);
    }
    if (typeof v.sha256 !== "string" || v.sha256.length < 40) {
      selfControlFailures.push(
        `${set.dir}: variant '${v.name}' has no usable sha256 (${v.sha256})`);
    }
    if (typeof v.integratedLufs !== "number" || !Number.isFinite(v.integratedLufs)) {
      selfControlFailures.push(
        `${set.dir}: variant '${v.name}' has no usable integratedLufs`);
    }
    if (typeof v.truePeakDbtp !== "number" || !Number.isFinite(v.truePeakDbtp)) {
      selfControlFailures.push(
        `${set.dir}: variant '${v.name}' has no usable truePeakDbtp`);
    }
  }
  const byName = new Map(variants.map((v) => [v.name, v]));
  for (const name of set.order) {
    if (!byName.has(name)) {
      selfControlFailures.push(
        `${set.dir}: expected variant '${name}' is absent — the spec and this ` +
        `gate disagree about the axis, so nothing below was scored`);
    }
  }
  loaded.push({ set, manifest, byName });
}

if (selfControlFailures.length > 0) {
  console.error("SELF-CONTROL FAILED — THIS GATE SCORED NOTHING:");
  for (const f of selfControlFailures) console.error(`  ${f}`);
  process.exit(3);
}

// ── control: the renderer is DETERMINISTIC ─────────────────────────────────
// The two sets share the same material and both carry a `no-shaper` control
// with NO effect at all. If those two files are not byte-identical, the render
// is not reproducible and EVERY distinct-hash finding below would be equally
// explainable as run-to-run noise. This is the closest thing to an identity
// control the manifest can carry, and it is a real one.
{
  const hashes = loaded.map((l) => l.byName.get("no-shaper").sha256);
  if (new Set(hashes).size !== 1) {
    console.error(
      `SELF-CONTROL FAILED: the two sets' 'no-shaper' controls render to ` +
      `DIFFERENT bytes (${hashes.join(" vs ")}). The render is not ` +
      `deterministic, so a distinct hash proves nothing. NOTHING WAS SCORED.`);
    process.exit(3);
  }
  console.log(`control: both sets' 'no-shaper' renders are byte-identical ` +
              `(${hashes[0].slice(0, 12)}…) — the render is deterministic.`);
}

// ── assertion 1: DIFFERENCE. Every variant in a set is distinct. ───────────
// This is the m39-e inert-effect assertion. `shapedFraction` forced to 0 (or
// any other way of making the unit do nothing) collapses all four variants of
// both sets onto one hash.
for (const { set, byName } of loaded) {
  const hashes = set.order.map((n) => byName.get(n).sha256);
  const unique = new Set(hashes);
  if (unique.size !== hashes.length) {
    const groups = new Map();
    set.order.forEach((n, i) => {
      if (!groups.has(hashes[i])) groups.set(hashes[i], []);
      groups.get(hashes[i]).push(n);
    });
    for (const names of groups.values()) {
      if (names.length > 1) {
        failures.push(
          `${set.dir}: ${names.join(" == ")} rendered BYTE-IDENTICAL — the ` +
          `${set.axis} axis did NOT take`);
      }
    }
  } else {
    console.log(`${set.axis}: all ${hashes.length} variants are distinct.`);
  }
}

// ── assertion 2: it changed PUNCH, not VOLUME. ─────────────────────────────
// Integrated loudness matched to within 1 LU, AND true peak moving
// monotonically along the axis. Either number alone is fakeable by a plain
// gain; together they are not, because a gain moves both in lockstep.
for (const { set, byName } of loaded) {
  const rows = set.order.map((n) => byName.get(n));
  const lufs = rows.map((v) => v.integratedLufs).slice().sort((a, b) => a - b);
  const median = rows.length % 2 === 0
    ? (lufs[rows.length / 2 - 1] + lufs[rows.length / 2]) / 2
    : lufs[(rows.length - 1) / 2];
  let worstLu = 0;
  for (const v of rows) {
    worstLu = Math.max(worstLu, Math.abs(v.integratedLufs - median));
  }
  if (worstLu > LOUDNESS_TOLERANCE_LU) {
    failures.push(
      `${set.dir}: loudness spread is ${worstLu.toFixed(2)} LU from the median ` +
      `${median.toFixed(1)} LUFS, over the ${LOUDNESS_TOLERANCE_LU} LU budget — ` +
      `a listener would be picking the loudest one. Trim with outputDb.`);
  }

  let monotone = true;
  for (let i = 1; i < rows.length; i++) {
    const delta = (rows[i].truePeakDbtp - rows[i - 1].truePeakDbtp) * set.peakDirection;
    if (delta <= 0) monotone = false;
  }
  const spread = Math.abs(
    rows[rows.length - 1].truePeakDbtp - rows[0].truePeakDbtp);
  const arrow = set.peakDirection > 0 ? "rising" : "falling";
  console.log(
    `${set.axis}: loudness ${median.toFixed(1)} LUFS ±${worstLu.toFixed(2)} LU; ` +
    `true peak ${rows.map((v) => v.truePeakDbtp.toFixed(1)).join(" → ")} dBTP ` +
    `(${arrow}, ${spread.toFixed(1)} dB of crest travel)`);
  if (!monotone) {
    failures.push(
      `${set.dir}: true peak is not monotonically ${arrow} along the ` +
      `${set.axis} axis — at matched loudness that is what "changes punch, not ` +
      `volume" MEANS, so the claim is not supported by these renders`);
  }
  if (spread < 2.0) {
    failures.push(
      `${set.dir}: only ${spread.toFixed(2)} dB of crest travel across the whole ` +
      `axis — the effect is present but so weak the demo cannot demonstrate it`);
  }
}

if (failures.length > 0) {
  console.error("\n✘ m39y transient-shaper byte/crest gate FAILED:");
  for (const f of failures) console.error(`  ${f}`);
  process.exit(1);
}

console.log("\n✔ m39y: both axes took, both are loudness-matched, and both move " +
            "crest factor in their own direction.");
process.exit(0);
