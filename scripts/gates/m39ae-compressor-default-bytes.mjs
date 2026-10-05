#!/usr/bin/env node
// m39-ae — THE SHIPPED COMPRESSOR RENDERS BIT-FOR-BIT WHAT IT ALWAYS DID.
//
// ⛔⛔ **THIS IS THE GATE THE WHOLE ITEM TURNS ON.** `.compressor` is one of the
// oldest kinds in the tree (M4 iii) and there are already user projects with one
// in a chain — and with AUTOMATION LANES on it, whose slot ids are positional.
// m39-ae adds a de-ess detector: three appended params and a per-channel biquad
// in front of the peak detector. If that changed what the effect does at its
// EXISTING settings, every one of those projects would change tone on the next
// open, silently. The repo has a binding precedent for this shape (the "bend
// range default stays 2.0" ruling, and m39-ad's saturator): when capability is
// added to a shipped thing, the default must preserve existing behaviour, and
// the preservation is proven by a BYTE-IDENTICAL RENDER, not by argument.
//
// ## ⛔⛔ FIVE PINNED VARIANTS, AND NOT ONE OF THEM IS REDUNDANT
//
// Each covers a branch the others cannot see:
//
//   · `comp-default`  — a freshly added compressor, NOTHING set. The promise a
//                       user cares about most, and the weakest pin on its own.
//   · `comp-partial`  — mix 0.37, knee 2, makeup 4. MEASURED ON THE SATURATOR
//                       DURING m39-ad AND IT COST AN AFTERNOON: at mix 1 the DRY
//                       term is multiplied by zero, so an algebraically
//                       identical but differently-rounded blend is bit-exact
//                       there and passes a default-only pin AND fifteen unit
//                       tests. Only a mix strictly between 0 and 1 has every
//                       term live. The nonzero knee keeps the quadratic knee
//                       branch on the pinned path for the same reason.
//   · `bus-selfkeyed` — the same compressor on a BUS fed by a send. A different
//                       graph position; the send/bus arithmetic is in the pin.
//   · `bus-keyed`     — ⛔ THE ONE THAT MATTERS MOST HERE. m39-ae restructured
//                       the detector's gather loop, and the KEYED limb of it is
//                       a separate branch that a self-keyed fixture never
//                       executes. A pin without a sidechained variant would have
//                       covered the wrong half of the change.
//
// ## Two controls, because there are two pipelines
//
//   · `no-compressor` — family 1's source with NO effect at all: the synth, the
//                       track path, the offline renderer and the wav writer.
//   · `bus-control`   — family 2's source (voice + key track + bus + send) with
//                       no effect anywhere: the send/bus path on top.
//
// and the legs say different things:
//
//   A CONTROL MOVED  → something changed that has NOTHING to do with the
//                      compressor. EXIT 3, "cannot score": the pins must be
//                      re-derived, and this gate refuses to call that a
//                      compressor regression, because a false accusation costs
//                      more than the gate saves.
//   CONTROLS SAME,
//   A VARIANT MOVED  → EXIT 1. Everything upstream and downstream of the insert
//                      is bit-identical and the only thing that changed is what
//                      the compressor did. That IS the regression.
//
// ## Provenance — and the positive control on the pins themselves
//
// All six hashes describe v0: the last state of this tree in which
// `CompressorParams` had seven fields and `CompressorEffect` had no detector
// filter.
//
// ⭐⭐ THEY WERE TAKEN TWICE FROM THE v0 BINARY AND AGREED, THEN REPRODUCED
// EXACTLY BY THE POST-CHANGE BINARY.
//   · measured from DemoRender `8d80d9642453…`, built from the working tree
//     before any m39-ae edit, and repeated into the same directory with
//     identical bytes both times;
//   · then re-measured from DemoRender `e121093a5d87…` — a different binary by
//     hash, built after the whole feature landed — which reproduced ALL SIX
//     hashes exactly. That second agreement is the actual result this gate
//     records; the first two runs only establish that a file hash is a usable
//     instrument here at all.
//
// Exit codes: 0 pass · 1 THE SHIPPED BEHAVIOUR CHANGED · 3 REFUSED TO SCORE.

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SET_DIR = "scripts/demos/out/deesser-bytes";
const SPEC_PATH = "scripts/demos/specs/deesser-bytes.json";

