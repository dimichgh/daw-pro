#!/usr/bin/env node
// m39-ac — THE CLIPPER'S PHYSICS GATE: the alias floor, measured off rendered
// audio.
//
// ⛔⛔ **AN OVERSAMPLED CLIPPER AND A NAIVE ONE ARE BOTH LOUD, AND THAT IS THE
// WHOLE REASON THIS FILE EXISTS.** They have the same loudness, the same peak,
// the same harmonics and byte-distinct renders. `render-variants.mjs` will exit
// 0 with `audible=true` on every variant whether the oversampler works or not —
// measured in this tree on 2026-09-20, where a COMPLETELY INERT shaper produced
// four distinct renders and passed a hardened byte gate, because per-variant
// output trims kept the bytes apart. **Identical bytes prove an axis did
// nothing; DISTINCT bytes prove nothing at all.**
//
// The one real quality number a clipper has is its ALIAS FLOOR: hard clipping
// is odd-symmetric, so a single sine at f0 comes out as f0 plus odd harmonics,
// and every odd harmonic above Nyquist FOLDS BACK onto a frequency unrelated to
// anything playing. Oversampling exists to suppress exactly that and nothing
// else. So this gate reads five spectral bins that are EMPTY before the effect
// runs, at three oversampling factors, and asserts:
//
//   · the CONTROL render has those bins empty (the probe is not seeing ghosts)
//   · `clip-1x` FILLS them (the naive path really does alias — without this,
//     every "it went down" number below would be a comparison against nothing)
//   · `clip-4x` drops the total by >= FLOOR_DB against `clip-1x`
//   · the improvement is MONOTONIC: 1x > 2x > 4x, so the factor is really
//     selecting a different filter rather than the same one three times
//   · H1 and H3 — REAL harmonics of the clipping, both below Nyquist — are
//     UNMOVED across all three factors
//
// Each assertion names a different wrong implementation:
//   · an oversampler whose FACTOR never reaches the primitive fails the delta
//     AND the monotonicity (MEASURED with that plant: delta 0.00 dB);
//   · a missing ANTI-IMAGING filter on the way up fails the delta AND the H3 leg
//     (MEASURED with sample-and-hold interpolation planted: delta 1.30 dB here,
//     1.22 dB on `ClipperTests` L1's tone — two instruments, same verdict);
//   · a missing ANTI-ALIAS filter on the way down fails the delta (MEASURED:
//     delta −0.00 dB);
//   · an implementation that just LOW-PASSES the output would satisfy every
//     alias assertion and fails the H3 leg instead.
//
// ⛔ THERE IS DELIBERATELY NO BYTE LEG. The `mix == 0` law worth asserting as an
// IDENTITY is this kind's DELAYED identity (`out[n] == in[n−32]`), and
// `render-variants.mjs` fails any set containing two byte-identical renders
// with no opt-out — so that law is proven by `ClipperTests` L5 instead, which is
// strictly stronger than a file hash: it compares BIT PATTERNS sample by sample
// over a buffer seeded with −0.0 and subnormals, with every other knob
// non-default.
//
// Exit codes follow the `m39z-freq-shifter-physics.mjs` convention:
//   0 = pass · 1 = a real failure · 3 = REFUSED TO SCORE (a self-control failed)

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readMonoFloat } from "./_measure-dsp.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SET_DIR = "scripts/demos/out/clipper-physics";
const SPEC_PATH = "scripts/demos/specs/clipper-physics.json";
const SAMPLE_RATE = 48_000;

// The fixture's one partial: MIDI 115. Derived here rather than written down, so
// the gate and the spec cannot drift apart on a rounding; the self-controls
// below re-read the spec's actual pitch and compare.
const MIDI_PITCH = 115;
const F0_HZ = 440 * Math.pow(2, (MIDI_PITCH - 69) / 12);   // 6271.927 Hz

