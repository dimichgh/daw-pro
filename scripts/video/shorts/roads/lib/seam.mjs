#!/usr/bin/env node
// ⛔ (S) A TILE BOUNDARY MUST BE INVISIBLE.
//
// The paper map no longer spans the whole road. It is a bounded tile of
// `paperTileH` rows wrapped `paperRepeatV` times down the sheet (see the long
// note in lib/prep.mjs), because one texture for a 60-90 s film wants ~50,000
// rows against a measured 16384 GPU limit. That buys the scaling wall — and it
// buys a NEW failure mode this gate exists to rule out: a visible step, line or
// discontinuity at each wrap.
//
// ⭐ THE ARGUMENT FOR WHY IT CANNOT STEP IS STRUCTURAL, and this gate is the
// experiment that could falsify it. The map has been CONTENT-FREE since round 5
// -- flat fill plus isotropic grain; every staff line, notehead, label and bar
// line is real geometry in the balls' own frame. So the two sides of a wrap are
// two draws from the SAME distribution about the SAME mean, exactly like any
// other pair of adjacent rows. There is no content to mis-register.
//
// ⚠⚠ THE MEASUREMENT MUST NOT BE "IS THERE A BRIGHTNESS DIFFERENCE ACROSS THE
// BOUNDARY". There always is: the road is lit by a point light with falloff and
// fog, so brightness changes with z EVERYWHERE. A naive across-the-join
// difference would fire on a perfect film and could be made to pass only by
// loosening it until it fired on nothing.
// ⭐ SO THE COMPARISON IS AGAINST THE SAME MEASUREMENT MADE OFF THE JOIN. For
// every boundary this samples a pair of patches straddling it at +-DZ, and then
// the SAME +-DZ pair centred at several NEARBY z values that contain no
// boundary. The seam step must not exceed REL x the median off-join step. That
// is a scale-free comparison: it needs no luma constant, and it survives any
// camera, exposure or lighting change.
//
// CONTROL: --control sets look.paperSeamControl, which darkens the last rows of
// the TILE so every wrap carries a deliberate mean step. It must fail.
//
// BROKEN (exit 2), never a pass: a payload that does not wrap (paperRepeatV <= 1
// has no boundary to look at -- the tuning sample is exactly this case, which is
// why the wrap is proven on a payload that needs it), or too few boundary
// samples that land on lit road in frame.
//
// Usage: node seam.mjs <payload.json> [--control] [--seam <luma>]
import puppeteer from 'puppeteer';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';

const __GATE = new URL(import.meta.url).pathname.split('/').pop();
const __broke = e => {
  console.error(`  [BROKEN] ${__GATE} crashed before it could measure a thing: ${(e && e.message) || e}`);
  console.error(`  [BROKEN] this is NOT a failed assertion — the gate has NO VERDICT here.`);
  process.exit(2);
};
process.on('uncaughtException', __broke);
process.on('unhandledRejection', __broke);

const HERE = path.dirname(new URL(import.meta.url).pathname);
const PY = process.env.ROADS_PY
  || '/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python';
const CONTROL = process.argv.includes('--control');
const SEAMV = Number(process.env.SEAM_CONTROL_LUMA ?? 26);
const REL = Number(process.env.SEAM_REL ?? 3.0);   // x the off-join step
const PXD = Number(process.env.SEAM_PXD ?? 9);      // SCREEN PIXELS either side of the join
const RPX = 5;                                     // patch half-size, pixels

const P = JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), 'utf8'));
const repV = P.paperRepeatV ?? 1;
if (!(repV > 1)) {
  console.error(`  [BROKEN] this payload does not wrap: paperRepeatV = ${repV}.`);
  console.error(`  [BROKEN] texture ${P.texW}x${P.texH}, tile ${P.texW}x${P.paperTileH ?? P.texH}.`);
  console.error(`  [BROKEN] There is no tile boundary in this film, so (S) has NO VERDICT here.`);
  console.error(`  [BROKEN] Run it on a payload long enough to wrap — that is the point of the gate.`);
  process.exit(2);
}
if (CONTROL) { P.look = { ...(P.look || {}), paperSeamControl: SEAMV }; }