// ⛔ THE PINS. MEASURED, not computed — see "Provenance" above.
const V0_BINARY_SHA = "8d80d9642453e6fb56ebd8b715f258275d8d2cbf96e6d945bd1cca9653f74ed0";
const PINS = {
  "no-compressor": "214fbcc5ab81a668bb48da7dfe381afb5055f5e6965b017b52ad21c2299a2963",
  "comp-default": "22ccbd1ed18991304af7a5960d58a79d7b2ebdad603ef9e7ca55bd55e840bc44",
  "comp-partial": "d336b02b5d107ff99e34514688f03629c9737ffb7175cb7cf05c2c5ce0eb531b",
  "bus-control": "0fc598d729877cacb1e0dcd381e0ab0018adb9156bcf69e57fd5e9fd965df0c7",
  "bus-selfkeyed": "e95fa87e54b4a9d979c8134ddcc1500afae1fd563699369630856941fda30071",
  "bus-keyed": "047d53ee17f37efda2cae7e025f50ae2d5d5883873fffe2398c5115c5c77bfe2",
};
// The two variants that measure the pipeline AROUND the insert, and the family
// each one controls for.
const CONTROLS = { "no-compressor": 1, "bus-control": 2 };
const FAMILY = {
  "no-compressor": 1, "comp-default": 1, "comp-partial": 1,
  "bus-control": 2, "bus-selfkeyed": 2, "bus-keyed": 2,
};
const EFFECT_VARIANTS = Object.keys(PINS).filter((n) => !(n in CONTROLS));

// ⛔ THE THREE KEYS THIS FIXTURE MUST NEVER MENTION. Its pins were measured on
// a build where they did not exist, so a fixture that sets one is asking a
// different question from the one the hash answers — and would be pinning
// m39-ae's own behaviour as if it were the legacy behaviour, which is the
// tautology this whole gate exists to avoid.
const FORBIDDEN_KEYS = ["detectorMode", "detectorFreqHz", "detectorQ"];

const selfControlFailures = [];
const failures = [];
const notes = [];

