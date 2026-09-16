// THE SCALING RUN. Walks a payload end to end at 30 fps calling __frame(t) with
// NO screenshot, and samples the LIVE scene graph and the JS heap along the way.
// ⚠ IT DOES NOT MEASURE THE SHOOT. A screenshot dominates the real pipeline (the
// build reports 14.1 fps end to end while this loop runs an order faster), so the
// per-frame figure here is the ENGINE's cost, not the film's. Both are reported
// in NOTES and they answer different questions.
// Usage: node _scaling.mjs <payload.json> [samples]
import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const N = Number(process.argv[3] ?? 16);
const HERE = path.dirname(new URL(import.meta.url).pathname);
const RSEC = P.pictureSeconds ?? P.renderSeconds ?? ((P.total ?? 14) + 2);
const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files', '--js-flags=--expose-gc'] });
const pg = await br.newPage();
await pg.setViewport({ width: P.width, height: P.height, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
const t0 = Date.now();
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 120000 });
const initMs = Date.now() - t0;
const e = await pg.evaluate(() => window.__err); if (e) { console.error('[BROKEN] ' + e); process.exit(2); }
console.log(`init ${initMs} ms   window ${RSEC.toFixed(2)} s   ${Math.round(RSEC*30)} frames`);
console.log('     t    frameMs  objects  geoms   verts  visible  sheetKids  labels  heapMB');
const rows = [];
const total = await pg.evaluate(async (rsec, n) => {
  const out = []; const NF = Math.round(rsec * 30);
  const every = Math.max(1, Math.floor(NF / n));
  const t00 = performance.now();
  for (let i = 0; i < NF; i++) {
    const t = i / 30;
    const a = performance.now(); window.__frame(t); const b = performance.now();
    if (i % every === 0) {
      const s = window.__stats();
      out.push({ t, ms: b - a, ...s });
    }
  }
  return { rows: out, wallMs: performance.now() - t00, NF };
}, RSEC, N);
for (const r of total.rows)
  console.log(`${r.t.toFixed(2).padStart(7)} ${r.ms.toFixed(2).padStart(8)} ${String(r.objects).padStart(8)} `
    + `${String(r.geometries).padStart(6)} ${String(r.vertices).padStart(8)} ${String(r.visibleMeshes).padStart(8)} `
    + `${String(r.sheetChildren).padStart(10)} ${String(r.labels).padStart(7)} `
    + `${(r.mem ? (r.mem/1048576).toFixed(0) : '-').padStart(7)}`);
const ms = total.rows.map(r => r.ms);
console.log(`\n__frame over ${total.NF} frames: total ${(total.wallMs/1000).toFixed(1)} s, `
  + `mean ${(total.wallMs/total.NF).toFixed(2)} ms/frame, sampled min ${Math.min(...ms).toFixed(2)} max ${Math.max(...ms).toFixed(2)} ms`);
const f = total.rows[0], l = total.rows[total.rows.length-1];
const grew = ['objects','geometries','vertices','sheetChildren','labels']
  .map(k => `${k} ${f[k]} -> ${l[k]}${l[k] > f[k] ? '  GREW' : ''}`).join('\n  ');
console.log('  ' + grew);
await br.close();