// the plane: PlaneGeometry(PW, PH) with uv.y 0..1 over local y -PH/2..PH/2,
// rotated -90deg about X (local +y -> world -z), centred at zmid0. So
//   world z(v) = zmid0 + PH/2 - v*PH
const PH = P.zlen + 2 * (P.look?.sheetPad ?? 7.0);
const zmid0 = (P.zNear + P.zFar) / 2;
const zOfV = v => zmid0 + PH / 2 - v * PH;
const bounds = [];
for (let k = 1; k < Math.ceil(repV); k++) bounds.push({ k, v: k / repV, z: zOfV(k / repV) });
console.log(`\nSEAM (S) — the tile boundary must be invisible`);
console.log(`  texture ${P.texW}x${P.texH} -> tile ${P.texW}x${P.paperTileH} wrapped ${repV.toFixed(3)}x`);
console.log(`  ${bounds.length} wrap boundar${bounds.length === 1 ? 'y' : 'ies'} at world z ` +
            bounds.map(b => b.z.toFixed(2)).join(', '));
if (CONTROL) console.log(`  ⚠ CONTROL: paperSeamControl=${SEAMV} — every boundary is deliberately stepped`);

const W = P.width, H = P.height;
const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await b.newPage();
await pg.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
const e0 = await pg.evaluate(() => window.__err);
if (e0) { console.error('PAGE ERROR:', e0); await b.close(); process.exit(2); }

// ────────────────────────────────────────────────────────────────────────────
// (S2) THE WRAP IS ACTUALLY APPLIED, AND BOUNDED. Read off the built mesh and
// the built texture, never re-derived here — the page reports what it made.
const info = await pg.evaluate(() => window.__paperBounds());
console.log(`  (S2) mesh reports tile ${info.texW}x${info.texH}, wrapT repeat ${info.repeat.toFixed(3)}x, ` +
            `${info.bounds.length} boundaries at z ` + info.bounds.map(q => q.z.toFixed(2)).join(', '));
{
  const bad = [];
  if (info.texH !== (P.paperTileH ?? P.texH)) bad.push(`texture height ${info.texH} != payload paperTileH ${P.paperTileH}`);
  if (info.texH > 12288) bad.push(`tile ${info.texH} rows exceeds the 12288 cap`);
  if (Math.abs(info.repeat - repV) > 1e-9) bad.push(`repeat ${info.repeat} != payload paperRepeatV ${repV}`);
  if (info.bounds.length !== bounds.length) bad.push(`mesh sees ${info.bounds.length} boundaries, this gate derived ${bounds.length}`);
  // ⛔⛔ THE TOLERANCE IS DERIVED FROM float32, NOT TYPED — AND THE 1e-6 IT
  // REPLACES PASSED THIS FILE'S OWN APPROVED FILM BY LUCK. `__paperBounds()`
  // reads `geometry.attributes.position`, which is a Float32Array; this side
  // derives the same z in float64. The residual is therefore float32
  // quantisation of a quantity of magnitude PH/2, and it GROWS with the road.
  // MEASURED with lib/_seamresid.mjs on two real payloads:
  //   03-moonlight-long  zlen 227.0  PH 241.0 (an EXACT integer, so PH/2 =
  //                      120.5 is exactly representable) -> worst residual
  //                      7.07e-8, 14x under the old 1e-6
  //   06-bach-prelude    zlen 254.7  PH 268.7  PH/2 = 134.35, NOT exactly
  //                      representable -> worst residual 2.95e-6, which the old
  //                      tolerance called a FAILED SEAM. It is 5x UNDER the
  //                      float32 ulp at that magnitude (1.53e-5).
  // So the old constant sat BELOW the noise floor of the thing it compares and
  // only ever passed because one film's paper length happened to be integral.
  // ⭐ THE CONTROL IS UNTOUCHED AND STILL FIRES: `--control` steps every
  // boundary in the TEXTURE and is caught by (S1)'s pixel test, which this
  // number does not reach. A tolerance that cannot be shown to still fail is a
  // tolerance that has been tuned for green; this one can.
  const Z_TOL = Math.max(1e-6, 8 * Math.pow(2, -23) * Math.abs(PH));
  for (let i = 0; i < Math.min(info.bounds.length, bounds.length); i++)
    if (Math.abs(info.bounds[i].z - bounds[i].z) > Z_TOL)
      bad.push(`boundary ${i} at ${info.bounds[i].z} vs derived ${bounds[i].z} `
               + `(residual ${Math.abs(info.bounds[i].z - bounds[i].z).toExponential(2)} > tol ${Z_TOL.toExponential(2)})`);
  if (bad.length) { console.log(`  [ FAIL ] (S2) ` + bad.join('; ')); await b.close(); process.exit(1); }
  console.log(`  [ ok ] (S2) the tile is bounded at ${info.texH} rows and wrapped ${info.repeat.toFixed(3)}x — ` +
              `it does NOT grow with the film`);
}