/// Where an odd harmonic lands after folding at `SAMPLE_RATE`. Real arithmetic,
/// not a table — a table is a second statement of the same fact.
function folded(hz) {
  let f = hz % SAMPLE_RATE;
  if (f > SAMPLE_RATE / 2) f = SAMPLE_RATE - f;
  return f;
}

// ⛔ THE FIVE MEASURED BINS. H5, H7, H9, H13, H15 — each above Nyquist, each
// folding to a frequency that is NOT a multiple of f0.
const ALIAS_BINS = [5, 7, 9, 13, 15].map((k) => ({ harmonic: k, hz: folded(k * F0_HZ) }));
// ⚠️ H11 folds to ~20 991 Hz, which is ABOVE the design's protected band
// (`OversamplerDesign.stopbandEdgeFraction` mirrors to 0.42 × 48 kHz = 20 160
// Hz), so the decimation filter is only partway into its stopband there. It is
// REPORTED and never summed — excluding it quietly would be flattering the
// number, and including it would fail a gate for doing exactly what the design
// says it does.
const UNPROTECTED_BIN = { harmonic: 11, hz: folded(11 * F0_HZ) };
// The two REAL harmonics, both below Nyquist. These must NOT move.
const HARMONIC_BINS = [{ harmonic: 1, hz: F0_HZ }, { harmonic: 3, hz: 3 * F0_HZ }];

// ⛔ THE GATE'S NUMBER. THIS gate measures 91.05 dB on the fixture below.
// ⚠️ A SECOND, INDEPENDENT INSTRUMENT DISAGREES BY 35 dB AND BOTH ARE RIGHT:
// `ClipperTests` L1 (offline render inside the suite, its own Goertzel probe)
// reads 55.57 dB — a different tone (6300 Hz), a different clip depth, a
// different analysis window. Neither is instrument-limited: this gate's 4x floor
// (-119.86 dB) sits ~67 dB above its own CONTROL floor (-187.36 dB), so it is
// reading the filter and not its own noise. They agree on direction, on
// monotonicity, and on every plant. The floor below is
// 25 dB — a deliberate ~30 dB of margin against the SMALLER of the two:
//   · wide enough that a rebuild, a different ffmpeg resampler or a
//     synth-envelope change cannot flicker it;
//   · narrow enough that the failures it exists to catch are nowhere near it —
//     all three planted defects collapsed the delta to under 1.3 dB, not to 20.
//     MEASURED, each through a full re-render of this set and a run of this gate:
//       factor forced to 1 in ClipperEffect ........... 1x->4x   0.00 dB
//       sample-and-hold up, no anti-imaging filter .... 1x->4x   1.30 dB
//       naive decimation, no anti-alias filter ........ 1x->4x  -0.00 dB
//     against 91.05 dB clean, so the healthy value clears the worst plant by ~90 dB.
// ⚠️ RAISE THIS IF THE MEASURED VALUE EVER DROPS TOWARD IT. A gate sitting just
// under a degrading measurement is a gate that will pass the regression.
const FLOOR_DB = 25;
// 2× is genuinely worse than 4× — it cannot remove a harmonic that aliases into
// the passband within its own doubled band. MEASURED at 23.90 dB.
const FLOOR_2X_DB = 10;

// The peak the fixture's tone arrives at the insert with, MEASURED not assumed:
//   ffmpeg -hide_banner -i demo-clipper-physics-no-clipper.wav \
//     -af astats=measure_overall=Peak_level:measure_perchannel=none -f null -
// → Peak level dB: -18.832041. The no-clipper variant IS the insert's input
// signal (same synth, same note, same chain, effect absent) and the chain gain
// from the insert to the file is 1.0 — proved by a scratch render with the
// ceiling at -24 dBFS, whose file peak came back -24.000000.
const SOURCE_PEAK_DBFS = -18.832;
// How far past the ceiling the fixture must push. 6 dB is well under the 11.17 dB
// the spec actually uses, so a synth tweak has room to move without tripping it,
// and well over the -0.832 dB the broken first fixture had.
const MIN_CLIP_DEPTH_DB = 6;