// ── read the manifest ───────────────────────────────────────────────────────

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
  // ⛔⛔ FRESHNESS FIRST. A gate in this tree passed a completely inert effect on
  // 2026-09-19 by scoring a manifest from a previous build: every figure it
  // printed was true of a binary that no longer existed. One hash turns a stale
  // pass into an honest "cannot score".
  const binPath = manifest.binaryPath
    ? resolve(ROOT, manifest.binaryPath)
    : resolve(ROOT, ".build/debug/DemoRender");
  if (!manifest.buildSha256) {
    selfControlFailures.push(
      `${SET_DIR}/manifest.json carries no buildSha256 — its provenance cannot be ` +
      `checked, so its hashes cannot be trusted. Re-render with the current harness.`);
  } else if (!existsSync(binPath)) {
    selfControlFailures.push(
      `${SET_DIR}: the DemoRender binary named by the manifest is gone (${binPath}); ` +
      `nothing can confirm these renders came from the code in this tree.`);
  } else {
    const liveSha = createHash("sha256").update(readFileSync(binPath)).digest("hex");
    if (liveSha !== manifest.buildSha256) {
      selfControlFailures.push(
        `${SET_DIR}: STALE MANIFEST — rendered by DemoRender ` +
        `${manifest.buildSha256.slice(0, 12)}…, but the binary at ${binPath} is ` +
        `${liveSha.slice(0, 12)}…. These renders describe a different build. Re-render: ` +
        `node scripts/demos/render-variants.mjs ${SPEC_PATH}`);
    } else {
      notes.push(
        `manifest is FRESH: rendered by DemoRender ${liveSha.slice(0, 12)}…, which is ` +
        `the binary on disk now` +
        (liveSha === V0_BINARY_SHA
          ? ` — and it IS the v0 build the pins were taken from, so this run is a ` +
            `self-check of the gate rather than a check of a change`
          : ``));
    }
  }

  // ── the spec must still be asking for what the pins describe ──────────────
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

    // ⛔ NO VARIANT MAY MENTION A DE-ESS KEY. Checked over the whole serialized
    // variant rather than a guessed path, because `fx.add` params, `fx.setParam`
    // and a future seeding route are three different shapes and this needs to
    // catch all of them.
    for (const [name, v] of byName) {
      const text = JSON.stringify(v.commands ?? []);
      for (const key of FORBIDDEN_KEYS) {
        if (text.includes(key)) {
          selfControlFailures.push(
            `the spec's ${name} mentions '${key}'. Its pinned hash was measured on a build ` +
            `where that parameter did not exist, so this fixture must not mention it — ` +
            `otherwise the gate pins m39-ae's behaviour as if it were the legacy behaviour.`);
        }
      }
    }

    // ⛔ `comp-default` must add a compressor and set NOTHING. A `params` object
    // — even one spelling out today's defaults — would make this a pin on those
    // literal numbers rather than on THE DEFAULT, and the day a default changed
    // the gate would stay green while every new compressor changed.
    const def = byName.get("comp-default");
    const defFx = def?.commands?.filter((c) => c.command === "fx.add") ?? [];
    if (defFx.length !== 1 || defFx[0]?.params?.kind !== "compressor") {
      selfControlFailures.push(
        `the spec's comp-default does not add exactly one compressor ` +
        `(${defFx.length} fx.add, kind '${defFx[0]?.params?.kind}')`);
    } else if (defFx[0].params.params !== undefined) {
      selfControlFailures.push(
        `the spec's comp-default passes a 'params' object to fx.add. It must pass NONE: ` +
        `this gate pins THE DEFAULT, and spelling the defaults out in the fixture would ` +
        `pin the numbers instead — the gate would then stay green through a default change.`);
    }

    // ⛔ `comp-partial` must use a PARTIAL mix, or it is a second copy of
    // `comp-default`'s blind spot rather than the cover for it.
    const partialFx = byName.get("comp-partial")?.commands
      ?.find((c) => c.command === "fx.add");
    const partialMix = partialFx?.params?.params?.mix;
    if (partialFx?.params?.kind !== "compressor") {
      selfControlFailures.push(
        `the spec's comp-partial adds '${partialFx?.params?.kind}', not a compressor`);
    }
    if (!(typeof partialMix === "number" && partialMix > 0.01 && partialMix < 0.99)) {
      selfControlFailures.push(
        `the spec's comp-partial is at mix ${partialMix}. It exists SPECIFICALLY to exercise ` +
        `the blend, and at mix 0 or 1 one of the two terms is multiplied by zero — which is ` +
        `exactly how a differently-rounded blend passed the sibling gate during m39-ad.`);
    }
    if (!(partialFx?.params?.params?.kneeDb > 0)) {
      selfControlFailures.push(
        `the spec's comp-partial has kneeDb ${partialFx?.params?.params?.kneeDb}. It must be ` +
        `> 0, or the quadratic soft-knee branch of the gain computer is never taken and no ` +
        `pin here covers it.`);
    }

    // ⛔ `bus-keyed` must actually attach a key, or the ONE branch this item
    // restructured is not in any pin at all.
    const keyed = byName.get("bus-keyed")?.commands ?? [];
    const sidechain = keyed.find((c) => c.command === "fx.setSidechain");
    if (!sidechain || !sidechain.params?.sourceTrackId) {
      selfControlFailures.push(
        `the spec's bus-keyed does not call fx.setSidechain with a sourceTrackId. That ` +
        `variant exists to cover the KEYED limb of the detector's gather loop — the exact ` +
        `branch m39-ae restructured — and without it this gate pins only the self-keyed half.`);
    }
    // …and `bus-selfkeyed` must NOT, or the pair proves nothing about the key.
    if ((byName.get("bus-selfkeyed")?.commands ?? [])
        .some((c) => c.command === "fx.setSidechain")) {
      selfControlFailures.push(
        `the spec's bus-selfkeyed calls fx.setSidechain. It is bus-keyed's PARTNER and must ` +
        `differ from it by exactly that one command.`);
    }

    // ⛔ Controls must carry NO effect at all, or they measure the pipeline AND
    // the compressor and cannot separate them.
    for (const name of Object.keys(CONTROLS)) {
      if (byName.get(name)?.commands?.some((c) => c.command.startsWith("fx."))) {
        selfControlFailures.push(
          `the spec's ${name} variant issues an fx.* command — it is not a control, and the ` +
          `"pipeline moved vs compressor moved" split below would be meaningless.`);
      }
    }

    // Every pinned variant must play the SAME source as its family's control,
    // or the control controls nothing. `fx.*` commands are the axis and are
    // excluded; everything else must match exactly.
    const sourceOf = (v) => JSON.stringify(
      (v?.commands ?? []).filter((c) => !c.command.startsWith("fx.")));
    for (const name of EFFECT_VARIANTS) {
      const controlName = Object.keys(CONTROLS).find((c) => CONTROLS[c] === FAMILY[name]);
      if (sourceOf(byName.get(controlName)) !== sourceOf(byName.get(name))) {
        selfControlFailures.push(
          `the spec's ${controlName} and ${name} variants do not play an identical source ` +
          `(their non-fx commands differ). A control can only separate "the pipeline moved" ` +
          `from "the compressor moved" if everything except the insert is the same.`);
      }
    }
  }

  // ── the named variants must be present and rendered ───────────────────────
  const variants = manifest.variants ?? [];
  const byVariant = new Map(variants.map((v) => [v.name, v]));
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
    }
  }

  // ── self-control: the hash this gate computes must match the manifest's ───
  // ⭐ A NEGATIVE RESULT FROM A HAND-BUILT PROBE IS THE WEAKEST EVIDENCE THERE
  // IS. Before "the bytes are unchanged" is believed, the gate must be shown to
  // hash the same file the harness hashed. If the two disagree the manifest is
  // describing a file that is no longer on disk, and every comparison below
  // would be about nothing.
  for (const name of Object.keys(PINS)) {
    const v = byVariant.get(name);
    if (!v?.path) continue;
    const abs = resolve(ROOT, v.path);
    if (!existsSync(abs)) continue;
    const onDisk = createHash("sha256").update(readFileSync(abs)).digest("hex");
    if (onDisk !== v.sha256) {
      selfControlFailures.push(
        `${SET_DIR}/${name}: the wav on disk hashes ${onDisk.slice(0, 12)}… but the ` +
        `manifest recorded ${String(v.sha256).slice(0, 12)}…. The file changed after the ` +
        `manifest was written; nothing here can be scored.`);
    }
  }
}

