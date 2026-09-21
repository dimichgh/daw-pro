#!/usr/bin/env node
// m39-af — THE DYNAMIC EQ RENDERS WHAT IT RENDERED WHEN IT LANDED, AND WHAT IT
// RENDERS IS THE PHYSICS IT CLAIMS.
//
// ⛔⛔ THIS GATE HAS TWO HALVES AND THE SECOND ONE IS THE IMPORTANT ONE.
//
//   HALF 1 — BYTES. Five pinned sha256s over `scripts/demos/specs/dyneq.json`.
//     This is the `m39ae-compressor-default-bytes` shape and it answers "did the
//     render move".
//
//   HALF 2 — PHYSICS. ⛔⛔ **IDENTICAL BYTES PROVE THE AXIS DID NOTHING, BUT
//     DISTINCT BYTES PROVE NOTHING.** This tree has watched five planted
//     defects pass `audible=true`, and a byte gate alone would pass a dynamic
//     EQ that had silently become a plain volume control. So every variant is
//     also measured through ffmpeg IN its band and OUT of its band, and the
//     assertion is the RELATION between the two: the band at 3 kHz must move by
//     dB while everything under 400 Hz moves by hundredths of a dB. That is what
//     distinguishes "an EQ band that moves" from "the whole thing got quieter",
//     and no hash can see the difference.
//
// ⚠️ WHAT THIS GATE DELIBERATELY DOES **NOT** PIN: the transparency null. A
// default `.dynamicEQ` renders BIT-IDENTICALLY to no effect at all, which would
// be the strongest hash in the file — and it cannot live here, because
// `render-variants.mjs` EXITS 1 when two variants render byte-identical (a law
// added 2026-09-20: "a set with identical renders is a set whose axis is not an
// axis"). The null is proven directly and more strongly instead, on bit
// patterns over a fixture containing NEGATIVE ZERO, by
// `DynamicEQRenderTests.allBandsOffIsBitExact` and
// `.aLiveBandAtZeroRangeIsBitExact`. Stated here so a future reader does not
// read its absence as an oversight.
//
// ⚠️ AND WHAT THE OTHER HALF OF THE TWO-GUARD RULE IS: a byte gate over rendered
// demos is BLIND to a `Codable` decode default, because the harness builds params
// through `fx.add` → the MEMBERWISE init, so `init(from:)` never runs. v1 of this
// kind has NO decode default — all 32 keys are required and a missing one throws
// — and `DynamicEQParamsTests.decodeOfAPartialObjectThrows` freezes that. The
// moment this kind gains its first additive optional, it acquires a decode
// default this gate cannot see, and the non-interchangeability plant is owed in
// both directions (design §10 G2).
//
// Exit codes: 0 pass · 1 THE RENDER OR THE PHYSICS CHANGED · 3 REFUSED TO SCORE.

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SET_DIR = "scripts/demos/out/dyneq";
const SPEC_PATH = "scripts/demos/specs/dyneq.json";

