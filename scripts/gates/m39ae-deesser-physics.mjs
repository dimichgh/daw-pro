#!/usr/bin/env node
// m39-ae — THE DE-ESSER'S PHYSICS GATE: what the detector listens to, measured
// off rendered audio.
//
// ⛔⛔ **A BROKEN DE-ESSER AND A WORKING ONE ARE BOTH LOUD, BOTH AUDIBLE, AND
// BOTH RENDER DISTINCT FILES.** `render-variants.mjs` will exit 0 with
// `audible=true` on every variant whether the detector filter reaches the render
// path or not — measured in this tree five separate times this week on planted
// defects. **Identical bytes prove an axis did nothing; DISTINCT bytes prove
// nothing at all.** So this file asserts the PHYSICS instead.
//
// ## What a de-esser actually promises, stated so it can be measured
//
// It is a compressor whose DETECTOR — the part that decides how much to turn
// down — hears a filtered copy of the signal, while the AUDIO PATH stays the
// untouched input. Two consequences, and they are the two halves of this gate:
//
//   1. IT IGNORES NON-SIBILANT MATERIAL. On a passage with no energy in the
//      sibilant band, a de-esser does nothing AT ALL while an ordinary
//      broadband compressor at the same settings ducks it.
//   2. IT IS A GAIN, NOT A FILTER. When it does act, it turns the WHOLE signal
//      down — it is WIDEBAND, deliberately (see the kind's `detectorMode` note)
//      — so it cannot change the BALANCE between two tones. A split-band
//      de-esser would; this one must not.
//
// ⭐⭐ **LEG 4 IS THE ONE THAT CATCHES THE REAL BUG, AND IT IS THE DULL ONE.**
// If the band-pass ever leaked out of the detector and into the AUDIO path —
// one line, a plausible refactor, and the single most likely way to build this
// wrong — the render would still be loud, still be audible, still duck on
// sibilance, and every headline number in this file would stay healthy. The
// only thing that would move is the ratio between the two tones. m39-ac's
// planted `factor = 1` was caught by exactly this shape of leg and not by the
// headline; m39-ad recorded the same lesson. Trim this gate to its headline and
// it will pass a broken build.
//
// ## The fixture, and why it is two sine tones
//
// `scripts/demos/specs/deesser.json`: a sustained LOW tone (MIDI 64 =
// 329.63 Hz, the "voice") for the whole render, joined at beat 8 = 4.0 s by a
// HIGH tone (MIDI 117 = 7040 Hz, the "sss"). That gives two windows whose
// contents are KNOWN rather than assumed:
//
//   · section A (1.0–3.5 s): low tone only. Nothing in the sibilant band.
//   · section B (5.0–7.0 s): both tones, within 0.4 dB of each other.
//
// On real music both bins already contain material, the measurement would read
// the material instead of the effect, and a build whose detector filter had
// quietly stopped working would pass while sounding roughly right.
//
// ## The measured numbers this gate was built on (2026-09-20)
//
//   variant      GR in section A   GR in section B   balance drift vs control
//   deess-off       −3.228 dB         −8.198 dB           −0.0013 dB
//   deess-band       0.000 dB         −3.113 dB            0.0000 dB
//   deess-high       0.000 dB         −8.336 dB            0.0000 dB
//
// Section A's 0.000 is not a rounding: `deess-band` and `deess-high` are
// SAMPLE-FOR-SAMPLE IDENTICAL to the control for the whole of section A. The
// detector never crosses threshold, the envelope snaps to exact 0, the gain is
// exactly 1.0, and the output is the input. Leg 2 asserts that identity rather
// than a tolerance, because it is available and a tolerance would be weaker.
//
// The margin behind it is large and is REPORTED so its erosion is visible: a
// 2-pole band-pass at 7000 Hz / Q 2 rejects 329.63 Hz by ~32.5 dB, putting the
// detector ~25 dB under the −24 dBFS threshold.
//
// Exit codes: 0 pass · 1 a real failure · 3 REFUSED TO SCORE.

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readMonoFloat } from "./_measure-dsp.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SET_DIR = "scripts/demos/out/deesser";
const SPEC_PATH = "scripts/demos/specs/deesser.json";
const SAMPLE_RATE = 48_000;

