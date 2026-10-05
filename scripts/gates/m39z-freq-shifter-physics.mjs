#!/usr/bin/env node
// m39-z — THE FREQUENCY SHIFTER'S PHYSICS GATE.
//
// ⛔⛔ **THIS GATE ASSERTS PHYSICS, NOT DIFFERENCE, AND THE DISTINCTION IS THE
// WHOLE REASON IT EXISTS.** Measured in this tree on 2026-09-19: a COMPLETELY
// INERT effect still rendered byte-DISTINCT variants, because the harness's
// per-variant output trims differed. "The hashes are all different" is therefore
// worth nothing as evidence that an effect did anything, and a gate built on it
// reads as rigorous while being unfalsifiable.
//
// So this gate measures THREE SPECTRAL BINS off the rendered audio and asserts
// the shape that ONLY single-sideband modulation produces:
//
//   · the WANTED sideband at f0 + shift is PRESENT
//   · the UNWANTED image at f0 − shift is SUPPRESSED by >= REJECTION_FLOOR_DB
//   · the CARRIER at f0 itself is SUPPRESSED by >= REJECTION_FLOOR_DB
//
// Each assertion names a different wrong implementation:
//   · an INERT effect fails the first (nothing at f0 + shift);
//   · a RING MODULATOR fails the second — it is double-sideband, so its two
//     sidebands come out within a fraction of a dB of each other. ⚠️ This is
//     ONE CHARACTER away in the all-pass difference equation: writing
//     `a*(x − y2) + x2` instead of `a*(x + y2) − x2` is still a valid all-pass,
//     still destroys the quadrature, and still sounds metallic;
//   · a TREMOLO / amplitude modulator fails the third — it keeps the original.
//
// ⛔ THERE IS DELIBERATELY NO BYTE LEG IN THIS GATE AT ALL. The `mix == 0`
// bit-exact-dry law (rule 6.0.7) would have been the one byte assertion worth
// making — an IDENTITY, which cannot be satisfied by accident the way a
// DIFFERENCE can — but `render-variants.mjs` fails any set containing two
// byte-identical renders, with no opt-out and for a stated reason. So that law
// is proven by `FreqShifterTests` L6 instead, which is strictly stronger than a
// file hash: it compares BIT PATTERNS sample by sample over a buffer seeded
// with −0.0 and subnormals, with every other knob non-default.
//
// Exit codes follow the `doc-count-drift.mjs` / `m39y-…-bytes.mjs` convention:
//   0 = pass · 1 = a real failure · 3 = REFUSED TO SCORE (a self-control failed)

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readMonoFloat } from "./_measure-dsp.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SET_DIR = "scripts/demos/out/freq-shifter-physics";
const SAMPLE_RATE = 48_000;

// The fixture's one partial: MIDI 69 = 440.000 Hz exactly, and the shift the
// spec applies. Both are properties of the SPEC, so they are re-read from the
// spec below rather than trusted here — see the self-controls.
const F0_HZ = 440;
const SHIFT_HZ = 200;

// ⛔ THE GATE'S NUMBER. Measured end-to-end at **49.75 dB** (rendered sine,
// Goertzel probe) and predicted at 49.67 dB from the network's 0.376° worst
// phase error — two independent instruments agreeing to 0.1 dB. The gate floor
// is set at 30 dB, a deliberate ~20 dB of margin:
//   · wide enough that a rebuild, a different ffmpeg resampler or a
//     synth-envelope change cannot flicker it;
//   · narrow enough that the failure it exists to catch is nowhere near it —
//     losing the quadrature collapses the rejection to ~0 dB, not to 25.
// ⚠️ RAISE THIS IF THE MEASURED VALUE EVER DROPS TOWARD IT. A gate that sits
// just under a degrading measurement is a gate that will pass the regression.
const REJECTION_FLOOR_DB = 30;

// A tone that is PRESENT must be at least this far above the analysis floor.
const PRESENCE_FLOOR_DB = -60;

const failures = [];
const selfControlFailures = [];
const notes = [];

// ── instrument ──────────────────────────────────────────────────────────────

