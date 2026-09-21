#!/usr/bin/env node
// m39-ae — THE RING MODULATOR DID NOT NOTICE ITS FILTER MOVING HOUSE.
//
// ⛔⛔ WHY THIS GATE EXISTS AT ALL. m39-ae needed a 2-pole biquad for the
// compressor's de-ess detector, and one already existed: `RingModEffect.Biquad`,
// private to that file. The tree's rule (the `Oversampler` precedent — extracted
// the moment the clipper became the saturator's second caller) says a primitive
// is extracted when a SECOND caller appears. So it moved to
// `Sources/DAWEngine/Effects/Primitives/Biquad.swift`.
//
// `.ringMod` is a SHIPPED kind. "I moved it unchanged" is a claim about
// arithmetic, and arithmetic claims made by the person doing the moving are the
// least reliable kind there is — a reordered expression, an `@inline(__always)`
// dropped, a `Float` where a `Double` was, or a denormal flush at a different
// threshold would each change a low bit while every unit test stayed green and
// the effect went on sounding exactly like a ring modulator.
//
// So this pins all four renders of the EXISTING `ringmod.json` demo set against
// hashes measured from the build that existed BEFORE the file was created. The
// set was not written for this and that is a point in its favour: it was written
// to demonstrate the effect, it exercises the filter at three carrier settings
// plus a no-effect control, and it cannot have been shaped to pass.
//
// ⚠️ THE `carrier-*` VARIANTS ARE THE ONES THAT READ THE FILTER. `no-effect` is
// the control — the same source with the insert absent — and it is what
// separates "the render pipeline moved" from "the extraction changed the
// filter". Both legs are needed: without the control a synth change would read
// as a filter regression, which is a false accusation; without the variants
// there is nothing measuring the filter at all.
//
// ⭐ THE COMPANION IS A UNIT TEST, NOT MORE HASHES. A file hash proves the
// output did not move but says nothing about WHY. `RingModBiquadExtractionTests`
// runs the extracted primitive and a hand-copy of the original inline
// expressions over a long recursive run at coefficients taken from
// `EQFilterResponse`, and requires BIT-EQUAL output including the denormal
// flush. Two instruments, two failure modes, one claim.
//
// Exit codes: 0 pass · 1 THE EXTRACTION CHANGED THE FILTER · 3 REFUSED TO SCORE.

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SET_DIR = "scripts/demos/out/ringmod";
const SPEC_PATH = "scripts/demos/specs/ringmod.json";

// ⛔ THE PINS. Measured from DemoRender `8d80d9642453…` — the working tree
// before `Primitives/Biquad.swift` existed — rendered TWICE into the same
// directory with identical bytes, then reproduced EXACTLY by DemoRender
// `e121093a5d87…`, a different binary by hash built after the extraction
// landed. That second agreement is the result; the first two runs establish
// only that a file hash is a usable instrument here.
const V0_BINARY_SHA = "8d80d9642453e6fb56ebd8b715f258275d8d2cbf96e6d945bd1cca9653f74ed0";
const CONTROL = "no-effect";
const PINS = {
  [CONTROL]: "14f422ab009df155d7fff31ba8a2305eabb2c8673a9a8e98cdfb85a7e147b0ca",
  "carrier-2hz": "38eddf50207c751e4350c3bcdcc6a9f5822b544f399781d22eee538a6838e8a6",
  "carrier-200hz": "6fdf417452b58e57d074ac3d0e52a8345d40cc717e98742562ce42e1f000ea96",
  "carrier-800hz": "c97f13773dae58a0286055de558159059d283c844c59c3afc7148ffef41aca4d",
};
const EFFECT_VARIANTS = Object.keys(PINS).filter((n) => n !== CONTROL);

const selfControlFailures = [];
const failures = [];
const notes = [];

const manifestPath = resolve(ROOT, SET_DIR, "manifest.json");
let manifest = null;
if (!existsSync(manifestPath)) {
  selfControlFailures.push(
    `${SET_DIR}/manifest.json does not exist. Render it first: ` +
    `node scripts/demos/render-variants.mjs ${SPEC_PATH}`);
} else {
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch (error) {
    selfControlFailures.push(`${SET_DIR}/manifest.json does not parse: ${error.message}`);
  }
}

