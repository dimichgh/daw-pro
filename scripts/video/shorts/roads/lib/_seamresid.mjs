// ⭐ WHY DOES (S2) FAIL ON ONE PAYLOAD AND PASS ON ANOTHER? Prints the RESIDUAL
// between the gate's float64 derivation and the mesh's own report, per boundary,
// next to the float32 quantum at that magnitude. Read-only; changes no gate.
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path'; import { fileURLToPath } from 'url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const repV = P.paperRepeatV;
const PH = P.zlen + 2 * (P.look?.sheetPad ?? 7.0);
const zmid0 = (P.zNear + P.zFar) / 2;
const zOfV = v => zmid0 + PH / 2 - v * PH;
const b = await puppeteer.launch({ headless: 'shell', args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await b.newPage();
await pg.setViewport({ width: P.width, height: P.height, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
const info = await pg.evaluate(() => window.__paperBounds());
// is the geometry float32? ask the page directly
const kind = await pg.evaluate(() => {
  const g = document.__nothing; return null; });
console.log(`payload ${path.basename(path.dirname(process.argv[2]))}  PH ${PH.toFixed(3)}  repeat ${repV.toFixed(4)}  boundaries ${info.bounds.length}`);
let worst = 0;
for (let i = 0; i < info.bounds.length; i++) {
  const d = zOfV((i + 1) / repV), got = info.bounds[i].z, r = Math.abs(got - d);
  worst = Math.max(worst, r);
  const q = Math.pow(2, Math.ceil(Math.log2(Math.abs(PH / 2))) - 24);   // float32 ulp at |ly|~PH/2
  console.log(`  b${i}  derived ${d.toFixed(9)}  mesh ${got.toFixed(9)}  residual ${r.toExponential(3)}  (float32 ulp at PH/2 ~ ${q.toExponential(2)})`);
}
console.log(`  WORST RESIDUAL ${worst.toExponential(3)}   gate tolerance 1e-6   -> ${worst > 1e-6 ? 'FAILS' : 'passes'}`);
await b.close();