if (selfControlFailures.length > 0) {
  console.error("m39ae-compressor-default-bytes: REFUSING TO SCORE.\n");
  for (const f of selfControlFailures) console.error(`  · ${f}`);
  console.error(
    "\nA gate that cannot read its own input must not report an all-clear. " +
    "Exit 3 is NOT a pass.");
  process.exit(3);
}

// ── LEG 1: THE CONTROLS — did the pipeline around the insert move? ──────────

const byVariant = new Map(manifest.variants.map((v) => [v.name, v]));
for (const name of Object.keys(PINS)) {
  notes.push(`${name.padEnd(14)}${name in CONTROLS ? " (control)" : "         "}: ` +
             byVariant.get(name).sha256);
}

for (const name of Object.keys(CONTROLS)) {
  const sha = byVariant.get(name).sha256;
  if (sha === PINS[name]) continue;
  console.error("m39ae-compressor-default-bytes: REFUSING TO SCORE.\n");
  console.error(
    `  · A CONTROL MOVED — '${name}'. The same source with NO effect in the chain\n` +
    `    rendered\n      ${sha}\n    but this gate pins\n      ${PINS[name]}\n` +
    `    from DemoRender ${V0_BINARY_SHA.slice(0, 12)}… on 2026-09-20.\n\n` +
    `    Something in the render pipeline changed that has NOTHING to do with the\n` +
    `    compressor — the synth, the mixer, the send/bus path, the offline renderer,\n` +
    `    the wav writer, or the fixture itself. This gate will not call that a\n` +
    `    compressor regression.\n\n` +
    `    TO RE-PIN HONESTLY: the pins must be re-derived from a build in which the\n` +
    `    compressor's behaviour is KNOWN good, not from whatever is in the tree now.\n` +
    `    Re-deriving them from the current build would make this gate a tautology.`);
  process.exit(3);
}
notes.push("⭐ BOTH CONTROLS HOLD — everything around the insert is bit-identical to v0");

// ── LEG 2: THE COMPRESSOR VARIANTS ──────────────────────────────────────────