if (manifest) {
  // ⛔⛔ FRESHNESS FIRST — a gate here passed a completely inert effect on
  // 2026-09-19 by scoring a manifest from a previous build.
  const binPath = manifest.binaryPath
    ? resolve(ROOT, manifest.binaryPath)
    : resolve(ROOT, ".build/debug/DemoRender");
  if (!manifest.buildSha256) {
    selfControlFailures.push(
      `${SET_DIR}/manifest.json carries no buildSha256 — its provenance cannot be checked.`);
  } else if (!existsSync(binPath)) {
    selfControlFailures.push(
      `${SET_DIR}: the DemoRender binary named by the manifest is gone (${binPath}).`);
  } else {
    const liveSha = createHash("sha256").update(readFileSync(binPath)).digest("hex");
    if (liveSha !== manifest.buildSha256) {
      selfControlFailures.push(
        `${SET_DIR}: STALE MANIFEST — rendered by DemoRender ` +
        `${manifest.buildSha256.slice(0, 12)}…, but the binary at ${binPath} is ` +
        `${liveSha.slice(0, 12)}…. Re-render: ` +
        `node scripts/demos/render-variants.mjs ${SPEC_PATH}`);
    } else {
      notes.push(
        `manifest is FRESH: rendered by DemoRender ${liveSha.slice(0, 12)}…` +
        (liveSha === V0_BINARY_SHA
          ? ` — which IS the v0 build the pins came from, so this run self-checks the gate`
          : ``));
    }
  }

  // ── the spec must still be the set the pins describe ──────────────────────
  const specPath = resolve(ROOT, SPEC_PATH);
  if (!existsSync(specPath)) {
    selfControlFailures.push(`the spec is missing: ${specPath}`);
  } else {
    const spec = JSON.parse(readFileSync(specPath, "utf8"));
    const byName = new Map(spec.variants.map((v) => [v.name, v]));
    for (const name of Object.keys(PINS)) {
      if (!byName.has(name)) {
        selfControlFailures.push(`the spec has no variant named '${name}'`);
      }
    }
    // The control must carry no effect, or it is not a control.
    if (byName.get(CONTROL)?.commands?.some((c) => c.command === "fx.add")) {
      selfControlFailures.push(
        `the spec's ${CONTROL} variant adds an effect — it cannot separate "the pipeline ` +
        `moved" from "the extracted filter changed".`);
    }
    // ⛔ AND THE VARIANTS MUST BE RING MODULATORS ON DISTINCT CARRIERS, or
    // Leg 3's distinctness check is measuring something other than the axis.
    const carriers = new Set();
    for (const name of EFFECT_VARIANTS) {
      const fx = byName.get(name)?.commands?.find((c) => c.command === "fx.add");
      if (fx?.params?.kind !== "ringMod") {
        selfControlFailures.push(
          `the spec's ${name} adds '${fx?.params?.kind}', not a ringMod`);
        continue;
      }
      carriers.add(fx?.params?.params?.carrierHz);
    }
    if (carriers.size !== EFFECT_VARIANTS.length) {
      selfControlFailures.push(
        `the spec's ${EFFECT_VARIANTS.length} ring-modulator variants use ${carriers.size} ` +
        `distinct carrierHz values. They are supposed to differ on that axis.`);
    }

    // ⚠️⚠️ HOW STRONG THIS FIXTURE ACTUALLY IS — MEASURED, AND STATED HERE
    // RATHER THAN ASSUMED, BECAUSE THE HONEST ANSWER IS "STRONG, BUT NOT FOR
    // THE REASON YOU WOULD GUESS".
    //
    // This gate's FIRST draft refused to score, on a self-control demanding
    // `inputHighCutHz` below the top of its range: the extracted biquad IS that
    // high-cut, and a wide-open corner sounded like a fixture measuring a
    // bypass. That refusal was WRONG and the self-control was deleted.
    // `RingModEffect` runs `filterL.step(...)`/`filterR.step(...)`
    // UNCONDITIONALLY — there is no skip at the top of the range — so at
    // 20 000 Hz the recurrence executes on every sample with real coefficients,
    // and any change to its arithmetic propagates into the carrier
    // multiplication. A 2-pole corner at 20 kHz is also not transparent at
    // 48 kHz: it is −3 dB at the corner and the ring modulation puts plenty of
    // energy up there.
    //
    // ⭐ AND IT WAS NOT LEFT AS AN ARGUMENT. A defect was PLANTED in
    // `Primitives/Biquad.swift` during this build — the denormal flush moved
    // from 1e-25 to 1e-20, the smallest change the file can carry — DemoRender
    // was rebuilt and this set re-rendered: all three `carrier-*` hashes moved
    // and the control did not. That is what makes these pins an instrument
    // rather than a hope.
    const cuts = EFFECT_VARIANTS.map((n) => byName.get(n)?.commands
      ?.find((c) => c.command === "fx.add")?.params?.params?.inputHighCutHz);
    notes.push(
      `fixture's inputHighCutHz per variant: ${cuts.join(", ")} — the biquad runs ` +
      `unconditionally at every setting, so these pins read its arithmetic regardless`);
  }

  const byVariant = new Map((manifest.variants ?? []).map((v) => [v.name, v]));
  for (const name of Object.keys(PINS)) {
    const v = byVariant.get(name);
    if (!v) {
      selfControlFailures.push(`${SET_DIR}: no variant named "${name}" in the manifest`);
      continue;
    }
    if (v.ok !== true) {
      selfControlFailures.push(`${SET_DIR}/${name}: render did not succeed (${v.error})`);
    }
    if (typeof v.sha256 !== "string" || v.sha256.length !== 64) {
      selfControlFailures.push(`${SET_DIR}/${name}: no usable sha256 (${v.sha256})`);
    }
    if (!v.path || !existsSync(resolve(ROOT, v.path))) {
      selfControlFailures.push(`${SET_DIR}/${name}: rendered wav is missing (${v.path})`);
      continue;
    }
    // ⭐ The gate must hash the same file the harness hashed, or every
    // comparison below is about a file that is no longer on disk.
    const onDisk = createHash("sha256")
      .update(readFileSync(resolve(ROOT, v.path))).digest("hex");
    if (onDisk !== v.sha256) {
      selfControlFailures.push(
        `${SET_DIR}/${name}: the wav on disk hashes ${onDisk.slice(0, 12)}… but the manifest ` +
        `recorded ${String(v.sha256).slice(0, 12)}…. Nothing here can be scored.`);
    }
  }
}

