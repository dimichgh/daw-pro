#!/usr/bin/env node
// ⭐⭐⭐ THE GATE THAT THE PERFORMANCE AND THE CAMERA ARE REALLY TWO LAYERS.
//
// The user's architecture: "play the whole scene in 3d and then we can replay
// it from different angles or camera moving around while focusing on playing
// scene". That is only true if the PERFORMANCE is a pure function of t --
// where every disk is, how bright, which notes are glowing, what each trail
// spans -- with the camera downstream of it and never upstream.
//
// It is easy to believe this and be wrong. Before round 5 there were three
// real camera->performance couplings in __frame: a near-cull that read
// cam.position.z, a trail clip against the lens, and the grade's light
// position. Two of those CHANGE WHAT EXISTS, not just what is seen, so a
// second camera take would have been a different performance and nobody would
// have noticed until the two angles refused to cut together.
//
// So this compares the STATE, not the framebuffer: __perf(t) is called under
// take A and take B and the returned vectors must be identical to the last
// digit. Comparing pixels could not do this -- the pixels are SUPPOSED to
// differ; that is what a different angle is.
//
// ⚠⚠ AND IT CARRIES ITS OWN CONTROL. A comparison that always says "equal" is
// indistinguishable from a correct one, so the same diff is run between
// __perf(t) and __perf(t + 1/30). If that comes back equal the gate is BROKEN
// and says so, rather than reporting a pass it did not earn.
//
// Usage: node perfcam.mjs <payload.json> [takeA] [takeB] [--couple]
//   --couple  makes __perf read the camera on purpose, to prove this reddens.
import puppeteer from 'puppeteer';
import fs from 'node:fs';
import path from 'node:path';

// ⛔⛔ CRASH IS NOT FAILURE, AND THIS SUITE COULD NOT TELL THEM APART.
// Positive control, every gate run against a NONEXISTENT payload: ribbon 1 ·
// entry 1 · paperpix 1 · marks 1 · roadpix 1 · framing 1 · perfcam 1 ·
// afterglow 1 — all eight exited 1, the code r4.sh records as A REAL FAILURE,
// having measured nothing. None had a handler; all are ESM with top-level
// await, so a throw becomes an unhandled rejection and node exits 1.
// ⭐ EXIT 2 MEANS BROKEN: the premise failed and there is NO VERDICT. Exit 1
// keeps its meaning — measured, and failed. This is the same rule framegate.py
// already followed and the .mjs half did not, and it is the general form of the
// (F) sky-box crash that silently voided entry's whole verdict on short-right1.
// ⚠ LIMIT, STATED: this catches throws in the module BODY. A throw inside an
// `import` is evaluated before this line runs and still exits 1.
const __GATE = new URL(import.meta.url).pathname.split('/').pop();
const __broke = e => {
  console.error(`  [BROKEN] ${__GATE} crashed before it could measure a thing: ` +
                `${(e && e.message) || e}`);
  console.error(`  [BROKEN] this is NOT a failed assertion — the gate has NO VERDICT here.`);
  process.exit(2);
};
process.on('uncaughtException', __broke);
process.on('unhandledRejection', __broke);


const payloadPath = path.resolve(process.argv[2]);
const args = process.argv.slice(3).filter(a => !a.startsWith('--'));
const COUPLE = process.argv.includes('--couple');
const P = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));
const takes = Object.keys(P.takes || { default: null });
const A = args[0] || 'default';
const B = args[1] || takes.find(x => x !== A) || 'default';
if (A === B) {
  console.error(`  [BROKEN] only one camera take in this payload (${takes.join(', ')}) — ` +
                `there is no second angle to compare against, so nothing was tested`);
  process.exit(2);
}
const HERE = path.dirname(new URL(import.meta.url).pathname);
const W = P.width ?? 1080, H = P.height ?? 1920;

const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await b.newPage();
let pageErr = null;
pg.on('pageerror', e => { pageErr = e.message; });
await pg.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 30000 });
const err = await pg.evaluate(() => window.__err);
if (err) { console.error('PAGE ERROR:', err); await b.close(); process.exit(2); }

if (COUPLE) {
  // the defect, put back: make the performance depend on the lens.
  await pg.evaluate(() => {
    const pure = window.__perf;
    window.__perf = function (t) {
      const S = pure(t);
      const cz = window.__camPos()[2];
      for (const v of S.voices) if (v.live) v.env *= (1 + 0.001 * cz);
      return S;
    };
  });
  console.log('  [control] __perf now scales env by cam.position.z — a performance');
  console.log('            that depends on the lens, which is exactly the class of');
  console.log('            coupling this gate exists to catch');
}

const TIMES = [0.30, 1.02, 2.27, 4.02, 6.60, 8.02, 9.52, 11.52, 12.90];
const grab = async (take) => {
  await pg.evaluate(tk => { window.__setLook({ take: tk }); }, take);
  const out = [];
  for (const t of TIMES) {
    // drive a full frame so the camera really moves for this take, then read
    // the performance -- reading __perf alone could pass while __frame differs
    await pg.evaluate(tt => window.__frame(tt), t);
    const camz = await pg.evaluate(() => window.__camPos());
    const S = await pg.evaluate(tt => JSON.parse(JSON.stringify(window.__perf(tt))), t);
    out.push({ t, S, camz });
  }
  return out;
};

const a = await grab(A), c = await grab(B);
await pg.evaluate(() => window.__setLook({ take: 'default' }));
await b.close();
if (pageErr) { console.error('PAGE ERROR:', pageErr); process.exit(2); }

const J = x => JSON.stringify(x);
const camMoved = a.some((r, i) => J(r.camz) !== J(c[i].camz));
const diffs = [];
for (let i = 0; i < a.length; i++) if (J(a[i].S) !== J(c[i].S)) diffs.push(a[i].t);

console.log(`\nPERFORMANCE vs CAMERA — take "${A}" against take "${B}", ${TIMES.length} timestamps`);
for (let i = 0; i < a.length; i++) {
  const same = J(a[i].S) === J(c[i].S);
  console.log(`  t=${a[i].t.toFixed(2)}  voices ${a[i].S.voices.length} arcs ${a[i].S.arcs.length} ` +
    `strikes ${a[i].S.strikes.length}  cam ${a[i].camz.map(v=>v.toFixed(2)).join(',')} vs ` +
    `${c[i].camz.map(v=>v.toFixed(2)).join(',')}  ${same ? 'state identical' : '<-- STATE DIFFERS'}`);
}

// ---- the controls, both of them ------------------------------------------
const selfDiff = J(a[4].S) !== J(a[5].S);       // 6.60 vs 8.02: must differ
console.log(`\n  control A: the same take at two DIFFERENT times differs: ${selfDiff}`);
console.log(`  control B: the two takes actually moved the camera:       ${camMoved}`);
if (!selfDiff) {
  console.error(`  [BROKEN] the state comparison cannot tell two different moments apart, ` +
                `so "identical" here means nothing`);
  process.exit(2);
}
if (!camMoved) {
  console.error(`  [BROKEN] take "${A}" and take "${B}" put the camera in the same place — ` +
                `there is no second angle here, so nothing was tested`);
  process.exit(2);
}
if (diffs.length) {
  console.error(`  [ FAIL ] the performance CHANGED when the camera changed, at t=` +
    diffs.map(v => v.toFixed(2)).join(', ') +
    ` — these are not two layers, and a second angle is a different take of a ` +
    `different performance`);
  process.exit(1);
}
console.log(`  [ ok ] one performance, two cameras: state identical at all ${TIMES.length} timestamps`);
