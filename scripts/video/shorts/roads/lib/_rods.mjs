// ROUND 34: shoot the rod variants. One browser, one page per variant payload,
// three stills each at the same three instants. usage:
//   node lib/_rods.mjs <payload> <outdir> [--strip <variant>]
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path'; import { fileURLToPath } from 'url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const BASE = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const OUT = process.argv[3];
fs.mkdirSync(OUT, { recursive: true });
export const VARIANTS = JSON.parse(fs.readFileSync(path.join(HERE, '_rods.variants.json'), 'utf8'));
const TS = (process.env.RODTS ? process.env.RODTS.split(",").map(Number) : [31.0, 101.0, 129.0, 131.0]);
const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
for (const [name, rods] of Object.entries(VARIANTS)) {
  if (process.env.ONLYVAR && !name.startsWith(process.env.ONLYVAR)) continue;
  const P = JSON.parse(JSON.stringify(BASE));
  if (rods) P.look.rods = rods;
  const pg = await br.newPage();
  await pg.setViewport({ width: P.width ?? 1920, height: P.height ?? 1080 });
  await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
  await pg.evaluate(p => window.__init(p), P);
  await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
  const e = await pg.evaluate(() => window.__err || null);
  if (e) { console.log('[BROKEN] ' + name + ': ' + e); process.exit(2); }
  for (const t of TS) {
    await pg.evaluate(tt => window.__frame(tt), t);
    const f = path.join(OUT, `${name}-t${t}.png`);
    await pg.screenshot({ path: f });
    const rs = await pg.evaluate(() => (window.__rodScreen ? window.__rodScreen() : []));
    const shown = await pg.evaluate(() => window.__rodsShown ?? 0);
    const ovf = await pg.evaluate(() => window.__rodOverflow ?? 0);
    console.log(`${name} t=${t}  rodsShown=${shown} overflow=${ovf}  ` +
      rs.map(r => `[road${r.road} z=${r.z.toFixed(1)} h=${r.h.toFixed(3)} sx=${r.sx.toFixed(0)} ` +
                  `frac=${r.frac.toFixed(3)} on=${r.onScreen}]`).join(' '));
  }
  await pg.close();
}
await br.close();
