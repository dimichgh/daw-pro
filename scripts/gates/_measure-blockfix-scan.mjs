// m28-bug BLOCK-SIZE SCAN — the falsifying test §2.4 of measure-gm-sax-cc.md
// named and could not run: does lowering `OfflineRenderer.maximumFrameCount`
// move the controller sample-and-hold null off the vibrato band?
//
// NOT a gate (`_` prefix), NOT product code, NEEDS NO APP. It re-analyses wavs
// written by `Tests/DAWEngineTests/BlockRateBounceProbeTests.swift`, which is
// the only place the render block size is reachable (it is not on the wire —
// that is precisely why the JS harness had to leave this prediction untested).
//
// ⭐ THE 4096 ARM IS THE POSITIVE CONTROL, NOT A BASELINE. A hand-built probe
// that reports "no alias at 512" is the weakest evidence in this repo: a probe
// that plumbed nothing scores identically. So the 4096 arm must first
// REPRODUCE THE PUBLISHED FIGURES (§2.3a: 8 Hz → image at 3.719 Hz ≈ 41.7 c;
// 11.72 Hz → ~0 depth and a static ≈ −17.9 cent detune). If it does not, the
// harness is wrong and the 512 arm is uninterpretable.
//
// ⚠️ DETECTION IS CONJUNCTIVE (the rule C0 earned, docs §2.3a): an image counts
// only if it is BOTH > 3 cents absolute AND > 10 % of the fundamental. A Hann
// window's sidelobes sit ±0.68 Hz off every peak at ~2.6 %, and a bare
// "is there a peak near the predicted frequency" test once found an image in
// the negative control that was its own sidelobe.
//
// ⚠️ AND SUCCESS IS CONJUNCTIVE TOO: "no image" alone is not a detection of a
// fix — a render with no modulation at all scores that. Success requires the
// image gone AND the commanded depth restored.
import { existsSync } from "node:fs";
import {
  readMonoFloat, coarseF0, instantaneousFreq, toCents, envelope,
} from "./_measure-dsp.mjs";

const SCRATCH = process.env.SAXCC_SCRATCH
  || "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad";
const SR = 48000;
const WIN = [2.0, 5.5];
const D4 = 293.6648;              // pitch 62, the doc's bend-arm note
const A4 = 440.0;                 // pitch 69, the CC arm
const DEPTH_CENTS = 50;           // what the bend lane commands

const blocks = (process.env.BLOCKS || "4096,512").split(",").map(Number);
// ⚠️ Keep the rate's TEXT as well as its value: the Swift probe names files
// with Swift's `\(Double)` rendering ("8.0"), and `Number("8.0")` stringifies
// back as "8" — a mismatch that reads as "NO RENDER" for a render that exists.
const rateTexts = (process.env.RATES || "2.0,5.5,8.0,11.0,11.72").split(",")
  .map((s) => s.trim());
const rates = rateTexts.map((s) => ({ text: s, value: Number(s) }));
const kind = process.env.KIND || "bend";
const expectHz = kind === "bend" ? D4 : A4;
// Scan high enough to SEE the moved image: at 512 the predicted image sits at
// 93.75 − f, i.e. ~85.75 Hz for an 8 Hz vibrato.
const SCAN_HI = Number(process.env.SCAN_HI || 120);

/** Local maxima of the modulation spectrum of the cents trace. */
function modSpectrum(path, expect) {
  const x = readMonoFloat(path, SR);
  const from = Math.round(WIN[0] * SR), to = Math.round(WIN[1] * SR);
  const fRef = coarseF0(x, SR, from, 16384, expect * 0.75, expect * 1.25);
  const ifq = instantaneousFreq(x, SR, fRef, from, to);
  const { cents, meanHz } = toCents(ifq.f);
  const n = cents.length;
  let mean = 0;
  for (const v of cents) mean += v;
  mean /= n;
  const w = new Float64Array(n);
  let wsum = 0;
  for (let i = 0; i < n; i++) { w[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / n); wsum += w[i]; }
  const xs = new Float64Array(n);
  for (let i = 0; i < n; i++) xs[i] = (cents[i] - mean) * w[i];
  const amps = [];
  for (let f = 0.5; f <= SCAN_HI; f += 0.02) {
    const om = 2 * Math.PI * f / ifq.traceRate;
    let cr = 0, ci = 0;
    for (let i = 0; i < n; i++) { cr += xs[i] * Math.cos(om * i); ci -= xs[i] * Math.sin(om * i); }
    amps.push({ f, a: 2 * Math.hypot(cr, ci) / wsum });
  }
  const peaks = [];
  for (let i = 2; i < amps.length - 2; i++) {
    if (amps[i].a > amps[i - 1].a && amps[i].a > amps[i + 1].a && amps[i].a > 1.0) {
      peaks.push(amps[i]);
    }
  }
  peaks.sort((p, q) => q.a - p.a);
  const at = (f) => {
    let best = { f, a: 0 };
    for (const p of amps) if (Math.abs(p.f - f) < 0.35 && p.a > best.a) best = p;
    return best;
  };
  return { meanHz, peaks: peaks.slice(0, 5), at, dc: mean };
}

// The demodulator is not flat to 120 Hz, and pretending otherwise would
// understate a surviving high image. Two cascaded boxcars of length
// L = sr/(2*150) plus a central difference over 2D samples (D = 4 ms).
function demodGain(f) {
  const L = Math.round(SR / 300), D = Math.round(SR * 0.004);
  const box = (x) => (x === 0 ? 1 : Math.abs(Math.sin(Math.PI * x) / (Math.PI * x)));
  const diff = (x) => (x === 0 ? 1 : Math.abs(Math.sin(Math.PI * x) / (Math.PI * x)));
  return box(f * L / SR) ** 2 * diff(f * 2 * D / SR);
}

