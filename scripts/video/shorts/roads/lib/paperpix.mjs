#!/usr/bin/env node
// ⛔⛔⛔ THE GATE THAT LOOKS AT THE PRINTED SHEET — RE-DERIVED FOR ROUND 5.
//
// It asks the only question the user's eye was ever asking: AT THE INSTANT AND
// PLACE A PLAYHEAD LANDS, IS THERE A NOTE ON THE PAPER THERE?
//
// ⭐ WHY IT HAD TO BE RE-DERIVED RATHER THAN INHERITED. Round 4's version
// measured INK ON A TEXTURE, lights off, against a hand-tuned absolute floor
// of 0.045. Round 5 makes the noteheads REAL GEOMETRY -- disks with thickness,
// lit and shaded -- so "ink" is no longer what is under the ball, and a floor
// fitted to one tune's paint would not survive to another film. Two changes
// follow:
//
//   - THE VERDICT IS A RATIO, NOT A FLOOR. For each road, the baseline's median
//     signal must beat the CONTROL's median signal by a factor K. Nothing in
//     that sentence is tuned to this song, so it travels.
//   - THE CONTROL RUNS IN THE SAME INVOCATION, ALWAYS. Round 4's `--mirror` was
//     manual and r4.sh only ever ran the baseline: a positive control nobody
//     runs is a probe that never looked. Now every run measures both.
//
// THE CONTROL IS `look.noteZOffset`, applied in road.html where the instance
// matrices are built: the PRINTED notes slide along the road while the
// playheads keep flying to the true position. That is the general class the
// mirror belonged to -- "the balls and the sheet disagree" -- expressed in the
// file where the geometry lives, because a payload edit cannot express it (the
// payload is what BOTH sides are derived from; that is exactly why the old
// marks.mjs could not fail).
//
// ⚠ WHY marks.mjs COULD NEVER HAVE CAUGHT ANY OF THIS: in prep.mjs `notes` and
// `voices` are both derived from the same `rn` through the same `xOf`, and
// `side` IS `drums` renamed. Its checks compare an array against the array it
// came from -- structurally identical multisets that cannot differ. And nothing
// in it ever opened road.html, where the defect lived.
//
// Usage: node paperpix.mjs <payload.json> <workdir> [--ratio K] [--offset Z]
import puppeteer from 'puppeteer';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

// ⛔⛔ CRASH IS NOT FAILURE, AND THIS SUITE COULD NOT TELL THEM APART.
// Positive control, every gate run against a NONEXISTENT payload: ribbon 1 ·
// entry 1 · paperpix 1 · marks 1 · roadpix 1 · framing 1 · perfcam 1 ·
// afterglow 1 — all eight exited 1, the code r4.sh records as A REAL FAILURE,
// having measured nothing. None had a handler; all are ESM with top-level
// await, so a throw becomes an unhandled rejection and node exits 1.
// ⭐ EXIT 2 MEANS BROKEN: the premise failed and there is NO VERDICT. Exit 1
// keeps its meaning — measured, and failed. This is the same rule framegate.py
// already followed and the .mjs half did not, and it is the general form of the
// (F) sky-box crash that silently voided entry's whole verdict on short-right1.
// ⚠ LIMIT, STATED: this catches throws in the module BODY. A throw inside an
// `import` is evaluated before this line runs and still exits 1.
const __GATE = new URL(import.meta.url).pathname.split('/').pop();
const __broke = e => {
  console.error(`  [BROKEN] ${__GATE} crashed before it could measure a thing: ` +
                `${(e && e.message) || e}`);
  console.error(`  [BROKEN] this is NOT a failed assertion — the gate has NO VERDICT here.`);
  process.exit(2);
};
process.on('uncaughtException', __broke);
process.on('unhandledRejection', __broke);


