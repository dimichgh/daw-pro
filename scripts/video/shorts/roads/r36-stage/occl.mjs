// ROUND 36 — OCCLUSION ACROSS A FULL ORBIT.
//
// ⛔ THE ROAD'S ~0 % NUMBERS DO NOT TRANSFER. Every occlusion figure round 34
// measured was taken from behind, down parallel lanes: nothing was ever in
// front of anything. Orbit a stage and the front row hides the back row at some
// azimuths by construction, so the question "is this layout legible from every
// side" is a number, and this is the tool that produces it.
//
// METHOD, same shape as lib/_occl.mjs, for the same reason: the occluders are
// rendered PURE BLACK and throw no light, so what is measured is GEOMETRY
// BLOCKING GEOMETRY and never one lamp washing out another.
//   A  = station i alone, no occluders        A0 = nothing, no occluders
//   B  = station i alone, others BLACK        B0 = nothing, others BLACK
//   M  = |A-A0| > th        (what i puts on the screen)
//   M' = |B-B0| > th        (what survives the other stations being there)
//   occluded = |M & ~M'| / |M|,  and the same restricted to BRIGHT pixels.
//
// ⚠ MEASURED WITH EVERY ROD FORCED UP (`allUp`). At a real instant only the
// sounding rods are standing, so a per-instant table scores the ARRANGEMENT,
// not the layout. The real-instant table is the secondary result, further down.
import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
import { execFileSync } from 'node:child_process';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const PY = '/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python';
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const TMP = process.argv[3] || path.join(HERE, 'measure', 'occl-tmp');
fs.mkdirSync(TMP, { recursive: true });
const TH = Number(process.env.OCCTHRESH ?? 6);
const AZSTEP = Number(process.env.AZSTEP ?? 15);
const ELS = (process.env.ELS || '24').split(',').map(Number);
const AZS = [];
for (let a = 0; a < 360; a += AZSTEP) AZS.push(a);
const RS = { 6: 9.6, 24: 13.5, 60: 15.5 };
const PLANT = process.env.PLANT ? JSON.parse(process.env.PLANT) : null;
const TAT = Number(process.env.TAT ?? -1);          // >=0 -> a REAL instant, rods not forced

const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await br.newPage();
await pg.setViewport({ width: P.width, height: P.height });
await pg.goto('file://' + path.join(HERE, 'stage.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
const err = await pg.evaluate(() => window.__err || null);
if (err) { console.error('INIT FAILED:', err); process.exit(2); }

const N = P.instruments.length;
const all = [...Array(N).keys()];
const rows = [];
const t = TAT >= 0 ? TAT : 5.0;

async function shot(show, black, az, el, tag) {
  await pg.evaluate((s, b, a, e, r, up, pl, tt) => {
    window.__setDbg({ show: s, black: b, allUp: up, plant: pl });
    window.__setCam({ az: a, el: e, r });
    window.__frame(tt);
    // ⚠ THE PLANT BELONGS TO THE OCCLUDER SET ONLY. Put it in A/A0 as well and
    // it blocks the same pixels in both, they cancel out of M, and the control
    // reads 0.00 % — a positive control that cannot fire is worse than none.
  }, show, black, az, el, RS[el] ?? 13.5, TAT < 0, black ? PLANT : null, t);
  // ⚠ READ __err EVERY CELL. A frame that throws half way through leaves the
  // PREVIOUS render on the canvas, screenshots fine, and scores as a colossal
  // occlusion. That is exactly how this probe first reported 100 %.
  const e = await pg.evaluate(() => { const x = window.__err || null; window.__err = null; return x; });
  if (e) { console.error('FRAME ERROR', tag, az, el, ':', e); process.exit(2); }
  const f = path.join(TMP, tag + '.png');
  await pg.screenshot({ path: f });
  return f;
}

for (const el of ELS) for (const az of AZS) for (const i of all) {
  const others = [...all.filter(j => j !== i), -1];   // -1 = the kit, also an occluder
  const A  = await shot([i], null,   az, el, 'A');
  const A0 = await shot([],  null,   az, el, 'A0');
  const B  = await shot([i], others, az, el, 'B');
  const B0 = await shot([],  others, az, el, 'B0');
  const out = execFileSync(PY, ['-c', `
import sys, json, numpy as np
from PIL import Image
def a(p): return np.asarray(Image.open(p).convert("RGB"), dtype=np.int16)
A,A0,B,B0 = [a(p) for p in sys.argv[1:5]]
th = int(sys.argv[5])
M  = (np.abs(A - A0).max(axis=2) > th)
Mp = (np.abs(B - B0).max(axis=2) > th)
# ⚠ MAX CHANNEL, NOT MEAN. A saturated coloured beam (#FF707C) has a mean of
# 164 and would never enter a mean-based "bright" mask at all — the bass read
# n/a for every cell of the first sweep for exactly that reason.
L  = A.max(axis=2)
Mb = M & (L >= 200)
print(json.dumps({"vis": int(M.sum()), "hid": int((M & ~Mp).sum()),
                  "visB": int(Mb.sum()), "hidB": int((Mb & ~Mp).sum())}))
`, A, A0, B, B0, String(TH)]).toString();
  const r = JSON.parse(out);
  const frac  = r.vis  ? r.hid  / r.vis  : null;
  const fracB = r.visB ? r.hidB / r.visB : null;
  rows.push({ el, az, i, name: P.instruments[i].name, ...r, frac, fracB });
  console.log(`el=${String(el).padStart(2)} az=${String(az).padStart(3)} ` +
    `${P.instruments[i].name.padEnd(8)} vis=${String(r.vis).padStart(7)} ` +
    `occluded=${frac == null ? 'n/a' : (100 * frac).toFixed(2).padStart(6) + ' %'}   ` +
    `bright vis=${String(r.visB).padStart(6)} occludedBright=` +
    (fracB == null ? 'n/a' : (100 * fracB).toFixed(2).padStart(6) + ' %'));
}
await br.close();
const outFile = process.env.OUTJSON || path.join(TMP, 'occlusion.json');
fs.writeFileSync(outFile, JSON.stringify(rows, null, 1));
console.log('wrote ' + outFile + '  rows=' + rows.length);