// ⛔ THE PINS. MEASURED from the landing build, not computed.
//
// ⭐⭐ PROVENANCE, AND THE PLANT THAT MATTERS WAS RUN BEFORE THEM.
//   · A first set was measured from DemoRender `568f7f467ebc…`, built from this
//     tree with `DynamicEQEffect.swift` as it landed.
//   · The one-sided rest-snap was then PLANTED, re-rendered (DemoRender
//     `d9bd400f7021…`) and this gate EXITED 1 naming the mechanism — with
//     `boost-12` and `below-12` rendering the CONTROL'S OWN HASH, i.e. a boost
//     band doing literally nothing, while `cut-6` and `cut-18` were bit-for-bit
//     unaffected. ⭐ That is a property of the CODE, not of the fixture, and it
//     is the whole reason the boost variants exist.
//   · The plant was reverted and DemoRender `ca3b75798e0b…` — a different binary
//     by hash — reproduced all five of those first pins exactly.
//   · ⛔⛔ THE FIXTURE WAS THEN REBUILT AND THE PINS RE-DERIVED (DemoRender
//     `4dea22ac27d3…`), because the first fixture FAILED DESIGN §10 G6 and I had
//     not noticed: its source was a single 16-beat chord, and the in-band level
//     across the sustain was MEASURED at -40.94 / -41.07 / -40.87 / -41.04 dB —
//     0.2 dB of swing. A dynamic EQ on a source with no in-band dynamics is a
//     STATIC EQ, so `cut-6` and `cut-18` (a 6 dB cap vs an 18 dB cap) came out
//     0.069 dB apart and the spec's prose claimed the difference was obvious.
//     That is the m39-ae de-esser mistake exactly: I measured the EFFECT'S
//     OUTPUT instead of the SOURCE'S SEPARATION. The source is now eight chord
//     stabs, and the separation was measured FIRST — see below.
//   · ⭐⭐ THE PLANT WAS THEN RE-RUN ON THE FIXTURE THAT SHIPS, because plant
//     evidence taken against a fixture that no longer exists is evidence about
//     nothing. DemoRender `9076ecbb45cd…` carried the one-sided forms: `boost-12`
//     AND `below-12` both rendered `992d831a532a7c9e…` — WHICH IS THE CONTROL'S
//     OWN PIN, the effect completely absent — while `cut-6` and `cut-18` still
//     measured -2.458 and -3.593 dB, unmoved to three decimals. 7 failures of 18
//     checks, exit 1. Reverting reproduced all five pins from DemoRender
//     `8976daf8b526…`, the FOURTH distinct binary to agree with them.
//
// Re-render to reproduce:
//   node scripts/demos/render-variants.mjs scripts/demos/specs/dyneq.json
const PINS = {
  "no-dyneq": "992d831a532a7c9ea43061cdcf91dbe9b249d94043b9a2b956532354a76e9857",
  "cut-6": "6013a3f53af91a04e5a477ac18bc5c3fe3479ca9527753c8bb4842f7e790f6b0",
  "cut-18": "9a6d8b28d8b2451eb46525071802cf7d1ffec74b3e29e6d0418590afdb644b91",
  "boost-12": "4cd69ecd7414c4c2f52746203e7144ddf3f16ea31df31235ec335919db1c2d86",
  "below-12": "1f1ad242cf46917d41038a6bb0880dd017126a444f3fcee0fae4a569cc77bdff",
};
const CONTROL = "no-dyneq";
const EFFECT_VARIANTS = Object.keys(PINS).filter((n) => n !== CONTROL);

// ⭐ THE SEPARATION, MEASURED ON THE SOURCE BEFORE ANY THRESHOLD WAS CHOSEN
// (design §10 G6). Through a 400 Hz-wide probe at 3 kHz, the control render
// reads a PEAK of -28.4 dBFS during a stab and -45.3 dBFS in the gap between
// stabs: **16.9 dB of in-band swing**, which is what a dynamic band has to work
// with. Every threshold in the spec is derived from that number — the three
// `above` variants sit at -43 (engages on each stab, releases in each gap) and
// `below-12` at -35 (the mirror: it is ABOVE the material, so the band wakes in
// the gaps).
//
// ⛔ THE PHYSICS, MEASURED AND WRITTEN DOWN rather than asserted as "unchanged".
// dB relative to the control, whole file.
//   variant     in band (3 kHz ±600)   out of band (<400 Hz)   selectivity
//   cut-6             -2.458                 -0.005              448:1
//   cut-18            -3.593                 -0.007              509:1
//   boost-12          +9.745                 +0.106               92:1
//   below-12          +1.622                 +0.007              227:1
// ⚠️ `rmsDb` below takes the FIRST "RMS level dB" astats prints, which is
// CHANNEL 1, not the overall figure — so these are left-channel numbers. A
// whole-file shell measurement of the same files reads within 0.04 dB of them
// (-2.488 / -3.643 / +9.780 / +1.626); the choice is deliberate, since a
// per-channel reading cannot be quietly averaged into looking healthy.
const IN_BAND_SIGN = { "cut-6": -1, "cut-18": -1, "boost-12": +1, "below-12": +1 };
const MIN_IN_BAND_MOVE_DB = 1.5;   // the band MUST move, in the right direction