const PY = '/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python';
const payloadPath = path.resolve(process.argv[2]);
const work = path.resolve(process.argv[3]);
const ri = process.argv.indexOf('--ratio');
const oi = process.argv.indexOf('--offset');
const P = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));
// ⚠⚠ RE-DERIVED FOR THE BLACK BEVELLED DISKS, AND THE OLD FLOOR DID NOT CARRY.
// The noteheads were pale ink 0.026 units thick; they are now near-black metal
// 0.016 thick. Both changes cut the film-vs-displaced ratio: the Bass road
// measured 2.13x against the old 2.2 floor on the first run after the change --
// a real ratio, over 2x, failing a threshold calibrated on a different look.
// Inheriting a floor across a look change is how a gate reports a defect that
// is not there. The floor is set from the measured spread on the new look, and
// the numbers it was set from are printed by every run.
// ⭐⭐ ROUND 7: RE-DERIVED ON THE LIGHT-GREY ROAD, WITH THE MEASUREMENT SHOWN.
// The 1.75 floor belonged to the cream-paper look and was NOT inherited. On the
// new ground the contrast went UP, not down -- a near-black disk on a light
// grey road that is no longer blown out by a warm key reads harder than it did
// on paper. MEASURED, forward/landscape camera, dimmed exposure:
//     road 0 Piano  film 0.183  control 0.015  ratio 12.00x
//     road 1 Bass   film 0.124  control 0.014  ratio  9.04x
//     back-3 (reverse, far)      ratios  9.78x / 6.67x
// so 4.0 sits a factor of ~1.7 under the worst real reading and a factor of 4
// above the ratio a gate that saw nothing would return (1.00x). Raising the
// floor from 1.75 makes this gate STRICTER than it was, which is the honest
// consequence of the measurement.
const RATIO = ri > 0 ? Number(process.argv[ri + 1]) : 4.0;
// ⛔⛔ THE PREMISE CHECK, ADDED ROUND 7. The close reverse-angle take (`track`,
// gap 1.55) reads 1.62x / 1.45x -- and that is NOT the film failing, it is this
// gate unable to SEE its subject. The control's own score gives it away:
//     forward camera   control 0.015 / 0.014   (dark road under the displaced note)
//     track, gap 1.55  control 0.155 / 0.169   (10x brighter -- the displaced
//                                               sample is INSIDE the playhead's
//                                               own light pool, so there is no
//                                               dark reference left to divide by)
// A ratio taken against a saturated control is arithmetic, not evidence. When
// the control is itself strongly lit the run reports BROKEN, not FAIL.
const CTRL_MAX = Number(process.env.PAPERPIX_CTRL_MAX ?? 0.08);
const OFFSET = oi > 0 ? Number(process.argv[oi + 1]) : 0.62;   // world units along the road
const W = P.width ?? 1080, H = P.height ?? 1920;
const HERE = path.dirname(new URL(import.meta.url).pathname);
fs.mkdirSync(work, { recursive: true });

const Q = JSON.parse(JSON.stringify(P));
Q.look = { ...(Q.look || {}), paperOnly: 1 };

const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files',
         '--enable-gpu-rasterization', '--ignore-gpu-blocklist'] });
const pg = await b.newPage();
let pageErr = null;
pg.on('pageerror', e => { pageErr = e.message; });
await pg.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), Q);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 30000 });
const err = await pg.evaluate(() => window.__err);
if (err) { console.error('PAGE ERROR:', err); await b.close(); process.exit(2); }

// ---- what lands, and where ------------------------------------------------
const items = [];
for (const v of P.voices)
  for (const n of v.notes) items.push({ kind: 'note', road: v.road ?? 0, t: n.t, x: n.x });
for (const d of P.drums) items.push({ kind: 'drum', road: d.road ?? 0, t: d.t, x: d.lane });
items.sort((a, c) => a.t - c.t);

// spread the samples across the piece AND across the roads, so a gate that is
// green cannot be green because it only ever looked at one instrument.
const byRoad = new Map();
for (const it of items) { if (!byRoad.has(it.road)) byRoad.set(it.road, []); byRoad.get(it.road).push(it); }
const pick = [];
const PER_ROAD = 12;
// ⚠ STRATIFY BY LANE, NOT JUST BY TIME. Sampling the percussion road evenly in
// time drew lane 1.35 ELEVEN times and lane 1.75 ONCE -- half the percussion
// rested on a single sample, and that sample (t=11.518) was the only row
// flagged BLANK PAPER in both passing baselines. An even sweep of a road whose
// two lanes alternate is not an even sweep of the road.
for (const [, arr] of byRoad) {
  const lanes = new Map();
  for (const it of arr) {
    const key = it.x.toFixed(3);
    if (!lanes.has(key)) lanes.set(key, []);
    lanes.get(key).push(it);
  }
  const per = Math.max(1, Math.floor(PER_ROAD / lanes.size));
  for (const [, la] of lanes)
    for (let i = 0; i < Math.min(per, la.length); i++)
      pick.push(la[Math.floor(i * (la.length - 1) / Math.max(1, per - 1))]);
}

