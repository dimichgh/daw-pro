// ROUND 34 — OCCLUSION, MEASURED. What fraction of another road's own visible
// light is HIDDEN by rod geometry?
//
// ⛔ NOT A DIFF OF LIT FRAMES. A rod that emits throws light on the paper for
// metres around; differencing lit scenes would score that as "occlusion" when
// it is the opposite. So the rod is rendered PURE BLACK, throwing no light
// (`rods.occlBlack`), and what it changes is geometry blocking geometry.
//
// Per (variant, t, other road N), four renders, all identical but for two flags:
//   A  = onlyRoad N, rods OFF          B  = onlyRoad N, rods BLACK
//   A0 = onlyRoad -1 (no voices), rods OFF   B0 = onlyRoad -1, rods BLACK
// M  = pixels where |A-A0|  > THRESH   -> road N's own light, alone
// M' = pixels where |B-B0| > THRESH    -> the same, with the rods in the way
// occluded = |M and not M'| / |M|
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path'; import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const PY = '/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python';
const BASE = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const TMP = process.argv[3];
fs.mkdirSync(TMP, { recursive: true });
const VAR = JSON.parse(fs.readFileSync(path.join(HERE, '_rods.variants.json'), 'utf8'));
if (process.env.PLANT) VAR['PLANT-fat-rod-positive-control'] =
  { ...VAR['V1-bass-thin-tall-lit-not-emitting'], r: Number(process.env.PLANT), h: 2.5 };
const TS = (process.env.RODTS ? process.env.RODTS.split(',') : ['31', '101', '129']).map(Number);
const THRESH = Number(process.env.OCCTHRESH ?? 6);
const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const rows = [];
for (const [name, rods] of Object.entries(VAR)) {
  if (!rods) continue;
  if (process.env.ONLYPLANT && !name.startsWith('PLANT')) continue;
  const P = JSON.parse(JSON.stringify(BASE));
  P.look.rods = { ...rods, occlBlack: true };
  const pg = await br.newPage();
  await pg.setViewport({ width: P.width, height: P.height });
  await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
  await pg.evaluate(p => window.__init(p), P);
  await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
  const others = P.roads.map(r => r.index).filter(i => !(rods.roads ?? []).includes(i));
  for (const t of TS) for (const N of others) {
    const shot = async (only, off, tag) => {
      await pg.evaluate((o, rd, tt) => { window.__setLook({ onlyRoad: o, rods: rd }); window.__frame(tt); },
                        only, { ...rods, occlBlack: true, off }, t);
      const f = path.join(TMP, `${tag}.png`); await pg.screenshot({ path: f }); return f;
    };
    const A = await shot(N, true, 'A'), A0 = await shot(-1, true, 'A0');
    const B = await shot(N, false, 'B'), B0 = await shot(-1, false, 'B0');
    const out = execFileSync(PY, ['-c', `
import sys, json, numpy as np
from PIL import Image
def a(p): return np.asarray(Image.open(p).convert("RGB"), dtype=np.int16)
A,A0,B,B0 = [a(p) for p in sys.argv[1:5]]
th = int(sys.argv[5])
M  = (np.abs(A - A0).max(axis=2) > th)
Mp = (np.abs(B - B0).max(axis=2) > th)
hid = int((M & ~Mp).sum()); tot = int(M.sum())
# ⚠ TWO DENOMINATORS, ON PURPOSE. "everything this road puts on the screen"
# is dominated by the soft POOL its lamp throws on the paper -- over half the
# frame -- and a thin rod covering a bright playhead scores ~0 against it.
# The brief asks about PLAYHEAD AND TRAIL pixels, so the second mask keeps only
# the road's own contribution where the image is actually BRIGHT (luma >= 200).
L = A.mean(axis=2)
Mb = M & (L >= 200)
hidb = int((Mb & ~Mp).sum()); totb = int(Mb.sum())
print(json.dumps({"visible": tot, "hidden": hid, "frac": (hid / tot) if tot else None,
                  "visibleBright": totb, "hiddenBright": hidb,
                  "fracBright": (hidb / totb) if totb else None}))
`, A, A0, B, B0, String(THRESH)]).toString();
    const r = JSON.parse(out);
    rows.push({ name, t, road: N, ...r });
    console.log(`${name.padEnd(36)} t=${String(t).padEnd(4)} road ${N} ` +
      `${String(P.roads[N].name).padEnd(7)} visible=${String(r.visible).padStart(7)} ` +
      `hidden=${String(r.hidden).padStart(7)}  occluded=` +
      (r.frac == null ? 'n/a' : (100 * r.frac).toFixed(2) + ' %') +
      `   bright=${String(r.visibleBright).padStart(6)} hidden=${String(r.hiddenBright).padStart(6)} ` +
      `occludedBright=` + (r.fracBright == null ? 'n/a (no bright pixels)' : (100 * r.fracBright).toFixed(2) + ' %'));
  }
  await pg.close();
}
fs.writeFileSync(path.join(TMP, 'occlusion.json'), JSON.stringify(rows, null, 1));
await br.close();
