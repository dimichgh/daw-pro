// ROUND 37 — shoot the three.js BASELINE stills and dump the RESOLVED scene
// state for the same poses, so Blender can be handed coordinates instead of a
// re-implementation of the envelopes. Baseline + dump come from ONE frame call
// each, so the picture and the JSON cannot describe different instants.
import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const R36 = path.join(HERE, '..', 'r36-stage');
const P = JSON.parse(fs.readFileSync(path.join(R36, 'stage.L2.payload.json'), 'utf8'));
const POSES = JSON.parse(fs.readFileSync(path.join(HERE, 'poses.json'), 'utf8'));
const OUT = path.join(HERE, 'stills'); fs.mkdirSync(OUT, { recursive: true });
const SC = path.join(HERE, 'scene');   fs.mkdirSync(SC, { recursive: true });
const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await br.newPage();
await pg.setViewport({ width: P.width, height: P.height });
await pg.goto('file://' + path.join(R36, 'stage.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
for (const s of POSES) {
  await pg.evaluate((c, tt) => { window.__setCam(c); window.__frame(tt); },
    { az: s.az, el: s.el, r: s.r, fov: s.fov, tgt: s.tgt }, s.t);
  const err = await pg.evaluate(() => { const x = window.__err || null; window.__err = null; return x; });
  if (err) { console.error('FRAME ERROR', s.tag, ':', err); process.exit(2); }
  await pg.screenshot({ path: path.join(OUT, `${s.tag}--threejs.png`) });
  const dump = await pg.evaluate(() => window.__dumpScene());
  const rs = await pg.evaluate(() => window.__rodScreen());
  fs.writeFileSync(path.join(SC, `${s.tag}.json`), JSON.stringify({ pose: s, ...dump, rodScreen: rs }, null, 1));
  console.log(`${s.tag}: rods=${dump.rods.length} rings=${dump.rings.length} kit=${dump.kit.length} ` +
              `cam=(${dump.camera.position.x.toFixed(3)},${dump.camera.position.y.toFixed(3)},${dump.camera.position.z.toFixed(3)}) fovY=${dump.camera.fovDegVertical}`);
}
await br.close();