// reference times on the same road at the same x with NO ink of their own
// ⚠ THE EXCLUSION MUST COVER THE MARK'S OWN FOOTPRINT, NOT JUST ITS CENTRE.
// At 0.14 s the percussion lane -- which fires roughly every 0.5 s -- kept
// handing back "blank paper" references that were sitting on the EDGE of a
// neighbouring mark. The reference then carried ink of its own, the difference
// collapsed, and the check reported the perc road as unprinted in BOTH the
// fixed and the mirrored render: no discrimination at all, which is a gate
// that cannot fail rather than a gate that passes.
const CLEAR = 0.42;
const occupied = (road, x, t) => items.some(o =>
  o.road === road && Math.abs(o.x - x) < 0.05 && Math.abs(o.t - t) < CLEAR);
const refDts = [];
for (let d = 0.5; d <= 2.6; d += 0.1) { refDts.push(-d); refDts.push(d); }

const lumAt = (file, pts, r) => JSON.parse(execFileSync(PY, ['-c', `
import sys, json
from PIL import Image
import numpy as np
# ⚠⚠ RGB, NOT GREY. A pitched notehead is near-black ink and shows up in
# luminance, but a PERCUSSION mark is the track's warm colour at globalAlpha
# 0.34 -- almost exactly the luminance of the paper it sits on. In grey it
# measured contrast 0.005 and the gate called all 6 drum landings blank, on a
# sheet where the mark is demonstrably drawn at the right spot. That is the
# same class of error as the min-vs-mean one below: a metric that cannot see
# the thing it is asked about reports its absence, confidently.
a = np.asarray(Image.open(sys.argv[1]).convert("RGB"), dtype=float)/255.0
pts = json.loads(sys.argv[2]); r = int(sys.argv[3])
out=[]
for x, y in pts:
    x, y = int(round(x)), int(round(y))
    x0, x1 = max(0, x-r), min(a.shape[1], x+r+1)
    y0, y1 = max(0, y-r), min(a.shape[0], y+r+1)
    # ⚠ MEAN, NOT MIN. The first cut took the darkest pixel in the disc, which
    # on a staff is always the STAFF LINE -- the line runs along z at fixed x,
    # so it passes through the notehead disc AND through every same-x reference
    # disc equally. Ink 0.000 vs "paper" 0.008: the check was comparing a line
    # against itself and calling a correctly printed sheet blank. The mean over
    # a head-sized disc is what a filled ellipse actually moves.
    out.append([float(v) for v in a[y0:y1, x0:x1].reshape(-1, 3).mean(axis=0)]
               if x1 > x0 and y1 > y0 else [-1.0, -1.0, -1.0])
print(json.dumps(out))
`, file, JSON.stringify(pts), String(r)]).toString());