// ────────────────────────────────────────────────────────────────────────────
// ⭐⭐ (S1) IS THE ASSERTION THAT CARRIES THE CLAIM, and it is measured on the
// MAP, not on a photograph of the road. "The join is invisible" is a statement
// about the texture: the two sides of a wrap are the tile's LAST rows and its
// FIRST rows. Measured there it needs no camera, no lighting model, no fog and
// nothing subtracted for the ink lying on top — and the scale it is compared
// against is the tile's OWN interior block-to-block variation, so there is no
// luma constant to tune.
{
  const N = Number(process.env.SEAM_ROWS ?? 64);
  const st = await pg.evaluate(n => window.__paperRowStats(n), N);
  const rel = st.innerMedian > 1e-9 ? st.join / st.innerMedian : Infinity;
  console.log(`\n  (S1) tile ${st.tileH} rows; mean luma of the first ${st.rows} rows ${st.first.toFixed(4)}, ` +
              `of the last ${st.rows} ${st.last.toFixed(4)}`);
  console.log(`       join difference ${st.join.toFixed(4)} luma   |   the tile's own interior block-to-block ` +
              `difference: median ${st.innerMedian.toFixed(4)}, max ${st.innerMax.toFixed(4)}`);
  // ⚠⚠ A RATIO OF TWO SUB-QUANTUM NUMBERS IS NOT A MEASUREMENT. Both sides of
  // this comparison are hundredths of a luma unit on a fill of ~184 — the 8-bit
  // LSB is 1.0, so NEITHER is renderable. On the 8-bar payload the join read
  // 0.0132 against an interior median of 0.0058 and the ratio came out 2.29x,
  // which looks like a near-miss and is nothing of the kind. So the ratio test is
  // paired with an ABSOLUTE floor: a join difference under 0.25 luma is under a
  // QUARTER of the smallest difference the frame buffer can even hold, and cannot
  // be a visible seam whatever it is a multiple of.
  // ⚠ It is not a loosening: the control reads 25.99 luma / 4507x and fails both
  // clauses by orders of magnitude.
  const ABS = Number(process.env.SEAM_ABS ?? 0.25);
  console.log(`       ratio ${rel.toFixed(2)}x (limit ${REL.toFixed(1)}x, or a join under ${ABS} luma — ` +
              `a quarter of the 8-bit LSB — which cannot be rendered at all)`);
  if (!(rel <= REL || st.join < ABS)) {
    console.log(`  [ FAIL ] (S1) the map STEPS across the wrap: the join differs ${rel.toFixed(2)}x more than ` +
                `two ordinary blocks of the same tile do`);
    await b.close(); process.exit(1);
  }
  console.log(`  [ ok ] (S1) the map is continuous across the wrap — the join is indistinguishable from any ` +
              `other pair of row blocks in the tile (carried by ` +
              `${rel <= REL ? 'the ratio test' : 'the sub-LSB floor'})`);
}

