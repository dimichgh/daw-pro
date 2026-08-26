// C0 — SYNTHETIC SELF-TEST for the measurement chain in _measure-dsp.mjs.
//
// Runs BEFORE any app is launched. Every signal here has a KNOWN ground truth,
// so this answers "can this chain measure what we are about to ask it to
// measure?" — the question that makes a later null interpretable.
//
// The load-bearing cases are 4, 5 and 6:
//   4  gain invariance — proves a level change CANNOT move the timbre metrics
//   5  filter detection — proves a real filter CAN move them (without this, a
//      null on the sound bank would be worthless)
//   6  NEGATIVE CONTROL on modPeak — proves it does not "find" modulation in a
//      signal that has none. modPeak always returns SOME peak; without this we
//      cannot tell a detection from an artefact.
//
// No app, no ports, no files. Pure computation.
import {
  magSpectrum, centroid, bandRatio, coarseF0, instantaneousFreq,
  envelope, modPeak, toCents, centsBetween, rms,
} from "./_measure-dsp.mjs";

const SR = 48000, DUR = 3.0, N = Math.round(SR * DUR);
const NFFT = 16384;
const F0 = 440;

let pass = 0, fail = 0;
const ck = (name, ok, detail = "") => {
  if (ok) { pass++; console.log(`  ok    ${name}   ${detail}`); }
  else { fail++; console.log(`  FAIL  ${name}   ${detail}`); }
};
const near = (a, b, tol) => Math.abs(a - b) <= tol;

// ── synthesis ─────────────────────────────────────────────────────────────
/** Sine with optional vibrato (cents, Hz) and tremolo (fraction, Hz). */
function tone({ f0 = F0, vibCents = 0, vibHz = 0, tremDepth = 0, tremHz = 0, gain = 1 } = {}) {
  const x = new Float64Array(N);
  let ph = 0;
  for (let i = 0; i < N; i++) {
    const t = i / SR;
    const f = f0 * Math.pow(2, (vibCents / 1200) * Math.sin(2 * Math.PI * vibHz * t));
    ph += 2 * Math.PI * f / SR;
    const am = 1 + tremDepth * Math.sin(2 * Math.PI * tremHz * t);
    x[i] = gain * am * Math.sin(ph);
  }
  return x;
}

/** Harmonically rich tone (1/n rolloff) — something a filter can actually bite. */
function rich(f0 = 200, harmonics = 24, gain = 0.3) {
  const x = new Float64Array(N);
  for (let h = 1; h <= harmonics; h++) {
    if (f0 * h > SR / 2 - 1000) break;
    const a = gain / h;
    for (let i = 0; i < N; i++) x[i] += a * Math.sin(2 * Math.PI * f0 * h * i / SR);
  }
  return x;
}

/** One-pole lowpass, the same shape leg C put in the sampler. */
function lowpass(x, fcHz) {
  const a = 1 - Math.exp(-2 * Math.PI * fcHz / SR);
  const y = new Float64Array(x.length);
  let z = 0;
  for (let i = 0; i < x.length; i++) { z += a * (x[i] - z); y[i] = z; }
  return y;
}

console.log("C0 — synthetic self-test of the measurement chain\n");

// ── 1. coarse f0 ──────────────────────────────────────────────────────────
const steady = tone({});
const f0est = coarseF0(steady, SR, SR * 0.5, NFFT);
ck("1  coarseF0 recovers 440 Hz", near(f0est, F0, 1.0), `got ${f0est.toFixed(3)} Hz`);

// ── 2. vibrato: rate AND depth ────────────────────────────────────────────
const VIB_HZ = 5.0, VIB_CENTS = 50;
const vib = tone({ vibCents: VIB_CENTS, vibHz: VIB_HZ });
const ifq = instantaneousFreq(vib, SR, F0, Math.round(SR * 0.3), Math.round(SR * 2.7));
const { cents } = toCents(ifq.f);
const vp = modPeak(cents, ifq.traceRate);
ck("2a vibrato RATE found", near(vp.rateHz, VIB_HZ, 0.15), `got ${vp.rateHz.toFixed(3)} Hz (want ${VIB_HZ})`);
ck("2b vibrato DEPTH found", near(vp.amplitude, VIB_CENTS, VIB_CENTS * 0.10),
   `got ±${vp.amplitude.toFixed(2)} cents (want ±${VIB_CENTS})`);
ck("2c vibrato is PROMINENT", vp.prominence > 20, `prominence ${vp.prominence.toFixed(1)}`);

