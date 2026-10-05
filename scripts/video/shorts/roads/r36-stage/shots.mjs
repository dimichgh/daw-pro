// ROUND 36 — named stills. Camera stated explicitly (az / el / r / fov) so a
// still can be reproduced, and so the orbit can be photographed at 8 azimuths
// with everything else held identical.
import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const OUT = process.argv[3]; fs.mkdirSync(OUT, { recursive: true });
const SHOTS = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await br.newPage();
await pg.setViewport({ width: P.width, height: P.height });
await pg.goto('file://' + path.join(HERE, 'stage.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
const e0 = await pg.evaluate(() => window.__err || null);
if (e0) { console.error('INIT FAILED:', e0); process.exit(2); }
for (const s of SHOTS) {
  await pg.evaluate((c, tt) => { window.__setCam(c); window.__frame(tt); },
    { az: s.az, el: s.el, r: s.r, fov: s.fov ?? 40, tgt: s.tgt ?? [0, 0.9, 0] }, s.t);
  const err = await pg.evaluate(() => { const x = window.__err || null; window.__err = null; return x; });
  if (err) { console.error('FRAME ERROR', s.tag, ':', err); process.exit(2); }
  const f = path.join(OUT, s.tag + '.png');
  await pg.screenshot({ path: f });
  console.log(`${s.tag}  t=${s.t}  az=${s.az} el=${s.el} r=${s.r}`);
}
await br.close();