// ⛔⛔ THE OUT-OF-BAND BOUND IS NOT A ROUND NUMBER, AND THE FIRST DRAFT'S ROUND
// NUMBER WAS WRONG IN PRINCIPLE. It was a flat 0.1 dB for every variant, and
// `boost-12` measured +0.108 — over budget. That is not leakage from a broken
// band: it is the side-path bell's OWN SKIRT, and the skirt is ASYMMETRIC by
// construction. `H = 1 + (G-1)·BP`, so the perturbation scales with `G-1`:
// +12 dB gives `G-1 = +2.98`, while -18 dB gives only `G-1 = -0.87` — 3.4×
// smaller, and bounded by -1 however deep the cut goes. A boost therefore
// ALWAYS disturbs the rest of the spectrum more than a cut of the same size,
// and a gate that budgets them equally is asserting something false about the
// filter. Predicted (analytic, at the 400 Hz probe corner): +0.279 dB at
// +12 dB, -0.019 dB at -18 dB, -0.015 dB at -6 dB.
//
// So the bound is COMPUTED PER VARIANT from its own `band3RangeDb`, read out of
// the spec, and the measured move must come in UNDER the bell's own skirt at
// the probe's corner frequency — an upper bound on the band-limited average,
// since the two cascaded low-passes are already -6 dB at that corner.
const OUT_OF_BAND_FLOOR_DB = 0.02;  // numerical slack for the shallowest cuts
const MIN_BAND_SELECTIVITY = 20;    // in-band move ÷ out-of-band move

/// |H(f)| in dB for the shipped side-path bell: an RBJ constant-0-dB-PEAK
/// band-pass at (f0, Q) wrapped as `1 + (G-1)·BP(z)`. This is the SAME algebra
/// `DynamicEQEffect` renders, restated here so the gate predicts rather than
/// remembers — a remembered number cannot notice that the band moved.
function bellResponseDb(hz, { f0 = 3000, q = 2, fs = 48000, gainDb }) {
  const w0 = (2 * Math.PI * f0) / fs;
  const alpha = Math.sin(w0) / (2 * q);
  const a0 = 1 + alpha;
  const b = [alpha / a0, 0, -alpha / a0];
  const a = [1, (-2 * Math.cos(w0)) / a0, (1 - alpha) / a0];
  const theta = (-2 * Math.PI * hz) / fs;
  const zr = Math.cos(theta), zi = Math.sin(theta);
  const z2r = zr * zr - zi * zi, z2i = 2 * zr * zi;
  const nr = b[0] + b[1] * zr + b[2] * z2r, ni = b[1] * zi + b[2] * z2i;
  const dr = a[0] + a[1] * zr + a[2] * z2r, di = a[1] * zi + a[2] * z2i;
  const den = dr * dr + di * di;
  const bpR = (nr * dr + ni * di) / den, bpI = (ni * dr - nr * di) / den;
  const g = Math.pow(10, gainDb / 20) - 1;
  const hr = 1 + g * bpR, hi = g * bpI;
  return 10 * Math.log10(hr * hr + hi * hi);
}

const selfControlFailures = [];
const failures = [];
const checks = [];
const notes = [];
/// Filled from the spec during the self-controls; the out-of-band bound is
/// computed from these, never from a literal in this file.
const rangeDbOf = new Map();
const qOf = new Map();

