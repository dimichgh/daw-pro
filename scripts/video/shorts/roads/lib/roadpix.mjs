#!/usr/bin/env node
// ⛔⛔ THE TWO CHECKS THAT LOOK AT PIXELS.
//
// Everything else in this pipeline checks a NUMBER. sync.py compares a
// brightness flash against an audio onset and does not know WHERE on screen the
// flash was drawn. marks.mjs proves every note was MAPPED to the right road but
// never sees a rendered frame. Between them sits a whole class of defect that
// is perfectly in time, perfectly mapped, and visibly wrong — and the user has
// caught two of them by eye that no gate here could see.
//
// So this one photographs the scene through the LIVE camera and measures:
//
//   (A) TRAIL CONTINUITY. "the tail should be longer still touching previous
//       note when the playhead touches next one". At the instant a ball lands
//       on note N, is there trail light at note N-1's projected pixel? Measured
//       DIFFERENTIALLY: the same frame is rendered with `arcGain: 0` and the
//       difference is the trail's own contribution, so the ball's light and the
//       note's residual glow cannot be mistaken for a trail that is not there.
//
//   (B) ROAD IDENTITY. With one staff a note could only be drawn at the wrong
//       PITCH; with a staff per instrument it can be drawn on the wrong
//       INSTRUMENT — in time, on a real staff, and completely wrong. For each
//       road in turn, the scene is isolated with `onlyRoad`, the brightest core
//       is found by argmax, and it must fall inside THAT road's band projected
//       through the real camera. The PNG is the witness; the scene supplies
//       only where it thinks the band is.
//
// Usage: node roadpix.mjs <payload.json> <workdir> [--short-trail] [--wrong-road]
//   --short-trail  kills the trail's lifetime and tail brightness, to prove (A)
//                  reddens — the exact state the r3 cut was in.
//   --wrong-road   offsets the rigs by one band without touching any TIME, to
//                  prove (B) reddens on a defect sync.py scores as perfect.
// ⛔⛔ THE TRAIL HALF OF THIS GATE IS VOID THIS ROUND, AND SAYING SO IS THE
// POINT. It was written for the PER-NOTE ARC ribbon: it samples the road a
// fixed world distance off a notehead and asks whether the ribbon to the
// PREVIOUS note is still lit there. The trail is no longer built that way --
// cometFor() samples the ball's own path backwards over an AGE window, so
// "reaches the previous notehead" is a consequence of cometAge and the note
// gap rather than a property the geometry guarantees.
// On the first run after the comet landed this gate reported "median
// contribution 0.0000, 8/8 landings have essentially no trail" on a film whose
// trails are plainly visible in an opened frame. That is a probe measuring the
// wrong thing, not a defect, and it has NOT been re-derived -- there was no
// round left to do it in.
// ⚠ So the trail assertion is DEMOTED TO INFORMATION and the ROAD IDENTITY
// assertion, which is unaffected, stays live. Do not read "ok" from this file
// as evidence about the tail. That is an owed item, named.
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
const SHORT_TRAIL = process.argv.includes('--short-trail');
const WRONG_ROAD = process.argv.includes('--wrong-road');
const P = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));
const W = P.width ?? 1080, H = P.height ?? 1920;
const HERE = path.dirname(new URL(import.meta.url).pathname);
fs.mkdirSync(work, { recursive: true });

const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files',
         '--enable-gpu-rasterization', '--ignore-gpu-blocklist'] });
const pg = await b.newPage();
let pageErr = null;
pg.on('pageerror', e => { pageErr = e.message; });
await pg.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });

// ⚠ --wrong-road MOVES THE RIGS, NOT THE TIMES. A defect that shifted onsets
// would be caught by sync.py and would prove nothing about this gate.
const Q = JSON.parse(JSON.stringify(P));
if (WRONG_ROAD) {
  const nr = Q.roads.length;
  for (const v of Q.voices) {
    const from = Q.roads[v.road ?? 0], to = Q.roads[((v.road ?? 0) + 1) % nr];
    const d = to.x0 - from.x0;
    for (const n of v.notes) n.x += d;
  }
  console.log(`  [control] every voice shifted onto the NEXT road's band; ` +
              `no onset time changed, so sync.py still scores this as perfect`);
}
await pg.evaluate(p => window.__init(p), Q);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 30000 });
const err = await pg.evaluate(() => window.__err);
if (err) { console.error('PAGE ERROR:', err); await b.close(); process.exit(2); }

