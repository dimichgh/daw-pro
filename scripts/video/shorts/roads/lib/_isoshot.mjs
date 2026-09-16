import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path'; import { fileURLToPath } from 'url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const t = Number(process.argv[3]), out = process.argv[4];
if (process.argv.includes('--control')) P.look.paperSeamControl = 26;
if (process.env.ISO_AMB) P.look.paperOnlyAmbient = Number(process.env.ISO_AMB);
const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await b.newPage();
await pg.setViewport({ width: P.width, height: P.height, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
await pg.evaluate(() => { window.__paperIso = true; });
await pg.evaluate(tt => window.__frame(tt), t);
await pg.screenshot({ path: out });
await b.close(); console.log(out, await Promise.resolve(''));