// ⭐ THE PREDICTOR'S OWN POSITIVE CONTROL, BEFORE IT IS TRUSTED TO BOUND
// ANYTHING. A hand-written biquad that returns 0 for every input would silently
// turn the out-of-band assertion into `|move| <= 0.02`, which is tighter than
// intended for a cut and far looser than intended for a boost — a wrong bound
// that reads as a working one. So: the bell must reproduce its own PEAK gain at
// the centre frequency to within a hundredth of a dB, must be flat at DC, and
// must show the boost/cut ASYMMETRY that motivates the per-variant bound at all.
{
  const peak12 = bellResponseDb(3000, { gainDb: 12 });
  const peakCut = bellResponseDb(3000, { gainDb: -18 });
  const dc = bellResponseDb(0, { gainDb: 12 });
  const skirtBoost = Math.abs(bellResponseDb(400, { gainDb: 12 }));
  const skirtCut = Math.abs(bellResponseDb(400, { gainDb: -18 }));
  if (Math.abs(peak12 - 12) > 0.01 || Math.abs(peakCut + 18) > 0.01) {
    selfControlFailures.push(
      `the bell predictor does not reproduce its own peak gain (asked +12 got ` +
      `${peak12.toFixed(4)}, asked -18 got ${peakCut.toFixed(4)}). Every out-of-band bound ` +
      `below would be nonsense. NOT SCORED.`);
  } else if (Math.abs(dc) > 1e-9) {
    selfControlFailures.push(
      `the bell predictor is not flat at DC (${dc.toFixed(6)} dB) — the band-pass is not a ` +
      `band-pass. NOT SCORED.`);
  } else if (!(skirtBoost > 4 * skirtCut) || !(skirtCut > 0)) {
    selfControlFailures.push(
      `the bell predictor shows no boost/cut skirt asymmetry (boost ${skirtBoost.toFixed(4)} ` +
      `dB vs cut ${skirtCut.toFixed(4)} dB at 400 Hz). The per-variant bound below exists ` +
      `BECAUSE a +12 dB boost disturbs the low end several times as much as an 18 dB cut; ` +
      `if that is not what the predictor says, it is not predicting this filter. NOT SCORED.`);
  } else {
    notes.push(`bell predictor OK — peak +12.0000/-18.0000 dB reproduced, flat at DC, and ` +
               `the +12 dB skirt at 400 Hz (${skirtBoost.toFixed(4)} dB) is ` +
               `${(skirtBoost / skirtCut).toFixed(1)}× the -18 dB skirt ` +
               `(${skirtCut.toFixed(4)} dB)`);
  }
}

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
  // printed was true of a binary that no longer existed.
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
      notes.push(`manifest is FRESH: rendered by DemoRender ${liveSha.slice(0, 12)}…, ` +
                 `which is the binary on disk now`);
    }
  }

  // ── the spec must still be asking what the pins answer ────────────────────
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

    // ⛔ The control must carry NO effect at all, or it measures the pipeline
    // AND the dynamic EQ and cannot separate them.
    if ((byName.get(CONTROL)?.commands ?? []).some((c) => c.command.startsWith("fx."))) {
      selfControlFailures.push(
        `the spec's ${CONTROL} variant issues an fx.* command — it is not a control, and ` +
        `every in-band/out-of-band delta below is measured against it.`);
    }

    // ⛔ Every effect variant must play the IDENTICAL source, or the control
    // controls nothing and an in-band delta could be a different note.
    const sourceOf = (v) => JSON.stringify(
      (v?.commands ?? []).filter((c) => !c.command.startsWith("fx.")));
    for (const name of EFFECT_VARIANTS) {
      if (sourceOf(byName.get(CONTROL)) !== sourceOf(byName.get(name))) {
        selfControlFailures.push(
          `the spec's ${CONTROL} and ${name} do not play an identical source (their ` +
          `non-fx commands differ). The band deltas below would then be measuring the ` +
          `music, not the effect.`);
      }
    }

    // ⛔ Every effect variant must drive the SAME band at the SAME frequency,
    // or "the band moved and nothing else did" is a claim about four different
    // bands. The frequency is also what the ffmpeg band-pass below is tuned to;
    // if a fixture moved the band, the measurement would look at the wrong place
    // and report a healthy null.
    for (const name of EFFECT_VARIANTS) {
      const add = (byName.get(name)?.commands ?? [])
        .find((c) => c.command === "fx.add");
      if (add?.params?.kind !== "dynamicEQ") {
        selfControlFailures.push(
          `the spec's ${name} adds '${add?.params?.kind}', not a dynamicEQ`);
        continue;
      }
      const p = add.params.params ?? {};
      // ⭐ The out-of-band bound below is COMPUTED from these, so they are read
      // from the spec rather than restated in this file. A variant whose range
      // or Q moved therefore gets a bound that moved with it.
      rangeDbOf.set(name, p.band3RangeDb);
      qOf.set(name, p.band3Q);
      if (p.band3Freq !== 3000) {
        selfControlFailures.push(
          `the spec's ${name} puts its band at ${p.band3Freq} Hz, but this gate measures at ` +
          `3000 Hz. A moved band would be measured OUTSIDE its own band and would report a ` +
          `healthy null — the exact shape of a gate that scores nothing and prints green.`);
      }
      // …and no OTHER band may be on, or "the 3 kHz band did it" is not proven.
      for (const key of ["band1Mode", "band2Mode", "band4Mode"]) {
        if ((p[key] ?? 0) !== 0) {
          selfControlFailures.push(
            `the spec's ${name} switches ${key} on. Exactly one band may work in this ` +
            `fixture, or the in-band/out-of-band split cannot attribute the change.`);
        }
      }
    }
  }

  // ── the named variants must be present and rendered ───────────────────────
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
    }
  }

  // ── self-control: this gate must hash the same file the harness hashed ────
  // ⭐ A NEGATIVE RESULT FROM A HAND-BUILT PROBE IS THE WEAKEST EVIDENCE THERE
  // IS. Before "the bytes are unchanged" is believed, the gate must be shown to
  // be reading the same files.
  if (!selfControlFailures.length) {
    for (const name of Object.keys(PINS)) {
      const v = byVariant.get(name);
      const live = createHash("sha256")
        .update(readFileSync(resolve(ROOT, v.path))).digest("hex");
      if (live !== v.sha256) {
        selfControlFailures.push(
          `${SET_DIR}/${name}: this gate hashes ${live.slice(0, 12)}… but the manifest says ` +
          `${v.sha256.slice(0, 12)}…. The wav changed after the manifest was written, or the ` +
          `two are hashing different things. Not scored.`);
      }
    }
  }
}

