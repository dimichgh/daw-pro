// ⭐⭐ (C) THE VISIBILITY CULL GATE. Two claims, in both directions, and the
// controls for both.
//
//   (C1) NOTHING VISIBLE IS EVER REMOVED — the rendered frame with the cull ON
//        is IDENTICAL, pixel for pixel, to the frame with it OFF. This is the
//        claim the falloff derivation only BOUNDS: the derivation is in
//        linear-light and the frame is tone-mapped, so the pixels are the proof.
//   (C2) THE DRAWN OBJECT COUNT IS BOUNDED — with the cull on, `visibleMeshes`
//        does not grow when the film gets 5x longer. With it OFF it does, and
//        the gate MEASURES that rather than asserting it.
//
// CONTROLS, both of which must FIRE or the run reports [BROKEN] and exits 2:
//   * (C1)'s control shrinks `cullMargin` to a value that removes things that
//     ARE visible; the pixel diff must then be non-zero. A pixel check that
//     cannot see an over-aggressive cull would pass an empty screen.
//   * (C2)'s control is the cull-OFF measurement itself: if the short and long
//     payloads do NOT differ in visibleMeshes with the cull off, there was no
//     growth to bound and the gate has proved nothing.
//
// usage: node lib/cull.mjs <long-payload.json> [short-payload.json]
// exit 0 pass · 1 measured and failed · 2 broken (premise failed, no verdict)
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path';
import os from 'os';
import { execFileSync } from 'child_process';

const HERE = path.dirname(new URL(import.meta.url).pathname);
const LONG = process.argv[2];
const SHORT = process.argv[3] || path.join(HERE, '../02-moonlight/out/payload.json');
if (!LONG) { console.log('[BROKEN] usage: node lib/cull.mjs <long-payload> [short-payload]'); process.exit(2); }

const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });

async function open(payloadPath, look) {
  const P = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));
  Object.assign(P.look, look || {});
  const pg = await br.newPage();
  await pg.setViewport({ width: P.width ?? 1920, height: P.height ?? 1080 });
  await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
  await pg.evaluate(p => window.__init(p), P);
  await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
  const err = await pg.evaluate(() => window.__err || null);
  if (err) { console.log('[BROKEN] __init: ' + err); process.exit(2); }
  return { pg, P };
}
// ⚠ PIXELS ARE READ IN PYTHON/PIL, the way every other gate in this directory
// reads them — no new image dependency, and the same decoder the seam gate's
// numbers came from.
const PY = '/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python';
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'cull-'));
let shotN = 0;
async function shot(pg, t) {
  await pg.evaluate(x => window.__frame(x), t);
  const f = path.join(work, `s${shotN++}.png`);
  await pg.screenshot({ path: f });
  return f;
}
function diff(a, b) {
  return JSON.parse(execFileSync(PY, ['-c', `
import sys, json
from PIL import Image
import numpy as np
a = np.asarray(Image.open(sys.argv[1]).convert("RGB"), dtype=int)
b = np.asarray(Image.open(sys.argv[2]).convert("RGB"), dtype=int)
if a.shape != b.shape:
    print(json.dumps({"px": -1, "max": -1})); sys.exit(0)
d = np.abs(a - b).max(axis=2)
print(json.dumps({"px": int((d > 0).sum()), "max": int(d.max())}))
`, a, b], { encoding: 'utf8' }));
}

const PL = JSON.parse(fs.readFileSync(LONG, 'utf8'));
const span = PL.total ?? 30;
const TS = [0.6, 0.18, 0.34, 0.52, 0.71, 0.88, 0.97].map(f => +(span * f).toFixed(3));

console.log(`\nCULL — falloff-derived visibility cull, ${TS.length} frames of ${path.basename(path.dirname(LONG))}`);

const off = await open(LONG, { cull: false });
const on  = await open(LONG, { cull: true });
const R = await on.pg.evaluate(() => window.__cullRadius ? window.__cullRadius() : -1);

let worst = { px: 0, max: 0, t: null };
let visOn = [], visOff = [];
for (const t of TS) {
  const a = await shot(off.pg, t), b = await shot(on.pg, t);
  const d = diff(a, b);
  if (d.px < 0) { console.log('[BROKEN] frame sizes differ'); process.exit(2); }
  visOff.push((await off.pg.evaluate(() => window.__stats().visibleMeshes)));
  visOn.push((await on.pg.evaluate(() => window.__stats().visibleMeshes)));
  if (d.px > worst.px) worst = { ...d, t };
  console.log(`   t=${String(t).padStart(7)}  differing px ${String(d.px).padStart(8)}  max channel delta ${d.max}   visible meshes ${visOff[visOff.length-1]} -> ${visOn[visOn.length-1]}`);
}

