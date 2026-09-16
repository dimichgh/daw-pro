// ROUND 34 — COLOUR, MEASURED OFF THE RENDER, not off the requested hex.
// For each variant: isolate the rod's own pixels (rods-on minus rods-off, on an
// onlyRoad=2 frame) and report their mean hue/saturation; then the same for the
// OTHER roads' bright pixels, so "separation" is a number.
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path'; import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const PY = '/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python';
const BASE = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const TMP = process.argv[3]; fs.mkdirSync(TMP, { recursive: true });
const VAR = JSON.parse(fs.readFileSync(path.join(HERE, '_rods.variants.json'), 'utf8'));
const T = Number(process.env.RODT ?? 101);
const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const hue = (a, b, mode) => JSON.parse(execFileSync(PY, ['-c', `
import sys, json, numpy as np
from PIL import Image
import colorsys
on = np.asarray(Image.open(sys.argv[1]).convert("RGB"), dtype=np.int16)
off = np.asarray(Image.open(sys.argv[2]).convert("RGB"), dtype=np.int16)
mode = sys.argv[3]
L = on.mean(axis=2)
m = (np.abs(on-off).max(axis=2) > 8) & (L >= 200) if mode=="diff" else (L >= 200)
n = int(m.sum())
if n == 0: print(json.dumps({"n":0})); raise SystemExit
px = on[m].astype(float)/255.0
hs = np.array([colorsys.rgb_to_hsv(*p) for p in px])
# circular mean of hue
ang = hs[:,0]*2*np.pi
h = (np.arctan2(np.sin(ang).mean(), np.cos(ang).mean())/(2*np.pi)) % 1.0
print(json.dumps({"n": n, "hueDeg": h*360, "sat": float(hs[:,1].mean()),
                  "val": float(hs[:,2].mean()),
                  "satUnclipped": float(hs[hs[:,2]<0.999][:,1].mean()) if (hs[:,2]<0.999).any() else None,
                  "clippedFrac": float((hs[:,2]>=0.999).mean())}))
`, a, b, mode]).toString());
for (const [name, rods] of Object.entries(VAR)) {
  if (!rods) continue;
  const P = JSON.parse(JSON.stringify(BASE)); P.look.rods = rods;
  const pg = await br.newPage();
  await pg.setViewport({ width: P.width, height: P.height });
  await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
  await pg.evaluate(p => window.__init(p), P);
  await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
  const shot = async (only, off, tag) => {
    await pg.evaluate((o, rd, tt) => { window.__setLook({ onlyRoad: o, rods: rd }); window.__frame(tt); },
                      only, { ...rods, off }, T);
    const f = path.join(TMP, `${tag}.png`); await pg.screenshot({ path: f }); return f;
  };
  const rodRoad = (rods.roads ?? [2])[0];
  const on = await shot(rodRoad, false, 'on'), offf = await shot(rodRoad, true, 'off');
  const r = hue(on, offf, 'diff');
  const others = P.roads.map(x => x.index).filter(i => !(rods.roads ?? []).includes(i));
  const os = [];
  for (const N of others) { const f = await shot(N, true, 'o' + N); os.push([N, hue(f, f, 'bright')]); }
  const sep = os.map(([N, o]) => o.n ? `road${N} ${o.hueDeg.toFixed(1)}deg S${(100*o.sat).toFixed(1)}% ` +
      `dHue=${(((r.hueDeg - o.hueDeg + 540) % 360) - 180).toFixed(1)}deg` : `road${N} n/a`).join('  |  ');
  console.log(`${name.padEnd(36)} rod n=${String(r.n).padStart(5)} hue=${r.n ? r.hueDeg.toFixed(1) : '-'}deg ` +
    `S=${r.n ? (100 * r.sat).toFixed(1) : '-'}% (unclipped S=${r.satUnclipped == null ? '-' : (100*r.satUnclipped).toFixed(1)}%, ` +
    `clipped ${r.n ? (100*r.clippedFrac).toFixed(0) : '-'}%)   ${sep}`);
  await pg.close();
}
await br.close();