// ── HALF 2's instrument, and its own control ────────────────────────────────

/// RMS in dB through an ffmpeg filter chain.
///
/// ⚠️ `-hide_banner`, NOT `-v error`: `astats` logs its summary at INFO, and
/// `-v error` would suppress the number that is the whole point (a documented
/// trap on this machine).
///
/// ⚠️⚠️ **STDERR, NOT STDOUT, AND `spawnSync` RATHER THAN `execFileSync`.**
/// ffmpeg writes its report to STDERR, and `execFileSync` returns only stdout on
/// SUCCESS — so the first draft of this function read an empty string from every
/// successful run and returned null for every file. The instrument control above
/// is what caught it and refused to score; without that control this gate would
/// have exited 0 having measured nothing at all.
function rmsDb(wavPath, filter) {
  const run = spawnSync("ffmpeg", [
    "-hide_banner", "-nostdin", "-i", wavPath,
    "-af", `${filter},astats=metadata=1:reset=0`, "-f", "null", "-",
  ], { encoding: "utf8", maxBuffer: 1 << 26 });
  const out = `${run.stdout ?? ""}${run.stderr ?? ""}`;
  const match = /RMS level dB:\s*(-?\d+(?:\.\d+)?)/.exec(out);
  return match ? Number(match[1]) : null;
}

const IN_BAND = "bandpass=f=3000:width_type=h:w=1200";
const OUT_OF_BAND = "lowpass=f=400,lowpass=f=400";

