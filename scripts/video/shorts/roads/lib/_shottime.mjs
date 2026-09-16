// ⭐ THE MEASUREMENT THAT DECIDES WHETHER A VISIBILITY CULL BUYS ANYTHING.
// Times the REAL shoot path — __frame(t) followed by pg.screenshot() — because
// timing comp.render() with performance.now() measures GL command SUBMISSION,
// not GPU work, and would read flat on a GPU-bound frame whatever N is.
// usage: node lib/_shottime.mjs <payload.json> [n] [label]
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const N = Number(process.argv[3] || 12);
const LBL = process.argv[4] || path.basename(path.dirname(process.argv[2]));
const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await br.newPage();
await pg.setViewport({ width: P.width ?? 1920, height: P.height ?? 1080 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
const span = P.total ?? 30;
const ts = []; for (let i = 0; i < N; i++) ts.push(span * (i + 0.5) / N);
for (const t of ts.slice(0, 3)) { await pg.evaluate(x => window.__frame(x), t); await pg.screenshot({ type: 'png' }); }
let frameMs = 0, shotMs = 0;
for (const t of ts) {
  let a = Date.now(); await pg.evaluate(x => window.__frame(x), t); frameMs += Date.now() - a;
  a = Date.now(); await pg.screenshot({ type: 'png' }); shotMs += Date.now() - a;
}
const st = await pg.evaluate(() => window.__stats());
const m = await pg.metrics();
const notes = P.voices.reduce((a, v) => a + v.notes.length, 0);
console.log(`${LBL}: notes=${notes} total=${span.toFixed(1)}s  __frame ${(frameMs/N).toFixed(1)} ms  screenshot ${(shotMs/N).toFixed(1)} ms  sum ${((frameMs+shotMs)/N).toFixed(1)} ms/frame`);
console.log(`   stats ${JSON.stringify(st)}  heapMB=${(m.JSHeapUsedSize/1e6).toFixed(1)}`);
await br.close();