// ── 3. tremolo through the envelope path ──────────────────────────────────
const TREM_HZ = 5.0, TREM_DEPTH = 0.25;
const trem = tone({ tremDepth: TREM_DEPTH, tremHz: TREM_HZ });
const env = envelope(trem, SR, Math.round(SR * 0.3), Math.round(SR * 2.7));
const tp = modPeak(env.v, env.traceRate);
ck("3a tremolo RATE found", near(tp.rateHz, TREM_HZ, 0.15), `got ${tp.rateHz.toFixed(3)} Hz`);
ck("3b tremolo is PROMINENT", tp.prominence > 20, `prominence ${tp.prominence.toFixed(1)}`);

// ── 4. GAIN INVARIANCE — a level change must NOT move timbre metrics ──────
const loud = rich(200), quiet = loud.map((v) => v * 0.25);
const mLoud = magSpectrum(loud, SR * 0.5, NFFT);
const mQuiet = magSpectrum(Float64Array.from(quiet), SR * 0.5, NFFT);
const cLoud = centroid(mLoud, SR, NFFT), cQuiet = centroid(mQuiet, SR, NFFT);
const rLoud = bandRatio(mLoud, SR, NFFT), rQuiet = bandRatio(mQuiet, SR, NFFT);
ck("4a centroid is GAIN-INVARIANT", near(cLoud, cQuiet, 0.5),
   `${cLoud.toFixed(3)} vs ${cQuiet.toFixed(3)} Hz (−12 dB apart)`);
ck("4b bandRatio is GAIN-INVARIANT", near(rLoud, rQuiet, 1e-6),
   `${rLoud.toFixed(6)} vs ${rQuiet.toFixed(6)}`);
ck("4c ...and the levels really DID differ", near(20 * Math.log10(rms(quiet) / rms(loud)), -12.04, 0.1),
   `${(20 * Math.log10(rms(quiet) / rms(loud))).toFixed(2)} dB`);

// ── 5. FILTER DETECTION — the chain must SEE a real filter ────────────────
const bright = lowpass(rich(200), 8000), dark = lowpass(rich(200), 1000);
const mB = magSpectrum(bright, SR * 0.5, NFFT), mD = magSpectrum(dark, SR * 0.5, NFFT);
const cB = centroid(mB, SR, NFFT), cD = centroid(mD, SR, NFFT);
const rB = bandRatio(mB, SR, NFFT), rD = bandRatio(mD, SR, NFFT);
ck("5a centroid MOVES with cutoff", cB > cD * 1.5,
   `8 kHz→${cB.toFixed(0)} Hz vs 1 kHz→${cD.toFixed(0)} Hz  (ratio ${(cB / cD).toFixed(2)}×)`);
ck("5b bandRatio MOVES with cutoff", rB > rD * 1.5,
   `${rB.toFixed(4)} vs ${rD.toFixed(4)}  (ratio ${(rB / rD).toFixed(2)}×)`);

// ── 6. NEGATIVE CONTROL — no modulation must NOT read as modulation ───────
const flatIf = instantaneousFreq(steady, SR, F0, Math.round(SR * 0.3), Math.round(SR * 2.7));
const flatCents = toCents(flatIf.f).cents;
const np = modPeak(flatCents, flatIf.traceRate);
// ⭐ C0 EARNED THIS ONE. A perfectly steady tone scores prominence ~28 while its
// modulation depth is ±0.0000 cents — modPeak is ranking the peak/median of
// numerical noise, which is not flat. **PROMINENCE ALONE IS NOT A DETECTION.**
// The operative rule, used by every real measurement below, is CONJUNCTIVE:
// a detection requires a musically meaningful DEPTH *and* high prominence.
const detected = (p, minDepth) => p.amplitude >= minDepth && p.prominence > 20;
ck("6a steady tone is NOT a detection (depth AND prominence)", !detected(np, 1.0),
   `depth ±${np.amplitude.toFixed(4)} cents, prominence ${np.prominence.toFixed(2)} — prominence alone would have said YES`);
ck("6a' the vibrato case IS a detection by the same rule", detected(vp, 1.0),
   `depth ±${vp.amplitude.toFixed(1)} cents, prominence ${vp.prominence.toFixed(1)}`);
ck("6b steady tone: depth is negligible", np.amplitude < 1.0,
   `±${np.amplitude.toFixed(4)} cents (vibrato was ±${vp.amplitude.toFixed(1)})`);
ck("6c the two are SEPARABLE by prominence", vp.prominence > np.prominence * 5,
   `${vp.prominence.toFixed(1)} vs ${np.prominence.toFixed(2)}`);

// ── 7. cents maths ────────────────────────────────────────────────────────
ck("7a octave = 1200 cents", near(centsBetween(880, 440), 1200, 1e-9), `${centsBetween(880, 440)}`);
ck("7b 2 semitones = 200 cents", near(centsBetween(440 * Math.pow(2, 2 / 12), 440), 200, 1e-9), "exact");

console.log(`\nC0 pass=${pass} fail=${fail}`);
process.exit(fail === 0 ? 0 : 1);