let physics = null;
if (!selfControlFailures.length && manifest) {
  const byVariant = new Map((manifest.variants ?? []).map((v) => [v.name, v]));
  const pathOf = (n) => resolve(ROOT, byVariant.get(n).path);

  // ⭐ CONTROL ON THE INSTRUMENT ITSELF, BEFORE ANY SCORING. ffmpeg may be
  // missing, the filter names may have changed, the regex may not match — and
  // every one of those returns "no number", which must never read as "no
  // change". The control is that the two filters give DIFFERENT readings on the
  // SAME file: this material has far more energy under 400 Hz than in a narrow
  // band at 3 kHz, so a measurement that returns the same number twice is not
  // measuring a band.
  const controlIn = rmsDb(pathOf(CONTROL), IN_BAND);
  const controlOut = rmsDb(pathOf(CONTROL), OUT_OF_BAND);
  if (controlIn === null || controlOut === null) {
    selfControlFailures.push(
      `the ffmpeg band measurement returned no number (in=${controlIn}, out=${controlOut}). ` +
      `Is ffmpeg installed and does astats still print "RMS level dB"? NOT SCORED — an ` +
      `absent number must never be read as an absent change.`);
  } else if (Math.abs(controlIn - controlOut) < 3) {
    selfControlFailures.push(
      `the two filters read ${controlIn} and ${controlOut} dB on the SAME control file. ` +
      `They must differ substantially (this pad has far more energy under 400 Hz than in a ` +
      `1.2 kHz-wide band at 3 kHz) — if they agree, the filters are not filtering and every ` +
      `delta below would be a delta of nothing. NOT SCORED.`);
  } else {
    notes.push(`instrument control OK — the control file reads ${controlIn.toFixed(3)} dB ` +
               `in band and ${controlOut.toFixed(3)} dB out of band, ` +
               `${Math.abs(controlIn - controlOut).toFixed(1)} dB apart`);
    physics = { controlIn, controlOut, rows: [] };
    for (const name of EFFECT_VARIANTS) {
      physics.rows.push({
        name,
        inDelta: rmsDb(pathOf(name), IN_BAND) - controlIn,
        outDelta: rmsDb(pathOf(name), OUT_OF_BAND) - controlOut,
      });
    }
  }
}

// ── refuse to score if anything above went wrong ────────────────────────────

if (selfControlFailures.length) {
  console.error("SELF-CONTROL FAILED — this gate scored NOTHING:\n  " +
    selfControlFailures.join("\n  "));
  process.exit(3);
}

// ── HALF 1: the bytes ───────────────────────────────────────────────────────

const byVariant = new Map((manifest.variants ?? []).map((v) => [v.name, v]));
for (const [name, pin] of Object.entries(PINS)) {
  const got = byVariant.get(name).sha256;
  checks.push({ name: `bytes/${name}`, ok: got === pin });
  if (got !== pin) {
    failures.push(
      `${name}: rendered ${got.slice(0, 16)}…, pinned ${pin.slice(0, 16)}…` +
      (name === CONTROL
        ? `  ⚠️ THIS IS THE CONTROL — it carries NO dynamic EQ, so something OUTSIDE the ` +
          `effect moved (the synth, the offline renderer, the wav writer). Re-derive the ` +
          `pins rather than reading this as a dynamic-EQ regression.`
        : ``));
  }
}

// Every effect variant must differ from the control AND from each other, or the
// spec's axis is not an axis. (`render-variants.mjs` enforces this too; it is
// restated here so this gate is meaningful when run on its own.)
const hashes = new Map(Object.keys(PINS).map((n) => [n, byVariant.get(n).sha256]));
const distinct = new Set(hashes.values());
checks.push({ name: "variants/all-distinct", ok: distinct.size === hashes.size });
if (distinct.size !== hashes.size) {
  failures.push(`only ${distinct.size} of ${hashes.size} variants are distinct — ` +
                `at least one axis did nothing`);
}

// ── HALF 2: the physics ─────────────────────────────────────────────────────

