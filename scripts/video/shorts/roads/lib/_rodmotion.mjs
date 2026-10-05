// ROUND 35 — ON-SCREEN LIFE, measured frame by frame over the SAME window the
// clips were rendered from. For each variant: step t at 30 fps, and for every
// note that is born inside the window record how many consecutive frames its
// rod (or bar) is both VISIBLE and projecting INSIDE the frame.
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path'; import { fileURLToPath } from 'url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const BASE = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const VAR = JSON.parse(fs.readFileSync(path.join(HERE, '_rods.variants.json'), 'utf8'));
const START = Number(process.env.START ?? 96), SECS = Number(process.env.SECS ?? 18);
const names = (process.env.VARIANTS || 'V1-bass-thin-tall-lit-not-emitting,V4-bass-height-from-duration,V8-standing-ahead-at-V5-colour,V9-horizontal-duration-bar').split(',');
const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
for (const name of names) {
  const rods = VAR[name]; if (!rods) { console.log(name + ': no such variant'); continue; }
  const P = JSON.parse(JSON.stringify(BASE)); P.look.rods = rods;
  const pg = await br.newPage();
  await pg.setViewport({ width: P.width, height: P.height });
  await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
  await pg.evaluate(p => window.__init(p), P);
  await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
  const seen = new Map();          // key: rounded anchor z -> {frames, onFrames, first, last}
  let anyVisible = 0;
  for (let i = 0; i < Math.round(SECS * 30); i++) {
    const t = START + i / 30;
    await pg.evaluate(tt => window.__frame(tt), t);
    const rs = await pg.evaluate(() => window.__rodScreen());
    if (rs.length) anyVisible++;
    for (const r of rs) {
      const k = r.z.toFixed(2);
      let e = seen.get(k);
      if (!e) { e = { frames: 0, on: 0, first: t, last: t, maxLen: 0 }; seen.set(k, e); }
      e.frames++; e.last = t;
      if (r.onScreen && r.sx >= 0 && r.sx <= P.width) e.on++;
      if (r.len != null) e.maxLen = Math.max(e.maxLen, r.len);
    }
  }
  const rows = [...seen.entries()].sort((a, b) => Number(b[0]) - Number(a[0]));
  const inWin = rows.filter(([, e]) => e.first > START + 0.05);
  const mean = a => a.length ? a.reduce((x, y) => x + y, 0) / a.length : 0;
  console.log(`\n${name}`);
  console.log(`  rods/bars that appear at all: ${rows.length}  (born inside the window: ${inWin.length})`);
  console.log(`  frames with anything visible: ${anyVisible}/${Math.round(SECS * 30)}`);
  for (const [z, e] of rows.slice(0, 12))
    console.log(`   z=${String(z).padStart(8)}  visible ${(e.frames/30).toFixed(2)}s  ` +
      `ON SCREEN ${(e.on/30).toFixed(2)}s  t ${e.first.toFixed(2)}..${e.last.toFixed(2)}` +
      (e.maxLen ? `  maxLen ${e.maxLen.toFixed(1)} units = ${(e.maxLen/P.zps).toFixed(2)}s of road` : ''));
  console.log(`  MEAN on-screen life (born in window): ${(mean(inWin.map(([, e]) => e.on)) / 30).toFixed(2)} s`);
  await pg.close();
}
await br.close();
