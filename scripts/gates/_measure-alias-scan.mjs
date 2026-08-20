// ALIAS SCAN — the analysis that turned §2.3 into §2.3a.
//
// NOT a gate (`_` prefix), NOT product code, and NEEDS NO APP: it re-analyses
// wavs the BENDLPF trials already wrote. Run `_measure-gm-sax-cc.mjs bendlpf
// bendlpfb` first, then this.
//
// ⭐ WHY IT EXISTS. The first pass measured only how much of the COMMANDED
// vibrato rate survived, found a textbook sinc rolloff, and concluded "the
// hosted path block-averages pitch bend." The fit was good and the conclusion
// was half right. Block AVERAGING and SAMPLE-AND-HOLD have the *same* response
// at the commanded rate and completely different consequences:
//
//     averaging      -> sinc rolloff, nothing else                (a shallower vibrato)
//     sample-and-hold -> sinc rolloff PLUS images at |k*fs +- f|  (a DIFFERENT vibrato)
//
// ⚠️ A MODEL THAT PREDICTS EVERYTHING YOU MEASURED CAN STILL BE THE WRONG MODEL
// IF YOU ONLY MEASURED WHAT IT PREDICTS. The discriminator is not the peak — it
// is everything that is NOT the peak. So this prints LOCAL MAXIMA across the
// whole modulation band instead of `modPeak`'s single global winner.
//
// The built-in `.sampler` rows are the negative control: same rates, same
// analysis, and NO images. Without them, an image could be an artefact of the
// heterodyne rather than a fact about the plugin.
import { existsSync } from "node:fs";
import {
  readMonoFloat, coarseF0, instantaneousFreq, toCents,
} from "./_measure-dsp.mjs";

const SCRATCH = process.env.SAXCC_SCRATCH
  || "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad";
const SR = 48000;
const BLOCK = 4096;                 // OfflineRenderer.maximumFrameCount default
const FS = SR / BLOCK;              // 11.719 Hz — the rate bend is sampled at
const WIN = [2.0, 5.5];
const RATES = [2.0, 3.5, 5.5, 8.0, 11.0, 11.72, 14.0];

/** Local maxima of the modulation spectrum of the cents trace, 0.5–20 Hz. */
function modSpectrum(path, expectHz) {
  const x = readMonoFloat(path, SR);
  const from = Math.round(WIN[0] * SR), to = Math.round(WIN[1] * SR);
  const fRef = coarseF0(x, SR, from, 16384, expectHz * 0.75, expectHz * 1.25);
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
  for (let f = 0.5; f <= 20; f += 0.02) {
    const om = 2 * Math.PI * f / ifq.traceRate;
    let cr = 0, ci = 0;
    for (let i = 0; i < n; i++) { cr += xs[i] * Math.cos(om * i); ci -= xs[i] * Math.sin(om * i); }
    amps.push({ f, a: 2 * Math.hypot(cr, ci) / wsum });
  }
  const peaks = [];
  for (let i = 2; i < amps.length - 2; i++) {
    if (amps[i].a > amps[i - 1].a && amps[i].a > amps[i + 1].a && amps[i].a > 1.0) peaks.push(amps[i]);
  }
  peaks.sort((p, q) => q.a - p.a);
  return { meanHz, peaks: peaks.slice(0, 4) };
}

console.log(`block ${BLOCK} frames @ ${SR} Hz -> bend sampled at ${FS.toFixed(4)} Hz`);
console.log(`Nyquist of that sampler = ${(FS / 2).toFixed(3)} Hz — above it, authored vibrato FOLDS DOWN\n`);

let hostedImages = 0, builtInImages = 0, checked = 0;
for (const [label, prefix, expectHz] of [
  ["HOSTED AUSampler (GM sax, D4)", "bendlpf", 293.6648],
  ["BUILT-IN .sampler (sine, A4)  ", "bendlpfBuiltIn", 440],
]) {
  console.log(`── ${label} ──`);
  for (const rate of RATES) {
    const path = `${SCRATCH}/saxcc-${prefix}-${rate}Hz.wav`;
    if (!existsSync(path)) { console.log(`  ${rate} Hz: NO RENDER at ${path} — run the bendlpf trials first`); continue; }
    const { meanHz, peaks } = modSpectrum(path, expectHz);
    const imageHz = Math.abs(FS - rate);
    const strongest = peaks[0]?.a ?? 0;
    // ⚠️ A HANN WINDOW PUTS SIDELOBES AT ±0.68 Hz ON EVERY PEAK, at ~2.6 % of
    // it. The first version of this detector used a bare ±0.25 Hz proximity
    // test and duly "found" an image in the BUILT-IN control at 5.5 Hz — it had
    // caught the 6.18 Hz sidelobe of the 5.50 Hz peak. That single false
    // positive would have destroyed the negative control and with it the whole
    // §2.3a argument. An image must therefore be BOTH absolutely significant
    // and a real fraction of the fundamental, not merely near the right place.
    const image = peaks.find((p) =>
      Math.abs(p.f - imageHz) < 0.25 && Math.abs(p.f - rate) > 0.3
      && p.a > 3.0 && p.a > 0.10 * strongest);
    // At f == fs the image folds to DC, which a 0.5–20 Hz scan cannot see by
    // construction: it shows up as a STATIC DETUNE of the mean f0 instead.
    const isDC = Math.abs(rate - FS) < 0.1;
    checked++;
    if (image) { if (prefix === "bendlpf") hostedImages++; else builtInImages++; }
    const verdictText = isDC
      ? `image folds to DC -> mean f0 ${meanHz.toFixed(3)} Hz (compare the other rows)`
      : `image predicted @ ${imageHz.toFixed(2)} Hz -> ${image ? `FOUND ${image.a.toFixed(1)}c` : "absent"}`;
    console.log(`  cmd ${String(rate).padEnd(5)} meanF0 ${meanHz.toFixed(3)} Hz  `
      + `peaks: ${peaks.map((p) => `${p.f.toFixed(2)}Hz:${p.a.toFixed(1)}c`).join("  ")}`
      + `   [${verdictText}]`);
  }
  console.log("");
}

// The verdict is COMPARATIVE. "Images exist" alone could be an analysis
// artefact; "images exist on one path and not the other, through identical
// code" cannot be.
console.log(`images found: hosted ${hostedImages}, built-in ${builtInImages} (of ${checked} renders)`);
console.log(hostedImages > 0 && builtInImages === 0
  ? "VERDICT: SAMPLE-AND-HOLD on the hosted path only — the built-in negative control is clean."
  : "VERDICT: inconclusive — re-read before quoting §2.3a.");
