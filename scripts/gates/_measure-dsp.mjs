// Measurement DSP for the GM-sax CC probe (docs/research/measure-gm-sax-cc.md).
//
// NOT a gate: the leading `_` keeps it out of gate discovery (_verdict.mjs:174).
// NOT product code — nothing here ships, nothing here runs on a render thread.
// It exists so the sound-bank questions can be answered from RENDERED AUDIO
// rather than from a plugin's documentation.
//
// Everything is dependency-free on purpose: this machine has no numpy, no
// scipy and no soundfile on any interpreter (measured), and Node's JIT is
// fast enough for a few 6-second files.
//
// ⚠️ The one law this file exists to serve: a metric computed on SILENCE is a
// number, not an error. Every caller must assert level before believing a
// centroid. `analyseSteady` returns `rmsDb` first for exactly that reason.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";

// ── I/O ───────────────────────────────────────────────────────────────────
// Read a wav as mono float32 by going THROUGH ffmpeg rather than parsing the
// header here. render.bounce defaults to 32-bit float and Apple's writers emit
// WAVE_FORMAT_EXTENSIBLE (0xFFFE); a hand-rolled parser that assumes int16
// yields garbage that LOOKS like data instead of failing loudly.
export function readMonoFloat(wavPath, sampleRate) {
  if (!existsSync(wavPath)) throw new Error(`no such render: ${wavPath}`);
  const raw = execFileSync("ffmpeg", [
    "-hide_banner", "-loglevel", "error",
    "-i", wavPath, "-f", "f32le", "-ac", "1", "-ar", String(sampleRate), "-",
  ], { maxBuffer: 1 << 30, encoding: "buffer" });
  if (raw.length < 4) throw new Error(`ffmpeg returned ${raw.length} bytes for ${wavPath}`);
  // Copy into an aligned buffer — Node's Buffer may not be 4-byte aligned.
  const out = new Float32Array(raw.length >> 2);
  const view = new DataView(raw.buffer, raw.byteOffset, raw.length);
  for (let i = 0; i < out.length; i++) out[i] = view.getFloat32(i * 4, true);
  return out;
}

export const dbfs = (v) => (v > 0 ? 20 * Math.log10(v) : -Infinity);

export function rms(x, from = 0, to = x.length) {
  let s = 0;
  const a = Math.max(0, from | 0), b = Math.min(x.length, to | 0);
  for (let i = a; i < b; i++) s += x[i] * x[i];
  return b > a ? Math.sqrt(s / (b - a)) : 0;
}

export function peak(x, from = 0, to = x.length) {
  let m = 0;
  const a = Math.max(0, from | 0), b = Math.min(x.length, to | 0);
  for (let i = a; i < b; i++) { const v = Math.abs(x[i]); if (v > m) m = v; }
  return m;
}

// ── FFT (iterative radix-2, in-place on re/im) ────────────────────────────
export function fft(re, im) {
  const n = re.length;
  if ((n & (n - 1)) !== 0) throw new Error("fft: length must be a power of two");
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      let t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = -2 * Math.PI / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ur = re[i + k], ui = im[i + k];
        const vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        const vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k] = ur + vr; im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi;
        const nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr; cr = nr;
      }
    }
  }
}

const hann = (n) => {
  const w = new Float64Array(n);
  for (let i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / n);
  return w;
};

/** Hann-windowed magnitude spectrum of x[from..from+nfft). */
export function magSpectrum(x, from, nfft) {
  const re = new Float64Array(nfft), im = new Float64Array(nfft);
  const w = hann(nfft);
  for (let i = 0; i < nfft; i++) re[i] = (x[from + i] ?? 0) * w[i];
  fft(re, im);
  const mag = new Float64Array(nfft / 2);
  for (let i = 0; i < nfft / 2; i++) mag[i] = Math.hypot(re[i], im[i]);
  return mag;
}

/**
 * Spectral centroid over [loHz, hiHz].
 * ⚠️ INVARIANT under a gain multiply — the scale cancels between the two sums.
 * That is a feature: it means a centroid that does NOT move cannot be hiding a
 * level change, and a centroid that DOES move cannot be explained by one.
 */