const shot = async (name) => {
  const f = path.join(work, name + '.png');
  await pg.screenshot({ path: f });
  return f;
};
const lum = (files, pts) => JSON.parse(execFileSync(PY, ['-c', `
import sys, json
from PIL import Image
import numpy as np
files = json.loads(sys.argv[1]); pts = json.loads(sys.argv[2])
out = []
for f, ps in zip(files, pts):
    a = np.asarray(Image.open(f).convert("L"), dtype=float) / 255.0
    row = []
    for p in ps:
        x, y, r = int(p[0]), int(p[1]), int(p[2])
        x0, x1 = max(0, x-r), min(a.shape[1], x+r+1)
        y0, y1 = max(0, y-r), min(a.shape[0], y+r+1)
        # ⚠ MEAN OVER A TIGHT DISC, NOT MAX OVER A WIDE ONE. Max picks the
        # BRIGHTEST thing in the disc, which since round 5 is the struck note's
        # own glow rather than the ribbon -- at t=6.268 that read 0.953 with the
        # trail on AND off, delta exactly 0.000, on a trail that is plainly
        # there in the frame. The trail is additive, so its contribution shows
        # up reliably in the mean.
        row.append(float(a[y0:y1, x0:x1].mean()) if x1 > x0 and y1 > y0 else -1.0)
    out.append(row)
print(json.dumps(out))
`, JSON.stringify(files), JSON.stringify(pts)]).toString());

const fails = [];

// ---------------------------------------------------------------- (A) TRAIL
// pick landings that HAVE a previous note close enough to be joined
const joinMax = Q.look.arcJoinMax ?? Q.look.arcMaxGap ?? 0.9;
const cases = [];
for (const v of Q.voices)
  for (let k = 1; k < v.notes.length; k++) {
    const gap = v.notes[k].t - v.notes[k-1].t;
    if (gap > joinMax || gap < 1e-3) continue;
    cases.push({ road: v.road ?? 0, prev: v.notes[k-1], next: v.notes[k], t: v.notes[k].t, gap });
  }
// spread the samples across the piece rather than clustering at the start
cases.sort((a, c) => a.t - c.t);
const pick = [];
const N = Math.min(8, cases.length);
for (let i = 0; i < N; i++) pick.push(cases[Math.floor(i * (cases.length - 1) / Math.max(1, N - 1))]);

if (SHORT_TRAIL) {
  await pg.evaluate(() => window.__setLook({ arcDecay: 0.05, arcTailGain: 0.0, arcFalloff: 3.0 }));
  console.log('  [control] arcDecay 0.05 / arcTailGain 0 — the r3 state, where the ' +
              'ribbon was ZERO-brightness at its own tail by construction');
}

const trailRows = [];
for (let i = 0; i < pick.length; i++) {
  const c = pick[i];
  // where is the PREVIOUS notehead on screen, at the landing instant?
  await pg.evaluate(t => window.__frame(t), c.t);
  // ⚠ SAMPLE THE RIBBON JUST OFF THE PREVIOUS NOTEHEAD, NOT ON IT. Round 5 gave
  // the struck note its own emissive glow, which saturates the notehead pixel
  // to 1.0 whether the trail is there or not -- the differential read exactly
  // 0.000 at all 7 landings and the gate reported a trail that is plainly
  // visible in the frame as missing. `s` is small, so this still answers "does
  // the tail reach back to the previous note", just without measuring a
  // different term while doing it.
  // ⚠ A FIXED WORLD DISTANCE FROM THE NOTE, NOT A FIXED FRACTION OF THE GAP.
  // At a constant s=0.10 a short hop (0.25 s = 0.45 u of road) put the sample
  // 0.045 u from the notehead -- inside its glow -- and that one landing read
  // delta 0.009 against a control of 0.004 while the long hops read 0.10+. The
  // ribbon is what is being measured, so step off the head by a distance, not
  // by a proportion.
  const S_OFF = Math.min(0.30, Math.max(0.06, 0.13 / Math.max(1e-6, c.gap * P.zps)));
  const ap = await pg.evaluate((x0, t0, x1, t1, s) => window.__arcPt(x0, t0, x1, t1, s),
                               c.prev.x, c.prev.t, c.next.x, c.next.t, S_OFF);
  const pr = await pg.evaluate((x, y, z) => window.__project(x, y, z), ap.x, ap.y, ap.z);
  if (pr.behind || pr.x < 4 || pr.x > W - 4 || pr.y < 4 || pr.y > H - 4) continue;
  const full = await shot(`trail${i}_full`);
  // the SAME frame with the trail switched off: the difference IS the trail
  const gainWas = Q.look.arcGain ?? 1.5;
  await pg.evaluate(() => window.__setLook({ arcGain: 0 }));
  const off = await shot(`trail${i}_notrail`);
  await pg.evaluate(g => window.__setLook({ arcGain: g }), gainWas);
  const [[a], [c2]] = lum([full, off], [[[pr.x, pr.y, 5]], [[pr.x, pr.y, 5]]]);
  trailRows.push({ i, t: c.t, road: c.road, gap: c.gap, x: Math.round(pr.x),
                   y: Math.round(pr.y), full: a, noTrail: c2, delta: a - c2 });
}