console.log("\n# in-band (3 kHz ± 600) vs out-of-band (< 400 Hz), dB relative to the control");
for (const row of physics.rows) {
  console.log(`  ${row.name.padEnd(10)} in ${row.inDelta >= 0 ? "+" : ""}` +
              `${row.inDelta.toFixed(3)} dB   out ${row.outDelta >= 0 ? "+" : ""}` +
              `${row.outDelta.toFixed(3)} dB   ` +
              `ratio ${Math.abs(row.inDelta / (row.outDelta || 1e-9)).toFixed(0)}:1`);

  // ⛔ 1. THE BAND MOVED, AND IN THE DIRECTION ITS SIGN ASKED FOR. This is the
  // ballistics-sign assertion on RENDERED AUDIO: `boost-12` and `below-12` both
  // carry a POSITIVE range, and a build that copied the compressor's one-sided
  // rest-snap would render them as a null.
  const wanted = IN_BAND_SIGN[row.name];
  const movedRight = Math.sign(row.inDelta) === wanted
    && Math.abs(row.inDelta) >= MIN_IN_BAND_MOVE_DB;
  checks.push({ name: `physics/${row.name}/in-band`, ok: movedRight });
  if (!movedRight) {
    failures.push(
      `${row.name}: the 3 kHz band moved ${row.inDelta.toFixed(3)} dB; it must move at least ` +
      `${MIN_IN_BAND_MOVE_DB} dB ${wanted > 0 ? "UP" : "DOWN"}.` +
      (wanted > 0
        ? `  ⛔ THIS VARIANT HAS A POSITIVE rangeDb. A boost band that renders a null is the ` +
          `signature of the compressor's ONE-SIDED rest-snap (env > -1e-10), which forces a ` +
          `positive envelope to zero on every sample. The snap must be TWO-SIDED ` +
          `(abs(env) < 1e-10) and the attack/release test must be abs(targetDb) > abs(env).`
        : ``));
  }

  // ⛔ 2. AND NOTHING ELSE DID. Without this leg, a dynamic EQ that had silently
  // become a plain volume rider would pass leg 1 on every variant.
  //
  // The budget is the BELL'S OWN SKIRT at the probe's corner, computed from this
  // variant's range and Q — an upper bound, because the two cascaded low-passes
  // are already -6 dB there and everything the probe passes below 400 Hz sees
  // LESS skirt than 400 Hz does.
  const budget = Math.max(
    OUT_OF_BAND_FLOOR_DB,
    Math.abs(bellResponseDb(400, { q: qOf.get(row.name), gainDb: rangeDbOf.get(row.name) })));
  const stayedPut = Math.abs(row.outDelta) <= budget;
  checks.push({ name: `physics/${row.name}/out-of-band`, ok: stayedPut });
  if (!stayedPut) {
    failures.push(
      `${row.name}: everything under 400 Hz moved ${row.outDelta.toFixed(3)} dB, over the ` +
      `${budget.toFixed(3)} dB this variant's own bell can account for (range ` +
      `${rangeDbOf.get(row.name)} dB at Q ${qOf.get(row.name)}). A dynamic EQ moves ITS BAND; ` +
      `a unit that moves the low end BEYOND its filter's skirt is a compressor wearing an ` +
      `EQ's name.`);
  }

  // ⛔ 3. …AND THE TWO ARE FAR APART. Leg 2 alone would pass a variant whose
  // band did the bare 1.5 dB minimum while the low end moved 0.27 dB — within a
  // +12 dB bell's skirt, but only 5:1 of selectivity, which is not a band.
  const selectivity = Math.abs(row.inDelta / (row.outDelta || 1e-12));
  const selective = selectivity >= MIN_BAND_SELECTIVITY;
  checks.push({ name: `physics/${row.name}/selectivity`, ok: selective });
  if (!selective) {
    failures.push(
      `${row.name}: the band moved ${row.inDelta.toFixed(3)} dB while the low end moved ` +
      `${row.outDelta.toFixed(3)} dB — only ${selectivity.toFixed(1)}:1. A dynamic EQ must ` +
      `separate its band from the rest by at least ${MIN_BAND_SELECTIVITY}:1.`);
  }
}

// ── the verdict (the m23-fa rule: zero checks is NOT a pass) ────────────────

console.log("");
for (const note of notes) console.log(`# ${note}`);
if (failures.length) {
  console.error(`\n✘ m39af-dyneq-bytes: ${failures.length} failure(s) of ${checks.length} ` +
                `check(s):\n  ` + failures.join("\n  "));
}
// ⛔ `checks.length > 0` IS PART OF THE VERDICT. 57 of 71 gates in this tree once
// exited 0 after running zero checks (m23-fa).
const passed = checks.length > 0 && checks.every((c) => c.ok);
if (passed) {
  console.log(`✔ m39af-dyneq-bytes: ${checks.length} checks passed — 5 renders byte-identical ` +
              `to their pins, and every band moved in its own direction by ≥ ` +
              `${MIN_IN_BAND_MOVE_DB} dB while the low end stayed inside its own bell's ` +
              `skirt and at least ${MIN_BAND_SELECTIVITY}:1 below the band.`);
}
process.exit(passed ? 0 : 1);