export function centroid(mag, sr, nfft, loHz = 50, hiHz = 16000) {
  const binHz = sr / nfft;
  let num = 0, den = 0;
  for (let i = Math.max(1, Math.ceil(loHz / binHz)); i <= Math.min(mag.length - 1, Math.floor(hiHz / binHz)); i++) {
    num += i * binHz * mag[i];
    den += mag[i];
  }
  return den > 0 ? num / den : NaN;
}

/** Energy ratio (high band / low band), also gain-invariant. */
export function bandRatio(mag, sr, nfft, splitHz = 2000, loHz = 50, hiHz = 16000) {
  const binHz = sr / nfft;
  let lo = 0, hi = 0;
  for (let i = Math.max(1, Math.ceil(loHz / binHz)); i <= Math.min(mag.length - 1, Math.floor(hiHz / binHz)); i++) {
    const e = mag[i] * mag[i];
    if (i * binHz < splitHz) lo += e; else hi += e;
  }
  return lo > 0 ? hi / lo : NaN;
}

/**
 * Per-harmonic level in dB relative to the fundamental. The SHARPEST filter
 * discriminator available here: a pure gain change moves every harmonic by the
 * same amount, so this profile is identical; a low-pass tilts it.
 */
export function harmonicProfile(mag, sr, nfft, f0, count = 12) {
  const binHz = sr / nfft;
  const levels = [];
  for (let k = 1; k <= count; k++) {
    const target = f0 * k;
    if (target > sr / 2 * 0.95) { levels.push(null); continue; }
    // Peak-pick in a ±3 % window so a slightly-off f0 estimate cannot null a
    // harmonic and fake a filter.
    const lo = Math.max(1, Math.floor(target * 0.97 / binHz));
    const hi = Math.min(mag.length - 1, Math.ceil(target * 1.03 / binHz));
    let m = 0;
    for (let i = lo; i <= hi; i++) if (mag[i] > m) m = mag[i];
    levels.push(m);
  }
  const ref = levels[0];
  return levels.map((v) => (v === null || !ref ? null : 20 * Math.log10(Math.max(v, 1e-30) / ref)));
}

// ── f0: coarse estimate, then heterodyne for precision ────────────────────

/** Coarse f0 by spectral peak with parabolic interpolation. */
export function coarseF0(x, sr, from, nfft, loHz = 60, hiHz = 1200) {
  const mag = magSpectrum(x, from, nfft);
  const binHz = sr / nfft;
  const lo = Math.max(1, Math.ceil(loHz / binHz)), hi = Math.min(mag.length - 2, Math.floor(hiHz / binHz));
  let best = lo;
  for (let i = lo; i <= hi; i++) if (mag[i] > mag[best]) best = i;
  const a = mag[best - 1], b = mag[best], c = mag[best + 1];
  const d = (a - 2 * b + c);
  const delta = d !== 0 ? 0.5 * (a - c) / d : 0;
  return (best + delta) * binHz;
}

/**
 * Instantaneous frequency by heterodyne.
 *
 * Shift the fundamental to DC, low-pass away every harmonic and the negative
 * image, then differentiate the unwrapped phase. On a steady tone this resolves
 * far below a cent, which is what a vibrato-depth question needs.
 *
 * Returns { t, f, amp, traceRate } decimated to ~`traceRate` Hz.
 */
export function instantaneousFreq(x, sr, fRef, from, to, {
  lowpassHz = 150, traceRate = 500, diffSpanMs = 4,
} = {}) {
  const n = to - from;
  const yr = new Float64Array(n), yi = new Float64Array(n);
  const w = 2 * Math.PI * fRef / sr;
  for (let i = 0; i < n; i++) {
    const ph = -w * (from + i);
    const s = x[from + i];
    yr[i] = s * Math.cos(ph);
    yi[i] = s * Math.sin(ph);
  }
  // Two cascaded boxcars — first null at sr/L, so L = sr/(2*lowpassHz) puts
  // every harmonic (>= fRef away) deep in the stopband for any musical f0.
  const L = Math.max(2, Math.round(sr / (2 * lowpassHz)));
  boxcar(yr, L); boxcar(yi, L);
  boxcar(yr, L); boxcar(yi, L);

  const D = Math.max(1, Math.round(sr * diffSpanMs / 1000));
  const step = Math.max(1, Math.round(sr / traceRate));
  const t = [], f = [], amp = [];
  for (let i = 2 * L + D; i + D < n - 2 * L; i += step) {
    let dphi = Math.atan2(yi[i + D], yr[i + D]) - Math.atan2(yi[i - D], yr[i - D]);
    while (dphi > Math.PI) dphi -= 2 * Math.PI;
    while (dphi < -Math.PI) dphi += 2 * Math.PI;
    t.push((from + i) / sr);
    f.push(fRef + dphi / (2 * D) * sr / (2 * Math.PI));
    amp.push(Math.hypot(yr[i], yi[i]));
  }
  return { t, f, amp, traceRate: sr / step };
}