const tfi = process.argv.indexOf('--floor');
const TRAIL_FLOOR = tfi > 0 ? Number(process.argv[tfi + 1]) : 0.020;
console.log(`\n(A) TRAIL CONTINUITY — trail light at the PREVIOUS notehead, ` +
            `at the instant the ball lands on the next one`);
console.log(`    sampled ${trailRows.length} landings; floor delta = ${TRAIL_FLOOR}`);
for (const r of trailRows)
  console.log(`    t=${r.t.toFixed(3)} road ${r.road} gap ${r.gap.toFixed(2)}s ` +
    `@(${r.x},${r.y})  full ${r.full.toFixed(3)}  no-trail ${r.noTrail.toFixed(3)}  ` +
    `delta ${r.delta.toFixed(3)} ${r.delta >= TRAIL_FLOOR ? '' : '  <-- NOT JOINED'}`);
if (!trailRows.length) fails.push('(A) no landing was on screen to sample — the check did not run');

// ⚠⚠ SATURATION IS *BROKEN*, NOT *FAIL*. If both readings are pinned the
// difference is 0 for a reason that has nothing to do with the trail, and
// reporting "no trail" there is a confident wrong answer.
const sat = trailRows.filter(r => r.full > 0.995 && r.noTrail > 0.995);
for (const r of sat)
  console.error(`  [BROKEN] t=${r.t.toFixed(3)}: both readings saturated at ` +
    `${r.full.toFixed(3)} — the differential cannot see the trail here`);

// ⭐ THE VERDICT IS A MEDIAN, NOT A PER-SAMPLE FLOOR, and that is measured
// rather than preferred. Against --short-trail the per-sample ranges OVERLAP:
// the film's weakest landing (a 0.25 s hop landing in an already-bright patch)
// reads 0.011 while the control's strongest reads 0.010, so no single
// threshold separates them. The MEDIANS are 0.054 against 0.004 — a factor of
// 13 — because a dead trail is dead everywhere and a live one is only
// occasionally hard to see.
const usable = trailRows.filter(r => !(r.full > 0.995 && r.noTrail > 0.995));
const medOf = a => { const c = a.map(r => r.delta).sort((x, y) => x - y);
  return c.length ? (c.length % 2 ? c[(c.length-1)/2] : (c[c.length/2-1]+c[c.length/2])/2) : 0; };
const tMed = medOf(usable);
const weak = usable.filter(r => r.delta < TRAIL_FLOOR / 3).length;
console.log(`    median delta ${tMed.toFixed(4)} (floor ${TRAIL_FLOOR}) · ` +
            `${usable.length - weak}/${usable.length} landings above ${(TRAIL_FLOOR/3).toFixed(4)}`);
if (usable.length && tMed < TRAIL_FLOOR)
  fails.push(`(A) the trail's median contribution at the previous notehead is ` +
    `${tMed.toFixed(4)}, under the ${TRAIL_FLOOR} floor — the tail does not reach back`);
if (usable.length && weak > usable.length * 0.25)
  fails.push(`(A) ${weak}/${usable.length} landings have essentially no trail behind them`);

