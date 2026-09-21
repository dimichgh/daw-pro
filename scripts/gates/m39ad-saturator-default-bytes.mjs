#!/usr/bin/env node
// m39-ad — THE SATURATOR'S DEFAULT IS BIT-FOR-BIT WHAT IT ALWAYS WAS.
//
// ⛔⛔ **THIS IS THE GATE THE WHOLE ITEM TURNS ON.** `.saturator` is a SHIPPED
// kind: there are already user projects with one in a chain. m39-ad adds an
// `oversampling` control to it. If adding that control changed what the effect
// does at its EXISTING settings, every one of those projects would change tone
// AND shift in time by the 32 samples the filters cost — silently, on the next
// open. The repo has a binding precedent for this shape (the "bend range default
// stays 2.0" ruling): when capability is added to a shipped thing, the default
// must preserve existing behaviour, and the preservation is proven by a
// BYTE-IDENTICAL RENDER, not by argument.
//
// So this gate pins ONE number: the sha256 of a render of a freshly-added,
// untouched saturator, captured from the build that existed BEFORE the parameter
// did. If `oversampling` defaults to 1, and factor 1 SKIPS the oversampling path
// outright rather than running it at factor 1, that hash cannot move.
//
// ## ⛔⛔ TWO SATURATOR VARIANTS, AND THE SECOND ONE IS NOT REDUNDANT
//
// MEASURED DURING THIS BUILD, and it is the most useful thing this file knows:
// `mix` defaults to 1, so at the default `dryGain` is ZERO and the blend
// degenerates to `dry·0 + wet·1`. Replacing the blend with the algebraically
// identical but differently-rounded `(dry − wet)·dryGain + wet` — the classic
// reassociation, and exactly the shape that was invisible to fifteen unit tests
// of another kind in this tree — changed NOTHING at the default. It passed this
// gate. It passed every unit test. It is a TRUE negative (both forms really are
// exact when `dryGain` is 0), and that is precisely the problem: **a pin taken
// only at the default cannot see the blend path at all.**
//
// So `sat-partial` renders the same tone at drive 29 / mix 0.37 / trim −5, where
// every term of the blend is live, and its bytes are pinned too.
//
// ## The invariance control, and why it is not optional
//
// A frozen file hash is a brittle instrument: it moves if ANY part of the render
// pipeline moves — the synth, the mixer, the offline renderer, the wav writer.
// Without a control, an unrelated engine change would redden this gate and read
// as "the saturator regressed", which is a false accusation that costs more than
// the gate saves.
//
// So a CONTROL hash is pinned from the SAME render of the SAME fixture:
//
//   · `no-saturator` — the identical tone with NO effect in the chain at all.
//     It is a pure measurement of the pipeline AROUND the saturator.
//
// and the legs say different things:
//
//   CONTROL MOVED  → the render pipeline changed for reasons that have nothing
//                    to do with this effect. EXIT 3, "cannot score": the pins
//                    must be re-derived, and this gate refuses to call that a
//                    saturator regression.
//   CONTROL SAME,
//   A SATURATOR
//   VARIANT MOVED  → EXIT 1. Everything upstream and downstream of the insert is
//                    bit-identical and the only thing that changed is what the
//                    saturator did. That IS the regression this gate exists for.
//
// ## Provenance — and the positive control on the pins themselves
//
// All three hashes describe v0: the last state of this tree in which
// `SaturatorParams` had three fields and `SaturatorEffect.latencySamples` was a
// literal `0`.
//
// ⭐⭐ THEY WERE TAKEN TWICE, FROM TWO DIFFERENT BINARIES, AND AGREED.
//   · `no-saturator` and `sat-default` were first measured from DemoRender
//     `6d1124c638ab…`, built from the working tree before any m39-ad edit, and
//     repeated into two output directories with identical bytes.
//   · All three were then measured again from DemoRender `0efc2596b6dc…`, a
//     COLD build of commit `a338854` in a separate `git worktree` — a different
//     binary by hash, from the same source. It reproduced the first two hashes
//     EXACTLY, which is what makes the third one (`sat-partial`, which the first
//     capture did not include) trustworthy rather than merely recorded.
//
// A file hash is only usable as an instrument if it is reproducible; that is the
// measurement which established it, rather than an assumption.
//
// Exit codes: 0 pass · 1 THE SHIPPED BEHAVIOUR CHANGED · 3 REFUSED TO SCORE.

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SET_DIR = "scripts/demos/out/saturator-oversampling";
const SPEC_PATH = "scripts/demos/specs/saturator-oversampling.json";

// ⛔ THE PINS. MEASURED, not computed — see "Provenance" above.
const V0_BINARY_SHA = "6d1124c638abb3cb15dd714e3cec8d9d779eee2653d90dcbc243fc37cd8c0063";
const V0_WORKTREE_BINARY_SHA =
  "0efc2596b6dc34aebfc1bb14102be0145f342219c470d7314cce3a53b1bb82c4";
