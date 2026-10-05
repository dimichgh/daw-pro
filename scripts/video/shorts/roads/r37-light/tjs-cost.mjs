import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const R36 = path.join(HERE, '..', 'r36-stage');
const P = JSON.parse(fs.readFileSync(path.join(R36, 'stage.L2.payload.json'), 'utf8'));
const br = await puppeteer.launch({ headless: 'shell', args: ['--use-angle=metal','--no-sandbox','--allow-file-access-from-files'] });
const pg = await br.newPage(); await pg.setViewport({ width: P.width, height: P.height });
await pg.goto('file://' + path.join(R36, 'stage.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err');
for (let i=0;i<10;i++) await pg.evaluate(t=>window.__frame(t), 26.0+i*0.01);   // warm
const N=60, t0=Date.now(); const tmp='/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/b1758ed8-13eb-4d9e-a984-4f35f1dff02d/scratchpad/tjs';
fs.mkdirSync(tmp,{recursive:true});
for (let i=0;i<N;i++){ await pg.evaluate(t=>window.__frame(t), 26.4+i/30); await pg.screenshot({path:`${tmp}/f${i}.png`}); }
console.log(`three.js: ${N} frames incl. screenshot in ${((Date.now()-t0)/1000).toFixed(2)} s = ${((Date.now()-t0)/N/1000).toFixed(3)} s/frame`);
await br.close();