// The fixture's two pitches, DERIVED here rather than written down so the gate
// and the spec cannot drift apart on a rounding; the self-controls below re-read
// the spec's actual pitches and compare.
const MIDI_LOW = 64, MIDI_HIGH = 117;
const F_LOW = 440 * Math.pow(2, (MIDI_LOW - 69) / 12);    // 329.628 Hz
const F_HIGH = 440 * Math.pow(2, (MIDI_HIGH - 69) / 12);  // 7040.000 Hz
// Beat 8 at 120 BPM. Derived, not written as "4.0".
const BPM = 120;
const HIGH_ENTERS_BEAT = 8;
const HIGH_ENTERS_S = (HIGH_ENTERS_BEAT * 60) / BPM;

// The two analysis windows, well inside their sections so no attack or release
// edge is in either.
const SECTION_A = [1.0, 3.5];
const SECTION_B = [5.0, 7.0];
// The window the SAMPLE-EXACT leg covers: from the very first sample to just
// before the high tone enters. Measured as exactly zero difference over the
// FULL 0 → HIGH_ENTERS_S; this stops a hair short so a future tempo or envelope
// tweak cannot make the gate fail for a reason that is not a regression.
const EXACT_UNTIL_S = HIGH_ENTERS_S - 0.1;

// ── FLOORS. Each one is set well clear of the measured value it guards, and
// each names the wrong implementation it exists to catch.
//
// A broadband detector must visibly duck the vowel, or "the de-esser left it
// alone" is a comparison against nothing. Measured −3.228 dB.
const BROADBAND_MIN_GR_A_DB = 2.0;
// The de-ess modes must not touch it. Measured 0.000 dB and sample-exact; this
// tolerance is the backstop for the identity leg, not the primary assertion.
const DEESS_MAX_GR_A_DB = 0.25;
// …and must act when sibilance IS present. Measured −3.113 / −8.336 dB.
const DEESS_MIN_GR_B_DB = 2.0;
// ⭐ THE BALANCE LEG. A wideband gain cannot move this at all; measured drift is
// 0.0013 dB, i.e. arithmetic noise. 0.25 dB is ~190× the measured value and
// still catches a detector filter leaking into the audio path by a mile — the
// band-pass would move it by tens of dB.
const BALANCE_TOLERANCE_DB = 0.25;
// Band-pass vs high-pass must be DISTINGUISHABLE and in the predicted
// DIRECTION: a 2-pole high-pass has gain Q at its own corner, so at the default
// Q of 2 it hands the detector ~6 dB more than the 0-dB-peak band-pass does and
// must therefore duck harder. Measured gap 5.22 dB. This leg is what catches a
// switch that quietly treats mode 2 as mode 1.
const MODE_GAP_MIN_DB = 2.0;
// A tone that is PRESENT must be at least this far above the analysis floor…
const PRESENCE_FLOOR_DB = -60;
// …and one that is ABSENT must be at least this far below it. The control's
// section A measures −209 dB at 7040 Hz, so this is not a close call; it is here
// so that a probe reading its own leakage announces itself.
const ABSENCE_CEILING_DB = -120;

const failures = [];
const selfControlFailures = [];
const notes = [];

// ── instrument ──────────────────────────────────────────────────────────────

/// Hann-windowed Goertzel magnitude at an arbitrary frequency.
///
/// ⚠️ THE WINDOW IS LOAD-BEARING. `F_LOW` is irrational (an equal-tempered MIDI
/// pitch), so nothing here lands on an exact DFT bin and a rectangular window's
/// leakage floor around a full-scale tone would be about −52 dB — far above the
/// −209 dB this gate has to resolve for the ABSENCE control. Hann's sidelobes
/// fall as 1/k³.
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

const samples = new Map();
function load(path) {
  if (!samples.has(path)) samples.set(path, readMonoFloat(resolve(ROOT, path), SAMPLE_RATE));
  return samples.get(path);
}

