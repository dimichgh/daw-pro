// ROUND 34: how long does a rod anchored at a note's own (x, z) stay in front
// of the camera? Prints depth-along-view and screen position of the anchor for
// a note, sampled through its whole sounding life.
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path'; import { fileURLToPath } from 'url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const ONSETS = process.argv.slice(3).map(Number);
const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await br.newPage();
await pg.setViewport({ width: P.width, height: P.height });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
await pg.evaluate(() => { window.__probeAnchor = function (x, z, y) {
  const THREE = window.__THREE;
  const c = window.__cam();
  const fwd = c.getWorldDirection(new THREE.Vector3());
  const p = new THREE.Vector3(x, y, z);
  const depth = p.clone().sub(c.position).dot(fwd);
  const q = p.clone().project(c);
  return { depth, camZ: c.position.z, camX: c.position.x,
           sx: (q.x + 1) / 2 * 1920, sy: (1 - q.y) / 2 * 1080, behind: q.z >= 1 };
}; });
for (const on of ONSETS) {
  const v = P.voices.find(v => v.notes.some(n => Math.abs(n.t - on) < 1e-6));
  const n = v.notes.find(n => Math.abs(n.t - on) < 1e-6);
  const z = -(n.t * P.zps);
  console.log(`\nnote t=${n.t} dur=${n.dur} x=${n.x} anchor z=${z.toFixed(2)}  road ${v.road}`);
  for (let u = 0; u <= n.dur + 2.6; u += 0.25) {
    const t = n.t + u;
    await pg.evaluate(tt => window.__frame(tt), t);
    const r = await pg.evaluate((x, zz, y) => window.__probeAnchor(x, zz, y), n.x, z, 0.4);
    const pz = -(t * P.zps);
    console.log(`  u=${u.toFixed(2)} t=${t.toFixed(3)}  camZ=${r.camZ.toFixed(2)} ` +
      `playheadZ=${pz.toFixed(2)} camTrail=${(r.camZ - pz).toFixed(2)}  ` +
      `anchorDepth=${r.depth.toFixed(2)}  sx=${r.sx.toFixed(0)} sy=${r.sy.toFixed(0)} ` +
      `${r.behind ? 'BEHIND' : (r.sx < 0 || r.sx > 1920 ? 'off-x' : 'in frame')}`);
  }
}
await br.close();