// A tone that is PRESENT must be at least this far above the analysis floor.
const PRESENCE_FLOOR_DB = -60;
// The control's alias bins must be at least this far BELOW `clip-1x`'s, or the
// probe is reading something other than aliasing.
const CONTROL_MARGIN_DB = 30;

const failures = [];
const selfControlFailures = [];
const notes = [];

// ── instrument ──────────────────────────────────────────────────────────────

/// Hann-windowed Goertzel magnitude at an arbitrary frequency.
///
/// ⚠️ THE WINDOW IS LOAD-BEARING. `F0_HZ` is irrational (an equal-tempered MIDI
/// pitch), so nothing here lands on an exact DFT bin and a rectangular window's
/// leakage floor around a full-scale tone would be about −52 dB — far above the
/// −90 dB readings this gate has to resolve. Hann's sidelobes fall as 1/k³, so a
/// few hundred Hz from the peak the leakage is below anything asserted here.
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

/// Every bin this gate cares about, measured over the steady middle of a render.
function bins(path) {
  const x = readMonoFloat(resolve(ROOT, path), SAMPLE_RATE);
  // Skip the synth's attack and any effect start-up; analyse 4 s of steady tone.
  const from = SAMPLE_RATE;
  const count = Math.min(4 * SAMPLE_RATE, x.length - from - SAMPLE_RATE);
  if (count < SAMPLE_RATE) {
    throw new Error(`${path} is too short to analyse (${x.length} samples)`);
  }
  const at = (hz) => goertzelHann(x, hz, from, count);
  // POWER sum, not the loudest bin: oversampling can move energy between folds,
  // and a max-of-bins metric would reward that instead of measuring it.
  let power = 0;
  const per = [];
  for (const b of ALIAS_BINS) {
    const m = at(b.hz);
    power += m * m;
    per.push(`H${b.harmonic}@${b.hz.toFixed(0)}=${db(m).toFixed(1)}`);
  }
  return {
    frames: x.length,
    aliasFloorDb: power > 0 ? 10 * Math.log10(power) : -300,
    perBin: per.join(" "),
    unprotectedDb: db(at(UNPROTECTED_BIN.hz)),
    h1: db(at(HARMONIC_BINS[0].hz)),
    h3: db(at(HARMONIC_BINS[1].hz)),
  };
}