function boxcar(a, L) {
  const n = a.length;
  const out = new Float64Array(n);
  let acc = 0;
  for (let i = 0; i < n; i++) {
    acc += a[i];
    if (i >= L) acc -= a[i - L];
    out[i] = acc / Math.min(L, i + 1);
  }
  a.set(out);
}

/** RMS envelope, hop/window in ms. */
export function envelope(x, sr, from, to, { hopMs = 1, winMs = 8 } = {}) {
  const hop = Math.max(1, Math.round(sr * hopMs / 1000));
  const win = Math.max(2, Math.round(sr * winMs / 1000));
  const t = [], v = [];
  for (let i = from; i + win < to; i += hop) {
    t.push(i / sr);
    v.push(rms(x, i, i + win));
  }
  return { t, v, traceRate: sr / hop };
}

/**
 * Strongest periodic component of a trace inside [loHz, hiHz], by direct
 * Goertzel-style evaluation on a fine frequency grid (the traces are short and
 * a 0.02 Hz grid is cheap; an FFT of a 2.5 s trace has 0.4 Hz bins, too coarse
 * to call a vibrato rate).
 *
 * `amplitude` is the PEAK deviation of the fitted sinusoid in the trace's own
 * units. `prominence` is peak/median across the band — a real modulation sits
 * far above its neighbours; noise does not. Without it, "the largest bin in
 * 2-12 Hz" always exists and always looks like an answer.
 */
export function modPeak(trace, traceRate, { loHz = 2, hiHz = 12, stepHz = 0.02 } = {}) {
  const n = trace.length;
  if (n < 16) return { rateHz: NaN, amplitude: NaN, prominence: NaN, mean: NaN, n };
  let mean = 0;
  for (let i = 0; i < n; i++) mean += trace[i];
  mean /= n;
  const w = hann(n);
  let wsum = 0;
  for (let i = 0; i < n; i++) wsum += w[i];
  const xs = new Float64Array(n);
  for (let i = 0; i < n; i++) xs[i] = (trace[i] - mean) * w[i];

  const amps = [];
  for (let fHz = loHz; fHz <= hiHz; fHz += stepHz) {
    const om = 2 * Math.PI * fHz / traceRate;
    let cr = 0, ci = 0;
    for (let i = 0; i < n; i++) { cr += xs[i] * Math.cos(om * i); ci -= xs[i] * Math.sin(om * i); }
    amps.push({ fHz, a: 2 * Math.hypot(cr, ci) / wsum });
  }
  let best = amps[0];
  for (const p of amps) if (p.a > best.a) best = p;
  const sorted = amps.map((p) => p.a).sort((p, q) => p - q);
  const median = sorted[sorted.length >> 1];
  return {
    rateHz: best.fHz,
    amplitude: best.a,
    prominence: median > 0 ? best.a / median : Infinity,
    mean, n,
  };
}

export const centsBetween = (f, ref) => 1200 * Math.log2(f / ref);

/** Convert a frequency trace to cents relative to its own mean. */
export function toCents(fTrace) {
  let mean = 0;
  for (const v of fTrace) mean += v;
  mean /= fTrace.length;
  return { cents: fTrace.map((v) => centsBetween(v, mean)), meanHz: mean };
}

/** Convert an amplitude trace to dB relative to its own mean. */
export function toDbTrace(vTrace) {
  let mean = 0;
  for (const v of vTrace) mean += v;
  mean /= vTrace.length;
  return { db: vTrace.map((v) => 20 * Math.log10(Math.max(v, 1e-12) / Math.max(mean, 1e-12))), meanLin: mean };
}
