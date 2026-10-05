// ⛔⛔ READ THIS BEFORE BELIEVING A NUMBER FROM THIS PROBE. `stretch()` repeats
// the piece end to end but does NOT update `total`, `zFar`, `zlen`, `texH` or
// `paperRepeatV` — so at K>1 most of the notes sit PAST THE END OF THE ROAD and
// off the paper. That is fine for the question it was written for (does the
// per-frame JS cost grow with the NOTE COUNT) and WRONG for anything about the
// scene graph or the rendered picture: its "72 sheet children at 1x and 8x" is
// how I briefly concluded the scene was already bounded, and on the REAL long
// payload it is 72 -> 276. For scene/pixel/timing questions use lib/_shottime.mjs
// on a payload prep.mjs actually produced.
// ⭐ THE MECHANISM PROBE for the O(N^2) fix. Times window.__perf(t) + __frame(t)
// ALONE — no render, no screenshot — so the JS loop cost is not hidden under a
// GPU-bound 1080p bloom pass (the film's own fps cannot see this fix at all).
// Runs the SAME payload at several LENGTH MULTIPLES: the claim being tested is
// "per-frame cost no longer grows with N", so the number that shows it is the
// per-frame microseconds at 1x vs 8x — rising before, flat after.
// usage: node lib/_perfprobe.mjs <payload.json> <road.html> [mults] [samples]
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const PAY = process.argv[2], PAGE = process.argv[3] || path.join(HERE, 'road.html');
const MULTS = (process.argv[4] || '1,2,4,8').split(',').map(Number);
const NS = Number(process.argv[5] || 40);
const base = JSON.parse(fs.readFileSync(PAY, 'utf8'));

// stretch the payload by repeating the piece K times end to end. Same note
// SHAPE, K times the note COUNT and K times the length — which is exactly how a
// longer film differs from this one.
function stretch(P, K) {
  const Q = JSON.parse(JSON.stringify(P));
  const span = Math.max(...P.voices.flatMap(v => v.notes.map(n => n.t + (n.dur||0)))) + 1.0;
  for (const v of Q.voices) {
    const src = v.notes.slice(); v.notes = [];
    for (let k = 0; k < K; k++) for (const n of src) v.notes.push({ ...n, t: n.t + k * span });
  }
  if (Q.notes) { const src = Q.notes.slice(); Q.notes = [];
    for (let k = 0; k < K; k++) for (const n of src) Q.notes.push({ ...n, t: n.t + k * span }); }
  if (Q.onsets) { const src = Q.onsets.slice(); Q.onsets = [];
    for (let k = 0; k < K; k++) for (const o of src) Q.onsets.push(o + k * span); }
  Q.__span = span * K;
  return Q;
}

const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const rows = [];
for (const K of MULTS) {
  const P = stretch(base, K);
  const N = P.voices.reduce((a, v) => a + v.notes.length, 0);
  const pg = await br.newPage();
  await pg.goto('file://' + PAGE, { waitUntil: 'networkidle0' });
  await pg.evaluate(p => window.__init(p), P);
  await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
  const err = await pg.evaluate(() => window.__err || null);
  if (err) { console.log('[BROKEN] __init: ' + err); process.exit(2); }
  const r = await pg.evaluate((span, ns) => {
    const ts = []; for (let i = 0; i < ns; i++) ts.push(span * (i + 0.5) / ns);
    for (const t of ts) { window.__perf(t); window.__frame(t); }   // warm
    const a0 = performance.now();
    for (const t of ts) window.__perf(t);
    const a1 = performance.now();
    for (const t of ts) { window.__perf(t); window.__frame(t); }
    const a2 = performance.now();
    return { perfUs: (a1 - a0) * 1000 / ts.length,
             us: (a2 - a1) * 1000 / ts.length,
             pool: (window.__stats && window.__stats().pool) ?? -1 };
  }, P.__span, NS);
  await pg.close();
  rows.push({ K, N, us: r.us, perfUs: r.perfUs, pool: r.pool });
  console.log(`K=${K}  notes=${N}  __perf ${r.perfUs.toFixed(0)} us  perf+frame ${r.us.toFixed(0)} us  pool=${r.pool}`);
}
await br.close();
const a = rows[0], b = rows[rows.length - 1];
console.log(`growth: notes x${(b.N/a.N).toFixed(1)}  ->  __perf x${(b.perfUs/a.perfUs).toFixed(2)}  perf+frame x${(b.us/a.us).toFixed(2)}`);