// ── self-controls: refuse to score rather than score wrongly ────────────────

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
        `${manifest.buildSha256.slice(0, 12)}…, but the binary at ${binPath} is ` +
        `${liveSha.slice(0, 12)}…. These renders describe a different build. Re-render: ` +
        `node scripts/demos/render-variants.mjs ${SPEC_PATH}`);
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
    // ⚠️ THE RATE IS NOT ASSUMED. Every frequency in this file is a fraction of
    // 48 000, and a 44.1 kHz render would put every fold somewhere else.
    if (v.sampleRate && v.sampleRate !== SAMPLE_RATE) {
      selfControlFailures.push(
        `${SET_DIR}/${v.name}: rendered at ${v.sampleRate} Hz but every bin this gate ` +
        `measures is derived for ${SAMPLE_RATE} Hz — the folds are elsewhere.`);
    }
  }

  // The spec's own numbers must be the ones this gate derives from, or the gate
  // is measuring bins the fixture never had anything in.
  const specPath = resolve(ROOT, SPEC_PATH);
  if (!existsSync(specPath)) {
    selfControlFailures.push(`the spec is missing: ${specPath}`);
  } else {
    const spec = JSON.parse(readFileSync(specPath, "utf8"));
    const byName = new Map(spec.variants.map((v) => [v.name, v]));
    for (const [name, factor] of [["clip-1x", 1], ["clip-2x", 2], ["clip-4x", 4]]) {
      const fx = byName.get(name)?.commands?.find((c) => c.command === "fx.add");
      if (fx?.params?.kind !== "clipper") {
        selfControlFailures.push(`the spec's ${name} adds '${fx?.params?.kind}', not a clipper`);
      }
      if (fx?.params?.params?.oversampling !== factor) {
        selfControlFailures.push(
          `the spec's ${name} sets oversampling ${fx?.params?.params?.oversampling} but this ` +
          `gate reads it as ${factor} — one of them has drifted.`);
      }
      if (fx?.params?.params?.mode !== 0) {
        selfControlFailures.push(
          `the spec's ${name} is not in HARD mode; the fold-back this gate measures is a ` +
          `property of the flat cut and soft mode makes far less of it.`);
      }
      // ⛔ THE FIXTURE MUST ACTUALLY REACH THE CEILING. This gate's first run
      // measured every alias bin between -175 and -210 dB and H3 at -193 dB —
      // not because the oversampler was broken but because the spec drove the
      // tone to -6.832 dBFS against a -6 dBFS ceiling, so the clipper applied
      // gain and nothing else. Every file rendered, every file was distinct,
      // every file was audibly a loud clean tone. The source level is measured
      // (astats on the no-clipper render: -18.832 dBFS peak) so the depth is
      // arithmetic the gate can check without rendering anything.
      const driveDb = fx?.params?.params?.driveDb;
      const ceilingDb = fx?.params?.params?.ceilingDb;
      const depthDb = SOURCE_PEAK_DBFS + driveDb - ceilingDb;
      if (!Number.isFinite(depthDb) || depthDb < MIN_CLIP_DEPTH_DB) {
        selfControlFailures.push(
          `the spec's ${name} drives to ${(SOURCE_PEAK_DBFS + driveDb).toFixed(3)} dBFS against a ` +
          `${ceilingDb} dBFS ceiling — ${Number.isFinite(depthDb) ? depthDb.toFixed(3) : "?"} dB of ` +
          `clipping depth, under the ${MIN_CLIP_DEPTH_DB} dB this gate requires. A clipper below its ` +
          `ceiling is a gain stage, and every bin below would be vacuously quiet.`);
      }
    }
    // The control must carry NO clipper at all, or "the bins are empty before
    // the effect runs" is not a statement about anything.
    const control = byName.get("no-clipper");
    if (control?.commands?.some((c) => c.command === "fx.add")) {
      selfControlFailures.push(`the spec's no-clipper variant adds an effect — it is not a control`);
    }
    for (const [name, variant] of byName) {
      const midi = variant.commands?.find((c) => c.command === "clip.addMIDI");
      const pitch = midi?.params?.notes?.[0]?.pitch;
      if (pitch !== MIDI_PITCH) {
        selfControlFailures.push(
          `the spec's ${name} plays MIDI ${pitch} but this gate derives every bin from ` +
          `MIDI ${MIDI_PITCH} (${F0_HZ.toFixed(2)} Hz) — one of them has drifted.`);
      }
    }
  }
}