// ────────────────────────────────────────────────────────────────────────────
// ⭐⭐ (S3) IS NOW AN ASSERTION, ON PIXELS — the thing the brief asked for by
// name. It was a diagnostic for two cuts because its control would not separate:
// photographing the FULL FILM, the 20-bar payload read film median 1.13x against
// the deliberately-stepped control's 1.73x. The road carries staff lines,
// noteheads, a moving key light and fog, and those swamp the map's contribution
// at the scale a boundary occupies.
// ⭐ WHAT FIXED IT WAS REMOVING EVERYTHING THAT IS NOT THE MAP. window.__paperIso
// renders the paper plane alone, flat ambient, no fog, no bloom, no sheet
// geometry. MEASURED on the 8-bar Moonlight payload, isolated:
//        film     worst 1.65x   median 0.81x
//        control  worst 455.33x median 31.31x     (paperSeamControl=26)
// — a 38x separation on the medians, against 1.5x for the same probe on the full
// film. The limit below sits between them with room on both sides.
// ⚠ (S1) still carries the map-side claim and is not redundant: it needs no
// camera at all, so it holds on payloads where every boundary lands somewhere
// unphotographable.
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'seam-'));
const lumAt = (file, pts, r) => JSON.parse(execFileSync(PY, ['-c', `
import sys, json
from PIL import Image
import numpy as np
a = np.asarray(Image.open(sys.argv[1]).convert("RGB"), dtype=float)
L = 0.299*a[:,:,0] + 0.587*a[:,:,1] + 0.114*a[:,:,2]
pts = json.loads(sys.argv[2]); r = int(sys.argv[3])
out = []
for x, y in pts:
    x = int(round(x)); y = int(round(y))
    p = L[max(0,y-r):y+r+1, max(0,x-r):x+r+1]
    out.append(float(p.mean()) if p.size else None)
print(json.dumps(out))
`, file, JSON.stringify(pts), String(r)], { encoding: 'utf8' }));

// ⚠ SAMPLE ON THE ROAD, NOT AT x=0. x=0 can fall between two road bands on a
// layout that is not centred; the lateral positions come from the roads the
// payload actually declares.
const xs = (P.roads || []).map(r => r.x0);

// ⛔⛔ THE FIRST VERSION OF THIS GATE SAMPLED EVERY BOUNDARY AT SIX EVENLY SPACED
// TIMES, AND IT WAS USELESS — measured, not suspected: the film and the
// --control run were INDISTINGUISHABLE (worst ratio Infinity in both, the same
// 0.65-luma "step" to three decimals). The road IS a timeline and the camera
// rides the playhead, so a boundary 60 units up the road sits in deep fog at
// almost every time. Every sample landed on near-black, where an 8-bit luma
// difference of 0.6 is compared against an off-join reference that quantises to
// 0.000 — Infinity out of two numbers that are both noise.
// ⭐ A CONTROL THAT CANNOT SEPARATE THE FIXED FILM FROM THE BROKEN ONE IS THE
// GATE FAILING, NOT THE FILM PASSING. What exposed it: cranking the control to
// 6000 rows and OPENING THE FRAME. The dark band was there the whole time, far
// up the road where nothing this gate did could reach it.
// ⭐⭐ SO EACH BOUNDARY IS SAMPLED WHEN THE CAMERA IS ON IT: z = -t*zps, so the
// boundary at z_b is under the lens at t = -z_b/zps. A boundary past the end of
// the film is UNREACHABLE and is reported as such, never silently dropped.
const zps = P.zps;
const TT = P.total ?? 12;
const rows = [], broken = [];
const shots = [];
for (const bd of bounds) {
  const tb = -bd.z / zps;
  if (tb < 0.4 || tb > TT - 0.4) {
    broken.push(`boundary k=${bd.k} at z=${bd.z.toFixed(2)} would be under the camera at ` +
      `t=${tb.toFixed(2)}, outside the film [0.4, ${(TT - 0.4).toFixed(2)}] — unreachable`);
    continue;
  }
  for (const dt of [-1.2, 0, 1.2]) {
    const t = tb + dt;
    if (t > 0.3 && t < TT - 0.3) shots.push({ t, bd });
  }
}
console.log(`  ${shots.length} camera-on-the-boundary samples from ${bounds.length} boundaries`);