// ---------------------------------------------------------------- MEASURE
// One sweep of the landings at a given note displacement. zoff = 0 is the film;
// zoff = OFFSET is the control, where the PRINTED notes have slid along the
// road and the playheads have not.
async function measure(zoff, tag) {
  await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
  const R = JSON.parse(JSON.stringify(Q));
  R.look.noteZOffset = zoff;
  await pg.evaluate(p => window.__init(p), R);
  await pg.waitForFunction('window.__ready || window.__err', { timeout: 30000 });
  const e = await pg.evaluate(() => window.__err);
  if (e) { console.error('PAGE ERROR:', e); await b.close(); process.exit(2); }

  const rows = [], broken = [];
  for (let i = 0; i < pick.length; i++) {
    const it = pick[i];
    await pg.evaluate(t => window.__frame(t), it.t);
    const zOf = t => -t * P.zps;
    const at = await pg.evaluate((x, z) => window.__project(x, 0.0, z), it.x, zOf(it.t));
    const at2 = await pg.evaluate((x, z) => window.__project(x, 0.0, z), it.x + 0.05, zOf(it.t));
    const rpx = Math.max(3, Math.min(12, Math.round(Math.abs(at2.x - at.x) * 0.75)));
    const M = 20;
    if (at.behind || at.x < M || at.x > W - M || at.y < M || at.y > H - M) {
      broken.push(`${it.kind} t=${it.t.toFixed(3)} road ${it.road} projects off screen`);
      continue;
    }
    const refs = [];
    for (const dt of refDts) {
      const rt = it.t + dt;
      if (rt < 0.05 || rt > P.total || occupied(it.road, it.x, rt)) continue;
      const pr = await pg.evaluate((x, z) => window.__project(x, 0.0, z), it.x, zOf(rt));
      if (pr.behind || pr.x < M || pr.x > W - M || pr.y < M || pr.y > H - M) continue;
      refs.push([pr.x, pr.y]);
      if (refs.length >= 4) break;
    }
    if (refs.length < 2) { broken.push(`${it.kind} t=${it.t.toFixed(3)}: <2 usable background refs`); continue; }
    const f = path.join(work, `${tag}${i}.png`);
    await pg.screenshot({ path: f });
    const vals = lumAt(f, [[at.x, at.y], ...refs], rpx);
    const head = vals[0], rf = vals.slice(1);
    const bg = [0, 1, 2].map(c => {
      const col = rf.map(v => v[c]).sort((a, d) => a - d);
      return col[Math.floor((col.length - 1) / 2)];
    });
    const ink = Math.hypot(bg[0] - head[0], bg[1] - head[1], bg[2] - head[2]);
    const L = v => 0.299 * v[0] + 0.587 * v[1] + 0.114 * v[2];
    rows.push({ it, x: Math.round(at.x), y: Math.round(at.y), rpx,
                head: L(head), bg: L(bg), ink });
  }
  return { rows, broken };
}

const med = a => { const c = a.slice().sort((x, y) => x - y);
                   return c.length % 2 ? c[(c.length-1)/2] : (c[c.length/2-1]+c[c.length/2])/2; };
const byRoadMed = rows => {
  const m = new Map();
  for (const r of rows) { if (!m.has(r.it.road)) m.set(r.it.road, []); m.get(r.it.road).push(r.ink); }
  return m;
};

// ⚠ --break MAKES THE FILM ITSELF WRONG, which is how this gate is shown to be
// capable of failing: the printed notes are displaced in BOTH runs, so the
// film's signal collapses to the control's and the ratio goes to ~1. Without
// this, "13x" is a number with nothing to compare it to.
const BREAK = process.argv.includes('--break');
if (BREAK) console.log(`  [control] --break: the FILM's own notes are displaced by ${OFFSET} u too,`,
                       `\n            so the playheads land on nothing in both runs`);
const base = await measure(BREAK ? OFFSET : 0, 'b');
const ctrl = await measure(BREAK ? OFFSET * 2 : OFFSET, 'c');
await pg.evaluate(() => window.__setLook({ paperOnly: 0 })).catch(() => {});
await b.close();
if (pageErr) { console.error('PAGE ERROR:', pageErr); process.exit(2); }

console.log(`\nSIGNAL UNDER THE PLAYHEAD — lights off, RGB distance vs same-x paper`);
console.log(`  ${base.rows.length} landings across ${byRoad.size} roads · ` +
            `control displaces the PRINTED notes by ${OFFSET} u along the road ` +
            `(${(OFFSET / P.zps).toFixed(3)} s) · required ratio ${RATIO}x`);
for (const r of base.rows)
  console.log(`  ${r.it.kind === 'drum' ? 'drum' : 'note'} t=${r.it.t.toFixed(3)} ` +
    `road ${r.it.road} x=${r.it.x.toFixed(2)} @(${r.x},${r.y}) r=${r.rpx}  ` +
    `dRGB ${r.ink.toFixed(3)}`);