if (selfControlFailures.length > 0) {
  console.error("m39ac-clipper-physics: REFUSING TO SCORE.\n");
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

const control = need("no-clipper");
const one = need("clip-1x");
const two = need("clip-2x");
const four = need("clip-4x");
if (selfControlFailures.length > 0) {
  console.error("m39ac-clipper-physics: REFUSING TO SCORE.\n");
  for (const f of selfControlFailures) console.error(`  · ${f}`);
  process.exit(3);
}

console.log(
  `  · fixture: MIDI ${MIDI_PITCH} = ${F0_HZ.toFixed(3)} Hz at ${SAMPLE_RATE} Hz; ` +
  `alias bins ${ALIAS_BINS.map((b) => `H${b.harmonic}→${b.hz.toFixed(0)}`).join(", ")}; ` +
  `H11→${UNPROTECTED_BIN.hz.toFixed(0)} reported only`);

// ── LEG 0: THE PROBE'S OWN POSITIVE CONTROL ─────────────────────────────────
// ⭐ A NEGATIVE RESULT FROM A HAND-BUILT PROBE IS THE WEAKEST EVIDENCE THERE IS.
// Before "the alias bins are quiet at 4x" is believed, the probe must be shown
// to FIND a tone where one certainly is, and to report a floor where one
// certainly is not — on the control render, whose content is known: one sine.
const controlBins = bins(control.path);
notes.push(
  `no-clipper (bare tone): H1 ${controlBins.h1.toFixed(2)} dB · H3 ` +
  `${controlBins.h3.toFixed(2)} dB · alias floor ${controlBins.aliasFloorDb.toFixed(2)} dB · ` +
  controlBins.perBin);
if (controlBins.h1 < PRESENCE_FLOOR_DB) {
  failures.push(
    `PROBE IS BLIND: the bare tone's own ${F0_HZ.toFixed(0)} Hz reads ` +
    `${controlBins.h1.toFixed(2)} dB. Every "this bin is empty" result below would be ` +
    `meaningless.`);
}

// ── LEG 1: THE NAIVE PATH REALLY ALIASES ────────────────────────────────────
const oneBins = bins(one.path);
notes.push(
  `clip-1x: alias floor ${oneBins.aliasFloorDb.toFixed(2)} dB · H1 ${oneBins.h1.toFixed(2)} · ` +
  `H3 ${oneBins.h3.toFixed(2)} · ${oneBins.perBin}`);
if (oneBins.aliasFloorDb < PRESENCE_FLOOR_DB) {
  failures.push(
    `clip-1x's alias floor is ${oneBins.aliasFloorDb.toFixed(2)} dB — NOTHING folded back, so ` +
    `there is nothing for oversampling to remove and every number below is vacuous. Either the ` +
    `clipper is not clipping or the fixture stopped driving it past the ceiling.`);
}
if (oneBins.aliasFloorDb - controlBins.aliasFloorDb < CONTROL_MARGIN_DB) {
  failures.push(
    `the CONTROL render's alias bins read ${controlBins.aliasFloorDb.toFixed(2)} dB against ` +
    `clip-1x's ${oneBins.aliasFloorDb.toFixed(2)} dB — less than ${CONTROL_MARGIN_DB} dB apart. ` +
    `The probe is reading something that is there WITHOUT the clipper (synth aliasing? leakage ` +
    `from the fundamental?), so it cannot attribute anything to the effect.`);
}

// ── LEG 2: THE PHYSICS — oversampling suppresses the fold ───────────────────
const twoBins = bins(two.path);
const fourBins = bins(four.path);
notes.push(
  `clip-2x: alias floor ${twoBins.aliasFloorDb.toFixed(2)} dB · ${twoBins.perBin}`);
notes.push(
  `clip-4x: alias floor ${fourBins.aliasFloorDb.toFixed(2)} dB · ${fourBins.perBin}`);

const deltaTwo = oneBins.aliasFloorDb - twoBins.aliasFloorDb;
const deltaFour = oneBins.aliasFloorDb - fourBins.aliasFloorDb;
notes.push(
  `⭐ ALIAS-FLOOR DELTA — 1x→2x ${deltaTwo.toFixed(2)} dB, 1x→4x ${deltaFour.toFixed(2)} dB ` +
  `(floors ${FLOOR_2X_DB} / ${FLOOR_DB})`);

if (deltaFour < FLOOR_DB) {
  failures.push(
    `4x oversampling dropped the alias floor by only ${deltaFour.toFixed(2)} dB (floor ` +
    `${FLOOR_DB}). Either the anti-imaging filter, the anti-alias filter, or the factor itself ` +
    `is not reaching the render path. All three of those defects were PLANTED during this ` +
    `build and measured 0.00, 1.30 and -0.00 dB here; clean measures 91.05 dB.`);
}
if (deltaTwo < FLOOR_2X_DB) {
  failures.push(
    `2x oversampling dropped the alias floor by only ${deltaTwo.toFixed(2)} dB ` +
    `(floor ${FLOOR_2X_DB}).`);
}
if (!(fourBins.aliasFloorDb < twoBins.aliasFloorDb
      && twoBins.aliasFloorDb < oneBins.aliasFloorDb)) {
  failures.push(
    `the improvement is not MONOTONIC: 1x ${oneBins.aliasFloorDb.toFixed(2)}, 2x ` +
    `${twoBins.aliasFloorDb.toFixed(2)}, 4x ${fourBins.aliasFloorDb.toFixed(2)} dB. The factor ` +
    `is not selecting a different filter for each setting.`);
}

// ── LEG 3: IT IS NOT JUST A LOW-PASS ────────────────────────────────────────
// ⛔ Anything that quietly removed high frequencies would drop the alias floor
// too — and would also remove H3, which is a REAL harmonic of the clipping and
// must survive untouched. This is the leg a "fix" by low-passing fails.
const h1s = [oneBins.h1, twoBins.h1, fourBins.h1];
const h3s = [oneBins.h3, twoBins.h3, fourBins.h3];
const spread = (a) => Math.max(...a) - Math.min(...a);
notes.push(
  `H1 across 1x/2x/4x: ${h1s.map((v) => v.toFixed(3)).join(", ")} (spread ` +
  `${spread(h1s).toFixed(3)} dB) · H3: ${h3s.map((v) => v.toFixed(3)).join(", ")} (spread ` +
  `${spread(h3s).toFixed(3)} dB)`);
if (spread(h3s) > 1.0) {
  failures.push(
    `H3 (${(3 * F0_HZ).toFixed(0)} Hz, a REAL harmonic of the clipping and well inside the ` +
    `passband) varies by ${spread(h3s).toFixed(2)} dB across the factors. Oversampling is ` +
    `changing the CLIPPING, or low-passing the result — either way it is not doing what it ` +
    `claims.`);
}
if (spread(h1s) > 1.0) {
  failures.push(`H1 varies by ${spread(h1s).toFixed(2)} dB across the factors.`);
}
if (Math.min(...h3s) < PRESENCE_FLOOR_DB) {
  failures.push(
    `H3 reads ${Math.min(...h3s).toFixed(2)} dB — the fixture is barely clipping, so the ` +
    `fold-back this gate measures is not really there.`);
}

// ── LEG 4: the unprotected bin, REPORTED ────────────────────────────────────
notes.push(
  `H11's fold at ${UNPROTECTED_BIN.hz.toFixed(0)} Hz — ABOVE the design's protected band, so ` +
  `NOT in the sum above — 1x ${oneBins.unprotectedDb.toFixed(2)} · 2x ` +
  `${twoBins.unprotectedDb.toFixed(2)} · 4x ${fourBins.unprotectedDb.toFixed(2)} dB`);
if (fourBins.unprotectedDb >= oneBins.unprotectedDb) {
  failures.push(
    `even the unprotected bin did not improve (1x ${oneBins.unprotectedDb.toFixed(2)} → 4x ` +
    `${fourBins.unprotectedDb.toFixed(2)} dB).`);
}

// ── report ──────────────────────────────────────────────────────────────────
for (const n of notes) console.log(`  · ${n}`);
if (failures.length > 0) {
  console.error(`\nm39ac-clipper-physics: ${failures.length} failure(s).\n`);
  for (const f of failures) console.error(`  ✘ ${f}`);
  process.exit(1);
}
console.log(
  `\nm39ac-clipper-physics: OK — alias floor down ${deltaFour.toFixed(2)} dB at 4x ` +
  `(floor ${FLOOR_DB} dB), monotonic across factors, H1/H3 unmoved.`);