/// Hann-windowed Goertzel magnitude at an arbitrary frequency.
///
/// ⚠️ THE WINDOW IS LOAD-BEARING, NOT COSMETIC. With a rectangular window the
/// spectral leakage floor around a full-scale tone is about −52 dB, which is
/// ABOVE the ~−50 dB rejection being measured — the gate would be reading its
/// own window rather than the effect and would report a pass no matter what the
/// DSP did. Hann's sidelobes fall away as 1/k³, so 200 Hz from the peak the
/// leakage is far below anything asserted here.
function goertzelHann(x, hz, from, count) {
  const k = (2 * Math.PI * hz) / SAMPLE_RATE;
  const coeff = 2 * Math.cos(k);
  let s1 = 0, s2 = 0, windowSum = 0;
  for (let n = 0; n < count; n++) {
    const w = 0.5 - 0.5 * Math.cos((2 * Math.PI * n) / (count - 1));
    windowSum += w;
    const s0 = w * x[from + n] + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  const re = s1 - s2 * Math.cos(k);
  const im = s2 * Math.sin(k);
  // Normalised by the window's coherent gain so a full-scale sine reads ~1.0.
  return (2 * Math.hypot(re, im)) / windowSum;
}

const db = (v) => (v > 0 ? 20 * Math.log10(v) : -300);

/// The three bins, measured over the steady middle of a render.
function bins(path) {
  const x = readMonoFloat(resolve(ROOT, path), SAMPLE_RATE);
  // Skip the synth's attack and any effect start-up; analyse 4 s of steady tone.
  const from = SAMPLE_RATE;
  const count = Math.min(4 * SAMPLE_RATE, x.length - from - SAMPLE_RATE);
  if (count < SAMPLE_RATE) {
    throw new Error(`${path} is too short to analyse (${x.length} samples)`);
  }
  return {
    frames: x.length,
    up: db(goertzelHann(x, F0_HZ + SHIFT_HZ, from, count)),
    down: db(goertzelHann(x, F0_HZ - SHIFT_HZ, from, count)),
    centre: db(goertzelHann(x, F0_HZ, from, count)),
  };
}

// ── self-controls: refuse to score rather than score wrongly ────────────────

const manifestPath = resolve(ROOT, SET_DIR, "manifest.json");
let manifest = null;
if (!existsSync(manifestPath)) {
  selfControlFailures.push(
    `${SET_DIR}/manifest.json does not exist. Render it first: ` +
    `node scripts/demos/render-variants.mjs scripts/demos/specs/freq-shifter-physics.json`);
} else {
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch (error) {
    selfControlFailures.push(`${SET_DIR}/manifest.json does not parse: ${error.message}`);
  }
}

if (manifest) {
  // ⛔⛔ FRESHNESS FIRST. A gate here passed a completely inert effect on
  // 2026-09-19 by scoring a manifest from a previous build: every figure it
  // printed was true of a binary that no longer existed. Comparing the
  // manifest's `buildSha256` against the binary on disk NOW costs one hash and
  // turns a stale pass into an honest "cannot score".
  const binPath = manifest.binaryPath
    ? resolve(ROOT, manifest.binaryPath)
    : resolve(ROOT, ".build/debug/DemoRender");
  if (!manifest.buildSha256) {
    selfControlFailures.push(
      `${SET_DIR}/manifest.json carries no buildSha256 — its provenance cannot be checked, ` +
      `so its numbers cannot be trusted. Re-render with the current harness.`);
  } else if (!existsSync(binPath)) {
    selfControlFailures.push(
      `${SET_DIR}: the DemoRender binary named by the manifest is gone (${binPath}); ` +
      `nothing can confirm these renders came from the code in this tree.`);
  } else {
    const liveSha = createHash("sha256").update(readFileSync(binPath)).digest("hex");
    if (liveSha !== manifest.buildSha256) {
      selfControlFailures.push(
        `${SET_DIR}: STALE MANIFEST — rendered by DemoRender ` +
        `${manifest.buildSha256.slice(0, 12)}…, but the binary on disk is ` +
        `${liveSha.slice(0, 12)}…. These renders describe a different build. Re-render: ` +
        `node scripts/demos/render-variants.mjs scripts/demos/specs/freq-shifter-physics.json`);
    }
  }

  const variants = manifest.variants ?? [];
  if (variants.length < 4) {
    selfControlFailures.push(`${SET_DIR}: ${variants.length} variant(s), expected >= 4`);
  }
  for (const v of variants) {
    if (v.ok !== true) {
      selfControlFailures.push(`${SET_DIR}/${v.name}: render did not succeed (${v.error})`);
    }
    if (typeof v.sha256 !== "string" || v.sha256.length < 40) {
      selfControlFailures.push(`${SET_DIR}/${v.name}: no usable sha256`);
    }
    if (!v.path || !existsSync(resolve(ROOT, v.path))) {
      selfControlFailures.push(`${SET_DIR}/${v.name}: rendered wav is missing (${v.path})`);
    }
  }

  // The spec's own numbers must be the ones this gate hard-codes, or the gate
  // is measuring bins the fixture never had anything in.
  const specPath = resolve(ROOT, "scripts/demos/specs/freq-shifter-physics.json");
  if (!existsSync(specPath)) {
    selfControlFailures.push(`the spec is missing: ${specPath}`);
  } else {
    const spec = JSON.parse(readFileSync(specPath, "utf8"));
    const up = spec.variants.find((v) => v.name === "shift-up-200");
    const fx = up?.commands?.find((c) => c.command === "fx.add");
    if (fx?.params?.params?.shiftHz !== SHIFT_HZ) {
      selfControlFailures.push(
        `the spec's shift-up-200 shifts by ${fx?.params?.params?.shiftHz} Hz but this gate ` +
        `measures bins for ${SHIFT_HZ} Hz — one of them has drifted.`);
    }
    const midi = up?.commands?.find((c) => c.command === "clip.addMIDI");
    const pitch = midi?.params?.notes?.[0]?.pitch;
    const expected = Math.round(69 + 12 * Math.log2(F0_HZ / 440));
    if (pitch !== expected) {
      selfControlFailures.push(
        `the spec plays MIDI ${pitch} but this gate measures bins around ${F0_HZ} Hz ` +
        `(MIDI ${expected}) — one of them has drifted.`);
    }
  }
}

if (selfControlFailures.length > 0) {
  console.error("m39z-freq-shifter-physics: REFUSING TO SCORE.\n");
  for (const f of selfControlFailures) console.error(`  · ${f}`);
  console.error(
    "\nA gate that cannot read its own input must not report an all-clear. " +
    "Exit 3 is NOT a pass.");
  process.exit(3);
}

const byName = new Map(manifest.variants.map((v) => [v.name, v]));
const need = (name) => {
  const v = byName.get(name);
  if (!v) {
    selfControlFailures.push(`${SET_DIR}: no variant named "${name}"`);
    return null;
  }
  return v;
};

const control = need("no-shifter");
const small = need("shift-up-40");
const up = need("shift-up-200");
const down = need("shift-down-200");
if (selfControlFailures.length > 0) {
  console.error("m39z-freq-shifter-physics: REFUSING TO SCORE.\n");
  for (const f of selfControlFailures) console.error(`  · ${f}`);
  process.exit(3);
}

// ── LEG 0: THE PROBE'S OWN POSITIVE CONTROL ─────────────────────────────────
// ⭐ A NEGATIVE RESULT FROM A HAND-BUILT PROBE IS THE WEAKEST EVIDENCE THERE IS.
// Before any absence below is believed, the probe must be shown to FIND a tone
// where one certainly is, and to report a floor where one certainly is not —
// on the control render, whose content is known: one 440 Hz sine, nothing else.
const controlBins = bins(control.path);
notes.push(
  `probe control (bare 440 Hz tone): @440 ${controlBins.centre.toFixed(2)} dB, ` +
  `@640 ${controlBins.up.toFixed(2)} dB, @240 ${controlBins.down.toFixed(2)} dB`);
if (controlBins.centre < PRESENCE_FLOOR_DB) {
  failures.push(
    `PROBE IS BLIND: the bare tone's own 440 Hz reads ${controlBins.centre.toFixed(2)} dB. ` +
    `Every "this bin is empty" result below would be meaningless.`);
}
if (controlBins.centre - controlBins.up < REJECTION_FLOOR_DB
    || controlBins.centre - controlBins.down < REJECTION_FLOOR_DB) {
  failures.push(
    `PROBE IS TOO BLUNT: on a bare 440 Hz sine the 640/240 Hz bins read ` +
    `${controlBins.up.toFixed(2)}/${controlBins.down.toFixed(2)} dB against 440 Hz's ` +
    `${controlBins.centre.toFixed(2)} dB — less than ${REJECTION_FLOOR_DB} dB of separation, ` +
    `so it cannot resolve the rejection it is being asked to measure.`);
}

// ── LEG 1: THE SMALL SHIFT LANDS WHERE IT SHOULD ────────────────────────────
// ⭐ A SECOND SHIFT SIZE, because every assertion below is of the form "energy
// moved by exactly the commanded amount", and with ONE size a build that had
// hard-coded 200 Hz somewhere would satisfy all of them.
{
  const x = readMonoFloat(resolve(ROOT, small.path), SAMPLE_RATE);
  const from = SAMPLE_RATE;
  const count = Math.min(4 * SAMPLE_RATE, x.length - from - SAMPLE_RATE);
  const at480 = db(goertzelHann(x, F0_HZ + 40, from, count));
  const at640 = db(goertzelHann(x, F0_HZ + SHIFT_HZ, from, count));
  notes.push(
    `shift-up-40: @480 ${at480.toFixed(2)} dB · @640 ${at640.toFixed(2)} dB ` +
    `(the +200 bin, which must be empty here)`);
  if (at480 < PRESENCE_FLOOR_DB) {
    failures.push(
      `shift-up-40: nothing at 480 Hz (${at480.toFixed(2)} dB) — a +40 Hz shift did not happen.`);
  }
  if (at480 - at640 < REJECTION_FLOOR_DB) {
    failures.push(
      `shift-up-40: the +200 Hz bin reads ${at640.toFixed(2)} dB against 480 Hz's ` +
      `${at480.toFixed(2)} dB. The shift AMOUNT is not following shiftHz.`);
  }
}

// ── LEG 2: THE PHYSICS, up and down ─────────────────────────────────────────
for (const [variant, wantedKey, imageKey, label] of [
  [up, "up", "down", `+${SHIFT_HZ} Hz`],
  [down, "down", "up", `−${SHIFT_HZ} Hz`],
]) {
  const b = bins(variant.path);
  const wanted = b[wantedKey];
  const image = b[imageKey];
  const rejection = wanted - image;
  const carrierRejection = wanted - b.centre;
  notes.push(
    `${variant.name}: wanted ${wanted.toFixed(2)} dB · image ${image.toFixed(2)} dB ` +
    `(rejection ${rejection.toFixed(2)} dB) · carrier ${b.centre.toFixed(2)} dB ` +
    `(rejection ${carrierRejection.toFixed(2)} dB)`);

  if (wanted < PRESENCE_FLOOR_DB) {
    failures.push(
      `${variant.name}: NOTHING arrived at the shifted frequency (${wanted.toFixed(2)} dB). ` +
      `The effect is INERT — this is the failure mode a byte-difference check cannot see.`);
  }
  if (rejection < REJECTION_FLOOR_DB) {
    failures.push(
      `${variant.name}: the UNWANTED sideband is only ${rejection.toFixed(2)} dB down ` +
      `(floor ${REJECTION_FLOOR_DB} dB). This is DOUBLE-sideband modulation — i.e. a RING ` +
      `MODULATOR, not a frequency shifter. Check the all-pass difference equation's signs: ` +
      `it must be y[n] = a*(x[n] + y[n-2]) - x[n-2].`);
  }
  if (carrierRejection < REJECTION_FLOOR_DB) {
    failures.push(
      `${variant.name}: the ORIGINAL ${F0_HZ} Hz tone survives only ` +
      `${carrierRejection.toFixed(2)} dB down (floor ${REJECTION_FLOOR_DB} dB). The dry signal ` +
      `is leaking through the wet path, which makes this an amplitude modulator.`);
  }
  // The shift went the RIGHT WAY: this is what a build that took abs(shiftHz)
  // would fail, and it would fail nothing else in this file.
  if (wanted <= image) {
    failures.push(
      `${variant.name}: shifting by ${label} put MORE energy in the opposite sideband. ` +
      `The sign of shiftHz is not reaching the oscillator.`);
  }
}

// ── report ──────────────────────────────────────────────────────────────────
for (const n of notes) console.log(`  · ${n}`);
if (failures.length > 0) {
  console.error(`\nm39z-freq-shifter-physics: ${failures.length} failure(s).\n`);
  for (const f of failures) console.error(`  ✘ ${f}`);
  process.exit(1);
}
console.log(
  `\nm39z-freq-shifter-physics: OK — single-sideband confirmed off rendered audio ` +
  `at two shift sizes (floor ${REJECTION_FLOOR_DB} dB).`);