const WHY = {
  "comp-default":
    `        · the three new params do not all default to the OFF/inert values;\n` +
    `        · 'detectorMode' 0 RUNS the detector filter instead of SKIPPING it (even a\n` +
    `          mathematically transparent filter is not bit-transparent);\n` +
    `        · the detector's rectify loop was rewritten rather than left verbatim — a\n` +
    `          different operand order, or a 'filtered = active ? f(x) : x' one-liner where\n` +
    `          v0 had 'abs(channelData[c]![frame])'.`,
  "comp-partial":
    `        ⭐ THIS IS THE PARTIAL-MIX VARIANT, AND IT FAILING ALONE IS INFORMATIVE:\n` +
    `        'comp-default' sits at mix 1, where the dry term is multiplied by zero, so a\n` +
    `        change confined to the BLEND — or to the soft-knee branch, which the default\n` +
    `        fixture also reaches but less deeply — is visible only here.`,
  "bus-selfkeyed":
    `        This one is on a BUS behind a send. If it moved and comp-partial did not, the\n` +
    `        change is in the send/bus path rather than in the compressor's own arithmetic\n` +
    `        — but bus-control holding says otherwise, so suspect the insert.`,
  "bus-keyed":
    `        ⛔⛔ THIS IS THE SIDECHAIN-KEYED VARIANT AND IT IS THE POINT OF THIS GATE.\n` +
    `        m39-ae restructured the detector's gather loop and this is the only pin that\n` +
    `        executes its KEYED limb. If this moved and 'bus-selfkeyed' did not, the change\n` +
    `        is in the keyed branch specifically: the key-underrun path, the key channel\n` +
    `        count, or the order of the key gather.`,
};

for (const name of EFFECT_VARIANTS) {
  const rendered = byVariant.get(name).sha256;
  if (rendered === PINS[name]) continue;
  failures.push(
    `THE SHIPPED COMPRESSOR CHANGED — variant '${name}'.\n` +
    `      rendered ${rendered}\n` +
    `      pinned   ${PINS[name]}\n` +
    `      Both controls are bit-identical, so the whole difference is inside the insert.\n` +
    `      Every existing user project containing a compressor now sounds different. The\n` +
    `      ways m39-ae can cause this:\n` + WHY[name]);
}

// ── LEG 3: INVARIANCE — the pinned variants must be DIFFERENT files ─────────
// ⭐ CARRY INVARIANCE CONTROLS, NOT JUST THE HEADLINE. Every hash here is
// checked against a pin, so "the compressor vanished from the chain" would
// already redden several legs — but a future edit that made `fx.add` silently
// drop the effect WHILE someone re-pinned the hashes from the broken build would
// leave this gate green and meaningless. All six renders describe different
// audio and must keep doing so.
const all = Object.keys(PINS).map((n) => byVariant.get(n).sha256);
if (new Set(all).size !== all.length) {
  failures.push(
    `two or more of the ${all.length} pinned renders are BYTE-IDENTICAL ` +
    `(${new Set(all).size} distinct hashes). Either the compressor is not in the chain, or ` +
    `it is doing nothing, or two settings are no longer different settings — and the pins ` +
    `above would then be pinning the same audio twice.`);
}
// ⭐ AND SPECIFICALLY: the key must still be doing something. If these two
// collapsed together, `fx.setSidechain` became a no-op and 'bus-keyed' would go
// on passing its pin while covering nothing.
if (byVariant.get("bus-keyed").sha256 === byVariant.get("bus-selfkeyed").sha256) {
  failures.push(
    `bus-keyed and bus-selfkeyed rendered IDENTICAL bytes. They differ by exactly one ` +
    `command — fx.setSidechain — so the key is no longer reaching the detector. The keyed ` +
    `pin above would still pass while proving nothing about the branch it exists to cover.`);
}

// ── report ──────────────────────────────────────────────────────────────────
for (const n of notes) console.log(`  · ${n}`);
if (failures.length > 0) {
  console.error(`\nm39ae-compressor-default-bytes: ${failures.length} failure(s).\n`);
  for (const f of failures) console.error(`  ✘ ${f}`);
  process.exit(1);
}
console.log(
  `\nm39ae-compressor-default-bytes: OK — a compressor at its default, at a partial blend, ` +
  `on a bus, and SIDECHAIN-KEYED all render BIT-FOR-BIT what they rendered before the ` +
  `de-ess detector existed, and both controls prove the rest of the pipeline is unchanged.`);