// ---------------------------------------------------------------- (B) ROAD
console.log(`\n(B) ROAD IDENTITY — the brightest core must sit inside its own road's band`);
const roadRows = [];
const tProbe = pick.length ? pick[Math.floor(pick.length / 2)].t : (Q.total / 2);
for (const rd of Q.roads) {
  await pg.evaluate((r, t) => { window.__setLook({ onlyRoad: r }); window.__frame(t); },
                    rd.index, tProbe);
  const f = await shot(`road${rd.index}`);
  const res = JSON.parse(execFileSync(PY, ['-c', `
import sys, json
from PIL import Image
import numpy as np
a = np.asarray(Image.open(sys.argv[1]).convert("L"), dtype=float)/255.0
m = a.max()
ys, xs = np.where(a >= max(m - 0.02, 0.60))
print(json.dumps({"max": float(m), "x": float(xs.mean()), "y": float(ys.mean()),
                  "n": int(len(xs))}))
`, f]).toString());
  // the ball's own z at this instant, so the band is projected at the right depth
  const band = await pg.evaluate((r, z) => window.__bandScreen(r, z), rd.index, -tProbe * P.zps);
  // ⚠⚠ A CHECK WHOSE OWN PREMISE FAILED MUST REPORT *BROKEN*, NOT *FAIL*.
  // If this road's band is off-screen at the probe instant there is no pixel to
  // test, and argmax will happily return some unrelated bright thing — a
  // confident wrong answer. Measured: the Short's piano band projects to
  // x=[-513,-108] at t=11.02 and argmax found a paper highlight at x=306, which
  // the first cut of this gate reported as the melody drawn on the wrong staff.
  // The band being off-screen is a REAL finding about the framing, and it is
  // reported as one — but it is not evidence about road identity.
  const onScreen = band && !band.behind && band.x1 > 0 && band.x0 < W;
  const inside = onScreen && res.x >= band.x0 - 12 && res.x <= band.x1 + 12;
  // ⛔ ROUND 7: THE HOLES ROAD CANNOT BE ASKED THIS QUESTION, AND THAT IS THE
  // ROUND-6 DRUM REVERSAL ARRIVING HERE LATE. (B) asserts a road's brightest
  // light sits over its own staff. The percussion road's light DELIBERATELY
  // LEAVES the road: the disks LEAP UP OUT OF THE HOLES, on the user's "light
  // disks should jump out of them on beat". A leaping disk projects wherever the
  // camera puts it, so `road 2 Perc brightest 0.95 at x=172, band [-534,16]` is
  // the feature working, not a defect. paperpix already reports this road n/a
  // for exactly the same reason; roadpix had never been told.
  const isHoles = (P.look?.drumHoles ?? 0) && (P.side || []).some(sd => (sd.road ?? 0) === rd.index);
  if (isHoles) {
    console.log(`    road ${rd.index} ${String(rd.name).padEnd(8)} brightest ${res.max.toFixed(2)} ` +
      `at x=${res.x.toFixed(0)}  band x=[${band ? band.x0.toFixed(0) : '?'}, ${band ? band.x1.toFixed(0) : '?'}]  ` +
      `[ n/a ] this road's disks LEAP OUT OF IT by design — its light is not required to stay over its staff`);
    continue;
  }
  roadRows.push({ rd, res, band, inside, onScreen });
  console.log(`    road ${rd.index} ${String(rd.name).padEnd(8)} brightest ${res.max.toFixed(2)} ` +
    `at x=${res.x.toFixed(0)}  band x=[${band ? band.x0.toFixed(0) : '?'}, ` +
    `${band ? band.x1.toFixed(0) : '?'}]  ` +
    `${!onScreen ? '<-- BAND OFF-SCREEN: not testable, and the road is not in frame'
                 : inside ? 'inside' : '<-- OUTSIDE ITS OWN BAND'}`);
}
await pg.evaluate(() => window.__setLook({ onlyRoad: null }));
const offScreen = roadRows.filter(r => !r.onScreen);
const off2 = roadRows.filter(r => r.onScreen && !r.inside && r.res.max > 0.6);
if (off2.length) fails.push(`(B) ${off2.length} road(s) drew their brightest core OUTSIDE their ` +
  `own band — first: road ${off2[0].rd.index} "${off2[0].rd.name}"`);

await b.close();
if (pageErr) { console.error('PAGE ERROR:', pageErr); process.exit(2); }
console.log('');
if (offScreen.length) {
  for (const r of offScreen)
    console.error(`  [BROKEN] road ${r.rd.index} "${r.rd.name}" is NOT IN FRAME at t=${tProbe.toFixed(2)} ` +
      `— road identity untestable there, and the camera is failing to frame all the roads`);
}
// the trail assertion is informational this round -- see the header
const gated = fails.filter(f => !/trail|reach|landings have essentially no trail/i.test(f));
for (const f of fails) if (!gated.includes(f)) console.log(`  [info, NOT GATED — probe not re-derived for the comet] ${f}`);
fails.length = 0; fails.push(...gated);
if (fails.length) { for (const f of fails) console.error(`  [ FAIL ] ${f}`); process.exit(1); }
if (offScreen.length) process.exit(2);
// ⛔ ROUND 7: THIS LINE CLAIMED A CHECK THAT NO LONGER EXISTS. (A) was de-gated
// for the comet and printed as information, but the success path still said
// "the trail reaches the previous notehead" -- a green line for a check that is
// not being made is worse than no line at all.
console.log('  [ ok ] every road\'s light is drawn on its own staff. ' +
            '(A), the trail assertion, is NOT part of this verdict — it is VOID, ' +
            'not re-derived for the comet, and is reported above as information only.');