if (selfControlFailures.length > 0) {
  console.error("m39ae-ringmod-unchanged-bytes: REFUSING TO SCORE.\n");
  for (const f of selfControlFailures) console.error(`  · ${f}`);
  console.error(
    "\nA gate that cannot read its own input must not report an all-clear. " +
    "Exit 3 is NOT a pass.");
  process.exit(3);
}

const byVariant = new Map(manifest.variants.map((v) => [v.name, v]));
for (const name of Object.keys(PINS)) {
  notes.push(`${name.padEnd(14)}${name === CONTROL ? " (control)" : "         "}: ` +
             byVariant.get(name).sha256);
}

// ── LEG 1: THE CONTROL ──────────────────────────────────────────────────────
if (byVariant.get(CONTROL).sha256 !== PINS[CONTROL]) {
  console.error("m39ae-ringmod-unchanged-bytes: REFUSING TO SCORE.\n");
  console.error(
    `  · THE CONTROL MOVED. The same source with NO effect rendered\n` +
    `      ${byVariant.get(CONTROL).sha256}\n    but this gate pins\n      ${PINS[CONTROL]}\n` +
    `    from DemoRender ${V0_BINARY_SHA.slice(0, 12)}… on 2026-09-20.\n\n` +
    `    Something in the render pipeline changed that has nothing to do with the\n` +
    `    biquad extraction. This gate will not call that a ring-modulator regression.`);
  process.exit(3);
}
notes.push("⭐ CONTROL HOLDS — the pipeline around the insert is bit-identical to v0");

// ── LEG 2: THE RING MODULATOR ───────────────────────────────────────────────
for (const name of EFFECT_VARIANTS) {
  const rendered = byVariant.get(name).sha256;
  if (rendered === PINS[name]) continue;
  failures.push(
    `THE RING MODULATOR CHANGED — variant '${name}'.\n` +
    `      rendered ${rendered}\n` +
    `      pinned   ${PINS[name]}\n` +
    `      The control is bit-identical, so the difference is inside the insert, and the\n` +
    `      only thing m39-ae touched in it is where the biquad's SOURCE lives. Look for:\n` +
    `        · a reordered expression in Biquad.step (the TDF2 recurrence is order-sensitive);\n` +
    `        · the 1e-25 denormal flush changed, moved, or applied to one state word;\n` +
    `        · a Float where the original had a Double;\n` +
    `        · a NaN/clamp guard ADDED to the primitive — it must not have one, and the\n` +
    `          reason is written at the top of Primitives/Biquad.swift.`);
}

// ── LEG 3: INVARIANCE — the four renders must still be four ─────────────────
const all = Object.keys(PINS).map((n) => byVariant.get(n).sha256);
if (new Set(all).size !== all.length) {
  failures.push(
    `two or more of the ${all.length} pinned renders are BYTE-IDENTICAL ` +
    `(${new Set(all).size} distinct). Either the ring modulator is not in the chain or the ` +
    `carrier settings stopped differing — the pins would then be pinning the same audio.`);
}

for (const n of notes) console.log(`  · ${n}`);
if (failures.length > 0) {
  console.error(`\nm39ae-ringmod-unchanged-bytes: ${failures.length} failure(s).\n`);
  for (const f of failures) console.error(`  ✘ ${f}`);
  process.exit(1);
}
console.log(
  `\nm39ae-ringmod-unchanged-bytes: OK — all ${EFFECT_VARIANTS.length} ring-modulator renders ` +
  `are BIT-FOR-BIT what they were before its biquad moved to Primitives/, and the control ` +
  `proves the rest of the pipeline is unchanged too.`);