// ⭐ ISOLATION. The first two cuts of (S3) photographed the FILM — staff lines,
// noteheads, moving key light and fog — and the map's contribution at a boundary
// was a small term inside all of that. window.__paperIso strips the frame down to
// the paper map under flat ambient with no fog, which is the only channel a wrap
// can reach the picture through. Set SEAM_ISO=0 to photograph the full film
// instead (that is the mode whose control did NOT separate).
const ISO = process.env.SEAM_ISO !== '0';
if (ISO) await pg.evaluate(() => { window.__paperIso = true; });
console.log(`  (S3) frames are ${ISO ? 'PAPER-ISOLATED (map only, flat light, no fog)' : 'the full film'}`);

for (const [ti, sh] of shots.entries()) {
  const t = sh.t, bd = sh.bd;
  await pg.evaluate(tt => window.__frame(tt), t);
  const f = path.join(work, `f${ti}.png`);
  await pg.screenshot({ path: f });
  {
    for (const x of xs) {
      // ⛔⛔ AND THE SECOND CUT WAS WRONG TOO, IN THE OPPOSITE DIRECTION: with
      // the separation measured in WORLD units the CONTROL PASSED WHILE THE FILM
      // FAILED — the verdicts came out inverted. The road is seen almost edge-on,
      // so 0.1 world units is a handful of pixels far away and a large fraction
      // of the frame near the lens. The off-join reference pairs, spread over
      // +-0.6 world units, therefore straddled a huge lighting gradient and read
      // 8.2 luma, which swamped a genuine 17-luma control step down to 2.1x.
      // ⭐⭐ SO THE SEPARATION IS IN SCREEN PIXELS, ALONG THE ROAD'S OWN PROJECTED
      // DIRECTION. That is the only frame in which "next to the join" means the
      // same thing near and far, and it is what makes the film/control comparison
      // an apples-to-apples one.
      const p0 = await pg.evaluate((xx, zz) => window.__project(xx, 0.02, zz), x, bd.z);
      const p1 = await pg.evaluate((xx, zz) => window.__project(xx, 0.02, zz), x, bd.z - 0.5);
      if (p0.behind || p1.behind) { broken.push(`t=${t.toFixed(2)} x=${x} k=${bd.k}: boundary behind the camera`); continue; }
      const dxp = p1.x - p0.x, dyp = p1.y - p0.y;
      const L = Math.hypot(dxp, dyp);
      // ⚠ A BOUNDARY THAT IS ONLY A FEW PIXELS LONG OVER HALF A WORLD UNIT IS
      // UNRESOLVED — there is no room to put a patch on either side of it, and a
      // measurement there would be an average of both sides. BROKEN, not a pass.
      if (L < 4 * PXD) { broken.push(`t=${t.toFixed(2)} x=${x} k=${bd.k}: 0.5 world units is only ${L.toFixed(1)} px along the road — unresolved`); continue; }
      const ux = dxp / L, uy = dyp / L;                 // one pixel FARTHER along the road
      const at = d => ({ x: p0.x + ux * d, y: p0.y + uy * d });
      const centres = [0, -3 * PXD, -5 * PXD, -7 * PXD, 3 * PXD, 5 * PXD, 7 * PXD];
      const pts = [];
      for (const c of centres) { pts.push(at(c + PXD)); pts.push(at(c - PXD)); }
      if (pts.some(p => p.x < RPX + 2 || p.x > W - RPX - 2 || p.y < RPX + 2 || p.y > H - RPX - 2)) {
        broken.push(`t=${t.toFixed(2)} x=${x} boundary k=${bd.k}: a patch is off-screen`);
        continue;
      }
      const v = lumAt(f, pts.map(p => [p.x, p.y]), RPX);
      if (v.some(q => q == null)) { broken.push(`t=${t.toFixed(2)} x=${x} k=${bd.k}: empty patch`); continue; }
      // ⚠ TOO DARK TO MEASURE IS NOT A PASS. Deep fog and far falloff put the
      // patch on near-black, where every difference quantises to zero and a
      // ratio of two noise figures comes out as Infinity — which is exactly the
      // artifact the first cut of this gate reported as a failure.
      const lo = Math.min(...v);
      if (lo < 25) { broken.push(`t=${t.toFixed(2)} x=${x} k=${bd.k}: patch luma ${lo.toFixed(1)} — too dark to measure (floor 25)`); continue; }
      const step = Math.abs(v[0] - v[1]);
      const off = [];
      for (let i = 1; i < centres.length; i++) off.push(Math.abs(v[2 * i] - v[2 * i + 1]));
      off.sort((a, c) => a - c);
      const ref = off[Math.floor((off.length - 1) / 2)];
      rows.push({ t, x, k: bd.k, step, ref, ratio: ref > 1e-6 ? step / ref : Infinity });
    }
  }
}
await b.close();
fs.rmSync(work, { recursive: true, force: true });