const CONTROL = "no-saturator";
const PINS = {
  [CONTROL]: "2179c070c50e91091b69b9ebe7e6b37e3dfa2229e369d71edfbe19bea3e979de",
  "sat-default": "63c6366c535f6f50909bb17c188a9a7aac0d1d0d58d74e798685158346a55a84",
  "sat-partial": "e39d52919429b33fe415b2cf6042944cdae561cd7365995e4f27b8d701a79ccc",
};
/// The variants that describe the EFFECT (everything but the control).
const SATURATOR_VARIANTS = Object.keys(PINS).filter((name) => name !== CONTROL);

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
        (liveSha === V0_BINARY_SHA || liveSha === V0_WORKTREE_BINARY_SHA
          ? ` — and it is one of the v0 builds the pins were taken from, so this run is ` +
            `a self-check of the gate rather than a check of a change`
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
    // ⛔ `sat-default` must add a saturator and set NOTHING. A `params` object —
    // even one spelling out today's defaults — would make this a pin on those
    // literal numbers rather than on THE DEFAULT, and the day a default changed
    // the gate would stay green while every new saturator changed.
    const def = byName.get("sat-default");
    const defFx = def?.commands?.filter((c) => c.command === "fx.add") ?? [];
    if (defFx.length !== 1 || defFx[0].params?.kind !== "saturator") {
      selfControlFailures.push(
        `the spec's sat-default does not add exactly one saturator ` +
        `(${defFx.length} fx.add, kind '${defFx[0]?.params?.kind}')`);
    } else if (defFx[0].params.params !== undefined) {
      selfControlFailures.push(
        `the spec's sat-default passes a 'params' object to fx.add. It must pass NONE: ` +
        `this gate pins THE DEFAULT, and spelling the defaults out in the fixture would ` +
        `pin the numbers instead — the gate would then stay green through a default change.`);
    }
    // ⛔ `sat-partial` must use a PARTIAL mix, or it is a second copy of
    // `sat-default`'s blind spot rather than the cover for it. At mix 1 the dry
    // term is multiplied by zero and a reassociated blend is exact; at mix 0 the
    // wet term is. Only strictly between the two is every term live.
    const partialFx = byName.get("sat-partial")?.commands
      ?.find((c) => c.command === "fx.add");
    const partialMix = partialFx?.params?.params?.mix;
    if (partialFx?.params?.kind !== "saturator") {
      selfControlFailures.push(
        `the spec's sat-partial adds '${partialFx?.params?.kind}', not a saturator`);
    }
    if (!(typeof partialMix === "number" && partialMix > 0.01 && partialMix < 0.99)) {
      selfControlFailures.push(
        `the spec's sat-partial is at mix ${partialMix}. It exists SPECIFICALLY to exercise ` +
        `the blend, and at mix 0 or 1 one of the two terms is multiplied by zero — which is ` +
        `exactly how a differently-rounded blend passed this gate during the m39-ad build.`);
    }
    // ⛔ …and it must NOT set `oversampling`. The pin came from a build where
    // that key did not exist; a fixture that sets it is asking a different
    // question from the one the hash answers.
    if (partialFx?.params?.params?.oversampling !== undefined) {
      selfControlFailures.push(
        `the spec's sat-partial sets 'oversampling'. Its pinned hash was measured on a build ` +
        `where that parameter did not exist, so the fixture must not mention it.`);
    }
    // ⛔ And the control must carry NO effect at all, or it measures the
    // pipeline AND the saturator and cannot separate them.
    const control = byName.get(CONTROL);
    if (control?.commands?.some((c) => c.command === "fx.add")) {
      selfControlFailures.push(
        `the spec's no-saturator variant adds an effect — it is not a control, and the ` +
        `"pipeline moved vs saturator moved" split below would be meaningless.`);
    }
    // Every pinned variant must play the SAME source, or the control controls
    // nothing.
    const sourceOf = (v) => JSON.stringify(
      (v?.commands ?? []).filter((c) => c.command !== "fx.add"));
    for (const name of SATURATOR_VARIANTS) {
      if (sourceOf(control) !== sourceOf(byName.get(name))) {
        selfControlFailures.push(
          `the spec's ${CONTROL} and ${name} variants do not play an identical source ` +
          `(their non-fx commands differ). The control can only separate "the pipeline ` +
          `moved" from "the saturator moved" if everything except the insert is the same.`);
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
  console.error("m39ad-saturator-default-bytes: REFUSING TO SCORE.\n");
  for (const f of selfControlFailures) console.error(`  · ${f}`);
  console.error(
    "\nA gate that cannot read its own input must not report an all-clear. " +
    "Exit 3 is NOT a pass.");
  process.exit(3);
}

// ── LEG 1: THE CONTROL — did the pipeline around the insert move? ───────────

const byVariant = new Map(manifest.variants.map((v) => [v.name, v]));
const controlSha = byVariant.get(CONTROL).sha256;

notes.push(`${CONTROL.padEnd(13)} (control): ${controlSha}`);
for (const name of SATURATOR_VARIANTS) {
  notes.push(`${name.padEnd(13)}          : ${byVariant.get(name).sha256}`);
}

if (controlSha !== PINS[CONTROL]) {
  console.error("m39ad-saturator-default-bytes: REFUSING TO SCORE.\n");
  console.error(
    `  · THE CONTROL MOVED. The same tone with NO effect in the chain rendered\n` +
    `    ${controlSha}\n` +
    `    but this gate pins\n` +
    `    ${PINS[CONTROL]}\n` +
    `    from DemoRender ${V0_BINARY_SHA.slice(0, 12)}… on 2026-09-20.\n\n` +
    `    Something in the render pipeline changed that has NOTHING to do with the\n` +
    `    saturator — the synth, the mixer, the offline renderer, the wav writer, or\n` +
    `    the fixture itself. This gate will not call that a saturator regression.\n\n` +
    `    TO RE-PIN HONESTLY: the pins must be re-derived from a build in which the\n` +
    `    saturator's behaviour is KNOWN good, not from whatever is in the tree now.\n` +
    `    Re-deriving them from the current build would make this gate a tautology.`);
  process.exit(3);
}
notes.push("⭐ CONTROL HOLDS — everything around the insert is bit-identical to v0");

// ── LEG 2: THE SATURATOR VARIANTS ───────────────────────────────────────────

for (const name of SATURATOR_VARIANTS) {
  const rendered = byVariant.get(name).sha256;
  if (rendered === PINS[name]) continue;
  failures.push(
    `THE SHIPPED SATURATOR CHANGED — variant '${name}'.\n` +
    `      rendered ${rendered}\n` +
    `      pinned   ${PINS[name]}\n` +
    `      The control is bit-identical, so the whole difference is inside the insert.\n` +
    `      Every existing user project containing a saturator now sounds different, or\n` +
    `      is shifted in time, or both. The ways m39-ad can cause this:\n` +
    `        · 'oversampling' does not default to 1;\n` +
    `        · factor 1 RUNS the oversampler instead of SKIPPING it (which is a 32-sample\n` +
    `          shift even when the filter is mathematically a unit delay);\n` +
    `        · the 1x arithmetic was rewritten — a different expression order, a\n` +
    `          REASSOCIATED blend, or per-sample interpolation where v0 had a constant.\n` +
    (name === "sat-partial"
      ? `      ⭐ THIS IS THE PARTIAL-MIX VARIANT, AND IT FAILING ALONE IS INFORMATIVE:\n` +
        `      'sat-default' sits at mix 1, where the dry term is multiplied by zero, so a\n` +
        `      change confined to the BLEND is invisible there and visible only here.`
      : `      ⚠️ If ONLY this variant failed and 'sat-partial' passed, the change is in the\n` +
        `      drive/shaper/trim path rather than the blend.`));
}

// ── LEG 3: INVARIANCE — the pinned variants must be DIFFERENT files ─────────
// ⭐ CARRY INVARIANCE CONTROLS, NOT JUST THE HEADLINE. Every hash here is
// checked against a pin, so a "the saturator vanished from the chain" defect
// would already redden two legs — but a future edit that made `fx.add` silently
// drop the effect WHILE someone re-pinned the hashes from the broken build would
// leave this gate green and meaningless. All three renders describe different
// audio and must keep doing so.
const distinct = new Set([controlSha, ...SATURATOR_VARIANTS.map((n) => byVariant.get(n).sha256)]);
if (distinct.size !== 1 + SATURATOR_VARIANTS.length) {
  failures.push(
    `two or more of the ${1 + SATURATOR_VARIANTS.length} pinned renders are BYTE-IDENTICAL ` +
    `(${distinct.size} distinct hashes). Either the saturator is not in the chain, or it is ` +
    `doing nothing, or the two settings are no longer different settings — and the pins ` +
    `above would then be pinning the same audio twice.`);
}

// ── report ──────────────────────────────────────────────────────────────────
for (const n of notes) console.log(`  · ${n}`);
if (failures.length > 0) {
  console.error(`\nm39ad-saturator-default-bytes: ${failures.length} failure(s).\n`);
  for (const f of failures) console.error(`  ✘ ${f}`);
  process.exit(1);
}
console.log(
  `\nm39ad-saturator-default-bytes: OK — a saturator at its default AND at a partial blend ` +
  `both render BIT-FOR-BIT what they rendered before 'oversampling' existed, and the ` +
  `control proves the rest of the pipeline is unchanged too.`);
