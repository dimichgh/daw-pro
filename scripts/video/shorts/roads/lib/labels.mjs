#!/usr/bin/env node
// ⭐⭐ (L) THE ROAD LABELS MUST READ THE RIGHT WAY ROUND — ASSERTED, not eyeballed.
// road.html's own comments record FIVE label-orientation errors in this project,
// every one of them found by cropping a frame and looking, and a sixth was found
// the same way at t=19.2 on the journey camera: with the per-label z-rule "Bass"
// and one "Arpeggio" read correctly while "Melody" and the other "Arpeggio" came
// back MIRRORED IN THE SAME FRAME. Nothing in the suite could see it.
//
// THE MEASUREMENT: project two points on each label's own baseline — local
// x = -0.4 and x = +0.4, i.e. the start and end of the word — and require the
// END to land to the RIGHT of the START on screen. That is exactly the question
// "does this word read left to right", asked of the real projection rather than
// of a proxy for where the camera is.
//
// ⚠ IT ONLY JUDGES LABELS THAT ARE ACTUALLY ON SCREEN and in front of the lens;
// a label nobody can see cannot be back-to-front for a viewer. If that leaves it
// with nothing to judge it reports BROKEN, never a hollow pass.
//
// CONTROL: --freeze pins labelFlip to false (rotation.z = 0 for every label,
// whatever the camera does), which is the round-7 behaviour that was measured
// mirrored. It MUST fail.
//
// Usage: node labels.mjs <payload.json> [--freeze]
import puppeteer from 'puppeteer';
import fs from 'node:fs';
import path from 'node:path';

const __GATE = new URL(import.meta.url).pathname.split('/').pop();
const __broke = e => {
  console.error(`  [BROKEN] ${__GATE} crashed before it could measure a thing: ${(e && e.message) || e}`);
  console.error(`  [BROKEN] this is NOT a failed assertion — the gate has NO VERDICT here.`);
  process.exit(2);
};
process.on('uncaughtException', __broke);
process.on('unhandledRejection', __broke);

const payloadPath = path.resolve(process.argv[2]);
const FREEZE = process.argv.includes('--freeze');
const P = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));
if (FREEZE) {
  P.look = Object.assign({}, P.look, { labelFlip: false });
  console.log('  [control] labelFlip pinned to false — every label frozen at rotation.z = 0');
}
const HERE = path.dirname(new URL(import.meta.url).pathname);
const W = P.width ?? 1080, H = P.height ?? 1920;

const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await br.newPage();
let pageErr = null;
pg.on('pageerror', e => { pageErr = e.message; });
await pg.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
const e0 = await pg.evaluate(() => window.__err);
if (e0) { console.error('PAGE ERROR:', e0); await br.close(); process.exit(2); }

const RSEC = P.renderSeconds ?? ((P.total ?? 14) + (P.look?.coastTau ?? 0.8) * 2.5);
const N = Number(process.env.LABELS_SAMPLES ?? 120);
let seen = 0, bad = [], frames = 0;
for (let i = 0; i < N; i++) {
  const t = (i + 0.5) * RSEC / N;
  const r = await pg.evaluate(tt => {
    window.__frame(tt);
    return window.__labelReading();
  }, t);
  if (r.length) frames++;
  for (const L of r) { seen++; if (L.d <= 0) bad.push({ t: +t.toFixed(2), ...L }); }
}
if (pageErr) { console.error('PAGE ERROR:', pageErr); await br.close(); process.exit(2); }
await br.close();

console.log(`\nLABELS — every on-screen road label reads left to right, ${N} samples over ${RSEC.toFixed(1)}s`);
if (!seen) {
  console.log('  [BROKEN] no label was on screen in any sample — nothing was measured');
  process.exit(2);
}
console.log(`  ${seen} on-screen label-frames across ${frames} of ${N} samples; ${bad.length} read BACKWARDS`);
if (bad.length) {
  console.log('  first: ' + bad.slice(0, 6).map(b => `t=${b.t} at screen(${b.sx},${b.sy}) d=${b.d}`).join('  '));
  console.log('  [ FAIL ] a road label is mirrored on screen');
  process.exit(1);
}
console.log('  [ ok ] every visible label reads the right way round');
