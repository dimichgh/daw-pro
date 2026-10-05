#!/usr/bin/env node
// THE EXACT REPRODUCTION of the long-rest re-entry defect, kept because the
// tuning sample cannot show it on its own: this REMOVES one voice's notes for
// 3 < t < 7 to manufacture the rest, which is the observer's own experiment.
// ⚠ RE-MEASURED 2026-09-07, AFTER THE ASSERTION INVERTED. The history, in order,
// on this same manufactured 4 s rest:
//   r19 (shipped):  live false->true at t=7.033, env 1.0531, spawning FALSE —
//                   a 12,240x one-frame step out of darkness. The defect.
//   r13 (the fix):  live false->true at t=5.200, env 0.0104, spawning TRUE.
//                   It flew back in — and the user rejected that on sight.
//   NOW:            NO live flip at all. The light never goes out, so there is
//                   nothing to come back. Worst one-frame ratio 8.1x at t=7.033,
//                   which is the note being STRUCK from the 0.13 idle floor —
//                   an ordinary strike, not an appearance.
// ⚠ `--off` (spawnReentryOff) is now a NO-OP and measures identically, because
// what it used to switch off is off by default. Kept as history, not as a control;
// the live controls are reentry.mjs's --r13 and --r19.
import puppeteer from 'puppeteer';
import fs from 'node:fs';
import path from 'node:path';
const __broke = e => { console.error(`  [BROKEN] repro crashed: ${(e && e.message) || e}`); process.exit(2); };
process.on('uncaughtException', __broke); process.on('unhandledRejection', __broke);
const HERE = path.dirname(new URL(import.meta.url).pathname);
const P = JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), 'utf8'));
P.voices[0].notes = P.voices[0].notes.filter(n => !(n.t > 3 && n.t < 7));
const OFF = process.argv.includes('--off');
P.look = P.look || {}; if (OFF) P.look.spawnReentryOff = true;
const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await b.newPage();
await pg.setViewport({ width: P.width, height: P.height });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err');
const rows = await pg.evaluate(() => {
  const out = []; let prev = null;
  for (let n = 0; n <= 300; n++) {
    const t = n / 30 + 2.0;
    const v = (window.__perf(t).voices || []).find(x => x.i === 0);
    const env = v ? v.env : 0;
    out.push({ t: +t.toFixed(3), env: +env.toFixed(4), live: !!(v && v.live),
               sp: !!(v && v.spawning), jump: +(prev && prev > 0 ? env / prev : 0).toFixed(1) });
    prev = env;
  }
  return out;
});
await b.close();
console.log(`${OFF ? 'CONTROL spawnReentryOff' : 'FILM'} — voice 0, notes removed 3<t<7`);
for (let i = 1; i < rows.length; i++) if (rows[i - 1].live !== rows[i].live)
  console.log(`   live flip at t=${rows[i].t} env=${rows[i].env} spawning=${rows[i].sp} jump=${rows[i].jump}x`);
const w = rows.reduce((a, r) => r.jump > a.jump ? r : a, { jump: 0 });
console.log(`   worst one-frame env ratio: ${w.jump}x at t=${w.t} (env ${w.env}, spawning ${w.sp})`);