if (rows.length < 6) {
  // ⛔ NOT A PASS. (S3) asserts now, so too few samples means no verdict, not a
  // good one. BROKEN (exit 2) — the same contract every other gate here uses.
  console.log(`  [BROKEN] (S3) only ${rows.length} usable pixel samples — no verdict.`);
  for (const q of broken.slice(0, 6)) console.log(`       ${q}`);
  process.exit(2);
}
rows.sort((a, c) => c.ratio - a.ratio);
console.log(`  ${rows.length} boundary samples on lit road (${broken.length} skipped)`);
for (const r of rows.slice(0, 5))
  console.log(`   t=${r.t.toFixed(2)} x=${r.x.toFixed(2)} k=${r.k}  join step ${r.step.toFixed(3)} luma` +
              `   off-join median ${r.ref.toFixed(3)}   ratio ${r.ratio.toFixed(2)}x`);
const worst = rows[0];
const med = rows.map(r => r.ratio).sort((a, c) => a - c)[Math.floor((rows.length - 1) / 2)];
const PXLIM = Number(process.env.SEAM_PX_RATIO ?? 6.0);
// ⚠ THE SAME SUB-QUANTUM TRAP (S1) HAS, AND THE SAME FIX. On isolated paper the
// off-join reference is often a fraction of an 8-bit LSB (the control rows show
// ref 0.036, and film rows show step 0.093 / ref 0.115) — so a pure ratio can be
// large between two numbers that are both noise, and a 20-bar payload offers 18
// chances at it instead of 7. Paired with an ABSOLUTE floor that sits between the
// largest step the FILM produces (2.36 luma, a near-lens lighting gradient) and
// the smallest the CONTROL produces (13.1): a join step under 5 luma cannot be
// the 26-luma tile offset this gate exists to catch, whatever it is a multiple of.
// ⭐ It does not weaken the control, which fails BOTH clauses everywhere.
const PXABS = Number(process.env.SEAM_PX_ABS ?? 5.0);
console.log(`  (S3) worst ratio ${worst.ratio.toFixed(2)}x, median ${med.toFixed(2)}x   ` +
            `(limit ${PXLIM.toFixed(1)}x on the worst sample, or a join step under ${PXABS} luma; ` +
            `film worst measures 1.65x/1.84x/1.50x at 8/14/20 bars, the stepped control 455x/304x/107x)`);
if (!(worst.ratio <= PXLIM || worst.step < PXABS)) {
  console.log(`  [ FAIL ] (S3) the RENDERED road steps across the wrap at t=${worst.t.toFixed(2)} ` +
              `x=${worst.x.toFixed(2)}: ${worst.step.toFixed(3)} luma across the join against ` +
              `${worst.ref.toFixed(3)} off it — ${worst.ratio.toFixed(2)}x`);
  process.exit(1);
}
console.log(`\n  [ ok ] (S) tile bounded and wrapped (S2), map continuous across every wrap (S1),` +
            ` and the RENDERED pixels show no step at any boundary (S3).`);