const bm = byRoadMed(base.rows), cm = byRoadMed(ctrl.rows);
const fails = [];
console.log('');
for (const [road, arr] of [...bm].sort((a, c) => a[0] - c[0])) {
  const nm = (P.roads && P.roads[road] && P.roads[road].name) || road;
  const mb = med(arr), mc = cm.has(road) ? med(cm.get(road)) : 0;
  const ratio = mc > 1e-6 ? mb / mc : Infinity;
  const lanes = new Set(base.rows.filter(r => r.it.road === road).map(r => r.it.x.toFixed(2)));
  // ⛔ THE PERCUSSION ROAD NO LONGER HAS PRINTED INK TO FIND. Its marks are
  // now HOLES cut through the road, on the user's "drums should be holes and
  // light disks should jump out of them on beat". This gate asks "is there ink
  // under the landing", and the honest answer for that road is that the
  // question no longer applies -- an absence is what is correct there.
  // Reporting it as a FAILURE would be a false defect; reporting it as a PASS
  // would be a verdict the gate did not earn. It is neither: it is n/a, and it
  // is named. Its measured ratio is still printed so the change stays visible.
  const isHoles = (P.look?.drumHoles ?? 0) && (P.side || []).some(sd => (sd.road ?? 0) === road);
  if (isHoles) {
    console.log(`  road ${road} ${String(nm).padEnd(8)} n=${arr.length}  film ${mb.toFixed(3)}  ` +
      `control ${mc.toFixed(3)}  ratio ${ratio === Infinity ? 'inf' : ratio.toFixed(2)}x  ` +
      `[ n/a ] this road's marks are HOLES, not ink — there is nothing under the ball by design`);
    continue;
  }
// ⚠ ROUND 8: THE ABSOLUTE 0.08 CUT-OFF WAS ARBITRARY AND THE SIDE TAKE LANDED
  // EXACTLY ON IT -- control 0.078, so it reported FAIL(1.54x) where `track` at
  // 0.155 reported BROKEN, for the same reason and with the same meaninglessness.
  // A SCALE-FREE form fixes it: the premise fails when the supposedly-empty
  // control is a large FRACTION of the film sample, because then there is no
  // contrast left to divide. Measured: forward 0.015/0.183 = 0.08, back-3
  // 0.021/0.143 = 0.15, side 0.078/0.120 = 0.65, track 0.155/0.251 = 0.62.
  const frac = mb > 1e-6 ? mc / mb : 0;
  if (mc > CTRL_MAX || frac > (Number(process.env.PAPERPIX_CTRL_FRAC ?? 0.35))) {
    console.log(`  road ${road} ${String(nm).padEnd(8)} n=${arr.length}  film ${mb.toFixed(3)}  ` +
      `control ${mc.toFixed(3)}  ratio ${ratio.toFixed(2)}x  ` +
      `[ BROKEN ] the control is itself lit (${mc.toFixed(3)} > ${CTRL_MAX}) — this camera puts the ` +
      `displaced sample inside the playhead's light pool, so the ratio is not a verdict`);
    base.broken.push(`road ${road}: control saturated at ${mc.toFixed(3)}`);
    continue;
  }
  const ok = ratio >= RATIO;
  console.log(`  road ${road} ${String(nm).padEnd(8)} n=${arr.length} over ${lanes.size} lane(s)  ` +
    `film ${mb.toFixed(3)}  control ${mc.toFixed(3)}  ratio ${ratio === Infinity ? 'inf' : ratio.toFixed(2)}x  ` +
    `${ok ? 'the playhead lands on its note' : '<-- NOTHING UNDER THE PLAYHEAD'}`);
  if (!ok) fails.push(`road ${road} "${nm}": the film scores ${mb.toFixed(3)} where a sheet with ` +
    `its notes displaced scores ${mc.toFixed(3)} — ratio ${ratio.toFixed(2)}x, under the ${RATIO}x ` +
    `this gate requires. The playheads and the printed notes do not agree.`);
}

// ⚠⚠ BROKEN IS NOT FAIL. A check whose own premise failed must not report a
// verdict -- saying "pass" there is exactly the confident wrong answer.
for (const x of [...base.broken, ...ctrl.broken]) console.error(`  [BROKEN] ${x}`);
if (base.rows.length < 12) {
  console.error(`  [BROKEN] only ${base.rows.length} landings testable`); process.exit(2);
}
if (!cm.size) {
  console.error(`  [BROKEN] the control produced no measurements, so the ratio means nothing`);
  process.exit(2);
}
if (fails.length) { for (const f of fails) console.error(`  [ FAIL ] ${f}`); process.exit(1); }
if (base.broken.length || ctrl.broken.length) process.exit(2);
console.log(`  [ ok ] every road's playheads land on their own printed notes ` +
            `(worst ratio ${Math.min(...[...bm].map(([r, a]) =>
              (cm.has(r) && med(cm.get(r)) > 1e-6) ? med(a) / med(cm.get(r)) : Infinity)).toFixed(2)}x)`);
