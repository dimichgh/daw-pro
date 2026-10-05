// ⭐ THE TERMINAL `done` FADE, MEASURED PER VOICE. road.html:1787 computes
//     done = t - (last note's t + dur)
// and :1788 multiplies env by exp(-done/1.1) once a voice has NO NEXT NOTE.
// ⛔ IT IS NOT A DEFECT BY ITSELF — it is what lets a film end. It becomes one
// when voices STOP AT DIFFERENT TIMES: the Moonlight Short shipped with the
// melody a dull grey dot beside brilliant white bass heads, because its excerpt
// cut the melody 3.2 s before the bass. An EXCERPT is exactly where that
// asymmetry gets manufactured, so an excerpt has to measure it.
// usage: node lib/_donefade.mjs <payload> <t0> <t1> [step]
// prints, per sampled instant, every voice's env / envCore / road, and the
// between-voice RATIO of the brightest to the dimmest LIVE voice.
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path'; import { fileURLToPath } from 'url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const t0 = Number(process.argv[3]), t1 = Number(process.argv[4]);
const st = Number(process.argv[5] || 0.5);
const b = await puppeteer.launch({ headless: 'shell', args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await b.newPage(); await pg.setViewport({ width: P.width, height: P.height });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err');
const rows = await pg.evaluate((a, z, s) => {
  const o = [];
  for (let t = a; t <= z + 1e-9; t += s) {
    const S = window.__perf(t);
    o.push({ t: +t.toFixed(3), v: S.voices.map(x => ({ i: x.i, road: x.road, live: !!x.live,
      env: +x.env.toFixed(4), core: +x.envCore.toFixed(4) })) });
  }
  return o;
}, t0, t1, st);
await b.close();
// the last onset+dur per voice, so `done` can be stated rather than guessed
const last = {};
for (const v of P.voices) last[v.index] = Math.max(...v.notes.map(n => n.t + n.dur));
const NM = {}; (P.roads || []).forEach(r => NM[r.index] = r.name);
console.log('  t      ' + Object.keys(last).map(i => `v${i}`.padStart(9)).join('') + '   ratio');
for (const r of rows) {
  const lv = r.v.filter(x => x.live);
  const mx = Math.max(...lv.map(x => x.env)), mn = Math.min(...lv.map(x => x.env));
  console.log(`  ${r.t.toFixed(2).padStart(6)} `
    + r.v.map(x => (x.live ? x.env.toFixed(4) : '   --  ').padStart(9)).join('')
    + `   ${lv.length ? (mx / mn).toFixed(3) : '-'}  (live ${lv.length}/${r.v.length})`);
}
console.log('\n  voice -> road, last note ends at, `done` fires from:');
for (const v of P.voices) console.log(`   v${v.index} ${(NM[v.road] || ('road ' + v.road)).padEnd(8)} `
  + `last note ends ${last[v.index].toFixed(4)}s`);
const ends = Object.values(last);
console.log(`  spread between voices: ${(Math.max(...ends) - Math.min(...ends)).toFixed(4)}s `
  + `(0 = every voice stops on the same instant, so the fade is UNIFORM)`);