/**
 * The CC 11 arm (P5). CC 11 is a LOUDNESS control on this patch (§3), so the
 * carrier is the amplitude envelope, not the instantaneous frequency.
 *
 * ⚠️ Envelope hop matters here. T5's `hop = 256` gives a 187.5 Hz envelope whose
 * NYQUIST IS 93.75 Hz — exactly the 512-frame block rate, so a 512 image would
 * land on the analyser's own fold. `hopMs = 1` (1000 Hz trace) keeps every
 * image of interest an order of magnitude clear of it.
 *
 * Depth is reported as PERCENT MODULATION of the mean envelope: the authored
 * lane's absolute loudness swing has no cents-like natural unit, and the
 * image/commanded RATIO is the dimensionless quantity the comparison rests on.
 */
function envSpectrum(path) {
  const x = readMonoFloat(path, SR);
  const from = Math.round(WIN[0] * SR), to = Math.round(WIN[1] * SR);
  const env = envelope(x, SR, from, to, { hopMs: 1, winMs: 8 });
  const v = env.v, n = v.length;
  let mean = 0;
  for (const s of v) mean += s;
  mean /= n;
  const w = new Float64Array(n);
  let wsum = 0;
  for (let i = 0; i < n; i++) { w[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / n); wsum += w[i]; }
  const xs = new Float64Array(n);
  for (let i = 0; i < n; i++) xs[i] = (v[i] - mean) * w[i];
  const at = (f) => {
    let best = 0;
    for (let g = f - 0.3; g <= f + 0.3; g += 0.02) {
      const om = 2 * Math.PI * g / env.traceRate;
      let cr = 0, ci = 0;
      for (let i = 0; i < n; i++) { cr += xs[i] * Math.cos(om * i); ci -= xs[i] * Math.sin(om * i); }
      best = Math.max(best, 2 * Math.hypot(cr, ci) / wsum);
    }
    return mean > 0 ? (best / mean) * 100 : 0;   // percent modulation
  };
  return { at, mean };
}

if (kind === "cc11") {
  console.log(`CC 11 arm (P5) — carrier is the AMPLITUDE ENVELOPE, 1000 Hz trace`);
  console.log(`depth = % modulation of mean envelope; the comparison rests on image/commanded\n`);
  for (const block of blocks) {
    const fs = SR / block;
    console.log(`── BLOCK ${block} → CC sampled at ${fs.toFixed(4)} Hz `
      + `(Nyquist ${(fs / 2).toFixed(3)} Hz) ──`);
    for (const { text, value: rate } of rates) {
      const path = `${SCRATCH}/blockfix-cc11-${block}-${text}Hz.wav`;
      if (!existsSync(path)) { console.log(`  ${text} Hz: NO RENDER`); continue; }
      const { at } = envSpectrum(path);
      const imageHz = Math.abs(fs - rate);
      const cmd = at(rate), img = at(imageHz);
      console.log(`  ${text.padStart(5)} Hz | commanded ${cmd.toFixed(2)} % | `
        + `image ${imageHz.toFixed(2)} Hz → ${img.toFixed(2)} % | `
        + `image/commanded ${(img / cmd).toFixed(3)}`
        + `${img > 0.1 * cmd && img > 0.5 ? "  ⛔ IMAGE" : "  ok"}`);
    }
    console.log("");
  }
  process.exit(0);
}

console.log(`kind=${kind} expect=${expectHz} Hz  scan 0.5–${SCAN_HI} Hz  win ${WIN[0]}–${WIN[1]} s`);
console.log(`detection: image counts only if > 3 cents AND > 10 % of the fundamental\n`);

const verdicts = [];
for (const block of blocks) {
  const fs = SR / block;
  console.log(`── BLOCK ${block} frames → controller sampled at ${fs.toFixed(4)} Hz `
    + `(Nyquist ${(fs / 2).toFixed(3)} Hz) ──`);
  for (const { text, value: rate } of rates) {
    const path = `${SCRATCH}/blockfix-${kind}-${block}-${text}Hz.wav`;
    if (!existsSync(path)) { console.log(`  ${text} Hz: NO RENDER at ${path}`); continue; }
    const { meanHz, peaks, at } = modSpectrum(path, expectHz);
    const imageHz = Math.abs(fs - rate);
    const cmd = at(rate).a;
    const img = imageHz <= SCAN_HI ? at(imageHz).a : NaN;
    const counted = img > 3 && img > 0.1 * cmd;
    if (counted) verdicts.push({ block, rate, imageHz, img });
    const g = demodGain(imageHz);
    const corrected = imageHz > 20 ? ` (demod gain ${g.toFixed(3)} → true ≈ ${(img / g).toFixed(2)} c)` : "";
    console.log(
      `  ${String(rate).padStart(5)} Hz | commanded ${cmd.toFixed(2)} c `
      + `(${((cmd / DEPTH_CENTS) * 100).toFixed(1)} % of ${DEPTH_CENTS}) | `
      + `image predicted ${imageHz.toFixed(2)} Hz → ${Number.isNaN(img) ? "OUT OF SCAN" : img.toFixed(2) + " c"}`
      + `${counted ? "  ⛔ IMAGE" : "  ok"}${corrected}`);
    console.log(`        mean f0 ${meanHz.toFixed(3)} Hz | top peaks: `
      + peaks.map((p) => `${p.f.toFixed(2)}Hz@${p.a.toFixed(1)}c`).join("  "));
  }
  console.log("");
}
console.log(`images counted: ${verdicts.length}`);
for (const v of verdicts) {
  console.log(`  block ${v.block}: ${v.rate} Hz → ${v.img.toFixed(2)} c at ${v.imageHz.toFixed(2)} Hz`);
}