// (C1) control: a margin small enough to remove things that ARE visible
const CTRL_MARGIN = Number(process.env.CULL_CTRL_MARGIN ?? 0.08);
const ctrl = await open(LONG, { cull: true, cullMargin: CTRL_MARGIN });
let ctrlWorst = 0;
for (const t of TS.slice(0, 3)) {
  const a = await shot(off.pg, t), c = await shot(ctrl.pg, t);
  ctrlWorst = Math.max(ctrlWorst, diff(a, c).px);
}
console.log(`   (C1) control at cullMargin=${CTRL_MARGIN}: ${ctrlWorst} differing px (must be > 0, or the pixel check is blind)`);

// (C2) the growth this bounds, measured on the comparator payload.
// ⛔⛔ THE COMPARATOR MUST BE LONGER THAN THE CULL RADIUS OR IT PROVES NOTHING.
// The first run of this gate used the approved 8-bar film, whose ENTIRE ROAD is
// 45.9 units against a 50.3-unit radius: nothing in it is ever culled, so its
// "cull ON" count is just its "cull OFF" count and the comparison measured the
// difference between a film that fits inside the radius and one that does not.
// That is not boundedness. BROKEN, not a pass.
{
  const zlen = JSON.parse(fs.readFileSync(SHORT, 'utf8')).zlen ?? 0;
  if (zlen <= R) {
    console.log(`\n  [BROKEN] (C2)'s comparator road is ${zlen.toFixed(1)} units long, inside the ${R.toFixed(1)}-unit cull radius — nothing in it can be culled, so it cannot show growth being bounded. No verdict.`);
    await br.close(); process.exit(2);
  }
}
const soff = await open(SHORT, { cull: false });
const son  = await open(SHORT, { cull: true });
const sspan = JSON.parse(fs.readFileSync(SHORT, 'utf8')).total ?? 30;
let sOff = 0, sOn = 0;
for (const f of [0.3, 0.6, 0.9]) {
  await soff.pg.evaluate(x => window.__frame(x), sspan * f);
  await son.pg.evaluate(x => window.__frame(x), sspan * f);
  sOff = Math.max(sOff, await soff.pg.evaluate(() => window.__stats().visibleMeshes));
  sOn  = Math.max(sOn,  await son.pg.evaluate(() => window.__stats().visibleMeshes));
}
const lOff = Math.max(...visOff), lOn = Math.max(...visOn);
console.log(`\n   (C2) visible meshes, short film -> long film (${(span/sspan).toFixed(1)}x the length)`);
console.log(`        cull OFF: ${sOff} -> ${lOff}   (+${lOff - sOff})`);
console.log(`        cull ON : ${sOn} -> ${lOn}   (+${lOn - sOn})`);
console.log(`   cull radius ${R > 0 ? R.toFixed(1) + ' world units' : '(not exported)'}`);
// ⚠ THE zlen > R GUARD IS WEAKER THAN THE THING IT GUARDS AGAINST, measured
// 2026-09-08. 07-bach-short has zlen 81.9 against a 50.3 radius, so it passes
// the guard — and still reads cull ON == cull OFF == 105, because at the three
// sampled instants the road AHEAD OF THE CAMERA is inside the radius. That is
// not a broken comparator: an entirely-unculled short film is the CLEANEST
// possible baseline for "how much would this have grown". But it must be SAID,
// or the next reader concludes the cull does nothing.
if (sOn === sOff)
  console.log(`   note: the comparator is itself unculled (${sOn} either way at the sampled instants), so it is a clean uncalled baseline, not evidence the cull is inert`);
await br.close();

let bad = false;
if (ctrlWorst <= 0) {
  console.log(`\n  [BROKEN] (C1)'s control did not fire: an over-aggressive cull changed no pixels, so the pixel check proves nothing. No verdict.`);
  process.exit(2);
}
if (lOff <= sOff) {
  console.log(`\n  [BROKEN] (C2) has nothing to bound: with the cull OFF the long film draws no more meshes than the short one. No verdict.`);
  process.exit(2);
}
const PXLIM = Number(process.env.CULL_PX ?? 0);
if (worst.px > PXLIM) {
  console.log(`\n  [ FAIL ] (C1) the cull CHANGED THE PICTURE: ${worst.px} pixels differ at t=${worst.t} (max channel delta ${worst.max}, limit ${PXLIM} px). Something visible was removed.`);
  bad = true;
}
const GROW = lOn - sOn, GROWOFF = lOff - sOff;
if (GROW > GROWOFF * 0.25) {
  console.log(`\n  [ FAIL ] (C2) the cull did not bound anything: drawn meshes still grew by ${GROW} against ${GROWOFF} uncalled.`);
  bad = true;
}
if (bad) process.exit(1);
console.log(`\n  [ ok ] (C) the cull removes nothing visible (0 differing pixels at ${TS.length} frames, and its control fires at ${ctrlWorst} px), and it holds the drawn mesh count at ${lOn} where an unculled film reaches ${lOff}.`);