/// Both tones in both windows, for one render.
function bins(path) {
  const x = load(path);
  const win = ([t0, t1]) => [Math.round(t0 * SAMPLE_RATE), Math.round((t1 - t0) * SAMPLE_RATE)];
  const [aFrom, aCount] = win(SECTION_A);
  const [bFrom, bCount] = win(SECTION_B);
  if (x.length < bFrom + bCount) {
    throw new Error(`${path} is too short to analyse (${x.length} samples)`);
  }
  return {
    frames: x.length,
    lowA: db(goertzelHann(x, F_LOW, aFrom, aCount)),
    highA: db(goertzelHann(x, F_HIGH, aFrom, aCount)),
    lowB: db(goertzelHann(x, F_LOW, bFrom, bCount)),
    highB: db(goertzelHann(x, F_HIGH, bFrom, bCount)),
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
  // printed was true of a binary that no longer existed.
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
  if (variants.length !== 4) {
    selfControlFailures.push(`${SET_DIR}: ${variants.length} variant(s), expected exactly 4`);
  }
  for (const v of variants) {
    if (v.ok !== true) {
      selfControlFailures.push(`${SET_DIR}/${v.name}: render did not succeed (${v.error})`);
    }
    if (!v.path || !existsSync(resolve(ROOT, v.path))) {
      selfControlFailures.push(`${SET_DIR}/${v.name}: rendered wav is missing (${v.path})`);
      continue;
    }
    // ⭐ The gate must be reading the same file the harness hashed.
    const onDisk = createHash("sha256")
      .update(readFileSync(resolve(ROOT, v.path))).digest("hex");
    if (onDisk !== v.sha256) {
      selfControlFailures.push(
        `${SET_DIR}/${v.name}: the wav on disk hashes ${onDisk.slice(0, 12)}… but the ` +
        `manifest recorded ${String(v.sha256).slice(0, 12)}…. Nothing here can be scored.`);
    }
    // ⚠️ THE RATE IS NOT ASSUMED. Every frequency here is a fraction of 48 000.
    if (v.sampleRate && v.sampleRate !== SAMPLE_RATE) {
      selfControlFailures.push(
        `${SET_DIR}/${v.name}: rendered at ${v.sampleRate} Hz but this gate derives every ` +
        `bin for ${SAMPLE_RATE} Hz.`);
    }
  }

  // ── the spec must still be asking what this gate answers ──────────────────
  const specPath = resolve(ROOT, SPEC_PATH);
  if (!existsSync(specPath)) {
    selfControlFailures.push(`the spec is missing: ${specPath}`);
  } else {
    const spec = JSON.parse(readFileSync(specPath, "utf8"));
    const byName = new Map(spec.variants.map((v) => [v.name, v]));

    // The control must carry NO effect at all, or "the bins are known before
    // the effect runs" is not a statement about anything.
    if (byName.get("no-compressor")?.commands?.some((c) => c.command.startsWith("fx."))) {
      selfControlFailures.push(
        `the spec's no-compressor variant issues an fx.* command — it is not a control.`);
    }

    // The fixture's PITCHES and the entry BEAT are what every window and bin
    // here is derived from.
    for (const [name, variant] of byName) {
      const midi = variant.commands?.find((c) => c.command === "clip.addMIDI");
      const notes_ = midi?.params?.notes ?? [];
      const pitches = notes_.map((n) => n.pitch);
      if (pitches.length !== 2 || pitches[0] !== MIDI_LOW || pitches[1] !== MIDI_HIGH) {
        selfControlFailures.push(
          `the spec's ${name} plays pitches [${pitches}] but this gate derives every bin ` +
          `from [${MIDI_LOW}, ${MIDI_HIGH}] (${F_LOW.toFixed(2)} / ${F_HIGH.toFixed(2)} Hz).`);
      }
      if (notes_[1]?.startBeat !== HIGH_ENTERS_BEAT) {
        selfControlFailures.push(
          `the spec's ${name} brings the high tone in at beat ${notes_[1]?.startBeat}, but ` +
          `this gate places its two analysis windows around beat ${HIGH_ENTERS_BEAT} ` +
          `(= ${HIGH_ENTERS_S.toFixed(2)} s at ${BPM} BPM).`);
      }
    }

    // ⛔⛔ ONE AXIS. The three compressor variants must share EVERY knob except
    // `detectorMode`. Without this, "band-pass ducked less than broadband"
    // could be a threshold difference somebody edited in, and the whole gate
    // would be attributing a number to the wrong cause.
    const knobsOf = (name) => {
      const fx = byName.get(name)?.commands?.find((c) => c.command === "fx.add");
      if (fx?.params?.kind !== "compressor") return null;
      const { detectorMode, ...rest } = fx.params.params ?? {};
      return { mode: detectorMode, rest: JSON.stringify(rest) };
    };
    const off = knobsOf("deess-off"), band = knobsOf("deess-band"), high = knobsOf("deess-high");
    if (!off || !band || !high) {
      selfControlFailures.push(
        `one of deess-off / deess-band / deess-high does not add a compressor`);
    } else {
      if (off.rest !== band.rest || off.rest !== high.rest) {
        selfControlFailures.push(
          `the three compressor variants do not share identical knobs apart from ` +
          `detectorMode:\n      deess-off  ${off.rest}\n      deess-band ${band.rest}\n` +
          `      deess-high ${high.rest}\n    This set claims ONE axis. With two, every ` +
          `number below is attributed to the wrong cause.`);
      }
      if (!(off.mode === 0 && band.mode === 1 && high.mode === 2)) {
        selfControlFailures.push(
          `the spec's detectorMode values are off=${off.mode}, band=${band.mode}, ` +
          `high=${high.mode}; this gate reads them as 0 / 1 / 2.`);
      }
      // The band must be parked ON the high tone, or "the detector hears the
      // sibilance" is false and every section-B number is about something else.
      const freq = JSON.parse(band.rest).detectorFreqHz;
      const q = JSON.parse(band.rest).detectorQ;
      if (!(Math.abs(Math.log2(freq / F_HIGH)) < 0.5)) {
        selfControlFailures.push(
          `the spec parks the de-ess band at ${freq} Hz, more than half an octave from the ` +
          `fixture's high tone at ${F_HIGH.toFixed(0)} Hz. The detector would not hear the ` +
          `"sibilance" this set is built around.`);
      }
      // …and its rejection of the LOW tone is what Leg 2 rests on. Derived
      // from the actual analog band-pass magnitude, not a rule of thumb.
      const r = F_LOW / freq;
      const rejectionDb = db(1 / Math.hypot(1, q * (r - 1 / r)));
      notes.push(
        `band-pass at ${freq} Hz / Q ${q} rejects the ${F_LOW.toFixed(0)} Hz tone by ` +
        `${(-rejectionDb).toFixed(1)} dB — that rejection is the margin Leg 2 lives on`);
      if (-rejectionDb < 20) {
        selfControlFailures.push(
          `the de-ess band rejects the fixture's low tone by only ${(-rejectionDb).toFixed(1)} ` +
          `dB. Leg 2 asserts the de-esser does not touch section A at all; with a rejection ` +
          `this small that assertion would be a coin flip on the threshold rather than a ` +
          `statement about the detector.`);
      }
    }
  }
}

if (selfControlFailures.length > 0) {
  console.error("m39ae-deesser-physics: REFUSING TO SCORE.\n");
  for (const f of selfControlFailures) console.error(`  · ${f}`);
  console.error(
    "\nA gate that cannot read its own input must not report an all-clear. " +
    "Exit 3 is NOT a pass.");
  process.exit(3);
}

const byName = new Map(manifest.variants.map((v) => [v.name, v]));
const need = (name) => {
  const v = byName.get(name);
  if (!v) selfControlFailures.push(`${SET_DIR}: no variant named "${name}"`);
  return v;
};
const control = need("no-compressor");
const off = need("deess-off");
const band = need("deess-band");
const high = need("deess-high");
if (selfControlFailures.length > 0) {
  console.error("m39ae-deesser-physics: REFUSING TO SCORE.\n");
  for (const f of selfControlFailures) console.error(`  · ${f}`);
  process.exit(3);
}

console.log(
  `  · fixture: MIDI ${MIDI_LOW} = ${F_LOW.toFixed(2)} Hz throughout; MIDI ${MIDI_HIGH} = ` +
  `${F_HIGH.toFixed(0)} Hz from beat ${HIGH_ENTERS_BEAT} (${HIGH_ENTERS_S.toFixed(2)} s). ` +
  `Section A ${SECTION_A[0]}–${SECTION_A[1]} s (no sibilance), ` +
  `section B ${SECTION_B[0]}–${SECTION_B[1]} s (sibilance present).`);

// ── LEG 0: THE PROBE'S OWN POSITIVE *AND NEGATIVE* CONTROL ──────────────────
// ⭐ A NEGATIVE RESULT FROM A HAND-BUILT PROBE IS THE WEAKEST EVIDENCE THERE IS.
// Before "the high band is quiet in section A" means anything, the probe must
// be shown to FIND a tone where one certainly is and to report a FLOOR where
// one certainly is not — on the control render, whose content is known exactly.
const c = bins(control.path);
notes.push(
  `no-compressor (control): A low ${c.lowA.toFixed(2)} / high ${c.highA.toFixed(2)} · ` +
  `B low ${c.lowB.toFixed(2)} / high ${c.highB.toFixed(2)} dB`);
if (c.lowA < PRESENCE_FLOOR_DB || c.lowB < PRESENCE_FLOOR_DB) {
  failures.push(
    `PROBE IS BLIND: the control's ${F_LOW.toFixed(0)} Hz tone, which plays throughout, reads ` +
    `${c.lowA.toFixed(2)} / ${c.lowB.toFixed(2)} dB. Every number below would be meaningless.`);
}
if (c.highB < PRESENCE_FLOOR_DB) {
  failures.push(
    `PROBE IS BLIND: the control's ${F_HIGH.toFixed(0)} Hz tone reads ${c.highB.toFixed(2)} dB ` +
    `in section B, where it is definitely playing.`);
}
if (c.highA > ABSENCE_CEILING_DB) {
  failures.push(
    `PROBE IS READING ITS OWN LEAKAGE: the control's ${F_HIGH.toFixed(0)} Hz bin reads ` +
    `${c.highA.toFixed(2)} dB in section A, where that tone is NOT PLAYING AT ALL. The two ` +
    `analysis windows are not where this gate thinks they are, or the window function is ` +
    `leaking — either way "section A has no sibilance" is false and Leg 2 proves nothing.`);
}

// ── the three compressor renders ────────────────────────────────────────────
const measured = { "deess-off": bins(off.path), "deess-band": bins(band.path),
                   "deess-high": bins(high.path) };
// Gain reduction = how far this render sits below the control, per window. The
// de-esser is a GAIN, so either tone reports it; the low tone is used because
// it is present in both windows.
const grA = (n) => measured[n].lowA - c.lowA;
const grB = (n) => measured[n].lowB - c.lowB;
for (const n of Object.keys(measured)) {
  notes.push(
    `${n.padEnd(11)}: GR section A ${grA(n).toFixed(3)} dB · GR section B ` +
    `${grB(n).toFixed(3)} dB · balance drift ` +
    `${((measured[n].highB - measured[n].lowB) - (c.highB - c.lowB)).toFixed(4)} dB`);
}

// ── LEG 1: THE BROADBAND DETECTOR REALLY DOES DUCK THE VOWEL ────────────────
// Without this, "the de-esser left section A alone" is a comparison against
// nothing: if the compressor were not compressing at all, every variant would
// leave section A alone and Leg 2 would pass vacuously.
if (-grA("deess-off") < BROADBAND_MIN_GR_A_DB) {
  failures.push(
    `deess-off (detectorMode 0, an ordinary broadband compressor) reduced section A by only ` +
    `${(-grA("deess-off")).toFixed(3)} dB (floor ${BROADBAND_MIN_GR_A_DB}). Section A has no ` +
    `sibilance, so a BROADBAND detector must still duck it — that is the whole difference a ` +
    `de-esser makes. If this is near zero the compressor is not compressing, and Leg 2 below ` +
    `would pass for the wrong reason.`);
}

// ── LEG 2: ⭐ THE HEADLINE — the de-esser IGNORES non-sibilant material ─────
// Asserted as a SAMPLE-EXACT IDENTITY, not a tolerance, because the identity is
// what actually happens: the detector never crosses threshold, the envelope
// snaps to exact 0, the gain is exactly 1.0 and the output IS the input.
const exactUntil = Math.round(EXACT_UNTIL_S * SAMPLE_RATE);
const cx = load(control.path);
for (const n of ["deess-band", "deess-high"]) {
  const gr = -grA(n);
  if (gr > DEESS_MAX_GR_A_DB) {
    failures.push(
      `${n} reduced section A by ${gr.toFixed(3)} dB (ceiling ${DEESS_MAX_GR_A_DB}). There is ` +
      `NOTHING in the sibilant band there, so a detector that is really filtered cannot be ` +
      `triggering. Either the filter is not reaching the render path, or it is passing the ` +
      `low tone, or detectorFreqHz/detectorQ are not what the fixture asked for.`);
  }
  const x = load((n === "deess-band" ? band : high).path);
  let firstDiff = -1;
  const upTo = Math.min(exactUntil, cx.length, x.length);
  for (let i = 0; i < upTo; i++) {
    if (x[i] !== cx[i]) { firstDiff = i; break; }
  }
  if (firstDiff >= 0) {
    failures.push(
      `${n} is NOT sample-identical to the control before the sibilance enters: first ` +
      `difference at sample ${firstDiff} (t=${(firstDiff / SAMPLE_RATE).toFixed(4)} s), value ` +
      `${x[firstDiff]} vs ${cx[firstDiff]}. With no energy in the detector's band the gain ` +
      `computer's envelope must sit at exactly 0 and the gain at exactly 1.0, so the output ` +
      `must BE the input. Any difference at all means the detector is seeing something it ` +
      `should not — the most likely cause is the band-pass having leaked into the AUDIO path.`);
  } else {
    notes.push(
      `⭐ ${n}: sample-for-sample IDENTICAL to the control over ` +
      `${(upTo / SAMPLE_RATE).toFixed(2)} s of non-sibilant material (${upTo} samples)`);
  }
}

// ── LEG 3: …AND IT DOES ACT WHEN SIBILANCE IS PRESENT ───────────────────────
for (const n of ["deess-band", "deess-high"]) {
  if (-grB(n) < DEESS_MIN_GR_B_DB) {
    failures.push(
      `${n} reduced section B by only ${(-grB(n)).toFixed(3)} dB (floor ${DEESS_MIN_GR_B_DB}). ` +
      `The sibilant tone IS present there and the detector is parked on it, so the unit must ` +
      `act. A de-esser that ignores everything is not a de-esser, and Leg 2 alone cannot tell ` +
      `that apart from a working one.`);
  }
}

// ── LEG 4: ⭐⭐ THE INVARIANCE LEG — IT IS A GAIN, NOT A FILTER ─────────────
// ⛔⛔ THIS IS THE LEG THAT CATCHES THE BUG THE HEADLINE NUMBERS CANNOT SEE. A
// wideband de-esser applies ONE gain to the whole signal, so the ratio between
// the two tones must be EXACTLY what it is in the control. If the band-pass
// leaked into the audio path — one line, a plausible refactor — the render
// would still be loud, still duck on sibilance, and pass every leg above.
const controlBalance = c.highB - c.lowB;
for (const n of Object.keys(measured)) {
  const drift = (measured[n].highB - measured[n].lowB) - controlBalance;
  if (Math.abs(drift) > BALANCE_TOLERANCE_DB) {
    failures.push(
      `${n} changed the BALANCE between the two tones by ${drift.toFixed(3)} dB (tolerance ` +
      `${BALANCE_TOLERANCE_DB}). In section B the control has ${F_HIGH.toFixed(0)} Hz sitting ` +
      `${controlBalance.toFixed(3)} dB from ${F_LOW.toFixed(0)} Hz; this render has them ` +
      `${(measured[n].highB - measured[n].lowB).toFixed(3)} dB apart. This kind is WIDEBAND — ` +
      `it multiplies everything by the same number — so it is arithmetically incapable of ` +
      `moving this. A filter is in the AUDIO path where only the DETECTOR should be filtered.`);
  }
}

// ── LEG 5: the three modes are three modes ──────────────────────────────────
// ⭐ Each comparison is a PREDICTION of the design, not a recorded number:
//   · band-pass hears ONLY the sibilant tone, broadband hears BOTH summed, so
//     broadband must duck harder;
//   · a 2-pole high-pass has gain Q at its own corner (default Q 2 = +6 dB), so
//     high-pass must duck harder than the 0-dB-peak band-pass.
// Together they mean a switch that quietly collapses two modes into one fails
// here even though every other leg would pass.
const gapBroadband = -grB("deess-off") - (-grB("deess-band"));
const gapHigh = -grB("deess-high") - (-grB("deess-band"));
notes.push(
  `⭐ MODE SEPARATION in section B — broadband over band-pass ${gapBroadband.toFixed(2)} dB, ` +
  `high-pass over band-pass ${gapHigh.toFixed(2)} dB (floor ${MODE_GAP_MIN_DB} each)`);
if (gapBroadband < MODE_GAP_MIN_DB) {
  failures.push(
    `deess-off ducked section B only ${gapBroadband.toFixed(2)} dB harder than deess-band ` +
    `(floor ${MODE_GAP_MIN_DB}). Broadband hears BOTH tones summed and the band-pass hears ` +
    `essentially one, so the gap must be real. If it has collapsed, detectorMode 1 is falling ` +
    `through to the unfiltered path.`);
}
if (gapHigh < MODE_GAP_MIN_DB) {
  failures.push(
    `deess-high ducked section B only ${gapHigh.toFixed(2)} dB harder than deess-band (floor ` +
    `${MODE_GAP_MIN_DB}). A 2-pole high-pass has gain Q AT its corner — the fixture's Q of 2 ` +
    `is +6 dB — while the band-pass peaks at 0 dB by construction, so mode 2 must hand the ` +
    `detector a hotter signal than mode 1. If the gap has collapsed, the two modes are ` +
    `selecting the same filter: check the switch in CompressorEffect.deriveDetectorFilter ` +
    `and EQFilterResponse.bandPassSection vs cutSection.`);
}

// ── LEG 6: invariance — four renders, four files ────────────────────────────
const all = [control, off, band, high].map((v) => v.sha256);
if (new Set(all).size !== all.length) {
  failures.push(
    `two or more of the four renders are BYTE-IDENTICAL (${new Set(all).size} distinct). The ` +
    `axis did not take effect somewhere, and the numbers above are describing the same audio ` +
    `twice.`);
}

// ── report ──────────────────────────────────────────────────────────────────
for (const n of notes) console.log(`  · ${n}`);
if (failures.length > 0) {
  console.error(`\nm39ae-deesser-physics: ${failures.length} failure(s).\n`);
  for (const f of failures) console.error(`  ✘ ${f}`);
  process.exit(1);
}
console.log(
  `\nm39ae-deesser-physics: OK — the de-esser leaves non-sibilant material SAMPLE-IDENTICAL ` +
  `while a broadband compressor at the same settings ducks it by ` +
  `${(-grA("deess-off")).toFixed(2)} dB; it ducks ${(-grB("deess-band")).toFixed(2)} dB when ` +
  `sibilance arrives; all three modes are separated in the predicted direction; and no ` +
  `variant moved the balance between the two tones by more than ` +
  `${Math.max(...Object.keys(measured).map((n) => Math.abs(
    (measured[n].highB - measured[n].lowB) - controlBalance))).toFixed(4)} dB, which is what ` +
  `proves the filter is on the DETECTOR and not in the audio path.`);
